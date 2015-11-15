require 'support/spec_helper'

require 'acpc_backend'

describe AcpcBackend do
  it 'has a version number' do
    ::AcpcBackend::VERSION.wont_be_nil
  end
end
