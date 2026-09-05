# Rails core best practices for Ractor safety

A study of the Rails ractorization effort (led by Shopify, landing
on `main` for Rails 8.2). Commit SHAs below refer to rails/rails.

## Methodology

Compiled on 2026-07-19 from a local rails/rails checkout at
8.2.0.alpha (`main`, HEAD cba6112015). Commit selection:

- `git log -i --grep=ractor`: 153 commits mentioning ractor in
  the message.
- `git log -S Ractor`: 57 commits adding or removing a `Ractor`
  symbol in code (pickaxe).
- Union: 161 unique commits; 103 after dropping merge commits.

Each of the 103 commits was read (`git show --stat -p`) and
classified by the root problem it fixed and the technique it
applied; about a quarter turned out to be file-history noise
unrelated to Ractors (mostly `source_annotation_extractor.rb`
churn) and was discarded. Roughly 75 substantive fixes remain and
back the patterns below. The analysis was performed by Claude
(Fable 5) with four parallel readers over commit slices; treat
SHAs as verified, prose as interpretation.

The one-line summary: freeze everything you can at boot, delete
lazy state instead of guarding it, prefer plain Ruby over wrapping
things in Ractor APIs, and keep a small set of escape hatches for
state that is genuinely per-process.

## The playbook, in the order Rails applied it

1. Freeze all literal constants, mechanically. One repo-wide sweep
   (5700c17c) enabled RuboCop's `Style/MutableConstant` with
   `EnforcedStyle: literals` across every gem; intentional mutation
   got explicit cop disables.
2. Fix class-level state: frozen defaults plus copy-on-write
   writes. Never mutate a shared collection; rebuild and refreeze.
3. Deal with procs, in order of preference: delete the proc and
   write plain Ruby; else make it shareable at definition time;
   for user-supplied blocks, try to make them shareable behind an
   application policy knob.
4. Convert lazy memoization to eager computation before anything
   is frozen, or freeze the cache at memoization time.
5. Add `#freeze` overrides that warm remaining lazy state first,
   then deep-freeze internals, then `super`.
6. Provide one boot-time entry point that freezes the world:
   `Rails::Application#ractorize!`.
7. For the irreducible leftovers, use escape hatches: proxy work
   to the main Ractor, keep a per-Ractor cache, or hand a
   single-owner resource to a message-passing worker.

## Pattern catalog

### 1. Deep-freeze constants (the volume play)

The most common fix by count. Details that matter:

- Nested values need freezing too. `EMPTY = new([]).freeze` still
  holds a mutable array; the fix is `new([].freeze).freeze`
  (27dd0001).
- Build-then-freeze replaces mutate-in-a-loop construction:

  ```ruby
  # before
  HTTP_METHOD_LOOKUP = {}
  HTTP_METHODS.each { |m| HTTP_METHOD_LOOKUP[m] = ... }
  # after
  HTTP_METHOD_LOOKUP =
    HTTP_METHODS.each.with_object({}) { |m, h| h[m] = ... }.freeze
  ```

  (6566363c)
- Runtime-constructed long-lived objects count as constants:
  database cast types and PG text encoders are frozen at the
  moment they are cached (76448a01, d2da8167).
- String values inside hashes get interned with unary minus.

### 2. class_attribute: frozen defaults, copy-on-write writes

The single most repeated idiom across Action Pack, Active Model,
and Active Record (5753c994, f02544d1, f03a9d95, 8b9a5311,
a8aa395d, cef305ac, 70b9f908 and more):

```ruby
# before
class_attribute :_flash_types, default: []
self._flash_types += [type]
# after
class_attribute :_flash_types, default: [].freeze
self._flash_types = (_flash_types | [type]).freeze
```

Underneath, `class_attribute` itself was reimplemented to be
Ractor-safe (9d4f4fa6): the value moved out of a `define_method`
closure (unshareable) into a plain ivar read through an
`attr_reader`, with a `Ractor.shareable_proc` that only returns
the owning class. Ruby's rule that frozen ivars on shareable
objects are readable from any Ractor does the rest.

### 3. Procs: delete first, wrap second, policy-gate user input

Three tiers, and Rails' own history shows the preference order:

- Best: eliminate the proc. Commit 981c74ce is literally titled
  "Just write regular Ruby and avoid having to make procs
  sharable". A hash of level-check lambdas became an array of
  symbols plus `logger.public_send("#{level}?")` (a21c2203); a
  `Hash.new { "" }` default proc became a plain frozen hash with
  explicit keys (90c23347).
- Framework-owned proc constants get wrapped at definition:

  ```ruby
  TERMINATOR = ActiveSupport::Ractors.shareable_lambda do |m, c|
    c.call
    m.finished_processing?
  end
  ```

  (edc157ae, fb591f73, 48cd191f, 64083b49, 32d830b3, 5949b7fc)
- User-supplied blocks go through `try_shareable_proc` /
  `try_make_shareable` at write time (4d37d051, b1128e1d,
  321ba85c, 2a3c52c4), gated by
  `ActiveSupport::Ractors.unshareable_proc_action`: `nil` means
  leave the proc alone, `:raise` fails fast, `:warn` deprecation
  warns and keeps the unshareable original. Migration policy as
  configuration.

