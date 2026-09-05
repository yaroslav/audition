---
name: ractor-readiness
description: Use when asked whether Ruby code (a gem, script,
  Rack or Rails app, or all Gemfile.lock dependencies) can run
  inside Ractors, when making code Ractor-safe or
  Ractor-compatible on Ruby 4.0+, when adding a CI gate for
  Ractor readiness, or when errors mention
  Ractor::IsolationError, Ractor::UnsafeError, can not access
  global variables from non-main Ractor, ractor unsafe method
  called from not main ractor, non-shareable objects, or an
  un-shareable Proc.
license: MIT
---

# Checking and fixing Ractor readiness with audition

## Overview

audition (a Ruby gem) probes any target for Ractor readiness:
script, gem, directory, Rack app, Rails root, or a whole
Gemfile.lock. Static Prism and rubydex checks plus a dynamic
probe that loads the target inside a real Ractor; every finding
carries a why and a fix, and mechanical fixes are automated. Do
not hand-roll Ractor analysis or re-verify Ruby 4.0 Ractor
semantics; the tool encodes them, verified empirically. Written
against audition 0.2.x.

## Quick reference

| Goal | Command |
|---|---|
| Audit one target | `audition --plain <target>` |
| Fast iteration | add `--static-only` |
| Preview fixes | `--fix-unsafe --dry-run` |
| Apply fixes | `--fix` (safe), `--fix-unsafe` |
| Rank all dependencies | `audition <dir>/Gemfile.lock` |
| CI gate | `-f github` or `-f json`, `--fail-on warning` |
| CI, non-blocking | add `--exit-zero` (= `--fail-on never`) |
| Git hook | `audition --static-only --plain <staged .rb files>` |
| Incremental adoption | `--write-baseline`, `.audition.yml`, pragmas |

The tool runs on Ruby 4.0+ (targets may support older Rubies).
Install once with `gem install audition`. Run it OUTSIDE
`bundle exec` so the dynamic probe resolves the target's own
gems. Exit code is 1 when findings reach `--fail-on` (default:
error), 0 when the gate is clean.

## The protocol

Battle-tested on a dozen real gems (i18n, sinatra, mail,
tzinfo, addressable, jwt, liquid, faraday, money, and more).
Order matters:

1. Baseline the target's own test suite; record the results.
   Fixes need a writable, git-clean tree: never point `--fix`
   at an installed gem path; clone or copy the source first.
2. `audition --plain --static-only <target>` for the picture.
3. `--fix`, then `--fix-unsafe`. Preview with `--dry-run`;
   after applying, review `git diff` and revert hunks you
   disagree with instead of hand-writing everything. House
   styles (line length and such) belong to your own projects,
   not to targets you are fixing.
4. Before accepting fixes that contain Ractor APIs
   (`store_if_absent`, `Ractor.current`), check the target
   gemspec's `required_ruby_version`: those APIs need Ruby
   3.4+ or 4.0+. Plain-Ruby fixes (`.freeze`, frozen
   constants) have no version floor.
5. Re-run the target's suite. Full parity with the baseline,
   including pre-existing failures, is the bar.
6. Encode accepted residuals so re-runs gate cleanly:
   `# audition:disable <check>` pragmas on intentionally
   main-only lines (Rake loading, ENV mutation),
   `.audition.yml` `exclude:` for deliberately lazy trees
   (test mixins, optional integrations), `--write-baseline`
   for bulk adoption.
7. Full run (drop `--static-only`) for dynamic ground truth.

## Reading the report

| Verdict | Meaning |
|---|---|
| ready | clean; info notes do not taint it |
| risky | warnings only |
| blocked | own code clean, dependencies dirty; not this target's bug |
| not_ready | own errors |

"Frozen memoization; warm on the main Ractor" info notes mean:
call the memoizing methods once at boot, before spawning
Ractors; the end of the gem's main file or an on_load hook is
the natural place.

## Native extensions (C, Rust, and Zig)

audition cannot read native code, but it reports the one
fact that decides its Ractor behavior. Ractor::UnsafeError
("ractor unsafe method called from not main ractor") is not
an IsolationError: it means a compiled extension never
declared rb_ext_ractor_safe, so every method it defines
raises on first call from a non-main Ractor, whether the
extension is C, Rust, or Zig. The `native-extension` check
byte-scans every compiled file in the target (*.bundle on
macOS, *.so elsewhere) for that import and warns when it is
missing; an unbuilt checkout is scanned at the source level
(ext/**) instead. A declared extension gets an info note: the
declaration is the maintainer's assertion, not a proof, and
only real calls from a Ractor (script and Rack probes, or the
gem's own tests under Ractor.new) verify it.

The require and Rails probes extend it to dependencies: the
harness records every compiled file the load pulled in and
byte-scans those too, reporting silent ones as
`runtime-native-extension` warnings attributed to the
dependency. Three things still hide: extensions loaded
lazily on a code path the probe never runs, Ruby's own
archdir extensions (left to Ruby: ripper and coverage raise
from Ractors, encoding and digest plug-ins define no
methods), and whatever a Rack app loads (the Rack probe
exercises real calls instead, so an UnsafeError shows up as
a boot or call failure). For those, check the binary the
same way:

    nm -u ext.bundle | grep rb_ext_ractor_safe    # macOS
    nm -D -u ext.so | grep rb_ext_ractor_safe     # Linux

A match means the extension declares Ractor safety; silence
means its methods raise from Ractors. For silent extensions:
keep those calls on the main Ractor, try a newer release, or
ask upstream to audit the native code for process-global
state and declare rb_ext_ractor_safe(true) (from Rust:
rb_sys::rb_ext_ractor_safe(true)) first thing in Init_*.

## What the fixer refuses (human work)

Registries and accumulators (`@x ||= {}` then mutated),
constructor singletons (`@instance ||= new`), computed config
setters, settings DSLs (sinatra-style), sync primitives,
cross-file-mutated tables. These need a copy-on-write redesign;
the pattern study has worked recipes for it, including
the frozen private constant for configuration-free memos,
freezing value objects at the end of initialize, and the
snapshot-and-rehydrate protocol for lock-bearing singletons:
https://github.com/yaroslav/audition/blob/main/docs/rails_core_best_practices.md

## Common mistakes

- Pointing `--fix` at an installed gem path: fixes need a
  writable checkout.
- Auditing under `bundle exec` from another project: the
  dynamic probe fails on missing target gems.
- Treating `blocked` as the target's failure: it is a
  dependency finding; report it as such.
- Hand-porting fixes the fixer already generates: apply,
  review, revert selectively.
- Fixing without a suite baseline: pre-existing failures get
  blamed on the fixes.
- Leaving accepted findings as prose instead of encoding them
  with pragmas, config, or the baseline.
- Reading a `native-extension` info note as proof of safety:
  the byte scan says declared or silent, never safe; only real
  calls from a Ractor verify the declaration.
