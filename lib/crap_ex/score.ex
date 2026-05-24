defmodule CrapEx.Score do
  @moduledoc """
  The CRAP metric kernel.

      CRAP(m) = CC(m)² · (1 − cov(m))³ + CC(m)

  where `CC` is cyclomatic complexity (>= 1) and `cov ∈ [0.0, 1.0]` is the
  fraction of executable lines in the unit that were covered by tests.

  This module is pure: no I/O, no coupling to discovery or coverage. It builds
  `CrapEx.Metric` structs from a complexity integer and a coverage observation,
  and aggregates clause metrics into per-function metrics.
  """

  alias CrapEx.Metric

  @typedoc """
  Coverage observation for a unit, as produced from `:cover` clause/function
  analysis: `{covered_lines, not_covered_lines}`. `{0, 0}` means the unit has no
  executable lines and coverage is undefined (`:not_applicable`).
  """
  @type coverage_obs :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Compute the CRAP score from cyclomatic complexity and a coverage fraction.

  `cov` is clamped into `[0.0, 1.0]`.

  ## Examples

      iex> CrapEx.Score.crap(1, 1.0)
      1.0

      iex> CrapEx.Score.crap(5, 0.0)
      30.0

      iex> CrapEx.Score.crap(5, 1.0)
      5.0
  """
  @spec crap(pos_integer(), float()) :: float()
  def crap(cc, cov) when is_integer(cc) and cc >= 1 and is_number(cov) do
    c = clamp(cov)
    cc * cc * :math.pow(1.0 - c, 3) + cc
  end

  @doc """
  Build a `CrapEx.Metric` for a unit from its complexity and coverage
  observation.

  When the observation is `{0, 0}` (no executable lines), coverage and crap are
  `:not_applicable` — the unit is excluded from gating by default.
  """
  @typedoc """
  Policy for a unit with no executable lines (`{0, 0}`), e.g. a clause absent
  from the imported coverdata: `:skip` → `:not_applicable` (not gated);
  `:zero` → treated as 0% covered (gated at worst case).
  """
  @type on_no_coverage :: :skip | :zero

  @spec metric(Metric.id(), pos_integer(), coverage_obs(), on_no_coverage()) :: Metric.t()
  def metric(id, cc, obs, policy \\ :skip)

  def metric(id, cc, {covered, not_covered}, policy)
      when is_integer(cc) and cc >= 1 and is_integer(covered) and is_integer(not_covered) do
    relevant = covered + not_covered

    {coverage, crap} =
      case {relevant, policy} do
        {0, :zero} ->
          {0.0, crap(cc, 0.0)}

        {0, _} ->
          {:not_applicable, :not_applicable}

        {n, _} ->
          cov = covered / n
          {cov, crap(cc, cov)}
      end

    %Metric{
      id: id,
      cc: cc,
      covered_lines: covered,
      relevant_lines: relevant,
      coverage: coverage,
      crap: crap
    }
  end

  @doc """
  Aggregate per-clause metrics belonging to the same `{module, name, arity}`
  into a single function-level metric.

  Classic multi-clause CC is additive across clauses; coverage is recomputed
  from the summed covered/relevant line counts (equivalent to what
  `:cover.analyse(mod, :coverage, :function)` reports). If every clause is
  `:not_applicable` (no executable lines anywhere), the function is too.
  """
  @typedoc """
  Aggregation options: `:policy` (`on_no_coverage`, default `:skip`); `:dampen`
  (treat pure-dispatch functions specially, default `false`); `:dispatch_threshold`
  (min trivial-clause count to qualify as dispatch, default 10).
  """
  @type agg_opts :: [
          policy: on_no_coverage(),
          dampen: boolean(),
          dispatch_threshold: pos_integer(),
          dispatch_max_clause_cc: pos_integer()
        ]

  @spec aggregate([Metric.t()], agg_opts()) :: Metric.t()
  def aggregate([%Metric{} | _] = clause_metrics, opts \\ []) do
    policy = Keyword.get(opts, :policy, :skip)
    dampen = Keyword.get(opts, :dampen, false)
    threshold = Keyword.get(opts, :dispatch_threshold, 10)
    max_clause_cc = Keyword.get(opts, :dispatch_max_clause_cc, 2)

    mfa = mfa_of(hd(clause_metrics))
    clauses = length(clause_metrics)
    cc = clause_metrics |> Enum.map(& &1.cc) |> Enum.sum()
    covered = clause_metrics |> Enum.map(& &1.covered_lines) |> Enum.sum()
    relevant = clause_metrics |> Enum.map(& &1.relevant_lines) |> Enum.sum()

    # Generated dispatch table: many clauses, each uniformly low-complexity (no
    # clause has real branching). A function with any genuinely complex clause
    # (cc > max_clause_cc) is NOT dispatch and stays gated. Dispatch tables are
    # scored with a dampened effective complexity of 1, but keep their real `cc`
    # and are surfaced in a separate report section.
    dispatch? =
      dampen and clauses > threshold and Enum.all?(clause_metrics, &(&1.cc <= max_clause_cc))

    effective_cc = if dispatch?, do: 1, else: cc
    # A function is source-trusted if at least one clause's CC came from source;
    # fully-unmatched functions (templates, generated) are not gated.
    source_matched? = Enum.any?(clause_metrics, & &1.source_matched)

    base = metric(mfa, effective_cc, {covered, relevant - covered}, policy)
    %{base | cc: cc, clauses: clauses, dispatch: dispatch?, source_matched: source_matched?}
  end

  @doc """
  Group clause metrics by `{module, name, arity}` and aggregate each group.
  Preserves first-seen order of functions. See `t:agg_opts/0`.
  """
  @spec aggregate_all([Metric.t()], agg_opts()) :: [Metric.t()]
  def aggregate_all(clause_metrics, opts \\ []) do
    clause_metrics
    |> Enum.group_by(&mfa_of/1)
    |> Enum.map(fn {_mfa, metrics} -> aggregate(metrics, opts) end)
    |> Enum.sort_by(fn %Metric{id: {m, n, a}} -> {to_string(m), to_string(n), a} end)
  end

  defp mfa_of(%Metric{id: %CrapEx.ClauseId{} = id}), do: CrapEx.ClauseId.mfa(id)
  defp mfa_of(%Metric{id: {_, _, _} = mfa}), do: mfa

  defp clamp(cov) when cov < 0.0, do: 0.0
  defp clamp(cov) when cov > 1.0, do: 1.0
  defp clamp(cov), do: cov
end
