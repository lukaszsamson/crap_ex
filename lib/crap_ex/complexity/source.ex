defmodule CrapEx.Complexity.Source do
  @moduledoc """
  Extracts function clauses from **source** files for source-AST complexity.

  Compiled `debug_info` stores the macro-*expanded* AST, which inflates cyclomatic
  complexity for compile-time DSLs (Ecto `from/where`, Phoenix `~H`) — a 26-LOC
  query can score CC 1000+. The source AST has those as opaque macro calls, so
  complexity reflects the code as written.

  This module builds an index of source clauses keyed by `{name, arity}` per file,
  each carrying its head line so the facade can join it to a discovered
  (`debug_info`) clause by `{abs_file, name, arity, line}`. We deliberately do
  **not** resolve module names from source (which would require alias/`defimpl`
  resolution): matching within a file by name/arity/line is sufficient and handles
  `defimpl`/`defprotocol`/nested modules correctly, since each clause has a unique
  head line.

  Skipped during extraction (these have no countable runtime body to attach):

    * `quote`/`unquote` subtrees — code generation, not the function's branches.
    * Bodyless heads (`def f(x, y \\\\ 5)` default declarations, protocol stubs) —
      no `do:` block; they must not consume a clause slot.
  """

  @kinds [:def, :defp, :defmacro, :defmacrop]

  @typedoc "A source clause: head line/column plus body and guards for counting."
  @type clause :: %{
          line: pos_integer(),
          column: pos_integer() | nil,
          body: Macro.t(),
          guards: [Macro.t()]
        }

  @typedoc "Per-file index: {name, arity} => clauses in textual order."
  @type file_index :: %{{atom(), arity()} => [clause()]}

  @doc "Build `%{abs_file => file_index}` for the given source files (parsed once each)."
  @spec index([String.t()]) :: %{String.t() => file_index()}
  def index(files) do
    files
    |> Enum.uniq()
    |> Map.new(fn file -> {file, clauses_in_file(file)} end)
  end

  @doc """
  Look up the source clause for a discovered `{abs_file, name, arity, line}`.
  Returns `{:ok, {body, guards}}` (caller computes CC via the chosen backend) or
  `{:miss, reason}` with reason `:no_source_file` / `:no_clause` / `:ambiguous` —
  the caller then falls back to the debug_info CC.
  """
  @spec lookup(%{String.t() => file_index()}, String.t() | nil, atom(), arity(), pos_integer()) ::
          {:ok, {Macro.t(), [Macro.t()]}} | {:miss, atom()}
  def lookup(_index, nil, _name, _arity, _line), do: {:miss, :no_source_file}

  def lookup(index, abs_file, name, arity, line) do
    with %{} = file_index <- Map.get(index, abs_file, :missing_file),
         clauses when is_list(clauses) <- Map.get(file_index, {name, arity}) do
      resolve(clauses, line)
    else
      :missing_file -> {:miss, :no_source_file}
      nil -> {:miss, :no_clause}
    end
  end

  # Prefer an exact head-line match (robust across multiple same-named functions in
  # one file). If exactly one clause exists for the mfa, accept it even if the line
  # drifted. Otherwise it is ambiguous → fall back.
  defp resolve(clauses, line) do
    case Enum.filter(clauses, &(&1.line == line)) do
      [clause] ->
        {:ok, {clause.body, clause.guards}}

      [] ->
        if match?([_], clauses),
          do: {:ok, {hd(clauses).body, hd(clauses).guards}},
          else: {:miss, :no_clause}

      _many ->
        {:miss, :ambiguous}
    end
  end

  # Reading project source files to measure complexity is the whole point.
  # sobelow_skip ["Traversal.FileModule"]
  defp clauses_in_file(file) do
    with {:ok, src} <- File.read(file),
         {:ok, ast} <- string_to_quoted(src) do
      ast
      |> collect()
      |> Enum.group_by(&{&1.name, &1.arity}, &Map.take(&1, [:line, :column, :body, :guards]))
    else
      _ -> %{}
    end
  end

  defp string_to_quoted(src) do
    Code.string_to_quoted(src, columns: true, token_metadata: true, emit_warnings: false)
  end

  defp collect(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        # Prune code-generation subtrees: defs inside them are templates, not
        # clauses of the enclosing module.
        {q, _, _}, acc when q in [:quote, :unquote, :unquote_splicing] ->
          {nil, acc}

        {kind, meta, [head, kw]} = node, acc when kind in @kinds and is_list(kw) ->
          case extract_clause(meta, head, kw) do
            nil -> {node, acc}
            clause -> {node, [clause | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # Only clauses with an actual `do:` body; bodyless heads are skipped.
  defp extract_clause(meta, head, kw) do
    if Keyword.has_key?(kw, :do) do
      {name, arity, guards} = parse_head(head)

      if name do
        %{
          name: name,
          arity: arity,
          line: Keyword.get(meta, :line, 0),
          column: Keyword.get(meta, :column),
          body: Keyword.fetch!(kw, :do),
          guards: guards
        }
      end
    end
  end

  defp parse_head({:when, _, [call, guard]}), do: with_guard(parse_call(call), guard)
  defp parse_head(call), do: with_guard(parse_call(call), nil)

  defp with_guard({name, arity}, nil), do: {name, arity, []}
  defp with_guard({name, arity}, guard), do: {name, arity, [guard]}

  defp parse_call({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp parse_call({name, _, _}) when is_atom(name), do: {name, 0}
  defp parse_call(_), do: {nil, 0}
end
