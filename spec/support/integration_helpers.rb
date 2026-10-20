# frozen_string_literal: true

# Consumers such as Active Record and Sequel wrap driver errors in their own
# exception classes, so the adapter's errors have to be found in the cause chain.
RSpec::Matchers.define :be_caused_by do |error_class|
  match do |error|
    causes = []
    while error
      causes << error
      error = error.cause
    end
    causes.any?(error_class)
  end
  failure_message do |error|
    "expected #{error.class} to have #{error_class} in its cause chain"
  end
end
