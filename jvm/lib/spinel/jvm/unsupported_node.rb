# frozen_string_literal: true

module Spinel
  module JVM
    # The IR needs a lowering or runtime operation that is not implemented.
    class UnsupportedNode < StandardError; end
  end
end
