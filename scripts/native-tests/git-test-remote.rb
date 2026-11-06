#!/usr/bin/ruby
# frozen_string_literal: true

# Local HTTP Git remote for the mobile push acceptance (G2 on the simulator,
# later G3 on a phone pointed at the Mac's LAN address).
#
# Runs on the system Ruby (2.6) because it ships WEBrick. Serves bare
# repositories through `git http-backend` with HTTP basic auth checked here,
# never by git. Nothing external is contacted.
#
#   git-test-remote.rb init   --root DIR
#   git-test-remote.rb serve  --root DIR --port N [--bind 127.0.0.1]
#                             --user U --token T
#   git-test-remote.rb compete --root DIR --repo target.git --branch B
#   git-test-remote.rb verify --root DIR --repo target.git --branch B
#                             --expect-oid OID [--file PATH=SHA256 ...]
#
# Repositories under DIR:
#   public.git  anonymous fetch (public clone leg), push always denied
#   target.git  basic auth required for every request, non-force push only
#   stall.git   authenticated info/refs sleeps 8 s (push cancellation tests)
#   slow-public.git anonymous fetch with an 8 s delay; push always denied
#
# Layout of DIR/server.json (written by `serve`, read by the orchestrator):
#   {"port": N, "bind": "…", "pid": N, "public_url": "…", "target_url": "…",
#    "user": "…", "started_at": "…"}

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'socket'
require 'time'
require 'webrick'

GIT = ENV.fetch('DSH_GIT', 'git')
PUBLIC_REPO = 'public.git'
TARGET_REPO = 'target.git'
STALL_REPO = 'stall.git'
SLOW_PUBLIC_REPO = 'slow-public.git'
REALM = 'rish-git-test'

def sh!(*command, chdir: nil, input: nil)
  options = {}
  options[:chdir] = chdir if chdir
  options[:stdin_data] = input if input
  output, status = Open3.capture2e(*command, **options)
  raise "#{command.join(' ')} failed (#{status.exitstatus}):\n#{output}" unless status.success?

  output
end

def git(*args, dir:, input: nil)
  sh!(GIT, '--git-dir', dir, *args, input: input).strip
end

def bare_path(root, repo)
  File.join(root, repo)
end

def seed_public(root)
  dir = bare_path(root, PUBLIC_REPO)
  return dir if File.directory?(dir)

  sh!(GIT, 'init', '--bare', '--quiet', '--initial-branch=main', dir)
  work = File.join(root, 'seed-work')
  FileUtils.rm_rf(work)
  sh!(GIT, 'clone', '--quiet', dir, work)
  File.write(File.join(work, 'README.md'), "# rish push acceptance seed\n")
  File.write(File.join(work, 'hello.txt'), "hello from the local test remote\n")
  sh!(GIT, 'add', '.', chdir: work)
  sh!(GIT, '-c', 'user.name=Rish Test', '-c', 'user.email=test@rish.local',
      'commit', '--quiet', '-m', 'seed', chdir: work)
  sh!(GIT, 'push', '--quiet', 'origin', 'main', chdir: work)
  FileUtils.rm_rf(work)
  sh!(GIT, 'config', 'http.receivepack', 'false', chdir: dir)
  dir
end

def seed_target(root)
  dir = bare_path(root, TARGET_REPO)
  return dir if File.directory?(dir)

  sh!(GIT, 'clone', '--bare', '--quiet', bare_path(root, PUBLIC_REPO), dir)
  sh!(GIT, 'config', 'http.receivepack', 'true', chdir: dir)
  sh!(GIT, 'config', 'receive.denyNonFastForwards', 'true', chdir: dir)
  sh!(GIT, 'config', 'receive.denyDeletes', 'true', chdir: dir)
  dir
end

