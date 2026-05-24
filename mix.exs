defmodule CrapEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukaszsamson/crap_ex"

  def project do
    [
      app: :crap_ex,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      # NOTE: we intentionally use Mix's native :cover-based coverage tool (not
      # ExCoveralls) so `mix test --cover --export-coverage` writes a coverdata
      # file that :cover.import/1 can read back with real per-clause counts.
      name: "crap_ex",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        check: :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Compute the CRAP (Change Risk Anti-Patterns) metric per function for Elixir " <>
      "code and gate CI on it, joining cyclomatic complexity with :cover coverage."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"
      },
      # Ship only what's needed at use time; dev/test artifacts are excluded.
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md PLAN.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "PLAN.md"]
    ]
  end

  defp deps do
    [
      # Optional: ergonomic AST zipper traversal for the complexity visitor.
      {:sourceror, "~> 1.7", optional: true},
      # Optional: Credo-backed cyclomatic complexity backend.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # JSON output uses Elixir's built-in JSON module (1.18+) — no runtime dep.
      # Dev/test harness tooling.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      # Validates generated SARIF against the official 2.1.0 schema (test only).
      {:ex_json_schema, "~> 0.10", only: :test},
      # Documentation generation for hexdocs.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow --exit --skip",
        "dialyzer",
        "test --cover --export-coverage crap --exclude uses_cover",
        "crap --coverdata cover/crap.coverdata --min-score 30"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/project.plt"},
      # :mix is needed because the `mix crap` task calls Mix.* functions.
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
