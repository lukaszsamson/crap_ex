defmodule CrapEx.ClauseId do
  @moduledoc """
  Identity of a single function/macro clause as discovered from compiled
  `debug_info` (or, in fallback mode, from source).

  `clause_index` is **1-based** to match the clause numbering used by Erlang's
  `:cover` (`:cover.analyse(mod, :coverage, :clause)` returns
  `{{Module, Name, Arity, ClauseIndex}, {Cov, NotCov}}`). Keeping the same base
  is what makes the coverage join in `CrapEx.Score` correct.
  """

  @type kind :: :def | :defp | :defmacro | :defmacrop

  @type t :: %__MODULE__{
          module: module(),
          name: atom(),
          arity: arity(),
          kind: kind(),
          clause_index: pos_integer(),
          file: String.t(),
          abs_file: String.t() | nil,
          line_start: pos_integer(),
          line_end: pos_integer()
        }

  @enforce_keys [:module, :name, :arity, :kind, :clause_index, :file, :line_start, :line_end]
  defstruct [
    :module,
    :name,
    :arity,
    :kind,
    :clause_index,
    :file,
    # Absolute source path (from debug_info `:file`), used to read source for
    # source-AST complexity; `file` stays relative for display/filtering.
    :abs_file,
    :line_start,
    :line_end
  ]

  @doc "The `{module, name, arity}` key this clause aggregates into."
  @spec mfa(t()) :: {module(), atom(), arity()}
  def mfa(%__MODULE__{module: m, name: n, arity: a}), do: {m, n, a}

  @doc "True if this clause is a macro definition (`defmacro`/`defmacrop`)."
  @spec macro?(t()) :: boolean()
  def macro?(%__MODULE__{kind: kind}), do: kind in [:defmacro, :defmacrop]

  @doc "Human-readable label, e.g. `MyMod.foo/2`."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{module: m, name: n, arity: a}) do
    "#{inspect(m)}.#{n}/#{a}"
  end
end
