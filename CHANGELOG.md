# Changelog

## [Unreleased]

- Native extensions. `audition .` in a gem checkout, `audition
  <gem>` on an installed gem, app targets, and bundle sweeps now
  report every compiled extension (`.bundle`/`.so`) that never
  declares Ractor safety, as a warning: every method such an
  extension defines raises `Ractor::UnsafeError` on the first
  call from a non-main Ractor, C, Rust, and Zig alike (verified
  on Ruby 4.0.6). The static check (`native-extension`) is a
  byte scan for the `rb_ext_ractor_safe` import, so it covers
  precompiled platform gems that ship no sources; an unbuilt
  checkout is scanned at the source level instead (`ext/**` in
  C, Rust, or Zig), anchored at the declaration or at `Init_*`,
  where it belongs, and harness trees (fuzz, benches, tests)
  are ignored. The require and Rails probes extend it to
  dependencies (`runtime-native-extension`): the harness records
  every compiled file the load pulled in and byte-scans those
  too, attributing them to the dependency; Ruby's own archdir
  extensions are left to Ruby, and files the static check
  already reported are not repeated. Declared extensions get an
  info note, since the declaration is the maintainer's
  assertion, not a proof. Cargo and Zig build output and
  `.dSYM` copies are skipped.
- The require probe finds squashed entry files. `audition
  activesupport` used to fail its dynamic probe with "cannot load
  such file": the gem's entry is `active_support`, and no rule
  inverts that spelling. When the target ships exactly one
  top-level file under `lib/`, the probe now requires it after
  the name and its slashed form fail, and reports the last error
  seen rather than the first.
- Fix knowledge base: third pass, the gem dialect. i18n PR 741
  (the first full gem conversion out of the Rails ractorization
  effort) read in full and distilled into three new patterns in
  docs/rails_core_best_practices.md: config class variables
  moving to singleton-class ivars behind delegators, the opt-in
  `<gem>/ractorize` entry point, and frozen caches degrading to
  recompute-per-call. audition was run on both sides of the PR
  to verify its checks against the conversion; it confirmed the
  fixes, caught a `.freeze` lost in a rebase and a class
  variable read that still raises from workers (reproduced on
  Ruby 4.0.6), and the class-variable semantics claim in the
  checks' advice was re-verified: reads raise even for
  shareable values.
- CI-ready. `--exit-zero` (alias for the new `--fail-on never`,
  also accepted in `.audition.yml`) reports every finding but
  always exits 0, the adoption mode other linters ship under the
  same name. `--format github` now also appends a verdict and
  counts markdown table to the job summary page when GitHub
  Actions provides one, strips `./` prefixes so annotations
  anchor to the PR diff, and works for bundle sweeps: one
  annotation per failing gem plus the readiness line, instead of
  a terminal table.
- Git-hook-ready. Several `.rb` file arguments now audit as one
  static target, the shape hook managers pass staged files in
  (lefthook's `{staged_files}`, pre-commit's filename
  arguments); config, pragmas, and the baseline resolve against
  the working directory. Previously everything after the first
  argument was silently ignored. README gained a CI and git
  hooks section with copy-paste lefthook, pre-commit, and
  GitHub Actions configs.
- Dogfooding: this repository now runs audition on itself, on
  every commit through lefthook (staged files, static) and on
  every push through a non-blocking CI self-audit with PR
  annotations and a job summary.
- Dynamic dependency attribution now matches the static
  scanner's exclusion rule: constants whose source lives in a
  vendored or dot directory under the target root (Bundler's
  deployment mode and Actions' bundler-cache put every gem in
  `vendor/bundle`) count as dependencies, not as the target's
  own code. Found by the very first CI self-audit, which
  attributed the vendored gems to audition itself and flipped
  the verdict from blocked to not_ready.
- Report rendering split into one class per format
  (`Report::Text`, `Report::Json`, `Report::Github`); the
  `Report` class keeps only the data, verdict, and counts. The
  `Report#to_text/to_json/to_github` methods are gone, an API
  change for anyone driving audition programmatically.

## [0.2.4] - 2026-08-23

