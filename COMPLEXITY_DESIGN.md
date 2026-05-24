# Design: source-AST complexity (fixing macro-DSL CC inflation)

> Reviewed independently by GPT (via codex). Corrections folded in: narrowed the
> correctness claim to *authored-source* CC; changed the join key from `{file,line}`
> to `{mfa, ordinal}` validated by `{file,line,column}`; flagged that the visitor's
> guard counting is not yet source-ready; made join status a reported diagnostic;
> kept dispatch dampening until fallback rates are measured.
>
> Further investigation (compiler constructs) added the **module-identity**
> refinement — `defimpl`/`defprotocol`/`defstruct`/`defoverridable` generate
> functions whose compiled module/name don't match a lexical `defmodule`/`def`, so
> the join must resolve module scope and classify generated functions. `elixir_rewrite`
> was checked and ruled out (it only touches the expanded translation path).

## Problem

`crap_ex` reads complexity from the compiled `debug_info` chunk, which stores the
**macro-expanded** AST. For compile-time DSLs this inflates cyclomatic complexity
by orders of magnitude:

- `base_grid_query/2` (Ecto `from/where`, 26 LOC, ~3 source branches) → **CC 1023**
  because each field access expands to a `case` checking `__schema__` (1,022 `case`
  nodes in the body).
- Phoenix `~H` `render/1` templates → CC 500–2,000.

These are the dominant false positives on real Phoenix/Ecto apps (unilink, zorbito).

## Validated insight

Computing CC on the **source** AST eliminates the inflation: macros are *not*
expanded, so a DSL call is an opaque node whose source form has no control-flow
tokens. Empirically, on the source AST the existing visitor scores
`base_grid_query/2` as **CC 1** (vs 1023). For plain control flow (`if`/`case`/
`with`/`&&`), source and expanded forms count equivalently, so non-DSL code is
unaffected. **Classic CC is, by definition, a property of the code as written —
so the source AST is the correct input, and `debug_info` was the wrong one for
this stage.**

The only reason `debug_info` was used for complexity is that it conveniently
carried clause identity + line ranges aligned to `:cover`. We keep using it for
*that*; we only move the **CC computation** to source.

> **Scope of the claim (narrowed after review).** This measures *authored-source*
> complexity, **not** runtime control flow after expansion. That is precisely what
> fixes Ecto/HEEX — but it also means runtime branching introduced *by* a macro the
> user relies on is **intentionally under-counted**. That is the correct trade-off
> for a "is this code, as written, risky to change" metric, but it must be stated:
> source CC ≤ expanded CC, and the gap is exactly the macro-generated control flow.

## What's needed beyond `Macro.traverse`

`Macro.prewalk`/`traverse` always descend into every subtree. A correct source-CC
walker needs **controlled descent (pruning)** so it can skip subtrees that are not
executable branches in the function being measured:

- `quote do … end` / `unquote` blocks — code *generation*, not branches. A normal
  `def` that builds AST with `quote do if x do … end end` must not count that `if`.
- Unknown macro calls carrying `do`/`->` clauses — must not be counted as
  `case`/`cond` branches (e.g. a DSL block that happens to use `->`).
- Macro-call arguments that are DSL syntax rather than evaluated expressions.

This is the "opacity policy": a small allowlist of control-flow special forms
that count and are descended into; everything else is an opaque leaf. Mutalisk's
`Mut.OpaquePolicy` / `Mut.EnvWalker` implement exactly this idea for mutation
testing, and `Mut.Trace` shows the compile-tracer technique for disambiguating
real macros from look-alikes.

## The hard sub-problem: source ↔ coverage mapping

`:cover` reports coverage per compiled clause `{M, F, A, clause_index}`. We must
attach the source-derived CC to the right clause.

**Key by `{mfa, textual_clause_ordinal}`, validated by `{file, line, column}` —
not by line alone.** (Review correction: multiple `def`s/clauses on one line are
real, so line-only matching collides.)

