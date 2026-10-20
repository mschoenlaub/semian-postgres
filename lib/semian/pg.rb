# frozen_string_literal: true

require 'semian/pg/version'
require 'semian/adapter'
require 'pg'

# We need to patch the actual pg gem to decorate the base errors such as PG::Error
module PG
  ::PG::Error.include(Semian::AdapterError)
  # A statement timeout is the server giving up on a slow query, which is the
  # closest thing PostgreSQL has to a client-side read timeout. Any other
  # cancellation (pg_cancel_backend, PG::Connection#cancel) is a deliberate
  # decision by an operator or the application and says nothing about the
  # health of the server, so it must not open the circuit.
  ::PG::QueryCanceled.class_eval do
    def marks_semian_circuits?
      message.include?('canceling statement due to statement timeout')
    end
  end

  # This allows us to use semian as a drop-in replacement.
  class SemianError < PG::Error
    def initialize(semian_identifier, *)
      super(*)
      @semian_identifier = semian_identifier
    end
  end

  ResourceBusyError = Class.new(SemianError)
  CircuitOpenError = Class.new(SemianError)
end

module Semian
  # The adapter wraps the PG::Connection class and implements the methods for resource acquisition.
  module PG
    include Semian::Adapter

    ResourceBusyError = ::PG::ResourceBusyError
    CircuitOpenError = ::PG::CircuitOpenError

    # This error is raised when the configuration hook is modified more than once.
    class ConfigurationChangedError < RuntimeError
      def initialize(msg = 'Cannot re-initialize semian_configuration')
        super
      end
    end

    class << self
      attr_accessor :exceptions
      attr_reader :semian_configuration

      def semian_configuration=(configuration)
        raise ConfigurationChangedError unless @semian_configuration.nil?

        @semian_configuration = configuration
      end

      def retrieve_semian_configuration(host, port)
        @semian_configuration.call(host, port) if @semian_configuration.respond_to?(:call)
      end
    end

    def conninfo_hash
      h = super
      h.merge!(connect_timeout: @connect_timeout) if @connect_timeout
      h
    end

    def semian_identifier
      @semian_identifier ||= "pg_#{raw_semian_options[:name]}" if raw_semian_options && raw_semian_options[:name]
      @semian_identifier ||= "pg_#{@iopts[:host]}:#{@iopts[:port]}"
    end

    def raw_semian_options
      @raw_semian_options ||= begin
        @raw_semian_options = Semian::PG.retrieve_semian_configuration(@iopts[:host], @iopts[:port])
        @raw_semian_options = @raw_semian_options.dup unless @raw_semian_options.nil?
      end
    end

    def disabled?
      raw_semian_options.nil?
    end

    RESOURCE_EXCEPTIONS = [::PG::ConnectionBad, ::PG::QueryCanceled].freeze

    def resource_exceptions
      RESOURCE_EXCEPTIONS
    end

    def async_connect_or_reset(*)
      acquire_semian_resource(adapter: :pg, scope: :connection) do
        super
      end
    end

    QUERY_WHITELIST = Regexp.union(
      %r{\A(?:/\*.*?\*/)?\s*ROLLBACK}i,
      %r{\A(?:/\*.*?\*/)?\s*COMMIT}i,
      %r{\A(?:/\*.*?\*/)?\s*RELEASE\s+SAVEPOINT}i
    )

    # Every PG::Connection method that sends a statement to the server, mapped to the
    # position of the SQL text when the statement can be allowlisted. The pg gem aliases
    # the plain names to their async_ variants, so each alias has to be wrapped by name.
    QUERY_METHODS = {
      exec: 0, query: 0, async_exec: 0, sync_exec: 0,
      exec_params: 0, async_exec_params: 0, sync_exec_params: 0,
      prepare: nil, async_prepare: nil, sync_prepare: nil,
      exec_prepared: nil, async_exec_prepared: nil, sync_exec_prepared: nil,
      describe_prepared: nil, async_describe_prepared: nil, sync_describe_prepared: nil,
      send_query: 0, send_query_params: 0, send_query_prepared: nil, send_prepare: nil
    }.freeze

    def query_whitelisted?(sql)
      QUERY_WHITELIST =~ sql
    rescue ArgumentError
      return false unless sql.valid_encoding?

      raise
    end

    QUERY_METHODS.each do |method, sql_index|
      define_method(method) do |*args, **kwargs, &block|
        return super(*args, **kwargs, &block) if sql_index && query_whitelisted?(args[sql_index])

        acquire_semian_resource(adapter: :pg, scope: :query) do
          super(*args, **kwargs, &block)
        end
      end
    end

    # With the asynchronous API the statement is sent through one of the wrapped
    # send_* methods, but a statement failure only surfaces later, when
    # PG::Result#check is called outside of any wrapped call. This records it
    # against the circuit and tags it with the resource identifier, the way
    # acquire_semian_resource does. A connection lost while waiting for the result
    # is not recorded here; the next statement on the connection fails inside a
    # wrapped call and is counted there.
    def semian_record_failure(error)
      return if resource_already_acquired? || error.semian_identifier

      marks_circuit = !error.respond_to?(:marks_semian_circuits?) || error.marks_semian_circuits?
      semian_resource.mark_failed(error, scope: :query, adapter: :pg) if marks_circuit
      error.semian_identifier = semian_identifier
    end

    # Statement failures read with the asynchronous API are raised by PG::Result#check.
    module ResultCheck
      def check(*)
        super
      rescue *RESOURCE_EXCEPTIONS => e
        e.connection.semian_record_failure(e) if e.connection.respond_to?(:semian_record_failure)
        raise
      end
    end

    def with_resource_timeout(temp_timeout)
      prev_conn_timeout = conninfo_hash[:connect_timeout]
      begin
        @connect_timeout = temp_timeout
        yield
      ensure
        @connect_timeout = prev_conn_timeout
      end
    end

    # The pg gem defines some necessary methods on class level, which is why we have to hook into them.
    module ClassMethods
      def connect_start(*)
        conn = super
        conn.instance_variable_set(:@iopts, _iopts(*))
        conn
      end

      private

      def _iopts(*) # rubocop:disable Metrics/AbcSize
        option_string = parse_connect_args(*)
        iopts = conninfo_parse(option_string).each_with_object({}) do |h, o|
          o[h[:keyword].to_sym] = h[:val] if h[:val]
        end
        conndefaults.each_with_object({}) { |h, o| o[h[:keyword].to_sym] = h[:val] if h[:val] }.merge(iopts)
      end
    end
  end
end

PG::Connection.prepend(Semian::PG)
PG::Connection.singleton_class.prepend(Semian::PG::ClassMethods)
PG::Result.prepend(Semian::PG::ResultCheck)
