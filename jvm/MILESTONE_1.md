# JVM prototype milestone 1: restart context

Milestone date: 2026-10-29. The commit containing this document is the first
prototype checkpoint on `codex/jvm-prototype-m1`. It starts from
`0d458e2b68858d15e4ead51a767fcdd0af6b1827`, without rebasing or changing remotes.
This is an experimental baseline, not a production-ready or upstream-ready backend.

## Start here

Read this document, [DEVELOPMENT.md](DEVELOPMENT.md),
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), and [PANAMA.md](PANAMA.md).
[README.md](README.md) describes the implemented command line and Java syntax;
[BENCHMARKS.md](BENCHMARKS.md) describes functional benchmark coverage.
The detailed implementation plan's Java-on/off audit is historical evidence,
not a claim that every compiled program runs correctly.

## Implemented baseline

- JRuby and BiteScript 0.1.4 compile Spinel IR into executable Java **17** JARs.
  Generated programs do not require JRuby. Java 25 is the next target, not the
  current classfile/API baseline; running existing tests on JDK 25 does not
  complete that migration.
- `spinel --emit-backend-ir` exports version-1 analyzed JSON plus a lexical
  syntax snapshot taken before native-specific rewriting. The Ruby reader
  validates format, IDs, scopes, and references. Native compilation remains
  available through the existing frontend.
- Primitive lowering emits typed methods/fields, checked long arithmetic,
  object construction/inheritance, direct calls, and JVM virtual dispatch.
  Finite integer `Range#each` statements can be inlined, including captured
  updates, parameter shadowing, and Java timing calls.
- Boxed lowering emits compiled program/block methods with lexical cells and
  a Java runtime for collections, strings, BigInteger promotion, Ruby-style
  numeric rules, object/method tables, nonlocal flow, files, and threads.
  It is not a source/AST interpreter. Coverage is limited to implemented
  operations, not the full Ruby or Spinel language.
- Java resolution supports classpaths, implicit `java.lang`, imports, public
  constructors and calls, overload selection, exact `java_send`, and exported
  `java_signature` methods. Keep those three directives JRuby-shaped within
  their documented subset. Do not introduce incompatible convenience forms.
- Java extension and implementation use ordinary class inheritance and
  `include`. Generated interfaces use `java_interface`/`java_abstract`, records
  use marked `Data.define`, and simple enums use `java_enum`. Java callers and
  reflection validate the generated ABI. No new language syntax was added.
- `spin` supports manifest/per-command JVM selection, transitive Java
  classpaths, `build/jvm/*.jar`, and launch classpaths. Normal `require` and
  `require_relative` still load Spinel source; imports bind Java names rather
  than loading Ruby code. `spin test --backend jvm` is not implemented.
- Ruby methods have descriptions; RuboCop enforces public/private method
  documentation outside language fixtures. Bytecode visitor complexity limits
  are intentional. Avoid reformatting the legacy AOT-subset `tools/spin.rb`.

The source map is in [DEVELOPMENT.md](DEVELOPMENT.md). Resolution is separated
into mixins for readability, but still depends on emitter state: this is not
yet the shared backend-neutral resolution pass required by the roadmap.

## Verified checkpoint and environment

Verification uses chruby-selected CRuby 3.4.7, JRuby 10.1.1.0, BiteScript 0.1.4,
Zulu JDK 25+36-LTS, and RuboCop 1.92.0.

- RuboCop: 25 compiler/tool/test files, no offenses.
- JVM semantic suite: bytecode toolchain, IR, scalars, objects, inheritance,
  boxed semantics/closures, Java imports/exports, and `spin` integration.
- The staged source snapshot's 62 original benchmarks all matched checked-in
  binary stdout with `-Xverify:all`; this is functional, not optimization parity.
- Native `make spin-check` passed in the working tree. That tree also contains
  an independent, unstaged pthread-probe escaping fix in `tools/spin.rb`; do not
  treat this as proof of the native gate on the exact committed tree.
- The full native/platform gate and a network-fresh dependency installation
  remain unverified. Temporary verification copies reused the built frontend
  and generated `spin_version.rb`; they were not clean native rebuilds.

The locked JRuby suite initially exposed Bundler activation leaking into the
CRuby `spin` subprocess. `capture_spin` now uses `Bundler.with_unbundled_env`
when needed; both bundled and ordinary invocations must remain supported.

## Reproduce locally

Select CRuby with chruby for **every** CRuby invocation, including reference
tests and native tool generation. On the original macOS host:

