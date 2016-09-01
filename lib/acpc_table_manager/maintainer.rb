require 'yaml'
require_relative 'dealer'
require_relative 'match'

require_relative 'simple_logging'
using AcpcTableManager::SimpleLogging::MessageFormatting

module AcpcTableManager
  class Maintainer
    include SimpleLogging

    def self.proxy_pids(pids_file)
      if !File.exists?(pids_file)
        File.open(pids_file, 'w') do |pids_file|
          yield pids_file, {} if block_given?
        end
      else
        File.open(pids_file, 'r+') do |pids_file|
          pids = YAML.safe_load(pids_file) || {}
          pids_file.seek(0, IO::SEEK_SET)
          pids_file.truncate(0)
          yield pids_file, pids if block_given?
        end
      end
    end

    def self.kill_orphan_proxies(pids, pids_file)
      new_pids = []
      pids.each do |pid_pair|
        if AcpcDealer::process_exists?(pid_pair['proxy']) && !AcpcDealer::process_exists?(pid_pair['dealer'])
          AcpcDealer::kill_process pid_pair['proxy']
          sleep 1 # Give the process a chance to exit

          if AcpcDealer::process_exists?(pid_pair['proxy'])
            AcpcDealer::force_kill_process pid_pair['proxy']
            sleep 1 # Give the process a chance to exit

            if AcpcDealer::process_exists?(pid_pair['proxy'])
              raise(
                StandardError.new(
                  "Proxy process #{pid_pair['proxy']} couldn't be killed!"
                )
              )
            end
          end
        else
          new_pids << pid_pair
        end
      end
      new_pids
    end

    def self.update_pids(pids)
      pids, pids_file = proxy_pids proxy_pids_file do |pids_file, pids|
        pids = kill_orphan_proxies pids, pids_file

        matches_started = yield if block_given?

        matches_started.each do |info|
          if info
            pids << {'dealer' => info[:dealer][:pid], 'proxy' => info[:proxy]}
          end
        end
        pids_file.write(YAML.dump(pids)) unless pids.empty?
      end
    end

    def self.proxy_pids_file() ::AcpcTableManager.config.proxy_pids_file end

    def initialize(logger_ = AcpcTableManager.new_log('table_manager.log'))
      @logger = logger_
      @table_queues = {}

      maintain!

      log(__method__)
    end

    def enqueue_waiting_matches(game_definition_key=nil)
      queues_touched = []
      if game_definition_key
        @table_queues[game_definition_key] ||= ::AcpcTableManager::TableQueue.new(game_definition_key)
        matches_to_check = @table_queues[game_definition_key].my_matches.not_running.and.not_started.to_a
        matches_to_check.each do |m|
          unless @table_queues[game_definition_key].running_matches[m.id.to_s]
            queues_touched << @table_queues[game_definition_key].enqueue!(m.id.to_s, m.dealer_options)
          end
        end
      else
        ::AcpcTableManager.exhibition_config.games.keys.each do |game_definition_key|
          queues_touched += enqueue_waiting_matches(game_definition_key)
        end
      end
      queues_touched
    end

    def maintain!
      log __method__, msg: "Starting maintenance"

      self.class().update_pids self.class().proxy_pids_file do
        queues_touched = enqueue_waiting_matches
        matches_started = []
        queues_touched.each do |queue|
          matches_started << queue.check_queue!
        end
        matches_started
      end

      clean_up_matches!

      log __method__, msg: "Finished maintenance"
    end

    def kill_match!(match_id)
      log(__method__, match_id: match_id)

      @table_queues.each do |key, queue|
        log(__method__, {queue: key, match_id: match_id})

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

        log(
          __method__,
          {
            msg: "Match not found",
            match_id: match_id
          },
          Logger::Severity::ERROR
        )

        return kill_match!(match_id)
      else
        self.class().update_pids self.class().proxy_pids_file do
          @table_queues[m.game_definition_key.to_s].enqueue! match_id, options
          @table_queues[m.game_definition_key.to_s].check_queue!
        end
      end
    end

    def start_proxy!(match_id)
      begin
        match = ::AcpcTableManager::Match.find match_id
      rescue Mongoid::Errors::DocumentNotFound

        log(
          __method__,
          {
            msg: "Match not found",
            match_id: match_id
          },
          Logger::Severity::ERROR
        )

        return kill_match!(match_id)
      else
        self.class().update_pids self.class().proxy_pids_file do
          [@table_queues[match.game_definition_key.to_s].start_proxy(match)]
        end
      end
    end

    def check_match(match_id)
      log(__method__, {match_id: match_id})
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
