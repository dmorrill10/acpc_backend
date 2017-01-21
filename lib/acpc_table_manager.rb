require 'contextual_exceptions'
require 'rusen'
require 'acpc_dealer'
require 'acpc_poker_types'
require 'redis'
require 'timeout'
require 'zaru'
require 'shellwords'
require 'yaml'

require_relative 'acpc_table_manager/version'
require_relative 'acpc_table_manager/config'
require_relative 'acpc_table_manager/monkey_patches'
require_relative 'acpc_table_manager/simple_logging'
require_relative 'acpc_table_manager/utils'
require_relative 'acpc_table_manager/proxy_utils'

using AcpcTableManager::SimpleLogging::MessageFormatting

module AcpcTableManager
  class UninitializedError < StandardError
    include ContextualExceptions::ContextualError
  end
  class NoPortForDealerAvailable < StandardError
    include ContextualExceptions::ContextualError
  end
  class MatchAlreadyEnqueued < StandardError
    include ContextualExceptions::ContextualError
  end
  class NoBotRunner < StandardError
    include ContextualExceptions::ContextualError
  end
  class RequiresTooManySpecialPorts < StandardError
    include ContextualExceptions::ContextualError
  end
  class SubscribeTimeout < StandardError
    include ContextualExceptions::ContextualError
  end

  class CommunicatorComponent
    attr_reader :channel
    def initialize(id)
      @channel = self.class.channel_from_id(id)
      @redis = AcpcTableManager.new_redis_connection()
    end
  end

  class Receiver < CommunicatorComponent
    def subscribe_with_timeout
      list, message = @redis.blpop(
        @channel,
        timeout: AcpcTableManager.config.maintenance_interval_s
      )
      if message
        yield JSON.parse(message)
      else
        raise SubscribeTimeout
      end
    end
  end

  class TableManagerReceiver < Receiver
    def self.channel_from_id(id) id end
  end

  class Sender < CommunicatorComponent
    def self.channel_from_id(id) "#{id}-from-proxy" end
    def publish(data)
      @redis.rpush @channel, data
      @redis.publish @channel, data
    end
    def del() @redis.del @channel end
  end

  class ProxyReceiver < Receiver
    def self.channel_from_id(id) "#{id}-to-proxy" end
  end

  class ProxyCommunicator
    def initialize(id)
      @sender = Sender.new(id)
      @receiver = ProxyReceiver.new(id)
    end
    def publish(data) @sender.publish(data) end
    def subscribe_with_timeout
      @receiver.subscribe_with_timeout { |on| yield on }
    end
    def send_channel() @sender.channel end
    def receive_channel() @receiver.channel end
    def del_saved() @sender.del end
  end

  module TimeRefinement
    refine Time.class() do
      def now_as_string
        now.strftime('%b%-d_%Y-at-%-H_%-M_%-S')
      end
    end
  end
  using AcpcTableManager::TimeRefinement

  def self.shell_sanitize(string)
    Zaru.sanitize!(Shellwords.escape(string.gsub(/\s+/, '_')))
  end

  def self.raise_uninitialized
    raise UninitializedError.new(
      "Unable to complete with AcpcTableManager uninitialized. Please initialize AcpcTableManager with configuration settings by calling AcpcTableManager.load! with a (YAML) configuration file name."
    )
  end

  @@config = nil

  def self.config
    if @@config
      @@config
    else
      raise_uninitialized
    end
  end

  @@exhibition_config = nil
  def self.exhibition_config
    if @@exhibition_config
      @@exhibition_config
    else
      raise_uninitialized
    end
  end

  @@is_initialized = false

  @@redis_config_file = nil
  def self.redis_config_file() @@redis_config_file end

  @@config_file = nil
  def self.config_file() @@config_file end

  @@notifier = nil
  def self.notifier() @@notifier end

  def self.load_config!(config_data, yaml_directory = File.pwd)
    interpolation_hash = {
      pwd: yaml_directory,
      home: Dir.home,
      :~ => Dir.home,
      dealer_directory: AcpcDealer::DEALER_DIRECTORY
    }
    config = interpolate_all_strings(config_data, interpolation_hash)
    interpolation_hash[:pwd] = File.dirname(config['table_manager_constants'])

    @@config = Config.new(
      config['table_manager_constants'],
      config['log_directory'],
      config['match_log_directory'],
      config['data_directory'],
      interpolation_hash
    )

    interpolation_hash[:pwd] = File.dirname(config['exhibition_constants'])
    @@exhibition_config = ExhibitionConfig.new(
      config['exhibition_constants'],
      interpolation_hash,
      Logger.from_file_name(File.join(@@config.my_log_directory, 'exhibition_config.log'))
    )

    if config['error_report']
      Rusen.settings.sender_address = config['error_report']['sender']
      Rusen.settings.exception_recipients = config['error_report']['recipients']

      Rusen.settings.outputs = config['error_report']['outputs'] || [:pony]
      Rusen.settings.sections = config['error_report']['sections'] || [:backtrace]
      Rusen.settings.email_prefix = config['error_report']['email_prefix'] || '[ERROR] '
      Rusen.settings.smtp_settings = config['error_report']['smtp']

      @@notifier = Rusen
    else
      @@config.log(
        __method__,
        {
          warning: "Email reporting disabled. Please set email configuration to enable this feature."
        },
        Logger::Severity::WARN
      )
    end
    @@redis_config_file = config['redis_config_file'] || 'default'

    FileUtils.mkdir(opponents_log_dir) unless File.directory?(opponents_log_dir)

    @@is_initialized = true

    @@exhibition_config.games.keys.each do |game|
      d = data_directory(game)
      FileUtils.mkdir_p d  unless File.directory?(d)
      q = enqueued_matches_file(game)
      FileUtils.touch q unless File.exist?(q)
      r = running_matches_file(game)
      FileUtils.touch r unless File.exist?(r)
    end
  end

  def self.new_redis_connection(options = {})
    if @@redis_config_file && @@redis_config_file != 'default'
      redis_config = YAML.load_file(@@redis_config_file).symbolize_keys
      options.merge!(redis_config[:default].symbolize_keys)
      Redis.new(
        if config['redis_environment_mode'] && redis_config[config['redis_environment_mode'].to_sym]
          options.merge(redis_config[config['redis_environment_mode'].to_sym].symbolize_keys)
        else
          options
        end
      )
    else
      Redis.new options
    end
  end

  def self.load!(config_file_path)
    @@config_file = config_file_path
    load_config! YAML.load_file(config_file_path), File.dirname(config_file_path)
  end

  def self.notify(exception)
    @@notifier.notify(exception) if @@notifier
  end

  def self.initialized?
    @@is_initialized
  end

  def self.raise_if_uninitialized
    raise_uninitialized unless initialized?
  end

  def self.new_log(log_file_name, log_directory_ = nil)
    raise_if_uninitialized
    log_directory_ ||= @@config.my_log_directory
    FileUtils.mkdir_p(log_directory_) unless File.directory?(log_directory_)
    Logger.from_file_name(File.join(log_directory_, log_file_name)).with_metadata!
  end

  def self.unload!
    @@is_initialized = false
  end

  def self.opponents_log_dir
    File.join(AcpcTableManager.config.log_directory, 'opponents')
  end

  def self.data_directory(game = nil)
    raise_if_uninitialized
    if game
      File.join(@@config.data_directory, shell_sanitize(game))
    else
      @@config.data_directory
    end
  end

  def self.enqueued_matches_file(game)
    File.join(data_directory(game), 'enqueued_matches.yml')
  end

  def self.running_matches_file(game)
    File.join(data_directory(game), 'running_matches.yml')
  end

  def self.enqueued_matches(game)
    YAML.load_file(enqueued_matches_file(game)) || []
  end

  def self.running_matches(game)
    saved_matches = YAML.load_file(running_matches_file(game))
    return [] unless saved_matches

    checked_matches = []
    saved_matches.each do |match|
      if AcpcDealer::process_exists?(match[:dealer][:pid])
        checked_matches << match
      end
    end
    if checked_matches.length != saved_matches.length
      update_running_matches game, checked_matches
    end
    checked_matches
  end

  def self.sanitized_player_names(names)
    names.map { |name| Shellwords.escape(name.gsub(/\s+/, '_')) }
  end

  def self.match_name(players: nil, game_def_key: nil, time: true)
    name = "match"
    name += ".#{sanitized_player_names(players).join('.')}" if players
    if game_def_key
      name += ".#{game_def_key}.#{exhibition_config.games[game_def_key]['num_hands_per_match']}h"
    end
    name += ".#{Time.now_as_string}" if time
    shell_sanitize name
  end

  def self.dealer_arguments(game, name, players, random_seed)
    {
      match_name: shell_sanitize(name),
      game_def_file_name: Shellwords.escape(
        exhibition_config.games[game]['file']
      ),
      hands: Shellwords.escape(
        exhibition_config.games[game]['num_hands_per_match']
      ),
      random_seed: Shellwords.escape(random_seed.to_s),
      player_names: sanitized_player_names(players).join(' '),
      options: exhibition_config.dealer_options.join(' ')
    }
  end

  def self.proxy_player?(player_name, game_def_key)
    exhibition_config.games[game_def_key]['opponents'][player_name].nil?
  end

  def self.start_dealer(game, name, players, random_seed, port_numbers)
    config.log __method__, name: name
    args = dealer_arguments game, name, players, random_seed

    config.log __method__, {
      dealer_arguments: args,
      log_directory: ::AcpcTableManager.config.match_log_directory,
      port_numbers: port_numbers,
      command: AcpcDealer::DealerRunner.command(
        args,
        port_numbers
      )
    }

    Timeout::timeout(3) do
      AcpcDealer::DealerRunner.start(
        args,
        config.match_log_directory,
        port_numbers
      )
    end
  end

  def self.start_proxy(game, proxy_id, port, seat)
    config.log __method__, msg: "Starting proxy"

    args = [
      "-t #{config_file}",
      "-i #{proxy_id}",
      "-p #{port}",
      "-s #{seat}",
      "-g #{game}"
    ]
    command = "#{File.expand_path('../../exe/acpc_proxy', __FILE__)} #{args.join(' ')}"
    start_process command
  end

  # @todo This method looks broken
  # def self.bots(game_def_key, player_names, dealer_host)
  #   bot_info_from_config_that_match_opponents = exhibition_config.bots(
  #     game_def_key,
  #     *opponent_names(player_names)
  #   )
  #   bot_opponent_ports = opponent_ports_with_condition do |name|
  #     bot_info_from_config_that_match_opponents.keys.include? name
  #   end
  #
  #   raise unless (
  #     port_numbers.length == player_names.length ||
  #     bot_opponent_ports.length == bot_info_from_config_that_match_opponents.length
  #   )
  #
  #   bot_opponent_ports.zip(
  #     bot_info_from_config_that_match_opponents.keys,
  #     bot_info_from_config_that_match_opponents.values
  #   ).reduce({}) do |map, args|
  #     port_num, name, info = args
  #     map[name] = {
  #       runner: (if info['runner'] then info['runner'] else info end),
  #       host: dealer_host, port: port_num
  #     }
  #     map
  #   end
  # end

  # @return [Integer] PID of the bot started
  def self.start_bot(id, bot_info, port)
    runner = bot_info['runner'].to_s
    if runner.nil? || runner.strip.empty?
      raise NoBotRunner, %Q{Bot "#{id}" with info #{bot_info} has no runner.}
    end
    args = [runner, config.dealer_host.to_s, port.to_s]
    log_file = File.join(opponents_log_dir, "#{id}.log")
    command_to_run = args.join(' ')

    config.log(
      __method__,
      {
        starting_bot: id,
        args: args,
        log_file: log_file
      }
    )
    start_process command_to_run, log_file
  end

  def self.enqueue_match(game, players, seed)
    sanitized_name = match_name(
      game_def_key: game,
      players: players,
      time: true
    )
    enqueued_matches_ = enqueued_matches game
    if enqueued_matches_.any? { |e| e[:name] == sanitized_name }
      raise(
        MatchAlreadyEnqueued,
        %Q{Match "#{sanitized_name}" already enqueued.}
      )
    end
    enqueued_matches_ << (
      {
        name: sanitized_name,
        game_def_key: game,
        players: sanitized_player_names(players),
        random_seed: seed
      }
    )
    update_enqueued_matches game, enqueued_matches_
  end

  def self.player_id(game, player_name, seat)
    shell_sanitize(
      "#{match_name(game_def_key: game, players: [player_name], time: false)}.#{seat}"
    )
  end

  def self.available_special_ports(ports_in_use)
    if exhibition_config.special_ports_to_dealer
      exhibition_config.special_ports_to_dealer - ports_in_use
    else
      []
    end
  end

  def self.next_special_port(ports_in_use)
    available_ports_ = available_special_ports(ports_in_use)
    port_ = available_ports_.pop
    until port_.nil? || AcpcDealer.port_available?(port_)
      port_ = available_ports_.pop
    end
    unless port_
      raise NoPortForDealerAvailable, "None of the available special ports (#{available_special_ports(ports_in_use)}) are open."
    end
    port_
  end

  def self.start_matches_if_allowed(game = nil)
    if game
      running_matches_ = running_matches(game)
      skipped_matches = []
      enqueued_matches_ = enqueued_matches(game)
      start_matches_in_game_if_allowed(
        game,
        running_matches_,
        skipped_matches,
        enqueued_matches_
      )
      unless enqueued_matches_.empty? && skipped_matches.empty?
        update_enqueued_matches game, skipped_matches + enqueued_matches_
      end
    else
      exhibition_config.games.keys.each do |game|
        start_matches_if_allowed game
      end
    end
  end

  def self.update_enqueued_matches(game, enqueued_matches_)
    write_yml enqueued_matches_file(game), enqueued_matches_
  end

  def self.update_running_matches(game, running_matches_)
    write_yml running_matches_file(game), running_matches_
  end

  def self.start_match(
    game,
    name,
    players,
    seed,
    port_numbers
  )
    dealer_info = start_dealer(
      game,
      name,
      players,
      seed,
      port_numbers
    )
    port_numbers = dealer_info[:port_numbers]

    player_info = []
    players.each_with_index do |player_name, i|
      player_info << (
        {
          name: player_name,
          pid: (
            if exhibition_config.games[game]['opponents'][player_name]
              start_bot(
                player_id(game, player_name, i),
                exhibition_config.games[game]['opponents'][player_name],
                port_numbers[i]
              )
            else
              start_proxy(
                game,
                player_id(game, player_name, i),
                port_numbers[i],
                i
              )
            end
          )
        }
      )
    end
    return dealer_info, player_info
  end

  def self.allocate_ports(players, game, ports_in_use)
    num_special_ports_for_this_match = 0
    max_num_special_ports = if exhibition_config.special_ports_to_dealer.nil?
      0
    else
      exhibition_config.special_ports_to_dealer.length
    end
    players.map do |player|
      bot_info = exhibition_config.games[game]['opponents'][player]
      if bot_info && bot_info['requires_special_port']
        num_special_ports_for_this_match += 1
        if num_special_ports_for_this_match > max_num_special_ports
          raise(
            RequiresTooManySpecialPorts,
            %Q{At least #{num_special_ports_for_this_match} special ports are required but only #{max_num_special_ports} ports were declared.}
          )
        end
        special_port = next_special_port(ports_in_use)
        ports_in_use << special_port
        special_port
      else
        0
      end
    end
  end

  private

  def self.write_yml(f, obj)
    File.open(f, 'w') { |f| f.write YAML.dump(obj) }
  end

  def self.start_matches_in_game_if_allowed(
    game,
    running_matches_,
    skipped_matches,
    enqueued_matches_
  )
    while running_matches_.length < exhibition_config.games[game]['max_num_matches']
      next_match = enqueued_matches_.shift
      break unless next_match

      ports_in_use = running_matches_.map do |m|
        m[:dealer][:port_numbers]
      end.flatten

      begin
        port_numbers = allocate_ports(next_match[:players], game, ports_in_use)
      rescue NoPortForDealerAvailable => e
        config.log(
          __method__,
          {
            message: e.message,
            backtrace: e.backtrace
          },
          Logger::Severity::WARN
        )
        skipped_matches << next_match
      rescue RequiresTooManySpecialPorts => e
        config.log(
          __method__,
          {
            message: e.message,
            backtrace: e.backtrace
          },
          Logger::Severity::ERROR
        )
      else
        dealer_info, player_info = start_match(
          game,
          next_match[:name],
          next_match[:players],
          next_match[:random_seed],
          port_numbers
        )

        running_matches_.push(
          name: next_match[:name],
          dealer: dealer_info,
          players: player_info
        )
        update_running_matches game, running_matches_
      end
      update_enqueued_matches game, enqueued_matches_
    end
  end

  def self.start_process(command, log_file = nil)
    config.log __method__, running_command: command

    options = {chdir: AcpcDealer::DEALER_DIRECTORY}
    if log_file
      options[[:err, :out]] = [log_file, File::CREAT|File::WRONLY|File::APPEND]
    end

    pid = Timeout.timeout(3) do
      pid = Process.spawn(command, options)
      Process.detach(pid)
      pid
    end

    config.log __method__, ran_command: command, pid: pid

    pid
  end
end
