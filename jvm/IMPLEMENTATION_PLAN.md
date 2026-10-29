# JVM feature coverage and optimizing-backend plan

Audit and revision date: 2026-10-21. This plan now targets Java 25 and supersedes
the earlier Java 17 target. The measurements below describe the existing
implementation, which still emits Java 17 classes; the Java 25 work has not
been implemented. No backend or benchmark source was changed during this
planning revision. See [commit readiness](COMMIT_READINESS.md) before publishing
the current checkpoint.

The prototype milestone and current restart instructions are recorded in
[MILESTONE_1.md](MILESTONE_1.md); the measurements below retain their original audit date.

## Objective

Make Java interop orthogonal to Spinel language support. A program must retain
its Ruby operations, results, and optimization opportunities when it adds
`require "java"`, an import, a Java call, or an exported Java method.

Retain JRuby and BiteScript as compiler dependencies, Java 25 as the generated
class-file/API baseline, and no JRuby runtime dependency. Prefer typed locals,
fields, calls, and collection storage. Use immutable records as value-double
carriers when a value can require both a primitive and a boxed representation.
Do not introduce new source syntax or a runtime Ruby interpreter.

### Java 25 scope decisions

- Virtual threads provide the stackful substrate for fibers/coroutines and
  suitable Ruby threads. A Spinel-level ownership/handoff protocol still has to
  implement Ruby's scheduling, fiber, thread-local, and transfer semantics.
- Ordinary records provide today's value-double representation; keep them
  identity-independent so a future Valhalla-capable target can use value
  classes. Neither Java 25 records nor future Valhalla imply guaranteed stack
  allocation in every context.
- Implement FFI and carried-native bindings using the final
  `java.lang.foreign` API, not a new JNI bridge. Keep native memory and object
  handles behind a narrow ABI. The required FFM implementation and optional
  Spinel C extension compatibility proposal are in [PANAMA.md](PANAMA.md).
- Ignore Spinel-specific GC control, heap traversal, collector counters, and
  GC-sensitive timing/finalizer tests. Use existing JVM/JMX/JFR tooling; do not
  emulate native collector APIs or introduce a replacement monitoring API.
  Diagnose code that requires these unsupported operations rather than silently
  treating them as successful no-ops.
- POSIX fork is explicitly out of scope. Implement other OS functionality with
  JDK APIs first and Panama only for demonstrated gaps.
- Produce readable JVM exceptions and stack traces. Native C backtraces and
  fidelity to the native compiler's stack layout are not goals.

## Measured baseline

The audit compiled temporary entry points containing `require "java"` followed
by a `require_relative` of each original file. Original sources, relative
dependencies, and expected-output files were preserved. A Java-disabled probe
compiled the same exported IR with the `java` feature marker removed; it is a
backend comparison, not a second native-compiler correctness result.

| Corpus | Java-enabled result | Java-disabled IR probe |
| --- | --- | --- |
| 62 benchmarks | 13 compile; 49 fail compilation | 62 compile |
| 3,592 top-level `test/*.rb` programs | 22 compile; 3,552 fail compilation; 18 invalid IR exports | 1,955 compile; 1,619 fail compilation; the same 18 invalid exports |

Of the 13 Java-enabled benchmarks that compile, 11 terminating programs match
their checked-in stdout under `java -Xverify:all`. `bm_bigint_fib.rb` raises
`ArithmeticException: long overflow`. The modified `bm_range_each.rb` is an
infinite timed loop and was compile-checked, not run by this audit. Its repeated
checksum was verified separately during the preceding fix.

The 11 matching programs are `bm_fib`, `bm_getivar`, `bm_inline`,
`bm_nested_loop`, `bm_object_new`, `bm_object_new_init`,
`bm_send_rubyfunc_block`, `bm_setivar`, `bm_setivar_object`, `bm_tak`, and
`bm_tarai`.

Compilation is not correctness coverage. A separate, deliberately selected
16-test runtime probe against original sources produced six matches, eight
runtime failures, and two compilation failures without Java; two matches and
14 compilation failures with Java. This sample is diagnostic, not an estimate
of the whole corpus's pass rate.

Examples from that runtime probe:

