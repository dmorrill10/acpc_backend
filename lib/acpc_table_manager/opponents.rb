require 'timeout'
require 'process_runner'
require_relative 'config'
require_relative 'simple_logging'

module AcpcTableManager
module Opponents
  extend SimpleLogging

  @logger = nil

  # @return [Array<Integer>] PIDs of the opponents started
  def self.start(*bot_start_commands)
    @logger ||= ::AcpcTableManager.new_log 'opponents.log'
    log __method__, num_opponents: bot_start_commands.length

    bot_start_commands.map do |bot_start_command|
      log(
        __method__,
        {
          bot_start_command_parameters: bot_start_command,
          command_to_be_run: bot_start_command.join(' ')
        }
      )
      pid = Timeout::timeout(3) do
        ProcessRunner.go(bot_start_command)
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
