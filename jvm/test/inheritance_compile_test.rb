# frozen_string_literal: true

# Verify inherited initialization and virtual dispatch through a generated superclass method.

require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
spinel = File.join(root, "bin/spinel")
backend = File.join(root, "jvm/bin/spinel-jvm")

Dir.mktmpdir("spinel-jvm-inheritance-") do |dir|
  source_file = File.join(__dir__, "fixtures/inheritance.rb")
  jar = File.join(dir, "inheritance.jar")

  _out, error, status = Open3.capture3(
    "jruby", backend, source_file, "--spinel", spinel, "-o", jar
  )
  raise "JVM inheritance compilation failed: #{error}" unless status.success?

  out, error, status = Open3.capture3("java", "-Xverify:all", "-jar", jar)
  raise "generated inheritance program failed: #{error}" unless status.success?
  raise "virtual override did not dispatch: #{out.inspect}" unless out == "21\n"
end

puts "Inheritance IR-to-JAR test passed"
