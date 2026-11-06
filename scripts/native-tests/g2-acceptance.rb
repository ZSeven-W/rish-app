#!/usr/bin/ruby
# frozen_string_literal: true

# G2 acceptance drive (remote push half) on the iOS Simulator.
#
# 1. Starts the local HTTP Git remote (git-test-remote.rb) with a fresh
#    random token.
# 2. Holds the shared simulator lock and runs the native XCTest drive
#    RishTests/GitPushG2Tests inside the app process. The drive clones
#    the public repository without credentials, commits, configures the
#    dedicated target remote, provisions the token through the native prompt
#    flow, pushes a new branch, asks the Mac (through the server) for a
#    competing commit, commits again, and proves the second push fails as
#    non-fast-forward. It reports every fact to the server.
# 3. Verifies the report independently with the system git against the bare
#    repository: remote OID, file hashes, ancestry, and that nothing from the
#    rejected push reached the remote.
#
#   g2-acceptance.rb --root DIR [--simulator UDID] [--derived-data DIR]
#                    [--bind 127.0.0.1] [--port 0] [--branch NAME]
#                    [--lock /tmp/rish-sim-lock] [--lock-owner NAME]
#                    [--project PATH] [--report-only] [--clone-only]
# Build the unsigned GPUI Release simulator app first with apps/gpui/scripts/build-ios.sh --release.
# --clone-only runs anonymous clone acceptance without credential or push actions.

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'securerandom'
require 'time'

SCRIPT_DIR = __dir__
REMOTE_SCRIPT = File.join(SCRIPT_DIR, 'git-test-remote.rb')
GIT = ENV.fetch('DSH_GIT', 'git')

options = {
  root: nil,
  simulator: 'F1B37F70-497C-4C1E-9C5C-87F4CC5448AC',
  derived_data: nil,
  bind: '127.0.0.1',
  port: 0,
  branch: "g2/simulator-#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}",
  lock: '/tmp/rish-sim-lock',
  lock_owner: 'wp/git-push',
  project: File.expand_path('../../apps/gpui/ios/RishGPUI.xcodeproj', SCRIPT_DIR),
  report_only: false,
  clone_only: false,
}
OptionParser.new do |parser|
  parser.on('--root DIR') { |value| options[:root] = File.expand_path(value) }
  parser.on('--simulator UDID') { |value| options[:simulator] = value }
  parser.on('--derived-data DIR') { |value| options[:derived_data] = File.expand_path(value) }
  parser.on('--bind ADDR') { |value| options[:bind] = value }
  parser.on('--port N', Integer) { |value| options[:port] = value }
  parser.on('--branch NAME') { |value| options[:branch] = value }
  parser.on('--lock PATH') { |value| options[:lock] = value }
  parser.on('--lock-owner NAME') { |value| options[:lock_owner] = value }
  parser.on('--project PATH') { |value| options[:project] = File.expand_path(value) }
  parser.on('--clone-only') { options[:clone_only] = true }
  parser.on('--report-only') { options[:report_only] = true }
end.parse!
abort 'usage: g2-acceptance.rb --root DIR [...]' if options[:root].nil?
abort '--clone-only cannot be combined with --report-only' if options[:clone_only] && options[:report_only]

root = options[:root]
FileUtils.mkdir_p(root)
transcript = File.open(File.join(root, 'g2-transcript.log'), 'a')
transcript.sync = true

def log(transcript, line)
  stamped = "[#{Time.now.utc.iso8601}] #{line}"
  puts stamped
  transcript.puts(stamped)
end

def git(dir, *args)
  output, status = Open3.capture2e(GIT, '--git-dir', dir, *args)
  [output.strip, status.success?]
end

def hold_lock(path, owner, transcript)
  loop do
    begin
      File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(owner) }
      log(transcript, "acquired #{path}")
      return
    rescue Errno::EEXIST
      log(transcript, "#{path} held by #{File.read(path).strip rescue '?'}; waiting 30 s")
      sleep 30
    end
  end
end

def release_lock(path, owner, transcript)
  return unless File.exist?(path)

  if (File.read(path).strip rescue nil) == owner
    File.delete(path)
    log(transcript, "released #{path}")
  end
