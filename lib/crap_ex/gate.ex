defmodule CrapEx.Gate do
  @moduledoc """
  Decide pass/fail for a `CrapEx.Report` against the configured thresholds.

  Gating operates on **function-level** metrics (aggregated clauses). A unit is
  gated only if it is in scope (see `--changed-only`, M6) and has an applicable
  coverage value; `:not_applicable` units never fail a gate.
  """

  alias CrapEx.{Config, Metric, Report}

  @type violation :: %{
          mfa: {module(), atom(), arity()},
          kind: :crap | :complexity,
          value: number(),
          threshold: number(),
          metric: Metric.t()
        }

  @doc """
  Return `:ok` if no gated function violates a threshold, otherwise
  `{:fail, [violation]}` sorted by descending value.
  """
  @spec check(Report.t(), Config.t()) :: :ok | {:fail, [violation()]}
  def check(%Report{functions: functions}, %Config{} = config) do
    gated = Enum.filter(functions, &gated?(&1, config))

    violations =
      gated
      |> Enum.flat_map(&violations_for(&1, config))
      |> Enum.sort_by(& &1.value, :desc)

    case violations do
      [] -> :ok
      _ -> {:fail, violations}
    end
  end

  # In-scope predicate. `config.scope` is `nil` (everything) or a MapSet of
  # `{module, name, arity}` keys to gate (set by the M6 changed-only resolver).
  defp gated?(%Metric{} = m, %Config{} = config) do
    applicable?(m) and in_scope?(m, config)
  end

  # Generated dispatch tables are reported separately, never gated.
  defp applicable?(%Metric{dispatch: true}), do: false
  defp applicable?(%Metric{crap: :not_applicable}), do: false
  defp applicable?(_), do: true

  defp in_scope?(_metric, %Config{scope: nil}), do: true

  defp in_scope?(%Metric{id: mfa}, %Config{scope: %MapSet{} = set}),
    do: MapSet.member?(set, mfa)

  defp violations_for(%Metric{crap: crap} = m, %Config{min_score: min} = config) do
    crap_v =
      if is_number(crap) and crap > min do
        [%{mfa: m.id, kind: :crap, value: crap, threshold: min, metric: m}]
      else
        []
      end

    cc_v =
      case config.max_complexity do
        nil ->
          []

        max when m.cc > max ->
          [%{mfa: m.id, kind: :complexity, value: m.cc, threshold: max, metric: m}]

        _ ->
          []
      end

    crap_v ++ cc_v
  end
end