- Discovery groups compiled clauses per `{M, F, A}` in definition order, giving each
  a `clause_index`. Source `def`/`defp` clauses for the same `{name, arity}`, taken
  in **textual order**, give a parallel ordinal. Zip them.
- Parse source with `columns: true, token_metadata: true` and validate each pairing
  against the clause's `{file, line, column}` (columns disambiguate same-line defs
  cheaply — no tracer needed for this).
- **Mapping must be a reported fact, not an invisible fallback.** Classify every
  compiled clause as one of: `:matched_source`, `:fallback_debug_info`,
  `:generated` (no source def — `use`-injected, macro-emitted), or `:ambiguous`
  (ordinal/validation mismatch). Surface counts; a high fallback rate means the
  source CC isn't trustworthy for that module and should warn — silently using the
  old `debug_info` CC would re-introduce the very inflation we're fixing.

**Module identity is the deeper issue (verified empirically).** A source `def`'s
*compiled module* is not always a lexically-enclosing `defmodule`. The source
extractor must track scope and resolve generated module names, or it cannot key by
`{module, name, arity}` at all:

- **`defimpl Proto, for: Type`** compiles to module **`Proto.Type`** — the `def`s
  sit inside `defimpl`, not a `defmodule Proto.Type`. `for:` may be a **list**
  (one source clause → *N* compiled modules) or computed (`__MODULE__`, a var).
- **`defprotocol Name`** compiles to `Name`; its `def`s are **bodyless stubs** in
  source but **generated dispatch bodies** in the artifact.
- **Nested `defmodule`** → dotted/aliased names need resolution.

So key on `{resolved_module, name, arity, ordinal}`, computed by a scope-tracking
walk (`defmodule`/`defimpl`/`defprotocol`/alias) — the same context elixir_sense's
compiler tracks. Handle literal cases; mark computed/dynamic targets `:ambiguous`.

**Generated functions with no clean source `def` (classify `:generated`, never use
the inflated debug_info CC):**

| Construct | Generated functions (in `definitions` + `:cover`) |
|---|---|
| `defstruct` | `__struct__/0`, `__struct__/1` |
| `defprotocol` | `__protocol__/1`, `impl_for/1`, `impl_for!/1`, `struct_impl_for/1`, + dispatch bodies for each protocol fun |
| `defimpl` | `__impl__/1` |
| `defoverridable` + `super` | the original, renamed to a **mangled atom like `:"greet (overridable 1)"`** (spaces/parens) |
| `Record.defrecord` | generates **macros** (gated out by default), not functions |
| `defdelegate` | a thin generated `def` (body is the delegated call — trivial CC) |

The walker can recognize the *generators* (`defstruct`/`defprotocol`/`defrecord`/
`defoverridable`) to mark these proactively; otherwise they fall through as
unmatched → `:generated`. Their real CC is trivial, so the gate outcome is correct
either way — the point is to classify, not silently trust the expanded CC.

**Other hazards:**

- **Bodyless `def` heads must be skipped during source extraction.** A `def`/`defp`
  with no `do:`/body block is a *declaration* — a default-arg head
  (`def f(x, y \\ 5)`) or a multi-clause grouping head. It carries no body to count
  and must **not** consume a clause ordinal, or it desyncs the zip. (Verified:
  `def deflt(x, y \\ 5)` + `def deflt(x, y), do: …` are two source `def` nodes but
  one compiled `deflt/2` clause.) Extract only `def`s that have a body block.
- **Default args** — the same construct also generates extra arities
  (`def deflt(x, y \\ 5)` → a generated `deflt/1` that calls `deflt/2`). Map the
  explicit arity to source; mark the generated lower arity `:generated`.