- `array_sum_kahan.rb`: uncompensated sum prints `0.6000000000000001` rather
  than `0.6`; array repetition then fails.
- `array_gap_is_nil.rb`: sparse nil slots work, but `Array#compact` is absent.
- `array_map_bang.rb`, `hash_default_proc.rb`: required runtime methods absent.
- `float_modulo.rb`: signed zero is lost and `modulo` is absent.
- `array_index_range_variable.rb`: a range index is treated as an integer.
- `and_short_circuit_nil.rb`: compilation succeeds, but `String#rindex` fails.
- `nil_ivar.rb`: matches with and without Java.

### First blockers in the benchmarks

These are mutually exclusive *first diagnostics*, not complete inventories of
what each benchmark needs. Fixing one blocker can reveal several more.

| First blocker | Programs | Examples |
| --- | ---: | --- |
| Unsupported array representations | 17 | Sudoku, Life, sieve, matrix multiplication, n-body, CSV |
| Unsupported `poly` values | 7 | JSON parser, micro Lisp, polymorphic cells, tree walkers |
| Unsupported hash representations | 2 | template, Sinatra mini |
| Invalid type joins | 3 | linked list and red-black tree (`nil`/object), Mandelbrot (`int`/float) |
| `yield` | 3 | Struct readers/writers, throw |
| `elsif` / short-circuit expression | 2 | Ackermann, nonescaping object allocation |
| Other missing calls/declarations | 15 | bitwise arithmetic, conversions, constants, keywords, class/module methods, strings |

### Gaps beyond the benchmarks

Among the readable top-level test exports, the Java-disabled probe stops first
at `BeginNode` in 480 files, regexp literals in 170, rescue modifiers in 167,
lambdas in 133, rest/forwarded parameters in 111, and block forwarding in 47.
Pattern matching, compound assignment, `super`, aliases, singleton classes,
`defined?`, and class variables provide additional substantial groups.

On the Java path, first diagnostics include 579 unsupported `poly` types,
347 `poly_array` types, and 330 unresolved `p` calls. These counts must not be
used as projected pass-rate gains.

There are also correctness issues below node lowering:

- Eighteen programs export invalid JSON for non-UTF-8 literal bytes, including
  `array_pack_string_unpack.rb`, `pack_float_directives.rb`,
  `string_append_binary_safe.rb`, and `string_inspect_invalid_utf8.rb`.
- Java resolution confuses some Ruby constants with `java.lang` classes.
  For example, 53 first diagnostics join Ruby `thread` with
  `java:java.lang.Thread`. Merely enabling Java must not replace Ruby `Thread`.
  Explicit imports must retain their specified JRuby-shaped behavior.
- Arithmetic depends on backend selection: the boxed runtime promotes while
  the primitive compiler uses checked `long` operations. The frontend supports
  `--int-overflow=raise|wrap|promote`, but the exported IR does not describe that
  policy.
- The snapshot captured before analysis has lexical syntax but no analyzed
  types; the other node table has analysis after native-specific rewriting.
  A reliable identity/binding bridge between them is necessary for optimized
  lexical lowering.
- 120 test programs declare native dependencies. They need separate
  classification, not an automatic promise of JVM portability.

Nested inference, RBS-seed, reject, backtrace, thread, extension, and
package-specific suites were inventoried but not included in the 3,592-program
compilation matrix. Their specialized harnesses remain required work.

## Target architecture

Use one resolved, typed program with two implementation choices **per operation
or value**, rather than two incompatible compilers chosen for the entire
program.

1. Preserve lexical bindings and source identities in a backend-neutral IR.
2. Resolve Spinel methods, builtins, Java imports, overloads, and exported
   contracts before representation selection.
3. Build typed control-flow blocks, including joins, exceptional edges,
   captures, and escape information.
4. Select primitive, nullable, tagged-union, reference, or boxed representations.
5. Emit bytecode through BiteScript; use small typed runtime helpers for
   operations whose semantics exceed a single instruction.

The current boxed core can provide an incremental compatibility bridge. It
must not become the mandatory representation of every Java-enabled program.
Likewise, copying every core operation into the current primitive emitter
would duplicate semantics and should not be the long-term architecture.

