# semian-postgres

![CI Workflow](https://github.com/mschoenlaub/semian-postgres/actions/workflows/ci.yml/badge.svg)
[![Gem Version](https://badge.fury.io/rb/semian-postgres.svg?kill_cache=1)](https://badge.fury.io/rb/semian-postgres)

This library provides a Postgres adapter for [Semian](https://github.com/Shopify/semian) by wrapping the [pg gem](https://rubygems.org/gems/pg)
Semian is a resiliency toolkit for Ruby applications that provides a way to protect your application from external failures by limiting the number of resources that can be used at a time.
You can read more about Semian [here](https://github.com/Shopify/semian)).

## Usage

Add the gem to your `Gemfile` and require it in your application.

```ruby
gem 'semian-postgres', require: %w(semian semian/pg)
```


Every way of sending a statement through a `PG::Connection` is protected: the blocking
`exec`, `exec_params`, `prepare`, `exec_prepared` and `describe_prepared` families, and the
asynchronous `send_query`, `send_query_params`, `send_query_prepared` and `send_prepare` calls.
With the asynchronous API the circuit breaker rejects the `send_*` call while the circuit is
open, and a statement failure that surfaces later in `PG::Result#check` is recorded against
the circuit. A connection lost while waiting in `get_result` is counted by the next statement
instead. The bulkhead ticket is only held for the duration of the `send_*` call.

## Configuration

The adapter is configured by a callback function, which would be ideally defined in some sort of initialization file.
For Rails applications these would usually live in the `config/initializers/` directory.


### Minimal example
The following example configures an adapter to open the circuit after three unsuccessful
connection attempts and close it after each successful attempt.

Bulkheading is disabled, because this is not supported with servers that have a thread-oriented model, such as [Puma](https://github.com/puma/puma)

```ruby
require "semian"
require "semian/pg"

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


## Which errors open the circuit

Semian protects against slow or unreachable resources, so only two kinds of errors count
as failures for the circuit breaker:

- `PG::ConnectionBad`: the server cannot be reached, or the connection was lost.
- `PG::QueryCanceled` caused by `statement_timeout`: the server gave up on a query that ran
  longer than the configured limit. libpq has no client-side read timeout, so this is the
  PostgreSQL equivalent of the `read_timeout` the Semian MySQL adapters use as a slow-query signal.

Any other error, including syntax errors and queries cancelled by `pg_cancel_backend` or
`PG::Connection#cancel`, is raised as usual but does not affect the circuit. A cancelled query
is an operator or application decision, not a measurement of the server's health.

The two causes of `PG::QueryCanceled` share the same SQLSTATE, so they are told apart by the
server's error message. This requires the server to send English messages
(`lc_messages = 'C'` or an English locale). With a different locale, statement timeouts are
not recognised and no longer open the circuit.

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

### Thanks to everyone that has already contributed

<a href="https://github.com/mschoenlaub/semian-postgres/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=mschoenlaub/semian-postgres" alt="Pictures of the folks who have contributed to the project" />
</a>


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
