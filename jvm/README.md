# Spinel JVM backend

Status: experimental. The current implementation emits Java 17 classes.
The revised target is Java 25; that migration, virtual-thread fibers,
record-based value-doubles, and Panama integration are planned, not yet
implemented. Documentation:

- [Prototype milestone 1 and new-chat restart context](MILESTONE_1.md)
- [Java 25 implementation plan](IMPLEMENTATION_PLAN.md)
- [Panama FFI/native binding and optional Spinel C API plan](PANAMA.md)
- [Current checkpoint commit/push assessment](COMMIT_READINESS.md)
- [Development, style, and verification](DEVELOPMENT.md)

The JVM backend runs on JRuby and emits Java class files through BiteScript.
Generated programs depend on the bundled Spinel JVM runtime, not on JRuby.
The compiler requires JRuby, BiteScript, and a JDK with `javac` (Java 17 or
newer). Generated JARs are standalone Java 17 applications; JRuby is needed
only during compilation.

The published BiteScript 0.1.4 adapter predates modern ASM metadata constants.
`lib/spinel/jvm/bitescript.rb` supplies the compatibility boundary, selects
Java 17 class files, and leaves frame/max-stack computation to JRuby's bundled
ASM.

Run the toolchain check with:

```sh
cd jvm
jruby -S bundle install
jruby -rbundler/setup -S rake
```

The compiler-side boundary is `spinel --emit-backend-ir`, which writes a
versioned `.spir.json` file containing the post-desugaring node table, inferred
node/scope/local/ivar types, nilability and capture flags, and program tables.

The executable slice supports scalar literals and locals, checked integer
arithmetic, float arithmetic, comparisons, `if`/`unless`, `while`/`until`,
fixed-arity top-level methods, direct and recursive calls, user-object
allocation, typed instance fields, fixed-arity instance methods, single
inheritance with inherited initialization, virtual overrides, and `puts`:

```sh
jruby jvm/bin/spinel-jvm app.rb -o app.jar
java -jar app.jar
```

Passing an already exported `.spir.json` file skips the frontend and is useful
for backend development.

### Ruby core and benchmark coverage

All 62 original programs in `benchmark/` compile and matched their checked-in
stdout with JVM verification enabled in the milestone-1 source snapshot on
JDK 25. This includes `bm_sudoku.rb` and its `int_array` locals. The original
workspace also retains an uncommitted infinite Java-timed `bm_range_each.rb`;
that personal driver is not part of the checkpoint and must be excluded from
expected-output execution in that workspace. Run the committed corpus with:

```sh
make jvm-bench
# Or select programs and save machine-readable results:
jruby jvm/benchmark_audit.rb --run --report /tmp/jvm-benchmarks.json sudoku nbody
```

`make jvm-test` includes core semantic regressions and compilation of every
benchmark. The full benchmark execution is an explicit `jvm-bench` target.
Each benchmark has a 180-second runtime limit, adjustable with `--timeout`.
The runner compares binary stdout exactly, including image-producing
benchmarks, and keeps timing diagnostics on stderr outside that comparison.
It refuses to overwrite an existing `/tmp/spinel_io_wf.txt` fixture.

The extended lowering supports resizable and sparse arrays, nested arrays,
ordered hashes, mutable strings and byte operations, interpolation, constants
and globals, short-circuit expressions, conditional values and `elsif`,
multiple assignment, loop `break`/`next`, explicit and nonlocal returns,
captured block locals, `yield`, static `define_method`, optional and keyword
arguments, module singleton methods, mixins, Struct construction and
attributes, polymorphic object fields, and stable `sort_by`. Integers promote
from `long` to `java.math.BigInteger` on overflow; integer division and modulo
use Ruby's floor/sign rules. File block lifetimes use Java resource cleanup;
threads run on Java threads and propagate failures through `Thread#value`.

Simple inferred programs retain the primitive lowering. Programs requiring
collections, closures, nil-bearing values, or polymorphism use the boxed core
lowering in `lib/spinel/jvm/core_compiler.rb`. Its bodies and blocks are
compiled JVM methods, with lexical cells and runtime class/method tables;
there is no runtime source/AST interpreter. The bundled
`runtime/org/spinel/runtime/Core.java` implements the needed Ruby value and
library operations using JDK APIs. Its classes are compiled once per compiler
process and packaged into each relevant JAR.

The analyzed IR now additionally preserves a validated `syntax` node table
before native-specific desugaring. This keeps lexical block lifetimes and
nonlocal control flow available to the JVM lowering while retaining the
existing inferred/post-desugaring tables. Older version-1 IR without this
optional table continues to use the primitive lowering.

This is functional benchmark coverage, not optimization parity: extended
collection/object operations currently box values. The Java import/export
path below still uses the primitive Java-ABI lowering; combining it with the
extended boxed core is not supported yet. One non-boxed block form is supported
on that path: a finite integer range's `each` used as a statement, with zero
or one required block parameter and a primitive-supported body. Its block is
inlined into the enclosing JVM method, including captured-local updates and
lexical parameter shadowing; Java calls such as `System.currentTimeMillis`
can be used around or inside the loop. Integer `%` uses `Math.floorMod` to
preserve Ruby's signed-modulo rules.

For example, this repeats the range benchmark with Java timing:

```ruby
require "java"
while true
  started = System.currentTimeMillis
  sum = 0
  (1..500_000_000).each { |i| sum = sum + (i % 7) }
  puts sum
  puts System.currentTimeMillis - started
end
```