### Representation and code-quality rules

| Construct | Preferred JVM lowering | Semantic guard |
| --- | --- | --- |
| Proven scalar | `long`, `double`, or boolean local/field and typed descriptor | Respect selected overflow mode, mixed arithmetic, NaN, and signed zero |
| Nullable value | Reference/null or primitive plus presence bit | Keep `nil`, `false`, and numeric zero distinct |
| Primitive/boxed alternative | Immutable record value-double, with primitive locals when proven sufficient | No carrier identity assumptions; keep observable numeric kinds distinct |
| Numeric array | Resizable owner around `long[]` / `double[]`; nil bitmap if needed | Preserve identity, negative indices, sparse nils, aliasing, and checked stores |
| Object/nested array | Typed reference storage where sound, boxed fallback otherwise | Preserve shared-fill identity and widening through all aliases |
| User object | Generated class, typed fields, normal constructor/virtual calls | Uninitialized ivars are Ruby nil, not automatically primitive zero |
| Non-escaping block | Inline body and local branches; captured JVM locals | Fresh block locals and lexical shadowing every invocation |
| Escaping block | Compiled callable class and only the required capture cells | Preserve lambda/proc arity, ownership, and nonlocal-transfer targets |
| Known method / Java call | Direct static, virtual, interface, or constructor call | Respect Ruby overrides and Java overload/access rules |
| Polymorphic call | Small guarded dispatch over the inferred target set | Keep uncommon boxed cases outside the hot path |
| Ruby string | Byte-backed value with encoding/frozen/ownership metadata | Convert explicitly at Java String boundaries; no blanket UTF-16 substitution |
| Hash | Ordered, semantically correct runtime map; specialize measured hot key/value shapes | Ruby equality/hash rules, defaults, copied string keys, and mutation behavior |

Primitive arrays are storage *inside* a Ruby-array abstraction, not a claim
that Ruby Array is interchangeable with a fixed-size Java array. Explicit
Java array conversions must define copying, sharing, and mutation behavior.

