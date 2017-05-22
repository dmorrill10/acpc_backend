require 'timeout'
require 'process_runner'
require_relative 'config'
require_relative 'simple_logging'
require 'fileutils'
require 'shellwords'

module AcpcTableManager
module Opponents
  extend SimpleLogging

  @logger = nil

  # @return [Array<Integer>] PIDs of the opponents started
  def self.start(match)
    @logger ||= ::AcpcTableManager.new_log 'opponents.log'

    opponents = match.bots(AcpcTableManager.config.dealer_host)
    log __method__, num_opponents: opponents.length

    if opponents.empty?
      raise StandardError.new("No opponents found to start for \"#{match.name}\" (#{match.id.to_s})!")
    end

    opponents_log_dir = File.join(AcpcTableManager.config.log_directory, 'opponents')
    FileUtils.mkdir(opponents_log_dir) unless File.directory?(opponents_log_dir)

    bot_start_commands = opponents.map do |name, info|
      {
        args: [info[:runner], info[:host], info[:port], Shellwords.escape(match.random_seed.to_s)],
        log: File.join(opponents_log_dir, "#{match.name}.#{match.id}.#{name}.log")
      }
    end

    bot_start_commands.map do |bot_start_command|
      log(
        __method__,
        {
          bot_start_command_parameters: bot_start_command[:args],
          command_to_be_run: bot_start_command[:args].join(' ')
        }
      )
      pid = Timeout::timeout(3) do
        ProcessRunner.go(
          bot_start_command[:args].map { |e| e.to_s },
          {
            [:err, :out] => [bot_start_command[:log], File::CREAT|File::WRONLY]
          }
        )
      end
      log(
        __method__,
        {
          bot_started?: true,
          pid: pid
        }
      )
      pid
    end
  end
end
end