end

server_pid = nil
token = SecureRandom.hex(20)
user = 'rish'
server_json = File.join(root, 'server.json')
report_path = File.join(root, 'g2-report.json')

at_exit do
  release_lock(options[:lock], options[:lock_owner], transcript)
  if server_pid
    begin
      Process.kill('TERM', server_pid)
      Process.wait(server_pid)
    rescue StandardError
      nil
    end
    log(transcript, 'server stopped')
  end
end

unless options[:report_only]
  FileUtils.rm_f(server_json)
  FileUtils.rm_f(report_path)
  server_log = File.join(root, 'server.log')
  server_pid = Process.spawn(
    '/usr/bin/ruby', REMOTE_SCRIPT, 'serve', '--root', root,
    '--port', options[:port].to_s, '--bind', options[:bind],
    '--user', user, '--token', token,
    out: server_log, err: server_log,
  )
  log(transcript, "server pid #{server_pid}, log #{server_log}")
  60.times do
    break if File.exist?(server_json)

    sleep 0.5
  end
  abort 'server did not publish server.json' unless File.exist?(server_json)
end

server = JSON.parse(File.read(server_json))
base = "http://#{server['bind']}:#{server['port']}"
health = Net::HTTP.get_response(URI("#{base}/g2/health"))
abort "server health check failed: #{health.code}" unless health.code == '200'
log(transcript, "server healthy at #{base}; public=#{server['public_url']} target=#{server['target_url']}")

unless options[:report_only]
  env = {
    'TEST_RUNNER_DSH_G2_SERVER' => base,
    'TEST_RUNNER_DSH_G2_PUBLIC_URL' => server['public_url'],
    'TEST_RUNNER_DSH_G2_TARGET_URL' => server['target_url'],
    'TEST_RUNNER_DSH_G2_STALL_URL' => server['stall_url'],
    'TEST_RUNNER_DSH_G2_USER' => user,
    'TEST_RUNNER_DSH_G2_TOKEN' => token,
    'TEST_RUNNER_DSH_G2_BRANCH' => options[:branch],
  }
  command = [
    'xcodebuild', 'test',
    '-project', options[:project],
    '-scheme', 'RishGPUI',
    '-configuration', 'Release',
    '-destination', "id=#{options[:simulator]}",
    options[:clone_only] ? '-only-testing:RishTests/GitPushG2Tests/testCloneOperationTransferCancellationAndPublication' : '-only-testing:RishTests/GitPushG2Tests',
  ]
  command += ['-derivedDataPath', options[:derived_data]] if options[:derived_data]
  command << 'CODE_SIGNING_ALLOWED=NO'
  { 'RISH_GPUI_NATIVE_VENDOR' => 'RISH_NATIVE_VENDOR', 'RISH_GPUI_NATIVE_INCLUDE' => 'RISH_NATIVE_INCLUDE' }.each do |environment, setting|
    command << "#{setting}=#{ENV[environment]}" if ENV[environment]
  end
  xcode_log = File.join(root, 'xcodebuild-g2.log')
  hold_lock(options[:lock], options[:lock_owner], transcript)
  log(transcript, "xcodebuild: #{command.join(' ')}")
  started = Time.now
  status = nil
  File.open(xcode_log, 'w') do |file|
    Open3.popen2e(env, *command) do |_stdin, output, wait|
      output.each_line do |line|
        file.write(line)
        transcript.puts(line.chomp) if line =~ /Test Case|Executed|error:|G2:/
        puts line if line =~ /Test Case '.*(passed|failed)|Executed|\*\* TEST|error:|G2:/
      end
      status = wait.value
    end
  end
  release_lock(options[:lock], options[:lock_owner], transcript)
  log(transcript, "xcodebuild exit #{status.exitstatus} after #{(Time.now - started).round}s; log #{xcode_log}")
  abort 'GitPushG2Tests did not pass' unless status.success?
end

if options[:clone_only]
  log(transcript, 'Clone transfer, cancellation, cleanup, offline failure, and publication: PASS')
  exit 0
