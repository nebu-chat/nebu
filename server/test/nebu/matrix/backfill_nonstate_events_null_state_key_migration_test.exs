defmodule Nebu.Matrix.BackfillNonstateEventsNullStateKeyMigrationTest do
  @moduledoc """
  Integration test for
  `priv/migrations/000036_backfill_nonstate_events_null_state_key`
  (bugfix unsigned-replaces-state, code-review cycle 2 — companion migration
  to the `do_send_event/7` writer fix in `room/server.ex`; REVISED in code-
  review cycle 3, MAJOR-1, from an exclusion list to an inclusion list).

  Per ADR-018 there is no `Ecto.Schema`/`Ecto.Migration` framework in this
  project — `priv/migrations/*.up.sql` are the sole canonical schema/data
  migrations, applied as raw SQL scripts by `Nebu.Release.migrate/0` (see
  `server/lib/nebu/release.ex`). This test runs the migration's own `.up.sql`
  file directly against the live `Nebu.Repo` connection — the same approach
  `Nebu.Matrix.BackfillPowerLevelsEventsMigrationTest` (migration 000035)
  uses for its sibling DB-executing tests.

  Covers the precision requirement from the migration's own rationale
  comment:
    - a genuinely non-state event incorrectly persisted with `state_key = ''`
      (the historical damage the pre-existing `do_send_event/7` bug caused)
      MUST be corrected to `state_key = NULL` — verified for `m.room.message`,
      the one verified-non-state type on the cycle-3 inclusion list;
    - a genuine state event whose real Matrix state_key IS the empty string
      (m.room.create, m.room.name, m.room.power_levels, m.room.tombstone)
      MUST be left completely untouched;
    - cycle 3's key behavioral change (MAJOR-1): an UNLISTED/custom event type
      with `state_key = ''` (not on the inclusion list, and not one of the
      well-known state types either — e.g. a custom state type a client wrote
      via createRoom's `initial_state`) MUST ALSO be left completely
      untouched — this is the fail-safe guarantee the old exclusion-list
      design did NOT provide (it would have nulled such a row, silently
      destroying a legitimate custom state event);
    - re-running the migration is idempotent (no change on the second run).
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Matrix.Room.DB, as: RoomDB

  @migration_sql File.read!(
                   Path.expand(
                     "../../../priv/migrations/000036_backfill_nonstate_events_null_state_key.up.sql",
                     __DIR__
                   )
                 )

  defp run_migration! do
    Ecto.Adapters.SQL.query!(Nebu.Repo, @migration_sql, [])
  end

  defp fetch_state_key(event_id) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT state_key FROM events WHERE event_id = $1",
        [event_id]
      )

    case rows do
      [[state_key]] -> state_key
      [] -> :not_found
    end
  end

  # Inserts a raw event row with a LITERAL "" state_key (bypassing
  # Room.DB.insert_event/1's own pass-through contract by going straight to
  # SQL) — this is what the pre-existing do_send_event/7 bug actually
  # persisted for every non-state event before its fix, and what every
  # genuine empty-state_key state event legitimately persists today.
  defp insert_raw_event(room_id, event_id, event_type, state_key, sender, ts) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
      VALUES ($1, $2, $3, $4, '{}'::jsonb, $5, $6)
      """,
      [event_id, room_id, sender, event_type, ts, state_key]
    )
  end

  setup do
    suffix = System.unique_integer([:positive])
    room_id = "!backfill-nonstate-#{suffix}:test.local"
    user_id = "@backfill-nonstate-#{suffix}:test.local"
    {:ok, _created_at_ms} = RoomDB.insert_room(room_id)
    {:ok, suffix: suffix, room_id: room_id, user_id: user_id}
  end

  test "nulls state_key for a genuinely non-state event incorrectly persisted with ''",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    event_id = "$nonstate-#{suffix}"
    insert_raw_event(room_id, event_id, "m.room.message", "", user_id, 1_000)

    assert fetch_state_key(event_id) == ""

    run_migration!()

    assert fetch_state_key(event_id) == nil
  end

  test "leaves m.room.create's legitimate empty state_key untouched",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    event_id = "$create-#{suffix}"
    insert_raw_event(room_id, event_id, "m.room.create", "", user_id, 1_000)

    run_migration!()

    assert fetch_state_key(event_id) == "",
           "m.room.create's legitimately-empty state_key must survive the backfill untouched"
  end

  test "leaves m.room.name's legitimate empty state_key untouched",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    event_id = "$name-#{suffix}"
    insert_raw_event(room_id, event_id, "m.room.name", "", user_id, 1_000)

    run_migration!()

    assert fetch_state_key(event_id) == "",
           "m.room.name's legitimately-empty state_key must survive the backfill untouched"
  end

  test "leaves m.room.power_levels's legitimate empty state_key untouched",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    event_id = "$pl-#{suffix}"
    insert_raw_event(room_id, event_id, "m.room.power_levels", "", user_id, 1_000)

    run_migration!()

    assert fetch_state_key(event_id) == "",
           "m.room.power_levels's legitimately-empty state_key must survive the backfill untouched"
  end

  test "leaves m.room.tombstone's legitimate empty state_key untouched (the grep-only find)",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    event_id = "$tombstone-#{suffix}"
    insert_raw_event(room_id, event_id, "m.room.tombstone", "", user_id, 1_000)

    run_migration!()

    assert fetch_state_key(event_id) == "",
           "m.room.tombstone's legitimately-empty state_key must survive the backfill " <>
             "untouched — this is the type the @writable_state_types-only list would have " <>
             "missed without the grep sweep for hardcoded emit_state_event/5 call sites"
  end

  test "leaves an UNLISTED/custom event type's empty state_key untouched (MAJOR-1, cycle 3 fail-safe)",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    # "org.example.custom.widget" is on NEITHER the inclusion list (verified
    # non-state types) NOR any well-known Matrix state type — exactly the
    # shape of a custom state event type a client could write via createRoom's
    # `initial_state` array (apply_initial_state/3 has no event-type allowlist
    # of its own). Under the OLD exclusion-list design (`event_type NOT IN
    # (<10 known types>)`), this row WOULD have matched (it is not one of the
    # 10 excluded types) and been destructively nulled — this test would have
    # FAILED under that design. Under the NEW inclusion-list design, this row
    # is simply not on the (much smaller) inclusion list, so it is left
    # completely untouched — proving the fail-safe behavior the cycle-3 fix
    # exists to guarantee.
    event_id = "$custom-state-#{suffix}"
    insert_raw_event(room_id, event_id, "org.example.custom.widget", "", user_id, 1_000)

    run_migration!()

    assert fetch_state_key(event_id) == "",
           "an unlisted/custom event type's legitimately-empty state_key must survive the " <>
             "backfill untouched (MAJOR-1 fail-safe) — the old exclusion-list design would have " <>
             "destructively nulled this row"
  end

  test "does not touch a genuine state event with a non-empty state_key",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    event_id = "$member-#{suffix}"
    insert_raw_event(room_id, event_id, "m.room.member", user_id, user_id, 1_000)

    run_migration!()

    assert fetch_state_key(event_id) == user_id,
           "a real (non-empty) state_key must never be touched by this migration"
  end

  test "idempotent: running the migration twice produces the same end state",
       %{suffix: suffix, room_id: room_id, user_id: user_id} do
    nonstate_event_id = "$nonstate-idem-#{suffix}"
    create_event_id = "$create-idem-#{suffix}"

    insert_raw_event(room_id, nonstate_event_id, "m.room.message", "", user_id, 1_000)
    insert_raw_event(room_id, create_event_id, "m.room.create", "", user_id, 1_000)

    run_migration!()

    assert fetch_state_key(nonstate_event_id) == nil
    assert fetch_state_key(create_event_id) == ""

    # Second run must be a true no-op: no error (no unique_violation / no-op
    # UPDATE matching zero rows), and the end state is unchanged.
    run_migration!()

    assert fetch_state_key(nonstate_event_id) == nil
    assert fetch_state_key(create_event_id) == ""
  end
end
