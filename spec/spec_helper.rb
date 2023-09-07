# frozen_string_literal: true

require 'bundler/setup'

TOXIPROXY_HOST = ENV.fetch('TOXIPROXY_HOST', 'localhost')
PGHOST = ENV.fetch('PGHOST', 'localhost')
PGPORT = ENV.fetch('PGPORT', 5432)

Dir['./spec/support/**/*.rb'].sort.each { |f| require f }

SEMIAN_OPTIONS = {
  name: :testing,
  tickets: 1,
  timeout: 0,
  error_threshold: 1,
  success_threshold: 2,
  error_timeout: 5
}.freeze

DEFAULT_SEMIAN_CONFIGURATION = proc do |host, port|
  next nil if host == TOXIPROXY_HOST && port == 8474

  SEMIAN_OPTIONS
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before do
    Semian.destroy_all_resources
  end

  config.before(:all) do
    Semian.logger = Logger.new(STDOUT, Logger::DEBUG)
    Semian::PG.semian_configuration = DEFAULT_SEMIAN_CONFIGURATION
    Toxiproxy.host = URI::HTTP.build(
      host: TOXIPROXY_HOST,
      port: 8474
    )
    Toxiproxy.populate([
                         {
                           name: 'semian_test_pg',
                           upstream: "#{PGHOST}:#{PGPORT}",
                           listen: "#{TOXIPROXY_HOST}:8475"
                         }
                       ])
  end
end
