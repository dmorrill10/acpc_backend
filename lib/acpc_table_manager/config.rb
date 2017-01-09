require 'socket'
require 'json'
require 'fileutils'

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

    attr_reader(
      :file,
      :log_directory,
      :my_log_directory,
      :match_log_directory,
      :data_directory
    )

    def initialize(
        file_path,
        log_directory_,
        match_log_directory_,
        data_directory_,
        interpolation_hash
    )
      @file = file_path
      JSON.parse(File.read(file_path)).each do |constant, val|
        define_singleton_method(constant.to_sym) do
          ::AcpcTableManager.interpolate_all_strings(val, interpolation_hash)
        end
      end
      @log_directory = log_directory_
      @match_log_directory = match_log_directory_
      @my_log_directory = File.join(@log_directory, 'acpc_table_manager')
      @logger = Logger.from_file_name(File.join(@my_log_directory, 'table_manager.log'))
      @data_directory = data_directory_
      FileUtils.mkdir_p @data_directory unless File.directory?(@data_directory)
    end

    def this_machine() THIS_MACHINE end
    def dealer_host() DEALER_HOST end
  end

  class ExhibitionConfig < NilDefaultConfig
    include SimpleLogging

    attr_reader :file

    def initialize(
      file_path,
      interpolation_hash,
      logger = Logger.new(STDOUT)
    )
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
          log(
            __method__, {warning: "Game '#{game_def_key}' has no opponents."},
            Logger::Severity::WARN
          )
          {}
        end
      else
        log(
          __method__, {warning: "Unrecognized game, '#{game_def_key}'."},
          Logger::Severity::WARN
        )
        {}
      end
    end
  end
end