Bytecode instructions and descriptors are defined by the
[Java 25 JVM specification](https://docs.oracle.com/javase/specs/jvms/se25/html/jvms-6.html).
Use ordinary JVM shapes that HotSpot can optimize. Do not build a second JIT,
assume escape analysis always succeeds, or impose unconditional frame and
`Object[]` allocations on a typed hot loop. Bound specialization and split
large generated methods before class-file limits are reached.

### Record value-doubles and the Valhalla migration seam

Use an internal immutable record such as this conceptual carrier:

```java
record IntValue(long small, BigInteger big) {
    // Invariant: big == null selects small; otherwise small == 0.
    // Factories normalize values representable as long back to small form.
}
```

This is one number with two possible representations, not two independent
values. In promote mode, checked primitive arithmetic returns the small form
until overflow, then computes the exact BigInteger result. Never compute an
already-wrapped primitive result and promote that corrupted value. Subsequent
operations handle both forms and can normalize small results again. Raise and
wrap modes retain their explicit, separate contracts.

Rules for the implementation:

- Proven non-promoting regions stay as primitive JVM locals/fields. Potentially
  promoting typed boundaries use `IntValue`, not `Object`, `Number`, or a
  mutable wrapper. Scalarize the carrier's components inside proven hot regions
  when that avoids repeated materialization.
- Use corresponding records for nullable primitives and other justified
  primitive/reference alternatives. Mutable capture cells, resource owners,
  Ruby arrays, and identity-bearing Ruby objects remain ordinary objects;
  replace an immutable carrier inside a cell rather than mutating the carrier.
- Keep equality, hashing, rendering, and Ruby numeric identity in semantic
  helpers. Record-generated equality/hash are not automatically Ruby's numeric
  contracts. Never synchronize on, identity-hash, weak-identity-key, or expose
  the carrier's Java identity as Ruby `object_id`.
- Factories/accessors and representation descriptors belong to one backend
  abstraction. No C layout, external serialization format, or public Java ABI
  may depend on the record's field layout. Regenerate internal descriptors
  when a future value-class target requires it.
- For potentially promoting arrays, compare record arrays against a
  structure-of-arrays primitive/BigInteger storage strategy behind the same
  Ruby owner. Do not require one heap allocation per arithmetic operation or
  assume Java 25 flattens arrays of records.
- Future Valhalla adoption is a separate compiler/runtime capability with its
  own tests. Do not emit draft value-class flags or require preview features
  on the Java 25 target. Scalar replacement/allocation elimination and future
  flattening are optimization opportunities, not contractual stack placement.

Java 25's [Record contract](https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/Record.html)
defines immutable component state but not allocation placement. Valhalla's
[draft record/value-class design](https://cr.openjdk.org/~dlsmith/jep401/jep401-20240624/specs/value-objects-jls.html)
motivates avoiding identity dependencies; it is not a Java 25 feature promise.

### Virtual-thread execution model

Use public Java 25 APIs, not internal continuation APIs. A fiber runs compiled
Spinel/Java frames on a dedicated virtual thread; `resume`, `yield`, and
`transfer` exchange messages and execution permission through a parked
rendezvous. Nested Java calls can therefore remain ordinary calls rather than
requiring a whole-program CPS transformation.

Required semantics and safeguards:

- Keep explicit `SpinelThreadState` and `FiberState`. Fibers of one logical Ruby
  thread share its thread state but have separate fiber-local storage. Do not
  implement all Ruby state with Java ThreadLocal: backing Java virtual threads
  differ, and native carrier threads can change.
- At most one fiber of a logical Ruby thread owns the cooperative execution
  token at a time. Implement NEW/RUNNING/SUSPENDED/TERMINATED transitions,
  resumer/transfer relationships, argument packing, dead/double/cross-thread
  resume errors, and exception delivery without lost wakeups or busy polling.
- A parked fiber's Java Thread is distinct from its logical Ruby Thread.
  Document this when users call `java.lang.Thread.currentThread` explicitly;
  keep Ruby `Thread.current`, ownership checks, and locks semantically correct.
- Escaping capture cells need proper publication. Cancellation, thread kill,
  deadlines, and shutdown must run cleanup through cooperative checkpoints and
  interruptible waits, not `Thread.stop` or asynchronous unsafe unwinding.
- Do not claim CPU speedups from virtual threads or pool them as worker objects.
  Keep nonescaping numerical blocks as inlined loops. Optimize statically known
  generators further only after the virtual-thread semantics pass their tests.
- FFM/native calls can pin a carrier. Use a bounded platform-thread executor
  for genuinely blocking native work where thread affinity permits, creating
  confined native resources on that worker or using explicitly shared scopes.
  Native calls cannot be forcibly interrupted safely merely because a Future
  times out. See the callback and lifetime restrictions in [PANAMA.md](PANAMA.md).

The [Java 25 virtual-thread guide](https://docs.oracle.com/en/java/javase/25/core/virtual-threads.html)
describes parking, carrier pinning, and throughput tradeoffs. Public
[Thread APIs](https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/Thread.html)
provide the substrate; the Ruby protocol above is compiler/runtime work.

## Implementation sequence

### 0. Move the toolchain to Java 25 and repair the IR contract

Scope:

- Require JDK 25 for compiler execution, runtime compilation, and generated
  programs. Update `spin.toml`, CLI release validation, runtime `javac --release
  25`, tests, and BiteScript's class-file version to 69. Check JRuby's bundled
  ASM supports that version; fail clearly rather than falling back to Java 17.
  Pin/document the tested JRuby/ASM combination and run CI on an actual JDK 25,
  not only newer JDKs producing older class files. No preview flags are needed.
  The installed JRuby 10.1.1.0 exposes ASM `V25 == 69`; the current adapter
  nevertheless selects class-file version 61. Actual version-69 emission and
  verification still need implementation and tests.
- Add checked-in benchmark/test audit modes for ordinary compilation, actual
  `require "java"`, and Java timing calls. Record compilation, JVM verification,
  execution, stdout/stderr match, timeout, and explicit skip separately.
- Derive a test manifest from the native harness: `.args`, `.stdin`, stderr
  fixtures, overflow modes, require gates, required packages, and isolated
  filesystem/network/process cases. Do not blindly run every fixture.
- Give the infinite performance benchmark a bounded audit entry point without
  changing the user's working benchmark or expected-output files.
- Export binary string bytes losslessly, with encoding and byte lengths.
  Base64 or a byte-array field avoids interpreting arbitrary bytes as JSON
  text. Test embedded NUL as well as invalid UTF-8 in both node tables.
- Preserve original node/binding identities across transformations; export
  lexical locals, method targets, effects, nullability, and overflow policy
  in a versioned, validated schema. Avoid matching nodes by line number.
  Bump the format version for incompatible changes; retain a version-1
  compatibility reader without applying optimizations whose proofs are absent.
- Export complete native-binding metadata, not just counts: functions, C
  symbols, library/source manifests, argument/result specs, callbacks,
  structs/buffers/accessors, ownership, and blocking/affinity requirements.
- Classify GC-control/metrics tests and fork tests as out of scope. Keep
  ordinary allocation-heavy algorithms and portable concurrency tests in scope.
- Until their Panama stage lands, reject unsupported native bindings
  consistently on every emission path rather than ignoring declarations.

Acceptance: Java 25 execution and class-file verification pass; all 3,592 source
programs can be categorized without invalid JSON;
existing Java export tests remain green; baseline reports distinguish generated
bytecode from verified, correct programs. Native-only exclusions are named.

### 1. Unify Java resolution and Ruby execution

Scope:

- Extract Java classpath loading, import binding, overload selection,
  `java_send`, signature parsing, and contract validation from emitter state
  into a shared resolution pass.
- Resolve lexical Spinel/Ruby constants before implicit `java.lang` fallback.
  Test `String`, `Thread`, `Math`, user-declared classes, explicit imports,
  qualified Java names, and import conflicts against the intended semantics.
- Keep `require`/`require_relative` feature loading separate from `java_import`
  name binding. Carry feature/dependency origins and classpaths through the
  compiler and `spin build`/`spin run`; fail clearly for missing Java dependencies.
- Allow resolved Java calls inside boxed bodies/closures using generated typed
  adapters and explicit scalar/string/reference conversions. Do not use
  reflective invocation in the generated hot path.
- Retain typed Java-visible methods and constructors. Generate bridges when
  their body temporarily needs the compatibility runtime; preserve Java
  inheritance, interfaces, records, enums, visibility, and checked signatures.
- Replace the unconditional `features.include?("java")` backend veto with
  capability/representation selection. Do not hide new failures by silently
  changing overflow or argument-conversion rules.

Acceptance: every existing benchmark has the same result with Java enabled,
using a declared overflow mode and a bounded range test. Add actual Java calls
inside array iteration, recursive methods, captured blocks, and object methods;
test external classpaths and Java-to-Spinel callbacks. Existing ambiguous
overloads must still require the exact JRuby-shaped `java_send` signature.

### 2. Complete scalar control flow and exception semantics

Scope:

- `elsif`, value-producing conditionals, general Ruby truthiness, short-circuit
  expressions, unary/bitwise operations, numeric conversions, and `for`.
- Compound/conditional assignment for locals, ivars, globals, constants,
  attributes, and indices; evaluate receivers and indices exactly once.
- Typed `begin`/`rescue`/`else`/`ensure`, rescue modifiers, exception binding,
  `retry`, and accurate return/break/next behavior through cleanup.
- Distinguish Ruby exceptions and imported Java exceptions from the runtime's
  nonlocal-control signals and JVM failures. Bare rescue catches StandardError,
  not arbitrary Throwable or SystemExit.
- Implement one numeric semantics layer for floor division, modulo, signed
  zero, overflow, shifts, powers, and later BigInteger/Rational/Complex helpers.
  Use the record-based value-double representation for possible promotion and
  nullable primitive boundaries; preserve primitive-only regions.
- Emit readable method/block names, original source-file/line information,
  exception causes, and JVM stack traces, including async fiber handoff origins
  where useful. Do not build native stack unwinding or native-symbol tooling.

Optimization: use local branches for local control transfer and JVM exception
tables for real exceptions. In raise/wrap mode keep integer operations primitive;
in promote mode retain a small-integer fast path with a cold BigInteger path.
Do not assume raw JVM division/remainder implements Ruby's rules.

Acceptance fixtures include `rescue_modifier_stmt_std_only.rb`,
`ensure_runs_on_return.rb`, `int_overflow_raises.rb`, `float_modulo.rb`, and
`block_local_fresh_per_iteration.rb`. Run all applicable `promote_*` tests under
their required mode. Ackermann, AO arithmetic, and nonescaping-object loops
must no longer require boxing solely for these constructs.

### 3. Specialize data, fields, and ordinary method calls

Scope:

- Typed arrays and nested numeric arrays with sparse/nil-aware operations,
  slicing, mutation, growth, and representation widening that preserves aliases.
- Typed generated classes, nullable object graphs, class/module methods,
  constants/globals, inherited fields and constructors, and accessor lowering.
- Replace strict Java-only type joins with sound value-flow joins for
  nil/object, primitive/reference boundaries, and numeric unions.
- Share the correct byte-string implementation across both former paths;
  retain frozen literals, mutation/aliasing rules, byte versus character indices,
  and deliberate Java String boundary conversions.
- Use inferred target sets for direct calls and bounded specialization;
  preserve a virtual call where Ruby overriding remains possible.

Acceptance: Sudoku, matrix multiplication, spectral norm, n-body, Life, sieve,
tree walkers, red-black tree, and string workloads run with Java calls and
correct output. Bytecode inspection shows primitive storage/loads in their
monomorphic numeric kernels and typed fields in ordinary object workloads.
Sparse-array and aliasing regressions must remain correct, not just fast.

### 4. Complete callables and argument binding

Scope:

- Lambdas and procs, first-class blocks, `&block`, symbol-to-proc, destructuring,
  rest/post arguments, splats, keywords/keyword-rest, `**`, anonymous forwarding,
  and `...` while preserving positional/keyword separation.
- Captured-local cells only for escaping/shared mutation. Inline known yielding
  methods and collection blocks when safe; preserve fresh captured cells when
  a block is saved during each iteration.
- Compiled callable objects for escaping bodies; typed callable signatures for
  common primitive arguments/results, general adapters only at real boundaries.
- Correct nonlocal return, break, next, block arity, lambda arity, and invalid
  cross-thread/outlived-method transfers. Java SAM/callback adapters share the
  same closure ownership model.

Acceptance fixtures include `lambda_explicit_return.rb`,
`arg_forwarding_fixed_callee.rb`, `blk_param_stored_proc_per_iteration.rb`,
and `yield_inside_escaping_block.rb`. Keyword benchmarks, `times`, static
`define_method`, Struct block methods, and throw/yield benchmarks retain their
meaning with Java enabled. Hot primitive iterator loops allocate no argument
array or capture environment per element when no value escapes.

### 5. Expand shared collections and numeric/string libraries

Scope:

- Arrays/Enumerable: repetition, slicing/splicing, compact/filter/map!, folds,
  searches, set operations, zip/transpose, combinatorics, stable keyed sorts,
  enumerator-returning forms, and user-defined `each`.
- Hashes: defaults/default_proc, fetch, key equality/hashing, ordered iteration,
  mutation during iteration, and derived-hash behavior. Normalize numeric key
  semantics where Java wrappers differ, including negative zero.
- Strings: the broader search/edit/iteration surface, frozen guards, Unicode
  and binary operations, formatting, packing/unpacking, and conversion checks.
- Numeric methods and aliases, compensated floating Array#sum,
  Rational/Complex, and consistent BigInteger propagation.
- Implement `p`, `print`, `warn`, inspect, and conversion protocols once for
  every representation; avoid letting trivial output support mask later gaps.

Optimization: fuse proven iterator chains, select typed loop bodies, pre-size
results when safe, cache immutable literals/regexps, and use small helpers whose
descriptors expose primitive arguments to the JVM. Introduce specialized hash
storage only after profiling; generic boxed maps are a correctness bridge, not
an optimization claim. Do not reorder observable operations or replace Ruby
floating-point algorithms with faster but different reductions.

Acceptance includes all runtime failures listed in the audit, plus the full
array/hash/string test families under both Java variants. Each method family
must pass wrong-arity/type, nil, empty, frozen, aliasing, and block-control cases.

### 6. Complete the static object model and structured matching

Scope:

- `super`/forwarding super, aliases that capture the correct definition,
  visibility, module mixins/prepend, static singleton definitions, class
  variables, lexical/qualified constants, and `defined?` without side effects.
- Closed-set literal `send`, Method objects, static metaprogramming forms,
  Struct/Data behavior, and composition with Java-exported classes/interfaces.
- `case/in`, rightward assignment, predicate matches, array/hash/find patterns,
  guards, pins, rest captures, and user `deconstruct`/`deconstruct_keys`.

Optimization: resolve the known ancestor graph and pattern layout at compile
time; emit explicit tests and extraction rather than a generic AST evaluator.
Use materialized runtime metadata only for the supported reflective operations.

Acceptance fixtures include `super_with_args.rb`,
`alias_captures_earlier_def.rb`, `array_pattern_match_basic.rb`, and the existing
Java interface/record/enum/subclass tests. Preserve documented AOT restrictions
instead of adding unrestricted runtime class or method mutation.

### 7. Add regexps, portable libraries, and virtual-thread fibers

Scope:

- Regex literals/interpolation/options, MatchData/backreferences and their
  scope, substitutions/capture replacement, and string-regexp interactions.
- JDK-backed Time, Random, Set, IO/File/Dir/Pathname, StringIO, process launching,
  selected serialization/crypto/networking, and package mappings, in measured
  test-family order. Preserve Ruby behavior rather than simply exposing Java
  APIs with similar names. Use `ProcessBuilder`/`ProcessHandle`, NIO channels
  and filesystem attribute views first; use Panama only for required OS gaps.
  Reject `fork` explicitly, including aliases and dynamic dispatch to it.
- Virtual-thread-backed Ruby threads and stackful fibers using the execution
  model above, synchronization/queues, exception propagation, and separate
  logical-thread/fiber-local match/global state.
- External/lazy enumerators and resumable generators on that fiber substrate;
  preserve lazy demand and close/cancel behavior. A generator whose suspension
  is statically visible can later become an optimized state machine without
  changing its public behavior.
- Omit GC APIs, counters, forced-collection semantics, and GC-specific tests;
  document standard JVM/JMX/JFR tools instead. Retain useful allocation and
  concurrency workloads with GC-specific assertions excluded explicitly.

Regexp decision: evaluate the standalone
[Joni Oniguruma implementation](https://github.com/jruby/joni) and its encoding
dependency against the existing corpus. Do not assume `java.util.regex.Pattern`
is a drop-in Ruby engine. Adding a bundled regexp dependency changes the current
JDK-only runtime contract and requires an explicit project decision; no library
was installed by this audit.

Acceptance: portable library families pass with isolated fixtures and explicit
dependencies. Network/process cases are opt-in and bounded. Test nested
resume/yield/transfer, Fiber storage, wrong-owner resume, saved captures,
shutdown, cancellation, and exceptions through ordinary Java frames on JDK 25.

### 8. Implement Panama FFI and carried-native bindings

This is required backend work, not an optional JNI fallback. Implement the
stages in [PANAMA.md](PANAMA.md): complete IR binding metadata, typed FFM
downcalls and memory access, callbacks, native build/loading policy, and narrow
adapters for native package objects. Start scalar FFI after phase 2; array and
callback support depend on phases 3 and 4, not on completion of every Ruby
library in phase 7.

Acceptance includes libc/libm calls, platform-correct `long`/`size_t`, renamed
symbols, native buffers/structs, binary string lengths, mutable array
copy-back, callback errors and lifetimes, a long blocking native call without
starving fibers, and one carried native class through the opaque-handle ABI.
CI uses explicit native-access grants and tests denial without them.

The broader source-compatible Spinel C extension API remains an optional,
separate milestone. Its proposed ABI, limitations, and acceptance tests are
stored in [PANAMA.md](PANAMA.md#optional-spinel-c-extension-api-compatibility).
It is not a promise of unchanged native or CRuby extension binary compatibility.

## Performance work and acceptance throughout

Performance validation starts at phase 0 and applies to each later phase.

- Separate frontend/JRuby compilation, JVM startup, warmup, and measured kernel
  execution. Compile once, measure multiple iterations in the same JVM, and use
  independent JVM forks as well as sufficient warmup.
- Provide callable benchmark entry points with explicit input parameters and
  observable results. Avoid optimizing away work, timing output, or confusing
  startup with throughput. Use an optional
  [OpenJDK JMH](https://github.com/openjdk/jmh) harness for Java-callable kernels;
  JMH is a benchmark dependency, not a program-runtime dependency.
- Track time/op, allocation/op, representation choices, and emitted method
  sizes. Include numeric loops, Sudoku, matrix/n-body/spectral norm, escaped and
  nonescaped objects, strings/hashes, fiber handoffs, and FFM crossings. Obtain
  optional GC observations only through standard JVM/JMX/JFR monitors; do not
  implement Spinel collector metrics. Measure whether carrier records are
  scalar-replaced on JDK 25 rather than asserting they are stack-allocated.
- Inspect verified bytecode for primitive locals/fields/arrays, direct Java
  invokes, absence of unnecessary boxing, and allocation-free inlined blocks.
  Use JIT/profiling evidence before claiming that a source-level optimization
  improves machine code.
- Compare against ordinary Java kernels, the current backend, and native Spinel
  where semantics and overflow policy match. Set numeric regression thresholds
  after stable baselines exist; do not promise a universal speedup.
- Require exact output and exception checks before accepting a faster lowering.
  Every compatibility fallback needs coverage; an unsupported reachable builtin
  should produce a useful compile-time diagnostic when statically knowable.

## Scope boundaries and decisions

Implement ordinary language/core-library gaps without requiring new syntax.
Do not classify difficult but portable features as fundamentally impossible.
Keep these cases separate:

- Native GC counters, green-worker tuning, raw JVM object addresses, and
  collector timing are not JVM semantics. Preserve algorithmic behavior and
  provide JVM-specific diagnostics instead of fabricating native results.
- Native FFI/carried bindings use Panama. A portable JDK implementation remains
  preferable for OS facilities, but declared C library integration must have an
  FFM implementation. Classify dependency edges rather than excluding an entire
  package because it contains C. Retain the optional C API route in PANAMA.md.
- Fork is not implemented and must fail clearly. Other POSIX operations use
  JDK facilities first and narrowly scoped Panama calls only where necessary.
  Do not replace fork with process launching or approximate unsupported flags.
- Stackful fiber support is planned on virtual threads. Native callback frames
  have explicit initial suspension restrictions; readable JVM traces suffice.
  Native unwinding, stack walking, and native symbol parity are not goals.
- Runtime eval, unrestricted dynamic class/method construction, and other
  explicitly excluded AOT features stay excluded unless the language's design
  changes. Existing static forms remain implementation targets.
- Numeric policy should follow Spinel's explicit `raise|wrap|promote` selection
  consistently. CRuby-expected bigint workloads need a declared promote-mode
  run; importing Java must never be the operation that changes this policy.

## Recommended first delivery

Start with phases 0 and 1 as small, separately reviewable changes:

1. Actual Java 25 toolchain/target, reproducible Java-on/off matrix, bounded
   benchmark driver, binary-safe IR, full native-binding declarations, and
   explicit overflow-policy metadata.
2. Shared Java resolution and constant binding with adapters into the existing
   boxed runtime, preserving primitive Java exports.
3. Demonstrate Java-enabled Sudoku plus an actual Java timing call, and a
   captured array block calling imported Java code; retain the allocation-free
   primitive range loop and all current Java ABI tests.

Then execute phases 2–6 by test family, enabling typed fast paths and record
value-doubles alongside shared semantic implementations. Build scalar Panama
support as soon as its prerequisites are ready. Phase 7 completes public-API
virtual-thread fibers and portable libraries; phase 8 completes the native
binding surface. The optional C extension compatibility layer does not block
the required FFI implementation or the coherent optimizing backend.

Raw diagnostic reports from this audit are under
`/tmp/spinel-java-audit.CoCKL7/` (`benchmarks-report.json`, `tests-report.json`,
and `runtime-report.json`). The directory also contains the temporary audit
scripts. These are local investigation artifacts, not checked-in test tools
or a substitute for the phase-0 reproducible harness.
