$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'minitest/autorun'
require 'minitest/spec'

begin
  require 'awesome_print'
  module Minitest::Assertions
    def mu_pp(obj)
      obj.awesome_inspect
    end
  end
rescue LoadError
end
