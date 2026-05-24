defmodule CrapEx.ReportTest do
  use ExUnit.Case, async: true

  alias CrapEx.{ClauseId, Config, Report, Score}

  defp clause(mod, name, idx, cc, obs) do
    id = %ClauseId{
      module: mod,
      name: name,
      arity: 1,
      kind: :def,
      clause_index: idx,
      file: "lib/x.ex",
      line_start: idx,
      line_end: idx
    }

    Score.metric(id, cc, obs)
  end

  test "build/3 aggregates functions and summarizes modules" do
    clauses = [
      clause(A, :f, 1, 5, {0, 3}),
      clause(A, :g, 1, 1, {1, 0}),
      clause(B, :h, 1, 4, {0, 4})
    ]

    report = Report.build(clauses, Config.new(), ["dev note"])

    assert length(report.functions) == 3
    assert report.deviations == ["dev note"]

    assert %{max: max_a} = report.modules[A]
    # A.f uncovered cc5 -> 30, A.g covered cc1 -> 1
    assert max_a == 30.0

    assert %{max: max_b} = report.modules[B]
    assert max_b == 20.0
  end

  test "module summary ignores not_applicable functions" do
    clauses = [clause(A, :f, 1, 3, {0, 0}), clause(A, :g, 1, 2, {0, 2})]
    report = Report.build(clauses, Config.new(), [])
    assert report.modules[A].max == 6.0
  end
end
