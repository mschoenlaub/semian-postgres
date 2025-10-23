# frozen_string_literal: true

require 'pg'
require 'semian'
require 'semian/pg'
require 'toxiproxy'

RSpec.describe PG do
  let(:proxy) { Toxiproxy[:semian_test_pg] }

  describe 'connection' do
    it_behaves_like 'a resource', :connect_to_pg!, :connection, %i[exec query exec prepare exec_prepared exec_params]
    it 'changes the timeout when the circuit is half open' do
      options = proc do |_host, _port|
        SEMIAN_OPTIONS.merge(timeout: 2, half_open_resource_timeout: 1)
      end
      with_semian_configuration(options) do
        conn = connect_to_pg!
        proxy.downstream(:latency, latency: 3200).apply do
          2.times do
            expect { conn.reset }.to raise_error(PG::Error)
          end
        end

        expect { conn.reset }.to raise_error(PG::CircuitOpenError)

        expect do
          time_travel(5 + 1) do
            conn.reset
          end
        end.to timeout_within(0.1).of(1)

        time_travel(10 + 1) do
          expect { conn.reset }.not_to raise_error
        end

        expect(conn.conninfo_hash).to include(connect_timeout: '3')
      end
    end
  end

  shared_examples 'a query method' do |f, q|
    let!(:conn) { connect_to_pg! }
    let(:query) { q }
    let(:query_with_syntax_error) { ['ERROR!'] }
    let(:long_query) { ['SELECT pg_sleep(5)'] }

    describe 'Allowlisting' do
      it 'allows ROLLBACK' do
        conn.public_send(f, 'START TRANSACTION')
        Semian['pg_testing'].acquire do
          expect { conn.public_send(f, 'ROLLBACK') }.not_to raise_error
        end
      end

      it 'allows COMMIT' do
        conn.public_send(f, 'START TRANSACTION')
        Semian['pg_testing'].acquire do
          expect { conn.public_send(f, 'COMMIT') }.not_to raise_error
        end
      end

      it 'allows RELEASE SAVEPOINT' do
        conn.public_send(f, 'START TRANSACTION')
        conn.public_send(f, 'SAVEPOINT foo')
        Semian['pg_testing'].acquire do
          expect { conn.public_send(f, 'RELEASE SAVEPOINT foo') }.not_to raise_error
        end
        conn.public_send(f, 'ROLLBACK')
      end

      describe 'executing commands' do
        let(:block) { proc {} }

        it 'executes a command' do
          allow(block).to receive(:call)

          expect do
            conn.public_send(f, *query) do |result|
              block.call(result)
            end
          end.not_to raise_error

          expect(block).to have_received(:call).with(an_instance_of(PG::Result))
        end
      end
    end

    describe 'Error handling' do
      let(:statement_timeout_query) { ['set statement_timeout to 1'] }

      it 'does not open the circuit on SyntaxError' do
        2.times do
          expect { conn.public_send(f, *query_with_syntax_error) }.to raise_error(PG::SyntaxError)
        end
      end

      it 'does open the circuit on statement timeout' do
        conn.public_send(f, *statement_timeout_query)
        expect { conn.public_send(f, *long_query) }.to raise_error(PG::QueryCanceled)
        expect { conn.public_send(f, *query) }.to raise_error(PG::CircuitOpenError)
        time_travel(5 + 1) do
          expect(conn.public_send(f, *query).column_values(0).first).to eq('1')
        end
      end

      it 'does tag network errors' do
        proxy.down do
          expect { conn.public_send(f, *query) }.to raise_error(PG::ConnectionBad) { |e|
            expect(e.semian_identifier).to eq(conn.semian_identifier)
          }
        end
      end

      it 'does not tag syntax errors' do
        expect { conn.public_send(f, *query_with_syntax_error) }.to raise_error(PG::SyntaxError) { |e| expect(e.semian_identifier).to be_nil }
      end

      context 'when there are two connections' do
        let!(:conn2) { connect_to_pg! }

        it 'raises a ResourceBusy error on resource timeout' do
          proxy.downstream(:latency, latency: 2200).apply do
            background { conn.public_send(f, *query) }

            expect { conn2.public_send(f, *query) }.to raise_error(PG::ResourceBusyError)
          end
        end

        it 'opens the circuit after resource timeout' do
          proxy.downstream(:latency, latency: 2200).apply do
            background { conn2.public_send(f, *query) }
            expect { conn.public_send(f, *query) }.to raise_error(PG::ResourceBusyError)
          end

          yield_to_background
          expect { conn.public_send(f, *query) }.to raise_error(PG::CircuitOpenError)
        end
      end
    end

    it 'acquires a resource when querying' do
      Semian['pg_testing'].acquire do
        expect { conn.public_send(f, *query) }.to raise_error(PG::ResourceBusyError) { |e|
          expect(e.semian_identifier).to eq('pg_testing')
        }
      end
    end
  end

  describe 'query' do
    it_behaves_like 'a query method', :query, ['SELECT 1']
    it_behaves_like 'a query method', :exec, ['SELECT 1']
    it_behaves_like 'a query method', :exec_params, ['SELECT $1::int', [1]]
  end
end