Corollary: never let a closure capture an unshareable `self`. The
MessageVerifiers block was rewritten to call `Rails.application`
instead of relying on the implicit receiver (f0b57bed), and
closure-capturing `define_method` in autosave associations was
replaced with `class_eval` string-generated methods that dispatch
to named methods (a698b118).

### 4. Eager compute: kill laziness before the freeze

Lazy `||=` on shared objects fails twice under Ractors: the write
races, and once the owner is frozen it raises FrozenError. Fixes:

- Move the computation to `initialize` (`local_cache_key`,
  c6127f88) or to the `inherited` hook so it runs at
  class-definition time on the main Ractor (`active_key`,
  f6be2037).
- Force evaluation at boot via `ActiveSupport.on_load`
  (`view_context_class`, 397b83cb).
- Or freeze the memoized value in place when laziness is fine but
  mutability is not (`action_methods` Set, 9e60f5e7;
  `controller_path`, 0facc5c8).

### 5. Custom #freeze overrides: warm, then freeze

Objects with lazy internals get a `freeze` that realizes them
first:

```ruby
def freeze
  return self if frozen?
  app                    # force the lazy memoization
  @app_build_lock = nil  # drop the now-useless mutex
  super
end
```

(Engine, 5a836db4). Inflections builds its lazy regexp pattern and
deep-freezes every rule list before `super` (d7119211);
InheritableOptions flattens its parent-chain `default_proc` into a
materialized hash and drops the closure entirely (26fed27f).

### 6. ractorize!: one explicit entry point

`Rails::Application#ractorize!` (4ffef4ba, e0933f45, plus
c6127f88) is the capstone: warn experimental, touch `env_config`,
`revision`, and `routes` so nothing lazy remains, nil out
autoloaders and reloaders (unshareable and unneeded once eager
loaded), then `Ractor.make_shareable(self)` and the same for
`Rails.event`, `Rails.error`, `Rails.backtrace_cleaner`.
Production-only by design: it requires eager loading.

### 7. Escape hatches for genuinely shared state

- Proxy-to-main-Ractor: `ActiveSupport::Ractors.on_main(obj) {}`
  (38ca8309, built on the ractor-dispatch gem). Used where a
  memoizing write must happen on shared class state: read the ivar
  as the fast path, hop to the main Ractor to perform the `||=`
  (`@predicate_builder`, 48cd08ad).
- Per-Ractor cache: CachingKeyGenerator's `freeze` moves its
  `Concurrent::Map` into Ractor-local storage; each Ractor lazily
  builds its own cache (2261fc86).
- Port-based worker for single-owner IO: the Ractor-shareable
  logger (443e55dc) proxies writes over a `Ractor::Port` to one
  consumer thread that owns the real log device; writes are
  fire-and-forget, flush and close are synchronous round trips.

### 8. API hygiene forced by ractorization

- Mutable public constants get deprecated, not fixed in place:
  `RENDERERS` became a `DeprecatedObjectProxy` over a private
  frozen set with a frozen `.all` reader (41799bd0, 7009e5a5).
- Registries move from class variables to a module ivar with
  copy-on-write registration (template handlers, cd416503).
- Global-variable defaults get removed outright: `safe_join`'s
  `sep = $,` became `sep = nil` as a breaking change (36bc3c9b).

### 9. Ractor-adjacent performance work

Once any Ractor has spawned, ivars on core-type subclasses go
through the VM's generic ivar table with global synchronization.
Rails removed hot-path uses: SafeBuffer inverted its flag so the
common case allocates no ivar at all (`@html_unsafe` only on the
rare path, db27b67b), and Uncountables stopped subclassing Array
(bfbd6233).

### 10. Migration infrastructure

- `ActiveSupport::Ractors` (5b20d232): internal `:nodoc:` shim
  module (`make_shareable`, `shareable?`, `shareable_proc`,
  `shareable_lambda`, `try_*`, `on_main`, `main?`); everything
  no-ops below Ruby 4.0. Deliberately moved out of `Kernel` so it
  can be deleted once old Rubies drop off. Unreleased as of Rails
  8.1; ships with 8.2.
- Test helpers: `assert_ractor_shareable` (is shareable now),
  `assert_ractor_make_shareable` (can be frozen into
  shareability), and `on_ractor { }` which runs a block on a fresh
  Ractor and returns the result (3864d6b3, db64346e, f68e6fbb).
- Not everything sticks: the JSON encoder ractorization was
  reverted wholesale after merging (261cec84). Freezing shared
  state can regress behavior; expect rollbacks.

## What this means for audition

Detection already aligned: mutable and shallow-frozen constants,
class-level ivar state on the graph, proc constants, global
variables, lazy requires. The de-memoization autofix mirrors
Rails' own "just write regular Ruby" preference, and
`store_if_absent` maps to the per-Ractor-cache escape hatch.

Ideas this study suggests:

- Flag `Hash.new { ... }` default procs; the closure makes the
  hash unshareable even when frozen, and Rails hit this twice.
- Flag closure-capturing `define_method` at class level; the
  `class_eval`-string rewrite is the established fix.
- Suggest copy-on-write rebuilds for in-place mutation of
  class-level collections (`<<`, `merge!`, `|=` on defaults).
- A Rails fix dialect: on targets with activesupport >= 8.2,
  emit `ActiveSupport::Ractors.*` spellings (version-shimmed)
  instead of raw `Ractor.*`.
