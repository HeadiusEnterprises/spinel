# frozen_string_literal: true

# Verify standalone BiteScript generation, JVM verification, and the selected classfile target.

require "fileutils"
require "tmpdir"
require "open3"
require_relative "../lib/spinel/jvm/bitescript"

module Spinel
  module JVM
    # Verifies class-file generation without the Spinel frontend.
    module BiteScriptSmokeTest
      module_function

      # Write a minimal Java 17 class that adds two integers and prints the result.
      def build(output_dir)
        builder = BiteScript::FileBuilder.build("bitescript_smoke_test.rb") do
          public_class "org/spinel/generated/BiteScriptSmoke" do
            public_static_method "main", [], void, string[] do
              line 17
              push_int 40
              push_int 2
              iadd
              invokestatic java.lang.String, "valueOf", [string, int]
              println string
              returnvoid
            end
          end
        end

        builder.generate do |filename, class_builder|
          path = File.join(output_dir, filename)
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, class_builder.generate)
        end
      end

      # Verify the generated class executes with output 42 and carries Java 17 classfile version 61.
      def run!
        Dir.mktmpdir("spinel-bitescript-") do |dir|
          build(dir)
          stdout, stderr, status = Open3.capture3(
            "java", "-Xverify:all", "-cp", dir,
            "org.spinel.generated.BiteScriptSmoke"
          )
          raise "bytecode verification failed:\n#{stderr}" unless status.success?
          raise "unexpected output: #{stdout.inspect}" unless stdout == "42\n"

          class_file = File.join(
            dir, "org/spinel/generated/BiteScriptSmoke.class"
          )
          bytes = File.binread(class_file)
          major = bytes.byteslice(6, 2).unpack1("n")
          raise "expected Java 17 class version 61, got #{major}" unless major == 61
        end

        puts "BiteScript smoke test passed (Java 17 class, verified execution)"
      end
    end
  end
end

Spinel::JVM::BiteScriptSmokeTest.run!
