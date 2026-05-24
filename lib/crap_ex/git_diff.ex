defmodule CrapEx.GitDiff do
  @moduledoc """
  Parse `git diff --unified=0 <ref>` into changed line ranges per file, for the
  `--changed-only` gate. Only added/modified lines in the *new* file are
  considered (the lines a contributor is responsible for).
  """

  @type ranges :: %{optional(String.t()) => [Range.t()]}

  @doc """
  Return `{:ok, ranges}` mapping each changed file path to a list of changed
  line ranges in the new file, comparing `ref` against the working tree.
  """
  @spec changed_ranges(String.t(), keyword()) :: {:ok, ranges()} | {:error, term()}
  def changed_ranges(ref, opts \\ []) do
    dir = Keyword.get(opts, :cd, File.cwd!())

    case System.cmd("git", ["diff", "--unified=0", ref], cd: dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse(output)}
      {output, _} -> {:error, {:git_diff_failed, String.trim(output)}}
    end
  end

  @doc "Parse `git diff --unified=0` text into per-file changed line ranges."
  @spec parse(String.t()) :: ranges()
  def parse(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, &reduce_line/2)
    |> elem(1)
    |> Map.new(fn {file, ranges} -> {file, Enum.reverse(ranges)} end)
  end

  defp reduce_line("+++ b/" <> path, {_file, acc}) do
    {String.trim(path), Map.put_new(acc, String.trim(path), [])}
  end

  defp reduce_line("+++ /dev/null" <> _, {_file, acc}), do: {nil, acc}

  defp reduce_line("@@" <> _ = line, {file, acc}) when is_binary(file) do
    case parse_hunk(line) do
      {:ok, range} -> {file, Map.update(acc, file, [range], &[range | &1])}
      :error -> {file, acc}
    end
  end

  defp reduce_line(_other, state), do: state

  # Hunk header: `@@ -old_start,old_len +new_start,new_len @@ ...`
  # A count of 0 means a pure deletion at that point; skip it (no new lines).
  defp parse_hunk(line) do
    case Regex.run(~r/@@ -\S+ \+(\d+(?:,\d+)?) @@/, line) do
      [_, plus] ->
        {start, len} = split_count(plus)
        if len == 0, do: :error, else: {:ok, start..(start + len - 1)}

      _ ->
        :error
    end
  end

  defp split_count(spec) do
    case String.split(spec, ",") do
      [s] -> {String.to_integer(s), 1}
      [s, l] -> {String.to_integer(s), String.to_integer(l)}
    end
  end
end
