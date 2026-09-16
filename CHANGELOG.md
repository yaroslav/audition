# Changelog

## [Unreleased]

- The constant classifier knows the return-type contracts of
  core methods, and a spec executes the tables against the
  running Ruby so no entry can drift. A call whose core contract
  is a newly allocated object is now an error where it was an
  unproven warning: Enumerable and Hash methods that allocate on
  every core receiver (`.map`, `.keys`, `.merge`,
  `.each_with_object({})`, `.flatten`, `.select`), set operators
  with a literal operand (`BASE + [:x]`, `PREFIX + "s"`), `.dup`,
  strings a core method builds (`[8, 2, 0].join(".")`,
  `:sym.to_s`, `/re/.source`, `+"str"`), and string splitters
  whose elements stay unfrozen under a bare `.freeze`
  (`".*".chars.freeze`). A Method or UnboundMethod in a constant
  (`Module.instance_method(:name)`) is an error no freeze can
  fix. Fresh strings get the safe `.freeze` autofix; fresh
  containers the unsafe `Ractor.make_shareable` wrap. In the
  other direction, integer arithmetic (`1024 * 1024`, `1 << 30`,
  `LIMIT - 1`), comparisons, negation, `-"str"` and `:sym.name`
  now classify as shareable and stop warning. Calls on a class or
  module (`Settings.dup`) keep their warning: a class method has
  no core contract. Across the 470 installed gems, unproven
  constant warnings fall from 1663 to 996, and 281 constants
  that raise from a worker are errors.
- New check `instance-memoization`, for the one instance-level
  lazy memo that is provable statically. A class whose
  initialize ends by freezing self (or by
  `Ractor.make_shareable(self)`) cannot memoize lazily: every
  `@x ||=` in an instance method is an error, since the first
  call raises FrozenError. A class with a `freeze` override is
  expected to be frozen, so a memo the override does not warm
  (by calling the memoizing method or assigning the ivar before
  `super`) is a warning; warming it there is the
  compute-on-freeze pattern. Class-level memos stay with the
  graph audit.
- Copy-on-write advice (`class_attribute`, class-level state,
  registry mutation) now separates a plain `.freeze` for
  shareable elements from `Ractor.make_shareable` for additions
  that may be unfrozen, such as `Symbol#to_s` results; the old
  recipe was a shallow freeze, the very shape the shallow-freeze
  error reports.
- The read-then-proxy memo, `@x || on_main(self) { @x ||= v }`,
  is rated as the main-Ractor escape hatch it is: a warning, an
  info note when the value is provably frozen, an error again
  when a stray write sits beside it. The unsafe fixer no longer
  edits inside the proxied block.
- Two `ractor-isolation` rules for blocks that
  `Ractor.shareable_proc` refuses: a block handed to
  `shareable_proc` or `shareable_lambda` (error) or to a Rails
  callback macro such as `before_create`, `validate`, `on_load`
  or `initializer` (warning) that captures a local holding a
  provably unshareable value (`prefix = +"Draft: "`, `[]`,
  `String.new`) or a local assigned more than once. Captures of
  unknown value stay silent; the boot gate below is their
  detector.
- The Rails probe arms `unshareable_proc_action = :warn` before
  boot and again before eager loading, and reports each block
  Rails could not share as `runtime-unshareable-proc` at the
  Proc's definition site. On Rails 8.2 it then calls `ractorize!`,
  serves one GET / on the main Ractor and one inside a Ractor,
  and reports the first object that cannot be shared, a request
  that broke on the frozen graph (a lazy memo raising
  FrozenError), or one that only broke inside a worker, each
  with the app-side line. Without `ractorize!` an info note
  names the installed Rails.
- Mutable-constant advice names the compatibility move for a
  public constant applications mutate: keep the constant, read
  it through an `initialize` keyword default into an ivar, and
  deprecate mutating it.
- README: `Ractor.make_shareable` wraps were listed under the
  safe fix tier; they have always been unsafe-tier.

## [0.4.0] - 2026-09-15

