# frozen_string_literal: true

# Check boxed Ruby semantics, bundled runtime contents, file lifetimes, and failure diagnostics.

require "open3"
require "tmpdir"
require_relative "../lib/spinel/jvm/compiler"

root = File.expand_path("../..", __dir__)
frontend = File.join(root, "bin/spinel")

Dir.mktmpdir("spinel-jvm-core-") do |dir|
  # Export each source through the frontend and compile its IR into the requested JAR.
  compile = lambda do |source, output|
    ir_path = File.join(dir, "input.spir.json")
    _out, error, status = Open3.capture3(frontend, source, "--emit-backend-ir", "-o", ir_path)
    raise "core frontend failed: #{error}" unless status.success?

    Spinel::JVM::Compiler.new(Spinel::JVM::IR.load(ir_path)).compile(output)
  end
  fixture = File.join(__dir__, "fixtures/core.rb")
  jar = File.join(dir, "core.jar")
  compile.call(fixture, jar)
  begin
    ir = Spinel::JVM::IR.load(File.join(dir, "input.spir.json"))
    Spinel::JVM::Compiler.new(ir, classpath: [File.join(dir, "missing.jar")])
    raise "missing Java classpath was accepted on the core path"
  rescue Spinel::JVM::UnsupportedNode => error
    raise unless error.message.include?("Java classpath entry does not exist")
  end
  out, error, status = Open3.capture3("java", "-Xverify:all", "-jar", jar)
  raise "core program failed: #{error}" unless status.success?

  expected = File.binread("#{fixture}.expected")
  raise "unexpected core output:\n#{out}" unless out.b == expected

  listing, error, status = Open3.capture3("jar", "tf", jar)
  raise "could not inspect core JAR: #{error}" unless status.success?
  raise "core runtime is absent" unless listing.include?("org/spinel/runtime/Core.class")
  raise "generated program depends on JRuby" if listing.include?("org/jruby/")

  io_source = File.join(dir, "io.rb")
  File.write(io_source, <<~RUBY)
    File.open(ARGV[0], "w") { |file| file.write("first\\nlast") }
    lines = []
    File.open(ARGV[0], "r") { |file| file.each_line { |line| lines << line } }
    p lines
  RUBY
  compile.call(io_source, jar)
  out, error, status = Open3.capture3("java", "-Xverify:all", "-jar", jar, File.join(dir, "lines.txt"))
  unless status.success? && out == "[\"first\\n\", \"last\"]\n"
    raise "unterminated last line was changed: #{out}#{error}"
  end

  {
    "frozen" => ["a = []; s = 'frozen'; s << 'x'", "FrozenError"],
    "array_index" => ["a = [1]; a[-2] = 7", "IndexError"],
    "missing_keyword" => ["def f(left:); left; end; puts f", "missing keyword: left"],
    "unknown_keyword" => ["def f(left:); left; end; puts f(left: 1, other: 2)", "unknown keyword: other"],
    "string_coercion" => ["a = []; puts 'value=' + 1", "TypeError"],
    "thread_failure" => ["threads = [Thread.new { raise 'worker failed' }]; threads[0].value", "worker failed"]
  }.each do |label, (source, diagnostic)|
    path = File.join(dir, "#{label}.rb")
    File.write(path, source)
    compile.call(path, jar)
    _out, error, status = Open3.capture3("java", "-Xverify:all", "-jar", jar)
    raise "#{label} did not fail with #{diagnostic}: #{error}" if status.success? || !error.include?(diagnostic)
  end
end

puts "JVM core values, lexical captures, control flow, and threads passed"