- **`@before_compile`/`@after_compile`** are macro-injectors like `use`: they emit
  `def`s into the *current* module whose `:line` points into the **hook module's
  `quote` block** (a different lexical module). Because the extractor (a) skips
  `quote` subtrees and (b) keys on the lexical module, these never falsely map and
  fall through to `:generated`. `@on_load`/`@after_verify`/`@on_definition` only
  *reference* ordinary `def`s — those map normally; no special handling.
- **`defguard`/`defguardp`** compile to a **`defmacro`** (gated out by default). Its
  guard logic is opaque on source, so a function *using* the guard under-counts the
  guard's internal ops — consistent with the documented macro under-count.
- **`defdelegate`** → a generated trivial `def` at the `defdelegate` line (no `def`
  node in source) → `:generated`. `defmacro`/`defmacrop` map normally but are gated
  unless `--include-macros`.
- **Dynamic `defmodule`** (`defmodule unquote(name)`, `Module.create/3`) → module
  can't be resolved syntactically → `:ambiguous`.
- **`super`** is just an opaque call in source — adds no CC; the overriding def is
  counted normally. No special handling.
- **Mangled/odd names** (overridable, `:"..."` atoms) must not crash labels/output —
  add a fixture.
- Source changed since compile → line/column drift. Detect via source mtime vs the
  beam/compile artifact and **warn** rather than silently mixing new source CC with
  stale coverage.

**`elixir_rewrite` is *not* a concern for this approach.** It renames call targets
(`Kernel.+/2`→`:erlang.+`, `Map.get`→…) and applies a few special rewrites *during
translation to Erlang*, on the expanded AST — never on the source we parse. It
changes call targets, not control-flow structure, so it wouldn't even affect CC on
the debug_info path. Its existence is one more reason the expanded AST is the wrong
CC input; the source approach sidesteps it entirely.

This keeps the existing pipeline (discovery, `:cover` join, gating, output) and
swaps only the per-clause CC source, with explicit diagnostics on the join.

## Approaches

### A. Source-AST CC, line-keyed to debug_info clauses  ⭐ recommended

Parse each source file once (cached), extract `def`/`defp` clause bodies+guards,
compute CC with a **pruning visitor + minimal opacity policy** (skip `quote`,
treat non-control-flow `do`/`->` macros as opaque). Join to discovered clauses by
`{file, head_line}`; fall back to `debug_info` CC when unmatched.

- Reuses the current visitor's counting rules (they already operate on
  pre-expansion forms — `if`/`with`/`&&` — which is what source has).
- No compilation changes; just file reads + parsing.
- **Feasibility: high. Complexity: medium** (~250–350 LOC + tests).
- **Risk:** mis-keying on clauses that share a head line; adversarial DSLs whose
  *source* uses `->` in a way the allowlist misjudges. Both are rare and degrade
  to a conservative count, not a crash.

### B. Source-AST CC + compile tracer (mutalisk-style)

As A, plus a compiler tracer (`:tracers`) during `mix crap`'s compile step that
records every macro-dispatch site by source line/column. The walker consults this
index to *prove* whether a call is a macro and whether an `if`/`with` is the real
Kernel form vs a user redefinition — removing the allowlist's guesswork.

- Precise on edge cases: redefined `if`, imported control-flow-shaped macros,
  custom DSLs that wrap `case`.
- **Feasibility: medium-high** (tracers are stable; we already compile).
  **Complexity: medium-high** (+tracer module, writer, index, line/col→node
  correlation; ~3 extra modules, cf. mutalisk).
- **Risk:** correlation by position is fiddly; tracer adds a compile dependency
  and per-run cost.
- **Verdict:** "optional" for product scope (the Ecto/HEEX fix doesn't need it),
  but it *is* what's required for strict correctness of macro-vs-function
  disambiguation and custom control-flow macros. Frame it as hardening that closes
  the opacity-policy under-count, not as unnecessary.

### C. Selective partial expansion (elixir_sense / elixir_expand mimic)

Expand only Kernel control-flow macros, leave user/library macros opaque, then
count. elixir_sense's compiler (≈8.6k LOC, mirroring the 1.3k-LOC
`elixir_expand.erl`) is a full partial-expander.

