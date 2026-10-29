# JVM prototype milestone 1: commit assessment

Assessment date: 2026-10-29. Restart context: [MILESTONE_1.md](MILESTONE_1.md).

## Conclusion

The selected source is suitable for the first experimental checkpoint on
`codex/jvm-prototype-m1`. It is not an upstream merge-ready or production-ready
backend. The implementation emits Java 17 classes; the documented Java 25
migration is a separate phase.

## Verification

Verification used chruby-selected CRuby 3.4.7, JRuby 10.1.1.0, BiteScript 0.1.4,
RuboCop 1.92.0, and Zulu JDK 25+36-LTS.

- RuboCop: 25 backend/tool/test Ruby files, no offenses, including the enforced
  public/private method-description policy. Language fixtures remain excluded.
- The staged source snapshot passed the JVM suite: toolchain, IR validation,
  scalars, objects, inheritance, boxed values/closures, Java imports/exports,
  `spin` integration, and compilation of all 62 original benchmarks.
- All 62 original benchmarks matched checked-in binary stdout with JVM
  verification enabled, including the portable one-shot range workload.
- The locally modified infinite `bm_range_each.rb` was not staged or run in the
  expected-output audit. Its source and expected-output fixture were preserved.
- Locked JRuby execution exposed a test-environment leak into CRuby `spin`.
  The integration test now isolates Bundler activation for that subprocess.
- Native `make spin-check` passed in the working tree using chruby. That tree
  includes a separate, unstaged pthread-probe escaping edit in `tools/spin.rb`;
  this result is not proof of the native gate on the exact committed snapshot.
- Staged-copy checks reused the built frontend and generated version module.
  A clean native rebuild, full native/platform gate, and network-fresh
  dependency installation were not performed.

## Scope and limitations

The checkpoint contains the frontend IR export, JVM compiler/runtime,
Java import/export ABI support, `spin` integration, source fixtures/tests,
dependency lockfile, lint policy, and development/future-design documentation.
It includes the source cleanup and descriptions for Ruby methods and fixtures.

Known limitations in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) remain:
separate Java/boxed lowering paths, invalid binary-string IR, differing numeric
policies, first-failure feature counts, and incomplete language/library coverage.
Virtual threads, record value-doubles, and Panama are planned, not implemented.

The user's benchmark edit, independent pthread-probe hunk, `.idea/`, generated
executables, JARs/AOT images, and unrelated root-level experiments stay outside
the checkpoint. Preserve them when continuing work. Do not use `git add .`.

## Integration and publication

The milestone starts from `0d458e2b6` (2026-09-17). The locally recorded
`origin/master` is `4deaef850` (2026-10-21), 11,537 commits ahead of that base.
No refs were fetched and no rebase was performed. Confirm the intended upstream
base and run the native gate before claiming integration readiness.

The only remote is `origin` at `git@github.com:matz/spinel.git`. There is no
configured `headius/spinel` remote or branch upstream. The milestone is local;
no push or remote modification is part of this request.
