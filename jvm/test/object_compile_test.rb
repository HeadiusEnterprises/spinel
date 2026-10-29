# frozen_string_literal: true

# Verify generated object allocation, typed fields, mutation, and instance-method calls.

require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
spinel = File.join(root, "bin/spinel")
backend = File.join(root, "jvm/bin/spinel-jvm")

Dir.mktmpdir("spinel-jvm-object-") do |dir|
  source_file = File.join(dir, "counter.rb")
  jar = File.join(dir, "counter.jar")
  source = <<~RUBY
    # Mutable object used to verify typed storage and compiled method dispatch.
    class Counter
      # Initialize the typed field through the Spinel construction path.
      def initialize(start)
        @value = start
      end

      # Mutate the instance field and return the assigned integer.
      def add(delta)
        @value = @value + delta
      end

      # Return the current instance field through a compiled method.
      def value
        @value
      end

      # Exercise receiver-free calls to another generated instance method.
      def double
        value + value
      end
    end

    counter = Counter.new(5)
    puts counter.add(7)
    puts counter.value
    puts counter.double
  RUBY
  File.write(source_file, source)

  _out, error, status = Open3.capture3(
    "jruby", backend, source_file, "--spinel", spinel, "-o", jar
  )
  raise "JVM object compilation failed: #{error}" unless status.success?

  listing, error, status = Open3.capture3("jar", "tf", jar)
  raise "could not inspect generated JAR: #{error}" unless status.success?
  raise "generated object class is absent" unless listing.include?("org/spinel/generated/Counter.class")

  out, error, status = Open3.capture3("java", "-Xverify:all", "-jar", jar)
  raise "generated object program failed: #{error}" unless status.success?
  raise "unexpected generated output #{out.inspect}" unless out == "12\n12\n24\n"
end

puts "Object IR-to-JAR test passed"
