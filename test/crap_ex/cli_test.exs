defmodule CrapEx.CliTest do
  @moduledoc "Gate G5: end-to-end `mix crap` exit codes 0 / 1 / 2."
  use ExUnit.Case, async: false

  # Shells out to the real Mix task; excluded from coverage-export runs.
  @moduletag :integration
  @moduletag :uses_cover
  @moduletag timeout: 120_000

  @coverdata "cover/crap.coverdata"

  setup_all do
    # Ensure a real coverdata file exists (generated without the cover-driving
    # suites). Reuse if present to keep the test fast.
    unless File.exists?(@coverdata) do
      {_, 0} =
        System.cmd(
          "mix",
          ~w(test --cover --export-coverage crap --exclude uses_cover --exclude integration),
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )
    end

    :ok
  end

  defp crap(args) do
    System.cmd("mix", ["crap" | args],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  test "exit 0 when nothing exceeds a very high threshold" do
    {out, status} = crap(["--coverdata", @coverdata, "--min-score", "100000"])
    assert status == 0, out
    assert out =~ "CRAP gate passed"
  end

  test "exit 1 when a function exceeds a low threshold" do
    {out, status} = crap(["--coverdata", @coverdata, "--min-score", "1"])
    assert status == 1, out
    assert out =~ "CRAP gate failed"
  end

  test "exit 2 on usage error (no coverdata files match)" do
    {out, status} = crap(["--coverdata", "cover/does-not-exist-*.coverdata"])
    assert status == 2, out
    assert out =~ "no_coverdata_files" or out =~ "crap:"
  end
end