def seed_stall(root)
  dir = bare_path(root, STALL_REPO)
  return dir if File.directory?(dir)

  sh!(GIT, 'clone', '--bare', '--quiet', bare_path(root, PUBLIC_REPO), dir)
  sh!(GIT, 'config', 'http.receivepack', 'true', chdir: dir)
  dir
end

def init_root(root)
  FileUtils.mkdir_p(root)
  seed_public(root)
  slow_public = bare_path(root, SLOW_PUBLIC_REPO)
  unless File.directory?(slow_public)
    sh!(GIT, 'clone', '--bare', '--quiet', bare_path(root, PUBLIC_REPO), slow_public)
    sh!(GIT, 'config', 'http.receivepack', 'false', chdir: slow_public)
  end
  seed_target(root)
  seed_stall(root)
  root
end

# Creates a competing commit on top of the branch tip using only system git
# plumbing on the bare repository: an independent client, not the app.
def compete(root, repo, branch, message = 'competing commit from the Mac')
  dir = bare_path(root, repo)
  ref = "refs/heads/#{branch}"
  old = git('rev-parse', '--verify', ref, dir: dir)
  tree = git('rev-parse', "#{old}^{tree}", dir: dir)
  blob = git('hash-object', '-w', '--stdin', dir: dir,
             input: "competing change #{Time.now.utc.iso8601}\n")
  entries = git('ls-tree', tree, dir: dir).lines.map(&:chomp)
  entries.reject! { |line| line.end_with?("\tCOMPETING.txt") }
  entries << "100644 blob #{blob}\tCOMPETING.txt"
  new_tree = git('mktree', dir: dir, input: entries.join("\n") + "\n")
  env_args = ['-c', 'user.name=Rish Test', '-c', 'user.email=test@rish.local']
  new_commit = sh!(GIT, *env_args, '--git-dir', dir, 'commit-tree', new_tree,
                   '-p', old, '-m', message).strip
  git('update-ref', ref, new_commit, old, dir: dir)
  { 'repo' => repo, 'branch' => branch, 'old_oid' => old, 'oid' => new_commit }
end

def refs(root, repo)
  dir = bare_path(root, repo)
  git('for-each-ref', '--format=%(refname) %(objectname)', dir: dir)
    .lines.map(&:split).to_h
end

def file_sha256(root, repo, oid, path)
  dir = bare_path(root, repo)
  data, status = Open3.capture2(GIT, '--git-dir', dir, 'cat-file', '-p', "#{oid}:#{path}")
  return nil unless status.success?

  Digest::SHA256.hexdigest(data)
end

