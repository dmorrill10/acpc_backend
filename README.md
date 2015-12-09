# AcpcTableManager

Must be able to accomplish the following tasks:

- Start a dealer
- Start a bot and have it connect to the dealer
- Start multiple bots and have them connect to the dealer
- Start a proxy and connect it to the dealer
- Send actions to the proxy for them to be played
- Ensure dealer processes are killed when matches are finished
- Ensure the number of matches being run is less than set maximum
- Manage a queue of matches
    - Start the next match in the queue when one finishes
- Manage a pool of port on which remote bots can connect to dealers

The following tasks can be done in parallel:

- Playing actions
- Starting proxies
- Starting bots

Everything else must be done sequentially.

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

