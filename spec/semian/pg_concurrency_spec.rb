# frozen_string_literal: true

require 'pg'
require 'semian'
require 'semian/pg'
require 'toxiproxy'

RSpec.describe Semian::PG do
  let(:proxy) { Toxiproxy[:semian_test_pg] }
  let(:resource) { Semian['pg_testing'] }

  # The largest number of intervals, given as [start, finish] pairs, that overlap at any point.
  def max_concurrency(intervals)
    events = intervals.flat_map { |s, f| [[s, 1], [f, -1]] }.sort_by { |t, d| [t, d] }
    events.each_with_object([0]) { |(_, d), acc| acc << (acc.last + d) }.max
  end

  # Runs one half-second query and returns when the server ran it, as a
  # [start, finish] pair of server clock readings, or the error it raised.
  # Waiting for a bulkhead ticket happens before the server sees the query,
  # so the interval only covers the time the query actually ran.
  def timed_query(conn)
    row = conn.exec('SELECT extract(epoch FROM clock_timestamp()), pg_sleep(0.5), extract(epoch FROM clock_timestamp())').values.first
    [row[0].to_f, row[2].to_f]
  rescue PG::Error => e
    e
  end

  describe 'threads sharing a circuit' do
    let(:options) { SEMIAN_OPTIONS.merge(bulkhead: false, error_threshold: 3) }
    let(:workers) { 6 }

    it 'opens the circuit once for everyone and stops the error storm' do
      with_semian_configuration(options) do
        conns = Array.new(workers) { connect_to_pg! }
        errors = Hash.new(0)
        lock = Mutex.new
        stop = false
        threads = conns.map do |conn|
          Thread.new do
            until stop
              begin
                conn.exec('SELECT 1')
              rescue PG::Error => e
                lock.synchronize { errors[e.class] += 1 }
              end
              sleep(0.01)
            end
          end
        end
        threads.each { |t| t.report_on_exception = false }

        sleep(0.2)
        proxy.down { sleep(0.5) }
        stop = true
        threads.each { |t| expect(t.join(5)).not_to be_nil }

        connection_errors = errors.sum { |klass, n| klass <= PG::ConnectionBad ? n : 0 }
        expect(connection_errors).to be_between(options[:error_threshold], workers)
        expect(errors[PG::CircuitOpenError]).to be > 0
        expect(resource).to be_open
      end
    end
  end

  describe 'the bulkhead' do
    before { skip('SysV semaphores are only available on Linux') unless Semian.semaphores_enabled? }

    let(:tickets) { 2 }
    let(:workers) { 4 }

    it 'lets no more than `tickets` queries run at once across threads' do
      with_semian_configuration(SEMIAN_OPTIONS.merge(tickets: tickets, timeout: 2)) do
        conns = Array.new(workers) { connect_to_pg! }
        results = conns.map { |conn| Thread.new { timed_query(conn) } }.map(&:value)

        expect(results).to all(be_an(Array))
        expect(max_concurrency(results)).to eq(tickets)
      end
    end

    it 'rejects the queries that find no ticket when the wait is zero' do
      with_semian_configuration(SEMIAN_OPTIONS.merge(tickets: tickets, timeout: 0)) do
        conns = Array.new(workers) { connect_to_pg! }
        results = conns.map { |conn| Thread.new { timed_query(conn) } }.map(&:value)

        expect(results.count { |r| r.is_a?(PG::ResourceBusyError) }).to eq(workers - tickets)
        expect(max_concurrency(results.grep(Array))).to eq(tickets)
      end
    end

    it 'lets no more than `tickets` queries run at once across forked workers' do
      with_semian_configuration(SEMIAN_OPTIONS.merge(tickets: tickets, timeout: 2)) do
        connect_to_pg!.close # registers the resource and its semaphore before forking
        reader, writer = IO.pipe
        pids = Array.new(workers) do
          fork do
            reader.close
            result = timed_query(connect_to_pg!)
            writer.puts(result.is_a?(Array) ? result.join(' ') : result.class.name)
            writer.close
            exit!(0)
          end
        end
        writer.close
        lines = reader.readlines(chomp: true)
        pids.each { |pid| Process.wait(pid) }

        intervals = lines.map { |l| l.split.map(&:to_f) }
        expect(lines.size).to eq(workers)
        expect(intervals).to all(have_attributes(size: 2))
        expect(max_concurrency(intervals)).to eq(tickets)
      end
    end
  end
end
