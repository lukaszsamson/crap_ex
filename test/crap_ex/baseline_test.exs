defmodule CrapEx.BaselineTest do
  @moduledoc "Gate G7 (baseline half): unchanged pass, worsened/new fail."
  use ExUnit.Case, async: true

  alias CrapEx.{Baseline, Config, Format, Report, Score}

  defp report(metrics, min_score \\ 30) do
    Report.build(metrics, Config.new(min_score: min_score), [])
  end

  defp fmetric(name, cc, obs) do
    Score.metric({Mod, name, 0}, cc, obs)
  end

  defp baseline_for(pairs) do
    Map.new(pairs, fn {key, crap} -> {key, crap} end)
  end

  test "unchanged offender is not a regression" do
    # Pre-existing CRAP 30 stays 30.
    rep = report([fmetric(:legacy, 5, {0, 5})])
    base = baseline_for([{"Mod.legacy/0", 30.0}])
    assert Baseline.regressions(rep, base) == []
  end

  test "worsened offender is a regression" do
    rep = report([fmetric(:legacy, 6, {0, 6})])
    base = baseline_for([{"Mod.legacy/0", 30.0}])
    assert [%{reason: :worsened, previous: 30.0, current: 42.0}] = Baseline.regressions(rep, base)
  end

  test "new function over min_score is a regression" do
    rep = report([fmetric(:fresh, 6, {0, 6})])
    base = baseline_for([])
    assert [%{reason: :new, current: 42.0, previous: nil}] = Baseline.regressions(rep, base)
  end

  test "new function under min_score is not a regression" do
    rep = report([fmetric(:fresh, 1, {1, 0})])
    base = baseline_for([])
    assert Baseline.regressions(rep, base) == []
  end

  test "improved function is not a regression" do
    rep = report([fmetric(:better, 2, {2, 0})])
    base = baseline_for([{"Mod.better/0", 42.0}])
    assert Baseline.regressions(rep, base) == []
  end

  test "load/1 round-trips JSON written by the Json formatter" do
    rep = report([fmetric(:legacy, 5, {0, 5})])
    tmp = Path.join(System.tmp_dir!(), "baseline_#{System.unique_integer([:positive])}.json")
    File.write!(tmp, Format.Json.render(rep))
    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, map} = Baseline.load(tmp)
    assert map["Mod.legacy/0"] == 30.0
  end
end
