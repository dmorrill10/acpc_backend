require 'support/spec_helper'

require 'acpc_backend/config'

describe AcpcBackend do
  let (:config_data) { {
      'table_manager_constants' => '%{pwd}/support/table_manager.json',
      'match_log_directory' => '%{pwd}/../tmp/log/match_logs',
      'exhibition_constants' => '%{pwd}/support/exhibition.json',
      'log_directory' => '%{pwd}/tmp/log',
      'mongoid_config' => '%{pwd}/support/mongoid.yml',
      'bots' => '%{pwd}/support/bots.yml',
      'mongoid_env' => 'development'
    }
  }
  let (:pwd) { File.dirname(__FILE__) }

  before do
    AcpcBackend.unload!
  end

  after do
    FileUtils.rm_rf File.expand_path('../tmp', __FILE__)
  end

  it 'begins uninitialized' do
    AcpcBackend.initialized?.must_equal false
  end

  it 'is initialized after loading some configuration' do
    AcpcBackend.load_config! config_data, pwd
    AcpcBackend.initialized?.must_equal true
  end

  it 'sets expected values upon initialization' do
    AcpcBackend.load_config! config_data, pwd

    AcpcBackend.config.file.must_equal File.expand_path('../support/table_manager.json', __FILE__)
    AcpcBackend.config.this_machine.must_equal Socket.gethostname
    AcpcBackend.config.dealer_host.must_equal Socket.gethostname
    AcpcBackend.config.log_directory.must_equal File.expand_path('../tmp/log', __FILE__)
    AcpcBackend.config.my_log_directory.must_equal File.expand_path('../tmp/log/acpc_backend', __FILE__)
    AcpcBackend.config.start_match_request_code.must_equal "dealer"
    AcpcBackend.config.start_proxy_request_code.must_equal "proxy"
    AcpcBackend.config.play_action_request_code.must_equal "play"
    AcpcBackend.config.kill_match.must_equal "kill-match"
    AcpcBackend.config.delete_irrelevant_matches_request_code.must_equal "delete_irrelevant_matches"
    AcpcBackend.config.poker_manager.must_equal "TableManager"
    AcpcBackend.config.player_action_channel_prefix.must_equal "player-action-in-"
    AcpcBackend.config.realtime_channel.must_equal "table-manager-update"
    AcpcBackend.config.match_id_key.must_equal "match_id"
    AcpcBackend.config.options_key.must_equal "options"
    AcpcBackend.config.action_key.must_equal "action"
    AcpcBackend.config.message_server_port.must_equal 6379
    AcpcBackend.config.update_match_queue_channel.must_equal "update_match_queue"
    AcpcBackend.config.special_ports_to_dealer.must_equal []
    AcpcBackend.config.match_lifespan_s.must_equal 120
    AcpcBackend.config.action_delay_s.must_equal 0.15
    AcpcBackend.config.maintenance_interval_s.must_equal 30
    AcpcBackend.config.max_time_to_wait_for_players_to_start_s.must_equal 180

    AcpcBackend.exhibition_config.games['two_player_limit'].must_equal(
      {
        'file' => File.join(AcpcDealer::DEALER_DIRECTORY, 'holdem.2p.reverse_blinds.game'),
        'label' => "Heads-up Limit Texas Hold'em",
        'max_num_matches' => 2,
        'exhibition_bot_names' => ["Tester"],
        'num_hands_per_match' => 100,
        'num_players' => 2,
        'opponents' => {
          'ExamplePlayer' => {
            'runner' => AcpcDealer::EXAMPLE_PLAYERS[2][:limit],
            'requires_special_port' => true
          }
        }
      }
    )
    AcpcBackend.exhibition_config.games['two_player_nolimit'].must_equal(
      {
        'file' => File.join(AcpcDealer::DEALER_DIRECTORY, 'holdem.nolimit.2p.reverse_blinds.game'),
        'label' => "Heads-up No-limit Texas Hold'em",
        'max_num_matches' => 2,
        'exhibition_bot_names' => ["Tester"],
        'num_players' => 2,
        'num_hands_per_match' => 100,
        'opponents' => {
          'ExamplePlayer' => {
            'runner' => AcpcDealer::EXAMPLE_PLAYERS[2][:nolimit],
            'requires_special_port' => false
          }
        }
      }
    )
    AcpcBackend.exhibition_config.games['three_player_kuhn'].must_equal(
      {
        'file' => File.join(AcpcDealer::DEALER_DIRECTORY, 'kuhn.limit.3p.game'),
        'label' => "3-player Kuhn",
        'max_num_matches' => 2,
        'exhibition_bot_names' => ["Opponent1", "Opponent2"],
        'num_players' => 3,
        'num_hands_per_match' => 3000
      }
    )
    AcpcBackend.exhibition_config.rejoin_button_id.must_equal "rejoin"
    AcpcBackend.exhibition_config.spectate_button_id_prefix.must_equal "spectate-"
  end

  describe 'ExhibitionConfig#bots' do
    it 'works properly' do
      AcpcBackend.load_config! config_data, pwd
      AcpcBackend.exhibition_config.bots('two_player_limit', 'ExamplePlayer', 'NotPlayer').must_equal [
        {
          'runner' => AcpcDealer::EXAMPLE_PLAYERS[2][:limit],
          'requires_special_port' => true
        }
      ]
    end
  end
end
