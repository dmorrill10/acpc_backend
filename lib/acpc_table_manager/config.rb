require 'socket'
require 'json'
require 'mongoid'
require 'moped'
require 'rusen'
require 'contextual_exceptions'
require 'acpc_dealer'
require 'redis'

require_relative 'simple_logging'
using AcpcTableManager::SimpleLogging::MessageFormatting

require_relative 'utils'

module AcpcTableManager
  class NilDefaultConfig
    def method_missing(sym, *args, &block)
      if respond_to?(sym) then super(sym, *args, &block) else nil end
    end
  end
  class Config < NilDefaultConfig
    include SimpleLogging

    THIS_MACHINE = Socket.gethostname
    DEALER_HOST = THIS_MACHINE

    attr_reader :file, :log_directory, :my_log_directory, :match_log_directory, :proxy_pids_file

    def initialize(file_path, log_directory_, match_log_directory_, proxy_pids_file_, interpolation_hash)
      @file = file_path
      JSON.parse(File.read(file_path)).each do |constant, val|
        define_singleton_method(constant.to_sym) do
          ::AcpcTableManager.interpolate_all_strings(val, interpolation_hash)
        end
      end
      @log_directory = log_directory_
      @match_log_directory = match_log_directory_
      @my_log_directory = File.join(@log_directory, 'acpc_table_manager')
      @proxy_pids_file = proxy_pids_file_
      @logger = Logger.from_file_name(File.join(@my_log_directory, 'config.log'))
    end

    def this_machine() THIS_MACHINE end
    def dealer_host() DEALER_HOST end
  end

  class ExhibitionConfig < NilDefaultConfig
    include SimpleLogging

    attr_reader :file

    def initialize(file_path, interpolation_hash, logger = Logger.new(STDOUT))
      @logger = logger
      @file = file_path
      JSON.parse(File.read(file_path)).each do |constant, val|
        interpolated_val = ::AcpcTableManager.interpolate_all_strings(val, interpolation_hash)
        log(__method__, {adding: {method: constant, value: interpolated_val}})

        instance_variable_set("@#{constant}".to_sym, interpolated_val)
        define_singleton_method(constant.to_sym) do
          instance_variable_get("@#{constant}".to_sym)
        end
      end
      unless special_ports_to_dealer
        @special_ports_to_dealer = []
        log(__method__, {adding: {method: 'special_ports_to_dealer', value: @special_ports_to_dealer}})
        define_singleton_method(:special_ports_to_dealer) do
          instance_variable_get(:@special_ports_to_dealer)
        end
      end
    end

    # @return [Array<Class>] Returns only the names that correspond to bot runner
    #   classes as those classes.
    def bots(game_def_key, *player_names)
      game_def_key = game_def_key.to_s
      if @games[game_def_key]
        if @games[game_def_key]['opponents']
          player_names.reduce({}) do |bot_map, name|
            bot_map[name] = @games[game_def_key]['opponents'][name] if @games[game_def_key]['opponents'][name]
            bot_map
          end
        else
          log(__method__, {warning: "Game '#{game_def_key}' has no opponents."}, Logger::Severity::WARN)
          {}
        end
      else
        log(__method__, {warning: "Unrecognized game, '#{game_def_key}'."}, Logger::Severity::WARN)
        {}
      end
    end
  end

  class UninitializedError < StandardError
    include ContextualExceptions::ContextualError
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
      config['proxy_pids_file'],
      interpolation_hash
    )
    @@exhibition_config = ExhibitionConfig.new(
      config['exhibition_constants'],
      interpolation_hash,
      Logger.from_file_name(File.join(@@config.my_log_directory, 'exhibition_config.log'))
    )

    # Moped.logger = Logger.from_file_name(File.join(@@config.log_directory, 'moped.log'))
    # Mongoid.logger = Logger.from_file_name(File.join(@@config.log_directory, 'mongoid.log'))
    # TODO: These should be set in configuration files
    Moped.logger.level = ::Logger::FATAL
    Mongoid.logger.level = ::Logger::FATAL
    Mongoid.load!(config['mongoid_config'], config['mongoid_env'].to_sym)

    if config['error_report']
      Rusen.settings.sender_address = config['error_report']['sender']
      Rusen.settings.exception_recipients = config['error_report']['recipients']

      Rusen.settings.outputs = config['error_report']['outputs'] || [:pony]
      Rusen.settings.sections = config['error_report']['sections'] || [:backtrace]
      Rusen.settings.email_prefix = config['error_report']['email_prefix'] || '[ERROR] '
      Rusen.settings.smtp_settings = config['error_report']['smtp']

      @@notifier = Rusen
    else
      @@config.log(__method__, {warning: "Email reporting disabled. Please set email configuration to enable this feature."}, Logger::Severity::WARN)
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
end
