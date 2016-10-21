require 'support/spec_helper'

require 'acpc_table_manager/config'

describe AcpcTableManager do
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
    AcpcTableManager.unload!
  end

  after do
    FileUtils.rm_rf File.expand_path('../tmp', __FILE__)
  end

  it 'begins uninitialized' do
    AcpcTableManager.initialized?.must_equal false
  end

  it 'is initialized after loading some configuration' do
    AcpcTableManager.load_config! config_data, pwd
    AcpcTableManager.initialized?.must_equal true
  end

  it 'it sets uninitialized values to nil' do
    AcpcTableManager.load_config! config_data, pwd
    AcpcTableManager.config.respond_to?(:_a).must_equal false
    AcpcTableManager.config._a.must_equal nil
  end

  it 'sets expected values upon initialization' do
    AcpcTableManager.load_config! config_data, pwd

    AcpcTableManager.config.file.must_equal File.expand_path('../support/table_manager.json', __FILE__)
    AcpcTableManager.config.this_machine.must_equal Socket.gethostname
    AcpcTableManager.config.dealer_host.must_equal Socket.gethostname
    AcpcTableManager.config.log_directory.must_equal File.expand_path('../tmp/log', __FILE__)
    AcpcTableManager.config.my_log_directory.must_equal File.expand_path('../tmp/log/acpc_table_manager', __FILE__)
    AcpcTableManager.config.start_match_request_code.must_equal "dealer"
    AcpcTableManager.config.start_proxy_request_code.must_equal "proxy"
    AcpcTableManager.config.play_action_request_code.must_equal "play"
    AcpcTableManager.config.kill_match.must_equal "kill-match"
    AcpcTableManager.config.delete_irrelevant_matches_request_code.must_equal "delete_irrelevant_matches"
    AcpcTableManager.config.poker_manager.must_equal "TableManager"
    AcpcTableManager.config.player_action_channel_prefix.must_equal "player-action-in-"
    AcpcTableManager.config.realtime_channel.must_equal "table-manager-update"
    AcpcTableManager.config.match_id_key.must_equal "match_id"
    AcpcTableManager.config.options_key.must_equal "options"
    AcpcTableManager.config.action_key.must_equal "action"
    AcpcTableManager.config.message_server_port.must_equal 6379
    AcpcTableManager.config.update_match_queue_channel.must_equal "update_match_queue"
    AcpcTableManager.config.special_ports_to_dealer.must_equal []
    AcpcTableManager.config.match_lifespan_s.must_equal 120
    AcpcTableManager.config.action_delay_s.must_equal 0.15
    AcpcTableManager.config.maintenance_interval_s.must_equal 30
    AcpcTableManager.config.max_time_to_wait_for_players_to_start_s.must_equal 180

    AcpcTableManager.exhibition_config.games['two_player_limit'].must_equal(
      {
        'file' => File.join(AcpcDealer::DEALER_DIRECTORY, 'holdem.2p.reverse_blinds.game'),
        'label' => "Heads-up Limit Texas Hold'em",
        'max_num_matches' => 2,
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
    AcpcTableManager.exhibition_config.games['two_player_nolimit'].must_equal(
      {
        'file' => File.join(AcpcDealer::DEALER_DIRECTORY, 'holdem.nolimit.2p.reverse_blinds.game'),
        'label' => "Heads-up No-limit Texas Hold'em",
        'max_num_matches' => 2,
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
    AcpcTableManager.exhibition_config.games['three_player_kuhn'].must_equal(
      {
        'file' => File.join(AcpcDealer::DEALER_DIRECTORY, 'kuhn.limit.3p.game'),
        'label' => "3-player Kuhn",
        'max_num_matches' => 2,
        'num_players' => 3,
        'num_hands_per_match' => 3000
      }
    )
    AcpcTableManager.exhibition_config.rejoin_button_id.must_equal "rejoin"
    AcpcTableManager.exhibition_config.spectate_button_id_prefix.must_equal "spectate-"
  end

  describe 'ExhibitionConfig#bots' do
    it 'works properly' do
      AcpcTableManager.load_config! config_data, pwd
      AcpcTableManager.exhibition_config.bots('two_player_limit', 'ExamplePlayer', 'NotPlayer').must_equal(
        {
          'ExamplePlayer' => {
            'runner' => AcpcDealer::EXAMPLE_PLAYERS[2][:limit],
            'requires_special_port' => true
          }
        }
      )
      AcpcTableManager.exhibition_config.bots('two_player_limit', 'ExamplePlayer', 'NotPlayer').values.must_equal(
        [
          {
            'runner' => AcpcDealer::EXAMPLE_PLAYERS[2][:limit],
            'requires_special_port' => true
          }
        ]
      )
    end
  end
end