end

abort "no report at #{report_path}" unless File.file?(report_path)
report = JSON.parse(File.read(report_path))
log(transcript, "report: #{JSON.generate(report)}")

target_dir = File.join(root, 'target.git')
branch = report.fetch('branch')
failures = []
check = lambda do |condition, message|
  log(transcript, "#{condition ? 'PASS' : 'FAIL'} #{message}")
  failures << message unless condition
end

fsck, fsck_ok = git(target_dir, 'fsck', '--full', '--strict')
check.call(fsck_ok && fsck.empty?, "target.git fsck --full --strict is clean (#{fsck.inspect})")

first = report.fetch('first_push')
receipt = first.fetch('receipt')
commit1 = report.fetch('commit1_oid')
check.call(receipt['local_oid'] == commit1, "receipt local_oid equals the app's commit #{commit1}")
check.call(receipt['remote_oid'] == commit1, "receipt remote_oid (server read-back) equals #{commit1}")
check.call(receipt['branch'] == branch && receipt['host'] == server['bind'],
           "receipt names branch #{branch} on host #{server['bind']}")
type1, _ = git(target_dir, 'cat-file', '-t', commit1)
check.call(type1 == 'commit', "system git finds commit #{commit1} in target.git")

report.fetch('files').each do |file|
  content, ok = Open3.capture2(GIT, '--git-dir', target_dir, 'cat-file', '-p', "#{commit1}:#{file['path']}")
  digest = ok.success? ? Digest::SHA256.hexdigest(content) : nil
  check.call(digest == file['sha256'], "#{file['path']} sha256 #{digest} equals mobile hash #{file['sha256']}")
end

compete = report.fetch('compete')
tip, _ = git(target_dir, 'rev-parse', '--verify', "refs/heads/#{branch}")
check.call(tip == compete['oid'], "remote #{branch} tip #{tip} is the Mac's competing commit #{compete['oid']}")
_, ancestor = git(target_dir, 'merge-base', '--is-ancestor', commit1, tip)
check.call(ancestor, "pushed commit #{commit1} is an ancestor of the competing commit (first push landed, history intact)")
check.call(compete['old_oid'] == commit1, "competing commit was built on top of the pushed commit")

second = report.fetch('second_push')
commit2 = report.fetch('commit2_oid')
check.call(second['code'] == 'non-fast-forward', "second push failed with code #{second['code'].inspect}")
_, commit2_present = git(target_dir, 'cat-file', '-e', commit2)
check.call(!commit2_present, "rejected commit #{commit2} never reached target.git")
check.call(report['head_after_nff'] == commit2, "local HEAD still at #{commit2} after the rejected push")
check.call(report['status_after_nff']['branch'] == branch, "local branch is still #{branch}")

credential = report.fetch('credential_status')
check.call(!credential.key?('token') && !credential.key?('username') && credential['configured'] == true,
           'bridge credential status carries no secret and reports configured')
check.call(credential['expiry_seconds'] == 3600, 'prompt stored the 1 hour expiry')
check.call(report['push_without_credential_code'] == 'credential', 'push before provisioning was refused with code credential')
check.call(report['receipts_count'].to_i >= 1, 'receipt journal surfaced through the bridge')
check.call(report['cleared_credential']['configured'] == false, 'clearCredential left no credential behind')

summary = {
  'schema_version' => 1,
  'gate' => 'G2-remote-push',
  'platform' => 'ios_simulator',
  'simulator' => options[:simulator],
  'server' => base,
  'branch' => branch,
  'commit1_oid' => commit1,
  'competing_oid' => compete['oid'],
  'commit2_oid' => commit2,
  'failures' => failures,
  'verified_at' => Time.now.utc.iso8601,
}
File.write(File.join(root, 'g2-summary.json'), JSON.pretty_generate(summary) + "\n")
log(transcript, "summary: #{JSON.generate(summary)}")
if failures.empty?
  log(transcript, 'G2 remote push acceptance PASSED on the simulator')
  exit 0
end
log(transcript, "G2 remote push acceptance FAILED: #{failures.size} check(s)")
exit 1
