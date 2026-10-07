defmodule Nebu.Matrix.Room.DBBehaviour do
  @moduledoc """
  Behaviour contract for the Room DB persistence layer.

  Story 5.29d AC1 (FB-E5-03) / AC2: Defines compile-time-checked callbacks that
  all production and test implementations of Nebu.Matrix.Room.DB must satisfy.

  ## Usage

  Production module:
    - `Nebu.Matrix.Room.DB` — Ecto/PostgreSQL-backed implementation
    - Must declare `@behaviour Nebu.Matrix.Room.DBBehaviour`

  Test fakes used by event_dispatcher tests:
    - FakeDB modules in create_room_test.exs, join_room_test.exs, sync_test.exs, etc.
    - Must declare `@behaviour Nebu.Matrix.Room.DBBehaviour` to get compile-time drift detection.

  Any fake that is missing a callback listed here will cause a compile-time warning
  (or error when `@dialyzer {:no_behaviours, _}` is absent) — surfacing interface
  drift before tests run.
  """

  @doc """
  Loads all active members for `room_id`.

  Returns `{:ok, [user_id], created_at_ms, power_levels_json}` if the room exists.
  Returns `{:error, :not_found}` if the room does not exist.
  Returns `{:error, reason}` on DB error.

  Bugfix sync-state-events-missing-fields (cluster-safety): the real
  `Nebu.Matrix.Room.DB` additionally returns a 5-tuple,
  `{:ok, [user_id], created_at_ms, power_levels_json, identity}`, where `identity`
  is `%{members: %{user_id => {event_id, origin_server_ts}}, power_levels:
  {event_id, origin_server_ts, sender} | nil}` — the real event identity for each
  member's join event and the power-levels event, so `Room.Server.do_init/1` can
  restore them into GenServer state after a crash/restart without them silently
  reverting to nil (do_init/1 rebuilds `members`/`power_levels` from this call on
  every restart). Code-review cycle 1 (MINOR-2): the power-levels tuple carries
  `sender` as a third element (same query, no extra round trip). Callers/fakes
  that only return the legacy 4-tuple are still fully supported — `do_init/1`
  falls back to empty identity in that case.
  """
  @callback load_members(room_id :: String.t()) ::
              {:ok, [String.t()], integer(), String.t()}
              | {:ok, [String.t()], integer(), String.t(), map()}
              | {:error, :not_found | term()}

  @doc """
  Inserts a new room into the rooms table.

  Returns `{:ok, created_at_ms}` on success.
  Returns `{:error, reason}` on DB failure.
  """
  @callback insert_room(room_id :: String.t()) :: {:ok, integer()} | {:error, term()}

  @doc """
  Hard-deletes a room and all rows that reference it (events, members), used to
  clean up an orphan room when room creation fails after `m.room.create` was
  written (story admin-room-creator-provisioning, AC3). This is a destructive
  delete reserved for the failed-create rollback path — NOT the archive flow.

  Returns `:ok` on success (idempotent — deleting an already-absent room is `:ok`).
  Returns `{:error, reason}` on DB failure.

  Optional callback: only ever invoked on the concrete `Nebu.Matrix.Room.DB`
  via `rooms_db_module().delete_room/1` in the failed-create orphan-cleanup path
  (and guarded by a `rescue`). Test fakes that do not exercise that path need not
  implement it.
  """
  @callback delete_room(room_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Inserts a member into room_members.

  Returns `:ok` on success.
  Returns `{:error, reason}` on DB failure.
  """
  @callback insert_member(room_id :: String.t(), user_id :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Soft-deletes a member from room_members by setting left_at.

  Returns `:ok` on success.
  Returns `{:error, :not_member}` if no active row matched.
  Returns `{:error, reason}` on DB failure.
  """
  @callback delete_member(room_id :: String.t(), user_id :: String.t()) ::
              :ok | {:error, :not_member | term()}

  @doc """
  Inserts a signed event into the events append-only table.

  Returns `:ok` on success.
  Returns `{:error, reason}` on DB failure.
  """
  @callback insert_event(event :: map()) :: :ok | {:error, term()}

  @doc """
  Persists the power_levels_json string for the given room_id.

  Returns `:ok` on success.
  Returns `{:error, reason}` on DB failure.
  """
  @callback set_power_levels(room_id :: String.t(), power_levels_json :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Returns all room IDs where user_id is currently an active member.

  Returns `{:ok, [room_id]}` — empty list if user has no active rooms.
  Returns `{:error, reason}` on DB error.
  """
  @callback get_rooms_for_user(user_id :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Returns all room IDs where user_id has left (left_at IS NOT NULL).

  Used by do_incremental_sync to include recently-left rooms in the initial
  fetch_delta_rooms check. Closes the race window where the {new_leave} broadcast
  fires before the sync task subscribes, causing a 30 s long-poll delay.

  Returns `{:ok, [room_id]}` — empty list if user has no left rooms.
  Returns `{:error, reason}` on DB error.
  """
  @callback get_recently_left_rooms_for_user(user_id :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Returns paginated events from the events table for the given room.

  Returns `{:ok, [event_map], next_batch, prev_batch}`.
  Returns `{:error, reason}` on DB error.
  """
  @callback fetch_events(
              room_id :: String.t(),
              direction :: String.t(),
              limit :: pos_integer(),
              from_token :: String.t()
            ) :: {:ok, [map()], String.t(), String.t()} | {:error, term()}

  @doc """
  Returns events in room_id with origin_server_ts strictly greater than
  the timestamp of last_event_id. Returns up to `limit` events in
  chronological order (ASC).

  Returns `{:ok, [event_map]}`.
  Returns `{:error, reason}` on DB error.
  """
  @callback fetch_events_since(
              room_id :: String.t(),
              last_event_id :: String.t() | nil,
              limit :: pos_integer()
            ) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Returns the origin_server_ts for the given event_id.

  Returns `{:ok, integer()}` on success.
  Returns `{:error, :not_found}` if the event does not exist.
  Returns `{:error, reason}` on DB error.
  """
  @callback get_event_timestamp(event_id :: String.t()) ::
              {:ok, integer()} | {:error, :not_found | term()}

  @doc """
  Returns the room name from the most recent m.room.name event.

  Returns `{:ok, String.t()}` on success. Bugfix sync-state-events-missing-fields
  (AC2): the real `Nebu.Matrix.Room.DB` returns a wider `{:ok, name, event_id,
  origin_server_ts}` 4-tuple instead — same query, no extra DB round trip (this
  is a hot path called on every `/sync`) — so `build_state_events/2` can thread
  real identity into the `m.room.name` state.events entry. Code-review cycle 1
  (MINOR-2): the real DB now returns an even wider `{:ok, name, event_id,
  origin_server_ts, sender}` 5-tuple (still the SAME query, zero extra round
  trips) so `sender` is no longer left as `""` once the event_id is real.
  Callers/fakes that return any of the narrower shapes continue to work:
  `build_state_events/2` and the `upgrade_room` name-copy path match on all of
  them.
  Returns `{:error, :not_found}` if no m.room.name event exists.
  Returns `{:error, reason}` on DB error.
  """
  @callback get_room_name(room_id :: String.t()) ::
              {:ok, String.t()}
              | {:ok, String.t(), String.t(), integer()}
              | {:ok, String.t(), String.t(), integer(), String.t()}
              | {:error, :not_found | term()}

  @doc """
  Returns heroes, joined count, and invited count for `room_id`, excluding `exclude_user_id`.

  Heroes = up to 5 participants ordered by joined_at ASC (joined members first, then
  pending invitations), excluding the syncing user.

  Returns `{:ok, %{heroes: [user_id], joined: integer(), invited: integer()}}` on success.
  Returns `{:error, reason}` on DB error.

  Story direct-room-heroes (§11.2.2): used by attach_heroes/3 in EventDispatcher.Server.
  """
  @callback get_room_heroes(room_id :: String.t(), exclude_user_id :: String.t()) ::
              {:ok, %{heroes: [String.t()], joined: integer(), invited: integer()}}
              | {:error, term()}

  @doc """
  Loads the mutable settings for `room_id` — currently only max_members.

  Returns `{:ok, max_members}` where `max_members` is 0 (no limit) or a positive integer.
  Returns `{:error, reason}` on DB error.

  Story 6.8: Called by Room.Server.init/1 to restore max_members after a GenServer restart.
  Fail-open: if this call fails, GenServer defaults to 0 (no limit).
  """
  @callback load_room_settings(room_id :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Returns the current archival status of `room_id` from the `rooms` table.

  Returns `{:ok, "active"}` for active (non-archived) rooms.
  Returns `{:ok, "archived"}` for archived rooms.
  Returns `{:error, :not_found}` when the room does not exist in the table.
  Returns `{:error, reason}` on DB error.

  Story 6.9: Called by Room.Server.init/1 before initialising state. When the result
  is `{:ok, "archived"}`, init/1 returns `{:stop, :normal}` so that Horde's `:transient`
  restart strategy does not restart the GenServer, preventing a restart loop. Any
  other return value (including `{:error, :not_found}` and DB errors) falls through
  to the normal init flow.
  """
  @callback get_room_status(room_id :: String.t()) ::
              {:ok, String.t()} | {:error, :not_found | term()}

  @doc """
  Atomically checks if a room is archived using SELECT FOR UPDATE.
  Called by Room.Server.send_event/6 before inserting an event.

  Must be called inside an Ecto transaction (the transaction context is
  created inside db.ex — caller does NOT need to manage a transaction).

  Returns {:ok, "active"} for active rooms.
  Returns {:ok, "archived"} for archived rooms.
  Returns {:error, :not_found} when the room does not exist.
  Returns {:error, reason} on DB error.

  Story 9-9: closes the TOCTOU race window between archive_room_atomic/1
  and send_event insert.
  """
  @callback check_room_status_for_update(room_id :: String.t()) ::
              {:ok, String.t()} | {:error, :not_found | term()}

  @doc """
  Returns the user_id of the room creator from the most recent m.room.create event.

  Returns `{:ok, String.t()}` on success.
  Returns `{:error, :not_found}` if no m.room.create event exists.
  Returns `{:error, reason}` on DB error.
  """
  @callback get_room_creator(room_id :: String.t()) ::
              {:ok, String.t()} | {:error, :not_found | term()}

  @doc """
  Returns the most recent state event per (event_type, state_key) for `room_id`,
  excluding types assembled from GenServer state (member, power_levels, create, name).

  Story 9-7: used by build_state_events/2 in EventDispatcher.Server to include
  state events set via PUT /rooms/{roomId}/state/{eventType}.

  Returns `{:ok, [%{type, state_key, content_json, sender}]}` on success. The real
  `Nebu.Matrix.Room.DB` additionally includes `event_id`/`origin_server_ts` in each
  map (bugfix sync-state-events-missing-fields, AC2) — `build_state_events/2` reads
  them defensively via `Map.get/3` (default `""` / `0`) so fakes that only return
  the original 4 keys are unaffected.
  Returns `{:error, reason}` on DB error.
  """
  @callback get_generic_state_events(room_id :: String.t()) ::
              {:ok, list(map())} | {:error, term()}

  @doc """
  Returns the content of the m.room.create event for `room_id` (the first such event
  by origin_server_ts ASC, i.e. the authoritative create event), plus its real
  identity.

  Used by build_state_events/2 so that upgraded rooms return their persisted
  m.room.create content (which includes the `predecessor` field) rather than a
  synthesized fallback that would omit predecessor.

  Returns `{:ok, content_map}` on success. Bugfix sync-state-events-missing-fields
  (AC2): the real `Nebu.Matrix.Room.DB` returns a wider `{:ok, content_map,
  event_id, origin_server_ts}` 4-tuple instead — same query, no extra DB round
  trip (hot path called on every `/sync`) — so `build_state_events/2` can thread
  real identity into the `m.room.create` state.events entry. Callers/fakes that
  only need existence/content (`check_parent_space_membership/2`,
  `parent_space_membership_ok?/2`, and any fake still returning the 2-tuple)
  continue to work unchanged.
  Returns `{:error, :not_found}` if no m.room.create event exists (new room not yet
  persisted, or pre-create-persist legacy room).
  Returns `{:error, reason}` on DB error.
  """
  @callback get_room_create_event(room_id :: String.t()) ::
              {:ok, map()}
              | {:ok, map(), String.t(), integer()}
              | {:error, :not_found | term()}

  @doc """
  Returns events in `room_id` that relate to `event_id` via `rel_type`.

  Queries JSONB content column for `m.relates_to` object.
  Story 9-28: up to `limit` events ordered newest first (DESC).
  Story 9-29: opts map extends behaviour:
    - `rel_type`: empty string = all relation types (no rel_type filter)
    - `event_type`: filter by event_type; empty = all event types
    - `dir`: "b" (DESC, default) or "f" (ASC)

  Returns `{:ok, [event_map]}` — empty list if no matching events.
  Returns `{:error, reason}` on DB error.

  Story 9-28: used by GetRelations gRPC handler and attach_thread_aggregations.
  Story 9-29: extended with opts for dir and event_type filtering.
  """
  @callback fetch_events_by_relation(
              room_id :: String.t(),
              event_id :: String.t(),
              rel_type :: String.t(),
              limit :: pos_integer(),
              opts :: map()
            ) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Returns the number of `m.thread` replies to `event_id` in `room_id`.

  Returns `{:ok, count}` — 0 when no thread replies exist.
  Returns `{:error, reason}` on DB error.

  Story 9-28: used by attach_thread_aggregations to build bundled aggregations.
  """
  @callback count_thread_children(room_id :: String.t(), event_id :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Returns `true` if `event_id` belongs to `room_id`, `false` otherwise.

  Fail-closed: DB errors return `false` so callers get a 404, not a 500.

  Story 9-28: room-scoped existence check used by GetRelations to prevent
  cross-room event-existence probing by room members.
  """
  @callback event_in_room?(event_id :: String.t(), room_id :: String.t()) :: boolean()

  @doc """
  Fetches a single event by `event_id` scoped to `room_id`.

  Returns `{:ok, event_map}` on success.
  Returns `{:error, :not_found}` if the event does not exist in this room.
  Returns `{:error, reason}` on DB error.

  Story 11-8: used by GetEvent gRPC handler (GET /rooms/{roomId}/event/{eventId}).
  """
  @callback fetch_event(event_id :: String.t(), room_id :: String.t()) ::
              {:ok, map()} | {:error, :not_found | term()}

  @doc """
  Returns the personal_room_id for `user_id`.

  Returns `{:ok, room_id}` when the user has a personal self-room.
  Returns `{:ok, nil}` when no personal self-room has been created yet.
  Returns `{:error, reason}` on DB error.

  Story personal-self-room: idempotency anchor for ensure_personal_room/1.
  """
  @callback get_personal_room_id(user_id :: String.t()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc """
  Sets `personal_room_id` for `user_id` when it is currently NULL.

  The WHERE personal_room_id IS NULL guard makes concurrent logins race-safe.

  Returns `:ok` on success (including the no-op case where the column was already set).
  Returns `{:error, reason}` on DB error.

  Story personal-self-room: called by ensure_personal_room/1 after room creation.
  """
  @callback set_personal_room_id(user_id :: String.t(), room_id :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Returns all room IDs that have is_auto_join=true and status='active'.

  Called by ensure_auto_join_memberships/1 when a new user is provisioned on first login.

  Returns `{:ok, [room_id]}` — empty list when no auto-join rooms exist.
  Returns `{:error, reason}` on DB error.

  Story admin-auto-join-rooms: auto-join enforcement at login time.
  """
  @callback list_auto_join_rooms() :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Returns all Space room IDs (`room_type = 'm.space'`) that have is_auto_join=true
  and status='active'.

  Spaces S5 (AC6): called by ensure_auto_join_space_memberships/1 when a new user is
  provisioned on first login. The complement of list_auto_join_rooms/0 (which is
  scoped to NON-spaces) so each flagged row is processed exactly once.

  Optional callback: fakes that predate Spaces S5 need not implement it.

  Returns `{:ok, [room_id]}` — empty list when no auto-join spaces exist.
  Returns `{:error, reason}` on DB error.
  """
  @callback list_auto_join_spaces() :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Returns whether `room_id` is an auto-join room/space (`rooms.is_auto_join = true`).

  Story rm5-personal-guards-optout: called by leave_room/2 after a successful leave
  to decide whether to record an auto-join opt-out for the leaving user.

  Optional callback: fakes that predate rm5 need not implement it (leave_room/2
  degrades gracefully via function_exported?/3).

  Returns `{:ok, true | false}` or `{:error, reason}` on DB error.
  """
  @callback auto_join_room?(room_id :: String.t()) :: {:ok, boolean()} | {:error, term()}

  @doc """
  Records that `user_id` opted out of auto-join room `room_id` at `opted_out_at` (ms).

  Story rm5-personal-guards-optout: idempotent upsert. Optional callback.

  Returns `:ok` or `{:error, reason}`.
  """
  @callback insert_auto_join_opt_out(
              room_id :: String.t(),
              user_id :: String.t(),
              opted_out_at :: integer()
            ) :: :ok | {:error, term()}

  @doc """
  Returns whether `user_id` has opted out of auto-join room `room_id`.

  Story rm5-personal-guards-optout: called by ensure_auto_join_memberships/1 and
  ensure_auto_join_space_memberships/1 to skip rooms the user left. Optional callback.

  Returns `{:ok, true | false}` or `{:error, reason}`.
  """
  @callback opted_out?(room_id :: String.t(), user_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @optional_callbacks delete_room: 1,
                      list_auto_join_spaces: 0,
                      auto_join_room?: 1,
                      insert_auto_join_opt_out: 3,
                      opted_out?: 2
end