- The mutable-constants check no longer crashes with a
  `NoMethodError` on a proc constant built from a block
  argument (e.g. `TRUE_NODE = lambda(&:true_type?)`. [@viralpraxis](https://github.com/viralpraxis)
- A proc constant whose block arrives as `&expr` gets no
  `Ractor.make_shareable` autofix. There is no body for the
  capture scanner to read, so the wrap cannot be shown safe. [@viralpraxis](https://github.com/viralpraxis)

## [0.2.3] - 2026-08-22

- Fix knowledge base refreshed from the latest fixes on Rails
  main: the 61 ractorization commits that landed after the first
  study (through 2026-08-20) were read in full and distilled into
  seven new patterns in docs/rails_core_best_practices.md, with
  every claim that touches audition's behavior verified on Ruby
  4.0.6. The check advice, autofix recipes, README, and agent
  skill below follow from that refresh.
- New mutable-constants finding, with a safe `.freeze` autofix,
  for constants holding a call result that the
  `frozen_string_literal` magic comment never covers: String-only
  methods on any receiver (`X.tr(":", "")`), String methods on
  literals (`"a" + "b"`), `format`, `String.new`, and
  `Regexp.new`/`union`/`compile`. Operator calls are
  parenthesized before the suffix. Validated on Rails 8.1.3,
  where it flags exactly the two sites Rails fixed in August
  2026 plus `Regexp.union` constants in four gems, with no false
  positives.
- The Rails macro rule is split: `cattr_*`/`mattr_*` stay errors
  (class variables, unreadable from any Ractor) and now point at
  the `class_attribute` migration Rails made itself;
  `class_attribute` and `thread_mattr_accessor` downgrade to a
  warning, because Rails 8.2 made their readers Ractor-safe, with
  the frozen-default plus copy-on-write recipe as the fix.
- The `define_method` advice now leads with
  `define_method(:x, Ractor.shareable_lambda { ... })`, the form
  Rails settled on, and spells out its capture rules.
- Class-level state advice refreshed: frozen private constants
  for configuration-free memos, dropping cheap memos, `defined?`
  guards for values that can be nil or false, `eager_load!` and
  `inherited` warmers, boot-hook freezing for plugin-extended
  registries, and per-Ractor mutexes only for per-Ractor state.

## [0.2.2] - 2026-07-27

- The Ractor-parallel scan no longer collapses into a serial
  rerun, spraying Ractor backtraces on stderr first, whenever a
  scanned file sends the capture scanner after local variables.
  Its visit methods were generated with define_method, the exact
  un-shareable-Proc pattern audition's own unsafe-calls check
  flags (and a pragma silenced), so the first dispatch from a
  worker Ractor raised. They are plain defs now, and the check
  is covered by an in-Ractor regression spec. Found while
  verifying rubydex 0.3.0, which audition now runs on: findings
  are byte-identical to 0.2.9 on real gems and no API we consume
  changed, so the dependency floor stays at 0.2.

## [0.2.1] - 2026-07-23

- Terminal tables modernized on table_tennis 1.0 (now the
  dependency floor). The sweep and capability tables follow the
  CLI's own color detection, so `--plain` and `NO_COLOR` reach
  them; cell coercion is off, so a version like "3.2" renders
  verbatim instead of 3.200; empty cells show "-"; interactive
  terminals get autolayout with ANSI-safe truncation while
  pipes keep full-width grep-able output; and the sweep table
  is zebra-striped for long dependency lists.

- Adversarial hardening pass: four independent reviews of the
  fixer, checks, dynamic layer, and CLI produced 38 verified
  findings, all fixed with regression specs. Highlights: probe
  timeouts kill the whole process group and cannot be defeated
  by spawned children; binary bytes anywhere in target output
  or exception messages can no longer crash a run; pragmas are
  parsed from real comments only and all pragmas on a line are
  honored; magic comments follow Ruby's position and case rules;
  explicit `frozen_string_literal: false` is never overridden;
  write-once conversion refuses conditional writes, inherited
  class variables, alias-escaping reads, and name collisions;
  nested edits can no longer swallow a companion group's
  rewrite; the sweep honors directives, per-gem config,
  `--fail-on`, and locked gem versions; excludes follow proper
  glob semantics; `--compare` is path-form-proof; JSON output
  stays parseable under `--fix`; and fixable counts only count
  what `--fix` alone would fix.

- New unsafe rewrite for config setters: a singleton setter
  assigning its bare parameter (`@backend = value`) becomes
  `@backend = (Ractor.make_shareable(value) rescue value)`, the
  Rails try_make_shareable recipe in plain Ruby. Shareable
  values are deeply frozen so any Ractor may read them;
  unshareable values keep their old behavior through the
  rescue. The class-level-state check recognizes the pattern
  and downgrades such state to a best-effort warning, with the
  dynamic probe as ground truth.

- Battle-tested against mail, liquid, sinatra, faraday, and
  money; suites pass at baseline parity after `--fix-unsafe`
  except three liquid tests that mutate a converted registry
  from another file (the documented cross-file blindness of the
  unsafe tier). Five more fixer bugs fixed: bracketless
  multi-value constants (`X = :a, :b`) gain brackets when
  wrapped; constructor memos (`@x ||= Set.new`, `@instance ||=
  new`) are never frozen or made Ractor-local; write-once
  conversion skips constructed values that may gain singleton
  methods (sinatra's `@@eats_errors`); Ractor-local conversion
  is limited to module-owned state, since class ivars shard per
  subclass (faraday's `DEFAULT_OPTIONS`); and constants the
  defining file itself mutates (sinatra's `PARAMS_CONFIG`)
  block both magic comments and inline wraps while keeping
  their finding.

## [0.2.0] - 2026-07-19

- Class-level memoization fixes recognize both idioms (`@x ||=`
  and `return @x if defined?(@x)`) and apply freeze-on-memoize,
  the Rails-core pattern: the memoization stays exactly as
  written and only the memoized value becomes shareable
  (`.freeze`, or `Ractor.make_shareable` for containers).
  `Ractor.store_if_absent` remains the fallback for initializers
  with blocks and invalidated caches, emitted as an indented
  `do..end` block when the value spans lines.
- Frozen memoization is recognized as a pattern, not punished:
  the class-level-state check and the runtime sweep downgrade
  class state that holds only shareable values to an info note
  telling you to warm the cache at boot. Info notes no longer
  taint the verdict; a target with only info findings is
  `ready`.
- `--dry-run` previews render touching edits as a single hunk
  instead of repeating a line in two half-applied states.
- Battle-tested against i18n; its full suite passes after
  `--fix-unsafe`. Five fixer bugs found and fixed in the process:
  autoload conversion keeps the registration and appends the
  eager require at the end of the file (converting in
  registration order broke mutually referencing files); the
  conversion is withheld for files guarded by `rescue LoadError`
  or resolving outside the target (optional dependencies);
  require hoisting moved to the unsafe tier (eager loading is not
  behavior-preserving for context-sensitive files);
  `shareable_constant_value` is only inserted when every constant
  is a literal all the way down (Racc parser tables are array
  literals full of locals and raise at load otherwise), and the
  insertion ignores doc comments that merely look like magic
  comments; caches with nil invalidation convert to
  `Ractor.current[key] ||=`, preserving reset semantics where
  `store_if_absent` would cache the nil forever.
- Battle-tested against five more gems (multi_json, jwt, tzinfo,
  addressable, public_suffix); every suite passes after
  `--fix-unsafe` except two public_suffix assertions that inspect
  the moved ivar itself. Six more fixer bugs found and fixed:
  edits are spliced by byte offset (multibyte sources, such as
  addressable's Unicode tables, were corrupted by
  character-indexed splicing); containers holding sync primitives
  classify as sync primitives and get no wrap
  (Ractor.make_shareable on multi_json's Hash of Mutexes raised
  at load); memoized values that are not provably strings get
  Ractor.make_shareable instead of `.freeze` (freezing a
  memoized adapter Class froze the class object); ternaries of
  string literals classify as strings so they keep a plain
  parenthesized `.freeze`; `shareable_constant_value` requires
  bare literals (a frozen literal is a method call and raises at
  assignment, as jwt's NAMED_CURVES showed); empty-container
  memo accumulators (`@x ||= {}` registries) and rescue-guarded
  requires (tzinfo's optional tzinfo-data) are left for humans.
- New checks trained on the Rails core ractorization effort
  (documented in docs/rails_core_best_practices.md): `Hash.new`
  with a default proc (the block survives `.freeze`), in-place
  mutation of screaming-case constants (`RENDERERS << key`), and
  `define_method` with a literal block (the method carries an
  unshareable Proc). Class-level state advice now teaches the
  Rails copy-on-write idiom: rebuild and refreeze on write, and
  compute per-subclass values in the `inherited` hook.

## [0.1.0] - 2026-07-18

Initial release. Written end to end by Claude Fable 5 (Anthropic);
see the README warning.

- Static analysis on Prism: global variables (allowlist verified on
  Ruby 4.0), deeply-shareable constant classification with shallow
  freeze detection, runtime require/autoload, `Ractor.new` outer
  local capture, and a knowledge base of hostile or removed APIs.
- Whole-program checks on the rubydex graph: class variables and
  class-level instance variable state unified across files and
  reopenings.
- Dynamic probing in subprocesses: scripts run inside a real
  Ractor, libraries are required and their namespaces swept with
  `Ractor.shareable?` and dependency attribution, Rack apps boot
  and serve a request per-Ractor, Rails boots and eager-loads, and
  `--capabilities` reports what the running Ruby allows in Ractors.
- Verdicts: `ready`, `risky`, `blocked` (own code clean,
  dependencies dirty), `not_ready`.
- `--fix` in two tiers: safe corrections (freezes,
  `Ractor.make_shareable` wraps, require hoisting) and
  `--fix-unsafe` rewrites (magic comments, class memoization to
  `Ractor.store_if_absent`, autoload conversion, write-once
  globals/class variables to constants), with `--dry-run` preview.
- Bundle sweep: `audition Gemfile.lock` or `--deps` ranks every
  gem in the bundle in one verdict table.
- Incremental adoption: `# audition:disable` pragmas,
  `.audition.yml` config, and a line-drift-resilient baseline
  (`--write-baseline`).
- Ractor-parallel static scanning of large targets.
- Terminal output with colors, glyphs, and OSC 8 hyperlinks; JSON
  for CI.
