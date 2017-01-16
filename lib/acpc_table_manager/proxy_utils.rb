#!/usr/bin/env ruby

module AcpcTableManager
  module ProxyUtils

    # @todo
    def to_json(players_at_the_table)
      begin
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
          first_state_of_first_round?: ms.first_state_of_first_round?
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
          hand_ended?: players_at_the_table.hand_ended?
        )

        if ms.first_state_of_round? && ms.round > 0
          s = ms.community_cards[ms.round - 1].length > 1 ? 'are' : 'is'
          new_slice.messages <<
            "#{(ms.community_cards[ms.round - 1].map { |c| c.rank.to_s + c.suit.to_html }).join('')} #{s} revealed."

        end

        if players_at_the_table.hand_ended?
          log(
            __method__,
            reached_showdown?: ms.reached_showdown?
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

        new_slice.save!

        # Since creating a new slice doesn't "update" the match for some reason
        @match.update_attribute(:updated_at, Time.now)
        @match.save!
      rescue => e
        raise UnableToCreateMatchSlice.with_context('Unable to create match slice', e)
      end
    end

    def start_proxy(game_info, seat, port, must_send_ready = false)
      game_definition = GameDefinition.parse_file(game_info['file'])

      AcpcPokerPlayerProxy::PlayerProxy.new(
        AcpcDealer::ConnectionInformation.new(
          port,
          AcpcTableManager.config.dealer_host
        ),
        game_definition,
        seat,
        must_send_ready
      ) do |patt|
        if patt.match_state
          AcpcTableManager.redis.publish @sending_channel, to_json(patt)
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
          AcpcTableManager.redis.publish @sending_channel, to_json(patt)
        end
      end
    end
  end
end