- Recognize custom `#freeze` overrides that warm lazy state as a
  legitimate pattern rather than flagging the lazy ivar inside.

## Second pass: 61 more commits, to 2026-08-20

Refreshed on 2026-08-22 against rails/rails `main` at 2a2db1e8d6
with the same selection over `cba6112015..origin/main`: 52
commits by message, 48 by pickaxe, 61 unique without merges,
every one read in full (`git show --stat -p`) by four parallel
readers; claims that touch audition's own behavior were then
re-verified on Ruby 4.0.6. The volume sits in Active Record
model schema, Action View templates, Active Support
notifications and callbacks, and routing. Every pattern from the
first pass recurs; what follows is new, numbered on from the
catalog.

### 11. Delete the memo before relocating it

The strongest new signal. Three commits remove a lazy class
memo outright instead of making it Ractor-aware: a thread
attribute key string is recomputed per call, a measured 1.6x to
2x microbenchmark cost accepted (5777ec7432); a derived default
drops its `||=` and recomputes from already cached values
(9b6ec3b27e); an unbounded `Concurrent::Map` keyed by method
names is replaced by a precomputed frozen index, with a 1.6x to
2.7x slowdown on the uncached miss path documented in the
commit (1a59302e64). Most telling: 46ee9525dc deletes a memo
that 09783bcb7b had just wrapped in `on_main`, because an
existing frozen structure (`columns_hash` plus `Symbol#name`)
already answered the query. The order of preference is now:
delete the cache, then hoist or warm it, and only then plumb
it through Ractor APIs.

### 12. Memo hygiene for the class-level `||=`

- Configuration-free memos become frozen private constants:

  ```ruby
  # before
  def self.empty
    @empty ||= new(nil, nil).freeze
  end
  # after
  EMPTY = new(nil, nil).freeze
  private_constant :EMPTY
  def self.empty = EMPTY
  ```

  (6bfcbc3115; verified: the `||=` form raises on cold access
  from a worker even though the value would be frozen.)
- Warm at load through the hierarchy: a class-body call plus an
  `inherited` hook guarded by `subclass.name`, because anonymous
  `Class.new` has no name yet (8123c3ed21), or an `eager_load!`
  override that touches the memo before `super` (fd5ffed45b).
- Interpolation is never auto-frozen: `@path ||= "#{a}/#{b}"`
  needs an explicit `.freeze` even under the magic comment
  (18fdd2f2c5).
- A memo that can hold nil or false never sticks under `||=`, so
  boot warming cannot pin it and a frozen owner raises
  `FrozenError` on the next read; use `return @x if
  defined?(@x)` (3189782fb2).
- Assign before sharing. `@x ||= make_shareable(Obj.new)` loops
  forever when `Obj#freeze` calls back into the owner, as
  `ActiveModel::Name#freeze` does; write `return @x if @x; @x =
  Obj.new; make_shareable(@x)` (c4dcf552cf; verified:
  `SystemStackError` on Ruby 4.0.6 for the `||=` form).
- The double-checked escape hatch for open class sets, where no
  warmer can reach user-defined subclasses:

  ```ruby
  @x || ActiveSupport::Ractors.on_main(self) { @x ||= compute.freeze }
  ```

  (552d7d242f, 09783bcb7b, c64ab952dd, d3ac5cabaa). The read
  stays dispatch-free; the memoized value must itself be
  shareable; `try_make_shareable` replaces `.freeze` when user
  procs may be embedded.

### 13. Value objects freeze at the end of initialize

Not a `#freeze` override (pattern 5) but an unconditional
self-freeze as the last statement of `initialize`, with caller
strings and arrays dup-frozen on the way in (`SimpleType`,
622080e4e7; `Mime::Type`, 39034c8368; `AS::TimeZone` via
`make_shareable(self)` because it owns a tzinfo object,
26e78a20db; `Arel::Table`, 6f8650f9fc; the primary key objects
at their factory, 741334f12d). Objects that accepted
post-construction mutation gain an overridable template method
that runs before the freeze: `PredicateBuilder#initialize` calls
`register_handlers` and then `make_shareable(self)`, and the old
`register_handler` call site becomes a subclass override
(3ba8970f4a). Side effect to expect: tests that stub methods on
such instances must `dup` them first.

### 14. Non-literal constant values

`# frozen_string_literal: true` covers literals only. Two late
fixes were plain `.freeze` appends on a `String#tr` result
(e5c5920bb2) and a `Regexp.new` (5d1a5d9f0f); two more replace a
shallow `.freeze` at boot with `make_shareable` because users
push unfrozen strings into the list (d0743addea), and
deep-share a shallow-frozen constant after the class body has
populated its nested hashes (4c30e8c6cd). Verified on Ruby
4.0.6: `Regexp.new`, `Regexp.union`, `String#tr`, `+`, `*`, `%`,
`format`, `String.new`, and `Symbol#to_s` all return unfrozen,
unshareable objects, and reading such a constant from a Ractor
raises. This is now an audition check (see below).

### 15. define_method with a shareable lambda

Rails converged on keeping `define_method` and passing an
isolated lambda positionally rather than rewriting to
`class_eval` strings everywhere:

