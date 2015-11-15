require 'acpc_dealer'
require 'timeout'

require_relative 'config'
require_relative 'match'

require_relative 'simple_logging'

module AcpcBackend
module Dealer
  extend SimpleLogging

  @logger = nil

  # @return [Hash<Symbol, Object>] The dealer information
  # @note Saves the actual port numbers used by the dealer instance in +match+
  def self.start(options, match, port_numbers: nil)
    @logger ||= ::AcpcBackend.new_log 'dealer.log'
    log __method__, options: options

    dealer_arguments = {
      match_name: Shellwords.escape(match.name.gsub(/\s+/, '_')),
      game_def_file_name: Shellwords.escape(match.game_definition_file_name),
      hands: Shellwords.escape(match.number_of_hands),
      random_seed: Shellwords.escape(match.random_seed.to_s),
      player_names: match.player_names.map { |name| Shellwords.escape(name.gsub(/\s+/, '_')) }.join(' '),
      options: (options.split(' ').map { |o| Shellwords.escape o }.join(' ') || '')
    }

    log __method__, {
      match_id: match.id,
      dealer_arguments: dealer_arguments,
      log_directory: ::AcpcBackend::MATCH_LOG_DIRECTORY,
      port_numbers: port_numbers
    }

    # Start the dealer
    dealer_info = Timeout::timeout(3) do
      AcpcDealer::DealerRunner.start(
        dealer_arguments,
        ::AcpcBackend::MATCH_LOG_DIRECTORY,
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
