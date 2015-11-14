require 'socket'
require 'json'
require 'mongoid'
require 'moped'
require 'rusen'
require 'contextual_exceptions'

require_relative 'simple_logging'
using SimpleLogging::MessageFormatting

require_relative 'utils'

module AcpcBackend
  module ExhibitionConstants
  end

  class UninitializedError < StandardError
    include ContextualExceptions::ContextualError
  end

  THIS_MACHINE = Socket.gethostname
  DEALER_HOST = THIS_MACHINE

  @@is_initialized = false

  def self.read_config(config_data, yaml_directory)
    interpolation_hash = { pwd: yaml_directory, home: Dir.home, :~ => Dir.home }

    final_data = config_data.dup

    config_data['paths'].each do |k, v|
      final_data['paths'][k] = resolve_path(v % interpolation_hash, yaml_directory).to_s
    end
    final_data
  end

  def self.read_config_file(config_file_path)
    read_config YAML.load_file(config_file_path), File.dirname(config_file_path)
  end

  def self.load!(config_file)
    config = read_config_file config_file
    CONSTANTS_FILE = config['paths']['table_manager_constants']

    JSON.parse(File.read(CONSTANTS_FILE)).each do |constant, val|
      self.const_set(constant, val) unless const_defined? constant
    end

    MONGOID_CONFIG = config['paths']['mongoid_config']
    MONGOID_ENV = config['mongoid_env'].to_sym
    LOG_DIRECTORY = config['paths']['log_directory']
    MATCH_LOG_DIRECTORY = config['paths']['match_log_directory']
    MY_LOG_DIRECTORY = File.join(LOG_DIRECTORY, 'acpc_backend')

    self::ExhibitionConstants.const_set('CONSTANTS_FILE', config['paths']['exhibition_constants'])
    JSON.parse(File.read(self::ExhibitionConstants::CONSTANTS_FILE)).each do |constant, val|
      self::ExhibitionConstants.const_set(constant, val) unless const_defined? constant
    end

    # Mongoid
    Mongoid.logger = Logger.from_file_name(File.join(LOG_DIRECTORY, 'mongoid.log'))
    Moped.logger = Logger.from_file_name(File.join(LOG_DIRECTORY, 'moped.log'))
    Mongoid.load!(MONGOID_CONFIG, MONGOID_ENV)

    # Rusen
    if config['error_report']
      Rusen.settings.sender_address = config['error_report']['sender']
      Rusen.settings.exception_recipients = config['error_report']['recipients']

      Rusen.settings.outputs = config['error_report']['outputs'] || [:email]
      Rusen.settings.sections = config['error_report']['sections'] || [:backtrace]
      Rusen.settings.email_prefix = config['error_report']['email_prefix'] || '[ERROR] '
      Rusen.settings.smtp_settings = config['error_report']['smtp']
    end

    @@is_initialized = true
  end

  def self.notify(exception)
    Rusen.notify exception
  end

  def self.initialized?
    @@is_initialized
  end

  def self.raise_if_uninitialized
    raise UninitializedError.new(
      "Unable to complete with AcpcBackend uninitialized. Please initialize AcpcBackend with configuration settings by calling AcpcBackend.load! with a (YAML) configuration file name."
    ) unless initialized?
  end

  def self.new_log(log_file_name)
    raise_if_uninitialized
    Logger.from_file_name(File.join(MY_LOG_DIRECTORY, log_file_name)).with_metadata!
  end
end
