# Compare debug_info CC vs source CC across compiled projects, to measure the
# macro/DSL false-positive reduction. Reads source via the abs_file in debug_info,
# so it needs no dep injection into the target projects.
#
#   BUGHUNT_ROOTS=/path/a:/path/b MIX_ENV=dev mix run bughunt_compare.exs

alias CrapEx.Discovery.DebugInfo
alias CrapEx.Complexity.{Source, Visitor}

roots = System.get_env("BUGHUNT_ROOTS", "") |> String.split(":", trim: true)

beams =
  roots
  |> Enum.flat_map(&Path.wildcard(Path.join(&1, "_build/*/lib/*/ebin/*.beam")))
  |> Enum.uniq()

# Collect every clause with its debug body, abs_file, name/arity/line.
clauses =
  Enum.flat_map(beams, fn beam ->
    case DebugInfo.extract(beam) do
      {:ok, entries} -> entries
      _ -> []
    end
  end)

abs_files = clauses |> Enum.map(fn {id, _} -> id.abs_file end) |> Enum.reject(&is_nil/1) |> Enum.uniq()
index = Source.index(abs_files)

# Per-clause: {key, debug_cc, source_cc_or_nil, status}
rows =
  Enum.map(clauses, fn {id, {dbg_body, dbg_guards}} ->
    debug_cc = Visitor.complexity(dbg_body, dbg_guards)

    {source_cc, status} =
      case Source.lookup(index, id.abs_file, id.name, id.arity, id.line_start) do
        {:ok, {b, g}} -> {Visitor.complexity(b, g), :matched}
        {:miss, r} -> {nil, r}
      end

    {{id.module, id.name, id.arity}, debug_cc, source_cc, status}
  end)

# Aggregate to function level (sum clause CCs) for matched clauses.
funs =
  rows
  |> Enum.group_by(fn {k, _, _, _} -> k end)
  |> Enum.map(fn {k, rs} ->
    dbg = rs |> Enum.map(fn {_, d, _, _} -> d end) |> Enum.sum()
    matched = Enum.filter(rs, fn {_, _, s, _} -> s != nil end)
    src = if matched == [], do: nil, else: matched |> Enum.map(fn {_, _, s, _} -> s end) |> Enum.sum()
    {k, dbg, src}
  end)

total = length(rows)
statuses = rows |> Enum.frequencies_by(fn {_, _, _, s} -> s end)

IO.puts("\n=== CC SOURCE-vs-DEBUG COMPARISON ===")
IO.puts("clauses: #{total}  join: #{inspect(statuses)}")

# Biggest inflation fixes: debug_cc high, source_cc low.
IO.puts("\n--- Top 15 inflation reductions (debug CC -> source CC) ---")
funs
|> Enum.filter(fn {_, d, s} -> s != nil and d - s > 0 end)
|> Enum.sort_by(fn {_, d, s} -> -(d - s) end)
|> Enum.take(15)
|> Enum.each(fn {{m, n, a}, d, s} ->
  IO.puts("  #{inspect(m)}.#{n}/#{a}: #{d} -> #{s}")
end)

# Genuine complexity that REMAINS after the fix (real CRAPy candidates).
IO.puts("\n--- Top 15 remaining high SOURCE CC (real candidates) ---")
funs
|> Enum.filter(fn {_, _, s} -> s != nil end)
|> Enum.sort_by(fn {_, _, s} -> -s end)
|> Enum.take(15)
|> Enum.each(fn {{m, n, a}, d, s} ->
  IO.puts("  #{inspect(m)}.#{n}/#{a}: source=#{s} (debug was #{d})")
end)

# How many functions cross a CC>20 "scary" line under each model?
scary_debug = Enum.count(funs, fn {_, d, _} -> d > 20 end)
scary_src = Enum.count(funs, fn {_, _, s} -> s != nil and s > 20 end)
IO.puts("\nfunctions with CC>20: debug=#{scary_debug}  source=#{scary_src}")
