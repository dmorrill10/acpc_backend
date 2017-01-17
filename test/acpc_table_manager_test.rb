require 'support/spec_helper'

require 'acpc_table_manager'

describe AcpcTableManager do
  it 'has a version number' do
    ::AcpcTableManager::VERSION.wont_be_nil
  end

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
    AcpcTableManager.load_config! config_data, pwd
  end

  after do
    FileUtils.rm_rf File.expand_path('../tmp', __FILE__)
  end

  let(:game) { 'two_player_nolimit' }
  let(:random_seed) { 9001 }

  describe '::start_match' do
    it 'works' do
      players = ['TestingBot', 'TestingBot']

      name = match_name(players)
      dealer_info, player_info = AcpcTableManager.start_match(
        game,
        name,
        players,
        random_seed,
        players.map { |e| 0 }
      )
      AcpcDealer.process_exists?(dealer_info[:pid]).must_equal true

      Timeout.timeout(2) do
        while AcpcDealer.process_exists?(dealer_info[:pid])
          sleep 0.1
        end
      end

      log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.log")
      File.exist?(log_file).must_equal true
      File.open(File.expand_path("../support/#{name}.log", __FILE__)) do |xf|
        File.open(log_file) do |f|
          f.readlines[1..-1].must_equal xf.readlines[1..-1]
        end
      end

      log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.actions.log")
      File.exist?(log_file).must_equal true
    end
  end

  describe '::start_dealer' do
    it 'works' do
      players = ['ExamplePlayer', 'human player']
      name = match_name(players)
      dealer_info = AcpcTableManager.start_dealer(
        game,
        name,
        players,
        random_seed,
        players.map { |e| 0 }
      )
      AcpcDealer.process_exists?(dealer_info[:pid]).must_equal true
      AcpcDealer.kill_process dealer_info[:pid]
      sleep 0.5
      AcpcDealer.process_exists?(dealer_info[:pid]).must_equal false
      log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.log")
      File.exist?(log_file).must_equal true
      log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.actions.log")
      File.exist?(log_file).must_equal true
    end
  end

  describe '::dealer_arguments' do
    it 'works' do
      players = ['ExamplePlayer', 'human player']

      AcpcTableManager.dealer_arguments(
        game,
        'my match',
        players,
        random_seed
      ).must_equal(
        match_name: 'my_match',
        game_def_file_name: AcpcDealer::GAME_DEFINITION_FILE_PATHS[2][:nolimit],
        hands: '10',
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

  describe '::participant_id' do
    it 'works' do
      AcpcTableManager.participant_id('my match', 'p1', 2).must_equal 'my_match.p1.2'
    end
  end

  def match_name(players)
    AcpcTableManager.match_name(
      game_def_key: game,
      players: players,
      time: false
    )
  end

  describe '::start_matches_if_allowed, ::enqueued_matches, and ::running_matches together' do
    it 'works' do
      players = ['TestingBot', 'TestingBot']

      AcpcTableManager.running_matches(game).length.must_equal 0
      AcpcTableManager.enqueue_match(
        game,
        players,
        random_seed
      )
      AcpcTableManager.start_matches_if_allowed

      patient = AcpcTableManager.running_matches(game)
      patient.length.must_equal 1
      AcpcDealer.process_exists?(patient.first[:dealer][:pid]).must_equal true
      patient.first[:name].must_match /^#{match_name(players)}/
      patient.first[:dealer][:port_numbers].length.must_equal players.length
      patient.first[:dealer][:log_directory].must_equal AcpcTableManager.config.match_log_directory
      patient.first[:players].length.must_equal players.length
      patient.first[:players].each_with_index do |player, i|
        player[:name].must_equal players[i]
        player[:pid].must_be :>, 0
      end

      Timeout.timeout(2) do
        while AcpcDealer.process_exists?(patient.first[:dealer][:pid])
          sleep 0.1
        end
      end

      AcpcTableManager.running_matches(game).length.must_equal 0
    end
  end

  it 'works with a special port' do
    players = ['SpecialPortTestingBot', 'TestingBot']

    AcpcTableManager.running_matches(game).length.must_equal 0
    AcpcTableManager.enqueue_match(
      game,
      players,
      random_seed
    )
    AcpcTableManager.start_matches_if_allowed

    patient = AcpcTableManager.running_matches(game)
    patient.length.must_equal 1
    AcpcDealer.process_exists?(patient.first[:dealer][:pid]).must_equal true
    patient.first[:name].must_match /^#{match_name(players)}/
    patient.first[:dealer][:port_numbers].length.must_equal players.length
    patient.first[:dealer][:port_numbers].first.must_equal 19001
    patient.first[:dealer][:log_directory].must_equal AcpcTableManager.config.match_log_directory
    patient.first[:players].length.must_equal players.length
    patient.first[:players].each_with_index do |player, i|
      player[:name].must_equal players[i]
      player[:pid].must_be :>, 0
    end

    Timeout.timeout(2) do
      while AcpcDealer.process_exists?(patient.first[:dealer][:pid])
        sleep 0.1
      end
    end

    AcpcTableManager.running_matches(game).length.must_equal 0
  end

  it 'adjusts when too many agents need special ports' do
    players = ['SpecialPortTestingBot', 'SpecialPortTestingBot']

    AcpcTableManager.running_matches(game).length.must_equal 0
    AcpcTableManager.enqueue_match(
      game,
      players,
      random_seed
    )
    AcpcTableManager.start_matches_if_allowed
    AcpcTableManager.running_matches(game).length.must_equal 0
    AcpcTableManager.enqueued_matches(game).length.must_equal 0
  end

  it 'adjusts when too many agents in multiple matches need special ports' do
    players = ['SpecialPortTestingBot', 'TestingBot']

    AcpcTableManager.running_matches(game).length.must_equal 0
    AcpcTableManager.enqueue_match(
      game,
      players,
      random_seed
    )
    sleep 1
    AcpcTableManager.enqueue_match(
      game,
      players,
      random_seed
    )
    AcpcTableManager.enqueued_matches(game).length.must_equal 2
    AcpcTableManager.start_matches_if_allowed
    AcpcTableManager.running_matches(game).length.must_equal 1
    AcpcTableManager.enqueued_matches(game).length.must_equal 1
    AcpcTableManager.start_matches_if_allowed
    patient = AcpcTableManager.running_matches(game)
    patient.length.must_equal 1
    AcpcTableManager.enqueued_matches(game).length.must_equal 1

    Timeout.timeout(2) do
      while AcpcDealer.process_exists?(patient.first[:dealer][:pid])
        sleep 0.1
      end
    end
    AcpcTableManager.start_matches_if_allowed
    patient = AcpcTableManager.running_matches(game)
    patient.length.must_equal 1
    AcpcTableManager.enqueued_matches(game).length.must_equal 0

    Timeout.timeout(2) do
      while AcpcDealer.process_exists?(patient.first[:dealer][:pid])
        sleep 0.1
      end
    end
    AcpcTableManager.running_matches(game).length.must_equal 0
  end

  describe '::enqueue_match' do
    it 'works' do
      players = ['ExamplePlayer', 'human player']
      sanitized_players = ['ExamplePlayer', 'human_player']

      AcpcTableManager.enqueued_matches(game).length.must_equal 0
      AcpcTableManager.enqueue_match(
        game,
        players,
        random_seed
      )
      patient = AcpcTableManager.enqueued_matches(game)
      patient.length.must_equal 1
      patient.first[:game_def_key].must_equal game
      patient.first[:players].must_equal sanitized_players
      patient.first[:name].must_match /^match\.#{sanitized_players.join('\.')}\.#{game}/
      patient.first[:random_seed].must_equal random_seed
    end
    it 'will not enqueue two matches with the same name' do
      players = ['ExamplePlayer', 'human player']
      AcpcTableManager.enqueued_matches(game).length.must_equal 0
      AcpcTableManager.enqueue_match(
        game,
        players,
        random_seed
      )
      AcpcTableManager.enqueued_matches(game).length.must_equal 1
      -> do
        AcpcTableManager.enqueue_match(
          game,
          players,
          1
        )
      end.must_raise AcpcTableManager::MatchAlreadyEnqueued
      AcpcTableManager.enqueued_matches(game).length.must_equal 1
    end
  end
end