- Progress narration on stderr, stdout left pipeable:
  `◆ Audition checking 50/919 5% (0.2s, on 8 ractors)`,
  rewritten in place on a terminal, one line per phase off one.
  A phase running in Ractors says how many, next to the clock
  rather than the counts. On above 200 files and for every
  bundle sweep, off for `--format json` and `--format github`;
  `--progress` / `--no-progress` force either way.
- Files are dealt to scan Ractors largest-first, onto whichever
  worker is carrying least (longest-processing-time-first).
  Contiguous slices put neighbouring files—alike in size—on one
  worker, which left a single Ractor still running well after
  the others had finished: 2,500 files went 2.3s to 1.1s on 8
  workers.
- Worker count is now every core the Ractor pool can run,
  `Etc.nprocessors` capped by `RUBY_MAX_CPU` (default 8), where
  it was one less than the core count. Ractors past that cap add
  no parallelism; `-j` / `--workers` overrides.
- The graph audit's four whole-tree walks now run in the same
  Ractors, above 100 files. Each worker parses its slice once
  and keeps the trees: one round reports the class and module
  names its slice declares, and once those are merged a second
  round walks the same trees against them. 3,400 files went
  2.4s to 1.2s on 8 workers, the whole phase 3.8s to 2.6s.
- New check `static-scan`, for the static pass's own blind
  spots. rubydex reports every expression it could not resolve;
  where the shape could hide what the class-state and constant
  walks look for, the hole is now a finding instead of a clean
  line: a singleton opened on a runtime receiver that writes
  class-level state (`class << pick_target` around
  `@cache = {}`), a runtime superclass or mixin argument
  (`class Widget < base`, `include Object.const_get(name)`),
  and a constant assigned through an unresolved path
  (`TABLE = mod::Lookup`, info). Only the class and module
  bodies are read, so an `include` matcher in a spec stays
  silent, and a line another check already reported keeps its
  own finding.
- New `.audition.yml` key `test_dirs`, for a project that files
  its tests somewhere other than `test`, `spec` or `features`.
  Findings under those directories are tagged `test` and
  counted apart from production code. The list replaces the
  default rather than adding to it; the `_test.rb` and
  `_spec.rb` suffixes count whatever it says.
- Color on every output surface, not just the findings list.
  The bundle sweep gained a titled table: severity glyphs on
  the verdicts, one color per row, blank cells where a count is
  zero. Usage text, the baseline line, fix and dry-run output,
  `--compare` deltas and `--capabilities` too. `--plain`,
  `NO_COLOR` and `TERM=dumb` strip all of it.
- New check `native-gem-calls`, for calls into a C extension
  that never declared `rb_ext_ractor_safe`: they raise
  `Ractor::UnsafeError`, and the extension is outside the tree,
  so the call site is what gets flagged. Which gems count comes
  from the target's own `Gemfile.lock`, its installed extension
  binaries and its generated type stubs—never a gem list—and a
  platform build Audition cannot inspect is reported as
  unverified. Taint then follows the values: chained calls,
  locals and ivars, `sig`/`T.let`/`T.cast` types, `case`/`when`
  and `is_a?` narrowing, block element parameters, arguments
  into other methods, reopened classes, mixin bodies, and
  across files until nothing new is learned.
- Rails targets scan the whole root, not just `app`, `lib` and
  `config`—local gems, engines and tests boot into the same
  process. Vendored and scratch directories stay excluded.
  Indexing another call's result (`Registry.by_name["KEY"]`) is
  an unprovable call result.
- New `shallow_opaque` finding: `X.new.freeze`,
  `compute.freeze`, and frozen containers of fresh instances or
  unprovable call results freeze the wrapper, not the value. A
  later bare `NAME.freeze` counts the same, and one unknown
  element no longer excuses a provably fresh sibling, so
  `T.let({KEY => Widget.new(...)}.freeze, ...)` now reports.
