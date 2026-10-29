# frozen_string_literal: true

# Verify deterministic IR export, inferred metadata, schema rejection, and Java feature preservation.

require "json"
require "open3"
require "tmpdir"
require_relative "../lib/spinel/jvm/ir"

root = File.expand_path("../..", __dir__)
spinel = File.join(root, "bin/spinel")
abort "build bin/spinel first" unless File.executable?(spinel)

Dir.mktmpdir("spinel-ir-") do |dir|
  path = File.join(dir, "sample.spir.json")
  second_path = File.join(dir, "sample-again.spir.json")
  source_path = File.join(dir, "sample.rb")
  source = "def twice(n); n * 2; end; puts twice(21)"
  File.write(source_path, source)
  _stdout, stderr, status = Open3.capture3(
    spinel, source_path, "--emit-backend-ir", "-o", path
  )
  raise "IR export failed: #{stderr}" unless status.success?

  _stdout, stderr, status = Open3.capture3(
    spinel, source_path, "--emit-backend-ir", "-o", second_path
  )
  raise "second IR export failed: #{stderr}" unless status.success?
  raise "IR export is not deterministic" unless File.binread(path) == File.binread(second_path)

  ir = Spinel::JVM::IR.load(path)
  raise "missing analyzed nodes" if ir.nodes.empty?
  raise "missing method scope" unless ir.scopes.values.any? { |s| s["name"] == "twice" }

  twice = ir.scopes.values.find { |s| s["name"] == "twice" }
  raise "wrong inferred return type" unless twice["return_type"] == "int"
  raise "wrong inferred parameter type" unless twice["locals"].first["type"] == "int"

  syntax = ir.data.fetch("syntax")
  raise "missing lexical root" unless syntax["nodes"].any? do |node|
    node["id"] == syntax["root"] && node["kind"] == "ProgramNode"
  end

  damaged_syntax = JSON.parse(File.binread(path))
  damaged_syntax["syntax"]["root"] = 999_999
  begin
    Spinel::JVM::IR.new(damaged_syntax)
    raise "invalid lexical syntax root accepted"
  rescue Spinel::JVM::InvalidIR => error
    raise unless error.message.include?("missing lexical syntax node")
  end

  damaged = JSON.parse(File.binread(path))
  damaged["version"] = 999
  begin
    Spinel::JVM::IR.new(damaged)
    raise "unsupported version was accepted"
  rescue Spinel::JVM::InvalidIR => error
    raise unless error.message.include?("unsupported analyzed IR version")
  end

  File.write(source_path, "require 'java'; puts System.currentTimeMillis > 0")
  _stdout, stderr, status = Open3.capture3(spinel, source_path, "--emit-backend-ir", "-o", path)
  raise "Java feature IR export failed: #{stderr}" unless status.success?
  raise "Java feature boundary was lost" unless Spinel::JVM::IR.load(path).data.fetch("features").include?("java")
end

puts "Analyzed IR export/read test passed"
