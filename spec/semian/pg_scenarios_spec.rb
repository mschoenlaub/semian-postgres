# frozen_string_literal: true

require 'benchmark'
require 'pg'
require 'semian'
require 'semian/pg'
require 'toxiproxy'

# Each example here follows one resource through a whole episode: the failures
# that open the circuit, what happens while it is open, and how it recovers.
RSpec.describe Semian::PG do
  let(:proxy) { Toxiproxy[:semian_test_pg] }
  let(:resource) { Semian['pg_testing'] }
  let(:error_timeout) { SEMIAN_OPTIONS[:error_timeout] }
  let(:transitions) { [] }

  before do
    Semian.subscribe(:scenarios) do |event, _resource, _scope, _adapter, payload|
      transitions << payload[:state] if event == :state_change
    end
  end

  after { Semian.unsubscribe(:scenarios) }

  def slow_query(conn)
    conn.exec('SELECT pg_sleep(5)')
  end

  describe 'an outage' do
    it 'opens the circuit, rejects callers without waiting, then probes and closes once the server is back' do
      conn = connect_to_pg!
      proxy.down do
        expect { conn.exec('SELECT 1') }.to raise_error(PG::ConnectionBad)
      end
      expect(resource).to be_open

      # The server is reachable again but slow; callers are rejected before they
      # would spend the connect timeout waiting for it.
      proxy.downstream(:latency, latency: 2000).apply do
        elapsed = Benchmark.realtime { expect { connect_to_pg! }.to raise_error(PG::CircuitOpenError) }
        expect(elapsed).to be < 0.1
      end

      time_travel(error_timeout + 1) do
        probe = connect_to_pg!
        expect(resource).to be_half_open
        probe.exec('SELECT 1')
        expect(resource).to be_closed
      end
      expect(transitions).to eq(%i[closed open half_open closed])
    end

    it 'reopens the circuit when the probe fails' do
      conn = connect_to_pg!
      proxy.down do
        expect { conn.exec('SELECT 1') }.to raise_error(PG::ConnectionBad)

        time_travel(error_timeout + 1) do
          expect { connect_to_pg! }.to raise_error(PG::ConnectionBad)
          expect(resource).to be_open
          expect { connect_to_pg! }.to raise_error(PG::CircuitOpenError)
        end
      end
      expect(transitions).to eq(%i[closed open half_open open])
    end
  end

  describe 'a slow database' do
    let(:options) { SEMIAN_OPTIONS.merge(error_threshold: 3, error_threshold_timeout: 2) }

    it 'opens the circuit on the third timeout and rejects the fourth query without running it' do
      with_semian_configuration(options) do
        conn = connect_to_pg!
        conn.exec('SET statement_timeout TO 100')

        2.times { expect { slow_query(conn) }.to raise_error(PG::QueryCanceled) }
        expect(resource).to be_closed
        expect { slow_query(conn) }.to raise_error(PG::QueryCanceled)
        expect(resource).to be_open

        elapsed = Benchmark.realtime { expect { slow_query(conn) }.to raise_error(PG::CircuitOpenError) }
        expect(elapsed).to be < 0.05
      end
    end

    it 'forgets timeouts that are older than error_threshold_timeout' do
      with_semian_configuration(options) do
        conn = connect_to_pg!
        conn.exec('SET statement_timeout TO 100')
        2.times { expect { slow_query(conn) }.to raise_error(PG::QueryCanceled) }

        time_travel(options[:error_threshold_timeout] + 1) do
          expect { slow_query(conn) }.to raise_error(PG::QueryCanceled)
          expect(resource).to be_closed
        end
      end
    end
  end

  describe 'a flapping database with exponential backoff' do
    let(:options) do
      SEMIAN_OPTIONS.merge(
        success_threshold: 1,
        error_timeout: 8,
        exponential_backoff_error_timeout: true,
        exponential_backoff_initial_timeout: 1,
        exponential_backoff_multiplier: 2
      )
    end

    it 'waits longer before each probe while probes keep failing, and starts over once a probe succeeds' do
      with_semian_configuration(options) do
        conn = connect_to_pg!
        conn.exec('SET statement_timeout TO 100')
        expect { slow_query(conn) }.to raise_error(PG::QueryCanceled)
        expect(resource).to be_open

        # First wait is the initial timeout of one second.
        time_travel(0.5) { expect { conn.exec('SELECT 1') }.to raise_error(PG::CircuitOpenError) }
        time_travel(1.5) do
          expect { slow_query(conn) }.to raise_error(PG::QueryCanceled)
          expect(resource).to be_open
        end

        # The failed probe doubles the wait: two seconds from the probe's failure.
        time_travel(3.0) { expect { conn.exec('SELECT 1') }.to raise_error(PG::CircuitOpenError) }
        time_travel(4.0) do
          expect(conn.exec('SELECT 1').getvalue(0, 0)).to eq('1')
          expect(resource).to be_closed
        end

        # Closing resets the backoff to the initial timeout.
        expect { slow_query(conn) }.to raise_error(PG::QueryCanceled)
        time_travel(1.5) { expect(conn.exec('SELECT 1').getvalue(0, 0)).to eq('1') }
        expect(transitions).to eq(%i[closed open half_open open half_open closed open half_open closed])
      end
    end
  end
end
