defmodule CrapEx.Format.Json do
  @moduledoc """
  JSON serialization of a `CrapEx.Report` (stable schema for tooling and
  baselines). `:not_applicable` coverage/crap are encoded as JSON `null`.

  Uses Elixir's built-in `JSON` module (Elixir 1.18+); output is compact.
  """

  alias CrapEx.{Metric, Report}

  @spec render(Report.t()) :: iodata()
  def render(%Report{} = report) do
    JSON.encode_to_iodata!(to_map(report))
  end

  @doc "Plain-map form of a report (used by the baseline store)."
  @spec to_map(Report.t()) :: map()
  def to_map(%Report{} = report) do
    %{
      "version" => 1,
      "min_score" => report.config.min_score,
      "functions" => Enum.map(report.functions, &function_map/1),
      "modules" => module_map(report.modules),
      "deviations" => report.deviations
    }
  end

  defp function_map(%Metric{id: {m, n, a}} = metric) do
    %{
      "module" => inspect(m),
      "name" => Atom.to_string(n),
      "arity" => a,
      "key" => "#{inspect(m)}.#{n}/#{a}",
      "cc" => metric.cc,
      "clauses" => metric.clauses,
      "dispatch" => metric.dispatch,
      "source_matched" => metric.source_matched,
      "coverage" => nullable(metric.coverage),
      "covered_lines" => metric.covered_lines,
      "relevant_lines" => metric.relevant_lines,
      "crap" => nullable(metric.crap)
    }
  end

  defp module_map(modules) do
    Map.new(modules, fn {mod, summary} ->
      {inspect(mod), Map.new(summary, fn {k, v} -> {Atom.to_string(k), v} end)}
    end)
  end

  defp nullable(:not_applicable), do: nil
  defp nullable(v), do: v
end
