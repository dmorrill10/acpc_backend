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
      @game_definition_key = game_definition_key_

      log(
        __method__,
        game_definition_key: @game_definition_key,
        max_num_matches: AcpcTableManager.exhibition_config.games[@game_definition_key]['max_num_matches']
      )
    end

    def start_players!(match)
      Opponents.start(match)
      log(__method__, msg: "Opponents started for #{match.id}")

      start_proxy! match
    end

    def start_proxy!(match)
      command = "#{File.expand_path('../../../exe/acpc_proxy', __FILE__)} -t #{AcpcTableManager.config_file} -m #{match.id}"
      log(
        __method__,
        msg: "Starting proxy for #{match.id}",
        command: command
      )

      match.proxy_pid = Timeout.timeout(3) do
        pid = Process.spawn(command)
        Process.detach(pid)
        pid
      end
      match.save!

      log(
        __method__,
        msg: "Started proxy for \"#{match.name}\" (#{match.id})",
        pid: match.proxy_pid
      )
      self
    end

    def matches_to_start
      my_matches.queue
    end

    def my_matches
      Match.where(game_definition_key: @game_definition_key.to_sym)
    end

    def change_in_number_of_running_matches?
      prevNumMatchesRunning = Match.running(my_matches).length
      yield if block_given?
      prevNumMatchesRunning != Match.running(my_matches).length
    end

    def length
      matches_to_start.length
    end

    def available_special_ports
      if AcpcTableManager.exhibition_config.special_ports_to_dealer
        AcpcTableManager.exhibition_config.special_ports_to_dealer - Match.ports_in_use
      else
        []
      end
    end

    def check!
      return if length < 1

      my_matches_to_start = matches_to_start.to_a

      max_running_matches = AcpcTableManager.exhibition_config.games[@game_definition_key]['max_num_matches']
      check_num_running_matches = max_running_matches > 0

      num_running_matches = 0
      if check_num_running_matches
        num_running_matches = Match.running(my_matches).length
        log(
          __method__,
          num_running_matches: num_running_matches,
          num_matches_to_start: my_matches_to_start.length
        )
      end

      matches_started = []
      while
        !my_matches_to_start.empty? &&
        (
          !check_num_running_matches ||
          num_running_matches < max_running_matches
        )

        matches_started << dequeue(my_matches_to_start.pop)
        num_running_matches += 1
      end

      log(
        __method__,
        matches_started: matches_started,
        num_running_matches: num_running_matches,
        num_matches_to_start: matches_to_start.length
      )

      matches_started
    end

    protected

    def port(available_ports)
      port_ = available_ports.pop
      until AcpcDealer.port_available?(port_)
        if available_ports.empty?
          raise NoPortForDealerAvailable, "None of the special ports (#{available_special_ports}) are open"
        end
        port_ = available_ports.pop
      end
      unless port_
        raise NoPortForDealerAvailable, "None of the special ports (#{available_special_ports}) are open"
      end
      port_
    end

    def ports_to_use(special_port_requirements, available_ports = nil)
      ports = special_port_requirements.map do |r|
        if r
          # Slow. Only check available special ports if necessary
          available_ports ||= available_special_ports
          port(available_ports)
        else
          0
        end
      end
      [ports, available_ports]
    end

    # @return [Object] The match that has been started or +nil+ if none could
    #   be started.
    def dequeue(match)
      log(
        __method__,
        msg: "Starting dealer for match \"#{match.name}\" (#{match.id})",
        options: match.dealer_options
      )

      special_port_requirements = match.bot_special_port_requirements

      # Add user's port
      special_port_requirements.insert(match.seat - 1, false)

      ports_to_be_used, available_ports = ports_to_use(special_port_requirements)

      num_repetitions = 0
      dealer_info = nil

      while dealer_info.nil?
        log(
          __method__,
          msg: "Added #{match.id} list of running matches",
          available_special_ports: available_ports,
          special_port_requirements: special_port_requirements,
          :'ports_to_be_used_(zero_for_random)' => ports_to_be_used
        )
        begin
          dealer_info = Dealer.start(match, port_numbers: ports_to_be_used)
        rescue Timeout::Error => e
          log(
            __method__,
            { warning: "The dealer for match \"#{match.name}\" (#{match.id}) timed out." },
            Logger::Severity::WARN
          )
          begin
            ports_to_be_used, available_ports = ports_to_use(special_port_requirements, available_ports)
          rescue NoPortForDealerAvailable => e
            available_ports = available_special_ports
            log(
              __method__,
              { warning: "#{ports_to_be_used} ports unavailable, retrying with all special ports, #{available_ports}." },
              Logger::Severity::WARN
            )
          end
          if num_repetitions < 1
            sleep 1
            log(
              __method__,
              { warning: "Retrying with all special ports, #{available_ports}." },
              Logger::Severity::WARN
            )
            num_repetitions += 1
          else
            log(
              __method__,
              { warning: 'Unable to start match after retry, giving up.' },
              Logger::Severity::ERROR
            )
            match.unable_to_start_dealer = true
            match.save!
            raise e
          end
        end
      end

      log(
        __method__,
        msg: "Dealer started for \"#{match.name}\" (#{match.id}) with pid #{match.dealer_pid}",
        ports: match.port_numbers
      )

      match.ready_to_start = false
      match.save!

      start_players! match

      match.id
    end
  end
end
