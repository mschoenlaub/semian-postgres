# frozen_string_literal: true

module TimeHelper
  def time_travel(val)  # rubocop:disable Metrics/AbcSize
    now_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    now_timestamp = Time.now

    new_monotonic = now_monotonic + val
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(new_monotonic)

    new_timestamp = now_timestamp + val
    allow(Time).to receive(:now).and_return(new_timestamp)

    yield
  ensure
    RSpec::Mocks.space.proxy_for(Time).reset
    RSpec::Mocks.space.proxy_for(Process).reset
  end
end

RSpec.configure do |config|
  config.include(TimeHelper)
end
