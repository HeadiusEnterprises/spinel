# JVM backend development

Restart context is in [MILESTONE_1.md](MILESTONE_1.md).
The checkpoint emits Java 17 bytecode. Java 25 runtime work remains in
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) and [PANAMA.md](PANAMA.md).

## Source boundaries

- `src/backend_ir.c`: deterministic analyzed IR and lexical syntax export.
- `lib/spinel/jvm/ir.rb`: schema and reference validation.
- `compiler.rb`: primitive values, object methods, and lowering selection.
- `java_interop.rb`: imports, signature resolution, overloads, and direct calls.
- `java_types.rb`: Java declaration collection and contract validation.
- `java_type_emitter.rb`: interface, record, and enum bytecode.
- `range_iteration.rb`: inlined finite integer range loops.
- `core_compiler.rb`: boxed values, lexical slots, and compiled closures.
- `runtime/org/spinel/runtime/Core.java`: boxed Ruby operations using JDK APIs.
- `benchmark_audit.rb`: compilation, bounded execution, and exact stdout checks.

Bare compiler filenames are under `lib/spinel/jvm/`; other paths are relative
to `jvm/`, except the frontend's `src/backend_ir.c`.
Generated programs do not depend on JRuby or BiteScript.

## Style

RuboCop is pinned in `Gemfile.lock`; `.rubocop.yml` defines the local policy:
two-space indentation, double-quoted strings, descriptive Ruby identifiers,
and 120-column lines. Comments describe contracts or non-obvious bytecode
invariants, not each instruction. Every method has a leading description,
including private helpers; complex methods also document stack effects,
scope handling, or resolution constraints. RuboCop enforces method descriptions
outside language fixtures. Bytecode visitors retain higher complexity
limits; `emit_expression` retains its node-kind dispatch as one method.
Language fixtures are excluded because their syntax and string mutability
are test inputs. The BiteScript compatibility shim deliberately reopens classes.

Use CRuby through chruby for linting:

```sh
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh
chruby ruby-3.4.7
cd jvm
bundle install
bundle exec rake lint
```

Select an installed CRuby under `~/.rubies` if that version is unavailable.
RuboCop is an MRI-only development dependency; JRuby compiles the backend.
For locked JVM tests, use `jruby -rbundler/setup -S rake` from `jvm/`; this
keeps executable shebangs from selecting a different Ruby installation.
Do not automatically correct fixtures or the entire existing `tools/spin.rb`:
the latter must remain in Spinel's AOT-compilable Ruby subset. Review automatic
corrections and run semantic tests, especially around BiteScript's dynamic API.

Java runtime formatting uses `clang-format --style=Google`. The C exporter
uses LLVM formatting with two-space indentation and a 100-column limit.

## Verification

From the repository root, with the selected JDK on `PATH` and in `JAVA_HOME`:

```sh
make jvm-test
make jvm-bench
# Run spin's native integration checks with chruby-selected CRuby:
chruby ruby-3.4.7
make spin-check
git diff --check
```

`jvm-test` compiles every benchmark and runs scalar, object, closure, Java ABI,
and `spin` regressions. `jvm-bench` also executes benchmarks and checks binary
stdout. The current local `bm_range_each.rb` is an infinite performance driver;
preserve it and exclude it from expected-output execution:

```sh
jruby -e '
  programs = Dir["benchmark/*.rb"].map { |path| File.basename(path) }
  ARGV.replace(["--run"] + programs.reject { |name| name == "bm_range_each.rb" })
  load "jvm/benchmark_audit.rb"
'
```

## Checkpoint scope

Include the JVM source/configuration/lockfile/tests/docs, `src/backend_ir.c`
and `.h`, frontend hooks, Makefile targets, and `spin` integration. Exclude
the user's modified benchmark, the independent native pthread-probe hunk in
`tools/spin.rb`, `.idea/`, generated binaries/JARs/AOT images, and unrelated
root-level experiments. Do not stage the whole working tree.
See [COMMIT_READINESS.md](COMMIT_READINESS.md) for verification and remaining gates.
