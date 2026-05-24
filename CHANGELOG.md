# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Source-AST complexity (default).** Cyclomatic complexity is now measured from
  the source AST, where macro DSLs stay opaque — eliminating the massive CC
  inflation for Ecto queries / Phoenix `~H` templates (an Ecto `from/where` query
  dropped from CC 1023 to 1). Functions with no matching source `def` (templates,
  generated, `use`-injected) are excluded from gating and reported separately.
  `--complexity-source debug_info` restores the legacy macro-expanded counting.
- The visitor now also counts `receive`, `for` filters, and multi-clause `fn`,
  prunes `quote` blocks, and counts source-form guard operators.
- Umbrella support: `mix crap` runs from an umbrella root (analyzing every child
  app) — previously `Mix.Project.compile_path/0` raised "umbrellas have no app".
- `--no-coverage` complexity-only mode: score every function as 0% covered
  (worst-case CRAP) without running the test suite, for finding hotspots.

### Known limitations

- Source CC ignores branching introduced *inside* a macro you call (a lower bound
  for macro-heavy logic). `for`-comprehension-generated multi-clause functions with
  mixed clause complexity may still read high unless dispatch-dampened.

## [0.1.0] - 2026-05-24

Initial release.

### Added

- `mix crap` task computing the CRAP metric per function/clause from compiled
  `debug_info` and `:cover` clause-level coverage.
- Cyclomatic complexity via an Elixir-aware AST visitor (default) or an optional
  Credo-backed backend; guard complexity is counted.
- Quality gates: absolute threshold (`--min-score`), `--max-complexity`,
  `--changed-only <ref>` (gate only functions touched vs a git ref), and
  `--baseline` regression mode.
- Output formats: human table, JSON, and SARIF 2.1.0 (validated against the
  official schema) for GitHub code scanning.
- Dampening of macro-generated dispatch tables (`--dispatch-threshold`,
  `--dispatch-max-clause-cc`, `--no-dampen`) with a separate report section.
- `--on-no-coverage zero|skip` policy and diagnostics for unmeasured code.
- Zero runtime dependencies (uses Elixir's built-in `JSON`).

[0.1.0]: https://github.com/lukaszsamson/crap_ex/releases/tag/v0.1.0
