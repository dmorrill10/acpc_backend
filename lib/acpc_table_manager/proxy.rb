require_relative 'config'
require_relative 'match'
require_relative 'match_slice'

require 'hescape'
require 'acpc_poker_player_proxy'
require 'acpc_poker_types'

require_relative 'simple_logging'
using AcpcTableManager::SimpleLogging::MessageFormatting

require 'contextual_exceptions'
using ContextualExceptions::ClassRefinement

module AcpcTableManager

class Proxy
  include SimpleLogging
  include AcpcPokerTypes

  exceptions :unable_to_create_match_slice

  def self.start(id, game_info, seat, port, must_send_ready = false)
    game_definition = GameDefinition.parse_file(game_info['file'])

    proxy = new(
      match.sanitized_name,
      AcpcDealer::ConnectionInformation.new(
        port,
        ::AcpcTableManager.config.dealer_host
      ),
      match.seat - 1,
      game_definition,
      match.player_names.join(' '),
      match.number_of_hands,
      must_send_ready
    ) do |players_at_the_table|
      yield players_at_the_table if block_given?
    end
  end

  # @todo Reduce the # of params
  #
  # @param [String] match_id The ID of the match in which this player is participating.
  # @param [String] match_name The name of the match in which this player is participating.
  # @param [DealerInformation] dealer_information Information about the dealer to which this bot should connect.
  # @param [GameDefinition, #to_s] game_definition A game definition; either a +GameDefinition+ or the name of the file containing a game definition.
  # @param [String] player_names The names of the players in this match.
  # @param [Integer] number_of_hands The number of hands in this match.
  def initialize(
    match_id,
    match_name,
    dealer_information,
    users_seat,
    game_definition,
    player_names='user p2',
    number_of_hands=1,
    must_send_ready=false
  )
    @logger = AcpcTableManager.new_log File.join('proxies', "#{match_name}.#{match_id}.#{users_seat}.log")

    log __method__, {
      dealer_information: dealer_information,
      users_seat: users_seat,
      game_definition: game_definition,
      player_names: player_names,
      number_of_hands: number_of_hands
    }

    @match_id = match_id
    @player_proxy = AcpcPokerPlayerProxy::PlayerProxy.new(
      dealer_information,
      game_definition,
      users_seat,
      must_send_ready
    ) do |players_at_the_table|

      if players_at_the_table.match_state
        update_database! players_at_the_table

        yield players_at_the_table if block_given?
      else
        log __method__, {before_first_match_state: true}
      end
    end
  end

  def next_hand!
    log __method__

    if @player_proxy.hand_ended?
      @player_proxy.next_hand! do |players_at_the_table|
        update_database! players_at_the_table

        yield players_at_the_table if block_given?
      end
     end

    log(
      __method__,
      {
        users_turn_to_act?: @player_proxy.users_turn_to_act?,
        match_ended?: @player_proxy.match_ended?
      }
    )

    self
  end

  # Player action interface
  # @see PlayerProxy#play!
  def play!(action, fast_forward = false)
    log __method__, users_turn_to_act?: @player_proxy.users_turn_to_act?, action: action

    if @player_proxy.users_turn_to_act?
      action = PokerAction.new(action) unless action.is_a?(PokerAction)

      @player_proxy.play! action do |players_at_the_table|
        update_database! players_at_the_table, fast_forward

        yield players_at_the_table if block_given?
      end

      log(
        __method__,
        {
          users_turn_to_act?: @player_proxy.users_turn_to_act?,
          match_ended?: @player_proxy.match_ended?
        }
      )
    end

    self
  end

  def users_turn_to_act?() @player_proxy.users_turn_to_act? end

  def play_check_fold!
    log __method__
    if @player_proxy.users_turn_to_act?
      play!(
        if (
          @player_proxy.legal_actions.any? do |a|
            a == AcpcPokerTypes::PokerAction::FOLD
          end
        )
          AcpcPokerTypes::PokerAction::FOLD
        else
          AcpcPokerTypes::PokerAction::CALL
        end,
        true
      )
    end
    self
  end

  # @see PlayerProxy#match_ended?
  def match_ended?
    return false if @player_proxy.nil?

    @match ||= begin
      Match.find(@match_id)
    rescue Mongoid::Errors::DocumentNotFound
      log(
        __method__,
        {
          msg: "Unable to find match",
          match_id: @match_id,
          match_ended: @player_proxy.match_ended?
        }
      )
      return true
    end

    (
      @player_proxy.match_ended? ||
      (
        @player_proxy.hand_ended? &&
        @player_proxy.match_state.hand_number >= @match.number_of_hands - 1
      )
    )
  end

  private

  def update_database!(players_at_the_table, fast_forward = false)
    @match = Match.find(@match_id)

    begin
      if fast_forward
        @match.last_slice_viewed = @match.slices.length - 1
      end

      MatchSlice.from_players_at_the_table!(
        players_at_the_table,
        match_ended?,
        @match
      )

      new_slice = @match.slices.last
      new_slice.messages = []

      ms = players_at_the_table.match_state

      log(
        __method__,
        {
          first_state_of_first_round?: ms.first_state_of_first_round?
        }
      )

      if ms.first_state_of_first_round?
        new_slice.messages << hand_dealt_description(
          @match.player_names.map { |n| Hescape.escape_html(n) },
          ms.hand_number + 1,
          players_at_the_table.game_def,
          @match.number_of_hands
        )
      end

      last_action = ms.betting_sequence(
        players_at_the_table.game_def
      ).flatten.last

      log(
        __method__,
        {
          last_action: last_action
        }
      )

      if last_action
        last_actor = @match.player_names[
          @match.slices[-2].seat_next_to_act
        ]

        log(
          __method__,
          {
            last_actor: last_actor
          }
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
              ms.players(players_at_the_table.game_def).num_wagers(ms.round) - 1,
              players_at_the_table.game_def.max_number_of_wagers[ms.round]
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
        {
          hand_ended?: players_at_the_table.hand_ended?
        }
      )

      if ms.first_state_of_round? && ms.round > 0
        s = if ms.community_cards[ms.round - 1].length > 1 then 'are' else 'is' end
        new_slice.messages << (
          "#{(ms.community_cards[ms.round - 1].map { |c| c.rank.to_s + c.suit.to_html }).join('')} #{s} revealed."
        )
      end

      if players_at_the_table.hand_ended?
        log(
          __method__,
          {
            reached_showdown?: ms.reached_showdown?
          }
        )

        if ms.reached_showdown?
          players_at_the_table.players.each_with_index do |player, i|
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
            ms.pot(players_at_the_table.game_def)
          )
        else
          winnings = winning_players.first['winnings']
          if winnings.to_i == winnings
            winnings = winnings.to_i
          end
          chip_balance = winning_players.first['chip_balance']
          if chip_balance.to_i == chip_balance
            chip_balance = chip_balance.to_i
          end

          new_slice.messages << hand_win_description(
            Hescape.escape_html(winning_players.first['name']),
            winnings,
            chip_balance - winnings
          )
        end
      end

      new_slice.save!

      # Since creating a new slice doesn't "update" the match for some reason
      @match.update_attribute(:updated_at, Time.now)
      @match.save!
    rescue => e
      raise UnableToCreateMatchSlice.with_context('Unable to create match slice', e)
    end

    self
  end
end
end
