defmodule CrapEx.Complexity do
  @moduledoc """
  Behaviour for cyclomatic-complexity backends.

  A backend receives the **body AST and guard list of a single clause** (as
  produced by `CrapEx.Discovery`) and returns its classic cyclomatic complexity,
  where a trivial clause has complexity 1. Guards carry branching logic
  (`when ... or ...`) and are counted separately from the body.

  Implementations:

    * `CrapEx.Complexity.Visitor` — the default, an Elixir-aware AST visitor.
    * `CrapEx.Complexity.Credo`  — optional, wraps Credo's checker (normalized).
  """

  @callback complexity(body :: Macro.t(), guards :: [Macro.t()]) :: pos_integer()
end