class GitBackend < WEBrick::HTTPServlet::AbstractServlet
  def initialize(server, root, user, token, report_path)
    super(server)
    @root = root
    @user = user
    @token = token
    @report_path = report_path
    @backend = File.join(`#{GIT} --exec-path`.strip, 'git-http-backend')
    raise "git-http-backend missing at #{@backend}" unless File.executable?(@backend)
  end

  def do_GET(req, res)
    handle(req, res)
  end

  def do_POST(req, res)
    handle(req, res)
  end

  private

  def authorized?(req)
    header = req['authorization'].to_s
    return false unless header.start_with?('Basic ')

    decoded = Base64.decode64(header.sub('Basic ', ''))
    decoded == "#{@user}:#{@token}"
  end

  def unauthorized(res)
    res.status = 401
    res['WWW-Authenticate'] = "Basic realm=\"#{REALM}\""
    res['Content-Type'] = 'text/plain'
    res.body = "authentication required\n"
  end

  def json(res, status, payload)
    res.status = status
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate(payload) + "\n"
  end

  def handle(req, res)
    path = req.path
    return handle_control(req, res) if path.start_with?('/g2/')

    repo = path.split('/')[1].to_s
    service = req.query['service'] || (path.end_with?('/git-receive-pack') ? 'git-receive-pack' : nil)
    receive = service == 'git-receive-pack' || path.end_with?('/git-receive-pack')
    case repo
    when PUBLIC_REPO
      return json(res, 403, 'error' => 'push is disabled on the public repository') if receive
    when SLOW_PUBLIC_REPO
      return json(res, 403, 'error' => 'push is disabled on the public repository') if receive

      sleep Float(ENV.fetch('DSH_GIT_TEST_CLONE_DELAY', '8')).clamp(0, 60) if path.end_with?('/info/refs')
    when TARGET_REPO
      return unauthorized(res) unless authorized?(req)
    when STALL_REPO
      return unauthorized(res) unless authorized?(req)

      sleep 8 if path.end_with?('/info/refs')
    else
      return json(res, 404, 'error' => 'unknown repository')
    end
    run_backend(req, res)
  end

  def handle_control(req, res)
    case [req.request_method, req.path]
    when ['GET', '/g2/health']
      json(res, 200, 'ok' => true, 'time' => Time.now.utc.iso8601)
    when ['GET', '/g2/refs']
      return unauthorized(res) unless authorized?(req)

      json(res, 200, 'refs' => refs(@root, req.query['repo'] || TARGET_REPO))
    when ['POST', '/g2/compete']
      return unauthorized(res) unless authorized?(req)

      body = JSON.parse(req.body.to_s)
      json(res, 200, compete(@root, body.fetch('repo', TARGET_REPO), body.fetch('branch')))
    when ['POST', '/g2/report']
      return unauthorized(res) unless authorized?(req)

      payload = JSON.parse(req.body.to_s)
      File.write(@report_path, JSON.pretty_generate(payload) + "\n")
      json(res, 200, 'stored' => @report_path)
    else
      json(res, 404, 'error' => 'unknown control endpoint')
    end
  rescue StandardError => error
    json(res, 500, 'error' => error.class.name, 'detail' => error.message)
  end

  def run_backend(req, res)
    env = {
      'GIT_PROJECT_ROOT' => @root,
      'GIT_HTTP_EXPORT_ALL' => '1',
      'PATH_INFO' => req.path,
      'QUERY_STRING' => req.query_string.to_s,
      'REQUEST_METHOD' => req.request_method,
      'CONTENT_TYPE' => req['content-type'].to_s,
      'REMOTE_ADDR' => req.peeraddr[3].to_s,
      'REMOTE_USER' => authorized?(req) ? @user : '',
      'SERVER_PROTOCOL' => 'HTTP/1.1',
      'GATEWAY_INTERFACE' => 'CGI/1.1',
    }
    body = req.request_method == 'POST' ? req.body.to_s : ''
    env['CONTENT_LENGTH'] = body.bytesize.to_s if req.request_method == 'POST'
    env['HTTP_CONTENT_ENCODING'] = req['content-encoding'] if req['content-encoding']
    output, status = Open3.capture2e(env, @backend, stdin_data: body, binmode: true)
    raise "git-http-backend exited #{status.exitstatus}" unless status.success?

    headers, payload = output.split("\r\n\r\n", 2)
    headers, payload = output.split("\n\n", 2) if payload.nil?
    res.status = 200
    headers.to_s.each_line do |line|
      name, value = line.chomp.split(':', 2)
      next if name.nil? || value.nil?

      if name.casecmp('Status').zero?
        res.status = value.strip.split(' ').first.to_i
      else
        res[name] = value.strip
      end
    end
    res['Connection'] = 'close'
    res.body = payload.to_s
  end
end

