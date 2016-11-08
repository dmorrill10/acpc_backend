require 'yaml'
require_relative 'dealer'
require_relative 'match'
require_relative 'table_queue'

require_relative 'simple_logging'
using AcpcTableManager::SimpleLogging::MessageFormatting

module AcpcTableManager
  class Maintainer
    include SimpleLogging

    def initialize(logger_ = AcpcTableManager.new_log('table_manager.log'))
      @logger = logger_
      log(__method__)

      @table_queues = {}
      ::AcpcTableManager.exhibition_config.games.keys.each do |game_definition_key|
        @table_queues[game_definition_key] = ::AcpcTableManager::TableQueue.new(game_definition_key)
      end
      maintain!
    end

    def maintain!
      log __method__, msg: "Starting maintenance"

      @table_queues.each do |key, queue|
        log(__method__, {queue: key})
        queue.check!
      end

      log __method__, msg: "Finished maintenance"
    end
  end
end
