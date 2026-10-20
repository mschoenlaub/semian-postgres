# frozen_string_literal: true

require 'pg'
require 'semian'
require 'semian/pg'
require 'toxiproxy'

RSpec.describe Semian::PG do
  let(:proxy) { Toxiproxy[:semian_test_pg] }

  # Every public way of sending a statement through a PG::Connection, with a
  # call that exercises it against a prepared statement named `stmt`.
  entry_points = {
    exec: ->(c) { c.exec('SELECT 1') },
    query: ->(c) { c.query('SELECT 1') },
    async_exec: ->(c) { c.async_exec('SELECT 1') },
    sync_exec: ->(c) { c.sync_exec('SELECT 1') },
    exec_params: ->(c) { c.exec_params('SELECT $1::int', [1]) },
    async_exec_params: ->(c) { c.async_exec_params('SELECT $1::int', [1]) },
    sync_exec_params: ->(c) { c.sync_exec_params('SELECT $1::int', [1]) },
    prepare: ->(c) { c.prepare('prepared_sync', 'SELECT 1') },
    async_prepare: ->(c) { c.async_prepare('prepared_async', 'SELECT 1') },
    sync_prepare: ->(c) { c.sync_prepare('prepared_blocking', 'SELECT 1') },
    exec_prepared: ->(c) { c.exec_prepared('stmt') },
    async_exec_prepared: ->(c) { c.async_exec_prepared('stmt') },
    sync_exec_prepared: ->(c) { c.sync_exec_prepared('stmt') },
    describe_prepared: ->(c) { c.describe_prepared('stmt') },
    send_query: ->(c) { c.send_query('SELECT 1') },
    send_query_params: ->(c) { c.send_query_params('SELECT $1::int', [1]) },
    send_query_prepared: ->(c) { c.send_query_prepared('stmt', []) },
    send_prepare: ->(c) { c.send_prepare('prepared_sent', 'SELECT 1') }
  }

  # Entry points whose first argument is the SQL text, and so can be allowlisted.
  sql_entry_points = {
    exec: ->(c, sql) { c.exec(sql) },
    async_exec: ->(c, sql) { c.async_exec(sql) },
    sync_exec: ->(c, sql) { c.sync_exec(sql) },
    exec_params: ->(c, sql) { c.exec_params(sql, []) },
    async_exec_params: ->(c, sql) { c.async_exec_params(sql, []) },
    sync_exec_params: ->(c, sql) { c.sync_exec_params(sql, []) },
    send_query: ->(c, sql) { c.send_query(sql) },
    send_query_params: ->(c, sql) { c.send_query_params(sql, []) }
  }

  # Opens the shared circuit from a second connection so that `conn` stays usable.
  def open_circuit!
    other = connect_to_pg!
    other.exec('SET statement_timeout TO 100')
    expect { other.exec('SELECT pg_sleep(5)') }.to raise_error(PG::QueryCanceled)
    expect(Semian['pg_testing']).to be_open
  end

  describe 'entry points' do
    let!(:conn) { connect_to_pg! }

    before { conn.exec('PREPARE stmt AS SELECT 1') }

    entry_points.each do |name, run|
      describe "##{name}" do
        it 'is rejected while the circuit is open' do
          open_circuit!

          expect { run.call(conn) }.to raise_error(PG::CircuitOpenError)
        end

        it 'holds a ticket while it runs' do
          Semian['pg_testing'].acquire do
            expect { run.call(conn) }.to raise_error(PG::ResourceBusyError)
          end
        end
      end
    end

    sql_entry_points.each do |name, run|
      describe "##{name}" do
        it 'lets transaction control statements through while the circuit is open' do
          conn.exec('START TRANSACTION')
          open_circuit!

          expect { run.call(conn, 'ROLLBACK') }.not_to raise_error
        end
      end
    end
  end

  describe 'results read with #get_result' do
    let!(:conn) { connect_to_pg! }

    def drain_results
      result = nil
      while (incoming = conn.get_result)
        result = incoming
      end
      result
    end

    it 'opens the circuit when the result reports a statement timeout' do
      conn.exec('SET statement_timeout TO 100')
      conn.send_query('SELECT pg_sleep(5)')

      expect { drain_results.check }.to raise_error(PG::QueryCanceled) { |e|
        expect(e.semian_identifier).to eq(conn.semian_identifier)
      }
      expect { conn.exec('SELECT 1') }.to raise_error(PG::CircuitOpenError)
    end

    it 'does not open the circuit when the result reports a syntax error' do
      conn.send_query('ERROR!')

      expect { drain_results.check }.to raise_error(PG::SyntaxError) { |e|
        expect(e.semian_identifier).to be_nil
      }
      expect(conn.exec('SELECT 1').column_values(0).first).to eq('1')
    end

    it 'counts a connection lost while waiting on the next statement' do
      conn.send_query('SELECT pg_sleep(2)')

      proxy.down do
        expect { conn.get_last_result }.to raise_error(PG::ConnectionBad) { |e|
          expect(e.semian_identifier).to be_nil
        }
      end
      expect(Semian['pg_testing']).to be_closed
      expect { conn.exec('SELECT 1') }.to raise_error(PG::ConnectionBad)
      expect(Semian['pg_testing']).to be_open
    end
  end

  describe 'failure accounting' do
    let(:options) { proc { |_host, _port| SEMIAN_OPTIONS.merge(error_threshold: 2) } }

    it 'records a failure raised by a blocking call once' do
      with_semian_configuration(options) do
        conn = connect_to_pg!
        conn.exec('SET statement_timeout TO 100')

        expect { conn.exec('SELECT pg_sleep(5)') }.to raise_error(PG::QueryCanceled)

        expect(Semian['pg_testing']).to be_closed
      end
    end

    it 'records a failure read through the asynchronous API once' do
      with_semian_configuration(options) do
        conn = connect_to_pg!
        conn.exec('SET statement_timeout TO 100')
        conn.send_query('SELECT pg_sleep(5)')
        result = nil
        while (incoming = conn.get_result)
          result = incoming
        end

        expect { result.check }.to raise_error(PG::QueryCanceled)

        expect(Semian['pg_testing']).to be_closed
      end
    end
  end
end
