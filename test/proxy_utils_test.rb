require_relative 'support/spec_helper'

require 'acpc_poker_types/match_state'
require 'acpc_poker_types/game_definition'
require 'acpc_poker_types/hand'
require 'acpc_poker_types/players_at_the_table'

require_relative '../lib/acpc_table_manager/config'
require_relative '../lib/acpc_table_manager/proxy_utils'

module MapWithIndex
  refine Array do
    def map_with_index
      i = 0
      map do |elem|
        result = yield elem, i
        i += 1
        result
      end
    end
  end
end
using MapWithIndex

include AcpcPokerTypes
include AcpcTableManager

describe ProxyUtils do
  let(:patient) { ProxyUtils }
  describe 'chip_contribution_after_calling and ::amount_to_call' do
    it 'work after all-in' do
      game_def = GameDefinition.new(
        :betting_type=>"nolimit",
        :chip_stacks=>[20000, 20000],
        :number_of_players=>2,
        :blinds=>[100, 50],
        :raise_sizes=>nil,
        :number_of_rounds=>4,
        :first_player_positions=>[1, 0, 0, 0],
        :max_number_of_wagers=>[255],
        :number_of_suits=>4,
        :number_of_ranks=>13,
        :number_of_hole_cards=>2,
        :number_of_board_cards=>[0, 3, 1, 1]
      )
      match_state = MatchState.parse(
        'MATCHSTATE:1:1:cr20000c///:7c7d|6cAc/2s9cKc/4s/5s'
      )
      patient.chip_contribution_after_calling(
        match_state, game_def
      ).must_equal 0
      patient.amount_to_call(match_state, game_def).must_equal 0
    end
  end
  describe 'betting_sequence' do
    it 'works' do
      game_def = GameDefinition.new(
        first_player_positions: [3, 2, 2, 2],
        chip_stacks: [200, 200, 200],
        blinds: [10, 0, 5],
        raise_sizes: [10]*4,
        number_of_ranks: 3
      )
      match_state = MatchState.parse(
        "#{MatchState::LABEL}:1:0:ccr20cc/r50fr100c/cc/cc:AhKs||"
      )
      patient.betting_sequence(match_state, game_def).must_equal 'ckR20cc/B30fr80C/Kk/Kk'
    end
  end
  describe 'pot_at_start_of_round' do
    it 'works after each round' do
      game_def = GameDefinition.new(
        first_player_positions: [3, 2, 2, 2],
        chip_stacks: [200, 200, 200],
        blinds: [10, 0, 5],
        raise_sizes: [10]*4,
        number_of_ranks: 3
      )
      betting_sequence = [['c', 'c', 'r20', 'c', 'c'], ['r50', 'f', 'r100', 'c'], ['c', 'c'], ['c', 'c']]
      betting_sequence_string = ''
      x_contributionx_at_start_of_round = [0, 60, 220, 220]

      betting_sequence.each_with_index do |actions_per_round, round|
        betting_sequence_string << '/' unless round == 0
        actions_per_round.each do |action|
          betting_sequence_string << action
          match_state = MatchState.parse(
            "#{MatchState::LABEL}:1:0:#{betting_sequence_string}:AhKs||"
          )

          patient.pot_at_start_of_round(match_state, game_def).must_equal x_contributionx_at_start_of_round[round]
          @patient = nil
        end
      end
    end
  end
  describe 'players_at_the_table_to_json' do
    it 'works at the beginning of a 2-player no-limit hand' do
      game_def = GameDefinition.new(
        betting_type: 'nolimit',
        first_player_positions: [2, 1, 1, 1],
        chip_stacks: [20000, 20000],
        blinds: [100, 50],
        number_of_ranks: 13,
        number_of_suits: 4,
        number_of_hole_cards: 2
      )
      seat = 0
      state_index = 9001
      match_state = MatchState.parse("#{MatchState::LABEL}:0:0::AhKc|")
      patient = ProxyUtils.players_at_the_table_to_json(
        PlayersAtTheTable.new(game_def, seat).update!(match_state),
        100,
        state_index
      )
      parsed_patient = JSON.parse(patient)
      x_patient = {
                 "status" => {
               "hand_has_ended" => false,
              "match_has_ended" => nil,
                   "hand_index" => 0,
                  "state_index" => state_index
          },
          "legal_actions" => [
              {
                'type' => "c",
                'cost' => 50.0
              },
              {
                'type' => 'f',
                'cost' => 0.0
              },
              {
                'type' => 'r',
                'cost' => 150.0
              },
              {
                'type' => 'r',
                'cost' => 19950.0
              }
          ],
                  "table" => {
              "board_cards" => [],
                "pot_chips" => 0.0,
                     "user" => {
                                 "seat" => seat,
                    "chip-stack-amount" => 19900,
                        "contributions" => [
                      100
                  ],
                  "chip-balance-amount" => 0,
                           "hole-cards" => [
                      {
                          "rank" => "A",
                          "suit" => "h"
                      },
                      {
                          "rank" => "K",
                          "suit" => "c"
                      }
                  ],
                             "winnings" => 0.0,
                               "dealer" => false,
                               "acting" => false
              },
                "opponents" => [
                  {
                                     "seat" => 1,
                        "chip-stack-amount" => 19950,
                            "contributions" => [
                          50
                      ],
                      "chip-balance-amount" => 0,
                               "hole-cards" => [{}, {}],
                                 "winnings" => 0.0,
                                   "dealer" => true,
                                   "acting" => true
                  }
              ]
          }
      }
      parsed_patient.must_equal x_patient
    end
    it 'works at the end of a 2-player no-limit hand' do
      game_def = GameDefinition.new(
        betting_type: 'nolimit',
        first_player_positions: [2, 1, 1, 1],
        chip_stacks: [20000, 20000],
        blinds: [100, 50],
        number_of_ranks: 13,
        number_of_suits: 4,
        number_of_hole_cards: 2
      )
      seat = 0
      state_index = 9001
      match_state = MatchState.parse("#{MatchState::LABEL}:0:99:cr300c/r500c/cc/cc:AhKc|Ts7h/2s5d7c/Jh/Jc")
      patient = ProxyUtils.players_at_the_table_to_json(
        PlayersAtTheTable.new(game_def, seat).update!(match_state),
        100,
        state_index
      )
      parsed_patient = JSON.parse(patient)
      x_patient = {
                 "status" => {
               "hand_has_ended" => true,
              "match_has_ended" => true,
                   "hand_index" => 99,
                  "state_index" => state_index
          },
          "legal_actions" => [],
                  "table" => {
            "board_cards" => [
              {
                "rank" => "2",
                "suit" => "s"
              },
              {
                "rank" => "5",
                "suit" => "d"
              },
              {
                "rank" => "7",
                "suit" => "c"
              },
              {
                "rank" => "J",
                "suit" => "h"
              },
              {
                "rank" => "J",
                "suit" => "c"
              }
            ],
            "pot_chips" => 1000,
                     "user" => {
                                 "seat" => seat,
                    "chip-stack-amount" => 19500,
                        "contributions" => [300, 200, 0, 0],
                  "chip-balance-amount" => -500.0,
                           "hole-cards" => [
                      {
                          "rank" => "A",
                          "suit" => "h"
                      },
                      {
                          "rank" => "K",
                          "suit" => "c"
                      }
                  ],
                             "winnings" => 0.0,
                               "dealer" => false,
                               "acting" => false
              },
                "opponents" => [
                  {
                                     "seat" => 1,
                        "chip-stack-amount" => 20500,
                            "contributions" => [300, 200, 0, 0],
                      "chip-balance-amount" => 500.0,
                               "hole-cards" => [
                                 {
                                   "rank" => "T",
                                   "suit" => "s"
                                 },
                                 {
                                   "rank" => "7",
                                   "suit" => "h"
                                 }
                               ],
                                 "winnings" => 1000.0,
                                   "dealer" => true,
                                   "acting" => false
                  }
              ]
          }
      }
      parsed_patient.must_equal x_patient
    end
  end
  describe 'players' do
    it 'works' do
      wager_size = 10
      game_def = GameDefinition.new(
        first_player_positions: [3, 2, 2, 2],
        chip_stacks: [500, 450, 550],
        blinds: [0, 10, 5],
        raise_sizes: [wager_size]*4,
        number_of_ranks: 3,
        number_of_hole_cards: 1
      )
      x_actions = [
        [
          [
            PokerAction.new(PokerAction::RAISE, cost: wager_size + 10),
          ],
          [
            PokerAction.new(PokerAction::CHECK)
          ],
          [
            PokerAction.new(PokerAction::FOLD)
          ]
        ],
        [
          [
            PokerAction.new(PokerAction::CALL, cost: wager_size)
          ],
          [
            PokerAction.new(PokerAction::CHECK)
          ],
          [
            PokerAction.new(PokerAction::BET, cost: wager_size)
          ]
        ],
        [
          [
            PokerAction.new(PokerAction::CALL, cost: 5),
            PokerAction.new(PokerAction::CALL, cost: wager_size)
          ],
          [
            PokerAction.new(PokerAction::CHECK)
          ],
          [
            PokerAction.new(PokerAction::RAISE, cost: 2 * wager_size)
          ]
        ]
      ]

      seat = 1
      x_is_acting = [
        [false, false, true],
        [false, true, false],
        [true, false, false]
      ]
      x_is_dealer = [
        [true, false, false],
        [false, false, true],
        [false, true, false]
      ]
      x_folded_seats = [1, 0, 2]

      game_def.number_of_players.times do |position|
        hands = []
        game_def.number_of_players.times.map do
          hands << [{}]*game_def.number_of_hole_cards
        end
        hands[seat] = [{'rank' => 'T', 'suit' => 's'}]
        hand_string = hands.rotate(seat - position).inject('') do |s, hand|
          cards = hand.inject('') do |t, card|
            t += "#{card['rank']}#{card['suit']}"
          end
          s << "#{cards}#{MatchState::HAND_SEPARATOR}"
        end[0..-2]

        x_contributions = x_actions.rotate(position - seat).map_with_index do |actions_per_player, i|
          player_contribs = actions_per_player.map do |actions_per_round|
            actions_per_round.inject(0) { |sum, action| sum += action.cost }.to_i
          end
          player_contribs[0] += game_def.blinds.rotate(position - seat)[i].to_i
          player_contribs
        end

        x_stacks = game_def.chip_stacks.rotate(position - seat).map_with_index do |chip_stack, i|
          chip_stack - x_contributions[i].inject(:+)
        end

        match_state = MatchState.parse(
          "#{MatchState::LABEL}:#{position}:0:crcc/ccc/rrf:#{hand_string}"
        )

        # Balances should only be adjusted at the end of the hand
        x_balances = x_contributions.map { |contrib| 0 }

        hands[x_folded_seats[position]] = []

        x_players = [
          {
            'seat' => 0,
            'chip-stack-amount' => x_stacks[0],
            'contributions' => x_contributions[0],
            'chip-balance-amount' => x_balances[0],
            'hole-cards' => hands[0],
            'winnings' => 0.to_f,
            'dealer' => x_is_dealer[position][0],
            'acting' => x_is_acting[position][0]
          },
          {
            'seat' => 1,
            'chip-stack-amount' => x_stacks[1],
            'contributions' => x_contributions[1],
            'chip-balance-amount' => x_balances[1],
            'hole-cards' => hands[1],
            'winnings' => 0.to_f,
            'dealer' => x_is_dealer[position][1],
            'acting' => x_is_acting[position][1]
          },
          {
            'seat' => 2,
            'chip-stack-amount' => x_stacks[2],
            'contributions' => x_contributions[2],
            'chip-balance-amount' => x_balances[2],
            'hole-cards' => hands[2],
            'winnings' => 0.to_f,
            'dealer' => x_is_dealer[position][2],
            'acting' => x_is_acting[position][2]
          }
        ]

        players = patient.players(
          PlayersAtTheTable.new(game_def, seat).update!(match_state)
        )
        players.must_equal x_players
        @patient = nil
      end
    end
    it 'works when players are all-in' do
      game_def = GameDefinition.new(
        :betting_type=>"nolimit",
        :chip_stacks=>[20000, 20000],
        :number_of_players=>2,
        :blinds=>[100, 50],
        :raise_sizes=>nil,
        :number_of_rounds=>4,
        :first_player_positions=>[1, 0, 0, 0],
        :number_of_suits=>4,
        :number_of_ranks=>13,
        :number_of_hole_cards=>2,
        :number_of_board_cards=>[0, 3, 1, 1]
      )
      patient.players(
        PlayersAtTheTable.new(game_def, 0).update!(
          MatchState.parse(
            'MATCHSTATE:0:2:cr20000c///:8h8s|5s5c/KdTcKh/9h/Jh'
          ),
        )
      ).map { |pl| pl['winnings'] }.must_equal [40000.0, 0.0]
    end
  end
  describe 'minimum_wager_to' do
    it 'works for large stacks' do
      wager_size = 10
      x_game_def = {
        first_player_positions: [0, 0, 0],
        chip_stacks: [1000, 2000, 1500],
        blinds: [0, 10, 5],
        raise_sizes: [wager_size]*3,
        number_of_ranks: 3
      }
      game_def = GameDefinition.new(x_game_def)

      x_min_wagers = [
        [2*wager_size],
        [2*wager_size, 50, 170, 170, wager_size],
        [wager_size, wager_size, wager_size],
        [wager_size, 2*wager_size, 50, 90, 90]
      ]

      hands = game_def.number_of_players.times.map { |i| '' }

      hand_string = hands.inject('') do |string, hand|
        string << "#{hand}#{MatchState::HAND_SEPARATOR}"
      end[0..-2]

      (0..game_def.number_of_players-1).each do |position|
        [
          [''],
          ['c', 'cr30', 'cr30r100', 'cr30r100c', 'cr30r100cc/'],
          ['cr30r100cc/c', 'cr30r100cc/cc', 'cr30r100cc/ccc/'],
          [
            'cr30r100cc/ccc/c',
            'cr30r100cc/ccc/cr110',
            'cr30r100cc/ccc/cr110r130',
            'cr30r100cc/ccc/cr110r130r160',
            'cr30r100cc/ccc/cr110r130r160c'
          ]
        ].each_with_index do |betting_sequence_list, i|
          betting_sequence_list.each_with_index do |betting_sequence, j|
            match_state = MatchState.parse(
              "#{MatchState::LABEL}:#{position}:0:#{betting_sequence}:#{hand_string}"
            )

            patient.minimum_wager_to(match_state, game_def).must_equal x_min_wagers[i][j]
            @patient = nil
          end
        end
      end
    end
    it 'works for small stacks' do
      wager_size = 10
      x_game_def = {
        first_player_positions: [0, 0, 0],
        chip_stacks: [100, 200, 150],
        blinds: [0, 10, 5],
        raise_sizes: [wager_size]*3,
        number_of_ranks: 3
      }
      game_def = GameDefinition.new(x_game_def)

      x_min_wagers = [
        [2*wager_size],
        [2*wager_size, 50, 100, 100, wager_size],
        [wager_size, wager_size, wager_size],
        [wager_size, 2*wager_size, 50, 90, 90]
      ]

      hands = game_def.number_of_players.times.map { |i| '' }

      hand_string = hands.inject('') do |string, hand|
        string << "#{hand}#{MatchState::HAND_SEPARATOR}"
      end[0..-2]

      (0..game_def.number_of_players-1).each do |position|
        [
          [''],
          ['c', 'cr30', 'cr30r100', 'cr30r100c', 'cr30r100cc/'],
          ['cr30r100cc/c', 'cr30r100cc/cc', 'cr30r100cc/ccc/'],
          [
            'cr30r100cc/ccc/c',
            'cr30r100cc/ccc/cr110',
            'cr30r100cc/ccc/cr110r130',
            'cr30r100cc/ccc/cr110r130r160',
            'cr30r100cc/ccc/cr110r130r160c'
          ]
        ].each_with_index do |betting_sequence_list, i|
          betting_sequence_list.each_with_index do |betting_sequence, j|
            match_state = MatchState.parse(
              "#{MatchState::LABEL}:#{position}:0:#{betting_sequence}:#{hand_string}"
            )

            patient.minimum_wager_to(match_state, game_def).must_equal x_min_wagers[i][j]
            @patient = nil
          end
        end
      end
    end
  end
  describe '#pot_after_call' do
    it 'works' do
      wager_size = 10
      x_game_def = {
        first_player_positions: [0, 0, 0],
        chip_stacks: [500, 600, 550],
        blinds: [0, 10, 5],
        raise_sizes: [wager_size]*3,
        number_of_ranks: 3
      }
      game_def = GameDefinition.new(x_game_def)

      x_pot = [
        [15 + 10],
        [
          15 + 10,
          30 * 2 + 10,
          100 * 2 + 30,
          300,
          300
        ],
        [
          300,
          300,
          300
        ],
        [
          300,
          310 + 10,
          110 * 3 + 20 * 2,
          160 * 3 - 30,
          160 * 3
        ]
      ]

      hands = game_def.number_of_players.times.map { |i| '' }

      hand_string = hands.inject('') do |string, hand|
        string << "#{hand}#{MatchState::HAND_SEPARATOR}"
      end[0..-2]

      game_def.number_of_players.times do |position|
        [
          [''],
          ['c', 'cr30', 'cr30r100', 'cr30r100c', 'cr30r100cc/'],
          ['cr30r100cc/c', 'cr30r100cc/cc', 'cr30r100cc/ccc/'],
          [
            'cr30r100cc/ccc/c',
            'cr30r100cc/ccc/cr110',
            'cr30r100cc/ccc/cr110r130',
            'cr30r100cc/ccc/cr110r130r160',
            'cr30r100cc/ccc/cr110r130r160c'
          ]
        ].each_with_index do |betting_sequence_list, i|
          betting_sequence_list.each_with_index do |betting_sequence, j|
            match_state = MatchState.parse(
              "#{MatchState::LABEL}:#{position}:0:#{betting_sequence}:#{hand_string}"
            )

            patient.pot_after_call(match_state, game_def).must_equal x_pot[i][j]
            @patient = nil
          end
        end
      end
    end
  end
  describe '#all_in' do
    it 'works' do
      wager_size = 10
      x_game_def = {
        first_player_positions: [0, 0, 0],
        chip_stacks: [5000, 5000, 5000],
        blinds: [0, 5, 10],
        raise_sizes: [wager_size]*3,
        number_of_ranks: 3
      }
      game_def = GameDefinition.new(x_game_def)

      x_all_in = [
        [5000],
        [5000]*4 << 4900,
        [4900]*3,
        [4900]*5
      ]

      hands = game_def.number_of_players.times.map { |i| '' }

      hand_string = hands.inject('') do |string, hand|
        string << "#{hand}#{MatchState::HAND_SEPARATOR}"
      end[0..-2]

      (0..game_def.number_of_players-1).each do |position|
        [
          [''],
          ['c', 'cr30', 'cr30r100', 'cr30r100c', 'cr30r100cc/'],
          ['cr30r100cc/c', 'cr30r100cc/cc', 'cr30r100cc/ccc/'],
          [
            'cr30r100cc/ccc/c',
            'cr30r100cc/ccc/cr110',
            'cr30r100cc/ccc/cr110r130',
            'cr30r100cc/ccc/cr110r130r160',
            'cr30r100cc/ccc/cr110r130r160c'
          ]
        ].each_with_index do |betting_sequence_list, i|
          betting_sequence_list.each_with_index do |betting_sequence, j|
            match_state = MatchState.parse(
              "#{MatchState::LABEL}:#{position}:0:#{betting_sequence}:#{hand_string}"
            )

            patient.all_in(match_state, game_def).must_equal x_all_in[i][j].floor
            @patient = nil
          end
        end
      end
    end
  end
end
