$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'minitest/autorun'
require 'minitest/spec'

require 'mocha/mini_test'

begin
  require 'awesome_print'
  module Minitest::Assertions
    def mu_pp(obj)
      obj.awesome_inspect
    end
  end
rescue LoadError
end
