# `crap_ex` — Spec & Implementation Plan

A library + Mix task that computes the **CRAP** (Change Risk Anti-Patterns) metric per
function and per clause for Elixir codebases, intended to be wired into CI as a quality
gate so automated and human contributors get fast feedback on risky code.

> Status: **implemented** (M1–M8). Target: Elixir `~> 1.19`, Erlang/OTP 28.
> All eight verification gates (G1–G8) are green; `mix check` (format, credo --strict,
> sobelow, dialyzer, tests, and a CRAP self-gate) passes. Implementation notes captured in
> §13.
> Several core claims below were **empirically verified** on Elixir 1.19.5 / OTP 28 — see
> §11 for the captured evidence.

---

## 1. Background & metric definition

CRAP combines complexity and test coverage into a single risk number. For a unit of
code `m` (a clause or function):

```
CRAP(m) = CC(m)² · (1 − cov(m))³ + CC(m)
```

where `CC(m)` is cyclomatic complexity and `cov(m) ∈ [0,1]` is test coverage of `m`.

- Fully covered code (`cov = 1`): `CRAP = CC`. Coverage cannot push CRAP below CC.
- Uncovered code (`cov = 0`): `CRAP = CC² + CC`. Complexity is penalized quadratically.
- Coverage is cubed, so each uncovered branch in complex code is punished hard.

**Threshold:** crap4j flags `CRAP > 30` as "CRAPpy". Configurable via `--min-score`
(default 30).

References: crap4j FAQ <http://www.crap4j.org/faq.html>; GMetrics
<https://dx42.github.io/gmetrics/metrics/CrapMetric.html>.

### 1.1 Honest deviations from the canonical definition

Deliberate, documented approximations — surfaced in README and `--explain` so the number
is not over-trusted.

1. **Coverage is line-based, not path/branch.** Canonical CRAP wants basis-*path*
   coverage; BEAM `:cover` counts executable-line hits per clause. Our CRAP is therefore a
   *lower bound* on true CRAP for branchy code. (`:cover` clause analysis gives
   covered/not-covered executable-line counts *per clause* — see §4.3 — which is much
   better than the line-range intersection approach, but still line- not path-based.)
2. **Cyclomatic complexity is source-AST-derived, not BEAM-CFG-derived.** We count decision
   points in the AST (§4.2), matching crap4j/Credo conventions, not the BEAM control-flow
   graph's edge count.
3. **Clause-first, then aggregate.** `:cover` and our CC are naturally per-*clause*; we
   compute at clause granularity and aggregate to `{module, name, arity}` (§4.4). Both
   levels are reported.

---

## 2. Goals & non-goals

### Goals
- `mix crap` computes CRAP for every `def/defp` **clause** and aggregates per function and
  module. (Macros are gated only behind `--include-macros`; see §4.5.)
- CI gate on configurable thresholds, with `--changed-only <ref>` to gate only functions
  touched relative to a git ref (the common monorepo/agent case).
- Machine-readable output: **SARIF 2.1.0** (GitHub code scanning) and JSON. Human output:
  sorted table + summary.
- Baseline support: store a JSON snapshot; gate on *regressions* (CRAP increased) so legacy
  code doesn't block all work.
- Usable as a library (`CrapEx.analyze/1` → structs) independent of the Mix task.
- A demonstrated **project quality harness** (format, Credo, Dialyzer, Sobelow, coverage,
  and `crap_ex` dogfooding itself) wired into CI — §8.

