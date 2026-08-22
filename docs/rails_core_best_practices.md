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
