# Changelog

## [0.2.0] - Unreleased

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
