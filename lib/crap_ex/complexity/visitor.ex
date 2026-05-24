defmodule CrapEx.Complexity.Visitor do
  @moduledoc """
  Default complexity backend: an Elixir-aware AST visitor producing **classic**
  cyclomatic complexity (a trivial clause = 1).

  Decision points counted over a clause's body (and guards):

    * `if`, `unless`              → +1
    * `and`, `or`, `&&`, `||`     → +1 (boolean short-circuit; in body and guards)
    * `case`, `cond`, `receive`   → +1 per branch beyond the first
    * `with`                      → +1 per `<-` match clause
    * `for`                       → +1 per comprehension filter
    * `fn`                        → +1 per clause beyond the first (multi-clause fn)
    * `try`                       → +1 per `rescue`/`catch` clause

  `quote`/`unquote` subtrees are **pruned**: they are code generation, not runtime
  branches of the function being measured. This is what makes the visitor correct
  on **source** ASTs (the default input); on the macro-expanded `debug_info` AST it
  still works because `if`/`&&`/`with` arrive as `case`/`cond`/`try` and the
  branch counting is equivalent.
  """

  @behaviour CrapEx.Complexity

  @bool_ops [:and, :or, :&&, :||]

  @doc "Convenience: complexity of a body with no guards."
  @spec complexity(Macro.t()) :: pos_integer()
  def complexity(body), do: complexity(body, [])

  @impl true
  @spec complexity(Macro.t(), [Macro.t()]) :: pos_integer()
  def complexity(body, guards) do
    1 + count(body) + guard_count(guards)
  end

  # Walk the body counting decision points, but PRUNE `quote`/`unquote` subtrees
  # (Macro.prewalk descends into the node we return, so returning a childless leaf
  # for a quote node stops descent into generated code).
  defp count(ast) do
    {_ast, added} =
      Macro.prewalk(ast, 0, fn
        {q, _, _}, acc when q in [:quote, :unquote, :unquote_splicing] -> {nil, acc}
        node, acc -> visit(node, acc)
      end)

    added
  end

  # Guard complexity: boolean operators in the clause's own guards. Handles both
  # source forms (`and`/`or`/`&&`/`||`) and the expanded `debug_info` forms
  # (`:erlang.andalso` / `:erlang.orelse`), so it is correct in either mode.
  defp guard_count(guards) when is_list(guards) do
    Enum.reduce(guards, 0, fn guard, acc ->
      {_g, n} =
        Macro.prewalk(guard, 0, fn
          {op, _, [_, _]} = node, a when op in @bool_ops ->
            {node, a + 1}

          {{:., _, [:erlang, op]}, _, [_, _]} = node, a when op in [:andalso, :orelse] ->
            {node, a + 1}

          node, a ->
            {node, a}
        end)

      acc + n
    end)
  end

  defp guard_count(_), do: 0

  defp visit({op, _, [_, _]} = node, acc) when op in @bool_ops do
    {node, acc + 1}
  end

  defp visit({op, _, [_ | _]} = node, acc) when op in [:if, :unless] do
    {node, acc + 1}
  end

  defp visit({op, _, args} = node, acc) when op in [:case, :cond] and is_list(args) do
    {node, acc + branches_beyond_first(args)}
  end

  defp visit({:receive, _, args} = node, acc) when is_list(args) do
    # do-clauses are alternative messages; an `after` clause is one more branch.
    extra = branches_beyond_first(args) + if has_key?(args, :after), do: 1, else: 0
    {node, acc + extra}
  end

  defp visit({:with, _, args} = node, acc) when is_list(args) do
    {node, acc + count_match_clauses(args)}
  end

  defp visit({:for, _, args} = node, acc) when is_list(args) do
    {node, acc + comprehension_filters(args)}
  end

  defp visit({:fn, _, clauses} = node, acc) when is_list(clauses) do
    {node, acc + max(length(clauses) - 1, 0)}
  end

  defp visit({:try, _, args} = node, acc) when is_list(args) do
    {node, acc + try_branches(args)}
  end

  # Anything else — including a *variable* whose name happens to be `case`,
  # `cond`, `with`, `try`, etc. (third element is a context atom/nil, not a list).
  defp visit(node, acc), do: {node, acc}

  # case/cond/receive carry their branches in a trailing `[do: [-> clauses]]`.
  defp branches_beyond_first(args) do
    case clauses_in(args, :do) do
      [] -> 0
      clauses -> length(clauses) - 1
    end
  end

  defp count_match_clauses(args) do
    Enum.count(args, &match?({:<-, _, [_, _]}, &1))
  end

  # `for` filters are positional args that are neither generators (`<-`/`<<>>`)
  # nor the trailing options keyword list.
  defp comprehension_filters(args) do
    {positional, _opts} =
      case List.last(args) do
        kw when is_list(kw) -> Enum.split(args, length(args) - 1)
        _ -> {args, []}
      end

    Enum.count(positional, fn
      {:<-, _, _} -> false
      {:<<>>, _, _} -> false
      _ -> true
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

  defp has_key?(args, key) do
    case List.last(args) do
      kw when is_list(kw) -> Keyword.has_key?(kw, key)
      _ -> false
    end
  end

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
