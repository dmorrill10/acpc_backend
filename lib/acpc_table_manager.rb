require 'contextual_exceptions'
require 'rusen'
require 'acpc_dealer'
require 'acpc_poker_types'
require 'redis'
require 'timeout'
require 'zaru'

require_relative 'acpc_table_manager/version'
require_relative 'acpc_table_manager/config'
require_relative 'acpc_table_manager/monkey_patches'
require_relative 'acpc_table_manager/simple_logging'
require_relative 'acpc_table_manager/utils'
require_relative 'acpc_table_manager/proxy_utils'

module AcpcTableManager
  class UninitializedError < StandardError
    include ContextualExceptions::ContextualError
  end
  class NoPortForDealerAvailable < StandardError
    include ContextualExceptions::ContextualError
  end

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

  @@redis = nil
  def self.redis() @@redis end

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

    @@config = Config.new(
      config['table_manager_constants'],
      config['log_directory'],
      config['match_log_directory'],
      config['data_directory'],
      interpolation_hash
    )
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

    if config['redis_config_file']
      @@redis_config_file = config['redis_config_file']
      redis_config = YAML.load_file(@@redis_config_file).symbolize_keys
      dflt = redis_config[:default].symbolize_keys
      @@redis = Redis.new(
        if config['redis_environment_mode'] && redis_config[config['redis_environment_mode'].to_sym]
          dflt.merge(redis_config[config['redis_environment_mode'].to_sym].symbolize_keys)
        else
          dflt
        end
      )
    end
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

  def self.new_log(log_file_name)
    raise_if_uninitialized
    Logger.from_file_name(File.join(@@config.my_log_directory, log_file_name)).with_metadata!
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
    File.open(
      running_matches_file(game),
      'w'
    ) do |f|
      f.write YAML.dump(checked_matches)
    end
    checked_matches
  end

  def self.dealer_arguments(match_info)
    {
      match_name: shell_sanitize(match_info['name']),
      game_def_file_name: Shellwords.escape(
        exhibition_config.games[match_info['game_def_key']]['file']
      ),
      hands: Shellwords.escape(
        exhibition_config.games[match_info['game_def_key']]['num_hands_per_match']
      ),
      random_seed: Shellwords.escape(match_info['random_seed'].to_s),
      player_names: (match_info['players'].map do |name|
        Shellwords.escape(name.gsub(/\s+/, '_'))
      end.join(' ')),
      options: exhibition_config.dealer_options
    }
  end

  def self.proxy_player?(player_name, game_def_key)
    exhibition_config.games[game_def_key]['opponents'][player_name].nil?
  end

  def self.start_dealer(match_info, port_numbers)
    config.log(
      __method__,
      msg: "Starting dealer for match \"#{match_info['name']}\"."
    )

    config.log __method__, {
      dealer_arguments: dealer_arguments(match_info),
      log_directory: ::AcpcTableManager.config.match_log_directory,
      port_numbers: port_numbers,
      command: AcpcDealer::DealerRunner.command(
        dealer_arguments(match_info),
        port_numbers
      )
    }

    Timeout::timeout(3) do
      AcpcDealer::DealerRunner.start(
        dealer_arguments(match_info),
        config.match_log_directory,
        port_numbers
      )
    end
  end

  def self.start_process(command, log_file = nil)
    config.log __method__, running_command: command

    options = {}
    if log_file
      options[[:err, :out]] = [log_file, File::CREAT|File::WRONLY]
    end

    pid = Timeout.timeout(3) do
      pid = Process.spawn(command, options)
      Process.detach(pid)
      pid
    end

    config.log __method__, ran_command: command, pid: pid

    pid
  end

  def self.start_proxy(proxy_id, port)
    command = "#{File.expand_path('../../exe/acpc_proxy', __FILE__)} -t #{config_file} -m #{proxy_id} -p #{port}"
    config.log(
      __method__,
      msg: "Starting proxy",
      proxy_id: proxy_id,
      port: port
    )
    start_process command
  end

  def self.start_players(match_info, game_info, port_numbers)
    match_info['players'].each_with_index do |player_name, i|
      if game_info['opponents'][player_name]
        start_bot(
          participant_id(match_info['name'], player_name, i),
          game_info['opponents'][player_name],
          port_numbers[i]
        )
      else
        start_proxy(
          participant_id(match_info['name'], player_name, i),
          port_numbers[i]
        )
      end
    end
  end

  # @todo Test all below methods

  def self.bots(game_def_key, player_names, dealer_host)
    bot_info_from_config_that_match_opponents = exhibition_config.bots(
      game_def_key,
      *opponent_names(player_names)
    )
    bot_opponent_ports = opponent_ports_with_condition do |name|
      bot_info_from_config_that_match_opponents.keys.include? name
    end

    raise unless (
      port_numbers.length == player_names.length ||
      bot_opponent_ports.length == bot_info_from_config_that_match_opponents.length
    )

    bot_opponent_ports.zip(
      bot_info_from_config_that_match_opponents.keys,
      bot_info_from_config_that_match_opponents.values
    ).reduce({}) do |map, args|
      port_num, name, info = args
      map[name] = {
        runner: (if info['runner'] then info['runner'] else info end),
        host: dealer_host, port: port_num
      }
      map
    end
  end

  # @return [Integer] PIDs of the bot started
  def self.start_bot(id, bot_info, port)
    args = [bot_info[:runner].to_s, config.dealer_host.to_s, port.to_s]
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

  def self.enqueue_match(match_info)
    enqueued_matches_ = enqueued_matches(match_info['game_def_key'])
    enqueued_matches_ << match_info
    File.open(
      enqueued_matches_file(match_info['game_def_key']),
      'w'
    ) do |f|
      f.write YAML.dump(enqueued_matches_)
    end
  end

  def self.participant_id(match_name, player, seat)
    shell_sanitize("#{match_name}.#{player}.#{seat}")
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
    until AcpcDealer.port_available?(port_)
      port_ = nil
      break if available_ports_.empty?
      port_ = available_ports_.pop
    end
    unless port_
      raise NoPortForDealerAvailable, "None of the available special ports (#{available_special_ports(ports_in_use)}) are open."
    end
    port_
  end

  def self.start_match_if_allowed
    exhibition_config.games.each do |game, info|
      running_matches_ = running_matches(game)
      skipped_matches = []
      enqueued_matches_ = nil
      while running_matches_.length < info['max_num_matches']
        enqueued_matches_ ||= enqueued_matches(game)
        next_match = enqueued_matches_.shift
        break unless next_match

        ports_in_use = running_matches_.map do |m|
          m[:dealer][:port_numbers]
        end.flatten

        begin
          port_numbers = next_match['players'].map do |player|
            bot_info = info['opponents'][player]
            if bot_info && bot_info['requires_special_port']
              port_numbers << next_special_port(ports_in_use)
            else
              port_numbers << 0
            end
          end

          dealer_info = start_dealer next_match, port_numbers
          proxy_pids = start_players(
            next_match,
            info,
            dealer_info['port_numbers']
          )

          proxies = []
          proxy_pids.each_with_index do |pid, i|
            proxies.push(
              name: next_match['proxies'][i],
              pid: pid
            )
          end

          running_matches_.push(
            name: next_match['name'],
            dealer: dealer_info,
            proxies: proxies
          )
          File.open(started_matches_file(game), 'w') do |f|
            f.write YAML.dump(running_matches_)
          end

          File.open(
            enqueued_matches_file(match_info['game_def_key']),
            'w'
          ) do |f|
            f.write YAML.dump(enqueued_matches_)
          end
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
        end
      end
      unless enqueued_matches_.nil?
        File.open(
          enqueued_matches_file(match_info['game_def_key']),
          'w'
        ) do |f|
          f.write YAML.dump(skipped_matches + enqueued_matches_)
        end
      end
    end
  end
end
