defmodule Nebu.Media.StateMachineInvariantTest do
  @moduledoc """
  AC6 — grep-based invariant check for `media-security-admin-control/1b-state-machine-module`.

  **This test suite is defense-in-depth only, NOT the authoritative
  guarantee.** The authoritative enforcement that `media_files.state` can
  only ever change alongside a corresponding `media_state_transitions` row —
  and that `media_state_transitions` itself can never be silently rewritten
  — is the DB-level `BEFORE UPDATE OR DELETE` trigger
  (`media_state_transitions_no_mutate`, SQLSTATE 23001) plus RLS/REVOKE added
  by Story 1a's migration (`000022_media_state_machine_foundation`,
  ADR-031). That trigger fires for every role, including the table owner,
  and is the only layer that also blocks a raw `psql` session or a future
  migration bug. See `Nebu.Media.StateMachine.MutationInvariant`'s
  `@moduledoc` (`test/nebu/media/media_mutation_invariant_support.exs`) for
  the full rationale.

  This test only proves that no *committed Elixir source file* under
  `server/lib/` (other than `nebu/media/state_machine.ex`, the single module
  allowed to write `media_files.state`) contains a direct SQL
  `UPDATE ... media_files ... SET ... state` statement. A green result here
  must never be read as proof that `media_state_transitions` is immutable —
  that is Story 1a's trigger's job, not this test's.

  Runs under `make test-unit-elixir` (plain ExUnit, no live DB, no
  `:integration` tag) — pure filesystem/regex scanning via
  `Nebu.Media.StateMachine.MutationInvariant`.
  """

  use ExUnit.Case, async: true

  alias Nebu.Media.StateMachine.MutationInvariant

  describe "scan/1 against the real server/lib tree (AC6 test 12)" do
    test "no file under server/lib (excluding state_machine.ex) contains a direct " <>
           "UPDATE ... media_files ... SET state statement" do
      assert MutationInvariant.scan() == []
    end
  end

  describe "violation?/1 — the checker itself is exercised (AC6 tests 13/14)" do
    test "flags a deliberately-introduced violation (positive control)" do
      fixture = """
      defmodule SomeOtherModule do
        def bad_direct_update(conn, media_id, to_state) do
          Ecto.Adapters.SQL.query(conn,
            "UPDATE media_files SET state = $2 WHERE media_id = $1",
            [media_id, to_state]
          )
        end
      end
      """

      assert MutationInvariant.violation?(fixture)
    end

    test "does not flag an unrelated UPDATE statement (negative control)" do
      fixture = """
      defmodule SomeOtherModule do
        def mark_compressed(conn, media_id) do
          Ecto.Adapters.SQL.query(conn,
            "UPDATE media_files SET compressed = true WHERE media_id = $1",
            [media_id]
          )
        end
      end
      """

      refute MutationInvariant.violation?(fixture)
    end

    # code-review MAJOR fix (M3, test-review-findings.md): the negative
    # control above never contains the substring "state" anywhere, so it
    # would pass even against a regex as crude as
    # `/UPDATE\s+media_files[\s\S]*state/i` — it proves nothing about
    # whether the checker can tell "state assigned in SET" apart from
    # "state merely referenced in WHERE". This fixture is the actual
    # false-positive case the test-review found reproducible against the
    # regex as originally shipped: a legitimate update of an unrelated
    # column (`compressed`) whose WHERE clause happens to filter on the
    # `state` column. A regex that stops the SET-clause span at the next
    # `WHERE` keyword (this module's fix) must NOT flag this; a regex that
    # lets its non-greedy span cross the WHERE boundary (the original bug)
    # would incorrectly flag it.
    test "does not flag an unrelated UPDATE whose WHERE clause references " <>
           "the state column (negative control — WHERE-boundary false positive)" do
      fixture = """
      defmodule SomeOtherModule do
        def mark_compressed_for_released(conn, media_id) do
          Ecto.Adapters.SQL.query(conn,
            "UPDATE media_files SET compressed = true WHERE state = 'released' AND media_id = $1",
            [media_id]
          )
        end
      end
      """

      refute MutationInvariant.violation?(fixture)
    end
  end
end
