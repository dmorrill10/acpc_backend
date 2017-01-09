# Annual Computer Poker Competition Table Manager

This is a server that starts an ACPC poker match on demand according to a fixed
configuration set at start-up through a messaging server
([Redis](https://redis.io/)). It manages the log files produced by all matches.
All matches to be started are persisted in a file-based queue, and information
about those already running are also saved in a file. Special ports can be
designed for use by agents that require them to connect remotely to
`dealer` instances, and this server will manage their allocation.


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'acpc_table_manager'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install acpc_table_manager

## Usage

TODO: Write usage instructions here

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/acpc_table_manager.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
