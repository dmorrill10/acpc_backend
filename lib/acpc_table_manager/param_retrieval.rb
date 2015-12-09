require_relative 'monkey_patches'
using AcpcTableManager::MonkeyPatches::StringToEnglishExtension

require_relative 'config'

module AcpcTableManager
  module ParamRetrieval
    protected

    # @param [Hash<String, Object>] params Parameter hash
    # @param parameter_key The key of the parameter to be retrieved.
    # @raise
    def retrieve_parameter_or_raise_exception(
      params,
      parameter_key
    )
      raise StandardError.new("nil params hash given") unless params
      retrieved_param = params[parameter_key]
      unless retrieved_param
        raise StandardError.new("No #{parameter_key.to_english} provided")
      end
      retrieved_param
    end

    # @param [Hash<String, Object>] params Parameter hash
    # @raise (see #param)
    def retrieve_match_id_or_raise_exception(params)
      AcpcTableManager.raise_if_uninitialized
      retrieve_parameter_or_raise_exception params, AcpcTableManager.config.match_id_key
    end
  end
end
