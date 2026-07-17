# audition; design

Probe anything (script, gem, Rack app, Rails app, directory) for the ability to run
under Ractors. Report **what** breaks, **why** it breaks, and **how to fix it**.
Strictly Ruby 4.0+.

## Why this tool

No prior art exists: RuboCop has one cop (`Style/MutableConstant`), the rest of the
ecosystem ships Ractor *utilities* (ractor_safe, ratomic, ractor-pool), not checkers.
`Ractor.shareable?` is a primitive, not a diagnosis. Companion use case: verifying an
app can run on Ractor-parallel web servers such as [kino](https://github.com/yaroslav/kino).

## Two probes, one report

1. **Static analysis** (`Audition::Static`); Prism AST checks over every `.rb` file.
   Finds code that *would* raise under a non-main Ractor, with file:line precision.
   Zero execution, safe on any codebase.
2. **Dynamic probing** (`Audition::Dynamic`); a subprocess harness (JSON over stdout)
   that actually loads the target and interrogates it: runs scripts inside a Ractor,
   requires libraries and walks their namespaces checking `Ractor.shareable?` on every
   constant plus class-level state, calls Rack apps inside a Ractor, and micro-probes
   the running Ruby's Ractor capabilities.

Static finds latent hazards dynamic can't reach (code paths never executed during a
probe); dynamic finds truth static can't see (metaprogramming, actual object graphs).

## Ruby 4.0 Ractor semantics (empirically verified on 4.0.6, 2026-07-17)

| Operation in non-main Ractor | Result |
|---|---|
| Global variable read or write | `Ractor::IsolationError` |
| Class variable access | `Ractor::IsolationError` |
| Class/module ivar **write** | `Ractor::IsolationError` |
| Class/module ivar **read**, shareable value | OK (new in 4.x line) |
| Class/module ivar **read**, unshareable value | `Ractor::IsolationError` |
| Read constant holding unshareable value | `Ractor::IsolationError` |
| ...including shallow-frozen (`[[1]].freeze`) | `Ractor::IsolationError` (deep check) |
| `const_set` with unshareable value | `Ractor::IsolationError` |
| ENV read/write | OK (was error in 3.x) |
| `$VERBOSE` / `$DEBUG` read and write, `$$` read | OK |
| `$0`, `$PROGRAM_NAME`, `$;` read; `$stdout =` write | `Ractor::IsolationError` |
| `load` | Runs in the calling Ractor (NOT proxied, unlike `require`) |
| `require` | OK; proxied to main Ractor (serializes) |
| `ObjectSpace.each_object`, `Signal.trap` | OK (was error in 3.x) |
| Copying a Proc into a Ractor | `TypeError: allocator undefined for Proc` |
| Block capturing outer locals | `ArgumentError` at `Ractor.new` |
| Errors via `Ractor#value` | `Ractor::RemoteError`, real error in `#cause` |
| `Ractor#take` / `Ractor.yield` | Removed; `Ractor::Port`, `Ractor#value` |

## Components

- `Audition::Finding`; `Data` value: check, severity (`:error/:warning/:info`),
  message, why, fix, path, line, source. Error = will raise under a Ractor;
  warning = raises depending on value/usage; info = works but has caveats.
- `Audition::Target`; detects `:script | :gem | :rack | :rails | :directory` from a
  path or installed gem name; enumerates the Ruby files to scan and the dynamic entry.
- `Audition::Static::SourceFile`; path + Prism parse result + magic-comment awareness
  (`frozen_string_literal`, `shareable_constant_value`).
- `Audition::Static::Checks::*`; one Prism visitor per check:
  `GlobalVariables`, `ClassVariables`, `MutableConstants` (deep shareability, shallow
  freeze detection), `ClassLevelState` (ivars on class objects incl. `@x ||=`
  memoization), `RuntimeRequire` (require/autoload at runtime), `UnsafeCalls`
  (knowledge-base driven: Rails class-level macros, sync primitives, removed APIs...).
- `Audition::Dynamic::Harness`; standalone script run via `ruby harness.rb <mode>`,
  stdlib-only, one JSON document out. Modes: `script_main`, `script_ractor`,
  `require` (namespace walk), `rack`, `capabilities`.
- `Audition::Dynamic::Prober`; spawns the harness per mode with timeout, parses JSON,
  converts results to findings.
- `Audition::Report`; text (grouped by file, colored) and JSON; verdict roll-up.
- `Audition::CLI` / `exe/audition`; OptionParser; exit 0 clean / 1 findings ≥
  `--fail-on` threshold / 2 usage error.

## Out of scope (v1)

Scoped `shareable_constant_value` regions (treated file-wide), non-literal constant
values statically (dynamic probe covers them), auto-fixing.
