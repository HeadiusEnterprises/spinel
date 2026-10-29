# JVM benchmark coverage

Milestone-1 verification (2026-10-29): all 62 original one-shot programs in the
staged source snapshot matched their expected output on JDK 25. The original
workspace's infinite Java-timed `bm_range_each.rb` is an uncommitted personal
driver, not part of the checkpoint; exclude it from expected-output execution
there. This remains Java 17-targeted bytecode running on JDK 25, not the planned
Java 25 target. See [restart context](MILESTONE_1.md), the
[revised plan](IMPLEMENTATION_PLAN.md), and [commit assessment](COMMIT_READINESS.md).

The 62 unmodified Ruby programs under `benchmark/` compile to standalone
Java 17 JARs. Every program has been executed at its default workload with
`java -Xverify:all -Xmx768m`; binary stdout matched the corresponding
`.rb.expected` file in all 62 cases. No benchmark or expected-output fixture
was changed to obtain this result.
Of these programs, 52 select the extended boxed core and 10 retain primitive
lowering.

## Implemented operations

| Coverage | Representative programs | JVM implementation |
| --- | --- | --- |
| Arrays, indexing, sparse growth, nested arrays | Sudoku, sieve, Life, matrix multiplication, n-queens | Resizable Ruby arrays, preserving shared-fill identity, negative indices, and nil holes |
| Ordered hashes and polymorphic fields/returns | CSV, word frequency, JSON parser, micro Lisp, tree walkers, Sinatra mini | JDK-backed hashes, boxed values, explicit runtime class tags and method tables |
| Closures and nonlocal control flow | range each, times loops, block sends, throw | Compiled block methods, lexical cells, targeted control-transfer exceptions |
| String identity, interpolation, and binary bytes | XOR, FASTA, templates, AO and Mandelbrot images | Mutable/frozen byte-backed strings with distinct character and byte operations |
| Large integers, numeric conversion, math | bigint Fibonacci, pi digits, STARK field, spectral norm, n-body | `long` with overflow promotion to `BigInteger`, Ruby division/modulo rules, JDK math |
| Class/module methods, accessors, Struct, keywords | get/set ivar, struct access, keyword args | Compiled methods with runtime class/attribute metadata and argument binding |
| Stable keyed sorting | sort_by | One key evaluation per element followed by stable JDK sorting |
| Files and concurrency | I/O word count, threaded rendering | JDK streams with block cleanup; Java threads with ordered joins and exception propagation |

All program bodies and blocks are compiled bytecode. The runtime contains no
source evaluator, AST interpreter, or JRuby dependency. Simple programs keep
the existing primitive lowering; the extended core uses boxed values and is
an initial functional implementation, not a claim of native-backend-equivalent
optimization.

## Reproducing the check

From the repository root:

```sh
make jvm-bench
jruby jvm/benchmark_audit.rb --run --report /tmp/spinel-jvm-benchmarks.json
# Individual benchmark, through the normal command line:
jruby jvm/bin/spinel-jvm benchmark/bm_sudoku.rb -o /tmp/sudoku.jar
java -Xverify:all -jar /tmp/sudoku.jar
```

The audit command can filter benchmark names (`--run sudoku bigint`) or compile
without running (omit `--run`). Failed frontend/backend compilation, invalid
bytecode, timeout, nonzero exit, and output mismatch each produce a failing
exit status. A JSON report records which lowering was selected. The I/O
benchmark's fixed temporary path is checked for collision before execution.

## Portability and remaining integration work

No construct used by these benchmarks needs additional language design or
user clarification. All required operations have JVM representations.

The threaded-render benchmark's allocation graph, yields, concurrency, and
deterministic digests are preserved. Its *native Spinel collector* measurements
are not portable: the JVM supplies its own collector and Java-thread
scheduling. Native `SPINEL_GC_*` thresholds, green-worker counts, and collector
phase counters have no direct JVM equivalents. JVM GC logging and heap options
must be used for that investigation.

Native C bindings, native extension/shim export, and machine-specific runtime
intrinsics cannot be translated automatically. Required Panama binding stages
and an optional C API compatibility route are specified in [PANAMA.md](PANAMA.md);
these are not yet implemented and none is required by the original corpus. The compiler
rejects declared native C/FFI dependencies on the extended core path.

The existing Java import/export backend and extended Ruby core currently use
separate lowering paths. Combining boxed arrays/closures with `java_import`,
`java_send`, or Java-exported signatures remains integration work. The primitive
Java-ABI path does support finite integer `Range#each` statements with an
inlined, primitive-supported block, including Java timing calls; this does not
require boxed closures or unify the two lowering paths. Broader Ruby
features outside the corpus are not implied by benchmark coverage.
