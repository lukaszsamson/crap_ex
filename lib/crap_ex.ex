defmodule CrapEx do
  @moduledoc """
  Compute the CRAP (Change Risk Anti-Patterns) metric per clause/function for
  Elixir codebases, for use as a CI quality gate.

      CRAP(m) = CC(m)² · (1 − cov(m))³ + CC(m)

  See `mix crap` (`CrapEx.Mix.Tasks.Crap`) for the CLI, and `PLAN.md` for the
  full design and its documented deviations from canonical CRAP (line- vs
  path-coverage, source-AST vs CFG complexity).
  """

  alias CrapEx.{Complexity.Source, Config, Coverage, Discovery, Report, Scope, Score}

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
         {:ok, coverage} <- load_coverage(config, entries) do
      config = %{config | scope: scope}
      {metrics, join_stats} = build_metrics(entries, coverage, config)
      {:ok, Report.build(metrics, config, deviations(config), join_stats)}
    end
  end

  # Complexity-only mode: no coverage data, every function scored as uncovered.
  defp load_coverage(%Config{no_coverage: true}, _entries), do: {:ok, %{}}
  defp load_coverage(config, entries), do: Coverage.load(config, entries)

  defp filter_kinds(entries, %Config{include_macros: false}) do
    Enum.reject(entries, fn {id, _ast} -> CrapEx.ClauseId.macro?(id) end)
  end

  defp filter_kinds(entries, _config), do: entries

  defp build_metrics(entries, coverage, %Config{complexity_source: :source} = config) do
    backend = config.complexity_backend
    source_index = source_index(entries)

    {metrics, stats} =
      Enum.map_reduce(entries, %{}, fn {id, {dbg_body, dbg_guards}}, stats ->
        {body, guards, status} =
          case Source.lookup(source_index, id.abs_file, id.name, id.arity, id.line_start) do
            {:ok, {sbody, sguards}} -> {sbody, sguards, :matched_source}
            {:miss, reason} -> {dbg_body, dbg_guards, fallback_status(id, reason)}
          end

        cc = backend.complexity(body, guards)
        obs = Map.get(coverage, coverage_key(id), {0, 0})

        metric = %{
          Score.metric(id, cc, obs, config.on_no_coverage)
          | source_matched: status == :matched_source
        }

        {metric, Map.update(stats, status, 1, &(&1 + 1))}
      end)

    {metrics, stats}
  end

  defp build_metrics(entries, coverage, %Config{complexity_source: :debug_info} = config) do
    backend = config.complexity_backend

    metrics =
      Enum.map(entries, fn {id, {body, guards}} ->
        cc = backend.complexity(body, guards)
        obs = Map.get(coverage, coverage_key(id), {0, 0})
        Score.metric(id, cc, obs, config.on_no_coverage)
      end)

    {metrics, %{debug_info: length(metrics)}}
  end

  defp source_index(entries) do
    entries
    |> Enum.map(fn {id, _} -> id.abs_file end)
    |> Enum.reject(&is_nil/1)
    |> Source.index()
  end

  # A miss on a generated-looking name (defstruct/protocol/impl/overridable/etc.)
  # is expected; everything else is an unexpected fallback worth reporting.
  defp fallback_status(%CrapEx.ClauseId{name: name}, _reason) do
    if generated_name?(name), do: :generated, else: :fallback_debug_info
  end

  defp generated_name?(name) do
    s = Atom.to_string(name)

    String.starts_with?(s, "__") or
      String.contains?(s, " ") or
      name in [:__struct__, :__impl__, :__protocol__, :impl_for, :impl_for!, :struct_impl_for]
  end

  defp coverage_key(%CrapEx.ClauseId{module: m, name: n, arity: a, clause_index: i}),
    do: {m, n, a, i}

  defp deviations(%Config{} = config) do
    base = [
      "Coverage is line-based (:cover clause analysis), not path/branch coverage; CRAP is a lower bound for branchy code.",
      "Cyclomatic complexity is derived from the source AST, not the BEAM control-flow graph."
    ]

    base =
      if config.no_coverage,
        do: ["Complexity-only mode: coverage assumed 0% (worst-case CRAP)." | base],
        else: base

    if config.include_macros do
      base ++
        ["Macros are gated; macro bodies often run at compile time and may read as uncovered."]
    else
      base
    end
  end
end
