defmodule Nebu.Matrix.BackfillPowerLevelsEventsMigrationTest do
  @moduledoc """
  Integration test for `priv/migrations/000035_backfill_power_levels_events`
  (code-review cycle 1 addendum, MAJOR-1: bugfix sync-state-events-missing-fields).

  Per ADR-018 there is no `Ecto.Schema`/`Ecto.Migration` framework in this
  project — `priv/migrations/*.up.sql` are the sole canonical schema/data
  migrations, applied as raw SQL scripts by `Nebu.Release.migrate/0` (see
  `server/lib/nebu/release.ex`). This test runs the migration's own `.up.sql`
  file directly against the live `Nebu.Repo` connection (same approach as
  `Nebu.Matrix.MigrationsGrantTest`'s sibling DB-executing tests, and the same
  `Ecto.Adapters.SQL.query(Nebu.Repo, ...)` idiom `matrix_client_compat_test.exs`
  already uses for direct DB fixture setup/assertions).

  Covers the exact scope the code-review cycle 1 addendum calls for, plus the
  cycle 2 widening (MAJOR-2):
    - runs cleanly against a representative legacy-shaped fixture: a room with
      `rooms.power_levels_json` set but NO `m.room.power_levels` row in
      `events` — exactly what every room looked like before this bugfix's
      `emit_power_levels_event/3` (room/server.ex) started persisting one;
    - is idempotent (running it twice backfills the row only once, no error);
    - does not touch/duplicate a room that already has a real
      `m.room.power_levels` event;
    - DOES backfill a room whose `power_levels_json` is still the trivial
      default `'{}'` (cycle 2, MAJOR-2) — that is the room's real current
      state, not a guessed default, so it must not be skipped;
    - post-migration, `/sync` (via `GetInitialSync`, the same function the
      `/_matrix/client/v3/sync` HTTP handler calls) for the backfilled room now
      carries real, non-sentinel `event_id`/`origin_server_ts`/`sender` for
      `m.room.power_levels` instead of the `""`/`0` sentinels MAJOR-1 describes.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Matrix.Room.DB, as: RoomDB

  @migration_sql File.read!(
                   Path.expand(
                     "../../../priv/migrations/000035_backfill_power_levels_events.up.sql",
                     __DIR__
                   )
                 )

  defp run_migration! do
    Ecto.Adapters.SQL.query!(Nebu.Repo, @migration_sql, [])
  end

  defp fetch_pl_events(room_id) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        """
        SELECT event_id, origin_server_ts, sender, content::text
        FROM events
        WHERE room_id = $1 AND event_type = 'm.room.power_levels' AND state_key = ''
        """,
        [room_id]
      )

    rows
  end

  # Inserts an m.room.create event directly (bypassing the normal create_room/2
  # command path entirely) so the fixture room looks exactly like data written by
  # the pre-fix code: power_levels_json set on `rooms`, a real m.room.create
  # event for creator lookup, but NO m.room.power_levels event anywhere.
  defp insert_legacy_create_event(room_id, creator_id, ts) do
    event_map = %{
      "room_id" => room_id,
      "type" => "m.room.create",
      "state_key" => "",
      "sender" => creator_id,
      "content" => %{"creator" => creator_id, "room_version" => "10"},
      "origin_server_ts" => ts
    }

    event_id = Nebu.Matrix.EventId.generate(event_map)
    :ok = RoomDB.insert_event(Map.put(event_map, "event_id", event_id))
  end

  setup do
    {:ok, suffix: System.unique_integer([:positive])}
  end

  test "backfills a legacy room (power_levels set, no m.room.power_levels event) with real identity",
       %{suffix: suffix} do
    room_id = "!legacy-pl-#{suffix}:test.local"
    user_id = "@legacy-creator-#{suffix}:test.local"

    _ =
      Nebu.Matrix.Session.TokenValidator.validate(
        user_id,
        "user",
        "LegacyCreator",
        "legacy-pl-#{suffix}@example.com"
      )

    {:ok, created_at_ms} = RoomDB.insert_room(room_id)
    insert_legacy_create_event(room_id, user_id, created_at_ms)

    power_levels = %{
      "users" => %{user_id => 100},
      "users_default" => 0,
      "state_default" => 50,
      "events_default" => 0
    }

    :ok = RoomDB.set_power_levels(room_id, Jason.encode!(power_levels))
    :ok = RoomDB.insert_member(room_id, user_id)

    # Precondition: exactly the pre-existing-room bug MAJOR-1 describes — power
    # levels are set but no backing event exists yet.
    assert fetch_pl_events(room_id) == []

    run_migration!()

    assert [[event_id, origin_server_ts, sender, content_text]] = fetch_pl_events(room_id)

    assert is_binary(event_id) and event_id != "" and String.starts_with?(event_id, "$"),
           "backfilled event_id must be a real, non-empty, spec-shaped Matrix event id, got: " <>
             inspect(event_id)

    assert origin_server_ts == created_at_ms,
           "backfilled origin_server_ts must equal the room's actual created_at, not a fake " <>
             "'now' (got #{inspect(origin_server_ts)}, expected #{inspect(created_at_ms)})"

    assert sender == user_id,
           "backfilled sender must be the room's real creator, got #{inspect(sender)}"

    assert Jason.decode!(content_text) == power_levels,
           "backfilled content must equal the room's CURRENT power_levels_json, not a guessed " <>
             "default"

    # Idempotency: re-running the migration must not duplicate the row or raise
    # a unique_violation on event_id (PRIMARY KEY).
    run_migration!()

    assert [[^event_id, ^origin_server_ts, ^sender, _]] = fetch_pl_events(room_id),
           "re-running the migration must be a no-op for an already-backfilled room"

    # Post-migration /sync (GetInitialSync, the function the real HTTP /sync
    # handler calls) carries real, non-sentinel identity for this event —
    # exercised via a freshly started Room GenServer so do_init/1 picks up the
    # backfilled identity from load_members/1, exactly as a production restart
    # or on-demand room start would.
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)

    %Core.GetInitialSyncResponse{rooms: rooms} =
      Nebu.Matrix.EventDispatcher.Server.get_initial_sync(
        %Core.GetInitialSyncRequest{user_id: user_id},
        nil
      )

    sync_room = Enum.find(rooms, &(&1.room_id == room_id))
    assert sync_room != nil, "backfilled room must appear in the syncing user's GetInitialSync"

    pl_state_event = Enum.find(sync_room.state_events, &(&1.type == "m.room.power_levels"))

    assert pl_state_event != nil,
           "m.room.power_levels must be present in state.events for the backfilled room"

    assert pl_state_event.event_id == event_id
    assert pl_state_event.origin_server_ts == created_at_ms
    assert pl_state_event.sender == user_id

    refute pl_state_event.event_id == "",
           "post-migration /sync must no longer carry the MAJOR-1 event_id: \"\" sentinel"

    refute pl_state_event.origin_server_ts == 0,
           "post-migration /sync must no longer carry the MAJOR-1 origin_server_ts: 0 " <>
             "(epoch 1970) sentinel"
  end

  test "does not touch or duplicate a room that already has a real m.room.power_levels event",
       %{suffix: suffix} do
    room_id = "!has-pl-#{suffix}:test.local"
    creator_id = "@has-pl-creator-#{suffix}:test.local"

    _ =
      Nebu.Matrix.Session.TokenValidator.validate(
        creator_id,
        "user",
        "HasPl",
        "has-pl-#{suffix}@example.com"
      )

    {:ok, created_at_ms} = RoomDB.insert_room(room_id)
    insert_legacy_create_event(room_id, creator_id, created_at_ms)

    power_levels = %{"users" => %{creator_id => 100}}
    :ok = RoomDB.set_power_levels(room_id, Jason.encode!(power_levels))

    # Simulate a room that already underwent the AC2-addendum fix (a real event
    # already exists — e.g. create_personal_room/2's own pl_event write, or any
    # post-fix set_power_levels call).
    real_event_map = %{
      "room_id" => room_id,
      "type" => "m.room.power_levels",
      "state_key" => "",
      "sender" => creator_id,
      "content" => power_levels,
      "origin_server_ts" => created_at_ms + 1_000
    }

    real_event_id = Nebu.Matrix.EventId.generate(real_event_map)
    :ok = RoomDB.insert_event(Map.put(real_event_map, "event_id", real_event_id))

    run_migration!()

    assert [[^real_event_id, _ts, ^creator_id, _content]] = fetch_pl_events(room_id),
           "a room that already has a real m.room.power_levels event must be left untouched " <>
             "(no duplicate row, no overwrite of the existing one)"
  end

  test "backfills a room whose power_levels_json is still the trivial default '{}'",
       %{suffix: suffix} do
    room_id = "!trivial-pl-#{suffix}:test.local"
    {:ok, created_at_ms} = RoomDB.insert_room(room_id)

    # insert_room/1 defaults power_levels_json to '{}'. Code-review cycle 2
    # (MAJOR-2): this is the room's REAL current power-levels state, not a
    # guessed default — a room lacking a backing m.room.power_levels event is
    # still exactly the bug this migration exists to close, regardless of
    # whether that room's power levels happen to be trivial. It must be
    # backfilled too (content == %{}), not skipped.
    run_migration!()

    assert [[event_id, origin_server_ts, _sender, content_text]] = fetch_pl_events(room_id),
           "a room with trivial (still-default '{}') power levels must now be backfilled too"

    assert is_binary(event_id) and event_id != "" and String.starts_with?(event_id, "$"),
           "backfilled event_id must be a real, non-empty, spec-shaped Matrix event id, got: " <>
             inspect(event_id)

    assert origin_server_ts == created_at_ms,
           "backfilled origin_server_ts must equal the room's actual created_at"

    assert Jason.decode!(content_text) == %{},
           "backfilled content must equal the room's actual (trivial) power_levels_json " <>
             "verbatim, not be skipped"
  end
end
