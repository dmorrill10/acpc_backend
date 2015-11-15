require 'support/spec_helper'

require 'acpc_backend/utils'

describe AcpcBackend do
  describe '#resolve_path' do
    it 'converts a path relative to this file to an absolute path' do
      AcpcBackend.resolve_path('test_file', __FILE__).must_equal File.expand_path('test_file', __FILE__)
    end
  end
  describe '#interpolate_all_strings' do
    it 'interpolates a string' do
      AcpcBackend.interpolate_all_strings(
        '%{pwd}/test_file',
        { pwd: File.dirname(__FILE__) }
      ).must_equal File.expand_path('../test_file', __FILE__)
    end
    it 'interpolates a shallow array' do
      AcpcBackend.interpolate_all_strings(
        [
          '%{pwd}/test_file',
          '%{pwd}/test_file2'
        ],
        { pwd: File.dirname(__FILE__) }
      ).must_equal(
        [
          File.expand_path('../test_file', __FILE__),
          File.expand_path('../test_file2', __FILE__)
        ]
      )
    end
    it 'interpolates a shallow hash' do
      AcpcBackend.interpolate_all_strings(
        {
          a: '%{pwd}/test_file',
          b: '%{pwd}/test_file2'
        },
        { pwd: File.dirname(__FILE__) }
      ).must_equal(
        {
          a: File.expand_path('../test_file', __FILE__),
          b: File.expand_path('../test_file2', __FILE__)
        }
      )
    end
    it 'interpolates a deep hash' do
      AcpcBackend.interpolate_all_strings(
        {
          a: {
            a2: '%{pwd}/test_file',
          },
          b: {
            b2: '%{pwd}/test_file2'
          }
        },
        { pwd: File.dirname(__FILE__) }
      ).must_equal(
        {
          a: {
            a2: File.expand_path('../test_file', __FILE__),
          },
          b: {
            b2: File.expand_path('../test_file2', __FILE__)
          }
        }
      )
    end
    it 'interpolates a deep hash with a deep array' do
      AcpcBackend.interpolate_all_strings(
        {
          a: {
            a2: '%{pwd}/test_file',
            a3: [
              '%{pwd}/test_file3',
              [
                '%{pwd}/test_file4'
              ]
            ]
          },
          b: {
            b2: '%{pwd}/test_file2'
          },
          c: '%{pwd}/test_file5'
        },
        { pwd: File.dirname(__FILE__) }
      ).must_equal(
        {
          a: {
            a2: File.expand_path('../test_file', __FILE__),
            a3: [
              File.expand_path('../test_file3', __FILE__),
              [
                File.expand_path('../test_file4', __FILE__)
              ]
            ]
          },
          b: {
            b2: File.expand_path('../test_file2', __FILE__)
          },
          c: File.expand_path('../test_file5', __FILE__)
        }
      )
    end
  end
end
