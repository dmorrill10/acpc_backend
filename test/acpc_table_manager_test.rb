require 'support/spec_helper'

require 'acpc_table_manager'

describe AcpcTableManager do
  it 'has a version number' do
    ::AcpcTableManager::VERSION.wont_be_nil
  end
end