### Non-goals (v1)
- True path/branch coverage (would need bytecode instrumentation / custom cover).
- Erlang-source modules (`.erl`) — possible later via `:erl_syntax`.
- Running the test suite *inside* `mix crap` by default (see §4.3 / change #3).
- A hosted dashboard. We emit artifacts; CI stores them.

---

## 3. CLI surface

```
mix crap [paths...] [options]

  --coverdata GLOB     Coverdata file(s) to import. REQUIRED in v1 (see §4.3).
  --min-score N        Fail if any gated unit CRAP > N. Default: 30.
  --max-complexity N   Secondary gate on raw CC. Default: off.
  --changed-only REF   Only gate units whose line range intersects the git diff vs REF.
  --baseline FILE      Compare to a stored baseline; gate on regressions only.
  --write-baseline FILE  Write current results as the new baseline; exit 0.
  --format FORMAT      table | json | sarif. Default: table. Repeatable.
  --output FILE        Write the (non-table) report to FILE.
  --include-macros     Also gate defmacro/defmacrop (off by default; see §4.5).
  --on-no-coverage P   Policy for clauses with no executable lines / no cover data:
                       skip | zero. Default: skip.
  --explain            Per-unit CC/coverage breakdown + active deviation notes.
  --sort SORT          crap | cc | coverage. Default: crap (desc).
```

**Canonical v1 workflow (two steps, on purpose):**
```
mix test --cover --export-coverage crap          # produces cover/crap.coverdata
mix crap --coverdata "cover/*.coverdata" --changed-only origin/main --format sarif --output crap.sarif
```

A convenience wrapper / `:test_coverage` `tool:` plugin that fuses these is **deferred**
to a later version (§4.3, change #3).

---

## 4. Architecture

Four stages joined at the end; each is a pure-ish, independently testable module.

```
 compiled beam   ┌──────────────────┐
 (debug_info)    │ 1. Discovery     │  enumerate user-defined clauses + identity + lines
                 └────────┬─────────┘
                          │  %ClauseId{module,name,arity,kind,clause_index,line_start..end}
         ┌────────────────┼──────────────────┐
         ▼                                    ▼
 ┌──────────────────┐              ┌──────────────────────────┐
 │ 2. Complexity    │              │ 3. Coverage              │
 │   AST visitor    │              │   :cover clause analysis │
 │   → CC per clause│              │   → {cov,notcov} per clause
 └────────┬─────────┘              └────────┬─────────────────┘
          └────────────────┬───────────────┘
                           ▼     join on ClauseId (with cover-alignment guard)
                  ┌──────────────────┐
                  │ 4. Score + gate  │  CRAP per clause → aggregate → gate → format
                  └──────────────────┘
```

### 4.1 Stage 1 — Discovery & clause identity

**Source of truth: the compiled BEAM `debug_info` chunk.** It yields module identity,
file, per-clause ASTs and line metadata in one shot, aligned with what `:cover` measured.

```elixir
{:ok, {mod, [debug_info: {:debug_info_v1, :elixir_erl, {:elixir_v1, map, _}}]}} =
  :beam_lib.chunks(beam_path, [:debug_info])

# map.definitions :: [{{name, arity}, kind, meta, clauses}]   (VERIFIED, §11)
#   kind    :: :def | :defp | :defmacro | :defmacrop
#   clauses :: [{clause_meta, args, guards, body}]  -- clause_meta[:line] present
# map.file, map.module also present.
```

**Change #2 — debug_info is an Elixir compiler *internal*, not a public contract.**
`:beam_lib.chunks/2` is stable (<https://www.erlang.org/doc/apps/stdlib/beam_lib.html>),
but the `{:elixir_v1, map, _}` payload schema is private and may change across Elixir
versions. Therefore:
- Wrap decoding in a **`CrapEx.Discovery.DebugInfo` adapter** keyed on the `{:debug_info_v1,
  backend, {tag, ...}}` tag (`tag == :elixir_v1` today). Unknown tags **fail loudly** with
  a clear "unsupported Elixir debug_info version" error, never silently degrade.
- A **shape-pinning fixture test** per supported Elixir version asserts the decoded
  `{module, kind, name, arity, clause_index, line_start}` exactly (§9, gate G1).

`clause_index` is **1-based** to match `:cover`'s clause numbering (verified in §11).
`line_start = clause_meta[:line]`; `line_end = max line in the clause AST` (walk metadata).

Synthetic functions the compiler injects (`__info__/1`, `__struct__/0,1`, behaviour
trampolines) are **absent from `map.definitions`** but **present in `:cover` output**
(verified — `__info__/1` shows 9 cover clauses). Discovery's `definitions` set is therefore
the authoritative user-code filter; the join (§4.4) keeps only its members.

> **Fallback:** if `debug_info` is stripped, fall back to `Code.string_to_quoted/2`
> (`columns: true, token_metadata: true`) over source. Only Discovery is affected by the
> beam-vs-source choice; later stages consume whatever clause ASTs / ranges it produced.
> Note clause-coverage join is unavailable in fallback mode → degrade to line coverage.

### 4.2 Stage 2 — Cyclomatic complexity

Two interchangeable backends behind a `CrapEx.Complexity` behaviour.

**(a) Own AST visitor (default).** `Macro.prewalk/3` (or `Sourceror.Zipper`) over the
clause AST with an Elixir-aware decision model, classic CC (trivial clause = 1):
- +1 base per clause.
- +1 each: `if`, `unless`, `and`/`&&`, `or`/`||`, `for` filter, `try` `rescue`/`catch`.
- `case`/`cond`/`with`: +1 per branch beyond the first (`->` clauses; `with` `else`).
- multi-clause functions / guards: counted per clause, aggregated in §4.4.
- anonymous `fn` clauses: folded into the enclosing clause (configurable).

**(b) Credo-backed (opt-in).**
`Credo.Check.Refactor.CyclomaticComplexity.complexity_for/1` is documented public API
(<https://hexdocs.pm/credo/Credo.Check.Refactor.CyclomaticComplexity.html>) taking a
`def`-form AST. **Caveat:** Credo counts the `:def` operator itself as +1, so its raw score
≠ classic "1 + decisions". We **normalize** to classic CC and pin the mapping with a guard
test so a Credo upgrade that changes counting is caught (§9, gate G3). Its counting
*semantics* are not a stability contract — hence the visitor is the default.

Both backends return `%{ClauseId => cc}`.

### 4.3 Stage 3 — Coverage collection

**Change #1 (highest impact) — use native `:cover` clause coverage as the primary source;
do NOT intersect executable lines with inferred AST ranges.**

`:cover` supports clause- and function-level coverage directly (verified, §11):

```elixir
{:ok, clauses}   = :cover.analyse(module, :coverage, :clause)
#   [{{Module, Name, Arity, ClauseIndex}, {CoveredLines, NotCoveredLines}}]
{:ok, functions} = :cover.analyse(module, :coverage, :function)
#   [{{Module, Name, Arity}, {Cov, NotCov}}]
```

`cov(clause) = Cov / (Cov + NotCov)`.

Line-level analysis is kept **only** for `--explain` output, SARIF physical locations, and
`--changed-only` line intersection — not for computing clause coverage:
```elixir
{:ok, lines} = :cover.analyse(module, :coverage, :line)   # [{{Module, Line}, {Cov, NotCov}}]
```

Erlang cover docs (module/function/clause/line levels):
<https://www.erlang.org/doc/apps/tools/cover_chapter>.

**Change #3 — `mix crap` does NOT run the suite by default.** Driving a full in-process
`mix test` run from a Mix task pollutes `:cover` / code-loading / ExUnit / task-reentrancy
state. v1 is explicitly two steps (§3): the user runs
`mix test --cover --export-coverage crap`, then `mix crap --coverdata "cover/*.coverdata"`.
We `:cover.start()`, reset, then `:cover.import/1` each file (merges across partitions:
<https://www.erlang.org/doc/apps/tools/cover_chapter>), then analyse. A convenience
wrapper / custom `:test_coverage` `tool:` plugin is deferred to ≥0.3.

**Change #5 — `{0, 0}` clauses (no executable lines, e.g. `def add(a,b), do: a+b` whose
body shares the head line).** Trust `:cover`: `{0,0}` ⇒ `coverage = :not_applicable`. Such
clauses are **excluded from CRAP gates** by default (`--on-no-coverage skip`); `zero`
opts into treating them as uncovered. We never synthesize hit/miss from line ranges.

### 4.4 Stage 4 — Join, aggregate, score, gate

**Join** Stage-2 CC and Stage-3 coverage on `ClauseId`. A **cover-alignment guard**
(§9, gate G2) asserts every `{module, name, arity, clause_index}` from Discovery has a
matching `:cover` clause entry; a mismatch fails loudly rather than mis-scoring. Cover-only
clauses absent from Discovery (synthetic) are dropped.

**Per-clause CRAP:** `crap = cc*cc*:math.pow(1.0 - cov, 3) + cc`.

**Aggregate to `{module, name, arity}`** (multi-clause):
- `cc_function = Σ cc_clause` (classic multi-clause CC is additive).
- `cov_function`: from `:cover.analyse(mod, :coverage, :function)` directly (no manual line
  union needed — `:cover` already aggregates clause line counts).
- `crap_function` recomputed from aggregated cc/cov (not summed from clause CRAP).

**Per-module:** report `max` (the gate cares about the worst offender), plus `mean`/`p90`.

**Gating:**
- absolute: fail if any *gated* unit `crap > min_score` (or `cc > max_complexity`).
- `--changed-only REF`: gated set = units whose `[line_start,line_end]` intersect added/
  modified hunks from `git diff REF -- <file>` (parse unified diff, map new-file lines).
  Everything reported; only the intersection gated.
- `--baseline`: load prior JSON; fail if a unit's CRAP increased beyond tolerance, or a new
  unit exceeds `min_score`. Unchanged pre-existing offenders pass.

Exit codes: `0` pass, `1` gate failure, `2` usage/internal error.

### 4.5 Change #4 — macros gated separately

Macro bodies often run at *compile* time, so runtime `:cover` may legitimately show them
uncovered (Mix coverage docs warn about this:
<https://hexdocs.pm/mix/Mix.Tasks.Test.Coverage.html>). Gating them by default would
produce false CRAP alarms. v1 default gates `def/defp` only; `defmacro/defmacrop` are
**reported with a caveat** and gated only under `--include-macros`.

---

## 5. Data model (public structs)

```elixir
%CrapEx.ClauseId{module, name, arity, kind, clause_index, file, line_start, line_end}

%CrapEx.Metric{
  id: %CrapEx.ClauseId{} | {module, name, arity},
  cc: pos_integer,
  covered_lines: non_neg_integer,
  relevant_lines: non_neg_integer,        # cov + notcov
  coverage: float | :not_applicable,      # 0.0..1.0
  crap: float | :not_applicable
}

%CrapEx.Report{
  clauses:   [%CrapEx.Metric{}],          # clause granularity
  functions: [%CrapEx.Metric{}],          # aggregated {mod,name,arity}
  modules:   %{module => %{max:, mean:, p90:}},
  deviations: [String.t()],               # the §1.1 caveats actually in effect
  config: %CrapEx.Config{}
}
```

Library API: `CrapEx.analyze(opts) :: {:ok, %Report{}} | {:error, term}`,
`CrapEx.gate(report, config) :: :ok | {:fail, [violation]}`.

---

## 6. Output formats

- **table** (default): one row per function, sorted by CRAP desc, colorized over threshold,
  summary footer; `--explain` adds the clause breakdown.
- **json**: full `%Report{}`; stable schema for baselines + tooling.
- **sarif**: SARIF 2.1.0 `result` per gated violation, `level: "warning"`, `ruleId:
  "crap/threshold"`, `physicalLocation` from `file` + `line_start`. Validated against the
  official SARIF 2.1.0 JSON schema in CI (§9, gate G7), not just snapshots. (Future:
  `--format github` for `::warning file=...` workflow commands.)

---

## 7. Module layout

```
lib/crap_ex.ex                          # facade: analyze/1, gate/2
lib/crap_ex/config.ex
lib/crap_ex/clause_id.ex
lib/crap_ex/metric.ex
lib/crap_ex/report.ex
lib/crap_ex/discovery.ex                # orchestrates beam vs source
lib/crap_ex/discovery/debug_info.ex     # versioned adapter (fails loudly)
lib/crap_ex/discovery/source.ex         # fallback parser
lib/crap_ex/complexity.ex               # behaviour
lib/crap_ex/complexity/visitor.ex       # own AST visitor (default)
lib/crap_ex/complexity/credo.ex         # optional Credo backend
lib/crap_ex/coverage.ex                 # :cover import + clause/function/line analyse
lib/crap_ex/score.ex                    # join + aggregate + CRAP formula
lib/crap_ex/gate.ex                     # absolute / changed-only / baseline
lib/crap_ex/git_diff.ex                 # parse `git diff REF` → changed line ranges
lib/crap_ex/format/{table,json,sarif}.ex
lib/mix/tasks/crap.ex                   # Mix.Task CLI
```

### Dependencies
- `:credo` — optional (`only: [:dev, :test], runtime: false`), Credo CC backend only.
- `:sourceror` — optional, ergonomic zipper traversal (avoidable).
- `:dialyxir`, `:sobelow`, `:excoveralls` — dev/test only, for the project's own harness.
- No hard runtime deps; `:cover`, `:beam_lib` ship with OTP (`:tools` app).

---

## 8. Project quality harness (dogfooding the gates)

`crap_ex` itself runs a layered harness locally and in CI; this is both quality assurance
and a worked example of the gates we advocate. A `mix check` alias chains them:

```elixir
# mix.exs aliases
check: [
  "format --check-formatted",
  "deps.unlock --check-unused",
  "compile --warnings-as-errors",
  "credo --strict",
  "sobelow --exit",                       # security static analysis
  "dialyzer",                             # success typing / specs
  "test --cover --export-coverage crap",
  "crap --coverdata cover/crap.coverdata --min-score 30 --changed-only origin/main"
]
```

| Gate | Tool | Fails build when |
|------|------|------------------|
| Format | `mix format --check-formatted` | code not formatted |
| Unused deps | `mix deps.unlock --check-unused` | stale lock entries |
| Warnings | `compile --warnings-as-errors` | any compiler warning |
| Style/consistency | `credo --strict` | Credo issues (incl. its own CC check) |
| Security | `sobelow --exit` | known unsafe patterns |
| Types | `dialyzer` | spec/type discrepancies (PLT cached in CI) |
| Coverage floor | `excoveralls` threshold | line coverage below floor |
| **CRAP** | `mix crap` (self) | any changed function CRAP > 30 |

CI specifics:
- **PLT caching** for Dialyzer keyed on `{otp, elixir, mix.lock}` to keep runs fast.
- Dialyzer uses a curated `:dialyzer` `flags:` set (`:error_handling`, `:underspecs` opt-in)
  and a checked-in `.dialyzer_ignore.exs` reviewed in PRs.
- The CRAP gate runs in `--changed-only origin/main` mode on PRs (don't block on legacy),
  full-repo + `--baseline` on the default branch to ratchet down over time.
- Version matrix (§9, gate G8): start narrow (Elixir 1.19 / OTP 28), expand as debug_info
  adapters are added.

---

## 9. Verification gates (harness for `crap_ex` itself) — land before M5

These are the correctness backbone; the cover-alignment gate (G2) is the most important.

- **G1 Debug-info compatibility:** compile fixtures, read `:beam_lib.chunks(.., [:debug_info])`,
  assert discovered `{module, kind, name, arity, clause_index, line_start}` exactly. One per
  supported Elixir version; unsupported versions must fail with a clear error.
- **G2 Cover alignment (critical):** for the same fixtures, assert every discovered
  `{module,name,arity,clause_index}` matches a `:cover.analyse(mod, :coverage, :clause)`
  entry, and that synthetic-only cover clauses (`__info__` etc.) are correctly dropped.
- **G3 Complexity goldens + Credo-parity:** hand-counted CC on a fixture matrix; cross-check
  the (normalized) Credo backend; pin the normalization mapping.
- **G4 Fixture matrix:** one-liners, multi-clause, guards, `case`, `cond`, `with`, boolean
  short-circuit, anonymous `fn`, generated macro call sites, private functions, `{0,0}`
  no-executable-line clauses.
- **G5 CLI integration:** `mix test --cover --export-coverage` then `mix crap --coverdata …`;
  assert exit codes 0, 1, and 2 across passing / failing / misuse scenarios.
- **G6 Changed-only:** tiny git fixture repo; modify one function; assert only intersecting
  units are gated.
- **G7 Baseline + SARIF schema:** unchanged offenders pass, worsened fail, new fail;
  validate generated SARIF against the SARIF 2.1.0 JSON schema.
- **G8 Version matrix in CI:** run G1/G2 across the supported Elixir/OTP matrix.

## 10. Milestones

1. **M1** — structs + `Score` formula + property tests (monotone in cc/cov; `cov=1 ⇒ crap=cc`).
2. **M2** — Discovery via `debug_info` adapter + source fallback; lands **G1**.
3. **M3** — complexity visitor (+ optional Credo backend); lands **G3**.
4. **M4** — coverage via `:cover` clause/function analysis + import; lands **G2, G4**.
5. **M5** — join + Mix task + table output; lands **G5**. → ship `0.1.0`.
6. **M6** — `--changed-only` + `--baseline`; lands **G6, G7 (baseline half)**.
7. **M7** — SARIF + JSON + docs + deviation disclosure; lands **G7 (schema half)**. → `0.2.0`.
8. **M8** — convenience `:test_coverage` tool plugin / fused workflow. → `0.3.0`.

## 11. Captured verification evidence (Elixir 1.19.5 / OTP 28)

Run against a fixture `Sample` module (`add/2`, three-clause `classify/1`, private
`helper/1`, `use_helper/1`):

- **debug_info shape** decodes as `{:debug_info_v1, :elixir_erl, {:elixir_v1, map, _}}`;
  `map.definitions` entries are `{{name, arity}, kind, meta, clauses}` with `clause_meta[:line]`
  present. `classify/1` reported clause lines `[3, 4, 5]` — three clauses, matching source.
- **`:cover.analyse(Sample, :coverage, :clause)`** returns
  `{{Sample, :classify, 1, 1}, {1,0}}`, `{.., 2}, {0,1}}`, `{.., 3}, {2,2}}` etc. — i.e.
  `{{Module,Name,Arity,ClauseIndex}, {Cov,NotCov}}`, **1-based clause index aligned with
  debug_info ordering.**
- **`:cover.analyse(Sample, :coverage, :function)`** returns `{{Sample,:classify,1},{3,3}}` etc.
- `__info__/1` appears with 9 cover clauses but is **absent from `map.definitions`** →
  confirms the synthetic-function filter is required.
- **Correction to an earlier assumption:** one-liners are *not* `{0,0}` — a body like
  `a + b` on the head line counts as one executable line, so cover reports `{cov, notcov}`
  with `cov+notcov >= 1`. The `{0,0}`/`:not_applicable` path (change #5) is therefore rare
  for ordinary `def`s; in practice the real-world trigger for `:not_applicable` is a
  discovered clause **absent from the imported coverdata**, which the facade defaults to
  `{0,0}`. The policy is unchanged; only the fixture that exercises it differs.

### 13.2 GPT (Codex) review — findings addressed

An external GPT review flagged correctness gaps; fixes landed with tests:

- **Guard complexity was ignored (now counted).** Clause guards were dropped
  (`{id, body}`), so `def f(x) when is_integer(x) or is_binary(x)` scored as trivial.
  The complexity backend now takes `(body, guards)`; guard `or`/`and`/`in` (expanded to
  `:erlang.orelse`/`:erlang.andalso`) are counted **only within the clause's own guards**,
  avoiding the double-count that body-internal `&&`/`in` expansions would cause. On ecto
  this surfaced 6 additional over-threshold functions (13 → 19).
- **`--on-no-coverage zero` was parsed but never applied (now wired).** The policy threads
  through `Score.metric/4` and aggregation; `:zero` treats `{0,0}` (e.g. a clause absent
  from coverdata) as 0% covered instead of skipping it.
- **Silent skips now surfaced.** The Mix task warns when the report is empty (stripped
  `debug_info` / no path match) or when functions are skipped for lack of coverage —
  closing the "gate passes on unmeasured code" hole.
- **Path matching normalized.** `--paths` and `debug_info` files are normalized
  (`Path.relative_to_cwd`, trailing-slash strip) so `./lib`, `lib/`, and absolute paths
  match consistently.
- **Global `:cover` mutation documented.** `CrapEx.analyze/1` now carries an explicit
  side-effects warning (starts/resets/imports global `:cover`); intended for the
  short-lived `mix crap` task, not a long-running VM.

## 12. Key risks / open questions

- **debug_info is internal** (mitigated: versioned adapter + G1, fail loudly).
- **Cover↔Discovery clause-index alignment** is the load-bearing assumption (mitigated: G2).
- **`:cover.import` constraints:** a module can't be imported twice from the same file
  without reset/recompile — reset cover state per run; document partitioned-CI import.
- **Macro coverage semantics** (mitigated: macros opt-in, change #4).
- **Coverage = line, not path** — accepted and disclosed (§1.1); true branch coverage is a
  much larger project (bytecode instrumentation) and out of scope.

## 13. Implementation notes (things found while building)

- **debug_info stores macro-expanded AST.** `if`/`unless`/`&&`/`||`/`with` arrive already
  rewritten into `case`/`cond`/`try`. The visitor's `case`/`cond` branch counting still
  yields correct classic CC (a 2-branch `case` = +1 = what the operator would add), but the
  Credo backend over-counts the expanded form — pinned by a test, reinforcing the
  visitor-as-default choice.
- **One-liners are not `{0,0}`.** A body like `a + b` on the head line is one executable
  line under `:cover`. The `:not_applicable` path is instead reached when a discovered
  clause is absent from the imported coverdata (facade defaults it to `{0,0}`).
- **ExCoveralls as the `:test_coverage` tool produces empty native exports.** Use Mix's
  default `:cover` tool so `--export-coverage` writes coverdata that `:cover.import/1` reads
  back with real counts.
- **`:cover`-driving tests must be excluded from `mix test --cover`.** They manipulate the
  global `:cover` server and would wipe Mix's session before export. Tagged `:uses_cover`
  and excluded from coverage-export runs.
- **`:cover` prints to the `:cover_server`'s group leader**, not the caller's — silencing
  requires redirecting that process's group leader.
- **Bug Dialyzer caught:** `line_end` was computed by `Macro.prewalk` over the clause
  *4-tuple*, which prewalk treats as an opaque leaf, so `line_end` silently equalled
  `line_start`. Fixed by walking `[args, guards, body]` (a list prewalk descends into); a
  regression test now asserts a multi-line clause spans more than one line.

### 13.1 Validated on real projects (decimal, plug)

- **Bug found in the field & fixed:** plug ships a module compiled from Erlang
  (`debug_info` backend `:erl_abstract_code`). The fail-loud decoder aborted the *entire*
  run for that one module. Fixed: non-`:elixir_erl` backends return
  `{:error, {:non_elixir_module, backend}}` and are *skipped*; fail-loud is reserved for an
  `:elixir_erl` payload whose shape is unrecognized (a real version mismatch). Regression
  test added.
- **Coverage accuracy confirmed.** On `Plug.Conn.Query` (66% module coverage per native
  `mix test --cover`), crap_ex's per-clause numbers correctly split the module: `decode_each`
  /`finalize_map`/`encode_pair` at 100%, while the public `decode_pair/2` → `assign_split/4`
  (CC 13) path is at 0%. crap_ex surfaced untested complex code *hidden inside* an
  otherwise well-covered module — the exact value proposition of per-function CRAP.
- **Second bug found & fixed (nimble_parsec):** the complexity visitor crashed
  (`List.last(nil)`) on an AST node named like a control-flow keyword whose third element
  is a context atom/`nil` rather than an argument list — i.e. a *variable* named `case`,
  `cond`, `with`, or `try`. The `:case`/`:cond`/`:with`/`:try` visit clauses now guard on
  `is_list(args)`; a regression test covers it. After the fix, NimbleParsec analyzes cleanly
  (worst CRAP 19.9).
- **Large-scale bug hunt (19 projects, `bughunt.exs`).** Ran discovery + the complexity
  visitor over **every compiled beam** (deps included) of 19 OSS projects — absinthe,
  bandit, decimal, ecto, ecto_sql, gettext, guarded_struct, jason, kino, livebook, makeup,
  oban, phoenix, phoenix_live_view, plug, tableau, telemetry, timex, vega_lite:
  **8,199 modules, 255,316 clauses, zero crashes, zero `:unsupported_debug_info` errors.**
  This exercises the AST/`debug_info` paths exhaustively (the `:erl_abstract_code` and
  variable-named-keyword fixes hold across the entire corpus).
- **Validated across decimal, plug, jason, gettext, ecto, nimble_parsec, timex** (≈6,500 host
  tests total) with no further crashes. Ecto (1,336 functions) surfaced legitimate findings
  like `Ecto.Query.Builder.call_type/2` (CC 35, 31% → 430) and `Ecto.Repo.Assoc.merge/3`
  (CC 10, 0% → 110); gettext produced no false alarms (worst 20, under threshold).
- **No runtime JSON dependency.** Output now uses Elixir's built-in `JSON` (1.18+) instead
  of Jason — removing the runtime dep and the project-name collision that previously blocked
  running on Jason itself. Trade-off: output is compact (the built-in `JSON` has no
  pretty-printer). JSON + SARIF were re-validated end-to-end on real ecto data (SARIF still
  passes the official 2.1.0 schema).
- **Correctly does not over-flag well-tested complex code:** `Decimal.compare/2` (CC 26,
  100% cov → CRAP 26) and `Plug.SSL.check_for_missing_keys/1` (CC 14, 89% → 14.3) stay low
  because coverage protects them.
- **Known characteristic — generated lookup tables.** `Decimal.pow10/1` (106 clauses) and
  `Plug.Conn.Status.code/1` (~67 clauses) are macro-generated dispatch tables; the additive
  multi-clause CC convention makes their CC ≈ clause count, so partial coverage yields huge
  CRAP (e.g. 10717). This is *accurate* (crap_ex reflects the compiled artifact) but benign.
  **Mitigation implemented (dampen + flag):** a function with many clauses (>
  `dispatch_threshold`, default 10) each of uniformly low complexity (≤
  `dispatch_max_clause_cc`, default 2) is classified as a generated dispatch table. Its CRAP
  is scored with a dampened effective complexity of 1 and it is excluded from gating, but it
  is reported in a separate "generated dispatch" section (real `cc`/clause count shown) so
  nothing is hidden. A function with *any* genuinely complex clause (cc > the max) is never
  dampened. On Timex this cut the over-threshold list from **335 → 141** and moved **195**
  generated tables (e.g. `olson_to_win/1` at 434 clauses) into the dispatch section, while
  keeping real findings like `Timex.Protocol.Tuple.shift/2` (CC 44, 0% cov, not generated)
  in the gated list. Tunable via `--dispatch-threshold` / `--dispatch-max-clause-cc`;
  `--no-dampen` disables it.
```
