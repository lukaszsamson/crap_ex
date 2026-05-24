defmodule CrapEx.Discovery do
  @moduledoc """
  Enumerate user-defined function/macro clauses from compiled BEAM files.

  Returns `{CrapEx.ClauseId.t(), Macro.t()}` pairs — identity plus the clause
  body AST that the complexity stage consumes. Synthetic functions the compiler
  injects (`__info__/1`, `__struct__`, behaviour trampolines) are absent from
  `debug_info`'s `:definitions` and so never appear here; this is what filters
  them out of the later `:cover` join.

  Primary path is `CrapEx.Discovery.DebugInfo` (the compiled-module chunk).
  """

  alias CrapEx.{ClauseId, Config, Discovery.DebugInfo}

  @type entry :: {ClauseId.t(), {Macro.t(), [Macro.t()]}}

  @doc """
  Discover clauses for the modules of the current Mix project, restricted to
  source files living under `config.paths`.
  """
  @spec discover(Config.t()) :: {:ok, [entry()]} | {:error, term()}
  def discover(%Config{paths: paths}) do
    compile_path = Mix.Project.compile_path()

    beams =
      compile_path
      |> Path.join("*.beam")
      |> Path.wildcard()

    with {:ok, entries} <- discover_beams(beams) do
      {:ok, filter_paths(entries, paths)}
    end
  end

  @doc "Discover clauses for explicit modules (used by tests)."
  @spec discover_modules([module()]) :: {:ok, [entry()]} | {:error, term()}
  def discover_modules(modules) do
    modules
    |> Enum.map(&beam_path/1)
    |> discover_beams()
  end

  @doc "Discover clauses from explicit beam paths."
  @spec discover_beams([charlist() | String.t()]) :: {:ok, [entry()]} | {:error, term()}
  def discover_beams(beams) do
    Enum.reduce_while(beams, {:ok, []}, fn beam, {:ok, acc} ->
      case DebugInfo.extract(beam) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        # Non-analyzable modules are skipped (not our target); only a genuine
        # Elixir debug-info version mismatch aborts the run.
        {:error, {:no_debug_info, _}} -> {:cont, {:ok, acc}}
        {:error, {:non_elixir_module, _}} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp filter_paths(entries, paths) do
    # debug_info `relative_file` is project-root-relative (e.g. "lib/foo.ex").
    # Normalize both sides so "./lib", "lib/", and absolute paths all match.
    norm_paths = Enum.map(paths, &normalize/1)

    Enum.filter(entries, fn {%ClauseId{file: file}, _ast} ->
      file != "" and Enum.any?(norm_paths, &under?(normalize(file), &1))
    end)
  end

  defp normalize(path) do
    path
    |> Path.relative_to_cwd()
    |> String.trim_trailing("/")
  end

  defp under?(file, path) do
    file == path or String.starts_with?(file, path <> "/")
  end

  defp beam_path(module) do
    case :code.which(module) do
      beam when is_list(beam) and beam != [] -> beam
      _ -> Path.join(Mix.Project.compile_path(), "#{module}.beam") |> to_charlist()
    end
  end
end
