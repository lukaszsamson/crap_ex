defmodule CrapEx do
  @moduledoc """
  Compute the CRAP (Change Risk Anti-Patterns) metric per clause/function for
  Elixir codebases, for use as a CI quality gate.

      CRAP(m) = CC(m)² · (1 − cov(m))³ + CC(m)

  See `mix crap` (`CrapEx.Mix.Tasks.Crap`) for the CLI, and `PLAN.md` for the
  full design and its documented deviations from canonical CRAP (line- vs
  path-coverage, source-AST vs CFG complexity).
  """

  alias CrapEx.{Config, Coverage, Discovery, Report, Scope, Score}

  @doc """
  Analyze the compiled application against imported coverage data and produce a
  `CrapEx.Report`.

  Expects `:coverdata` paths in `config` (v1 does not run the test suite itself;
  run `mix test --cover --export-coverage <name>` first).

  > #### Side effects {: .warning}
  > This **mutates VM-global `:cover` state** — it starts `:cover`, calls
  > `:cover.reset/0`, and imports the coverdata. It is designed for a short-lived
  > `mix crap` invocation. Do not call it inside a long-running VM or alongside
  > other `:cover`-based tooling without isolating cover state yourself.
  """
  @spec analyze(Config.t()) :: {:ok, Report.t()} | {:error, term()}
  def analyze(%Config{} = config) do
    with {:ok, entries} <- Discovery.discover(config),
         entries = filter_kinds(entries, config),
         {:ok, scope} <- Scope.resolve(entries, config),
         {:ok, coverage} <- Coverage.load(config, entries) do
      config = %{config | scope: scope}
      metrics = build_metrics(entries, coverage, config)
      {:ok, Report.build(metrics, config, deviations(config))}
    end
  end

  defp filter_kinds(entries, %Config{include_macros: false}) do
    Enum.reject(entries, fn {id, _ast} -> CrapEx.ClauseId.macro?(id) end)
  end

  defp filter_kinds(entries, _config), do: entries

  defp build_metrics(entries, coverage, config) do
    backend = config.complexity_backend

    Enum.map(entries, fn {id, {body, guards}} ->
      cc = backend.complexity(body, guards)
      obs = Map.get(coverage, coverage_key(id), {0, 0})
      Score.metric(id, cc, obs, config.on_no_coverage)
    end)
  end

  defp coverage_key(%CrapEx.ClauseId{module: m, name: n, arity: a, clause_index: i}),
    do: {m, n, a, i}

  defp deviations(%Config{} = config) do
    base = [
      "Coverage is line-based (:cover clause analysis), not path/branch coverage; CRAP is a lower bound for branchy code.",
      "Cyclomatic complexity is derived from the source AST, not the BEAM control-flow graph."
    ]

    if config.include_macros do
      base ++
        ["Macros are gated; macro bodies often run at compile time and may read as uncovered."]
    else
      base
    end
  end
end
