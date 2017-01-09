require 'support/spec_helper'

require 'acpc_table_manager/config'

describe AcpcTableManager do
  let (:config_data) { {
      'table_manager_constants' => '%{pwd}/support/table_manager.json',
      'match_log_directory' => '%{pwd}/../tmp/log/match_logs',
      'exhibition_constants' => '%{pwd}/support/exhibition.json',
      'log_directory' => '%{pwd}/tmp/log',
      'bots' => '%{pwd}/support/bots.yml',
      'data_directory' => '%{pwd}/tmp/db'
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
  end

  it 'creates data directory properly' do
    AcpcTableManager.load_config! config_data, pwd
    AcpcTableManager.config.data_directory.must_equal "#{pwd}/tmp/db"
    File.directory?(AcpcTableManager.config.data_directory).must_equal true
  end

  it 'creates its data files correctly' do
    AcpcTableManager.load_config! config_data, pwd
    AcpcTableManager.data_directory.must_equal "#{pwd}/tmp/db"
    AcpcTableManager.exhibition_config.games.keys.each do |game|
      AcpcTableManager.data_directory(game).must_equal "#{pwd}/tmp/db/#{game}"
      File.directory?(AcpcTableManager.data_directory(game)).must_equal true

      AcpcTableManager.enqueued_matches_file(game).must_equal "#{pwd}/tmp/db/#{game}/enqueued_matches.yml"
      File.exist?(AcpcTableManager.enqueued_matches_file(game)).must_equal true
      AcpcTableManager.enqueued_matches(game).length.must_equal 0

      AcpcTableManager.running_matches_file(game).must_equal "#{pwd}/tmp/db/#{game}/running_matches.yml"
      File.exist?(AcpcTableManager.running_matches_file(game)).must_equal true
      AcpcTableManager.running_matches(game).length.must_equal 0
    end
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

  let(:match_info) do
    {
      'name' => 'my match',
      'game_def_key' => 'two_player_nolimit',
      'players' => [
        'ExamplePlayer',
        'human player'
      ],
      'random_seed' => 9001
    }
  end

  describe '::shell_sanitize' do
    it 'removes spaces' do
      AcpcTableManager.shell_sanitize('hello world').must_equal 'hello_world'
    end
  end

  describe '::dealer_arguments' do
    it 'works' do
      AcpcTableManager.load_config! config_data, pwd
      AcpcTableManager.dealer_arguments(match_info).must_equal(
        match_name: 'my_match',
        game_def_file_name: AcpcDealer::GAME_DEFINITION_FILE_PATHS[2][:nolimit],
        hands: '100',
        random_seed: '9001',
        player_names: 'ExamplePlayer human_player',
        options: [
          "--t_response 0",
          "--t_hand 0",
          "--t_per_hand 0",
          "--t_ready 0",
          "-a"
        ]
      )
    end
  end

  describe '::proxy_player?' do
    it 'works' do
      AcpcTableManager.load_config! config_data, pwd
      AcpcTableManager.proxy_player?(
        'ExamplePlayer',
        'two_player_nolimit'
      ).must_equal false
      AcpcTableManager.proxy_player?(
        'NotExamplePlayer',
        'two_player_nolimit'
      ).must_equal true
    end
  end
end
