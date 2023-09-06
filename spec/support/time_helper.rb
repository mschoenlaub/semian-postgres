# frozen_string_literal: true
module TimeHelper
  def time_travel(val)
    now_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    now_timestamp = Time.now

    new_monotonic = now_monotonic + val
    Process.stub(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(new_monotonic)

    new_timestamp = now_timestamp + val
    Time.stub(:now).and_return(new_timestamp)

    yield
  ensure
    Time.unstub(:now)
    Process.unstub(:clock_gettime)
  end
end

RSpec.configure do |config|
  config.include(TimeHelper)
end
