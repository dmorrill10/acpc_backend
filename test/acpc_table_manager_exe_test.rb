require 'support/spec_helper'
require 'acpc_table_manager'

PWD = File.dirname(__FILE__)
CONFIG_DATA = {
  'table_manager_constants' => '%{pwd}/../support/table_manager.json',
  'match_log_directory' => '%{pwd}/log/match_logs',
  'exhibition_constants' => '%{pwd}/../support/exhibition.json',
  'log_directory' => '%{pwd}/log',
  'bots' => '%{pwd}/../support/bots.yml',
  'data_directory' => '%{pwd}/db',
  'redis_config_file' => 'default'
}

def my_setup
  tmp_dir = File.join(PWD, 'exe_test_tmp')
  FileUtils.mkdir_p tmp_dir
  config_file = File.join(tmp_dir, 'config.yml')
  File.open(config_file, 'w') do |f|
    f.puts YAML.dump(CONFIG_DATA)
  end
  redis_pid = Process.spawn('redis-server')
  patient_pid = Process.spawn(
    "#{File.join(PWD, '..', 'exe', 'acpc_table_manager')} -t #{config_file}"
  )
  sleep 0.5
  return tmp_dir, config_file, redis_pid, patient_pid
end
tmp_dir, config_file, redis_pid, patient_pid = my_setup

def my_teardown(tmp_dir, config_file, redis_pid, patient_pid)
  AcpcDealer.kill_process(redis_pid)
  AcpcDealer.kill_process(patient_pid)
  FileUtils.rm_rf tmp_dir
  Timeout.timeout(3) do
    while (
      AcpcDealer.process_exists?(redis_pid) ||
      AcpcDealer.process_exists?(patient_pid)
    )
      sleep 0.1
    end
  end
  Process.wait
end
MiniTest.after_run { my_teardown(tmp_dir, config_file, redis_pid, patient_pid) }

describe 'exe/acpc_table_manager' do
  let(:game) { 'two_player_nolimit' }
  let(:random_seed) { 9001 }

  before do
    AcpcTableManager.unload!
    File.exist?(config_file).must_equal true
    AcpcTableManager.load! config_file
    AcpcDealer.process_exists?(redis_pid).must_equal true
    AcpcDealer.process_exists?(patient_pid).must_equal true
  end

  def match_name(players)
    AcpcTableManager.match_name(
      game_def_key: game,
      players: players,
      time: false
    )
  end

  it 'works' do
    players = ['TestingBot', 'Proxy']
    redis = Redis.new
    redis.publish(
      'table-manager',
      {'game_def_key' => game, 'players': players, 'random_seed': random_seed}
    )
    sleep 2
    running_matches = AcpcTableManager.running_matches(game)
    running_matches.length.must_equal 1
    match = running_matches.first

    AcpcDealer.process_exists?(match[:dealer][:pid]).must_equal true
    match[:name].must_match(/^#{match_name(players)}/)
    match[:dealer][:port_numbers].length.must_equal players.length
    match[:dealer][:log_directory].must_equal AcpcTableManager.config.match_log_directory
    match[:players].length.must_equal players.length
    match[:players].each_with_index do |player, i|
      player[:name].must_equal players[i]
      player[:pid].must_be :>, 0
      AcpcDealer.process_exists?(player[:pid]).must_equal true
      # todo
      AcpcDealer.kill_process player[:pid]
      Timeout.timeout(3) do
        while AcpcDealer.process_exists?(player[:pid])
          sleep 0.1
        end
      end
    end
  end
end
