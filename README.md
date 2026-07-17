# Audition

Point it at a Ruby script, a gem, a Rack app, or a Rails root and it
tells you whether that code can run inside Ractors, why it cannot,
and how to fix it. Unlike a linter, audition does not stop at
pattern-matching your source: it also loads the target in a
sandboxed subprocess and observes real `Ractor::IsolationError`s on
the live object graph.

[![GitHub Release](https://img.shields.io/github/v/release/yaroslav/audition)](https://github.com/yaroslav/audition/releases)
[![Docs](https://img.shields.io/badge/yard-docs-blue.svg)](https://rubydoc.info/gems/audition)

- **Three probes, one verdict.** Per-file Prism AST checks,
  whole-program semantic analysis on the
  [rubydex](https://github.com/Shopify/rubydex) graph (class-level
  state is resolved across files and reopenings), and dynamic
  in-Ractor execution of the actual target.
- **Explains, not just flags.** Every finding carries a `why`
  (which rule of the Ractor model it violates) and a `fix`
  (what to write instead).
- **`--fix` like RuboCop, in two tiers.** Safe corrections:
  `.freeze` on string constants, `Ractor.make_shareable(...)` for
  mutable and shallow-frozen containers and Proc constants, and
  boot-time hoisting of method-body requires. `--fix-unsafe` adds
  semantics-affecting rewrites: magic-comment insertion, class
  memoization to `Ractor.store_if_absent`, `autoload` to
  `require`, and write-once globals/class variables to frozen
  constants. `--dry-run` previews everything as a diff.
- **Dependency-aware.** Runtime findings are attributed to their
  source via `const_source_location`; when your own code is clean
  but a dependency is not, the verdict is a distinct `blocked`
  state, so `globalid` is not blamed for ActiveSupport's state.
- **Terminal-native output.** Colors, glyphs, and OSC 8 hyperlinks;
  `path:line` is clickable in supporting terminals. JSON output for
  CI.

```console
$ audition worker.rb
* audition 0.1.0 ruby 4.0.6 · script at .

  worker.rb
    x raises inside a Ractor: Ractor::IsolationError: can not
      access global variable $jobs from non-main Ractor
      why: The script ran fine on the main Ractor but failed under
      Ractor.new; the static findings usually pinpoint the line.
    x worker.rb:1  write to global variable $jobs
      why: Non-main Ractors cannot access global variables; this
      raises Ractor::IsolationError the moment the line executes
      in a Ractor (verified on Ruby 4.0).
      fix: Pass the value into the Ractor explicitly
      (Ractor.new(value) { |v| ... }) or over a Ractor::Port; for
      per-Ractor state use Ractor.current[:key].
    x worker.rb:4  read of global variable $jobs
      ...

  dynamic probes
    x script probe failed (details above)

  summary: 3 errors
  verdict: x not ractor-ready
$ echo $?
1
```

And the whole-bundle view:

```console
$ audition Gemfile.lock --static-only
╭───────────────┬─────────┬───────────┬────────┬──────────┬─────────╮
│ gem           │ version │ verdict   │ errors │ warnings │ fixable │
├───────────────┼─────────┼───────────┼────────┼──────────┼─────────┤
│ activesupport │ 8.1.0   │ not ready │    157 │       97 │      77 │
│ i18n          │ 1.14.7  │ not ready │     48 │       40 │      45 │
│ mail          │ 2.9.1   │ not ready │     27 │        4 │      13 │
│ rack          │ 3.2.6   │ not ready │     23 │       45 │      60 │
│ ...           │         │           │        │          │         │
╰───────────────┴─────────┴───────────┴────────┴──────────┴─────────╯
0 of 11 gems ractor-ready
```

**Requires Ruby 4.0 or newer**, strictly: the tool targets the modern
Ractor API (`Ractor::Port`, `Ractor#value`, main-Ractor `require`
proxying) and its verified semantics.

> [!WARNING]
> The entire codebase was written by Claude Fable 5 (Anthropic).
> It has a thorough spec suite and was validated against real
> gems, but no human has reviewed every line. Be wary; read before
> you trust, especially `--fix` rewrites.

## Table of contents

- [Installation](#installation)
- [Usage](#usage)
- [Adopting incrementally](#adopting-incrementally)
- [What it catches](#what-it-catches)
- [Field notes](#field-notes)
- [Extending](#extending)
- [Development](#development)
- [License](#license)

## Installation

```console
gem install audition
```

Or in a Gemfile:

```ruby
gem "audition", require: false
```

## Usage

```console
audition worker.rb            # a script: static + run inside Ractor
audition my_gem               # an installed gem, by name
audition path/to/gem-checkout # a gem working copy (*.gemspec)
audition path/to/rack-app     # a config.ru directory
audition path/to/rails-root   # a Rails application
audition lib                  # any directory, static-only
audition Gemfile.lock         # sweep every gem in the bundle
audition path/to/app --deps   # same, from the app root
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--deps` | sweep the target's Gemfile.lock gem by gem |
| `--write-baseline` / `--no-baseline` | record / ignore known findings |
| `--fix` | apply safe corrections, then re-check |
| `--fix-unsafe` | also apply semantics-affecting corrections |
| `--dry-run` | with a fix flag: preview edits, change nothing |
| `--format json` | machine-readable report for CI |
| `--format github` | GitHub Actions annotations on PR diffs |
| `--compare old.json` | delta vs a previous report: fixed/introduced |
| `--static-only` / `--dynamic-only` | pick one probe layer |
| `--fail-on warning` | stricter CI gate (default: error) |
| `--capabilities` | table of what this Ruby allows in Ractors |
| `--timeout 60` | dynamic probe budget in seconds |
| `--plain` | no colors or hyperlinks (also via NO_COLOR, pipes) |

Exit codes: `0` clean, `1` findings at or above the `--fail-on`
threshold (or a failed dynamic probe), `2` usage error.

## Adopting incrementally

Nobody goes from 150 findings to zero in one commit. Three tools
keep the gate useful from day one:

**Baseline.** Record today's findings, then fail CI only on new
ones:

```console
audition . --write-baseline    # writes .audition-baseline.json
audition .                     # exit 0; summary shows "N baselined"
```

The ledger stores per-check-per-file counts, so line drift never
invalidates it. `--no-baseline` shows everything again.

**Inline pragmas.** Silence a single line, rubocop-style:

```ruby
$legacy_flag = true # audition:disable global-variables
risky_call          # audition:disable
```

**Project config.** `.audition.yml` at the target root
(CLI flags always win):

```yaml
fail_on: warning
timeout: 60
exclude:
  - legacy/**
  - db/schema.rb
checks:
  disable:
    - at-exit
```

## What it catches

Static, with file:line precision:

- **Global variables**, with a verified allowlist: `$stdout`, `$~`,
  `$!`, `$VERBOSE` writes and friends stay legal.
- **Class variables**, resolved on the rubydex graph.
- **Class-level instance variables**, unified across the class
  body, `def self.`, and `class << self`, across files; the classic
  `@cache ||= {}` memoization.
- **Constants that are not deeply shareable**: bare mutable
  literals, interpolated strings, and the subtle shallow freeze
  (`[[1], [2]].freeze` still raises; audition explains why).
  Honors `# frozen_string_literal:` and
  `# shareable_constant_value:` magic comments.
- **Sync primitives and Procs in constants** (Mutex, Queue,
  lambdas).
- **Runtime require and autoload** (serializes all Ractors through
  the main-Ractor proxy).
- **`Ractor.new` blocks capturing outer locals** (the ArgumentError
  at creation time), resolved through Prism's exact scope depths.
- **Hostile or removed APIs**: `Ractor.yield`/`take` (gone in 4.0),
  ActiveSupport `class_attribute`/`cattr_*`/`mattr_*`,
  `include Singleton`, `fork`, `ObjectSpace._id2ref`, ENV mutation.

Dynamic, on the live object graph:

- Runs scripts inside a real Ractor (via `load`, which is not
  proxied) and reports the actual exception.
- Requires a library, then sweeps every constant it introduced with
  `Ractor.shareable?`, and inspects every class and module for
  class-level ivars and class variables, with
  `const_source_location` attribution.
- Boots `config.ru` and serves one GET / entirely inside a Ractor,
  the per-worker model of Ractor web servers; then hammers it from
  4 Ractors x 25 requests to surface failures that only appear
  under concurrency.
- Boots Rails (`config/environment.rb`), eager-loads, and sweeps
  the application's namespaces.

## Field notes

Findings from running audition on popular gems (July 2026,
Ruby 4.0.6):

- **rack 3.2**: `Rack::Builder.parse_file` cannot run inside a
  Ractor at all; `Rack::BUILDER_TOPLEVEL_BINDING` holds an
  unshareable Binding. audition's own rack probe rebuilds the app
  with `Rack::Builder.new` + `instance_eval` to get around it.
- **mail 2.9**: 28 hard findings, including `@@maximum_amount`,
  `@@autoloads`, and unfrozen table constants like `FIELDS_MAP`.
- **globalid 1.3**: only 6 findings of its own; the rest of its
  report is ActiveSupport state, attributed as dependency errors
  in the summary.

## Extending

Checks are written in a small declarative DSL and can be registered
from outside the gem:

```ruby
class NoSleep < Audition::Static::Checks::Base
  check_name "no-sleep"

  explain :sleepy,
          severity: :warning,
          message: "sleep inside potential Ractor code",
          why: "Blocking one Ractor blocks its whole OS thread.",
          fix: "Prefer Ractor::Port#receive with a timeout."

  on :call_node do |node|
    flag(node, :sleepy) if node.name == :sleep && !node.receiver
  end
end

Audition::Static::Checks.register(NoSleep)
```

`on` generates the Prism visitor and always continues traversal;
`explain` entries are a message catalog with `%{placeholders}`.

## Development

```console
bundle install
bundle exec rake spec       # RSpec suite
bundle exec rake standard   # standardrb lint
lefthook install            # pre-commit lint hook
bundle exec exe/audition --capabilities
```

Static scanning is Ractor-parallel on large targets (one worker
per core, minus one for the main Ractor); audition's own `lib/`
passes `audition lib` clean.

The design notes in `docs/design.md` include the empirically
verified Ruby 4.0 Ractor semantics table that the checks are
calibrated against.

## Assisted by

Claude Fable 5.

## License

MIT. See LICENSE.txt.
