# frozen_string_literal: true

# Verify primitive recursion, loops, comparisons, and value-producing conditionals end to end.

require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
spinel = File.join(root, "bin/spinel")
backend = File.join(root, "jvm/bin/spinel-jvm")

Dir.mktmpdir("spinel-jvm-scalar-") do |dir|
  source_file = File.join(dir, "sample.rb")
  jar = File.join(dir, "sample.jar")
  source = <<~RUBY
    # Exercise recursive integer calls and value-producing conditional branches.
    def fib(n)
      if n < 2
        n
      else
        fib(n - 1) + fib(n - 2)
      end
    end

    # Exercise an unless expression with integer results on both branches.
    def magnitude(n)
      unless n < 0
        n
      else
        0 - n
      end
    end

    i = 0
    sum = 0
    while i < 5
      sum = sum + i
      i = i + 1
    end
    j = 0
    until j >= 3
      j = j + 1
    end
    puts fib(10)
    puts sum
    puts magnitude(-7)
    puts j
    if sum == 10
      puts "branch"
    end
    puts "ok"
  RUBY
  File.write(source_file, source)

  _out, error, status = Open3.capture3(
    "jruby", backend, source_file, "--spinel", spinel, "-o", jar
  )
  raise "JVM compilation failed: #{error}" unless status.success?

  out, error, status = Open3.capture3("java", "-Xverify:all", "-jar", jar)
  raise "generated program failed: #{error}" unless status.success?

  expected = "55\n10\n7\n3\nbranch\nok\n"
  raise "unexpected generated output #{out.inspect}" unless out == expected
end

puts "Scalar IR-to-JAR test passed"
