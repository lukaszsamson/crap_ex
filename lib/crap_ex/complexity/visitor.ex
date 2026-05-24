defmodule CrapEx.Complexity.Visitor do
  @moduledoc """
  Default complexity backend: an Elixir-aware AST visitor producing **classic**
  cyclomatic complexity (a trivial clause = 1).

  Decision points counted (each over the clause body AST):

    * `if`, `unless`            → +1
    * `and`, `or`, `&&`, `||`   → +1 (boolean short-circuit)
    * `case`, `cond`            → +1 per branch beyond the first
    * `with`                    → +1 per `<-` match clause (each can fail through)
    * `try`                     → +1 per `rescue`/`catch` clause

  `for` comprehension filters are not yet counted (documented limitation); the
  default reflects only the base path plus the operators above.

  > Note: clause bodies from `CrapEx.Discovery` come from `debug_info`, which
  > stores the **macro-expanded** AST. There `if`/`unless`/`&&`/`||`/`with` are
  > already rewritten into `case`/`cond`/`try`, so in practice the `case`/`cond`
  > counting carries the weight. A 2-branch `case` adds +1 — exactly what the
  > original `if`/boolean operator would have added — so classic CC is preserved.
  > The explicit operator clauses below still matter for the source-AST fallback.
  """

  @behaviour CrapEx.Complexity

  @doc "Convenience: complexity of a body with no guards."
  @spec complexity(Macro.t()) :: pos_integer()
  def complexity(body), do: complexity(body, [])

  @impl true
  @spec complexity(Macro.t(), [Macro.t()]) :: pos_integer()
  def complexity(body, guards) do
    1 + count(body) + guard_count(guards)
  end

  defp count(ast) do
    {_ast, added} = Macro.prewalk(ast, 0, &visit/2)
    added
  end

  # Guard complexity, counted over the clause's *own* guard expressions only
  # (not body-internal `&&`/`in` expansions). In debug_info, guard `or`/`and`/`in`
  # appear as `:erlang.orelse` / `:erlang.andalso`; each is one decision point.
  defp guard_count(guards) when is_list(guards) do
    Enum.reduce(guards, 0, fn guard, acc ->
      {_g, n} =
        Macro.prewalk(guard, 0, fn
          {{:., _, [:erlang, op]}, _, [_, _]} = node, a when op in [:andalso, :orelse] ->
            {node, a + 1}

          node, a ->
            {node, a}
        end)

      acc + n
    end)
  end

  defp guard_count(_), do: 0

  defp visit({op, _, [_, _]} = node, acc) when op in [:and, :or, :&&, :||] do
    {node, acc + 1}
  end

  defp visit({op, _, [_ | _]} = node, acc) when op in [:if, :unless] do
    {node, acc + 1}
  end

  defp visit({op, _, args} = node, acc) when op in [:case, :cond] and is_list(args) do
    {node, acc + branches_beyond_first(args)}
  end

  defp visit({:with, _, args} = node, acc) when is_list(args) do
    {node, acc + count_match_clauses(args)}
  end

  defp visit({:try, _, args} = node, acc) when is_list(args) do
    {node, acc + try_branches(args)}
  end

  # Anything else — including a *variable* whose name happens to be `case`,
  # `cond`, `with`, `try`, etc. (where the third element is a context atom or
  # nil, not an argument list) — contributes no branches.
  defp visit(node, acc), do: {node, acc}

  # case/cond carry their branches in a trailing `[do: [-> clauses]]` keyword.
  defp branches_beyond_first(args) do
    case clauses_in(args, :do) do
      [] -> 0
      clauses -> length(clauses) - 1
    end
  end

  defp count_match_clauses(args) do
    Enum.count(args, fn
      {:<-, _, [_, _]} -> true
      _ -> false
    end)
  end

  defp try_branches(args) do
    case List.last(args) do
      kw when is_list(kw) ->
        clause_count(Keyword.get(kw, :rescue)) + clause_count(Keyword.get(kw, :catch))

      _ ->
        0
    end
  end

  defp clause_count(clauses) when is_list(clauses), do: length(clauses)
  defp clause_count(_), do: 0

  defp clauses_in(args, key) do
    case List.last(args) do
      kw when is_list(kw) ->
        case Keyword.get(kw, key) do
          clauses when is_list(clauses) -> clauses
          _ -> []
        end

      _ ->
        []
    end
  end
end