Native C/FFI dependencies are not implemented by the current backend. The
Java 25 roadmap requires Panama bindings and keeps broader C API compatibility
as an open option; see [PANAMA.md](PANAMA.md). The JVM owns GC and thread
scheduling, so the
native collector instrumentation and `SPINEL_GC_*`/`SPINEL_WORKERS` benchmark
tuning do not carry over. See [BENCHMARKS.md](BENCHMARKS.md) for the coverage
and portability report.

Java interop starts with JRuby-shaped imports. A binary-name string or a Java
class expression is accepted, and one call may import multiple classes:

```ruby
require "java"
java_import "java.lang.System", java.lang.StringBuilder
puts System.currentTimeMillis

builder = StringBuilder.new("value=")
builder.append(7)
puts builder.toString
```

```sh
jruby jvm/bin/spinel-jvm --require-gate \
  --class-path vendor/example.jar app.rb -o app.jar
java -cp app.jar:vendor/example.jar org.spinel.generated.SpinelMain
```

Public constructors, static methods, and instance methods are resolved at
compile time. Exact Java reference types flow through chained calls and local
variables. Supported scalar boundaries are `long`/`int`/`short`/`byte`/`char`,
`double`/`float`, `boolean`, and `java.lang.String`.

Normal calls use inferred Spinel types to select an overload. Ambiguous calls
use JRuby's exact-signature form: the first argument is a symbol or string, the
second is an array of Java class objects, and the remaining arguments are the
method arguments. Omitting the type array selects a zero-argument method:

```ruby
puts service.java_send(:convert, [Java::double], 2.0)
puts System.java_send(:currentTimeMillis)
```

`java_signature` also uses JRuby's literal Java declaration syntax and applies
to the immediately following Spinel method. The name in the signature is the
exported Java name, so Spinel methods can provide Java overloads while retaining
distinct Spinel names. `public`, `protected`, and `private` visibility and a
`throws` clause are preserved in the class file:

```ruby
class Converter
  java_signature "public long convert(long value)"
  def convert_integer(value)
    value
  end

  java_signature "public double convert(double value)"
  def convert_float(value)
    value
  end
end
```

Java subclasses use Ruby's superclass syntax, and Java interfaces use JRuby's
`include` form. A unique inherited method descriptor supplies the override's
types; overloaded overrides require `java_signature`. Exported methods are
retained even when only Java code calls them:

```ruby
require "java"
java_package "com.example"
java_import "java.util.TimerTask", "java.lang.Runnable"

class Worker < TimerTask
  include Runnable

  def run
    puts "running"
  end
end
```

The Java superclass must be public and non-final, with an accessible
no-argument constructor. Its public inherited methods are callable from
Spinel. Generated objects can be passed to Java methods and constructors
accepting their superclass or implemented interfaces.

`java_package` sets the package for the generated application types. Without
it, types use `org.spinel.generated`. The executable entry point remains
`org.spinel.generated.SpinelMain`, so `spin run` and `java -jar` retain their
existing behavior. Package declarations currently apply to the entire
compilation, including required Spinel sources.

Java interface, record, and enum definitions use explicit compile-time calls
and require no new Ruby grammar:

```ruby
module Greeter
  java_interface
  java_abstract "String greet(String name)"

  java_signature "public long twice(long value)"
  def twice(value)
    value * 2
  end
end

Point = Data.define(:x, :y) do
  java_record x: Java::long, y: Java::double
end

class Color
  java_enum :RED, :GREEN, :BLUE
end

point = Point.new(3, 4.0)
puts point.x
puts Color::RED.name
puts Color.valueOf("BLUE").ordinal
```

Marked modules become JVM interfaces. `java_abstract` declares a public
abstract method without a body; signed public instance methods become Java
default methods. Interfaces may include imported or generated Java interfaces.
Ordinary Spinel modules are not implicitly exported as interfaces.

Marked `Data.define` classes become final JVM records, with record component
metadata, private final fields, a public canonical constructor, component
accessors, and the JDK's record equality, hashing, and string rendering. The
component names and order must match `Data.define`. Positional Spinel
construction and component reads use the canonical Java API. Additional
fields, component mutation, generated-member replacement, keyword
construction, and record subclassing are unsupported. Explicitly signed
additional instance methods are supported. `Struct.new` is not a Java record.

Marked enum classes extend `java.lang.Enum`. The compiler emits public enum
constants, ordinals, `values()` returning a defensive copy, and `valueOf`.
They work with Java reflection and `switch`. Shared signed instance methods
are supported; payload constructors, additional instance state, and
per-constant bodies are unsupported. The `values()` array API is currently
available to Java callers; Spinel does not yet lower enum-array operations.

Java signatures may refer to other generated types by Spinel name or full
Java binary name. Missing abstract implementations, duplicate descriptors,
ambiguous overrides, incompatible return types, and invalid declarations
produce compilation errors. Overrides currently require identical Java
return types; covariant-return bridges are not emitted. Class construction
from Java currently exposes the generated no-argument constructor; Spinel's
argument-taking `initialize` still uses the existing internal calling
convention. Explicit superclass constructor arguments and `super` calls are
not supported.

Import-renaming blocks, varargs calls, boxing, static or annotated
`java_signature` methods, generic signature metadata, and annotation
declarations remain unsupported.

An executable example and Java-caller verification are available in
`test/fixtures/java_types.rb` and `test/java_types_test.rb`:

```sh
jruby jvm/bin/spinel-jvm jvm/test/fixtures/java_types.rb -o /tmp/types.jar
java -Xverify:all -jar /tmp/types.jar
javap -classpath /tmp/types.jar example.spinel.Greeter example.spinel.Point example.spinel.Color
jruby jvm/test/java_types_test.rb
```

An inheritance example that exercises an inherited method calling an override
is available at `test/fixtures/inheritance.rb`.
