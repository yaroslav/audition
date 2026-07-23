# Changelog

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
