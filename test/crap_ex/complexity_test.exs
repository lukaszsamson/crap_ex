defmodule CrapEx.ComplexityTest do
  @moduledoc "Gate G3: golden complexity values + Credo-parity pinning."
  use ExUnit.Case, async: true

  alias CrapEx.{Complexity.Credo, Complexity.Visitor, Discovery}

  # Expected per-clause classic CC for the visitor, summed across clauses
  # for multi-clause functions (the facade aggregation does the summing).
  @visitor_expected %{
    one_liner: 1,
    simple: 1,
    classify: 5,
    with_case: 2,
    with_if: 2,
    boolean_ops: 3,
    with_expr: 2,
    anon_fn: 2,
    guarded: 2,
    helper: 1,
    use_helper: 1
  }

  setup_all do
    {:ok, entries} = Discovery.discover_modules([CrapFixtures.Shapes])

    by_name =
      entries
      |> Enum.group_by(fn {id, _} -> id.name end, fn {_, ast} -> ast end)

    %{by_name: by_name}
  end

  defp visitor_total(clauses) do
    clauses |> Enum.map(fn {body, guards} -> Visitor.complexity(body, guards) end) |> Enum.sum()
  end

  for {name, expected} <- @visitor_expected do
    test "visitor: #{name} has classic CC #{expected}", %{by_name: by_name} do
      clauses = Map.fetch!(by_name, unquote(name))
      assert visitor_total(clauses) == unquote(expected)
    end
  end

  test "visitor: every clause has complexity >= 1", %{by_name: by_name} do
    for {_name, clauses} <- by_name, {body, guards} <- clauses do
      assert Visitor.complexity(body, guards) >= 1
    end
  end

  test "visitor: does not crash on variables named like control-flow keywords" do
    # A variable reference has an atom/nil third element, not an arg list.
    # Seen in the wild (nimble_parsec) — these must not be treated as branches.
    for kw <- [:case, :cond, :with, :try] do
      var = {kw, [], nil}
      assert Visitor.complexity(var) == 1
      assert Visitor.complexity({:__block__, [], [var, {kw, [], Elixir}]}) == 1
    end
  end

  describe "Credo backend (pinned)" do
    test "trivial clause is 1", %{by_name: by_name} do
      [{body, guards}] = Map.fetch!(by_name, :simple)
      assert Credo.complexity(body, guards) == 1
    end

    test "boolean ops: debug_info is macro-expanded, inflating Credo", %{by_name: by_name} do
      # debug_info stores post-expansion AST, so `&&`/`||` are nested `case`s.
      # The visitor's case-counting still yields correct classic CC (3), but
      # Credo's per-branch counting over-counts the expanded form (5). This is
      # exactly why the visitor is the default backend.
      [{body, guards}] = Map.fetch!(by_name, :boolean_ops)
      assert Visitor.complexity(body, guards) == 3
      assert Credo.complexity(body, guards) == 5
    end

    test "cond diverges: Credo counts per-branch (clause3 = 4 vs visitor 3)", %{by_name: by_name} do
      # classify clause 3 is the cond; it is the 3rd discovered clause.
      {body, guards} = by_name |> Map.fetch!(:classify) |> Enum.at(2)
      assert Visitor.complexity(body, guards) == 3
      assert Credo.complexity(body, guards) == 4
    end

    test "guard `or` is counted (def f when a or b)", %{by_name: by_name} do
      [{body, guards}] = Map.fetch!(by_name, :guarded)
      assert Visitor.complexity(body, guards) == 2
    end
  end
end
