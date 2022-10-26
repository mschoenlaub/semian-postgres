# frozen_string_literal: true

module BackgroundHelpers
  attr_writer :threads

  private

  def background(&block)
    thread = Thread.new(&block)
    thread.report_on_exception = false
    threads << thread
    thread.join(0.1)
    thread
  end

  def threads
    @threads ||= []
  end

  def yield_to_background
    threads.each(&:join)
  end
end

RSpec.configure do |config|
  config.after do
    threads.each(&:kill)
    self.threads = []
  end
  config.include(BackgroundHelpers)
end
