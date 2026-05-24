defmodule CrapEx.Format.Sarif do
  @moduledoc """
  SARIF 2.1.0 output for GitHub code scanning. Emits one `result` per function
  over the CRAP threshold, with a `physicalLocation` pointing at the function's
  first clause (file + start line), so findings render as inline annotations.

  The generated log is validated against the official SARIF 2.1.0 JSON schema in
  the test suite (gate G7), not just against snapshots.
  """

  alias CrapEx.{ClauseId, Metric, Report}

  @schema "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/sarif-2.1.0.json"
  @version "2.1.0"

  @spec render(Report.t()) :: iodata()
  def render(%Report{} = report) do
    JSON.encode_to_iodata!(to_map(report))
  end

  @doc "Plain-map SARIF log (used by tests for schema validation)."
  @spec to_map(Report.t()) :: map()
  def to_map(%Report{functions: functions, clauses: clauses, config: config}) do
    locations = location_index(clauses)

    results =
      functions
      |> Enum.filter(&over_threshold?(&1, config.min_score))
      |> Enum.map(&result(&1, config.min_score, locations))

    %{
      "$schema" => @schema,
      "version" => @version,
      "runs" => [
        %{
          "tool" => %{
            "driver" => %{
              "name" => "crap_ex",
              "informationUri" => "https://hexdocs.pm/crap_ex",
              "rules" => [
                %{
                  "id" => "crap/threshold",
                  "name" => "ChangeRiskAntiPattern",
                  "shortDescription" => %{"text" => "Function CRAP score exceeds threshold"},
                  "helpUri" => "http://www.crap4j.org/faq.html"
                }
              ]
            }
          },
          "results" => results
        }
      ]
    }
  end

  # mfa -> {file, line} from the lowest-line clause of each function.
  defp location_index(clauses) do
    clauses
    |> Enum.filter(&match?(%Metric{id: %ClauseId{}}, &1))
    |> Enum.group_by(fn %Metric{id: id} -> ClauseId.mfa(id) end)
    |> Map.new(fn {mfa, metrics} ->
      %Metric{id: id} = Enum.min_by(metrics, fn %Metric{id: c} -> c.line_start end)
      {mfa, {id.file, id.line_start}}
    end)
  end

  defp over_threshold?(%Metric{crap: :not_applicable}, _), do: false
  defp over_threshold?(%Metric{crap: crap}, min), do: crap > min

  defp result(%Metric{id: {mod, n, a} = mfa} = m, min, locations) do
    label = "#{inspect(mod)}.#{n}/#{a}"

    %{
      "ruleId" => "crap/threshold",
      "level" => "warning",
      "message" => %{
        "text" =>
          "#{label} has CRAP #{fmt(m.crap)} (CC #{m.cc}, coverage #{pct(m.coverage)}), over #{min}."
      },
      "locations" => [location(Map.get(locations, mfa))]
    }
  end

  defp location(nil) do
    %{"physicalLocation" => %{"artifactLocation" => %{"uri" => "unknown"}}}
  end

  defp location({file, line}) do
    %{
      "physicalLocation" => %{
        "artifactLocation" => %{"uri" => file},
        "region" => %{"startLine" => line}
      }
    }
  end

  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp pct(:not_applicable), do: "n/a"
  defp pct(c), do: "#{:erlang.float_to_binary(c * 100, decimals: 1)}%"
end