```sh
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh
chruby ruby-3.4.7
make bin/spinel
export JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-25.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"

# Keep chruby's Ruby on PATH for the spin integration subprocess, but do not
# leak its GEM_HOME/GEM_PATH into JRuby.
(
  unset GEM_HOME GEM_PATH
  cd jvm
  jruby -S bundle install
  jruby -rbundler/setup -S rake
  jruby -rbundler/setup -S rake benchmarks
)

# Compiler example; use the selected JDK for compilation and execution.
jruby jvm/bin/spinel-jvm jvm/test/fixtures/java_range_each.rb -o /tmp/range.jar
java -Xverify:all -jar /tmp/range.jar

# MRI-only lint tools; install through the selected CRuby, not JRuby.
(cd jvm && bundle install && bundle exec rake lint)
git diff --check
```

For a fresh native checkout, install the native prerequisites documented by
the repository before building. `make deps` fetches vendored dependencies.
Adapt the chruby/JDK installation paths on other hosts. Do not depend on
temporary gem directories or audit scripts from this chat.

## Known blockers and non-goals

1. Enabling Java vetoes boxed lowering. Arrays, closures, polymorphism, and
   other Ruby features that work normally often fail under `require "java"`.
   Preserve the primitive fast path while unifying semantics, not by boxing
   all Java-enabled programs or duplicating the runtime into both compilers.
2. Java fallback can mistake Ruby constants such as `Thread` for Java classes.
   Resolve Ruby/user bindings before implicit Java names; retain explicit imports.
3. Arbitrary literal bytes can make exported JSON invalid. Both node tables
   need lossless bytes, encoding, lengths, and a versioned compatibility reader.
4. Primitive overflow raises; boxed integers promote. Export and obey the
   frontend's overflow policy, with shared semantics independent of Java imports.
5. Lexical syntax lacks analyzed types, while analyzed nodes have undergone
   native rewriting. Stable binding/node identities must bridge the tables;
   source line matching is not an adequate identity contract.
6. Broad language/runtime support is incomplete: exceptions/ensure, callable
   forms, richer arguments, regexps, matching, collections, and libraries need
   categorized semantic tests. Compilation counts alone are not correctness.
7. FFI/carried-native metadata is mostly counts in version 1. Native binding
   rejection is not yet uniform across paths. Panama work is required, not
   implemented. Broader Spinel C API compatibility remains optional and open.
8. No POSIX fork. Do not implement native GC control, collector metrics, heap
   traversal, or native stack traces. Use JDK OS facilities first, Panama only
   for gaps, JVM/JMX/JFR for monitoring, and readable JVM traces for diagnostics.

The intended Java 25 design uses public virtual threads for stackful
fiber/coroutine protocols and suitable threads, with explicit Ruby ownership
and handoff state. Immutable record value-doubles carry primitive/boxed
alternatives without identity dependence, leaving a future Valhalla seam.
Records do not guarantee stack allocation. FFI uses final `java.lang.foreign`
APIs and a minimal C ABI, never JVM object addresses or a new JNI layer.

## Next implementation sequence

Proceed in small, separately tested commits following plan phases 0 and 1:

1. Emit actual Java 25/version-69 classes, require JDK 25 consistently, and
   update runtime compilation, CLI, `spin.toml` defaults, ASM validation, and tests.
2. Check in a reproducible Java-on/off correctness matrix with timeouts,
   verification, expected streams/arguments, explicit skips, and bounded
   performance cases. Historical `/tmp` audit artifacts may no longer exist.
3. Repair/version IR: binary strings, overflow policy, stable lexical bindings,
   and complete typed native declarations with ownership/lifetime information.
4. Extract shared Java resolution; add typed adapters into boxed bodies while
   retaining direct typed Java exports. Demonstrate Java-enabled Sudoku and
   captured array blocks making real Java calls with unchanged results.
5. Continue exception/control-flow, specialization, callable, and library
   phases. Implement record numeric carriers, virtual-thread fibers, and Panama
   along the documented semantic boundaries rather than as compatibility hacks.

## Git and working-tree cautions

Only `origin` is configured, pointing to `git@github.com:matz/spinel.git`.
There is no `headius/spinel` remote or branch upstream. No push is part of this
milestone. The locally recorded `origin/master` was `4deaef850`, 11,537 commits
ahead of the old base; refs were not fetched. Confirm destination/base and run
the native gate before upstream integration; do not silently rebase this checkpoint.

The original workspace retains an uncommitted Java-timed infinite
`benchmark/bm_range_each.rb` and the independent native pthread-probe edit.
Neither belongs to this commit. The committed one-shot range benchmark and
all expected-output fixtures remain portable and unchanged. Preserve local
`.idea/`, JARs/AOT images, binaries, and root-level experiments; do not use
`git add .`, destructive resets, or broad cleanup commands.

Suggested new-chat request: "Continue the Spinel JVM backend from prototype
milestone 1 on codex/jvm-prototype-m1. Read jvm/MILESTONE_1.md and its linked
plans first, preserve unrelated dirty files, and begin the Java 25 phase-0
toolchain/IR work with regression tests."
