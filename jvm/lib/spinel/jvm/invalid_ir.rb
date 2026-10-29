# frozen_string_literal: true

module Spinel
  module JVM
    # The serialized IR violates the backend format contract.
    class InvalidIR < StandardError; end
  end
end