def serve(options)
  root = init_root(options[:root])
  report_path = File.join(root, 'g2-report.json')
  server = WEBrick::HTTPServer.new(
    BindAddress: options[:bind],
    Port: options[:port],
    AccessLog: [[$stderr, '%h %m %U %s %b']],
    Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
    RequestTimeout: 120,
  )
  server.mount('/', GitBackend, root, options[:user], options[:token], report_path)
  port = server.config[:Port]
  host = options[:bind]
  File.write(File.join(root, 'server.json'), JSON.pretty_generate(
    'port' => port,
    'bind' => host,
    'pid' => Process.pid,
    'public_url' => "http://#{host}:#{port}/#{PUBLIC_REPO}",
    'target_url' => "http://#{host}:#{port}/#{TARGET_REPO}",
    'stall_url' => "http://#{host}:#{port}/#{STALL_REPO}",
    'user' => options[:user],
    'report_path' => report_path,
    'started_at' => Time.now.utc.iso8601,
  ) + "\n")
  $stderr.puts "git-test-remote: serving #{root} on http://#{host}:#{port} (user #{options[:user]})"
  %w[INT TERM].each { |signal| trap(signal) { server.shutdown } }
  server.start
end

def verify(options)
  root = options[:root]
  repo = options[:repo]
  branch = options[:branch]
  dir = bare_path(root, repo)
  failures = []
  fsck = sh!(GIT, '--git-dir', dir, 'fsck', '--full', '--strict')
  failures << "fsck output: #{fsck}" unless fsck.strip.empty?
  actual = git('rev-parse', '--verify', "refs/heads/#{branch}", dir: dir)
  puts "#{repo} refs/heads/#{branch} = #{actual}"
  if options[:expect_oid] && actual != options[:expect_oid]
    failures << "remote OID #{actual} != expected #{options[:expect_oid]}"
  end
  options[:files].each do |path, expected|
    digest = file_sha256(root, repo, actual, path)
    puts "#{path} sha256 = #{digest}"
    failures << "#{path}: #{digest} != #{expected}" unless digest == expected
  end
  if options[:ancestor]
    _out, status = Open3.capture2e(GIT, '--git-dir', dir, 'merge-base',
                                   '--is-ancestor', options[:ancestor], actual)
    failures << "#{options[:ancestor]} is not an ancestor of #{actual}" unless status.success?
  end
  failures.each { |failure| warn "VERIFY FAIL: #{failure}" }
  failures.empty?
end

def parse(argv)
  options = {
    root: nil, port: 0, bind: '127.0.0.1', user: 'rish', token: nil,
    repo: TARGET_REPO, branch: nil, expect_oid: nil, files: {}, ancestor: nil,
  }
  command = argv.shift
  OptionParser.new do |parser|
    parser.on('--root DIR') { |value| options[:root] = File.expand_path(value) }
    parser.on('--port N', Integer) { |value| options[:port] = value }
    parser.on('--bind ADDR') { |value| options[:bind] = value }
    parser.on('--user U') { |value| options[:user] = value }
    parser.on('--token T') { |value| options[:token] = value }
    parser.on('--repo NAME') { |value| options[:repo] = value }
    parser.on('--branch NAME') { |value| options[:branch] = value }
    parser.on('--expect-oid OID') { |value| options[:expect_oid] = value }
    parser.on('--ancestor OID') { |value| options[:ancestor] = value }
    parser.on('--file PATH=SHA256') do |value|
      path, digest = value.split('=', 2)
      options[:files][path] = digest
    end
  end.parse!(argv)
  abort 'usage: git-test-remote.rb <init|serve|compete|verify> --root DIR ...' if command.nil? || options[:root].nil?
  [command, options]
end

command, options = parse(ARGV)
case command
when 'init'
  init_root(options[:root])
  puts JSON.generate('root' => options[:root], 'refs' => refs(options[:root], TARGET_REPO))
when 'serve'
  abort 'serve requires --token' if options[:token].to_s.empty?
  serve(options)
when 'compete'
  abort 'compete requires --branch' if options[:branch].to_s.empty?
  puts JSON.generate(compete(options[:root], options[:repo], options[:branch]))
when 'verify'
  abort 'verify requires --branch' if options[:branch].to_s.empty?
  exit(verify(options) ? 0 : 1)
else
  abort "unknown command #{command}"
end
