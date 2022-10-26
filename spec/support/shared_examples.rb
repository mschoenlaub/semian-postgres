# frozen_string_literal: true

RSpec.shared_examples 'a resource' do |aquire_proc, resource_scope, query_methods|
  describe '#semian_identifier' do
    it 'uses a name if given' do
      options = proc do |_host, _port|
        SEMIAN_OPTIONS.merge(name: 'foo')
      end
      with_semian_configuration(options) do
        resource = PG::Connection.connect(
          host: TOXIPROXY_HOST,
          port: 8475
        )
        expect(resource.semian_identifier).to eq('pg_foo')
      end
    end

    it 'uses host and port by default' do
      options = proc do |_host, _port|
        options = SEMIAN_OPTIONS.dup
        options.delete(:name)
        options
      end
      with_semian_configuration(options) do
        resource = PG::Connection.connect(
          host: TOXIPROXY_HOST,
          port: 8475
        )

        expect(resource.semian_identifier).to eq("pg_#{TOXIPROXY_HOST}:8475")
      end
    end
  end

  query_methods.each do |query_method|
    describe query_method.to_s do
      it "has a method #{query_method}" do
        conn = connect_to_pg!
        expect(conn).to respond_to(query_method)
      end
    end
  end

  context 'when an error occurs' do
    it 'opens the circuit' do
      proxy.downstream(:latency, latency: 2200).apply do
        expect { method(aquire_proc).call }.to raise_error(::PG::Error)
        expect { method(aquire_proc).call }.to raise_error(::PG::CircuitOpenError)
      end
    end

    it 'raises a ResourceBusy error on connect timeout' do
      proxy.downstream(:latency, latency: 5000).apply do
        background { method(aquire_proc).call }
        expect { method(aquire_proc).call }.to raise_error(::PG::ResourceBusyError)
      end
    end

    it 'opens the circuit after timeout on connect' do
      proxy.downstream(:latency, latency: 2000).apply do
        background { method(aquire_proc).call }
        expect { method(aquire_proc).call }.to raise_error(::PG::ResourceBusyError)
      end
      yield_to_background
      expect { method(aquire_proc).call }.to raise_error(::PG::CircuitOpenError)
    end
  end

  it 'acquires a resource' do
    method(aquire_proc).call
    Semian['pg_testing'].acquire do
      expect { method(aquire_proc).call }.to raise_error(::PG::ResourceBusyError) { |e|
        expect(e.semian_identifier).to eq('pg_testing')
      }
    end
  end

  it 'triggers the notification' do
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      next unless event == :success

      notified = true
      expect(resource).to eq(Semian['pg_testing'])
      expect(scope).to eq(resource_scope)
      expect(adapter).to eq(:pg)
    end

    method(aquire_proc).call

    expect(notified).to be(true)
  ensure
    Semian.unsubscribe(subscriber)
  end
end
