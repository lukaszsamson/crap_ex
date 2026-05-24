defmodule CrapEx.DiscoveryTest do
  @moduledoc "Gate G1: pin the decoded debug_info shape for the supported Elixir."
  use ExUnit.Case, async: true

  alias CrapEx.{ClauseId, Discovery}
  alias CrapEx.Discovery.DebugInfo

  setup_all do
    {:ok, entries} = Discovery.discover_modules([CrapFixtures.Shapes, CrapFixtures.WithMacro])
    %{entries: entries, ids: Enum.map(entries, fn {id, _} -> id end)}
  end

  defp ids_for(ids, name) do
    ids |> Enum.filter(&(&1.name == name)) |> Enum.sort_by(& &1.clause_index)
  end

  test "discovers all user-defined clauses with correct identity", %{ids: ids} do
    names = ids |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

    assert :one_liner in names
    assert :classify in names
    assert :helper in names
    # synthetic functions are absent
    refute :__info__ in names
    refute :module_info in names
  end

  test "multi-clause functions get sequential 1-based clause indexes", %{ids: ids} do
    classify = ids_for(ids, :classify)
    assert length(classify) == 3
    assert Enum.map(classify, & &1.clause_index) == [1, 2, 3]
    assert Enum.all?(classify, &(&1.arity == 1))
    assert Enum.all?(classify, &(&1.kind == :def))
  end

  test "captures kind for private and macro defs", %{ids: ids} do
    [helper] = ids_for(ids, :helper)
    assert helper.kind == :defp

    [double] = ids_for(ids, :double)
    assert double.kind == :defmacro
    assert ClauseId.macro?(double)
  end

  test "line_start/line_end bound each clause", %{ids: ids} do
    [simple] = ids_for(ids, :simple)
    assert simple.line_start >= 1
    assert simple.line_end >= simple.line_start
    assert simple.file =~ "fixtures.ex"
  end

  test "line_end spans a multi-line clause body (not just the head line)", %{ids: ids} do
    # classify clause 3 is the multi-line cond; its body must extend past the head.
    classify3 = ids_for(ids, :classify) |> Enum.at(2)
    assert classify3.line_end > classify3.line_start
  end

  test "explicit --beams globs bypass project discovery" do
    # Build the path from the compile path (robust under `mix test --cover`, where
    # :code.which/1 returns :cover_compiled rather than a beam path).
    beam = Path.join(Mix.Project.compile_path(), "Elixir.CrapFixtures.Shapes.beam")
    {:ok, entries} = Discovery.discover(CrapEx.Config.new(beams: [beam]))
    names = entries |> Enum.map(fn {id, _} -> id.name end) |> Enum.uniq()
    assert :classify in names
  end

  test "non-Elixir modules are skipped, not fatal" do
    # Erlang modules carry the :erl_abstract_code backend; we only analyze Elixir.
    assert {:error, {:non_elixir_module, :erl_abstract_code}} =
             DebugInfo.__test_decode__(:some_erlang_mod, {:debug_info_v1, :erl_abstract_code, []})
  end

  test "unsupported debug_info shape fails loudly" do
    # __test_decode__/2 exercises the version dispatch without a real beam file.
    assert {:error, {:unsupported_debug_info, _}} =
             DebugInfo.__test_decode__(
               Fake,
               {:debug_info_v1, :elixir_erl, {:elixir_v99, %{}, []}}
             )
  end
end
