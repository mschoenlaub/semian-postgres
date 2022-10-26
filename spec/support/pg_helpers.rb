# frozen_string_literal: true

module PGHelpers
  def connect_to_pg!
    PG::Connection.connect(
      connect_timeout: 2,
      host: TOXIPROXY_HOST,
      port: 8475
    )
  end
end

RSpec.configure do |config|
  config.include(PGHelpers)
end
