require 'support/spec_helper'
require 'acpc_table_manager'
require 'json'

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
  FileUtils.rm_rf tmp_dir if File.directory?(tmp_dir)
  FileUtils.mkdir_p tmp_dir
  config_file = File.join(tmp_dir, 'config.yml')
  File.open(config_file, 'w') do |f|
    f.puts YAML.dump(CONFIG_DATA)
  end
  redis_pid = begin
    AcpcTableManager.new_redis_connection.ping
  rescue Redis::CannotConnectError
    STDERR.puts "WARNING: Default redis server had to be started before the test."
    Process.spawn('redis-server')
  else
    nil
  end
  patient_pid = Process.spawn(
    "#{File.join(PWD, '..', 'exe', 'acpc_table_manager')} -t #{config_file}"
  )
  sleep 0.5
  return tmp_dir, config_file, redis_pid, patient_pid
end
tmp_dir, config_file, redis_pid, patient_pid = my_setup

def my_teardown(tmp_dir, config_file, redis_pid, patient_pid)
  AcpcDealer.kill_process(redis_pid) if redis_pid
  AcpcDealer.kill_process(patient_pid)
  FileUtils.rm_rf tmp_dir
  begin
    Timeout.timeout(3) do
      while (
        (redis_pid && AcpcDealer.process_exists?(redis_pid)) ||
        AcpcDealer.process_exists?(patient_pid)
      )
        sleep 0.1
      end
    end
  rescue Timeout::Error # @todo Necessary for TravisCI for some reason
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
    AcpcDealer.process_exists?(redis_pid).must_equal(true) if redis_pid
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
    proxy_name = 'Proxy'
    players = ['TestingBot', proxy_name]
    redis = AcpcTableManager.new_redis_connection
    redis.publish(
      'table-manager',
      {'game_def_key' => game, 'players' => players, 'random_seed' => random_seed}.to_json
    )
    sleep 0.5
    running_matches = AcpcTableManager.running_matches(game)
    running_matches.length.must_equal 1
    match = running_matches.first
    name = match[:name]

    log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.log")
    File.exist?(log_file).must_equal true
    actions_log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.actions.log")
    File.exist?(actions_log_file).must_equal true

    AcpcDealer.process_exists?(match[:dealer][:pid]).must_equal true
    match[:name].must_match(/^#{match_name(players)}/)
    match[:dealer][:port_numbers].length.must_equal players.length
    match[:dealer][:log_directory].must_equal AcpcTableManager.config.match_log_directory
    match[:players].length.must_equal players.length

    match[:players].each_with_index do |player, i|
      player[:name].must_equal players[i]
      player[:pid].must_be :>, 0
      AcpcDealer.process_exists?(player[:pid]).must_equal true
    end

    to_channel = "#{AcpcTableManager.player_id(name, proxy_name, 1)}-to-proxy"

    proxy_pid = match[:players][1][:pid]
    loop do
      redis.publish to_channel, {AcpcTableManager.config.action_key => 'c'}.to_json
      sleep 0.001
      break unless AcpcDealer.process_exists?(proxy_pid)
      redis.publish to_channel, {AcpcTableManager.config.action_key => 'r1'}.to_json
      sleep 0.001
      break unless AcpcDealer.process_exists?(proxy_pid)
      redis.publish to_channel, {AcpcTableManager.config.action_key => 'f'}.to_json
      sleep 0.001
      break unless AcpcDealer.process_exists?(proxy_pid)
    end
    sleep 0.001

    match[:players].each_with_index do |player, i|
      AcpcDealer.process_exists?(player[:pid]).must_equal false
      if AcpcDealer.process_exists?(player[:pid])
        AcpcDealer.kill_process player[:pid]
        Timeout.timeout(3) do
          while AcpcDealer.process_exists?(player[:pid])
            sleep 0.1
          end
        end
      end
    end
    AcpcDealer.process_exists?(match[:dealer][:pid]).must_equal false
    if AcpcDealer.process_exists?(match[:dealer][:pid])
      AcpcDealer.kill_process match[:dealer][:pid]
      Timeout.timeout(3) do
        while AcpcDealer.process_exists?(match[:dealer][:pid])
          sleep 0.1
        end
      end
    end
  end
end
