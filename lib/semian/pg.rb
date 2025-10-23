# frozen_string_literal: true

require 'semian/pg/version'
require 'semian/adapter'
require 'pg'

# We need to patch the actual pg gem to decorate the base errors such as PG::Error
module PG
  ::PG::Error.include(Semian::AdapterError)
  ::PG::QueryCanceled.class_eval do
    def marks_semian_circuits?
      message != ~/canceling statement due to statement timeout/
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

    def resource_exceptions
      [::PG::ConnectionBad, ::PG::QueryCanceled].freeze
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

    QUERY_METHODS = %i[query exec exec_params].freeze

    def query_whitelisted?(sql)
      QUERY_WHITELIST =~ sql
    rescue ArgumentError
      return false unless sql.valid_encoding?

      raise
    end

    QUERY_METHODS.each do |method|
      define_method(method) do |*args, &block|
        return super(*args, &block) if query_whitelisted?(args[0])

        acquire_semian_resource(adapter: :pg, scope: :query) do
          super(*args, &block)
        end
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