```ruby
%w( sec min hour day month year ).each do |method|
  name = method.to_sym
  reader = ActiveSupport::Ractors.shareable_lambda do
    @datetime.is_a?(Hash) ? @datetime[name] : @datetime.send(name)
  end
  define_method(method, reader)
end
```

(6af668321f). Rules that fell out of the series: captured locals
must be shareable (the String became a Symbol) and must be
assigned before the lambda is created, since `shareable_lambda`
refuses "outer variable may be reassigned" (c652246e15 moved a
`Class.new` block's capture after the assignment); user-supplied
procs go through `try_shareable_proc` and are passed positionally
(35950bd1e9); procs stored into any registry are converted on
insertion (57187b9d3a); `class_eval` strings remain the answer
when the captures are literals (463a0620c8, flash types). Two
subtler shapes: bind the lambda to a frozen receiver with
`Ractor.shareable_lambda(self: obj)` so it may keep reading
`@ivars`, converting once at the consumer instead of hoisting
ivars into locals at every definition (4b2edb1e79, which reverted
the hoisting version of 7edcc87b6a); and late binding through a
shareable anchor, where a closure that captured `self` captures
the enclosing Module instead and resolves the instance at call
time, so the proc is shareable now and the instance becomes
shareable later at its `finalize!` (0b1de97b43, url helpers).

### 16. Registries: freeze in the last boot hook

Configuration that plugins extend during boot is frozen in
`after_initialize`, not at definition, and deep
(`make_shareable`), not `.freeze` (cc70d62782, efd6072d58,
6afe70b811); inline freezing stays correct only where nothing
appends later (56d19e536b). Post-freeze writes are deprecated,
not broken: merge into a fresh frozen copy and warn
(73bdeced4f), with a two-phase variant where `eager_load!`
shallow-freezes to stop mutation and `ractorize!` deep-shares
later so boot-time registrants holding a Mutex keep working.
Copy-on-write breaks identity, so every holder of the old
reference needs repair: `DeprecatedObjectProxy#target=` and an
`on_change` hook for the aliased `default_formats` (39034c8368).
A copy-on-write proxy over a class-held collection must re-read
the current value on every call and intercept every mutator,
including `!` variants and `*_before`/`*_after` (dd67a577d9,
640e8c25c1, 63847f40f9). Libraries whose public constants must
stay mutable for compatibility ship an opt-in `ractorize` file
that the application's entry point requires (c0db4bb1eb,
`rack/ractorize`).

### 17. Per-Ractor state for shared objects

`ActiveSupport::Ractors.store_if_absent` joined the shim
(444c16102d) with a Mutex-guarded `Ractor.current[key] ||=`
fallback, and the mechanical rewrite is exactly what audition
emits (bf6b888a7b: `@cache = Concurrent::Map.new` to `def
self.cache = store_if_absent(:key) { Concurrent::Map.new }`,
`map[k] ||= v` to `compute_if_absent`). New shapes on top of it:
a Mutex constant becomes a Ractor-local mutex, justified only
because the state it guards is per-Ractor too (911b897b97); a
frozen object keeps mutable side state in a Ractor-local table
keyed by itself behind a `frozen?` branch, and its `freeze`
override nils the map and lock (285464aaca, 2afdfaf660, which
also raises from `freeze` when lazy state cannot be pre-warmed);
a per-class key derived from `object_id` is memoized on main in
`inherited` (de26f6e7c8). For singletons that can never be
frozen (a Mutex plus caches keyed by runtime input), Rails
introduced snapshot-and-rehydrate: the main Ractor records
`try_make_shareable(snapshot, copy: true)` after every mutation
and each worker builds its own instance from it under
`Ractor[:key] ||=`, formalized as a `to_ractor_snapshot` /
`load_ractor_snapshot` protocol gated by `respond_to?`
(a6b2abf05e, bd9ea455eb). The pitfall cd0f63ba4b fixed: a
shared copy drops Hash default procs and freezes nested lists,
so rehydrating writers must restore them. Bigger refactors land
first and ractorize later: `SchemaContext` consolidates a
model's interdependent lazy memos into one eagerly built object
swapped by pointer, with its Ractor tests skipped for now
(ae739c3854). Policy stays a dial: the test suite runs with
`unshareable_proc_action = :warn` and still-unshareable executor
callbacks deferred (1c03ccc2db), and the one correction in the
series replaced a hand-rolled `:raise`-only gate with plain
`try_make_shareable` (5eca1bc9a3): never reimplement the gate.

Not fixed, for the record: I18n keeps configuration in class
variables (stubbed in tests), `OpenSSL::Digest` builds its
per-algorithm methods from closures (upstream), and
`_returning_columns_for_insert` stays on `on_main` because it
needs a connection.

## What changed in audition after the second pass

- Pattern 14 became a mutable-constants finding with a safe
  `.freeze` autofix: String-only methods on any receiver,
  String methods on literals, `format`, `String.new`, and the
  `Regexp` factories. On Rails 8.1.3 it flags exactly the two
  sites Rails fixed in e5c5920bb2 and 5d1a5d9f0f plus
  `Regexp.union` constants in Active Support, Action Pack, mail,
  and liquid, with no false positives.
- The Rails macro rule is split. `cattr_*` and `mattr_*` stay
  errors and point at the migration Rails made itself
  (5d1a5d9f0f: `cattr_accessor` to `class_attribute`);
  `class_attribute` and `thread_mattr_accessor` downgrade to a
  warning carrying the frozen-default plus copy-on-write recipe,
  since Rails 8.2 made their readers Ractor-safe.
