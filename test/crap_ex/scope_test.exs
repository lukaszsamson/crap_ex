defmodule CrapEx.ScopeTest do
  @moduledoc "Gate G6: --changed-only narrows the gated set to touched functions."
  use ExUnit.Case, async: false

  alias CrapEx.{ClauseId, Config, Scope}

  @relpath "lib/sample.ex"

  @source """
  defmodule Sample do
    def a(x) do
      x + 1
    end

    def b(x) do
      x + 2
    end

    def c(x) do
      x + 3
    end
  end
  """

  defp clause(name, ls, le) do
    id = %ClauseId{
      module: Sample,
      name: name,
      arity: 1,
      kind: :def,
      clause_index: 1,
      file: @relpath,
      line_start: ls,
      line_end: le
    }

    {id, :body_ast}
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "crap_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "lib"))
    git = fn args -> {_, 0} = System.cmd("git", args, cd: tmp, stderr_to_stdout: true) end

    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])
    File.write!(Path.join(tmp, @relpath), @source)
    git.(["add", "."])
    git.(["commit", "-qm", "init"])

    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "only the modified function is in scope", %{tmp: tmp} do
    # Change b/1's body (line 7).
    new = String.replace(@source, "x + 2", "x + 2 + 0")
    File.write!(Path.join(tmp, @relpath), new)

    entries = [clause(:a, 2, 4), clause(:b, 6, 8), clause(:c, 10, 12)]
    config = Config.new(changed_only: "HEAD")

    {:ok, scope} = File.cd!(tmp, fn -> Scope.resolve(entries, config) end)

    assert scope == MapSet.new([{Sample, :b, 1}])
  end

  test "nil scope when changed_only is not set" do
    assert {:ok, nil} = Scope.resolve([clause(:a, 2, 4)], Config.new())
  end
end
