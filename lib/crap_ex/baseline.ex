defmodule CrapEx.Baseline do
  @moduledoc """
  Compare a current `CrapEx.Report` against a stored baseline (the JSON written
  by `--write-baseline`) and report **regressions** only:

    * a function whose CRAP increased beyond `tolerance` vs the baseline, or
    * a brand-new function that exceeds `min_score`.

  Pre-existing offenders that did not get worse are not regressions, so legacy
  code does not block all future work.
  """

  alias CrapEx.{Metric, Report}

  @type regression :: %{
          key: String.t(),
          reason: :worsened | :new,
          current: float(),
          previous: float() | nil,
          metric: Metric.t()
        }

  @default_tolerance 0.0

  @doc "Load a baseline JSON file into a `%{key => crap}` map."
  @spec load(String.t()) :: {:ok, %{String.t() => float()}} | {:error, term()}
  # Reading a user-supplied baseline path is the intended behavior of this CLI.
  # sobelow_skip ["Traversal.FileModule"]
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- JSON.decode(body) do
      functions = Map.get(json, "functions", [])

      map =
        Map.new(functions, fn f ->
          {f["key"], normalize(f["crap"])}
        end)

      {:ok, map}
    end
  end

  @doc """
  Return the list of regressions of `report` against the loaded `baseline` map.
  `opts`: `:tolerance` (default 0.0), `:min_score` (default from report config).
  """
  @spec regressions(Report.t(), %{String.t() => float()}, keyword()) :: [regression()]
  def regressions(%Report{functions: functions} = report, baseline, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    min_score = Keyword.get(opts, :min_score, report.config.min_score)

    functions
    |> Enum.reject(&(&1.crap == :not_applicable))
    |> Enum.flat_map(fn metric ->
      key = key_of(metric)
      classify(key, metric, Map.get(baseline, key, :missing), tolerance, min_score)
    end)
    |> Enum.sort_by(& &1.current, :desc)
  end

  defp classify(key, %Metric{crap: crap} = m, :missing, _tol, min_score) do
    if crap > min_score do
      [%{key: key, reason: :new, current: crap, previous: nil, metric: m}]
    else
      []
    end
  end

  defp classify(_key, _m, nil, _tol, _min), do: []

  defp classify(key, %Metric{crap: crap} = m, previous, tol, _min) when is_number(previous) do
    if crap > previous + tol do
      [%{key: key, reason: :worsened, current: crap, previous: previous, metric: m}]
    else
      []
    end
  end

  defp key_of(%Metric{id: {m, n, a}}), do: "#{inspect(m)}.#{n}/#{a}"

  defp normalize(nil), do: nil
  defp normalize(n) when is_number(n), do: n / 1.0
end
