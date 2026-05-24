defmodule CrapEx.Scope do
  @moduledoc """
  Resolve which `{module, name, arity}` functions are *in scope* for gating.

  Default scope is everything (`nil`). With `--changed-only REF`, scope narrows
  to functions whose discovered line range intersects a changed line range from
  `CrapEx.GitDiff`.
  """

  alias CrapEx.{ClauseId, Config, Discovery, GitDiff}

  @doc """
  Compute the gating scope for `entries` under `config`.

  Returns `{:ok, MapSet.t() | nil}` — `nil` means "gate everything".
  """
  @spec resolve([Discovery.entry()], Config.t()) ::
          {:ok, MapSet.t() | nil} | {:error, term()}
  def resolve(_entries, %Config{changed_only: nil}), do: {:ok, nil}

  def resolve(entries, %Config{changed_only: ref}) do
    with {:ok, ranges} <- GitDiff.changed_ranges(ref) do
      {:ok, intersecting_mfas(entries, ranges)}
    end
  end

  defp intersecting_mfas(entries, ranges) do
    entries
    |> Enum.filter(fn {%ClauseId{} = id, _ast} -> touched?(id, ranges) end)
    |> Enum.map(fn {id, _ast} -> ClauseId.mfa(id) end)
    |> MapSet.new()
  end

  defp touched?(%ClauseId{file: file, line_start: s, line_end: e}, ranges) do
    case Map.get(ranges, file) do
      nil -> false
      file_ranges -> Enum.any?(file_ranges, &overlaps?(&1, s, e))
    end
  end

  defp overlaps?(lo..hi//_, s, e), do: lo <= e and s <= hi
end
