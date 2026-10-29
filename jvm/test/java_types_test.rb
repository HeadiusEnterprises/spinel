# frozen_string_literal: true

# Verify generated Java types from Java callers and reject unsupported declarations or invalid overrides.

require "fileutils"
require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
backend = File.join(root, "jvm/bin/spinel-jvm")

# Run a fixture tool or program and return stdout, raising with its command and diagnostics on failure.
def run!(*command)
  out, error, status = Open3.capture3(*command)
  raise "#{command.join(" ")} failed:\n#{out}#{error}" unless status.success?

  out
end

Dir.mktmpdir("spinel-java-types-") do |dir|
  jar = File.join(dir, "types.jar")
  external = File.join(dir, "ExternalBase.java")
  File.write(external, <<~JAVA)
    package support;
    public abstract class ExternalBase {
      protected ExternalBase() {}
      protected abstract long calculate(long value);
      public long answer(long value) { return calculate(value); }
      public final long fixed() { return 42; }
    }
  JAVA
  overloaded = File.join(dir, "Overloaded.java")
  File.write(overloaded, <<~JAVA)
    package support;
    public interface Overloaded {
      long convert(long value);
      double convert(double value);
    }
  JAVA
  classes = File.join(dir, "classes")
  FileUtils.mkdir_p(classes)
  run!("javac", "-d", classes, external, overloaded)
  source = File.join(dir, "types.rb")
  File.write(source, File.read(File.join(__dir__, "fixtures/java_types.rb")) + <<~RUBY)
    java_import "support.ExternalBase", "support.Overloaded"
    # Implement a protected abstract Java method with an inferred descriptor.
    class Child < ExternalBase
      # Implement the inherited abstract calculation contract for Java override validation.
      def calculate(value)
        value * 2
      end
    end
    # Export two Java overloads from distinct Spinel method names.
    class Overloader
      include Overloaded
      java_signature "public long convert(long value)"
      # Export the long overload while retaining a distinct Spinel method name.
      def convert_integer(value)
        value
      end
      java_signature "public double convert(double value)"
      # Export the double overload while retaining a distinct Spinel method name.
      def convert_float(value)
        value
      end
    end
  RUBY
  run!("jruby", backend, "--class-path-entry", classes, source, "-o", jar)
  out = run!("java", "-Xverify:all", "-jar", jar)
  raise "unexpected Spinel output: #{out.inspect}" unless out == "3\n4.0\nRED\n2\nfalse\n"

  caller = File.join(dir, "Caller.java")
  File.write(caller, <<~JAVA)
    import example.spinel.*;
    import java.lang.reflect.Modifier;
    import java.util.Arrays;

    public class Caller {
      public static void main(String[] args) throws Exception {
        Worker worker = new Worker();
        Runnable runnable = worker;
        runnable.run();
        if (!worker.greet("hello").equals("hello")) throw new AssertionError();
        if (worker.twice(21) != 42) throw new AssertionError();
        if (!(worker instanceof java.util.TimerTask)) throw new AssertionError();
        if (!Greeter.class.isInterface()) throw new AssertionError();
        if (!Greeter.class.getMethod("twice", long.class).isDefault()) throw new AssertionError();
        if (!Modifier.isAbstract(Greeter.class.getMethod("greet", String.class).getModifiers())) throw new AssertionError();
        Greeter javaGreeter = name -> name;
        if (javaGreeter.twice(3) != 6) throw new AssertionError();
        if (!javaGreeter.welcome("hello").equals("hello")) throw new AssertionError();
        if (!worker.welcome("hello").equals("hello")) throw new AssertionError();
        if (!new GreetingClient().invoke(javaGreeter, "hello").equals("hello")) throw new AssertionError();
        Picker picker = new Picker() {
          public String pick(Object value) { return "object"; }
          public String pick(CharSequence value) { return "sequence"; }
        };
        PickingClient picking = new PickingClient();
        if (!picking.choose(picker).equals("sequence")) throw new AssertionError();
        if (!picking.chooseObject(picker).equals("object")) throw new AssertionError();
        if (new Child().answer(21) != 42) throw new AssertionError();
        support.Overloaded overloaded = new Overloader();
        if (overloaded.convert(21L) != 21L || overloaded.convert(2.5) != 2.5) throw new AssertionError();

        Point point = new Point(3, 4.0);
        if (!Point.class.isRecord() || !Modifier.isFinal(Point.class.getModifiers())) throw new AssertionError();
        if (point.x() != 3 || point.y() != 4.0) throw new AssertionError();
        if (point.twiceX() != 6) throw new AssertionError();
        if (new PointIdentity().identity(point) != point) throw new AssertionError();
        if (!point.equals(new Point(3, 4.0)) || point.equals(new Point(4, 3.0))) throw new AssertionError();
        if (point.equals(null) || point.equals("point")) throw new AssertionError();
        if (point.hashCode() != new Point(3, 4.0).hashCode()) throw new AssertionError();
        if (!point.toString().equals("Point[x=3, y=4.0]")) throw new AssertionError(point);
        if (!Point.class.getRecordComponents()[0].getName().equals("x")) throw new AssertionError();
        if (Point.class.getRecordComponents()[1].getType() != double.class) throw new AssertionError();
        if (!Modifier.isPrivate(Point.class.getDeclaredField("x").getModifiers())) throw new AssertionError();
        if (!Modifier.isFinal(Point.class.getDeclaredField("x").getModifiers())) throw new AssertionError();
        if (!Point.class.getConstructor(long.class, double.class).getParameters()[0].getName().equals("x")) throw new AssertionError();
        Primitives primitives = new Primitives(7, Float.NaN, true, "label");
        if (primitives.small() != 7 || !primitives.flag() || !primitives.label().equals("label")) throw new AssertionError();
        if (!primitives.equals(new Primitives(7, Float.NaN, true, "label"))) throw new AssertionError();

        if (!Color.class.isEnum()) throw new AssertionError();
        if (!Arrays.equals(Color.values(), new Color[] { Color.RED, Color.GREEN, Color.BLUE })) throw new AssertionError();
        Color[] copy = Color.values();
        copy[0] = Color.BLUE;
        if (Color.values()[0] != Color.RED) throw new AssertionError();
        if (Color.valueOf("GREEN") != Color.GREEN || Color.BLUE.ordinal() != 2) throw new AssertionError();
        if (Color.RED.code() != 42 || !Color.RED.name().equals("RED")) throw new AssertionError();
        switch (Color.BLUE) {
          case BLUE: break;
          default: throw new AssertionError();
        }
        System.out.println("Java callers passed");
      }
    }
  JAVA
  run!("javac", "-cp", [jar, classes].join(File::PATH_SEPARATOR), "-d", dir, caller)
  out = run!("java", "-Xverify:all", "-cp", [jar, classes, dir].join(File::PATH_SEPARATOR), "Caller")
  raise "unexpected Java caller output #{out.inspect}" unless out == "running\nJava callers passed\n"

  failures = {
    "missing interface method" => [<<~RUBY, "missing Java interface/abstract method run"],
      require "java"
      java_import "java.lang.Runnable"
      # Deliberately omit the required Runnable implementation.
      class Missing
        include Runnable
      end
    RUBY
    "final superclass" => [<<~RUBY, "extension of final Java class java.lang.String"],
      require "java"
      # Attempt to extend a final external Java class.
      class Bad < String
      end
    RUBY
    "no default constructor" => [<<~RUBY, "without an accessible no-argument constructor"],
      require "java"
      java_import "java.io.FilterInputStream"
      # Attempt inheritance without an accessible no-argument parent constructor.
      class Bad < FilterInputStream
      end
    RUBY
    "record component mismatch" => [<<~RUBY, "record component names/order differ"],
      require "java"
      # Deliberately mismatch the Data member and typed record component names.
      Point = Data.define(:x) do
        java_record y: Java::long
      end
    RUBY
    "record subclass" => [<<~RUBY, "subclassing final Java record"],
      require "java"
      # Declare a final record that the following class must not extend.
      Point = Data.define(:x) do
        java_record x: Java::long
      end
      # Attempt to extend a final generated record.
      class Child < Point
      end
    RUBY
    "duplicate enum constants" => [<<~RUBY, "duplicate Java enum constants"],
      require "java"
      # Deliberately repeat an enum constant name.
      class Color
        java_enum :RED, :RED
      end
    RUBY
    "untyped interface default" => [<<~RUBY, "interface default method without java_signature"],
      require "java"
      # Declare an interface default body without its required Java signature.
      module Bad
        java_interface
        # Provide a source body used to check interface typing or exported return-type validation.
        def count
          1
        end
      end
    RUBY
    "return mismatch" => [<<~RUBY, "return type string incompatible with java_signature long"],
      require "java"
      # Deliberately return a String from a long-valued Java export.
      class Bad
        java_signature "public long count()"
        # Provide a source body used to check interface typing or exported return-type validation.
        def count
          "wrong"
        end
      end
    RUBY
    "final method override" => [<<~RUBY, "override of final Java method fixed"],
      require "java"
      java_import "support.ExternalBase"
      # Satisfy the abstract method but attempt to override a final member.
      class Bad < ExternalBase
        # Implement the inherited abstract calculation contract for Java override validation.
        def calculate(value)
          value
        end
        # Attempt to replace a final inherited Java method so compilation must reject the override.
        def fixed
          1
        end
      end
    RUBY
    "duplicate abstract declaration" => [<<~RUBY, "duplicate exported Java method descriptor"],
      require "java"
      # Deliberately declare the same abstract Java method twice.
      module Bad
        java_interface
        java_abstract "void run()"
        java_abstract "void run()"
      end
    RUBY
    "overloaded override" => [<<~RUBY, "overloaded Java override submit; use java_signature"]
      require "java"
      java_import "java.util.concurrent.ForkJoinPool"
      # Leave an overloaded Java override ambiguous for descriptor inference.
      class Bad < ForkJoinPool
        # Leave an overloaded inherited method unannotated to require an explicit java_signature.
        def submit(value)
          true
        end
      end
    RUBY
  }
  failures.each_with_index do |(label, (source, diagnostic)), index|
    path = File.join(dir, "bad_#{index}.rb")
    File.write(path, source)
    _out, error, status = Open3.capture3("jruby", backend, "--class-path-entry", classes, path, "-o",
                                         File.join(dir, "bad.jar"))
    raise "#{label} compiled unexpectedly" if status.success?
    raise "#{label}: expected #{diagnostic.inspect}, got #{error}" unless error.include?(diagnostic)
  end
end

puts "Java interfaces, records, enums, and superclass integration passed"
