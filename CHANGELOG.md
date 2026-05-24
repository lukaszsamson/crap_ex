# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Umbrella support: `mix crap` runs from an umbrella root (analyzing every child
  app) — previously `Mix.Project.compile_path/0` raised "umbrellas have no app".
- `--no-coverage` complexity-only mode: score every function as 0% covered
  (worst-case CRAP) without running the test suite, for finding hotspots.

### Known limitations

- Complexity is read from the macro-expanded `debug_info` AST, so Phoenix `~H`
  templates and large Ecto queries report inflated CC (hundreds–thousands).
  Source-AST complexity is the planned fix.

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
