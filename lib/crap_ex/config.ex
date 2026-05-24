defmodule CrapEx.Config do
  @moduledoc """
  Resolved configuration for an analysis/gate run, built from CLI options or a
  keyword list. See `CrapEx.Mix.Tasks.Crap` for the CLI surface.
  """

  @type on_no_coverage :: :skip | :zero

  @type t :: %__MODULE__{
          paths: [String.t()],
          coverdata: [String.t()],
          min_score: number(),
          max_complexity: pos_integer() | nil,
          changed_only: String.t() | nil,
          baseline: String.t() | nil,
          include_macros: boolean(),
          on_no_coverage: on_no_coverage(),
          complexity_backend: module(),
          sort: :crap | :cc | :coverage,
          scope: MapSet.t() | nil,
          explain: boolean(),
          dampen: boolean(),
          dispatch_threshold: pos_integer(),
          dispatch_max_clause_cc: pos_integer()
        }

  defstruct paths: ["lib"],
            coverdata: [],
            min_score: 30,
            max_complexity: nil,
            changed_only: nil,
            baseline: nil,
            include_macros: false,
            on_no_coverage: :skip,
            complexity_backend: CrapEx.Complexity.Visitor,
            sort: :crap,
            scope: nil,
            explain: false,
            # Dampen macro-generated dispatch tables (many all-trivial clauses)
            # so their CRAP does not dominate; still reported separately.
            dampen: true,
            dispatch_threshold: 10,
            dispatch_max_clause_cc: 2

  @doc "Build a config from a keyword list, applying defaults."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
