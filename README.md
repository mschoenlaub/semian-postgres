# semian-postgres

![CI Workflow](https://github.com/mschoenlaub/semian-postgres/actions/workflows/ci.yml/badge.svg)
[![Gem Version](https://badge.fury.io/rb/semian-postgres.svg?kill_cache=1)](https://badge.fury.io/rb/semian-postgres)

This library provides a Postgres adapter for [Semian](https://github.com/Shopify/semian) by wrapping the [pg gem](https://rubygems.org/gems/pg)
Semian is a resiliency toolkit for Ruby applications that provides a way to protect your application from external failures by limiting the number of resources that can be used at a time.
You can read more about Semian [here](https://github.com/Shopify/semian)).

## Usage

Add the gem to your `Gemfile` and require it in your application.

```ruby
gem 'semian-pg', require: %w(semian semian/pg)
```


## Configuration

The adapter is configured by a callback function, which would be ideally defined in some sort of initialization file.
For Rails applications these would usually live in the `config/initializers/` directory.


### Minimal example
The following example configures an adapter to open the circuit after three unsuccessful
connection attempts and close it after each successful attempt.

Bulkheading is disabled, because this is not supported with servers that have a thread-oriented model, such as [Puma](https://github.com/puma/puma)

```ruby
require "semian"
require "semian/postgres"

SEMIAN_PARAMETERS = {
  circuit_breaker: true,
  success_threshold: 1,
  error_threshold: 3,
  error_timeout: 3,
  bulkhead: false,
}

Semian::PG.semian_configuration = proc do |host, port|
  if host == "localhost" && port == 5432
    return SEMIAN_PARAMETERS
  end
end

conn = PG.connect(host: "example.com", port: 5432)
conn.exec("SELECT 1")
```


## Development
Semian, and by extension semian-postgres, currently depends on Linux for **Bulkheading**.

The development environment is based on `docker-compose`, spinning up containers for Postgres and Toxiproxy.
Additionally a `dev` container is spun up. The `Gemfile` contains `ruby-debug-ide` to support remote debugging from the IDE.

A typical development workflow would be to run the tests in the `dev` container
```bash
docker compose up -d
docker compose exec dev bin/setup
docker compose exec dev rake rubocop spec
```


## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/mschoenlaub/semian-postgres).


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
