defmodule CrapEx.Report do
  @moduledoc """
  The result of an analysis run: clause-level and function-level metrics,
  per-module summaries, and the deviation notes that were in effect.
  """

  alias CrapEx.{Metric, Score}

  @type module_summary :: %{max: float(), mean: float(), p90: float()}

  @type t :: %__MODULE__{
          clauses: [Metric.t()],
          functions: [Metric.t()],
          modules: %{module() => module_summary()},
          deviations: [String.t()],
          config: CrapEx.Config.t()
        }

  @enforce_keys [:clauses, :functions, :modules, :deviations, :config]
  defstruct [:clauses, :functions, :modules, :deviations, :config]

  @doc """
  Build a report from clause-level metrics: aggregates to functions and computes
  per-module summaries (max / mean / p90 of applicable function CRAP scores).
  """
  @spec build([Metric.t()], CrapEx.Config.t(), [String.t()]) :: t()
  def build(clause_metrics, config, deviations) do
    functions =
      Score.aggregate_all(clause_metrics,
        policy: config.on_no_coverage,
        dampen: config.dampen,
        dispatch_threshold: config.dispatch_threshold,
        dispatch_max_clause_cc: config.dispatch_max_clause_cc
      )

    modules =
      functions
      |> Enum.reject(& &1.dispatch)
      |> Enum.group_by(fn %Metric{id: {m, _, _}} -> m end)
      |> Map.new(fn {mod, metrics} -> {mod, summarize(metrics)} end)

    %__MODULE__{
      clauses: clause_metrics,
      functions: functions,
      modules: modules,
      deviations: deviations,
      config: config
    }
  end

  defp summarize(metrics) do
    scores =
      metrics
      |> Enum.map(& &1.crap)
      |> Enum.reject(&(&1 == :not_applicable))
      |> Enum.sort()

    case scores do
      [] -> %{max: 0.0, mean: 0.0, p90: 0.0}
      _ -> %{max: Enum.max(scores), mean: mean(scores), p90: percentile(scores, 90)}
    end
  end

  defp mean(scores), do: Enum.sum(scores) / length(scores)

  # nearest-rank percentile on a pre-sorted, non-empty list
  defp percentile(sorted, p) do
    rank = max(1, ceil(p / 100 * length(sorted)))
    Enum.at(sorted, rank - 1)
  end
end
