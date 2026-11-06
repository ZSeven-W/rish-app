#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'io/console'
require 'open3'
require 'yaml'

secure_stdin = ARGV.delete('--secure-stdin')
udid = ARGV.fetch(0) do
  abort 'usage: provision-simulator-key.rb [--secure-stdin] <simulator-udid> [bundle-id] [credential-slot]'
end
bundle_id = ARGV.fetch(1, 'tech.zseven.rish.gpui')
slot = ARGV.fetch(2, 'DEEPSEEK_API_KEY')
abort 'unknown credential slot' unless %w[DEEPSEEK_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY].include?(slot)
credentials_path = ENV['DSH_CREDENTIALS']

key = if secure_stdin
        abort '--secure-stdin requires an interactive terminal' unless $stdin.tty?
        $stderr.print "#{slot} (input hidden): "
        value = $stdin.noecho(&:gets)&.strip
        $stderr.puts
        value
      else
        abort 'set DSH_CREDENTIALS to a 0600 YAML credential file you own, or use --secure-stdin' if credentials_path.nil?
        source_stat = File.lstat(credentials_path)
        abort 'managed credential source must be a regular file, not a symlink' unless source_stat.file? && !source_stat.symlink?
        abort 'managed credential source must be owned by the current user' unless source_stat.uid == Process.uid
        abort 'managed credential source permissions must be 0600' unless (source_stat.mode & 0o777) == 0o600

        credentials = YAML.safe_load(
          File.read(credentials_path),
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false,
        )
        abort 'managed credential schema version must be 1' unless credentials['version'] == 1
        credentials.dig('refs', slot)
      end
abort "#{slot} is absent or invalid" unless key.is_a?(String) && key.length.between?(16, 512)

container, status = Open3.capture2e(
  'xcrun', 'simctl', 'get_app_container', udid, bundle_id, 'data',
)
abort "cannot resolve Simulator app container: #{container.strip}" unless status.success?

temporary = File.join(container.strip, 'tmp')
staged = File.join(temporary, '.dsh-provision-key')
staged_slot = File.join(temporary, '.dsh-provision-slot')
acknowledgement = File.join(temporary, '.dsh-provision-ack')
FileUtils.mkdir_p(temporary, mode: 0o700)
abort 'a staged credential already exists; remove it only after auditing the failed import' if File.exist?(staged) || File.symlink?(staged)
abort 'a staged credential slot already exists; remove it only after auditing the failed import' if File.exist?(staged_slot) || File.symlink?(staged_slot)
FileUtils.rm_f(acknowledgement)
no_follow = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0
File.open(staged, File::WRONLY | File::CREAT | File::EXCL | no_follow, 0o600) do |file|
  file.write(key)
  file.write("\n")
  file.flush
  file.fsync
end
File.open(staged_slot, File::WRONLY | File::CREAT | File::EXCL | no_follow, 0o600) do |file|
  file.write(slot)
  file.write("\n")
  file.flush
  file.fsync
end
key.replace("\0" * key.bytesize)
File.chmod(0o600, staged)
File.chmod(0o600, staged_slot)
at_exit do
  FileUtils.rm_f(staged)
  FileUtils.rm_f(staged_slot)
end

launch, launch_status = Open3.capture2e(
  'xcrun', 'simctl', 'launch', '--terminate-running-process', udid, bundle_id,
)
abort "cannot launch Simulator app for credential import: #{launch.strip}" unless launch_status.success?

deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
until File.file?(acknowledgement) && !File.exist?(staged)
  abort 'Simulator app did not acknowledge credential import' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep 0.1
end
FileUtils.rm_f(acknowledgement)
puts "managed #{slot} credential imported into the Simulator Keychain; value not printed"
