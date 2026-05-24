defmodule CrapEx.CoverageTest do
  @moduledoc """
  Gate G2 (cover↔discovery clause-index alignment — the load-bearing one) and
  G4 (fixture matrix coverage observations).
  """
  use ExUnit.Case, async: false

  # This suite drives the global :cover server directly, which is incompatible
  # with `mix test --cover` (it would wipe Mix's coverage session). The harness
  # excludes this tag from coverage-export runs; plain `mix test` includes it.
  @moduletag :uses_cover

  alias CrapEx.{Coverage, Discovery}

  @fixture CrapFixtures.Shapes

  setup_all do
    # Drive :cover directly over the fixture, exercising a deliberate subset of
    # functions so we get a mix of covered / uncovered / not-applicable clauses.
    start_cover()
    beam = :code.which(@fixture)
    {:ok, _} = :cover.compile_beam(beam)

    # Exercised:
    @fixture.simple(2)
    @fixture.classify(50)
    @fixture.use_helper(1)
    # Not exercised: one_liner, with_case, with_if, boolean_ops, with_expr,
    #   anon_fn, classify clauses 1 & 2.

    cover_map = Coverage.analyse_clauses([@fixture])
    {:ok, entries} = Discovery.discover_modules([@fixture])
    discovered_ids = Enum.map(entries, fn {id, _} -> id end)

    on_exit(fn -> :cover.stop() end)
    %{cover_map: cover_map, ids: discovered_ids}
  end

  defp start_cover do
    case :cover.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :cover.reset()
  end

  test "G2: every discovered clause has a matching :cover clause entry", %{
    cover_map: cover_map,
    ids: ids
  } do
    for id <- ids do
      key = {id.module, id.name, id.arity, id.clause_index}

      assert Map.has_key?(cover_map, key),
             "no :cover clause for #{inspect(key)} — discovery/cover indexes diverged"
    end
  end

  test "G2: synthetic clauses exist in :cover but are dropped by discovery", %{
    cover_map: cover_map,
    ids: ids
  } do
    # __info__/1 is generated: present in :cover, absent from discovery.
    assert Enum.any?(Map.keys(cover_map), fn {_, n, _, _} -> n == :__info__ end)
    refute Enum.any?(ids, &(&1.name == :__info__))
  end

  test "G4: unexercised one-liner (arity 2) reports executable-but-uncovered", %{
    cover_map: cover_map
  } do
    # A one-liner's body IS executable under :cover (the head line counts), so
    # it appears with {0, n}, not {0, 0}. The {0,0}/not_applicable path is
    # triggered instead by clauses absent from coverdata (see facade default).
    {cov, not_cov} = cover_map[{@fixture, :one_liner, 2, 1}]
    assert cov == 0
    assert not_cov > 0
  end

  test "G4: exercised clause is covered, unexercised is not", %{cover_map: cover_map} do
    # simple/1 was called: covered lines > 0.
    {cov, _} = cover_map[{@fixture, :simple, 1, 1}]
    assert cov > 0

    # boolean_ops/3 never called: not-covered lines > 0, covered == 0.
    {bcov, bnot} = cover_map[{@fixture, :boolean_ops, 3, 1}]
    assert bcov == 0
    assert bnot > 0
  end

  test "G4: multi-clause classify has per-clause coverage", %{cover_map: cover_map} do
    # clause 3 (the cond) was exercised via classify(50); clauses 1,2 were not.
    assert {c3, _} = cover_map[{@fixture, :classify, 1, 3}]
    assert c3 > 0
    assert {0, n1} = cover_map[{@fixture, :classify, 1, 1}]
    assert n1 >= 0
  end
end
