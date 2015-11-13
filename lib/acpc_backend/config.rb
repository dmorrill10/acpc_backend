require 'socket'
require 'json'
require 'mongoid'
require 'moped'
require 'rusen'
require_relative 'simple_logging'
require_relative 'utils'

module AcpcBackend
  module ExhibitionConstants
  end

  THIS_MACHINE = Socket.gethostname
  DEALER_HOST = THIS_MACHINE

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
    self.const_set('CONSTANTS_FILE', config['paths']['table_manager_constants'])

    JSON.parse(File.read(CONSTANTS_FILE)).each do |constant, val|
      self.const_set(constant, val) unless const_defined? constant
    end

    self.const_set('MONGOID_CONFIG', config['paths']['mongoid_config'])
    self.const_set('MONGOID_ENV', config['mongoid_env'].to_sym)
    self.const_set('LOG_DIRECTORY', config['paths']['log_directory'])
    self.const_set('MATCH_LOG_DIRECTORY', config['paths']['match_log_directory'])

    self::ExhibitionConstants.const_set('CONSTANTS_FILE', config['paths']['exhibition_constants'])
    JSON.parse(File.read(self::ExhibitionConstants::CONSTANTS_FILE)).each do |constant, val|
      self::ExhibitionConstants.const_set(constant, val) unless const_defined? constant
    end

    # Mongoid
    Mongoid.logger = Logger.from_file_name(File.join(LOG_DIRECTORY, 'mongoid.log'))
    Moped.logger = Logger.from_file_name(File.join(LOG_DIRECTORY, 'moped.log'))
    Mongoid.load!(MONGOID_CONFIG, MONGOID_ENV)

    # Rusen
# Rusen.settings.outputs = [:email]
# Rusen.settings.sections = [:backtrace]
# Rusen.settings.email_prefix = '[ERROR] '
# Rusen.settings.sender_address = 'sender@example.com'
# Rusen.settings.exception_recipients = %w(receiver@example.com)
# Rusen.settings.smtp_settings = {
#   :address              => 'smtp.gmail.com',
#   :port                 => 587,
#   :domain               => 'example.com',
#   :authentication       => :plain,
#   :user_name            => 'sender@example.com',
#   :password             => '********',
#   :enable_starttls_auto => true
# }
  end
end
