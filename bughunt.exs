# Bug-hunt harness: run crap_ex discovery + complexity over every compiled beam
# under the given root(s), catching any crash. Coverage is not needed — this
# stress-tests the AST/debug_info handling across a large variety of real code.
#
#   MIX_ENV=dev mix run bughunt.exs <root_dir> [<root_dir> ...]

alias CrapEx.Discovery.DebugInfo
alias CrapEx.Complexity.Visitor

roots =
  case System.argv() do
    [] -> System.get_env("BUGHUNT_ROOTS", "") |> String.split(":", trim: true)
    args -> args
  end

beams =
  roots
  |> Enum.flat_map(fn root ->
    Path.wildcard(Path.join(root, "_build/*/lib/*/ebin/*.beam"))
  end)
  |> Enum.uniq()

defmodule Hunt do
  def analyze_clause(id, body, guards) do
    cc = Visitor.complexity(body, guards)
    if not (is_integer(cc) and cc >= 1), do: throw({:bad_cc, cc})
    :ok
  rescue
    e -> {:crash, id, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 300)}
  catch
    kind, val -> {:crash, id, inspect({kind, val})}
  end
end

{ok_modules, crashes, extract_errors, clause_count} =
  Enum.reduce(beams, {0, [], [], 0}, fn beam, {okm, crs, errs, cc} ->
    case DebugInfo.extract(beam) do
      {:ok, entries} ->
        new_crs =
          for {id, {body, guards}} <- entries,
              res = Hunt.analyze_clause(id, body, guards),
              res != :ok,
              do: res

        {okm + 1, new_crs ++ crs, errs, cc + length(entries)}

      {:error, {reason, _}} when reason in [:non_elixir_module, :no_debug_info] ->
        {okm, crs, errs, cc}

      {:error, reason} ->
        {okm, crs, [{beam, reason} | errs], cc}
    end
  end)

IO.puts("\n=== BUGHUNT SUMMARY ===")
IO.puts("beams scanned:        #{length(beams)}")
IO.puts("elixir modules:       #{ok_modules}")
IO.puts("clauses analyzed:     #{clause_count}")
IO.puts("complexity crashes:   #{length(crashes)}")
IO.puts("extract hard-errors:  #{length(extract_errors)}")

for {id, msg} <- Enum.take(crashes, 25) do
  IO.puts("  CRASH #{CrapEx.ClauseId.label(id)} (clause #{id.clause_index}): #{msg}")
end

for {beam, reason} <- Enum.take(extract_errors, 25) do
  IO.puts("  EXTRACT-ERR #{Path.basename(beam)}: #{inspect(reason)}")
end

if crashes == [] and extract_errors == [] do
  IO.puts("OK — no crashes")
end
