# frozen_string_literal: true

# Verify manifest-selected JVM builds and execution with an external Java class directory.

require "fileutils"
require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
spin = File.join(root, "tools/spin.rb")

# Run spin under CRuby without inheriting activation of the JRuby test bundle.
def capture_spin(...)
  return Open3.capture3(...) unless defined?(Bundler)

  Bundler.with_unbundled_env { Open3.capture3(...) }
end

Dir.mktmpdir("spinel-spin-jvm-") do |project|
  FileUtils.mkdir_p(File.join(project, "bin"))
  FileUtils.mkdir_p(File.join(project, "classes/example"))
  java_source = File.join(project, "External.java")
  File.write(java_source, <<~JAVA)
    package example;
    public final class External {
      public static long answer() { return 42L; }
    }
  JAVA
  _out, error, status = Open3.capture3(
    "javac", "-d", File.join(project, "classes"), java_source
  )
  raise "spin Java fixture compilation failed: #{error}" unless status.success?

  File.write(File.join(project, "spin.toml"), <<~TOML)
    [build]
    backend = "jvm"

    [jvm]
    release = 17
    class_dirs = ["classes"]
  TOML
  File.write(File.join(project, "bin/app.rb"), <<~RUBY)
    require "java"
    java_import "example.External"
    puts External.answer
  RUBY

  env = { "PATH" => "#{File.join(root, "bin")}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH", "")}" }
  out, error, status = capture_spin(
    env, "ruby", "-I", File.join(root, "build"), spin, "build", chdir: project
  )
  raise "spin JVM build failed: #{out}#{error}" unless status.success?

  jar = File.join(project, "build/jvm/app.jar")
  runtime_classpath = [jar, File.join(project, "classes")].join(File::PATH_SEPARATOR)
  out, error, status = Open3.capture3(
    "java", "-Xverify:all", "-cp", runtime_classpath,
    "org.spinel.generated.SpinelMain"
  )
  raise "spin JVM application failed: #{error}" unless status.success?
  raise "unexpected spin JVM output #{out.inspect}" unless out == "42\n"

  out, error, status = capture_spin(
    env, "ruby", "-I", File.join(root, "build"), spin, "run", chdir: project
  )
  raise "spin JVM run failed: #{out}#{error}" unless status.success?
  raise "spin JVM run did not execute the application: #{out.inspect}" unless out.lines.last == "42\n"
end

puts "spin JVM integration test passed"
