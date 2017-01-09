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
require_relative 'acpc_table_manager/proxy'
require_relative 'acpc_table_manager/simple_logging'
require_relative 'acpc_table_manager/utils'

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
    YAML.load_file(running_matches_file(game)) || []
  end

  def self.start_dealer(match_info)
    config.log(
      __method__,
      msg: "Starting dealer for match \"#{match_info['name']}\".",
    )

    dealer_arguments = {
      match_name: shell_sanitize(match_info['name'],
      game_def_file_name: Shellwords.escape(
        exhibition_config.games[match_info['game_def_key']]['file']
      ),
      hands: Shellwords.escape(match_info['number_of_hands']),
      random_seed: Shellwords.escape(match_info['random_seed'].to_s),
      player_names: match['players'].map do |player|
        Shellwords.escape(player['name'].gsub(/\s+/, '_'))
      end.join(' '),
      options: match['dealer_options']
    }

    port_numbers = match_info['players'].map do |player|
      player['port']
    end

    config.log __method__, {
      dealer_arguments: dealer_arguments,
      log_directory: ::AcpcTableManager.config.match_log_directory,
      port_numbers: port_numbers,
      command: AcpcDealer::DealerRunner.command(dealer_arguments, port_numbers)
    }

    Timeout::timeout(3) do
      AcpcDealer::DealerRunner.start(
        dealer_arguments,
        config.match_log_directory,
        port_numbers
      )
    end
  end

  # Move the creation of this command into the match_info message
  def self.start_proxy(proxy_id)
    command = "#{File.expand_path('../../exe/acpc_proxy', __FILE__)} -t #{config_file} -m #{proxy_id}"
    config.log(
      __method__,
      msg: "Starting proxy for \"#{proxy_id}\".",
      command: command
    )

    pid = Timeout.timeout(3) do
      pid = Process.spawn(command)
      Process.detach(pid)
      pid
    end

    config.log(
      __method__,
      msg: "Started proxy for \"#{proxy_id}\".",
      pid: pid
    )
    pid
  end

  def self.start_players(match_info)
    start_opponents match_info
    config.log(
      __method__,
      msg: "Opponents started for \"#{match_info['name']}\"."
    )

    match_info['proxies'].map do |player|
      start_proxy proxy_id(match_info['name'], player)
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

  # @todo Unfinished. Merge with start_proxy.
  # @return [Array<Integer>] PIDs of the opponents started
  def self.start_opponents(match)
    opponents = match.bots(config.dealer_host)
    log __method__, num_opponents: opponents.length

    if opponents.empty?
      raise StandardError.new("No opponents found to start for \"#{match.name}\" (#{match.id.to_s})!")
    end

    opponents_log_dir = File.join(AcpcTableManager.config.log_directory, 'opponents')
    FileUtils.mkdir(opponents_log_dir) unless File.directory?(opponents_log_dir)

    bot_start_commands = opponents.map do |name, info|
      {
        args: [info[:runner], info[:host], info[:port]],
        log: File.join(opponents_log_dir, "#{match.name}.#{match.id}.#{name}.log")
      }
    end

    bot_start_commands.map do |bot_start_command|
      log(
        __method__,
        {
          bot_start_command_parameters: bot_start_command[:args],
          command_to_be_run: bot_start_command[:args].join(' ')
        }
      )
      pid = Timeout::timeout(3) do
        ProcessRunner.go(
          bot_start_command[:args].map { |e| e.to_s },
          {
            [:err, :out] => [bot_start_command[:log], File::CREAT|File::WRONLY]
          }
        )
      end
      log(
        __method__,
        {
          bot_started?: true,
          pid: pid
        }
      )
      pid
    end
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

  def self.proxy_id(match_name, player)
    "#{match_name}.#{player}"
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
          next_match['players'].each do |player|
            if player['requires_special_port']
              player['port'] = next_special_port(ports_in_use)
            else
              player['port'] ||= 0
            end
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
          next
        end

        dealer_info = start_dealer next_match
        proxy_pids = start_players next_match

        proxies = []
        proxy_pids.each_with_index do |pid, i|
          proxies.push(
            name: next_match['proxies'][i],
            pid: pid
          )
        end

        running_matches.push(
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
