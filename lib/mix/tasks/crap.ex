defmodule Mix.Tasks.Crap do
  @shortdoc "Compute the CRAP metric and gate on it"
  @moduledoc """
  Compute the CRAP (Change Risk Anti-Patterns) metric per function and gate CI.

  CRAP needs coverage, and v1 does not run your suite. Produce coverage first:

      mix test --cover --export-coverage crap
      mix crap --coverdata "cover/crap.coverdata"

  ## Options

      --coverdata GLOB     Coverdata file(s) to import (repeatable).
      --no-coverage        Complexity-only: skip coverage, score all as 0% covered.
      --complexity-source S  source (default) | debug_info. `source` measures CC on
                             source AST so macro DSLs (Ecto/HEEX) don't inflate it.
      --min-score N        Fail if any gated function CRAP > N. Default: 30.
      --max-complexity N   Also fail if a gated function CC > N.
      --changed-only REF   Gate only functions whose lines changed vs git REF.
      --baseline FILE      Gate on regressions vs a stored baseline JSON.
      --write-baseline FILE  Write current results as a baseline and exit 0.
      --format FORMAT      table | json | sarif. Default: table. Repeatable.
      --output FILE        Write the (non-table) report to FILE.
      --include-macros     Also gate defmacro/defmacrop (off by default).
      --no-dampen          Don't dampen generated dispatch tables (gate them too).
      --dispatch-threshold N  Min clauses to call a function dispatch (default 10).
      --dispatch-max-clause-cc N  Max per-clause CC for dispatch (default 2; raise
                                  to also dampen lightly-branching generated code).
      --on-no-coverage P   skip | zero for clauses with no executable lines.
      --sort SORT          crap | cc | coverage. Default: crap.
      --paths PATH         Restrict to source under PATH (repeatable). Default: lib.

  Exit codes: `0` pass, `1` gate failure, `2` usage/internal error.
  """
  use Mix.Task

  alias CrapEx.{Baseline, Config, Format, Gate}

  @switches [
    coverdata: :keep,
    min_score: :float,
    max_complexity: :integer,
    changed_only: :string,
    baseline: :string,
    write_baseline: :string,
    format: :keep,
    output: :string,
    include_macros: :boolean,
    on_no_coverage: :string,
    sort: :string,
    explain: :boolean,
    dampen: :boolean,
    dispatch_threshold: :integer,
    dispatch_max_clause_cc: :integer,
    no_coverage: :boolean,
    complexity_source: :string,
    paths: :keep
  ]

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("compile")

    config = build_config(opts)

    case CrapEx.analyze(config) do
      {:ok, report} -> handle_report(report, config, opts)
      {:error, reason} -> abort(reason)
    end
  end

  defp build_config(opts) do
    no_coverage = Keyword.get(opts, :no_coverage, false)

    Config.new(
      coverdata: Keyword.get_values(opts, :coverdata),
      paths: paths(opts),
      min_score: Keyword.get(opts, :min_score, 30),
      max_complexity: opts[:max_complexity],
      changed_only: opts[:changed_only],
      baseline: opts[:baseline],
      include_macros: Keyword.get(opts, :include_macros, false),
      no_coverage: no_coverage,
      complexity_source: complexity_source(opts),
      # In complexity-only mode, score uncovered functions rather than skip them.
      on_no_coverage: if(no_coverage, do: :zero, else: on_no_coverage(opts)),
      sort: sort(opts),
      explain: Keyword.get(opts, :explain, false),
      dampen: Keyword.get(opts, :dampen, true),
      dispatch_threshold: Keyword.get(opts, :dispatch_threshold, 10),
      dispatch_max_clause_cc: Keyword.get(opts, :dispatch_max_clause_cc, 2)
    )
  end

  defp paths(opts) do
    case Keyword.get_values(opts, :paths) do
      [] -> ["lib"]
      paths -> paths
    end
  end

  defp on_no_coverage(opts) do
    case opts[:on_no_coverage] do
      "zero" -> :zero
      _ -> :skip
    end
  end

  defp sort(opts) do
    case opts[:sort] do
      "cc" -> :cc
      "coverage" -> :coverage
      _ -> :crap
    end
  end

  defp complexity_source(opts) do
    case opts[:complexity_source] do
      "debug_info" -> :debug_info
      _ -> :source
    end
  end

  defp handle_report(report, config, opts) do
    warn_join_stats(report)
    warn_diagnostics(report)

    case opts[:write_baseline] do
      nil -> emit_and_gate(report, config, opts)
      file -> write_baseline(report, file)
    end
  end

  # Surface the silent-skip risks GPT flagged: an empty report (stripped
  # debug_info or paths matching nothing) or functions skipped for lack of
  # coverage would otherwise let a gate pass on unmeasured code.
  defp warn_diagnostics(%{functions: []}) do
    Mix.shell().error(
      "crap: no analyzable functions found — is debug_info present and do --paths match? Gate cannot protect anything."
    )
  end

  defp warn_diagnostics(%{functions: functions, config: %{on_no_coverage: :skip}}) do
    skipped = Enum.count(functions, &(&1.crap == :not_applicable))

    if skipped > 0 do
      Mix.shell().error(
        "crap: #{skipped}/#{length(functions)} functions have no coverage data and are NOT gated. " <>
          "Pass --on-no-coverage zero to treat them as uncovered, or check your --coverdata is complete."
      )
    end
  end

  defp warn_diagnostics(_report), do: :ok

  # Source-AST complexity diagnostics. Unmatched clauses (no source `def` — usually
  # templates/generated) are excluded from gating, not scored on inflated CC, so
  # this is informational: it reports source-match coverage so a surprisingly low
  # rate (e.g. a line-metadata regression) is visible.
  defp warn_join_stats(%{join_stats: stats}) when map_size(stats) > 0 do
    total = stats |> Map.values() |> Enum.sum()
    matched = Map.get(stats, :matched_source, 0)

    if total > 0 do
      pct = Float.round(matched / total * 100, 1)
      unmatched = total - matched

      Mix.shell().info(
        "crap: complexity measured from source for #{matched}/#{total} clauses (#{pct}%); " <>
          "#{unmatched} not gated (templates / generated / macro-injected)."
      )
    end
  end

  defp warn_join_stats(_report), do: :ok

  defp write_baseline(report, file) do
    File.write!(file, CrapEx.Format.Json.render(report))
    Mix.shell().info("Wrote baseline to #{file}")
  end

  defp emit_and_gate(report, _config, opts) do
    formats = formats(opts)
    # report.config now carries the resolved --changed-only scope.
    Enum.each(formats, &emit(&1, report, opts[:output]))

    case opts[:baseline] do
      nil -> gate_absolute(report)
      file -> gate_baseline(report, file)
    end
  end

  defp gate_absolute(report) do
    case Gate.check(report, report.config) do
      :ok ->
        Mix.shell().info([:green, "CRAP gate passed", :reset])

      {:fail, violations} ->
        report_violations(violations)
        exit({:shutdown, 1})
    end
  end

  defp gate_baseline(report, file) do
    case Baseline.load(file) do
      {:ok, baseline} ->
        case Baseline.regressions(report, baseline) do
          [] ->
            Mix.shell().info([:green, "CRAP baseline gate passed (no regressions)", :reset])

          regressions ->
            report_regressions(regressions)
            exit({:shutdown, 1})
        end

      {:error, reason} ->
        abort({:baseline_load_failed, file, reason})
    end
  end

  defp formats(opts) do
    case Keyword.get_values(opts, :format) do
      [] -> ["table"]
      fs -> fs
    end
  end

  defp emit("table", report, _output) do
    IO.write(Format.Table.render(report))
  end

  defp emit(format, report, output) do
    rendered = render(format, report)

    case output do
      nil -> IO.write([rendered, "\n"])
      file -> File.write!(file, rendered)
    end
  end

  defp render("json", report), do: Format.Json.render(report)
  defp render("sarif", report), do: Format.Sarif.render(report)
  defp render(other, _report), do: abort({:unknown_format, other})

  defp report_violations(violations) do
    Mix.shell().error("CRAP gate failed — #{length(violations)} violation(s):")

    for v <- violations do
      {m, n, a} = v.mfa

      Mix.shell().error("  #{inspect(m)}.#{n}/#{a}: #{v.kind} #{fmt(v.value)} > #{v.threshold}")
    end
  end

  defp report_regressions(regressions) do
    Mix.shell().error("CRAP baseline gate failed — #{length(regressions)} regression(s):")

    for r <- regressions do
      detail =
        case r.reason do
          :new -> "new function at CRAP #{fmt(r.current)}"
          :worsened -> "CRAP #{fmt(r.previous)} -> #{fmt(r.current)}"
        end

      Mix.shell().error("  #{r.key}: #{detail}")
    end
  end

  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp fmt(v), do: to_string(v)

  @spec abort(term()) :: no_return()
  defp abort(reason) do
    Mix.shell().error("crap: #{inspect(reason)}")
    exit({:shutdown, 2})
  end
end
