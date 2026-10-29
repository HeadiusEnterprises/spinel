# frozen_string_literal: true

require "open3"
require "tmpdir"

module Spinel
  module JVM
    # Compiles the bundled runtime once per compiler process.
    module RuntimeSupport
      # Compile the Java 17 runtime in a temporary directory and cache its class bytes by JAR entry name.
      # Raise a compiler error if javac fails; remove temporary output after collecting the classes.
      def self.classes
        @classes ||= Dir.mktmpdir("spinel-jvm-runtime-") do |dir|
          source = File.expand_path("../../../runtime/org/spinel/runtime/Core.java", __dir__)
          out, error, status = Open3.capture3("javac", "--release", "17", "-d", dir, source)
          raise UnsupportedNode, "JVM runtime compilation failed: #{out}#{error}" unless status.success?

          Dir.glob(File.join(dir, "**/*.class")).to_h do |path|
            [path.delete_prefix("#{dir}/"), File.binread(path)]
          end.freeze
        end
      end
    end
  end
end
