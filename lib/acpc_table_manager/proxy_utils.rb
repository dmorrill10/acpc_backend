require 'json'
require 'acpc_poker_types'
include AcpcPokerTypes
require 'acpc_poker_player_proxy'
include AcpcPokerPlayerProxy
require 'acpc_dealer'
include AcpcDealer

module AcpcTableManager
  module ProxyUtils
    def exit_and_del_saved
      @communicator.del_saved
      exit
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
          log __method__, msg: 'Sending match state'
          @communicator.publish(
            ProxyUtils.players_at_the_table_to_json(
              patt,
              game_info['num_hands_per_match'],
              @state_index
            )
          )
          @state_index += 1
        else
          log __method__, msg: 'Before first match state'
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
          log __method__, msg: 'Sending match state'
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
      opp = players.dup.rotate(users_seat)
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

    def self.players_at_the_table_to_json(
      patt,
      max_num_hands_per_match,
      state_index = 0
    )
      players_ = players(patt)
      {
        status: {
          hand_has_ended: patt.hand_ended?,
          match_has_ended: (
            if patt.match_state.stack_sizes
              patt.match_ended?
            else
              patt.match_ended?(max_num_hands_per_match)
            end
          ),
          hand_index: patt.match_state.hand_number,
          state_index: state_index
        },
        legal_actions: patt.legal_actions.map do |action|
          {type: action.to_s, cost: action.cost}
        end,
        table: {
          board_cards: (
            patt.match_state.community_cards.flatten.map do |c|
              {rank: c.rank.to_s, suit: c.suit.to_s}
            end
          ),
          pot_chips: pot_at_start_of_round(patt.match_state, patt.game_def).to_i,
          user: players_[patt.seat],
          opponents: opponents(players_, patt.seat)
        }
      }.to_json
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
    # 'seat'
    # 'chip-stack-amount'
    # 'contributions'
    # 'chip-balance-amount'
    # 'hole-cards'
    # 'winnings'
    # 'dealer'
    # 'acting'
    def self.players(patt)
      patt.players.map do |player|
        hole_cards = if player.folded?
          []
        elsif player.hand.empty?
          [{}] * patt.game_def.number_of_hole_cards
        else
          player.hand.map do |c|
            {rank: c.rank.to_acpc, suit: c.suit.to_acpc}
          end
        end

        {
          seat: player.seat.to_i,
          chipStackAmount: player.stack.to_i,
          contribution: (
            if player.contributions.length <= patt.match_state.round
              0
            else
              player.contributions.last.to_i
            end
          ),
          chipBalanceAmount: player.balance,
          holeCards: hole_cards,
          winnings: player.winnings.to_f,
          dealer: player.seat == patt.dealer_player.seat.to_i,
          acting: (
            patt.next_player_to_act && (
              player.seat == patt.next_player_to_act.seat
            )
          )
        }
      end
    end

    # Over round
    def self.minimum_wager_to(state, game_def)
      return 0 unless state.next_to_act(game_def)

      min_wager = [
        (
          state.min_wager_by(game_def) +
          chip_contribution_after_calling(state, game_def)
        ).ceil,
        state.players(game_def)[state.next_to_act(game_def)].stack
      ].min
      if chip_contribution_after_calling(state, game_def) < state.players(game_def)[state.next_to_act(game_def)].stack
        min_wager
      else
        nil
      end
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