- The `define_method` advice leads with pattern 15.
- Class-level state advice absorbs patterns 11, 12, 16, and 17.

Declined, deliberately:

- A Rails dialect emitting `ActiveSupport::Ractors.*`. The module
  is `:nodoc:` and documented as disposable once old Rubies drop
  off; audition keeps emitting plain Ruby.
- An `on_main` autofix. It needs the ractor-dispatch gem and is
  the last rung of Rails' own ladder.
- Autofixes for deleting memos or hoisting them into constants.
  Both change evaluation order or cost and need a human reading
  the benchmark; the advice names the recipes instead.
- Changing the freeze-on-memoize emitter to the assign-then-share
  shape. Constructor memos are already left alone, which removes
  the re-entrancy hazard from the generated code; the hazard is
  documented above for hand-written fixes.

## Third pass: the gem dialect (i18n PR 741)

Studied 2026-09-04: ruby-i18n/i18n#741 "Ractor support" by the
engineer leading the Rails ractorization (open, head 58aa1dc).
The first full gem-side conversion out of that effort, and the
fix for the residual recorded at the end of the second pass
("I18n keeps configuration in class variables"). Method: the
diff and every review comment read in full, audition run on
both sides of the PR (static and dynamic), and every Ruby
semantics claim below re-verified on Ruby 4.0.6.

### 18. Config singletons: class variables to class-level ivars

The bulk of the PR converts `@@backend`-style config storage to
ivars on the singleton class, with one-line instance delegators
(`def backend; Config.backend; end`) preserving the public API.
The Ruby rules doing the work, verified on 4.0.6:

- Class-variable access from a non-main Ractor raises
  Ractor::IsolationError even for reads, and even when the value
  is shareable ("can not access class variables").
- Class-level ivars are readable from workers when the value is
  shareable, raise when it is not, and are never writable.

So the conversion alone buys nothing for a lazy `||=` reader:
the cold-path write still raises from a worker. It pays off only
combined with boot-time warming plus `make_shareable` of every
value, which is the next pattern.

### 19. The opt-in ractorize file

`require "i18n/ractorize"` is the gem-side capstone, mirroring
`Rails::Application#ractorize!` (pattern 6) and `rack/ractorize`
(pattern 16): eager_load, re-assign `available_locales` to
itself to materialize the backend-derived value, make_shareable
each config value, touch every reader so no memo stays cold,
drop the owner link, then make_shareable the config object.
Verified end to end on the PR head: store translations, require
the file, and `I18n.translate(:greet, name: "world")` inside a
Ractor returns the interpolated string, with missing keys going
through the shared exception handler.

Two compatibility moves ride along. The legacy mutable constant
becomes a frozen alias of the new state plus `deprecate_constant`
(`RESERVED_KEYS = @reserved_keys`), the plain-Ruby version of
pattern 8's DeprecatedObjectProxy. And per-Ractor caches get a
portability guard for pre-3.0 rubies: `if defined?(Ractor)` uses
`Ractor.current[key] ||=` (the shape audition emits) and the
else branch keeps the old class variable. Statically that
fallback scans as a class-variables error; dynamically the
branch never runs on 4.0, so the class variable is never even
created and the probe clears it. A pragma on the fallback line
is the honest encoding.

### 20. Frozen caches degrade to recompute

`Fallbacks#[]` becomes `super || (frozen? ? compute(locale) :
store(locale, compute(locale)))`: a cache that can no longer
store simply recomputes per call, the read-side answer to
pattern 11's delete-the-memo. The unset default is allocated
frozen on every read instead of memoized, and a custom `freeze`
deep-freezes `@map` and `@defaults` first (pattern 5). Two more
deletions in the same spirit: `eval(IO.read(f), binding)`
becomes `instance_eval` on a frozen, stateless context Object,
and the Simple backend's lazily vivifying `Concurrent::Hash`
default proc with a Mutex inside it becomes a plain
`Concurrent::Hash`, accepting a behavior change (unknown locale
reads return nil, not a vivified empty hash).

