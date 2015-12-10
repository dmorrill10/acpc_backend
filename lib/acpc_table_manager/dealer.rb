require 'acpc_dealer'
require 'timeout'
require 'zaru'

require_relative 'config'
require_relative 'match'

require_relative 'simple_logging'

module AcpcTableManager
module Dealer
  extend SimpleLogging

  @logger = nil

  # @return [Hash<Symbol, Object>] The dealer information
  # @note Saves the actual port numbers used by the dealer instance in +match+
  def self.start(options, match, port_numbers: nil)
    @logger ||= ::AcpcTableManager.new_log 'dealer.log'
    log __method__, options: options, match: match

    dealer_arguments = {
      match_name: Zaru.sanitize!(Shellwords.escape(match.name.gsub(/\s+/, '_'))),
      game_def_file_name: Shellwords.escape(match.game_definition_file_name),
      hands: Shellwords.escape(match.number_of_hands),
      random_seed: Shellwords.escape(match.random_seed.to_s),
      player_names: match.player_names.map { |name| Shellwords.escape(name.gsub(/\s+/, '_')) }.join(' '),
      options: (options.split(' ').map { |o| Shellwords.escape o }.join(' ') || '')
    }

    log __method__, {
      match_id: match.id,
      dealer_arguments: dealer_arguments,
      log_directory: ::AcpcTableManager.config.match_log_directory,
      port_numbers: port_numbers,
      command: AcpcDealer::DealerRunner.command(dealer_arguments, port_numbers)
    }

    dealer_info = Timeout::timeout(3) do
      AcpcDealer::DealerRunner.start(
        dealer_arguments,
        ::AcpcTableManager.config.match_log_directory,
        port_numbers
      )
    end

    match.port_numbers = dealer_info[:port_numbers]
    match.save!

    log __method__, {
      match_id: match.id,
      saved_port_numbers: match.port_numbers
    }

    dealer_info
  end
end
end
