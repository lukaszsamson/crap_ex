defmodule CrapEx.SourceTest do
  @moduledoc "Source-AST complexity extraction, quote-pruning, and the join."
  use ExUnit.Case, async: true

  alias CrapEx.Complexity.{Source, Visitor}
  alias CrapEx.Discovery

  @fixture CrapFixtures.Shapes

  setup_all do
    {:ok, entries} = Discovery.discover_modules([@fixture])

    abs =
      entries |> Enum.map(fn {id, _} -> id.abs_file end) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{entries: entries, index: Source.index(abs)}
  end

  test "discovery captures absolute source path", %{entries: entries} do
    {id, _} = hd(entries)
    assert is_binary(id.abs_file)
    assert File.exists?(id.abs_file)
  end

  test "lookup matches a source clause by file/name/arity/line", %{entries: entries, index: index} do
    {id, _} = Enum.find(entries, fn {id, _} -> id.name == :classify and id.clause_index == 3 end)
    assert {:ok, {body, guards}} = Source.lookup(index, id.abs_file, :classify, 1, id.line_start)
    # classify clause 3 is the cond with 3 branches -> CC 3 on source too.
    assert Visitor.complexity(body, guards) == 3
  end

  test "quote subtrees are pruned (the if inside quote does not count)", %{
    entries: entries,
    index: index
  } do
    {id, _} = Enum.find(entries, fn {id, _} -> id.name == :builds_ast end)

    assert {:ok, {body, guards}} =
             Source.lookup(index, id.abs_file, :builds_ast, 1, id.line_start)

    assert Visitor.complexity(body, guards) == 1
  end

  test "Visitor prunes quote directly" do
    ast = quote(do: if(x, do: 1, else: 2))
    quoted = {:quote, [], [[do: ast]]}
    assert Visitor.complexity(ast) == 2
    assert Visitor.complexity(quoted) == 1
  end

  test "miss returns a reason when no source clause matches", %{index: index} do
    assert {:miss, _} = Source.lookup(index, "/nonexistent.ex", :foo, 1, 1)
  end
end
