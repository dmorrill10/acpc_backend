require_relative 'dealer'
require_relative 'match'

require_relative 'simple_logging'
using AcpcTableManager::SimpleLogging::MessageFormatting

module AcpcTableManager
  class Maintainer
    include SimpleLogging

    def initialize(logger_ = AcpcTableManager.new_log('table_manager.log'))
      @logger = logger_

      @table_queues = {}
      enqueue_waiting_matches

      log(__method__)
    end

    def enqueue_waiting_matches(game_definition_key=nil)
      if game_definition_key
        @table_queues[game_definition_key] ||= ::AcpcTableManager::TableQueue.new(game_definition_key)
        matches_to_check = @table_queues[game_definition_key].my_matches.not_running.and.not_started.to_a
        matches_to_check.each do |m|
          unless @table_queues[game_definition_key].running_matches[m.id.to_s]
            @table_queues[game_definition_key].enqueue! m.id.to_s, m.dealer_options
          end
        end
      else
        ::AcpcTableManager.exhibition_config.games.keys.each do |game_definition_key|
          enqueue_waiting_matches game_definition_key
        end
      end
    end

    def maintain!
      log __method__, msg: "Starting maintenance"

      enqueue_waiting_matches
      @table_queues.each { |key, queue| queue.check_queue! }
      clean_up_matches!

      log __method__, msg: "Finished maintenance"
    end

    def kill_match!(match_id)
      log(__method__, match_id: match_id)

      @table_queues.each do |key, queue|
        queue.kill_match!(match_id)
      end
    end

    def clean_up_matches!
      ::AcpcTableManager::Match.delete_matches_older_than! 1.day
    end

    def enqueue_match!(match_id, options)
      begin
        m = ::AcpcTableManager::Match.find match_id
      rescue Mongoid::Errors::DocumentNotFound
        return kill_match!(match_id)
      else
        @table_queues[m.game_definition_key.to_s].enqueue! match_id, options
      end
    end

    def start_proxy!(match_id)
      begin
        match = ::AcpcTableManager::Match.find match_id
      rescue Mongoid::Errors::DocumentNotFound
        return kill_match!(match_id)
      else
        @table_queues[match.game_definition_key.to_s].start_proxy match
      end
    end

    def check_match(match_id)
      log(__method__, { match_id: match_id })
      begin
        match = ::AcpcTableManager::Match.find match_id
      rescue Mongoid::Errors::DocumentNotFound
        log(
          __method__,
          {
            msg: "Match \"#{match_id}\" doesn't exist! Killing match.",
            match_id: match_id
          },
          Logger::Severity::ERROR
        )
        return kill_match!(match_id)
      end
      unless @table_queues[match.game_definition_key.to_s].running_matches[match_id]
        log(
          __method__,
          {
            msg: "Match \"#{match_id}\" in seat #{match.seat} doesn't have a proxy! Killing match.",
            match_id: match_id,
            match_name: match.name,
            last_updated_at: match.updated_at,
            running?: match.running?,
            last_slice_viewed: match.last_slice_viewed,
            last_slice_present: match.slices.length - 1
          },
          Logger::Severity::ERROR
        )
        return kill_match!(match_id)
      end
      proxy_pid = @table_queues[match.game_definition_key.to_s].running_matches[match_id][:proxy]

      log __method__, {
        match_id: match_id,
        running?: proxy_pid && AcpcDealer::process_exists?(proxy_pid)
      }

      unless proxy_pid && AcpcDealer::process_exists?(proxy_pid)
        log(
          __method__,
          {
            msg: "The proxy for match \"#{match_id}\" in seat #{match.seat} isn't running! Killing match.",
            match_id: match_id,
            match_name: match.name,
            last_updated_at: match.updated_at,
            running?: match.running?,
            last_slice_viewed: match.last_slice_viewed,
            last_slice_present: match.slices.length - 1
          },
          Logger::Severity::ERROR
        )
        kill_match!(match_id)
      end
    end
  end
end
