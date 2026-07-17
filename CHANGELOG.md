# Changelog

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
