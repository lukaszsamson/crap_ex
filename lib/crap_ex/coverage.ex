defmodule CrapEx.Coverage do
  @moduledoc """
  Load test coverage from exported `.coverdata` and produce per-clause coverage
  observations keyed by `{module, name, arity, clause_index}`.

  Coverage comes from Erlang's `:cover` clause-level analysis
  (`:cover.analyse(mod, :coverage, :clause)` → `{{M,N,A,Idx}, {Cov, NotCov}}`),
  **not** from intersecting executable lines with inferred AST ranges. `:cover`
  already knows which executable lines belong to which clause, which removes the
  hardest correctness problem.

  v1 does not run the suite; the caller runs
  `mix test --cover --export-coverage <name>` first and points `--coverdata` at
  the resulting file(s). `:cover.import/1` merges data across multiple files
  (e.g. partitioned CI runs).
  """

  alias CrapEx.{ClauseId, Config, Discovery}

  @typedoc "covered_lines / not_covered_lines for a clause"
  @type obs :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Load clause-level coverage for the modules present in `entries`.

  Returns `{:ok, %{{m,n,a,idx} => obs}}`. Modules with no imported data simply
  contribute nothing (those clauses later default to `{0, 0}` → not_applicable).
  """
  @spec load(Config.t(), [Discovery.entry()]) :: {:ok, %{tuple() => obs()}} | {:error, term()}
  def load(%Config{coverdata: globs}, entries) do
    with {:ok, files} <- expand(globs),
         :ok <- import_all(files) do
      modules = entries |> Enum.map(fn {%ClauseId{module: m}, _} -> m end) |> Enum.uniq()
      {:ok, analyse_clauses(modules)}
    end
  end

  @doc """
  Analyse clause coverage for the given modules from the *current* `:cover`
  state (data already imported or cover-compiled). Useful for tests that drive
  `:cover` directly. Returns the clause-keyed observation map.
  """
  @spec analyse_clauses([module()]) :: %{tuple() => obs()}
  def analyse_clauses(modules) do
    # :cover prints "Analysis includes data from imported files" to the group
    # leader on every analyse call when imported data is present; silence it.
    silence(fn ->
      modules
      |> Enum.flat_map(&analyse_module/1)
      |> Map.new(fn {{m, n, a, idx}, {cov, not_cov}} -> {{m, n, a, idx}, {cov, not_cov}} end)
    end)
  end

  defp analyse_module(module) do
    case :cover.analyse(module, :coverage, :clause) do
      {:ok, results} -> results
      {:error, _} -> []
    end
  end

  # :cover emits the "Analysis includes data from imported files" notice from
  # the :cover_server process, so we redirect *its* group leader (and ours) to a
  # throwaway sink for the duration of the call.
  defp silence(fun) do
    {:ok, sink} = StringIO.open("")
    targets = [self(), Process.whereis(:cover_server)] |> Enum.filter(& &1)
    olds = Enum.map(targets, fn pid -> {pid, Process.info(pid, :group_leader)} end)
    Enum.each(targets, &Process.group_leader(&1, sink))

    try do
      fun.()
    after
      for {pid, {:group_leader, gl}} <- olds, Process.alive?(pid) do
        Process.group_leader(pid, gl)
      end

      StringIO.close(sink)
    end
  end

  defp expand(globs) do
    files = globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq()

    case {globs, files} do
      {[], _} -> {:error, :no_coverdata_specified}
      {_, []} -> {:error, {:no_coverdata_files, globs}}
      {_, files} -> {:ok, files}
    end
  end

  defp import_all(files) do
    ensure_started()
    :cover.reset()

    Enum.reduce_while(files, :ok, fn file, :ok ->
      case :cover.import(to_charlist(file)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:import_failed, file, reason}}}
      end
    end)
  end

  defp ensure_started do
    case :cover.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
