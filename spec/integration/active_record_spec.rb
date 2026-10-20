# frozen_string_literal: true

require 'active_record'
require 'semian'
require 'semian/pg'
require 'toxiproxy'

# Runs the adapter underneath Active Record's PostgreSQL adapter, the way a Rails
# application that does not use semian/activerecord_postgresql_adapter would.
RSpec.describe 'Semian::PG under Active Record', type: :integration do
  let(:proxy) { Toxiproxy[:semian_test_pg] }
  let(:resource) { Semian['pg_testing'] }
  let(:connection) { ActiveRecord::Base.connection }

  before(:all) do
    ActiveRecord::Base.establish_connection(
      adapter: 'postgresql',
      host: TOXIPROXY_HOST,
      port: 8475,
      username: ENV.fetch('PGUSER', 'postgres'),
      password: ENV.fetch('PGPASSWORD', nil),
      database: ENV.fetch('PGDATABASE', 'postgres'),
      connect_timeout: 3,
      prepared_statements: true,
      # The same place a Rails application sets it: a statement timeout is the
      # slow query signal that opens the circuit.
      variables: { statement_timeout: 1000 }
    )
    ActiveRecord::Base.connection.create_table(:semian_widgets, force: true) { |t| t.string(:name) }
  end

  after(:all) do
    ActiveRecord::Base.connection.drop_table(:semian_widgets, if_exists: true)
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  # Each example gets a fresh raw connection, as the Semian resource it holds is
  # destroyed between examples.
  before do
    ActiveRecord::Base.connection_handler.clear_all_connections!
    stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'semian_widgets' })
    Widget.delete_all
  end

  def open_circuit!
    expect { connection.execute('SELECT pg_sleep(5)') }.to raise_error(ActiveRecord::QueryCanceled)
    expect(resource).to be_open
  end

  describe 'slow queries' do
    it 'opens the circuit on the statement timeout from the connection variables' do
      expect { Widget.find_by_sql('SELECT pg_sleep(5)') }.to raise_error(ActiveRecord::QueryCanceled) { |e|
        expect(e).to be_caused_by(PG::QueryCanceled)
      }

      expect(resource).to be_open
    end

    it 'rejects model queries while the circuit is open' do
      open_circuit!

      expect { Widget.count }.to raise_error(ActiveRecord::StatementInvalid) { |e|
        expect(e).to be_caused_by(PG::CircuitOpenError)
      }
    end

    it 'rejects cached prepared statements while the circuit is open' do
      Widget.where(name: 'cached').to_a
      expect(connection.select_value('SELECT count(*) FROM pg_prepared_statements')).to be_positive
      open_circuit!

      expect { Widget.where(name: 'cached').to_a }.to raise_error(ActiveRecord::StatementInvalid) { |e|
        expect(e).to be_caused_by(PG::CircuitOpenError)
      }
    end

    it 'rolls back the transaction that hit the timeout' do
      expect do
        Widget.transaction do
          Widget.create!(name: 'uncommitted')
          connection.execute('SELECT pg_sleep(5)')
        end
      end.to raise_error(ActiveRecord::QueryCanceled)

      expect(resource).to be_open
      expect(connection.raw_connection.transaction_status).to eq(PG::PQTRANS_IDLE)
      time_travel(SEMIAN_OPTIONS[:error_timeout] + 1) do
        expect(Widget.count).to eq(0)
      end
    end

    it 'serves queries again once error_timeout has elapsed' do
      open_circuit!

      time_travel(SEMIAN_OPTIONS[:error_timeout] + 1) do
        Widget.create!(name: 'recovered')
        expect(Widget.pluck(:name)).to eq(['recovered'])
      end
      expect(resource).to be_closed
    end
  end

  describe 'outages' do
    before { Widget.count }

    it 'opens the circuit when the server goes away' do
      proxy.down do
        expect { Widget.count }.to raise_error(ActiveRecord::ActiveRecordError) { |e|
          expect(e).to be_caused_by(PG::ConnectionBad)
        }
      end

      expect(resource).to be_open
    end

    it 'fails fast while the server is still unreachable' do
      proxy.down do
        expect { Widget.count }.to raise_error(ActiveRecord::ActiveRecordError)
        expect { Widget.count }.to raise_error(ActiveRecord::ActiveRecordError) { |e|
          expect(e).to be_caused_by(PG::CircuitOpenError)
        }
      end
    end

    it 'reconnects once the server is back and error_timeout has elapsed' do
      proxy.down do
        expect { Widget.count }.to raise_error(ActiveRecord::ActiveRecordError)
      end
      expect { Widget.count }.to raise_error(ActiveRecord::ActiveRecordError) { |e|
        expect(e).to be_caused_by(PG::CircuitOpenError)
      }

      time_travel(SEMIAN_OPTIONS[:error_timeout] + 1) do
        expect(Widget.count).to eq(0)
      end
      expect(resource).to be_closed
    end
  end
end
