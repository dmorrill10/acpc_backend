require 'pathname'

module AcpcTableManager
  def self.each_key_value_pair(collection)
    # @todo I can't believe this is necessary...
    if collection.is_a?(Array)
      collection.each_with_index { |v, k| yield k, v }
    else
      collection.each { |k, v| yield k, v }
    end
    collection
  end

  def self.resolve_path(path, root = __FILE__)
    path = Pathname.new(path)
    if path.exist?
      path.realpath.to_s
    else
      File.expand_path(path, root)
    end
  end

  def self.interpolate_all_strings(value, interpolation_hash)
    if value.is_a?(String)
      # $VERBOSE and $DEBUG change '%''s behaviour
      _v = $VERBOSE
      $VERBOSE = false
      r = begin
        value % interpolation_hash
      rescue ArgumentError
        value
      end
      $VERBOSE = _v
      r
    elsif value.respond_to?(:each)
      each_key_value_pair(value) do |k, v|
        value[k] = interpolate_all_strings(v, interpolation_hash)
      end
    else
      value
    end
  end
end
