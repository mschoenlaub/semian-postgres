# frozen_string_literal: true

require 'sequel'
require 'semian'
require 'semian/pg'
require 'toxiproxy'

# Runs the adapter underneath Sequel's postgres adapter, which subclasses
# PG::Connection and drives it through async_exec, prepare and exec_prepared.
RSpec.describe 'Semian::PG under Sequel', type: :integration do
  let(:proxy) { Toxiproxy[:semian_test_pg] }
  let(:resource) { Semian['pg_testing'] }
  let(:widgets) { db[:semian_widgets] }

  # rubocop:disable RSpec/InstanceVariable
  let(:db) { @db }

  before(:all) do
    @db = Sequel.connect(
      adapter: 'postgres',
      host: TOXIPROXY_HOST,
      port: 8475,
      user: ENV.fetch('PGUSER', 'postgres'),
      password: ENV.fetch('PGPASSWORD', nil),
      database: ENV.fetch('PGDATABASE', 'postgres'),
      connect_timeout: 3,
      # The slow query signal that opens the circuit, set once per connection.
      after_connect: ->(conn) { conn.exec('SET statement_timeout TO 1000') }
    )
    @db.create_table!(:semian_widgets) { String :name }
  end

  after(:all) do
    @db.drop_table?(:semian_widgets)
    @db.disconnect
  end
  # rubocop:enable RSpec/InstanceVariable

  # Each example gets a fresh connection, as the Semian resource it holds is
  # destroyed between examples.
  before do
    db.disconnect
    widgets.delete
  end

  def open_circuit!
    expect { db.run('SELECT pg_sleep(5)') }.to raise_error(Sequel::DatabaseError)
    expect(resource).to be_open
  end

  describe 'slow queries' do
    it 'opens the circuit on the statement timeout set after connect' do
      expect { db.fetch('SELECT pg_sleep(5)').all }.to raise_error(Sequel::DatabaseError) { |e|
        expect(e).to be_caused_by(PG::QueryCanceled)
      }

      expect(resource).to be_open
    end

    it 'rejects dataset queries while the circuit is open' do
      open_circuit!

      expect { widgets.count }.to raise_error(Sequel::DatabaseError) { |e|
        expect(e).to be_caused_by(PG::CircuitOpenError)
      }
    end

    it 'rejects prepared statements while the circuit is open' do
      by_name = widgets.where(name: :$name).prepare(:select, :widgets_by_name)
      by_name.call(name: 'cached')
      expect(db[:pg_prepared_statements].count).to be_positive
      open_circuit!

      expect { by_name.call(name: 'cached') }.to raise_error(Sequel::DatabaseError) { |e|
        expect(e).to be_caused_by(PG::CircuitOpenError)
      }
    end

    it 'rolls back the transaction that hit the timeout' do
      expect do
        db.transaction do
          widgets.insert(name: 'uncommitted')
          db.run('SELECT pg_sleep(5)')
        end
      end.to raise_error(Sequel::DatabaseError)

      expect(resource).to be_open
      expect(db.synchronize(&:transaction_status)).to eq(PG::PQTRANS_IDLE)
      time_travel(SEMIAN_OPTIONS[:error_timeout] + 1) do
        expect(widgets.count).to eq(0)
      end
    end

    it 'serves queries again once error_timeout has elapsed' do
      open_circuit!

      time_travel(SEMIAN_OPTIONS[:error_timeout] + 1) do
        widgets.insert(name: 'recovered')
        expect(widgets.select_map(:name)).to eq(['recovered'])
      end
      expect(resource).to be_closed
    end
  end

  describe 'outages' do
    before { widgets.count }

    it 'opens the circuit when the server goes away' do
      proxy.down do
        expect { widgets.count }.to raise_error(Sequel::DatabaseError) { |e|
          expect(e).to be_caused_by(PG::ConnectionBad)
        }
      end

      expect(resource).to be_open
    end

    it 'fails fast while the server is still unreachable' do
      proxy.down do
        expect { widgets.count }.to raise_error(Sequel::DatabaseError)
        expect { widgets.count }.to raise_error(Sequel::DatabaseError) { |e|
          expect(e).to be_caused_by(PG::CircuitOpenError)
        }
      end
    end

    it 'reconnects once the server is back and error_timeout has elapsed' do
      proxy.down do
        expect { widgets.count }.to raise_error(Sequel::DatabaseError)
      end
      expect { widgets.count }.to raise_error(Sequel::DatabaseError) { |e|
        expect(e).to be_caused_by(PG::CircuitOpenError)
      }

      time_travel(SEMIAN_OPTIONS[:error_timeout] + 1) do
        expect(widgets.count).to eq(0)
      end
      expect(resource).to be_closed
    end
  end
end
