require 'acpc_poker_types'
require 'acpc_dealer'
require 'timeout'

require_relative 'dealer'
require_relative 'opponents'
require_relative 'config'
require_relative 'match'

require_relative 'simple_logging'
using AcpcTableManager::SimpleLogging::MessageFormatting

require 'contextual_exceptions'
using ContextualExceptions::ClassRefinement

module AcpcTableManager
  class TableQueue
    include SimpleLogging

    attr_reader :running_matches

    exceptions :no_port_for_dealer_available

    def initialize(game_definition_key_)
      @logger = AcpcTableManager.new_log 'queue.log'
      @matches_to_start = []
      @running_matches = {}
      @game_definition_key = game_definition_key_

      log(
        __method__,
        {
          game_definition_key: @game_definition_key,
          max_num_matches: AcpcTableManager.exhibition_config.games[@game_definition_key]['max_num_matches']
        }
      )

      # Clean up old matches
      my_matches.running_or_started.each do |m|
        m.delete
      end
    end

    def start_players!(match)
      opponents = match.bots(AcpcTableManager.config.dealer_host)

      if opponents.empty?
        kill_match! match.id.to_s
        raise StandardError.new("No opponents found to start for #{match.id.to_s}! Killed match.")
      end

      Opponents.start(
        *opponents.map { |name, info| [info[:runner], info[:host], info[:port]] }
      )
      log(__method__, msg: "Opponents started for #{match.id.to_s}")

      start_proxy match
      self
    end

    def start_proxy(match)
      command = "bundle exec acpc_proxy -t #{AcpcTableManager.config_file} -m #{match.id.to_s}"
      log(
        __method__,
        {
          msg: "Starting proxy for #{match.id.to_s}",
          command: command
        }
      )

      @running_matches[match.id.to_s][:proxy] = Timeout::timeout(3) do
        pid = Process.spawn(command)
        Process.detach(pid)
        pid
      end

      log(
        __method__,
        {
          msg: "Started proxy for #{match.id.to_s}",
          pid: @running_matches[match.id.to_s][:proxy]
        }
      )
    end

    def my_matches
      Match.where(game_definition_key: @game_definition_key.to_sym)
    end

    def change_in_number_of_running_matches?
      prevNumMatchesRunning = @running_matches.length
      yield if block_given?
      prevNumMatchesRunning != @running_matches.length
    end

    def length
      @matches_to_start.length
    end

    def ports_in_use
      @running_matches.values.inject([]) do |ports, m|
        if m[:dealer] && m[:dealer][:port_numbers]
          m[:dealer][:port_numbers].each { |n| ports << n.to_i }
        end
        ports
      end
    end

    def available_special_ports
      if AcpcTableManager.exhibition_config.special_ports_to_dealer
        AcpcTableManager.exhibition_config.special_ports_to_dealer - ports_in_use
      else
        []
      end
    end

    # @return (@see #dequeue!)
    def enqueue!(match_id, dealer_options)
      log(
        __method__,
        {
          match_id: match_id,
          running_matches: @running_matches.map { |r| r.first },
          game_definition_key: @game_definition_key,
          max_num_matches: AcpcTableManager.exhibition_config.games[@game_definition_key]['max_num_matches']
        }
      )

      if @running_matches[match_id]
        return log(
          __method__,
          msg: "Match #{match_id} already started!"
        )
      end

      @matches_to_start << {match_id: match_id, options: dealer_options}

      check_queue!
    end

    # @return (@see #dequeue!)
    def check_queue!
      log __method__

      kill_matches!

      log __method__, {num_running_matches: @running_matches.length, num_matches_to_start: @matches_to_start.length}

      if @running_matches.length < AcpcTableManager.exhibition_config.games[@game_definition_key]['max_num_matches']
        dequeue!
      else
        nil
      end
    end

    # @todo Shouldn't be necessary, so this method isn't called right now, but I've written it so I'll leave it for now
    def fix_running_matches_statuses!
      log __method__
      my_matches.running do |m|
        if !(@running_matches[m.id.to_s] && AcpcDealer::dealer_running?(@running_matches[m.id.to_s][:dealer]))
          m.is_running = false
          m.save
        end
      end
    end

    def kill_match!(match_id)
      return unless match_id

      begin
        match = Match.find match_id
      rescue Mongoid::Errors::DocumentNotFound
      else
        match.is_running = false
        match.save!
      end

      match_info = @running_matches[match_id]
      if match_info
        @running_matches.delete(match_id)
      end
      @matches_to_start.delete_if { |m| m[:match_id] == match_id }

      kill_dealer!(match_info[:dealer]) if match_info && match_info[:dealer]
      kill_proxy!(match_info[:proxy]) if match_info && match_info[:proxy]

      log __method__, match_id: match_id, msg: 'Match successfully killed'
    end

    def force_kill_match!(match_id)
      log __method__, match_id: match_id
      kill_match! match_id
      ::AcpcTableManager::Match.delete_match! match_id
      log __method__, match_id: match_id, msg: 'Match successfully deleted'
    end

    protected

    def kill_dealer!(dealer_info)
      log(
        __method__,
        pid: dealer_info[:pid],
        was_running?: true,
        dealer_running?: AcpcDealer::dealer_running?(dealer_info)
      )

      if AcpcDealer::dealer_running? dealer_info
        AcpcDealer.kill_process dealer_info[:pid]

        sleep 1 # Give the dealer a chance to exit

        log(
          __method__,
          pid: dealer_info[:pid],
          msg: 'After TERM signal',
          dealer_still_running?: AcpcDealer::dealer_running?(dealer_info)
        )

        if AcpcDealer::dealer_running?(dealer_info)
          AcpcDealer.force_kill_process dealer_info[:pid]
          sleep 1

          log(
            __method__,
            pid: dealer_info[:pid],
            msg: 'After KILL signal',
            dealer_still_running?: AcpcDealer::dealer_running?(dealer_info)
          )

          if AcpcDealer::dealer_running?(dealer_info)
            raise(
              StandardError.new(
                "Dealer process #{dealer_info[:pid]} couldn't be killed!"
              )
            )
          end
        end
      end
    end

    def kill_proxy!(proxy_pid)
      log(
        __method__,
        pid: proxy_pid,
        was_running?: true,
        proxy_running?: AcpcDealer::process_exists?(proxy_pid)
      )

      if proxy_pid && AcpcDealer::process_exists?(proxy_pid)
        AcpcDealer.kill_process proxy_pid

        sleep 1 # Give the proxy a chance to exit

        log(
          __method__,
          pid: proxy_pid,
          msg: 'After TERM signal',
          proxy_still_running?: AcpcDealer::process_exists?(proxy_pid)
        )

        if AcpcDealer::process_exists?(proxy_pid)
          AcpcDealer.force_kill_process proxy_pid
          sleep 1

          log(
            __method__,
            pid: proxy_pid,
            msg: 'After KILL signal',
            proxy_still_running?: AcpcDealer::process_exists?(proxy_pid)
          )

          if AcpcDealer::process_exists?(proxy_pid)
            raise(
              StandardError.new(
                "Proxy process #{proxy_pid} couldn't be killed!"
              )
            )
          end
        end
      end
    end

    def kill_matches!
      log __method__

      unless AcpcTableManager.config.match_lifespan_s < 0
        Match.running.and.old(AcpcTableManager.config.match_lifespan_s).each do |m|
          log(
            __method__,
            {
              old_running_match_id_being_killed: m.id.to_s
            }
          )

          kill_match! m.id.to_s
        end
      end

      running_matches_array = @running_matches.to_a
      running_matches_array.each_index do |i|
        match_id, match_info = running_matches_array[i]

        unless (
          AcpcDealer::dealer_running?(match_info[:dealer]) &&
          Match.id_exists?(match_id)
        )
          log(
            __method__,
            {
              match_id_being_killed: match_id
            }
          )

          kill_match! match_id
        end
      end
      @matches_to_start.delete_if do |m|
        !Match.id_exists?(m[:match_id])
      end
    end

    def match_queued?(match_id)
      @matches_to_start.any? { |m| m[:match_id] == match_id }
    end

    def port(available_ports_)
      port_ = available_ports_.pop
      while !AcpcDealer::port_available?(port_)
        if available_ports_.empty?
          raise NoPortForDealerAvailable.new("None of the special ports (#{available_special_ports}) are open")
        end
        port_ = available_ports_.pop
      end
      unless port_
        raise NoPortForDealerAvailable.new("None of the special ports (#{available_special_ports}) are open")
      end
      port_
    end

    # @return [Object] The match that has been started or +nil+ if none could
    # be started.
    def dequeue!
      log(
        __method__,
        num_matches_to_start: @matches_to_start.length
      )
      return nil if @matches_to_start.empty?

      match_info = nil
      match_id = nil
      match = nil
      loop do
        match_info = @matches_to_start.shift
        match_id = match_info[:match_id]
        begin
          match = Match.find match_id
        rescue Mongoid::Errors::DocumentNotFound
          return self if @matches_to_start.empty?
        else
          break
        end
      end
      return self unless match_id

      options = match_info[:options]

      log(
        __method__,
        msg: "Starting dealer for match #{match_id}",
        options: options
      )

      @running_matches[match_id] ||= {}

      special_port_requirements = match.bot_special_port_requirements

      # Add user's port
      special_port_requirements.insert(match.seat - 1, false)

      available_ports_ = available_special_ports
      ports_to_be_used = special_port_requirements.map do |r|
        if r then port(available_ports_) else 0 end
      end

      match.is_running = true
      match.save!

      num_repetitions = 0
      while @running_matches[match_id][:dealer].nil? do
        log(
          __method__,
          msg: "Added #{match_id} list of running matches",
          available_special_ports: available_ports_,
          special_port_requirements: special_port_requirements,
          :'ports_to_be_used_(zero_for_random)' => ports_to_be_used
        )
        begin
          @running_matches[match_id][:dealer] = Dealer.start(
            options,
            match,
            port_numbers: ports_to_be_used
          )
        rescue Timeout::Error => e
          log(
            __method__,
            {warning: "The dealer for match #{match_id} timed out."},
            Logger::Severity::WARN
          )
          begin
            ports_to_be_used = special_port_requirements.map do |r|
              if r then port(available_ports_) else 0 end
            end
          rescue NoPortForDealerAvailable => e
            available_ports_ = available_special_ports
            log(
              __method__,
              {warning: "#{ports_to_be_used} ports unavailable, retrying with all special ports, #{available_ports_}."},
              Logger::Severity::WARN
            )
          end
          if num_repetitions < 1
            sleep 1
            log(
              __method__,
              {warning: "Retrying with all special ports, #{available_ports_}."},
              Logger::Severity::WARN
            )
            num_repetitions += 1
          else
            log(
              __method__,
              {warning: "Unable to start match after retry, force killing match."},
              Logger::Severity::ERROR
            )
            force_kill_match! match_id
            raise e
          end
        end
      end

      begin
        match = Match.find match_id
      rescue Mongoid::Errors::DocumentNotFound => e
        kill_match! match_id
        raise e
      end

      log(
        __method__,
        msg: "Dealer started for #{match_id} with pid #{@running_matches[match_id][:dealer][:pid]}",
        ports: match.port_numbers
      )

      start_players! match
    end
  end
end
