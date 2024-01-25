# frozen_string_literal: true

require 'benchmark'
module SemianHelpers
  def with_semian_configuration(options) # rubocop:disable Metrics/AbcSize
    orig_semian_options = Semian::PG.semian_configuration
    Semian::PG.instance_variable_set(:@semian_configuration, nil)
    mutated_objects = {}
    Semian::PG.send(:alias_method, :orig_semian_resource, :semian_resource)
    Semian::PG.send(:alias_method, :orig_raw_semian_options, :raw_semian_options)
    Semian::PG.send(:define_method, :semian_resource) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_semian_resource
    end
    Semian::PG.send(:define_method, :raw_semian_options) do
      mutated_objects[self] = [@semian_resource, @raw_semian_options] unless mutated_objects.key?(self)
      orig_raw_semian_options
    end

    Semian::PG.semian_configuration = options
    yield
  ensure
    Semian::PG.instance_variable_set(:@semian_configuration, nil)
    Semian::PG.semian_configuration = orig_semian_options
    Semian::PG.send(:alias_method, :semian_resource, :orig_semian_resource)
    Semian::PG.send(:alias_method, :raw_semian_options, :orig_raw_semian_options)
    Semian::PG.send(:undef_method, :orig_semian_resource, :orig_raw_semian_options)
    mutated_objects.each do |instance, (res, opt)|
      instance.instance_variable_set(:@semian_resource, res)
      instance.instance_variable_set(:@raw_semian_options, opt)
    end
  end
end

RSpec.configure do |config|
  config.include(SemianHelpers)

  RSpec::Matchers.define :timeout_within do |delta|
    chain :of, :expected
    match do |block|
      latency = ((expected + (3 * delta)) * 1000).to_i

      bench = Benchmark.measure do
        expect { proxy.downstream(:latency, latency: latency).apply(&block) }.to raise_error(PG::Error)
      end

      expect(bench.real).to be_within(delta).of(expected)
    end
    failure_message do |block|
      "expected that #{block} would timeout within #{delta} seconds of #{expected} seconds"
    end
    supports_block_expectations
  end
end