- Class-level state finds three more shapes: `attr_accessor` or
  `attr_writer` on a singleton class (the declaration itself,
  plus every assignment through one), ivars assigned by
  instance methods of a module something `extend`s, and
  `instance_variable_set("@x", v)` or
  `remove_instance_variable(:@x)` where the receiver is
  provably a class. Computed names, unprovable receivers,
  `instance_variable_get`, `instance_variable_defined?` and
  `instance_variables` stay quiet.
- Class-level state no longer waits to be shown the `extend`. A
  concern puts its companion module on the class from inside
  whatever library defines the pattern, so nothing in the target
  ever spells `extend ClassMethods`, and a nested `ClassMethods`
  module or a `class_methods do` block went unread. Both are now
  walked as class-level scope. Which trees reported them used to
  turn on an unrelated file—one literal `extend ClassMethods`
  anywhere in a scan seeded the name for all of it—so the same
  shape was an error in one library and silent in its neighbour.
  `extend const_get(:Name)` on self and a module mixed into a
  `singleton_class` now count as extend sites, and a mixin
  argument that resolves this way stops being reported as one
  the graph could not read.
- New check `dependency-class-state`: a dependency holding its
  configuration in a class-level ivar has no source in the
  tree, so the call site is flagged; the target's own type
  stubs say which calls are attribute reads. Reads warn, writes
  error.
- New check `derived-constants`: an alias (`DEFAULT = PRIMARY`)
  or a frozen container of references (`ALL = [A, B].freeze`)
  inherits the referent's finding. `mutable-constants` findings
  seed a graph pass that propagates along constant references,
  transitively and across files, at the source's severity.
- New check `unshareable-reads`: reading a gem constant that
  holds an unshareable object warns at the read site, `sig`
  blocks included—Sorbet's `T::Boolean` is an unfrozen, lazily
  memoizing `TypeAlias`.
- Test findings are counted apart. Anything under `test/`,
  `spec/` or `features/`, or in a `_test.rb`/`_spec.rb` file,
  is marked `(tests)` in text and `"test"` in JSON and never
  moves the verdict or the exit code.
