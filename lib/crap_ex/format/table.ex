defmodule CrapEx.Format.Table do
  @moduledoc """
  Human-readable table output for a `CrapEx.Report`: one row per function sorted
  by the configured key (default CRAP descending), with a summary footer and the
  active deviation notes.
  """

  alias CrapEx.{Metric, Report}

  @spec render(Report.t()) :: iodata()
  def render(%Report{functions: functions, config: config} = report) do
    {unmatched, matched} = Enum.split_with(functions, &(not &1.source_matched))
    {dispatch, scored} = Enum.split_with(matched, & &1.dispatch)
    rows = scored |> sort(config.sort) |> Enum.map(&row/1)
    header = ["FUNCTION", "CC", "COV%", "CRAP"]
    widths = column_widths([header | rows])

    [
      format_row(header, widths),
      separator(widths),
      Enum.map(rows, &format_row(&1, widths)),
      "\n",
      summary(report, scored),
      dispatch_section(dispatch),
      unmatched_section(unmatched),
      explain(report),
      deviations(report.deviations)
    ]
  end

  defp unmatched_section([]), do: []

  defp unmatched_section(unmatched) do
    [
      "\n#{length(unmatched)} function(s) not gated — no source `def` matched ",
      "(templates / generated / macro-injected).\n"
    ]
  end

  defp dispatch_section([]), do: []

  defp dispatch_section(dispatch) do
    listed =
      dispatch
      |> Enum.sort_by(& &1.clauses, :desc)
      |> Enum.take(10)
      |> Enum.map(fn %Metric{id: {m, n, a}} = met ->
        "  #{inspect(m)}.#{n}/#{a} (#{met.clauses} clauses, #{cov_str(met.coverage)}% cov)\n"
      end)

    [
      "\n#{length(dispatch)} generated dispatch table(s) — dampened, not gated",
      " (top by clause count):\n",
      listed
    ]
  end

  defp explain(%Report{config: %{explain: false}}), do: []

  defp explain(%Report{clauses: clauses}) do
    rows =
      clauses
      |> Enum.sort_by(&crap_num/1, :desc)
      |> Enum.map(fn %Metric{id: %CrapEx.ClauseId{} = id} = m ->
        [
          "  ",
          CrapEx.ClauseId.label(id),
          " clause ##{id.clause_index} @ #{id.file}:#{id.line_start}  ",
          "cc=#{m.cc} cov=#{cov_str(m.coverage)} crap=#{crap_str(m.crap)}\n"
        ]
      end)

    ["\nPer-clause breakdown:\n", rows]
  end

  defp sort(functions, :cc), do: Enum.sort_by(functions, & &1.cc, :desc)

  defp sort(functions, :coverage) do
    Enum.sort_by(functions, &coverage_num/1, :asc)
  end

  defp sort(functions, _crap) do
    Enum.sort_by(functions, &crap_num/1, :desc)
  end

  defp crap_num(%Metric{crap: :not_applicable}), do: -1.0
  defp crap_num(%Metric{crap: c}), do: c
  defp coverage_num(%Metric{coverage: :not_applicable}), do: 2.0
  defp coverage_num(%Metric{coverage: c}), do: c

  defp row(%Metric{id: {m, n, a}} = metric) do
    [
      "#{inspect(m)}.#{n}/#{a}",
      Integer.to_string(metric.cc),
      cov_str(metric.coverage),
      crap_str(metric.crap)
    ]
  end

  defp cov_str(:not_applicable), do: "n/a"
  defp cov_str(c), do: :erlang.float_to_binary(c * 100, decimals: 1)

  defp crap_str(:not_applicable), do: "n/a"
  defp crap_str(c), do: :erlang.float_to_binary(c, decimals: 1)

  defp summary(%Report{config: config}, functions) do
    applicable = Enum.reject(functions, &(&1.crap == :not_applicable))
    over = Enum.count(applicable, &(&1.crap > config.min_score))
    worst = applicable |> Enum.map(& &1.crap) |> max_or_zero()

    [
      "#{length(functions)} functions, ",
      "#{over} over CRAP #{config.min_score}, ",
      "worst #{:erlang.float_to_binary(worst, decimals: 1)}\n"
    ]
  end

  defp deviations([]), do: []

  defp deviations(notes) do
    ["\nNotes:\n", Enum.map(notes, &["  - ", &1, "\n"])]
  end

  defp max_or_zero([]), do: 0.0
  defp max_or_zero(list), do: Enum.max(list)

  defp column_widths(rows) do
    rows
    |> Enum.zip_with(& &1)
    |> Enum.map(fn col -> col |> Enum.map(&String.length/1) |> Enum.max() end)
  end

  defp format_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end)
    |> then(&[&1, "\n"])
  end

  defp separator(widths) do
    [widths |> Enum.map_join("  ", &String.duplicate("-", &1)), "\n"]
  end
end
