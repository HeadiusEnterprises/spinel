# frozen_string_literal: true

# Verify classpath imports, Java signatures, overloads, and allocation-free range loops with Java calls.

require "fileutils"
require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
spinel = File.join(root, "bin/spinel")
backend = File.join(root, "jvm/bin/spinel-jvm")

Dir.mktmpdir("spinel-jvm-java-") do |dir|
  classes = File.join(dir, "classes")
  package_dir = File.join(dir, "java/example")
  FileUtils.mkdir_p(package_dir)
  FileUtils.mkdir_p(classes)
  java_source = File.join(package_dir, "ExternalMath.java")
  File.write(java_source, <<~JAVA)
    package example;

    public final class ExternalMath {
      public static long triple(long value) { return value * 3; }
      public static int small() { return 7; }
      public static float half(float value) { return value / 2.0f; }
      public static boolean positive(long value) { return value > 0; }
      public static String greeting() { return "hello from Java"; }
      public static ExternalMath create(String prefix) { return new ExternalMath(prefix); }
      public static String describe(ExternalMath value) { return value.render(6); }
      public static CharSequence sequence() { return "four"; }
      public static String choose(long value) { return "long=" + value; }
      public static String choose(double value) { return "double=" + value; }
      public static String specific(Object value) { return "object"; }
      public static String specific(CharSequence value) { return "sequence"; }
      public static String ambiguous(String value) { return "string"; }
      public static String ambiguous(StringBuilder value) { return "builder"; }

      private final String prefix;
      public ExternalMath(String prefix) { this.prefix = prefix; }
      public ExternalMath append(long value) { return new ExternalMath(prefix + value + ":"); }
      public String render(long value) { return prefix + value; }
      public String overloaded(long value) { return "instance-long=" + value; }
      public String overloaded(double value) { return "instance-double=" + value; }
    }
  JAVA
  _out, error, status = Open3.capture3("javac", "-d", classes, java_source)
  raise "Java fixture compilation failed: #{error}" unless status.success?

  source_file = File.join(dir, "interop.rb")
  jar = File.join(dir, "interop.jar")
  File.write(source_file, <<~RUBY)
    require "java"
    java_import "example.ExternalMath", java.lang.StringBuilder

    puts ExternalMath.triple(14)
    puts ExternalMath.small
    puts ExternalMath.half(8.0)
    puts ExternalMath.positive(1)
    puts ExternalMath.greeting
    puts ExternalMath.java_send(:greeting)
    puts System.currentTimeMillis > 0
    box = ExternalMath.new("value=")
    puts box.render(9)
    puts box.append(4).render(5)
    created = ExternalMath.create("created=")
    puts created.render(8)
    puts ExternalMath.describe(created)
    sequence = ExternalMath.sequence
    puts sequence.length
    message = ExternalMath.greeting
    puts message
    puts ExternalMath.java_send(:choose, [Java::double], 2.0)
    puts ExternalMath.specific("x")
    puts ExternalMath.java_send(:specific, [java.lang.Object], "x")
    puts box.java_send(:overloaded, [Java::long], 7)
    builder = StringBuilder.new("builder=")
    builder.append(3)
    puts builder.toString

    # Expose renamed long/int members and throws metadata to Java callers.
    class JavaVisible
      java_signature "public long identity(long value) throws java.io.IOException"
      # Export a long-valued identity method with a renamed Java member and throws clause.
      def ruby_identity(value)
        value
      end

      java_signature "public int narrow(int value)"
      # Exercise the int-to-Spinel-long argument and return conversion boundary.
      def ruby_narrow(value)
        value
      end
    end

    visible = JavaVisible.new
    puts visible.ruby_identity(11)
    puts visible.ruby_narrow(12)
  RUBY

  _out, error, status = Open3.capture3(
    "jruby", backend, "--require-gate", "--class-path-entry", classes,
    source_file, "--spinel", spinel, "-o", jar
  )
  raise "JVM Java interop compilation failed: #{error}" unless status.success?

  runtime_classpath = [jar, classes].join(File::PATH_SEPARATOR)
  out, error, status = Open3.capture3(
    "java", "-Xverify:all", "-cp", runtime_classpath,
    "org.spinel.generated.SpinelMain"
  )
  raise "generated Java interop program failed: #{error}" unless status.success?

  expected = <<~OUTPUT
    42
    7
    4.0
    true
    hello from Java
    hello from Java
    true
    value=9
    value=4:5
    created=8
    created=6
    4
    hello from Java
    double=2.0
    sequence
    object
    instance-long=7
    builder=3
    11
    12
  OUTPUT
  raise "unexpected Java interop output #{out.inspect}" unless out == expected

  javap, error, status = Open3.capture3(
    "javap", "-classpath", jar, "org.spinel.generated.JavaVisible"
  )
  raise "javap failed: #{error}" unless status.success?
  raise "java_signature did not export the JRuby name and descriptor" unless
    javap.include?("public long identity(long) throws java.io.IOException;") &&
    javap.include?("public int narrow(int);")

  ambiguous_source = File.join(dir, "ambiguous.rb")
  File.write(ambiguous_source, <<~RUBY)
    require "java"
    java_import "example.ExternalMath"
    puts ExternalMath.ambiguous(nil)
  RUBY
  _out, error, status = Open3.capture3(
    "jruby", backend, "--require-gate", "--class-path-entry", classes,
    ambiguous_source, "--spinel", spinel, "-o", File.join(dir, "ambiguous.jar")
  )
  raise "ambiguous Java overload compiled successfully" if status.success?
  raise "ambiguous Java overload did not recommend java_send: #{error}" unless
    error.include?("ambiguous Java call") && error.include?("use java_send")

  range_source = File.join(__dir__, "fixtures/java_range_each.rb")
  _out, error, status = Open3.capture3(
    "jruby", backend, "--require-gate", range_source, "--spinel", spinel, "-o", jar
  )
  raise "Java timing with Range#each did not compile: #{error}" unless status.success?

  range_stdout = File.join(dir, "range.stdout")
  range_stderr = File.join(dir, "range.stderr")
  builder = java.lang.ProcessBuilder.new(["java", "-Xverify:all", "-jar", jar].to_java(:string))
  builder.redirect_output(java.io.File.new(range_stdout))
  builder.redirect_error(java.io.File.new(range_stderr))
  process = builder.start
  unless process.wait_for(15, java.util.concurrent.TimeUnit::SECONDS)
    process.destroy_forcibly.wait_for
    raise "Java Range#each did not terminate (check terminal-bound overflow)"
  end
  out = File.binread(range_stdout)
  raise "Java timing with Range#each failed: #{File.binread(range_stderr)}" unless process.exit_value.zero?
  raise "unexpected Java Range#each output #{out.inspect}" unless
    out.b == File.binread("#{range_source}.expected")

  listing, error, status = Open3.capture3("javap", "-c", "-classpath", jar, "org.spinel.generated.SpinelMain")
  raise "could not inspect Java Range#each bytecode: #{error}" unless status.success?
  raise "Java timing was not compiled as a direct call" unless listing.include?("java/lang/System.currentTimeMillis")
  raise "integer modulo was not compiled with Ruby sign semantics" unless listing.include?("java/lang/Math.floorMod")
end

puts "Java classpath interop test passed"
