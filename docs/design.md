# Audition; design

Probe anything (script, gem, Rack app, Rails app, directory) for the ability to run
under Ractors. Report **what** breaks, **why** it breaks, and **how to fix it**.
Strictly Ruby 4.0+.

## Why this tool

No prior art exists: RuboCop has one cop (`Style/MutableConstant`), the rest of the
ecosystem ships Ractor *utilities* (ractor_safe, ratomic, ractor-pool), not checkers.
`Ractor.shareable?` is a primitive, not a diagnosis. Companion use case: verifying an
app can run on Ractor-parallel web servers such as [kino](https://github.com/yaroslav/kino).

## Three passes, one report

1. **Per-file static** (`Audition::Static::Analyzer`); one Prism visitor per check over
   every `.rb` file. Expression-level: what a single file can prove alone. Zero
   execution, safe on any codebase.
2. **Whole-program static** (`Audition::Static::GraphAudit`); semantic checks on the
   rubydex graph, which resolves state to its true owner. An ivar written in the class
   body, in `def self.x`, and inside `class << self`, across several files, unifies
   into one declaration; per-file visitors cannot see that. The pass also reports where
   the graph *fails* to resolve, so a hole does not read as a clean line.
3. **Dynamic probing** (`Audition::Dynamic`); a subprocess harness (JSON over stdout)
   that actually loads the target and interrogates it: runs scripts inside a Ractor,
   requires libraries and walks their namespaces checking `Ractor.shareable?` on every
   constant plus class-level state, calls Rack apps inside a Ractor, boots Rails apps
   with the proc gate armed and freezes them through `ractorize!` before serving a
   request on the main Ractor and inside a worker, and micro-probes the running Ruby's
   Ractor capabilities.

Static finds latent hazards dynamic can't reach (code paths never executed during a
probe); dynamic finds truth static can't see (metaprogramming, actual object graphs).
Neither closes the other's blind spots, so both report, and the check name says which
layer spoke (`runtime-*` and `dynamic-*` are the probe's).

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

## Scanning in Ractors

The scan is CPU-bound and embarrassingly parallel, so both static passes fan out:
`Etc.nprocessors` capped by `RUBY_MAX_CPU` (default 8—Ractors past the cap add no
parallelism), overridable with `-j`. `WorkSplit` deals files largest-first onto
whichever worker carries least (longest-processing-time-first, Graham 1969; byte size
stands in for parse cost). Contiguous slices would not do: neighbours in a tree are
alike in size, so one worker can draw a slice weighing several times the mean and
still be running once the rest have finished.

The graph audit fans out differently, because parsed Prism trees cannot cross a Ractor
boundary. Its whole-tree walks may not emit until every name the scan declares is
known, so each worker parses its slice once and keeps the trees: round one reports the
names its slice declares, and once those are merged round two walks the same trees
against them. Below 100 files the spawn and source copy cost more than the walks they
divide, so it stays serial. Any `Ractor::Error` falls back to serial, and under `-w`
the fallback says why—a walk that is itself Ractor-hostile must not hide behind it.

The bundle sweep is the exception: its per-gem static analysis runs in worker threads,
because the dynamic probes it interleaves are subprocesses and those parallelize
regardless of the GVL.

**Audition's own code has to be Ractor-safe**, since it runs its own checks inside
Ractors. Both violations so far were found by running Audition on itself: a constant
holding a hash of unfrozen arrays, and a shallow-frozen singleton.

### Mechanics the scanner itself depends on (verified on 4.0.6, 2026-09-13)

| Fact | Consequence |
|---|---|
| A `Set` of compound elements cannot cross a boundary; `Marshal` can | Dedup sets travel as pair arrays, rebuilt in the worker |
| `Ractor::ClosedError` is a `StopIteration`, not a `Ractor::Error` | Rescue both, or a send to a dead worker kills the scan |
| `Ractor#close` from another Ractor raises | Workers can't be cancelled; a bailed fan-out is abandoned |
| Blocked Ractors hold no Ractor-pool native threads | Abandoning them costs no later parallelism |
| No penalty for running outside the main Ractor | Walks move into workers wholesale |
| A process's first parallel round pays warmup | The per-file pass absorbs it before the graph phase |

## Components

- `Audition::Finding`; `Data` value: check, severity (`:error/:warning/:info`),
  message, why, fix, path, line, source. Error = will raise under a Ractor;
  warning = raises depending on value/usage; info = works but has caveats.
- `Audition::Target`; detects `:script | :gem | :rack | :rails | :directory` from a
  path or installed gem name; enumerates the Ruby files to scan and the dynamic entry.
- `Audition::Static::SourceFile`; path + Prism parse result + magic-comment awareness
  (`frozen_string_literal`, `shareable_constant_value`).
- `Audition::Static::Analyzer`; runs the per-file checks over sources or paths,
  serially or across Ractors, and reports unparseable files itself (`syntax`).
- `Audition::Static::Checks::*`; one Prism visitor per check: `GlobalVariables`,
  `MutableConstants` (deep shareability, shallow freeze detection), `RactorIsolation`
  (blocks capturing outer locals, off Prism's exact scope depths), `RuntimeRequire`
  (require/autoload at runtime), `UnsafeCalls` (knowledge-base driven: Rails
  class-level macros, sync primitives, removed APIs...), `UnshareableReads`,
  `DependencyClassState`, `InstanceMemoization` (lazy memos on classes that freeze
  their instances). Subclass `Base` and `Checks.register` to add one.
- `Audition::Static::LiteralClassifier`; classifies an expression node by shareability
  (`:shareable`, `:mutable_container`, `:fresh_container`, `:shallow_freeze`, `:proc`,
  `:default_proc`, `:unshareable_object`, `:opaque_call`, `:shallow_opaque`...); the
  shared vocabulary under the constant checks. Its return-type tables for core
  methods are executed against the running Ruby by their spec.
- `Audition::Static::GraphAudit`; the rubydex-graph pass: `class-variables`,
  `class-level-state` (including singleton attributes, writes through them, and
  the companion module a concern puts on the class),
  `derived-constants` (a flagged value followed into the constants that capture it),
  and `static-scan` (the graph's own unresolved expressions, where the shape could
  hide what the other walks look for).
- `Audition::Static::NativeExtensions` / `GemCalls`; byte-scan every compiled
  `.bundle`/`.so` for the `rb_ext_ractor_safe` import, then flag call sites into gems
  that never declared it—the extension is outside the scanned tree, so the call site
  is all that is left to report. Taint follows the values from there.
- `Audition::Static::WorkSplit`; worker count and largest-first work dealing.
- `Audition::Dynamic::Harness`; standalone script run via `ruby harness.rb <mode>`,
  stdlib-only, one JSON document out. Modes: `script_main`, `script_ractor`,
  `require` (namespace walk), `rack`, `rails` (boot, proc gate, `ractorize!`, one
  request on main and one in a Ractor), `capabilities`.
- `Audition::Dynamic::Prober`; spawns the harness per mode with timeout, parses JSON,
  converts results to findings.
- `Audition::Fixer` / `Audition::Rewriters`; safe inline autofixes attached to
  findings, applied bottom-up so offsets hold, plus unsafe-tier multi-site rewrites
  planned from a parsed file and its findings. `--dry-run` previews either.
- `Audition::Baseline` / `Config` / `Directives`; the incremental-adoption ledger
  (counts per `check|relative/path`, so line drift does not resurrect a finding),
  `.audition.yml`, and `# audition:disable <check>` pragmas.
- `Audition::BundleSweep`; audits every gem in a `Gemfile.lock` and ranks the
  results; the "can my whole app move to Ractors" view.
- `Audition::Progress`; narrates the scan phase by phase on stderr, stdout left
  pipeable. Shareable, so a worker can hold one.
- `Audition::Report`; `Text` (grouped by file, colored), `JSON`, `GitHub`
  (annotations plus job summary), `Sweep` (the per-gem table), `Style` (color and OSC 8
  hyperlinks, decided once and stripped for pipes, `NO_COLOR`, `TERM=dumb`); verdict
  roll-up over all three passes.
- `Audition::CLI` / `exe/audition`; OptionParser; exit 0 clean / 1 findings ≥
  `--fail-on` threshold / 2 usage error.

## Out of scope (v1)

Scoped `shareable_constant_value` regions (treated file-wide). Constant values that
depend on runtime state: the classifier names the shapes it can (`:opaque_call`,
`:shallow_opaque`) and taint-follows them, but proving what a call actually returns
stays the dynamic probe's job.