- `T.let`, `T.cast` and `T.must` are unwrapped everywhere:
  classification, the reported container type (no more "mutable
  T literal"), depth checks and autofixes all see the value
  inside. The safe fix is now `T.let({...}.freeze, ...)`, not a
  freeze on the cast.
- Dynamic findings pin the failing line. The harness ships a
  backtrace with every error, so script, rack, Rails boot and
  load failures land on the deepest frame inside the target
  instead of `line: nil` on the entry file.
- Constant sweep limit 5,000 → 200,000, and hitting it is a
  `runtime-scan` warning naming the count and the limit instead
  of silent truncation; probes take `max_constants`. A failed
  Rails boot keeps the sweep of everything loaded before it,
  and the rails probe realpaths the environment file so a
  symlinked root (macOS `/var`) stops turning the app's own
  findings into dependency findings.
- The sweep catches state planted on classes that already
  existed—a cache ivar on `String`, a class variable on a
  stdlib module. Every pre-boot module's ivars and class
  variables are snapshotted (without forcing autoloads) and
  diffed after the boot; RubyGems, Bundler and VM internals are
  excluded as probe machinery.
- Rack targets get the full sweep, not just the boot-and-serve
  verdict: the same constant, class-state, class-variable and
  native-extension passes require and Rails targets already
  got.
- Unshareable constants name their blocker: "just not frozen"
  where freezing the value fixes it, "blocked by unfrozen
  String inside" or "blocked by Proc inside" where it does not.
- `begin ... end` is classified by its last statement, so a
  constant built in a block is reported and fixed instead of
  reading as opaque; an inline cast around it is peeled in
  either order. A block with `rescue`, `else` or `ensure` stays
  opaque.
- More call shapes classified: a `Set` from an opaque source or
  a mapping block is a mutable container whatever it holds;
  indexing a constant (`Mime[:xml]`) is an unprovable call
  result, with `ENV` and Sorbet's `T` constructors silent; and
  `File.expand_path`, `join`, `dirname`, `basename`,
  `absolute_path` and `realpath` return fresh Strings—mutable
  bare, shareable frozen.
- Requires rubydex 0.4. The static scan reads rule objects and
  the `Rubydex::Rules` table, neither of which 0.3 ships; the
  dependency floor moves from 0.2 to 0.4 to say so.

## [0.3.0] - 2026-09-05

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
- Mutable constants learn three shapes, each verified on Ruby
  4.0.6: a bare `Object.new` sentinel (safe `.freeze` autofix,
  withheld when the file gives the object singleton methods;
  `BasicObject.new`, which has no `#freeze`, gets an
  `Object.new.freeze` replacement in the unsafe tier),
  `Set.new([...])`, `Set[...]`, and `[...].to_set` as containers,
  and `Concurrent::Map`, which cannot be frozen at all, beside
  the sync primitives. A constant frozen by a bare `NAME.freeze`
  statement later in the same class body now counts as
  build-then-freeze, so only provably mutable elements are
  reported. The container autofix writes a plain `.freeze` when
  every element is provably shareable and keeps the deep
  `Ractor.make_shareable` wrap otherwise; bracket-less
  `X = :a, :b` gains its brackets. On the 43 Rails files studied
  below the new rules flag all fourteen sites the PRs fixed and
  none after; on current rails/rails they find sixteen more that
  no PR has touched.
- Advice text stands on Ruby semantics: the class-variable macro
  advice names the singleton-ivar-plus-delegate conversion next
  to class_attribute, the runtime-require advice names the
  class-level macro as the boot-time scope for an optional
  dependency, and no advice cites Rails as the reason for a
  recipe or carries a commit id.
- Fix knowledge base: fourth pass, the 28 merged "Ractor
  Support" PRs that the commit-message and pickaxe selection of
  the first two passes never saw (freezes, memo deletions, and
  eager requires mention neither Ractor nor ractor). All 45
  commits and their review threads read in full and distilled
  into nine new patterns in docs/rails_core_best_practices.md:
  sentinel and Set constants, benchmark-gated memo deletion,
  constants versus module ivars for registries, settings as
  singleton ivars plus delegate, capture-free boot procs and the
  boot-in-raise-mode gate, share-a-copy and freeze-in-the-setter,
  main-or-local singletons with per-Ractor rebuilds, subsystem
  make_shareable! hooks, and boot-time loading hygiene. Audition
  was run on both sides of the 43 files the PRs touch.
- Fix knowledge base: third pass, the gem dialect. i18n PR 741
  (the first full gem conversion out of the Rails ractorization
  effort) read in full and distilled into three new patterns in
  docs/rails_core_best_practices.md: config class variables
  moving to singleton-class ivars behind delegators, the opt-in
  `<gem>/ractorize` entry point, and frozen caches degrading to
  recompute-per-call. Audition was run on both sides of the PR
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
- Dogfooding: this repository now runs Audition on itself, on
  every commit through lefthook (staged files, static) and on
  every push through a non-blocking CI self-audit with PR
  annotations and a job summary.
- Dynamic dependency attribution now matches the static
  scanner's exclusion rule: constants whose source lives in a
  vendored or dot directory under the target root (Bundler's
  deployment mode and Actions' bundler-cache put every gem in
  `vendor/bundle`) count as dependencies, not as the target's
  own code. Found by the very first CI self-audit, which
  attributed the vendored gems to Audition itself and flipped
  the verdict from blocked to not_ready.
- Report rendering split into one class per format
  (`Report::Text`, `Report::Json`, `Report::Github`); the
  `Report` class keeps only the data, verdict, and counts. The
  `Report#to_text/to_json/to_github` methods are gone, an API
  change for anyone driving Audition programmatically.

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
  every claim that touches Audition's behavior verified on Ruby
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
  un-shareable-Proc pattern Audition's own unsafe-calls check
  flags (and a pragma silenced), so the first dispatch from a
  worker Ractor raised. They are plain defs now, and the check
  is covered by an in-Ractor regression spec. Found while
  verifying rubydex 0.3.0, which Audition now runs on: findings
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
