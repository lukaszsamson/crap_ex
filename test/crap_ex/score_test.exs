defmodule CrapEx.ScoreTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrapEx.{ClauseId, Metric, Score}

  doctest CrapEx.Score

  describe "crap/2" do
    test "fully covered code scores exactly its complexity" do
      for cc <- 1..20, do: assert(Score.crap(cc, 1.0) == cc * 1.0)
    end

    test "uncovered code scores cc^2 + cc" do
      assert Score.crap(5, 0.0) == 30.0
      assert Score.crap(10, 0.0) == 110.0
    end

    test "clamps coverage outside [0,1]" do
      assert Score.crap(3, -0.5) == Score.crap(3, 0.0)
      assert Score.crap(3, 1.5) == Score.crap(3, 1.0)
    end

    property "crap is always >= cc" do
      check all(cc <- integer(1..50), cov <- float(min: 0.0, max: 1.0)) do
        assert Score.crap(cc, cov) >= cc
      end
    end

    property "crap is monotone decreasing in coverage" do
      check all(
              cc <- integer(1..50),
              c1 <- float(min: 0.0, max: 1.0),
              c2 <- float(min: 0.0, max: 1.0)
            ) do
        {lo, hi} = {min(c1, c2), max(c1, c2)}
        assert Score.crap(cc, hi) <= Score.crap(cc, lo) + 1.0e-9
      end
    end

    property "crap is monotone increasing in complexity" do
      check all(cov <- float(min: 0.0, max: 1.0), a <- integer(1..49)) do
        assert Score.crap(a, cov) <= Score.crap(a + 1, cov) + 1.0e-9
      end
    end
  end

  describe "metric/3" do
    test "{0,0} coverage observation yields :not_applicable (default :skip)" do
      m = Score.metric({Foo, :bar, 1}, 4, {0, 0})
      assert m.coverage == :not_applicable
      assert m.crap == :not_applicable
      assert m.relevant_lines == 0
    end

    test "{0,0} with :zero policy is treated as uncovered" do
      m = Score.metric({Foo, :bar, 1}, 4, {0, 0}, :zero)
      assert m.coverage == 0.0
      assert m.crap == 20.0
    end

    test "complexity-only mode (no coverage) scores worst-case CRAP" do
      # No coverdata: analyze treats every function as uncovered via :zero policy.
      config = CrapEx.Config.new(no_coverage: true, on_no_coverage: :zero)
      {:ok, report} = CrapEx.analyze(config)
      assert "Complexity-only mode: coverage assumed 0% (worst-case CRAP)." in report.deviations
      # crap_ex's own modules are discovered; everything has a numeric CRAP.
      assert Enum.all?(report.functions, &is_number(&1.crap))
      assert report.functions != []
    end

    test "computes coverage fraction and crap" do
      m = Score.metric({Foo, :bar, 1}, 5, {0, 3})
      assert m.coverage == 0.0
      assert m.crap == 30.0
      assert m.relevant_lines == 3
    end
  end

  describe "aggregate/1" do
    test "sums cc and recomputes coverage over summed lines" do
      c1 = clause_metric(1, 2, {1, 0})
      c2 = clause_metric(2, 3, {0, 2})
      agg = Score.aggregate([c1, c2])

      assert agg.id == {Foo, :bar, 1}
      assert agg.cc == 5
      assert agg.covered_lines == 1
      assert agg.relevant_lines == 3
      assert_in_delta agg.coverage, 1 / 3, 1.0e-9
    end

    test "all-not-applicable clauses aggregate to not_applicable" do
      agg = Score.aggregate([clause_metric(1, 1, {0, 0}), clause_metric(2, 2, {0, 0})])
      assert agg.coverage == :not_applicable
      assert agg.crap == :not_applicable
    end
  end

  describe "dispatch-table dampening" do
    defp trivial_clauses(n, obs) do
      for i <- 1..n, do: clause_metric(i, 1, obs)
    end

    test "many trivial clauses are flagged dispatch and CRAP-dampened" do
      # 50 trivial (CC 1) clauses, mostly uncovered — a generated lookup table.
      agg = Score.aggregate(trivial_clauses(50, {0, 1}), dampen: true, dispatch_threshold: 10)
      assert agg.dispatch
      assert agg.cc == 50
      assert agg.clauses == 50
      # scored with effective cc 1, not 50: crap = 1^2*(1)^3 + 1 = 2.0
      assert agg.crap == 2.0
    end

    test "without dampening, the same function scores on full CC" do
      agg = Score.aggregate(trivial_clauses(50, {0, 1}), dampen: false)
      refute agg.dispatch
      assert agg.crap == 50 * 50 + 50
    end

    test "a complex (non-trivial) multi-clause function is not dispatch" do
      clauses = [clause_metric(1, 5, {0, 5}) | trivial_clauses(20, {0, 1})]
      agg = Score.aggregate(clauses, dampen: true, dispatch_threshold: 10)
      refute agg.dispatch
    end

    test "few trivial clauses stay below the dispatch threshold" do
      agg = Score.aggregate(trivial_clauses(3, {0, 1}), dampen: true, dispatch_threshold: 10)
      refute agg.dispatch
    end
  end

  defp clause_metric(idx, cc, obs) do
    id = %ClauseId{
      module: Foo,
      name: :bar,
      arity: 1,
      kind: :def,
      clause_index: idx,
      file: "lib/foo.ex",
      line_start: idx,
      line_end: idx
    }

    %Metric{} = Score.metric(id, cc, obs)
  end
end
