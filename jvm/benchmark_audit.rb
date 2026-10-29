# frozen_string_literal: true

# Audit benchmark compilation and optionally verify bounded execution against exact expected output.

require "open3"
require "tmpdir"
require "optparse"
require "json"
require_relative "lib/spinel/jvm/compiler"

module Spinel
  module JVM
    # Compiles benchmarks and optionally compares their exact stdout.
    class BenchmarkAudit
      # Record execution/report options and initialize per-benchmark results and node/call inventories.
      def initialize(run:, timeout:, inventory:, report:, selected:)
        @root = File.expand_path("..", __dir__)
        @run = run
        @timeout = timeout
        @inventory = inventory
        @report = report
        @selected = selected
        @results = []
        @node_counts = Hash.new(0)
        @call_counts = Hash.new(0)
      end

      # Audit selected benchmark sources in temporary storage, print a summary, and return overall success.
      def run
        Dir.mktmpdir("spinel-benchmark-audit-") do |directory|
          Dir.glob(File.join(@root, "benchmark/*.rb")).each do |source|
            next if !@selected.empty? && @selected.none? { |pattern| File.basename(source).include?(pattern) }

            audit(source, directory)
          end
        end
        summarize
        @results.all? { |result| result[:status] == (@run ? "PASSED" : "COMPILED") }
      end

      private

      # Compile one benchmark, optionally execute it, and record failures without stopping the remaining audit.
      def audit(source, directory)
        result = { source: File.basename(source) }
        @results << result
        ir = load_ir(source, directory, result)
        return unless ir

        jar = File.join(directory, "output.jar")
        compiler = Compiler.new(ir)
        compiler.compile(jar)
        result.merge!(engine: compiler.engine, status: "COMPILED")
        if @run
          execute(source, jar, directory, result)
        else
          puts "#{result[:source]} COMPILED"
        end
      rescue StandardError => error
        result.merge!(status: "COMPILE_FAILED", diagnostic: error.message)
        puts "#{result[:source]} #{error.class}: #{error.message}"
      end

      # Export and validate a benchmark's IR, recording frontend failures and accumulating syntax inventories.
      def load_ir(source, directory, result)
        path = File.join(directory, "input.spir.json")
        _stdout, error, status = Open3.capture3(File.join(@root, "bin/spinel"),
                                                source, "--emit-backend-ir", "-o", path)
        unless status.success?
          result.merge!(status: "FRONTEND_FAILED", error: error)
          puts "#{result[:source]} FRONTEND #{error.lines.first}"
          return nil
        end
        ir = IR.load(path)
        ir.nodes.each_value do |node|
          @node_counts[node["kind"]] += 1
          @call_counts[node.dig("strings", "name")] += 1 if node["kind"] == "CallNode"
        end
        ir
      end

      # Run a verified JAR with a heap limit, isolated working directory, and timeout.
      # Protect the fixed I/O fixture path and compare completed runs against checked-in stdout.
      def execute(source, jar, directory, result)
        if result[:source] == "bm_io_wordcount.rb" && File.exist?("/tmp/spinel_io_wf.txt")
          result[:status] = "FIXTURE_COLLISION"
          puts "#{result[:source]} FIXTURE_COLLISION /tmp/spinel_io_wf.txt already exists"
          return
        end
        stdout = File.join(directory, "stdout")
        stderr = File.join(directory, "stderr")
        builder = java.lang.ProcessBuilder.new(["java", "-Xverify:all", "-Xmx768m", "-jar", jar].to_java(:string))
        builder.redirect_output(java.io.File.new(stdout))
        builder.redirect_error(java.io.File.new(stderr))
        builder.directory(java.io.File.new(directory))
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        process = builder.start
        unless process.wait_for(@timeout, java.util.concurrent.TimeUnit::SECONDS)
          process.destroy_forcibly.wait_for
          result[:status] = "TIMEOUT"
          puts "#{result[:source]} TIMEOUT"
          return
        end
        state = compare_output(source, process.exit_value, stdout, stderr)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        result.merge!(status: state.split.first, seconds: elapsed)
        result[:diagnostic] = state unless state == "PASSED"
        puts "#{result[:source]} #{state} (#{elapsed.round(3)}s)"
      end

      # Return a pass/failure diagnostic from the exit status and exact binary stdout comparison.
      def compare_output(source, exit_value, stdout, stderr)
        return "FAILED #{File.binread(stderr).lines.first(8).join.strip}" unless exit_value.zero?

        actual = File.binread(stdout)
        expected = File.binread("#{source}.expected")
        return "PASSED" if actual == expected

        "MISMATCH expected=#{expected.byteslice(0, 160).inspect} actual=#{actual.byteslice(0, 160).inspect}"
      end

      # Print optional inventories, write the JSON report, and summarize results; reject an empty selection.
      def summarize
        puts "NODES #{@node_counts.sort.to_h.inspect}" if @inventory
        puts "CALLS #{@call_counts.sort_by { |name, _count| name.to_s }.to_h.inspect}" if @inventory
        if @report
          File.write(@report, "#{JSON.pretty_generate({ format: "spinel-jvm-benchmarks-v1", results: @results })}\n")
        end
        expected_status = @run ? "PASSED" : "COMPILED"
        passed = @results.count { |result| result[:status] == expected_status }
        description = @run ? "matched checked-in output" : "compiled"
        puts "#{passed}/#{@results.length} benchmarks #{description}"
        abort "no benchmarks matched" if @results.empty?
      end
    end
  end
end

$stdout.sync = true
# Parse audit options and name filters before returning the aggregate process status.
options = { run: false, inventory: false, timeout: 180, report: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: jruby jvm/benchmark_audit.rb [options] [benchmark name fragments]"
  parser.on("--run", "Run JARs and compare exact checked-in stdout") { options[:run] = true }
  parser.on("--inventory", "Print node and call inventories") { options[:inventory] = true }
  parser.on("--timeout SECONDS", Integer, "Per-program runtime limit (default 180)") do |value|
    options[:timeout] = value
  end
  parser.on("--report FILE", "Write JSON results") { |value| options[:report] = value }
end.parse!
abort "timeout must be positive" unless options[:timeout].positive?
exit(Spinel::JVM::BenchmarkAudit.new(**options, selected: ARGV).run ? 0 : 1)
