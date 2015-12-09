require_relative 'dealer'
require_relative 'match'

require_relative 'simple_logging'
using SimpleLogging::MessageFormatting

module AcpcTableManager
  class Null
    def method_missing(*args, &block) self end
  end
  module HandleException
    protected

    # @param [String] match_id The ID of the match in which the exception occurred.
    # @param [Exception] e The exception to log.
    def handle_exception(match_id, e)
      log(
        __method__,
        {
          match_id: match_id,
          message: e.message,
          backtrace: e.backtrace
        },
        Logger::Severity::ERROR
      )
    end
  end

  class Maintainer
    include ParamRetrieval
    include SimpleLogging
    include HandleException

    def initialize(logger_)
      @logger = logger_

      @table_queues = {}
      enqueue_waiting_matches

      log(__method__)
    end

    def enqueue_waiting_matches(game_definition_key=nil)
      if game_definition_key
        @table_queues[game_definition_key] ||= ::AcpcTableManager::TableQueue.new(game_definition_key)
        @table_queues[game_definition_key].my_matches.not_running.and.not_started.each do |m|
          @table_queues[game_definition_key].enqueue! m.id.to_s, m.dealer_options
        end
      else
        ::AcpcTableManager.exhibition_config.games.keys.each do |game_definition_key|
          enqueue_waiting_matches game_definition_key
        end
      end
    end

    def maintain!
      log __method__, msg: "Starting maintenance"

      begin
        enqueue_waiting_matches
        @table_queues.each { |key, queue| queue.check_queue! }
        clean_up_matches!
      rescue => e
        handle_exception nil, e
        Rusen.notify e # Send an email notification
      end
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

    def play_action!(match_id, action)
      log __method__, {
        match_id: match_id,
        action: action
      }
      begin
        match = ::AcpcTableManager::Match.find match_id
      rescue Mongoid::Errors::DocumentNotFound
        log(
          __method__,
          {
            msg: "Request to play in match #{match_id} when no such proxy exists! Killed match.",
            match_id: match_id,
            action: action
          },
          Logger::Severity::ERROR
        )
        return kill_match!(match_id)
      end
      unless @table_queues[match.game_definition_key.to_s].running_matches[match_id]
        log(
          __method__,
          {
            msg: "Request to play in match #{match_id} in seat #{match.seat} when no such proxy exists! Killed match.",
            match_id: match_id,
            match_name: match.name,
            last_updated_at: match.updated_at,
            running?: match.running?,
            last_slice_viewed: match.last_slice_viewed,
            last_slice_present: match.slices.length - 1,
            action: action
          },
          Logger::Severity::ERROR
        )
        return kill_match!(match_id)
      end
      log __method__, {
        match_id: match_id,
        action: action,
        running?: !@table_queues[match.game_definition_key.to_s].running_matches[match_id].nil?
      }
      proxy = @table_queues[match.game_definition_key.to_s].running_matches[match_id][:proxy]
      if proxy
        proxy.play! action
      else
        log(
          __method__,
          {
            msg: "Request to play in match #{match_id} in seat #{match.seat} when no such proxy exists! Killed match.",
            match_id: match_id,
            match_name: match.name,
            last_updated_at: match.updated_at,
            running?: match.running?,
            last_slice_viewed: match.last_slice_viewed,
            last_slice_present: match.slices.length - 1,
            action: action
          },
          Logger::Severity::ERROR
        )
      end
      kill_match!(match_id) if proxy.nil? || proxy.match_ended?
    end
  end

  class TableManager
    include ParamRetrieval
    include SimpleLogging
    include HandleException

    attr_accessor :maintainer

    def initialize
      @logger = AcpcTableManager.new_log 'table_manager.log'
      log __method__, "Starting new #{self.class()}"
      @maintainer = Maintainer.new @logger
    end

    def maintain!
      begin
        @maintainer.maintain!
      rescue => e
        log(
          __method__,
          {
            message: e.message,
            backtrace: e.backtrace
          },
          Logger::Severity::ERROR
        )
        Rusen.notify e # Send an email notification
      end
    end

    def perform!(request, params=nil)
      match_id = nil
      begin
        log(__method__, {request: request, params: params})

        case request
        # when START_MATCH_REQUEST_CODE
          # @todo Put bots in erb yaml and have them reread here
        when ::AcpcTableManager.config.delete_irrelevant_matches_request_code
          return @maintainer.clean_up_matches!
        end

        match_id = retrieve_match_id_or_raise_exception params

        log(__method__, {request: request, match_id: match_id})

        do_request!(request, match_id, params)
      rescue => e
        handle_exception match_id, e
        Rusen.notify e # Send an email notification
      end
    end

    protected

    def do_request!(request, match_id, params)
      case request
      when ::AcpcTableManager.config.start_match_request_code
        log(__method__, {request: request, match_id: match_id, msg: 'Enqueueing match'})

        @maintainer.enqueue_match!(
          match_id,
          retrieve_parameter_or_raise_exception(params, ::AcpcTableManager.config.options_key)
        )
      when ::AcpcTableManager.config.start_proxy_request_code
        log(
          __method__,
          request: request,
          match_id: match_id,
          msg: 'Starting proxy'
        )

        @maintainer.start_proxy! match_id
      when ::AcpcTableManager.config.play_action_request_code
        log(
          __method__,
          request: request,
          match_id: match_id,
          msg: 'Taking action'
        )

        @maintainer.play_action! match_id, retrieve_parameter_or_raise_exception(params, ::AcpcTableManager.config.action_key)
      when ::AcpcTableManager.config.kill_match
        log(
          __method__,
          request: request,
          match_id: match_id,
          msg: "Killing match #{match_id}"
        )
        @maintainer.kill_match! match_id
      else
        raise StandardError.new("Unrecognized request: #{request}")
      end
    end
  end
end
