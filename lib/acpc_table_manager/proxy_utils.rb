require 'acpc_poker_types'
include AcpcPokerTypes
require 'acpc_poker_player_proxy'
include AcpcPokerPlayerProxy
require 'acpc_dealer'
include AcpcDealer

module AcpcTableManager
  module ProxyUtils
    class Sender
      def initialize(id)
        @channel = "#{id}-from-proxy"
        @redis = AcpcTableManager.new_redis_connection
      end
      def publish(data)
        @redis.publish @sending_channel, data
      end
    end

    class Receiver
      def initialize(id)
        @channel = "#{id}-to-proxy"
        @redis = AcpcTableManager.new_redis_connection
      end
      def subscribe_with_timeout
        begin
          @redis.subscribe_with_timeout(
            AcpcTableManager.config.maintenance_interval_s,
            @channel
          ) { |on| yield on }
        rescue Redis::TimeoutError
        end
      end
    end

    class ProxyCommunicator
      def initialize(id)
        @sender = Sender.new(id)
        @receiver = Receiver.new(id)
      end
      def publish(data) @sender.publish(data) end
      def subscribe_with_timeout
        @receiver.subscribe_with_timeout { |on| yield on }
      end
    end

    def start_proxy(
      game_info,
      seat,
      port,
      must_send_ready = false
    )
      game_definition = GameDefinition.parse_file(game_info['file'])

      PlayerProxy.new(
        ConnectionInformation.new(
          port,
          AcpcTableManager.config.dealer_host
        ),
        game_definition,
        seat,
        must_send_ready
      ) do |patt|
        if patt.match_state
          @communicator.publish to_json(patt)
        else
          log __method__, before_first_match_state: true
        end
      end
    end

    def play_check_fold!(proxy)
      log __method__
      if proxy.users_turn_to_act?
        action = if (
          proxy.legal_actions.any? do |a|
            a == AcpcPokerTypes::PokerAction::FOLD
          end
        )
          AcpcPokerTypes::PokerAction::FOLD
        else
          AcpcPokerTypes::PokerAction::CALL
        end
        proxy.play!(action) do |patt|
          @communicator.publish to_json(patt)
        end
      end
    end

    def self.chip_contributions_in_previous_rounds(player, round)
      if round > 0
        player['chip_contributions'][0..round-1].inject(:+)
      else
        0
      end
    end

    def self.opponents(players, users_seat)
      opp = players.dup
      opp.delete_at(users_seat)
      opp
    end

    # Over round
    def self.pot_fraction_wager_to_over_round(proxy, fraction=1)
      return 0 if proxy.hand_ended?

      [
        [
          (
            (fraction * pot_after_call(proxy.match_state, proxy.game_def)) +
            chip_contribution_after_calling(proxy.match_state, proxy.game_def)
          ),
          minimum_wager_to
        ].max,
        all_in
      ].min.floor
    end

    def self.proxy_to_json(proxy)
      return {}.to_json
      data = {
        hand_has_ended: proxy.hand_ended?,
        match_has_ended: proxy.match_ended?,
        seat_with_dealer_button: proxy.dealer_player.seat.to_i,
        seat_next_to_act: if proxy.next_player_to_act
          proxy.next_player_to_act.seat.to_i
        end,
        betting_sequence: betting_sequence(proxy.match_state, proxy.game_def),
        pot_at_start_of_round: pot_at_start_of_round(proxy.match_state, proxy.game_def).to_i,
        minimum_wager_to: minimum_wager_to(proxy.match_state, proxy.game_def).to_i,
        chip_contribution_after_calling: chip_contribution_after_calling(proxy.match_state, proxy.game_def).to_i,
        pot_after_call: pot_after_call(proxy.match_state, proxy.game_def).to_i,
        all_in: all_in(proxy.match_state, proxy.game_def).to_i,
        is_users_turn_to_act: proxy.users_turn_to_act?,
        legal_actions: proxy.legal_actions.map { |action| action.to_s },
        amount_to_call: amount_to_call(proxy.match_state, proxy.game_def).to_i,
        messages: []
      }

      ms = proxy.match_state

      log(
        __method__,
        first_state_of_first_round?: ms.first_state_of_first_round?
      )

      if ms.first_state_of_first_round?
        new_slice.messages << hand_dealt_description(
          @match.player_names.map { |n| Hescape.escape_html(n) },
          ms.hand_number + 1,
          proxy.game_def,
          @match.number_of_hands
        )
      end

      last_action = ms.betting_sequence(
        proxy.game_def
      ).flatten.last

      log(
        __method__,
        last_action: last_action
      )

      if last_action
        last_actor = @match.player_names[
          @match.slices[-2].seat_next_to_act
        ]

        log(
          __method__,
          last_actor: last_actor
        )

        case last_action.to_acpc_character
        when PokerAction::CHECK
          new_slice.messages << check_description(
            last_actor
          )
        when PokerAction::CALL
          new_slice.messages << call_description(
            last_actor,
            last_action
          )
        when PokerAction::BET
          new_slice.messages << bet_description(
            last_actor,
            last_action
          )
        when PokerAction::RAISE
          new_slice.messages << if @match.no_limit?
                                  no_limit_raise_description(
                                    last_actor,
                                    last_action,
                                    @match.slices[-2].amount_to_call
                                  )
                                else
                                  limit_raise_description(
                                    last_actor,
                                    last_action,
                                    ms.players(proxy.game_def).num_wagers(ms.round) - 1,
                                    proxy.game_def.max_number_of_wagers[ms.round]
                                  )
          end
        when PokerAction::FOLD
          new_slice.messages << fold_description(
            last_actor
          )
        end
      end

      log(
        __method__,
        hand_ended?: proxy.hand_ended?
      )

      if ms.first_state_of_round? && ms.round > 0
        s = ms.community_cards[ms.round - 1].length > 1 ? 'are' : 'is'
        new_slice.messages <<
          "#{(ms.community_cards[ms.round - 1].map { |c| c.rank.to_s + c.suit.to_html }).join('')} #{s} revealed."

      end

      if proxy.hand_ended?
        log(
          __method__,
          reached_showdown?: ms.reached_showdown?
        )

        if ms.reached_showdown?
          proxy.players.each_with_index do |player, i|
            hd = PileOfCards.new(
              player.hand +
              ms.community_cards.flatten
            ).to_poker_hand_description
            new_slice.messages << "#{Hescape.escape_html(@match.player_names[i])} shows #{hd}"
          end
        end
        winning_players = new_slice.players.select do |player|
          player['winnings'] > 0
        end
        if winning_players.length > 1
          new_slice.messages << split_pot_description(
            winning_players.map { |player| Hescape.escape_html(player['name']) },
            ms.pot(proxy.game_def)
          )
        else
          winnings = winning_players.first['winnings']
          winnings = winnings.to_i if winnings.to_i == winnings
          chip_balance = winning_players.first['chip_balance']
          chip_balance = chip_balance.to_i if chip_balance.to_i == chip_balance

          new_slice.messages << hand_win_description(
            Hescape.escape_html(winning_players.first['name']),
            winnings,
            chip_balance - winnings
          )
        end
      end
    end

    def self.betting_sequence(match_state, game_def)
      sequence = ''
      match_state.betting_sequence(game_def).each_with_index do |actions_per_round, round|
        actions_per_round.each_with_index do |action, action_index|
          adjusted_action = adjust_action_amount(
            action,
            round,
            match_state,
            game_def
          )

          sequence << if (
            match_state.player_acting_sequence(game_def)[round][action_index].to_i ==
            match_state.position_relative_to_dealer
          )
            adjusted_action.capitalize
          else
            adjusted_action
          end
        end
        sequence << '/' unless round == match_state.betting_sequence(game_def).length - 1
      end
      sequence
    end

    def self.pot_at_start_of_round(match_state, game_def)
      return 0 if match_state.round == 0

      match_state.players(game_def).inject(0) do |sum, pl|
        sum += pl.contributions[0..match_state.round - 1].inject(:+)
      end
    end

    # @return [Array<Hash>] Player information ordered by seat.
    # Each player hash should contain
    # values for the following keys:
    # 'name',
    # 'seat'
    # 'chip_stack'
    # 'chip_contributions'
    # 'chip_balance'
    # 'hole_cards'
    # 'winnings'
    def self.players(patt, player_names)
      player_names_queue = player_names.dup
      patt.players.map do |player|
        hole_cards = if !(player.hand.empty? || player.folded?)
          player.hand.to_acpc
        elsif player.folded?
          ''
        else
          '_' * patt.game_def.number_of_hole_cards
        end

        {
          'name' => player_names_queue.shift,
          'seat' => player.seat,
          'chip_stack' => player.stack.to_i,
          'chip_contributions' => player.contributions.map { |contrib| contrib.to_i },
          'chip_balance' => player.balance,
          'hole_cards' => hole_cards,
          'winnings' => player.winnings.to_f
        }
      end
    end

    # Over round
    def self.minimum_wager_to(state, game_def)
      return 0 unless state.next_to_act(game_def)

      (
        state.min_wager_by(game_def) +
        chip_contribution_after_calling(state, game_def)
      ).ceil
    end

    # Over round
    def self.chip_contribution_after_calling(state, game_def)
      return 0 unless state.next_to_act(game_def)

      (
        (
          state.players(game_def)[
            state.next_to_act(game_def)
          ].contributions[state.round] || 0
        ) + amount_to_call(state, game_def)
      )
    end

    # Over round
    def self.pot_after_call(state, game_def)
      return state.pot(game_def) if state.hand_ended?(game_def)

      state.pot(game_def) + state.players(game_def).amount_to_call(state.next_to_act(game_def))
    end

    # Over round
    def self.all_in(state, game_def)
      return 0 if state.hand_ended?(game_def)

      (
        state.players(game_def)[state.next_to_act(game_def)].stack +
        (
          state.players(game_def)[state.next_to_act(game_def)]
            .contributions[state.round] || 0
        )
      ).floor
    end

    def self.amount_to_call(state, game_def)
      return 0 if state.next_to_act(game_def).nil?

      state.players(game_def).amount_to_call(state.next_to_act(game_def))
    end

    private

    def self.adjust_action_amount(action, round, match_state, game_def)
      amount_to_over_hand = action.modifier
      if amount_to_over_hand.nil? || amount_to_over_hand.strip.empty?
        action
      else
        amount_to_over_round = (
          amount_to_over_hand.to_i - match_state.players(game_def)[
            match_state.position_relative_to_dealer
          ].contributions_before(round).to_i
        )
        "#{action[0]}#{amount_to_over_round}"
      end
    end
  end
end
