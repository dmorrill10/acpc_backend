# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'acpc_backend/version'

Gem::Specification.new do |spec|
  spec.name          = "acpc_backend"
  spec.version       = AcpcBackend::VERSION
  spec.authors       = ["Dustin Morrill"]
  spec.email         = ["dmorrill10@gmail.com"]

  spec.summary       = %q{Backend components to the ACPC Poker GUI Client}
  spec.description   = %q{Backend components to the ACPC Poker GUI Client. Includes a player that saves states from the dealer to persistent storage, and components to start, stop, and manage match components.}
  spec.homepage      = "TODO: Put your gem's website or public repo URL here."
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "sidekiq"
  spec.add_dependency "mongoid", '~> 5.0.0'
  spec.add_dependency "acpc_poker_types"
  spec.add_dependency 'acpc_dealer', '~> 2.0'
  spec.add_dependency 'acpc_poker_player_proxy', '~> 1.1'

  # Simple exception email notifications
  spec.add_dependency 'rusen'

  # To run background processes
  spec.add_dependency 'process_runner', '~> 0.0'

  spec.add_dependency 'timeout'

  # For better errors in WAPP
  spec.add_dependency 'contextual_exceptions'

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest"
end
