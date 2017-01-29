# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'acpc_table_manager/version'

Gem::Specification.new do |spec|
  spec.name          = "acpc_table_manager"
  spec.version       = AcpcTableManager::VERSION
  spec.authors       = ["Dustin Morrill"]
  spec.email         = ["dmorrill10@gmail.com"]

  spec.summary       = %q{Backend components to the ACPC Poker GUI Client}
  spec.description   = %q{Backend components to the ACPC Poker GUI Client. Includes a player that saves states from the dealer to persistent storage, and components to start, stop, and manage match components.}
  spec.homepage      = "https://github.com/dmorrill10/acpc_table_manager"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # To send emails
  spec.add_dependency "pony", '~> 1.11'

  # For message passing
  spec.add_dependency 'redis', '~> 3.3'

  # For poker logic
  spec.add_dependency "acpc_poker_types", '~> 7.8'
  spec.add_dependency 'acpc_dealer', '~> 3.1'
  spec.add_dependency 'acpc_poker_player_proxy', '~> 1.6'

  # Simple exception email notifications
  spec.add_dependency 'rusen', '~> 0.1'

  # For better errors
  spec.add_dependency 'contextual_exceptions', '~> 0.0'

  # For better logging
  spec.add_dependency 'awesome_print', '~> 1.7'

  # For sanitizing file names
  spec.add_dependency 'zaru', '~> 0.1'

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest", '~> 5.10'
  spec.add_development_dependency "pry", '~> 0.10'
end
