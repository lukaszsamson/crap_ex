# crap_ex

[![Hex.pm](https://img.shields.io/hexpm/v/crap_ex.svg)](https://hex.pm/packages/crap_ex)
[![Docs](https://img.shields.io/badge/hexdocs-docs-purple.svg)](https://hexdocs.pm/crap_ex)
[![CI](https://github.com/lukaszsamson/crap_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/lukaszsamson/crap_ex/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/crap_ex.svg)](https://github.com/lukaszsamson/crap_ex/blob/main/LICENSE)

Compute the **CRAP** (Change Risk Anti-Patterns) metric per function for Elixir
codebases, and gate CI on it.

```
CRAP(f) = CC(f)² · (1 − coverage(f))³ + CC(f)
```

A high CRAP score means a hazardous combination of high cyclomatic complexity
and low test coverage — code that is risky to change. The original crap4j
project flags scores over **30** as unacceptable; that's the default threshold.

## How it works

`crap_ex` joins three sources, all BEAM-native:

1. **Discovery** — function/clause identity and per-clause ASTs are read from the
   compiled module's `debug_info` chunk (`:beam_lib.chunks/2`). The decoder is
   versioned and fails loudly if Elixir's internal debug-info schema changes.
2. **Complexity** — an Elixir-aware AST visitor computes classic cyclomatic
   complexity (a trivial clause = 1). An optional Credo-backed backend exists for
   teams that want parity with their Credo configuration.
3. **Coverage** — Erlang's `:cover` clause-level analysis
   (`:cover.analyse(mod, :coverage, :clause)`) gives covered/uncovered executable
   lines *per clause*, joined to discovery by the 1-based clause index.

## Usage

CRAP needs coverage, and `crap_ex` does **not** run your test suite for you
(driving `mix test` in-process would pollute `:cover`/ExUnit state). Two steps:

```sh
# 1. Produce coverage with Mix's native cover tool.
mix test --cover --export-coverage crap

# 2. Compute CRAP and gate.
mix crap --coverdata "cover/crap.coverdata" --min-score 30
```

### Common modes

```sh
# Gate only functions you changed (great for PRs / agents):
mix crap --coverdata "cover/*.coverdata" --changed-only origin/main

# Machine output for GitHub code scanning:
mix crap --coverdata "cover/*.coverdata" --format sarif --output crap.sarif

# Ratchet down legacy debt without blocking it:
mix crap --coverdata "cover/*.coverdata" --write-baseline .crap_baseline.json
mix crap --coverdata "cover/*.coverdata" --baseline .crap_baseline.json

# Complexity-only (no test run): find hotspots, scoring everything as 0% covered:
mix crap --no-coverage --min-score 30
```

Works in **umbrella** projects too — run it from the umbrella root (it analyzes
every child app) or from inside a single app.

### Running on itself, the Elixir stdlib, or any compiled beams

`crap_ex` analyzes compiled BEAM files (via `debug_info`) plus the source on disk,
so it can run on more than the current project:

```sh
# On crap_ex itself — it's a normal Mix project, so just run the task in its repo:
mix crap --no-coverage

# On any external set of compiled beams — point --beams at their ebin dir(s).
# Coverage usually won't be available, so pair it with --no-coverage.
# Example: the Elixir standard library (run from any project that has crap_ex):
mix crap --no-coverage --beams "$(elixir -e 'IO.puts(Path.expand(:code.lib_dir(:elixir)))')/ebin/*.beam"

# A release or any other ebin directory:
mix crap --no-coverage --beams "_build/prod/rel/myapp/lib/*/ebin/*.beam"
```

`--beams` bypasses project discovery and analyzes exactly the matched modules
(non-Elixir/`.erl` modules are skipped). Complexity is read from each module's
source file when it can be located on disk; functions whose source can't be found
(stripped sources, generated code) are reported but not gated. On the Elixir
stdlib this matches ~93% of clauses and surfaces genuinely complex internals like
`Kernel.Typespec.typespec/4` and `Code.Formatter.quoted_to_algebra/3`.

Exit codes: `0` pass, `1` gate failure, `2` usage/internal error. Run
`mix help crap` for the full option list.

## Honest deviations from canonical CRAP

These approximations are deliberate and reported in `--explain`:

- **Coverage is line-based, not path/branch coverage.** `:cover` counts
  executable-line hits per clause, not basis paths. The CRAP reported here is a
  *lower bound* on the true CRAP for branchy code.
- **Complexity is measured from the *source* AST** (default), so compile-time
  DSLs stay opaque and don't inflate CC: an Ecto `from/where` or a Phoenix `~H`
  template counts as ~1, not the hundreds of `case` nodes its macro expansion
  generates. Functions with no matching source `def` (templates, `defexception`,
  `use`-injected, other generated code) can't be measured from source and are
  **excluded from gating**, reported separately. `--complexity-source debug_info`
  restores the legacy (macro-expanded) counting. Caveat: source CC intentionally
  ignores branching introduced *inside* a macro you call, so it is a lower bound
  for macro-heavy logic.
- **Macros are not gated by default.** Macro bodies often run at compile time and
  can read as uncovered; gate them only with `--include-macros`.
- **Generated dispatch tables are dampened.** Macro-generated lookup tables (HTTP status
  maps, timezone tables, Gettext translation dispatch) accumulate huge additive CC from many
  uniformly-trivial clauses. crap_ex detects these (many clauses, each with CC ≤
  `--dispatch-max-clause-cc`, default 2) and scores them with a dampened complexity so they
  don't dominate — but lists them in a separate "generated dispatch" section so nothing is
  hidden. Disable with `--no-dampen`, or tune with `--dispatch-threshold` /
  `--dispatch-max-clause-cc`. A function with any genuinely complex clause is never dampened.

## Installation

Add `crap_ex` to your dev/test dependencies (it has no runtime dependencies and
is not needed at runtime):

```elixir
def deps do
  [
    {:crap_ex, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

Requires Elixir `~> 1.19` (uses the built-in `JSON` module and OTP `:cover`).
Docs are published at [hexdocs.pm/crap_ex](https://hexdocs.pm/crap_ex).

## License

Apache-2.0 — see [LICENSE](LICENSE).

See [`PLAN.md`](PLAN.md) for the full design, verification-gate matrix, and roadmap.
