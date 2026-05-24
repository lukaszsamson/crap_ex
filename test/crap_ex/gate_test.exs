defmodule CrapEx.GateTest do
  use ExUnit.Case, async: true

  alias CrapEx.{Config, Gate, Report, Score}

  defp report(metrics, config) do
    # metrics are already function-level; wrap them in a report directly.
    %Report{
      clauses: [],
      functions: metrics,
      modules: %{},
      deviations: [],
      config: config
    }
  end

  defp fmetric(mfa, cc, obs), do: Score.metric(mfa, cc, obs)

  test "passes when all functions are under threshold" do
    config = Config.new(min_score: 30)
    metrics = [fmetric({A, :ok, 0}, 3, {3, 0}), fmetric({A, :fine, 0}, 5, {5, 0})]
    assert Gate.check(report(metrics, config), config) == :ok
  end

  test "fails functions over the CRAP threshold, sorted desc" do
    config = Config.new(min_score: 30)

    metrics = [
      fmetric({A, :bad, 0}, 6, {0, 6}),
      fmetric({A, :worse, 0}, 8, {0, 8}),
      fmetric({A, :ok, 0}, 2, {2, 0})
    ]

    assert {:fail, [v1, v2]} = Gate.check(report(metrics, config), config)
    assert v1.value > v2.value
    assert v1.mfa == {A, :worse, 0}
    assert Enum.all?([v1, v2], &(&1.kind == :crap))
  end

  test "not_applicable functions never fail" do
    config = Config.new(min_score: 1)
    metrics = [fmetric({A, :noexec, 0}, 9, {0, 0})]
    assert Gate.check(report(metrics, config), config) == :ok
  end

  test "dispatch tables are never gated, even with huge CC" do
    config = Config.new(min_score: 1, max_complexity: 5)
    dispatch = %{fmetric({A, :lookup, 1}, 400, {0, 400}) | dispatch: true}
    assert Gate.check(report([dispatch], config), config) == :ok
  end

  test "max_complexity gate is independent of crap" do
    config = Config.new(min_score: 1000, max_complexity: 4)
    metrics = [fmetric({A, :complex, 0}, 5, {5, 0})]
    assert {:fail, [v]} = Gate.check(report(metrics, config), config)
    assert v.kind == :complexity
    assert v.value == 5
  end

  test "scope restricts gating to listed mfas" do
    config = Config.new(min_score: 1, scope: MapSet.new([{A, :gated, 0}]))

    metrics = [
      fmetric({A, :gated, 0}, 5, {0, 5}),
      fmetric({A, :ignored, 0}, 9, {0, 9})
    ]

    assert {:fail, [v]} = Gate.check(report(metrics, config), config)
    assert v.mfa == {A, :gated, 0}
  end
end
