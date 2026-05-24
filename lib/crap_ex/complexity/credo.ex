defmodule CrapEx.Complexity.Credo do
  @moduledoc """
  Optional complexity backend wrapping
  `Credo.Check.Refactor.CyclomaticComplexity.complexity_for/1`.

  `complexity_for/1` expects a `def`-form AST, so we wrap the clause body in a
  synthetic zero-arg `def` before delegating. Credo's trivial complexity is 1
  (matching classic CC), but its `case`/`cond` counting differs from the default
  `CrapEx.Complexity.Visitor` (Credo adds +1 *per* branch; the visitor adds
  branches−1). This divergence is intentional and **pinned** by a guard test
  (`CrapEx.Complexity.CredoTest`) so a Credo upgrade that changes counting is
  caught. Credo's semantics are not a stability contract — prefer the visitor
  unless you specifically want parity with your existing Credo config.

  Requires the optional `:credo` dependency; raises a clear error otherwise.
  """

  @behaviour CrapEx.Complexity

  alias Credo.Check.Refactor.CyclomaticComplexity

  @impl true
  @spec complexity(Macro.t(), [Macro.t()]) :: pos_integer()
  def complexity(body, guards) do
    ensure_credo!()
    CyclomaticComplexity.complexity_for(def_ast(body, guards))
  end

  defp def_ast(body, []) do
    {:def, [line: 1], [{:__crap_ex__, [line: 1], []}, [do: body]]}
  end

  defp def_ast(body, guards) when is_list(guards) do
    head =
      Enum.reduce(guards, {:__crap_ex__, [line: 1], []}, fn g, acc ->
        {:when, [line: 1], [acc, g]}
      end)

    {:def, [line: 1], [head, [do: body]]}
  end

  defp ensure_credo! do
    Code.ensure_loaded?(CyclomaticComplexity) ||
      raise """
      The Credo complexity backend requires the optional :credo dependency.
      Add {:credo, "~> 1.7", only: [:dev, :test], runtime: false} to deps.
      """
  end
end