Mid-review color: the first version rebuilt the interpolation
pattern cache copy-on-write behind a Hash default proc, and the
author scrapped it himself ("This was wrong. We can't have
default procs in the hash."). The default-proc rule bites even
the people leading the Rails effort.

### What audition says about the PR (verified)

On pre-PR main (547917d), the static scan flags everything the
PR fixes: RESERVED_KEYS mutable Array plus in-place `<<`,
INTERPOLATION_PATTERNS_CACHE default proc, and some thirty
class-variable sites; the require probe adds six runtime errors.
On the PR head the class-variable errors are gone, runtime
errors drop to three, and the warmed state surfaces as info
notes ("shareable; warm on the main Ractor"). The static verdict
stays not_ready, though, and correctly so: every `@@var` became
a lazy `||=` class-ivar memo that is only safe after the opt-in
ractorize file runs, and no static scan can see a file the
application must choose to require.

Three residuals audition catches are real, two worth reporting
upstream:

- INTERPOLATION_PATTERN lost its `.freeze` in a rebase (the PR
  body claims it is frozen; the first review thread shows the
  freeze existed before the scrapped approach took it away).
  audition marks it fixable.
- `@@fallbacks` survives, and the reader's comment claims class
  variable reads are safe from workers. Reproduced: with the
  fallbacks backend loaded and ractorize applied,
  `I18n.fallbacks[:en]` from a worker raises IsolationError at
  the `Fiber[:i18n_fallbacks] || @@fallbacks` line. Reads raise,
  full stop; the second-pass claim is re-confirmed.
- Gettext's `@@plural_keys` and the Simple backend's MUTEX
  constant (still guarding main-only `store_translations`
  writes) remain, consistent with the PR's declared "most of
  what Rails needs" scope.

### What this means for audition (third pass)

- Four checks confirmed against a conversion written by the
  people who set the patterns: mutable-constants (including the
  Regexp.union freeze the PR lost), Hash-default-proc,
  class-variables, and the class-level-state error on lazy `||=`
  memos that survive a class-variable conversion.
- The adoption gap is now concrete: a gem following the blessed
  ractorize idiom still audits statically not_ready, because the
  safety lives in an opt-in file. Idea for later: detect a
  shipped `lib/<gem>/ractorize.rb` and say so in the report, or
  offer a probe mode that requires it first. A design question,
  not implemented.
- The `defined?(Ractor)` class-variable fallback branch is a
  legitimate pragma site; the dynamic probe already clears it.

## Fourth pass: what the label knew and the grep did not

Studied 2026-09-05. The first two passes selected commits by
`git log --grep=ractor` plus a `Ractor` pickaxe; the GitHub
label "Ractor Support" selects by intent. Scoring the 114
labeled PRs against the studied set found 28 merged PRs no pass
had read: 10 merged after the second pass cutoff and 18 inside
its window whose commit messages never say ractor and whose
diffs add no `Ractor` token, because a plain `.freeze`, a
deleted memo, or an eager require needs neither. All 45 commits
and every PR discussion were read in full, audition was run on
both sides of the 43 files they touch, and every Ruby claim
below was re-verified on Ruby 4.0.6. Numbered on from the
catalog.

### 21. Sentinels and Sets are constants too

The follow-up to the MutableConstant sweep (c10c3c5bf4) froze
what the cop cannot see: nine `NOT_GIVEN = Object.new`
sentinels, `%w(...).to_set` and `Set.new([...])` lookups, arrays
built by constant arithmetic (`(A + B + C).freeze`), an unfrozen
array nested in an already frozen hash, and a hash whose keys
are computed, rebuilt as one literal with `.encode!.freeze` keys
instead of two index writes after the fact. Verified: an
unfrozen `Object.new` in a constant raises from a worker and
`Object.new.freeze` is shareable, the same for a Set of frozen
strings; `BasicObject.new` has no `#freeze` at all, which is why
`PRIMARY_KEY_NOT_SET` became an `Object`. Two constants were
frozen by a bare `NAME.freeze` statement after the class body
had populated them (TYPE_NAMES, PRE_CONTENT_STRINGS); the second
stayed unshareable because a default proc survives the freeze,
until 5949b7fc52 (pattern 3). 57475 applied the same sweep to
Active Record: a `class_attribute` default frozen, the relation
delegate cache frozen once populated, and two `@x ||=
new.freeze` memos turned into frozen private constants, the
origin of the shape in pattern 12. Its review also records a
limit: a memo on `QueryAttribute` "can't be eagerly memoized"
and was reverted. All of this is now an audition check (see
below).

### 22. Deleting a memo is a benchmark decision

57642 set out to remove five class-level memos from Active
Record (`arel_table`, `attribute_method_patterns_cache`,
`attributes_builder`, `column_names`, `default_scope_override`)
and its review thread is the most honest record of the trade in
the series. benchmark-ips with `save!` and `compare!` against
main showed `column_names` 7.4x and `arel_table` about 6x slower
on the micro path, `respond_to?` 4.6x and `Post.new` 1.2x slower
on real ones. The outcome: `column_names` deleted (7x on a path
nothing hits hot); `symbol_column_to_string_name_hash` and
`finder_needs_type_condition?` restored; `arel_table` kept as
state but assigned eagerly in `included`, `inherited`,
`table_name=` and the schema reload, with `Arel::Table#name`
made lazy (`@name || @klass&.table_name`) so the object is cheap
to build before the table name is known, 1.1x instead of 6x;
`attribute_method_patterns_cache` assigned eagerly as a
`Concurrent::Map` in `included` and `inherited`. audition flags
that last one as class-level state on the post-PR file, and two
months later 1a59302e64 (pattern 11) deleted it for a frozen
index. A reviewer also had the justification comment on the
cache removed: a cache that earns its keep "justifies itself by
existing". The rule that fell out: measure with
save-and-compare, delete when the miss path is cold,
eager-assign when the object is cheap, and push the expensive
part behind a lazy reader on an immutable field.

### 23. Constants hold fixed values; everything else is an ivar

Three PRs converge on a rule for registries. A constant is for
a value fixed at definition. A value that changes after
definition, in a load hook (57751: `ENVELOPE_SERIALIZERS << X`
inside `on_load(:message_pack)`), through a registration API
(57826: `Mime::SET`, `LOOKUP`, `EXTENSION_LOOKUP`), or at
configuration time (57952: `parameter_parsers`), moves to a
module ivar behind a reader, reassigned copy-on-write where it
is frozen (`self.envelope_serializers = (envelope_serializers |
[X]).freeze`). Public constants that leaked a registry become
`DeprecatedObjectProxy` instances over the ivar, with new public
API for whatever only the constant could do (`Mime.extensions`).
The author measured the alternative: a lexically resolved
constant reads about 1.08x faster than a module ivar reader on
Ruby 4.0.5 (1.23x on 3.4) and the difference is invisible at
the request level; the review settled on ivars because
"registries or caches that get mutated" should not be
constants, while a registry mutated only during initialization
"could work better" as a constant later. Setters freeze what
they store (`parameter_parsers=` freezes the transformed hash)
and the default is assigned to the ivar directly to skip a
needless copy. User-supplied parser procs are left alone: they
are called, so only their author can decide whether they are
shareable.

### 24. Settings: class variables to singleton ivars plus delegate

The framework-side version of pattern 18 (i18n), now the
standard conversion for `mattr_accessor` and `cattr_accessor`
settings (58627, 58643): `singleton_class.attr_accessor(
*settings)` on the module, `delegate(*settings, to: TheModule)`
for the instance-level readers that helpers use,
`singleton_class.delegate` in the `included` block so
`Request.strict_accept_header` keeps working for including
classes, and the instance writers dropped, because an instance
writing its class's setting was always a bug
(`Request.new({}).ignore_accept_header = true` flipped the
global). The values still need sharing: the railtie merges user
config into the rescue tables, `Hash#merge` returns an unfrozen
hash (verified), and an `after_initialize` block makes them
shareable explicitly. audition confirms the conversion (all
twelve `mattr_accessor`/`cattr_accessor` errors vanish) and then
reports the seven new module ivars as class-level state, the
adoption gap the i18n pass recorded: the target shape of the
conversion still audits as an error until the boot-time sharing
is visible. Whether a class ivar whose every in-file assignment
is a shareable literal should be a warning instead is an open
policy question (below).

### 25. Capture-free boot procs, and the gate that finds them

Booting with `unshareable_proc_action = :raise` is now a
railties test (58659), and it caught a series of callbacks
registered during boot that captured an unshareable object:
`app` in initializer blocks, `reflection` in association
callbacks, and the `length` and `prefix` locals of
`has_secure_token`. The fix is one move: hoist the shareable
leaf into a local before the lambda (`name = reflection.name`,
`reloader = app.reloader`, `executor = app.executor`) and
capture that. Verified on 4.0.6: a lambda that captures an
unshareable object cannot be made shareable, one that captures
a hoisted Symbol can, a `Class` instance is always shareable (so
a reloader class can be captured), and a local reassigned after
the lambda is refused by `make_shareable` as well ("outer
variable 'x' may be reassigned"), which is why `prefix = ... if
prefix == true` became a fresh `token_prefix`. The one value
with no shareable leaf, the routes reloader, is stored on a
reachable object (`app.reloader.routes_reloader`) and re-read
inside the block through `self.class`, the late-binding anchor
of pattern 15. A sibling fix: `Array(options[:on])` captured by
the transaction callback condition lambdas needed `.freeze`
(58653), because `Array()` returns a fresh unfrozen array
(verified). None of this is visible statically; audition
reports nothing on either side of these files. The boot gate is
the detector.

### 26. Share a copy; freeze in the setter

Sharing the value that came out of user configuration froze the
configuration itself (56d19e536b, pattern 16), and a gem that
cleared `config.action_dispatch.default_headers` in an `on_load`
hook that runs twice crashed on the second run. The correction
(58656) is `make_shareable(value, copy: true)`: the response
class gets a frozen copy and the config object stays mutable,
its later writes ineffective rather than fatal (verified: the
original stays unfrozen, the copy is shareable). The controller
`default_url_options` went the other way (58483): the mattr
default became `{}.freeze`, because in-place mutation of a
class-level hash was never documented and produced
autoload-order surprises (a subclass body writing
`default_url_options[:lang]` changed every controller's
redirects once it loaded); the test suite migrated from
`default_url_options[:host] = x` to reassignment or to
overriding the method, the documented API. Freezing a
class-level config hash is presented as a bug fix, not a Ractor
concession.

### 27. Main-or-local singletons and per-Ractor rebuilds

`ActiveSupport.event_reporter` (58599) keeps the ivar on the
main Ractor and hands each worker an instance of its own:

```ruby
def self.event_reporter
  return @event_reporter if ActiveSupport::Ractors.main?
  Ractor[:__event_reporter] ||= ActiveSupport::EventReporter.new
end
```

with the accepted consequence that subscribers registered on
main are not seen by workers (the test asserts exactly that;
shape verified). The same PR moved a `Concurrent::Map` constant
(`PREFIXED_PARTIAL_NAMES`) behind a `store_if_absent` method,
pattern 17 applied to a constant; audition was silent on that
constant and now flags it, since `Concurrent::Map` defines no
`#freeze` at all. The larger rebuild is `SchemaContext` (58578,
the follow-up to ae739c3854): the context is frozen and made
shareable right after `load_schema!`, and the attribute state
(defaults, types, builder, column defaults), which serializes
lazily by design and cannot be frozen, moves into an
`Attributes` object built per Ractor under `store_if_absent`
keyed by the context's `object_id`. Pending attribute
modifications become copy-on-write (`[*@pending, mod]`) and
`try_make_shareable` at schema load so workers can replay them;
a `freeze` override loads the schema first (pattern 5); the two
memos that need a connection stay on the model class behind
`on_main` (pattern 12). The reviewer pushed for precomputed
frozen defaults instead, and the author called the per-Ractor
copy a stopgap on the way to "a mutable ractor safe data store"
(the ractor_safe gem). The immediate cost: a per-Ractor rebuild
reads configuration on a worker, so `time_zone_aware_types` and
`skip_time_zone_conversion_for_attributes` had to be frozen in
`after_initialize` (58642), with the PostgreSQL `<<` in a nested
load hook rewritten as `+=` then freeze. Every config a
worker-side build reads joins the shareable surface. Tests that
spawn Ractors now run under forked isolation to avoid a Ruby
crash.

### 28. Subsystems expose a make_shareable! hook

`ractorize!` grew two calls of one shape.
`ActionView::PathRegistry.make_shareable!` (58640) warms every
file-system resolver's templates, freezes the resolvers, then
makes the two registries shareable under their mutex; and the
controller configs are made shareable for
`AbstractController::Base` and every descendant (58647), with
freeze plus copy-on-write declined as complexity "that doesn't
bring anything at the moment" since controller configs should
not change after boot. Review notes worth keeping:
`make_shareable` freezes in place, so no `dup` or reassignment
is needed; a load hook is the wrong place for this, because it
runs at load rather than after boot; and the author expects the
code to disappear once global configuration becomes
Ractor-mutable. All of it is eager-load-only, because a
controller body can mutate the view path cache during autoload
(`append_view_paths`).

### 29. Boot-time loading hygiene

Three PRs fix things that loaded during the first request of an
eager-loaded app: `Request::Session` and `Utils` were autoloaded
(moved under `Http::` and `eager_autoload`, 57856, with the
discovery that `eager_load!` must be a class method on the
namespace or nothing cascades); `require "useragent"` sat inside
the request-time `allow_browser` method (57974) and moved into
the class-level macro, a boot-time scope that still loads the
gem only for apps using the feature, after a reviewer declined
the file top; and `Template::Sources::File` was an
`eager_autoload` no `eager_load!` chain reached (58062), fixed
by inlining the one-constant namespace. The template lookup
refactors (57780, 57783, 58279, 58280: raising and non-raising
`find`, a single-pass `rank_for` instead of filter, sort, and
bind-all, one lookup for the implicit render, and no
`Concurrent::Map` allocated per uncached call) are the
groundwork for 58390's per-Ractor template cache: shrink what
the hot path touches before moving it per Ractor. A style note
from 57859: `shareable_lambda { |x| ... }` in block form, not
`shareable_lambda(&->(x) { ... })`.

### What audition says about the 28 PRs (verified)

Static scan of both sides of the 43 files these PRs touch, with
the checks as they stood before this pass: 195 findings before,
182 after. Confirmed conversions: every `cattr_accessor` and
`mattr_accessor` error (12) is gone after the settings PRs; the
`@empty ||= new.freeze` memos clear (`WhereClause`, `Type`);
`JS_ESCAPE_MAP`'s rebuild and the metadata serializer constants
clear; the `Concurrent::Map` that 57642 assigned eagerly is
flagged, and was deleted later. What audition missed, and what
changed because of it:

- Nine `Object.new` sentinels, one `BasicObject.new`, three
  `Set` constants, and the `Concurrent::Map` constant were
  invisible on both sides. They are `mutable-constants` findings
  now: a bare `Object.new` with a safe `.freeze` autofix,
  withheld when the file gives the object singleton methods;
  `BasicObject.new` with an `Object.new.freeze` replacement;
  `Set.new([...])`, `Set[...]`, and `[...].to_set` as
  containers; `Concurrent::Map` beside the sync primitives.
  Rerun: 208 before, 180 after; all fourteen new findings sit on
  the pre-PR side and none survive. On current rails/rails the
  same rules find two sentinels, four Sets, and ten
  `Concurrent::Map` constants (adapter quoting caches,
  `ENCODED_BLANKS`) that no PR has touched.
- Two false positives went away: `TYPE_NAMES` and `TAG_TYPES`
  are built in the class body and frozen by a bare `NAME.freeze`
  statement at the same level. The check treats that as
  build-then-freeze and reports only provably mutable elements;
  a freeze inside a method does not count.
- The container autofix emits a plain `.freeze` when every
  element is provably shareable and keeps the deep
  `Ractor.make_shareable` wrap for the rest, which is what the
  sweeps actually wrote; `X = :a, :b` gains brackets.
- Advice text names the singleton-ivar-plus-delegate shape next
  to `class_attribute` for the class-variable macros, and the
  class-level macro as the boot-time scope for an optional
  dependency's require. Advice no longer cites Rails as the
  reason for a recipe and carries no commit ids; the reasons
  stay in this document.

Open, not implemented: the seven module ivars the settings PRs
create audit as class-level-state errors. A warning for a class
ivar whose every in-file assignment is a shareable literal would
close the adoption gap for this conversion; whether the severity
should drop is a policy call. Also left alone: the gvar and memo
rewriters still wrap literal containers in
`Ractor.make_shareable`, where the constants check now writes
`.freeze`.
