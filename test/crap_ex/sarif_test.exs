defmodule CrapEx.SarifTest do
  @moduledoc "Gate G7 (schema half): generated SARIF validates against 2.1.0."
  use ExUnit.Case, async: true

  alias CrapEx.{ClauseId, Config, Format.Sarif, Report, Score}

  @schema_path "priv/schemas/sarif-2.1.0.json"

  defp resolved_schema do
    @schema_path
    |> File.read!()
    |> JSON.decode!()
    |> ExJsonSchema.Schema.resolve()
  end

  defp clause_metric(name, line, cc, obs) do
    id = %ClauseId{
      module: My.Mod,
      name: name,
      arity: 1,
      kind: :def,
      clause_index: 1,
      file: "lib/my/mod.ex",
      line_start: line,
      line_end: line + 2
    }

    Score.metric(id, cc, obs)
  end

  defp sample_report do
    clauses = [
      clause_metric(:risky, 7, 6, {0, 6}),
      clause_metric(:safe, 20, 2, {2, 0})
    ]

    Report.build(clauses, Config.new(min_score: 30), ["note"])
  end

  test "generated SARIF validates against the official 2.1.0 schema" do
    sarif = Sarif.to_map(sample_report())
    assert :ok = ExJsonSchema.Validator.validate(resolved_schema(), sarif)
  end

  test "emits one result per over-threshold function with a physical location" do
    sarif = Sarif.to_map(sample_report())
    [run] = sarif["runs"]
    results = run["results"]

    assert length(results) == 1
    [result] = results
    assert result["ruleId"] == "crap/threshold"
    assert result["level"] == "warning"

    loc = hd(result["locations"])["physicalLocation"]
    assert loc["artifactLocation"]["uri"] == "lib/my/mod.ex"
    assert loc["region"]["startLine"] == 7
  end

  test "empty report still validates (no results)" do
    empty = Report.build([], Config.new(), [])
    assert :ok = ExJsonSchema.Validator.validate(resolved_schema(), Sarif.to_map(empty))
  end

  test "rendered output is valid JSON" do
    assert {:ok, _} = sample_report() |> Sarif.render() |> IO.iodata_to_binary() |> JSON.decode()
  end
end
