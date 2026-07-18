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
