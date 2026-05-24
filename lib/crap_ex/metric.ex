defmodule CrapEx.Metric do
  @moduledoc """
  A computed CRAP metric for a single unit — either one clause
  (`id` is a `CrapEx.ClauseId`) or an aggregated function
  (`id` is a `{module, name, arity}` tuple).

  `coverage` and `crap` are `:not_applicable` when the unit has no executable
  lines (`:cover` reported `{0, 0}`); see `CrapEx.Score`.
  """

  @type id :: CrapEx.ClauseId.t() | {module(), atom(), arity()}

  @type t :: %__MODULE__{
          id: id(),
          cc: pos_integer(),
          clauses: pos_integer(),
          dispatch: boolean(),
          covered_lines: non_neg_integer(),
          relevant_lines: non_neg_integer(),
          coverage: float() | :not_applicable,
          crap: float() | :not_applicable
        }

  @enforce_keys [:id, :cc, :covered_lines, :relevant_lines, :coverage, :crap]
  defstruct [
    :id,
    :cc,
    :covered_lines,
    :relevant_lines,
    :coverage,
    :crap,
    clauses: 1,
    # `dispatch: true` marks a macro-generated dispatch table — many trivial
    # (CC 1) clauses, e.g. an HTTP-status or timezone lookup. Its CRAP is scored
    # with a dampened effective complexity so generated code does not dominate.
    dispatch: false
  ]
end
