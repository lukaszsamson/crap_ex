defmodule CrapEx.Discovery.DebugInfo do
  @moduledoc """
  Versioned adapter that decodes Elixir's `debug_info` BEAM chunk into
  `CrapEx.ClauseId` structs plus the per-clause AST (for the complexity stage).

  `:beam_lib.chunks/2` is a stable Erlang API, but the payload it returns for
  Elixir modules — `{:debug_info_v1, :elixir_erl, {:elixir_v1, map, _}}` — is
  Elixir compiler **internal** data with no stability guarantee. We therefore
  match the known shape explicitly and **fail loudly** on anything else, so a
  future Elixir release that changes the schema produces a clear error rather
  than silently wrong scores. See gate G1.
  """

  alias CrapEx.ClauseId

  @typedoc "A discovered clause and its `{body_ast, guard_asts}`, for complexity."
  @type clause_entry :: {ClauseId.t(), {Macro.t(), [Macro.t()]}}

  @doc """
  Read `beam_path` and return `{:ok, [clause_entry]}`, or `{:error, reason}`.

  `reason` is `{:no_debug_info, module}` when the chunk is stripped, or
  `{:unsupported_debug_info, term}` when the payload shape is unrecognized.
  """
  @spec extract(charlist() | String.t()) ::
          {:ok, [clause_entry()]} | {:error, term()}
  def extract(beam_path) do
    path = to_charlist(beam_path)

    case :beam_lib.chunks(path, [:debug_info]) do
      {:ok, {module, [debug_info: debug_info]}} ->
        decode(module, debug_info)

      {:error, :beam_lib, reason} ->
        {:error, {:beam_lib, reason}}
    end
  end

  @doc false
  # Test hook: exercise the version-dispatch logic without a real beam file.
  def __test_decode__(module, debug_info), do: decode(module, debug_info)

  # Known Elixir shape.
  defp decode(module, {:debug_info_v1, :elixir_erl, {:elixir_v1, map, _specs}})
       when is_map(map) do
    file = Map.get(map, :relative_file) || Map.get(map, :file) || ""
    definitions = Map.get(map, :definitions, [])
    {:ok, decode_definitions(module, to_string(file), definitions)}
  end

  defp decode(module, :none), do: {:error, {:no_debug_info, module}}

  # A non-Elixir backend (e.g. :erl_abstract_code for an Erlang module). We only
  # analyze Elixir modules, so this is a skip, not a fatal version mismatch.
  defp decode(_module, {:debug_info_v1, backend, _}) when backend != :elixir_erl do
    {:error, {:non_elixir_module, backend}}
  end

  # An Elixir module (:elixir_erl) whose payload shape we don't recognize: this
  # is a real version mismatch and must fail loudly.
  defp decode(_module, other), do: {:error, {:unsupported_debug_info, summarize(other)}}

  defp decode_definitions(module, file, definitions) do
    definitions
    |> Enum.flat_map(fn {{name, arity}, kind, _meta, clauses} ->
      clauses
      |> Enum.with_index(1)
      |> Enum.map(fn {{clause_meta, args, guards, body}, index} ->
        line_start = line_of(clause_meta)
        # NOTE: a clause is a 4-tuple, which Macro.prewalk treats as an opaque
        # leaf. Walk the parts as a *list* so prewalk descends into the AST and
        # we find the real maximum line (clause_meta carries only the head line).
        line_end = max_line([args, guards, body], line_start)

        id = %ClauseId{
          module: module,
          name: name,
          arity: arity,
          kind: kind,
          clause_index: index,
          file: file,
          line_start: line_start,
          line_end: line_end
        }

        {id, {body, List.wrap(guards)}}
      end)
    end)
  end

  defp line_of(meta) when is_list(meta), do: Keyword.get(meta, :line, 1)
  defp line_of(_), do: 1

  # Walk any AST term collecting the maximum :line metadata seen.
  defp max_line(ast, default) do
    {_, max} =
      Macro.prewalk(ast, default, fn
        {_, meta, _} = node, acc when is_list(meta) ->
          {node, max(acc, Keyword.get(meta, :line, acc))}

        node, acc ->
          {node, acc}
      end)

    max
  end

  defp summarize(term) do
    case term do
      {tag, backend, _} -> {tag, backend}
      other -> other
    end
  end
end
