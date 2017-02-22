require 'optparse'
require 'acpc_table_manager/simple_logging'
require 'acpc_table_manager/proxy_utils'

module AcpcTableManager
  class AcpcProxy
    include AcpcTableManager::SimpleLogging
    include AcpcTableManager::ProxyUtils

    attr_reader :game, :id, :game_info, :state_index, :last_message_received

    def initialize(id, game)
      @game = game
      @id = id
      @game_info = AcpcTableManager.exhibition_config.games[game]
      unless @game_info
        raise OptionParser::ArgumentError.new(
          "\"#{game}\" is not a recognized game. Registered games: #{AcpcTableManager.exhibition_config.games.keys}."
        )
      end

      @logger = AcpcTableManager.new_log(
        "#{id}.log",
        File.join(AcpcTableManager.config.log_directory, 'proxies')
      )

      @communicator = AcpcTableManager::ProxyCommunicator.new(id)
      @communicator.del_saved # Clear stale messages to avoid unpredictable behaviour
      @state_index = 0
      @last_message_received = Time.now
    end

    def must_send_ready() AcpcTableManager.config.must_send_ready end

    def num_hands_per_match() @game_info['num_hands_per_match'] end

    def play(action)
      action = PokerAction.new(action) unless action.is_a?(PokerAction)

      @proxy.play!(action) do |patt|
        log 'play! block', match_state: patt.match_state.to_s
        @communicator.publish(
          AcpcTableManager::ProxyUtils.players_at_the_table_to_json(
            patt,
            num_hands_per_match,
            @state_index
          )
        )
        @state_index += 1
      end
    end

    def act(action)
      if action == 'next-hand'
        @proxy.next_hand! do |patt|
          log 'next_hand! block', match_state: patt.match_state.to_s
          @communicator.publish(
            AcpcTableManager::ProxyUtils.players_at_the_table_to_json(
              patt,
              num_hands_per_match,
              @state_index
            )
          )
          @state_index += 1
        end

        log(
          'after next_hand!',
          users_turn_to_act?: @proxy.users_turn_to_act?,
          match_over?: match_over?
        )
      else
        log 'before play', users_turn_to_act?: @proxy.users_turn_to_act?,
                           action: action

        if @proxy.users_turn_to_act?
          play action

          log(
            'after play',
            users_turn_to_act?: @proxy.users_turn_to_act?,
            match_over?: match_over?
          )
        else
          log 'skipped play'
        end
      end
    end

    def match_over?
      @proxy.match_ended?(num_hands_per_match) ||
      !@proxy.connected?
    end

    def message_loop
      @communicator.subscribe_with_timeout do |data|
        log __method__, data: data

        if data['resend']
          log __method__, msg: 'Resending match state'
          @communicator.publish(
            AcpcTableManager::ProxyUtils.players_at_the_table_to_json(
              @proxy,
              num_hands_per_match,
              @state_index
            )
          )
          @state_index += 1
        elsif data['kill']
          log __method__, msg: 'Exiting'
          exit_and_del_saved
        else
          act data['action']
        end
        exit_and_del_saved if match_over?
        @last_message_received = Time.now
      end
    end

    def action_timeout_reached
      AcpcTableManager.config.proxy_timeout_s && (
        Time.now > (
          @last_message_received + AcpcTableManager.config.proxy_timeout_s
        )
      )
    end

    def start(seat, port)
      begin
        log(
          __method__,
          id: @id,
          game: @game,
          seat: seat,
          port: port,
          version: AcpcTableManager::VERSION,
          send_channel: @communicator.send_channel,
          receive_channel: @communicator.receive_channel,
          must_send_ready: must_send_ready
        )

        @proxy = start_proxy(
          @game_info,
          seat,
          port,
          must_send_ready
        ) do |patt|
          log 'start_proxy_block', match_state: patt.match_state.to_s
          @communicator.publish(
            AcpcTableManager::ProxyUtils.players_at_the_table_to_json(
              patt,
              num_hands_per_match,
              @state_index
            )
          )
          @state_index += 1
        end

        log 'starting event loop'

        loop do
          begin
            message_loop
          rescue AcpcTableManager::SubscribeTimeout
            match_is_over = match_over?

            log(
              'subscription timeout reached',
              {
                match_over?: match_is_over,
                users_turn_to_act?: @proxy.users_turn_to_act?,
                action_timeout_reached: action_timeout_reached,
                on_proxy_timeout: AcpcTableManager.config.on_proxy_timeout
              }
            )
            if match_is_over
              exit_and_del_saved
            elsif !@proxy.users_turn_to_act?
              @last_message_received = Time.now
            elsif action_timeout_reached
              if AcpcTableManager.config.on_proxy_timeout == 'fold'
                play_check_fold! @proxy
              else
                exit_and_del_saved
              end
            end
          end
        end
      rescue => e
        log(
          __method__,
          {
            id: @id,
            message: e.message,
            backtrace: e.backtrace
          },
          Logger::Severity::ERROR
        )
        AcpcTableManager.notify e # Send an email notification
      end
      exit_and_del_saved
    end
  end
end