- **Feasibility: low. Complexity: very high.** It re-implements a large slice of
  the compiler and must track `Macro.Env`, imports, and aliases to expand
  correctly.
- **Wrong direction:** expansion is what *causes* the inflation; we'd expand and
  then discard most of it. Counting `if`/`with` on the source (A) is simpler and
  equivalent for CC. Reach for this only if we later want semantic complexity
  (data/effect flow), which is out of scope.
- **Verdict: reject** for this problem.

## Comparison

| | A (source + opacity) | B (+ tracer) | C (partial expand) |
|---|---|---|---|
| Fixes Ecto/HEEX inflation | yes | yes | yes |
| New code | ~250–350 LOC | +~300 LOC | ~thousands |
| Compile-step changes | none | tracer | none/loader |
| Edge-case precision | good | best | best |
| Risk | low | medium | high |
| Effort | ~1–2 days | +2–3 days | weeks |

## Recommendation

Ship **A** now; it eliminates the false positives with modest, low-risk code and
reuses the existing visitor. Layer **B** (tracer) later only if real projects show
allowlist misclassifications. Skip **C**.

### Phasing for A

0. **Make the visitor source-ready first (review correction — it is not today).**
   `guard_count/1` only counts `:erlang.andalso`/`:erlang.orelse` (the *expanded*
   guard shape from `debug_info`); on source, guards use `and`/`or`/`&&`/`||`, so
   `def f(x) when a or b` would under-count. Update guard counting for source
   operators (or normalize both shapes). Also add (or add explicit
   limitation/skip tests for): `for` comprehension filters, `receive`, multi-clause
   `fn`, and `try` `rescue`/`catch`/`else`. Golden tests must cover the source form
   of every construct the metric claims to count.
1. `CrapEx.Complexity.Source` — parse (`columns: true, token_metadata: true`) +
   cache files; **scope-track `defmodule`/`defimpl`/`defprotocol`/alias to resolve
   each `def`'s compiled module** (incl. `defimpl … for: list` → N modules); skip
   protocol stubs and `defstruct`/`defrecord`/`defoverridable`-generated names.
   Output: ordered clause list per `{resolved_module, name, arity}`, each carrying
   `{file, line, column}`.
2. Pruning walker + opacity policy (extend the visitor with controlled descent;
   skip `quote`/`unquote`; opaque non-allowlisted `do`/`->` macros). Keep the same
   counting rules so existing golden tests hold. **Document the opacity under-count:
   without a tracer we cannot reliably tell `foo do … end` (macro boundary) from a
   function call with a block, so runtime branches inside an unknown block macro are
   skipped.**
3. Facade: zip compiled clauses (per mfa, definition order) with source clauses
   (textual order), validate by `{file, line, column}`, attach a join status
   (`:matched_source` / `:fallback_debug_info` / `:generated` / `:ambiguous`).
   Report status counts; warn on high fallback rate.
4. Make source CC the default; add `--complexity-source debug_info|source` to opt
   out. **Keep dispatch dampening** until real-project fallback rates are measured
   low (it still catches `:fallback_debug_info` generated tables). Revisit retiring
   it only after data.
5. Re-validate on unilink/zorbito: `base_grid_query` ≈ 1, `decline_task/3` ≈ 10
   (unchanged), join fallback rate low, over-threshold list drops to genuine
   findings.

### Notes / open questions

- Source must match the compiled artifact. Guard against stale source (compare
  `debug_info` line ranges to parsed file; if a file changed since compile, warn).
- Files compiled from `.eex`/`.heex` or `eval`'d strings have no on-disk source
  `def` → fall back. Umbrella child files resolve via the `file` (absolute) the
  `debug_info` map carries.
- `--changed-only` already parses source diffs; the source map can share that
  file-reading layer.
