defmodule CrapFixtures.Shapes do
  @moduledoc """
  A matrix of clause shapes for discovery/complexity/coverage gates (G1–G4).

  Each function's expected **classic** cyclomatic complexity (trivial clause = 1,
  multi-clause summed) is documented next to it; `CrapEx.Complexity.VisitorTest`
  asserts these exact numbers.
  """

  # cc: 1 (one-liner; arity 2; body `a + b` IS one executable line under :cover)
  def one_liner(a, b), do: a + b

  # cc: 1 (single clause, one executable body line)
  def simple(x) do
    x * 2
  end

  # cc: 1 + 1 + 3 = 5  (clause1=1, clause2=1, clause3 has cond with 3 branches=3)
  def classify(n) when n < 0, do: :neg
  def classify(0), do: :zero

  def classify(n) do
    cond do
      n > 100 -> :big
      n > 10 -> :med
      true -> :small
    end
  end

  # cc: 1 + 1 (case with 2 branches adds 1) = 2
  def with_case(x) do
    case x do
      :a -> 1
      _ -> 2
    end
  end

  # cc: 1 + 1 (if) = 2
  def with_if(x) do
    if x > 0, do: :pos, else: :nonpos
  end

  # cc: 1 + 1 (&&) + 1 (||) = 3
  def boolean_ops(a, b, c) do
    (a && b) || c
  end

  # cc: base 1 + with-else adds 1 = 2
  def with_expr(map) do
    with {:ok, v} <- Map.fetch(map, :k) do
      v
    else
      :error -> :missing
    end
  end

  # cc: base 1 + anonymous fn body branch (if) folded in = 2
  def anon_fn(list) do
    Enum.map(list, fn x -> if x > 0, do: x, else: 0 end)
  end

  # cc: 1 base + 1 (guard `or` -> :erlang.orelse) = 2
  def guarded(x) when is_integer(x) or is_binary(x), do: x

  # cc: 1 (private, one executable body line)
  defp helper(x), do: x + 1

  # cc: 1
  def use_helper(x), do: helper(x)
end

defmodule CrapFixtures.WithMacro do
  @moduledoc "A macro fixture; gated only under --include-macros."

  # macro, cc: 1
  defmacro double(x) do
    quote do: unquote(x) * 2
  end
end
