defmodule Nebu.Matrix.Room.DB do
  @moduledoc """
  PostgreSQL persistence layer for Room GenServers.

  Uses raw SQL via `Ecto.Adapters.SQL.query/3` — no Ecto schemas or changesets.
  All timestamps stored as BIGINT milliseconds per architecture enforcement rule #1.
  """

  require Logger

  @behaviour Nebu.Matrix.Room.DBBehaviour

  @sql_load_members """
  SELECT user_id FROM room_members
  WHERE room_id = $1 AND left_at IS NULL
  """

  @sql_check_room_exists """
  SELECT room_id, created_at, power_levels_json FROM rooms WHERE room_id = $1
  """

  # Bugfix sync-state-events-missing-fields (AC2/cluster-safety): real identity
  # (event_id, origin_server_ts) for each user's most recent m.room.member event —
  # needed so Room.Server.do_init/1 can restore member_identity after a crash/
  # restart instead of it silently reverting to nil.
  @sql_member_identities """
  SELECT DISTINCT ON (state_key) state_key, event_id, origin_server_ts
  FROM events
  WHERE room_id = $1 AND event_type = 'm.room.member'
  ORDER BY state_key, origin_server_ts DESC
  """

  # Bugfix sync-state-events-missing-fields (AC2 addendum/cluster-safety): real
  # identity for the room's current m.room.power_levels event — see
  # Room.Server.handle_call({:set_power_levels, ...}) which now emits this event.
  # Code-review cycle 1 (MINOR-2): sender is added to this SAME query (zero extra
  # DB round trips) so build_state_events/2 can carry the real sender alongside
  # event_id/origin_server_ts instead of leaving m.room.power_levels.sender "" —
  # now observably inconsistent once the event_id points at a real persisted row.
  @sql_power_levels_identity """
  SELECT event_id, origin_server_ts, sender FROM events
  WHERE room_id = $1 AND event_type = 'm.room.power_levels' AND state_key = ''
  ORDER BY origin_server_ts DESC LIMIT 1
  """

  @sql_insert_room """
  INSERT INTO rooms (room_id, visibility, created_at)
  VALUES ($1, 'private', $2)
  ON CONFLICT (room_id) DO NOTHING
  RETURNING created_at
  """

  @sql_insert_member """
  INSERT INTO room_members (room_id, user_id, joined_at)
  VALUES ($1, $2, $3)
  ON CONFLICT (room_id, user_id) DO UPDATE
  SET left_at = NULL, joined_at = EXCLUDED.joined_at
  WHERE room_members.left_at IS NOT NULL
  RETURNING user_id
  """

  @sql_soft_delete_member """
  UPDATE room_members SET left_at = $3
  WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL
  RETURNING user_id
  """

  # Hard-delete used ONLY by the failed-create rollback (story
  # admin-room-creator-provisioning, AC3). Deletes child rows first to satisfy the
  # FK constraints (events.room_id, room_members.room_id, room_aliases.room_id →
  # rooms.room_id), then the room itself. room_id is bound as a query parameter ($1)
  # — no SQL injection.
  #
  # room_aliases (story room-canonical-alias-from-name) has
  # `room_id TEXT NOT NULL REFERENCES rooms(room_id)` with NO ON DELETE CASCADE, so if
  # create_room registered a canonical alias and a LATER step raised, the orphan
  # cleanup would FK-fail on `DELETE FROM rooms` and roll back — leaving the exact
  # orphan room this rollback exists to remove. Deleting the alias rows first (FK
  # child before parent) keeps the cleanup transaction valid.
  @sql_delete_events_for_room "DELETE FROM events WHERE room_id = $1"
  @sql_delete_members_for_room "DELETE FROM room_members WHERE room_id = $1"
  @sql_delete_aliases_for_room "DELETE FROM room_aliases WHERE room_id = $1"
  @sql_delete_room "DELETE FROM rooms WHERE room_id = $1"

  @doc """
  Loads all active members for the given `room_id`.

  Returns `{:ok, [user_id], created_at_ms, power_levels_json, identity}` (possibly
  empty member list) if the room exists, where `identity` is
  `%{members: %{user_id => {event_id, origin_server_ts}}, power_levels: {event_id,
  origin_server_ts, sender} | nil}` — the real event identity for each member's
  join event and the power-levels event (bugfix sync-state-events-missing-fields,
  cluster-safety: `Room.Server.do_init/1` rebuilds `member_identity`/
  `power_levels_event` from this on every restart; without it they would silently
  revert to nil after a crash/restart). Code-review cycle 1 (MINOR-2): the
  power-levels tuple is now a 3-tuple carrying `sender` too (zero extra DB round
  trips — same query), so `build_state_events/2` no longer has to leave
  `m.room.power_levels`'s sender as `""`.
  Returns `{:error, :not_found}` if the room does not exist in the `rooms` table.
  Returns `{:error, reason}` on DB error.
  """
  @spec load_members(String.t()) ::
          {:ok, [String.t()], integer(), String.t(), map()} | {:error, :not_found | term()}
  def load_members(room_id) do
    # First check if room exists at all (also fetches created_at and power_levels_json)
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_check_room_exists, [room_id]) do
      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:ok, %{rows: [[_, created_at_ms, power_levels_json]]}} ->
        # Room exists — load members
        case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_members, [room_id]) do
          {:ok, %{rows: rows}} ->
            user_ids = Enum.map(rows, fn [uid] -> uid end)
            pl_json = power_levels_json || "{}"
            identity = load_member_power_levels_identity(room_id, user_ids)
            {:ok, user_ids, created_at_ms, pl_json, identity}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Bugfix sync-state-events-missing-fields (cluster-safety): fetches real
  # (event_id, origin_server_ts) identity for each active member's m.room.member
  # event and for the room's current m.room.power_levels event, so do_init/1 can
  # restore Room.Server state after a crash/restart without losing identity.
  # Fails open to empty identity on any DB error — do_init/1 must not be blocked
  # from starting the room just because this supplementary lookup failed.
  defp load_member_power_levels_identity(room_id, user_ids) do
    user_id_set = MapSet.new(user_ids)

    member_identity =
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_member_identities, [room_id]) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.filter(fn [uid, _event_id, _ts] -> MapSet.member?(user_id_set, uid) end)
          |> Map.new(fn [uid, event_id, ts] -> {uid, {event_id, ts}} end)

        {:error, _reason} ->
          %{}
      end

    power_levels_event =
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_power_levels_identity, [room_id]) do
        {:ok, %{rows: [[event_id, ts, sender]]}} -> {event_id, ts, sender}
        _ -> nil
      end

    %{members: member_identity, power_levels: power_levels_event}
  end

  @sql_update_room_name "UPDATE rooms SET name = $2 WHERE room_id = $1"

  @doc """
  Persist the room's display name into `rooms.name`. The Matrix timeline tracks the name
  via the `m.room.name` state event, but the denormalised `rooms.name` column is what the
  Admin UI (and any name-based lookup) reads, so it must be kept in sync on create/rename.
  """
  def update_room_name(room_id, name) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_update_room_name, [room_id, name]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_update_room_type "UPDATE rooms SET room_type = $2 WHERE room_id = $1"

  @doc """
  Persist the room's type into the denormalised `rooms.room_type` column.

  Matrix Spaces (spaces-elixir s1): a Space is a room whose `m.room.create` event has
  `content.type == "m.space"` (MSC1772). The type lives authoritatively in that event,
  but `rooms.room_type` is the denormalised column used for type-based lookups (Admin UI,
  hierarchy queries) without re-reading the create event. NULL == an ordinary room.

  The `room_type` value is bound as a query parameter ($2), never interpolated, so a
  client-supplied type string cannot be used for SQL injection.
  """
  def update_room_type(room_id, room_type) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_update_room_type, [room_id, room_type]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Inserts a new room into the `rooms` table.

  Returns `{:ok, created_at_ms}` on success.
  Returns `{:error, reason}` on DB failure.
  """
  @spec insert_room(String.t()) :: {:ok, integer()} | {:error, term()}
  def insert_room(room_id) do
    now_ms = Nebu.DB.Helpers.now_ms()

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_insert_room, [room_id, now_ms]) do
      {:ok, %{rows: [[created_at_ms]]}} ->
        {:ok, created_at_ms}

      {:ok, %{rows: []}} ->
        # ON CONFLICT DO NOTHING — room already exists (race condition); treat as ok
        {:ok, now_ms}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Inserts a member into `room_members`.

  Returns `:ok` on success.
  Returns `{:error, reason}` on DB failure.
  """
  @spec insert_member(String.t(), String.t()) :: :ok | {:error, term()}
  def insert_member(room_id, user_id) do
    now_ms = Nebu.DB.Helpers.now_ms()

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_insert_member, [room_id, user_id, now_ms]) do
      {:ok, %{rows: [[_]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        # ON CONFLICT DO NOTHING — already an active member
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Hard-deletes a room and everything that references it (events, members, aliases), in
  one transaction. Used by the failed-create rollback (story
  admin-room-creator-provisioning, AC3) so a create that fails after `m.room.create`
  leaves no orphan room. Idempotent: deleting an absent room returns `:ok`.

  Child rows are deleted before the parent `rooms` row to satisfy the FK constraints
  — this includes `room_aliases` (story room-canonical-alias-from-name), whose
  `room_id` FK has no ON DELETE CASCADE; omitting it would FK-fail the rollback and
  leave the orphan room.

  Returns `:ok` on success, `{:error, reason}` on DB failure.
  """
  @spec delete_room(String.t()) :: :ok | {:error, term()}
  def delete_room(room_id) do
    Nebu.Repo.transaction(fn ->
      with {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_events_for_room, [room_id]),
           {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_members_for_room, [room_id]),
           {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_aliases_for_room, [room_id]),
           {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_room, [room_id]) do
        :ok
      else
        {:error, reason} -> Nebu.Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Soft-deletes a member from `room_members` by setting `left_at`.

  Returns `:ok` on success.
  Returns `{:error, reason}` on DB failure.
  """
  @spec delete_member(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_member(room_id, user_id) do
    now_ms = Nebu.DB.Helpers.now_ms()

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_soft_delete_member, [room_id, user_id, now_ms]) do
      {:ok, %{rows: [[_]]}} ->
        :ok

      {:ok, %{rows: []}} ->
        # No active row matched — user was not an active member
        {:error, :not_member}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sql_get_rooms_for_user """
  SELECT room_id FROM room_members
  WHERE user_id = $1 AND left_at IS NULL
  """

  @doc """
  Returns all room IDs where `user_id` is currently an active member.

  Returns `{:ok, [room_id]}` — empty list if user has no active rooms.
  Returns `{:error, reason}` on DB error.
  """
  @spec get_rooms_for_user(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_rooms_for_user(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_rooms_for_user, [user_id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [rid] -> rid end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_get_recently_left_rooms_for_user """
  SELECT room_id FROM room_members
  WHERE user_id = $1 AND left_at IS NOT NULL
  """

  @doc """
  Returns all room IDs where `user_id` has left (left_at IS NOT NULL).

  Used by do_incremental_sync to include recently-left rooms in the initial
  fetch_delta_rooms check. Closes the race window where {new_leave} fires before
  the sync task subscribes to :pg groups, causing a 30 s long-poll delay.

  Returns `{:ok, [room_id]}` — empty list if user has no left rooms.
  Returns `{:error, reason}` on DB error.
  """
  @spec get_recently_left_rooms_for_user(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_recently_left_rooms_for_user(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_recently_left_rooms_for_user, [user_id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [rid] -> rid end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── forget-room-membership-purge: forgotten_rooms per-user preference store ──
  # The forgotten_rooms table (user_id, room_id, forgotten_at_ms) already exists in
  # 000001_init.up.sql (PRIMARY KEY (user_id, room_id), ON DELETE CASCADE on user_id).
  # Forget is orthogonal to room_members: it is a per-user preference that excludes a
  # left room from /sync until the user re-joins. All queries are parameter-bound (ADR-018).
  #
  # These three functions are NOT in Nebu.Matrix.Room.DBBehaviour by design: adding a
  # behaviour callback would force every injected FakeDB across the test suite to
  # implement it (warnings-as-errors → broken tests). The sync builders reach them via
  # a function_exported?/3 guard so injected fakes that lack them safely degrade to "no
  # forgotten rooms" without an UndefinedFunctionError.

  @sql_insert_forgotten_room """
  INSERT INTO forgotten_rooms (user_id, room_id)
  VALUES ($1, $2)
  ON CONFLICT (user_id, room_id) DO NOTHING
  """

  @doc """
  Records that `user_id` has forgotten `room_id`. Idempotent — a repeated forget
  is a no-op (`ON CONFLICT (user_id, room_id) DO NOTHING`).

  Returns `:ok` on success or `{:error, reason}` on DB failure.
  """
  @spec insert_forgotten_room(String.t(), String.t()) :: :ok | {:error, term()}
  def insert_forgotten_room(user_id, room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_insert_forgotten_room, [user_id, room_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_get_forgotten_room_ids """
  SELECT room_id FROM forgotten_rooms WHERE user_id = $1
  """

  @doc """
  Returns all room IDs that `user_id` has forgotten.

  Read fresh on every sync to exclude forgotten rooms from the response.

  Returns `{:ok, [room_id]}` — empty list if the user has forgotten nothing.
  Returns `{:error, reason}` on DB error.
  """
  @spec get_forgotten_room_ids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_forgotten_room_ids(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_forgotten_room_ids, [user_id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [rid] -> rid end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_remove_forgotten_room """
  DELETE FROM forgotten_rooms WHERE user_id = $1 AND room_id = $2
  """

  @doc """
  Removes the forgotten-room record for `(user_id, room_id)` — e.g. when the user
  re-joins a previously forgotten room (Matrix: a re-joined room is no longer
  forgotten). Idempotent: deleting an absent row returns `:ok`.

  Returns `:ok` on success or `{:error, reason}` on DB failure.
  """
  @spec remove_forgotten_room(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_forgotten_room(user_id, room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_remove_forgotten_room, [user_id, room_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_set_power_levels """
  UPDATE rooms SET power_levels_json = $2 WHERE room_id = $1
  """

  @doc """
  Persists the `power_levels_json` string for the given `room_id`.

  Returns `:ok` on success or `{:error, reason}` on DB failure.
  """
  @spec set_power_levels(String.t(), String.t()) :: :ok | {:error, term()}
  def set_power_levels(room_id, power_levels_json) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_set_power_levels, [room_id, power_levels_json]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_insert_event """
  INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
  """

  @doc """
  Inserts a signed event into the `events` append-only table.

  Expects the event map to have string keys: `"event_id"`, `"room_id"`, `"sender"`,
  `"type"`, `"content"`, `"origin_server_ts"`, and optionally `"signatures"` and
  `"state_key"` (Story 9-7: state events; nil/absent for regular events).

  JSONB columns (`content`, `signatures`) are JSON-encoded before passing to Postgrex.

  Returns `:ok` on success or `{:error, reason}` on DB failure.
  """
  @spec insert_event(map()) :: :ok | {:error, term()}
  def insert_event(event) do
    # Story 9-7: state_key is nil for regular (non-state) events and is stored
    # as NULL in the DB. State events always have a state_key — either "" (empty
    # string, the default for m.room.name, m.room.topic, m.room.join_rules, etc.)
    # or a user/server ID (e.g. for m.room.member). We pass the value through
    # unchanged so that "" is stored as "" (NOT NULL), making it visible to the
    # WHERE state_key IS NOT NULL query in get_generic_state_events/1.
    # (MAJOR-2 fix, code review story 9-7 — removing the erroneous "" -> nil branch)
    state_key = Map.get(event, "state_key")

    # Pass maps directly to Postgrex — Ecto+Postgrex encodes Elixir maps as JSONB
    # objects. Pre-encoding to a JSON string then passing to Postgrex causes double-
    # encoding: Postgrex treats the string as a JSON string literal (adds outer
    # quotes), so the DB stores a JSONB string instead of a JSONB object. That breaks
    # any JSONB path query (content->'m.relates_to'->>'event_id' etc.).
    case Ecto.Adapters.SQL.query(
           Nebu.Repo,
           @sql_insert_event,
           [
             event["event_id"],
             event["room_id"],
             event["sender"],
             event["type"],
             event["content"],
             event["origin_server_ts"],
             event["signatures"],
             state_key
           ]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_fetch_events_since """
  SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
  FROM events
  WHERE room_id = $1 AND origin_server_ts > $2
  ORDER BY origin_server_ts ASC
  LIMIT $3
  """

  @doc """
  Returns events in `room_id` with `origin_server_ts` strictly greater than
  the timestamp of `last_event_id`. Returns up to `limit` events in
  chronological order (ASC).

  If `last_event_id` is `nil` or `""`, uses `since_ts = 0` (return all events).
  If `get_event_timestamp/1` returns `{:error, :not_found}`, uses `since_ts = 0`
  (conservative fallback — treat as full sync).

  Returns `{:ok, [event_map]}` — empty list if no new events.
  """
  @spec fetch_events_since(String.t(), String.t() | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_events_since(room_id, last_event_id, limit) do
    since_ts =
      cond do
        is_nil(last_event_id) or last_event_id == "" ->
          0

        true ->
          case get_event_timestamp(last_event_id) do
            {:ok, ts} -> ts
            {:error, _} -> 0
          end
      end

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_fetch_events_since, [room_id, since_ts, limit]) do
      {:ok, %{columns: cols, rows: rows}} ->
        events =
          Enum.map(rows, fn row ->
            cols |> Enum.zip(row) |> Map.new()
          end)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sql_fetch_event """
  SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
  FROM events
  WHERE event_id = $1 AND room_id = $2
  LIMIT 1
  """

  @doc """
  Fetches a single event by `event_id` scoped to `room_id`.

  Returns `{:ok, event_map}` on success.
  Returns `{:error, :not_found}` if the event does not exist in this room.
  Returns `{:error, reason}` on DB error.
  """
  @spec fetch_event(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def fetch_event(event_id, room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_fetch_event, [event_id, room_id]) do
      {:ok, %{columns: cols, rows: [row]}} ->
        {:ok, cols |> Enum.zip(row) |> Map.new()}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sql_event_in_room "SELECT 1 FROM events WHERE event_id = $1 AND room_id = $2 LIMIT 1"

  @doc """
  Returns `true` if `event_id` belongs to `room_id`, `false` otherwise.

  Used by `get_relations` to prevent cross-room event-existence probing.
  Fail-closed: DB errors return `false` so missing events yield 404, not 500.
  """
  @spec event_in_room?(String.t(), String.t()) :: boolean()
  def event_in_room?(event_id, room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_event_in_room, [event_id, room_id]) do
      {:ok, %{rows: [_]}} -> true
      _                   -> false
    end
  end

  @sql_get_event_ts "SELECT origin_server_ts FROM events WHERE event_id = $1 LIMIT 1"

  @doc """
  Returns the `origin_server_ts` for the given `event_id`.

  Returns `{:ok, integer()}` on success.
  Returns `{:error, :not_found}` if the event does not exist.
  Returns `{:error, reason}` on DB error.
  """
  @spec get_event_timestamp(String.t()) :: {:ok, integer()} | {:error, :not_found | term()}
  def get_event_timestamp(event_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_event_ts, [event_id]) do
      {:ok, %{rows: [[ts]]}} -> {:ok, ts}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches paginated events from the `events` table for the given room.

  Pagination is keyset-based on `(origin_server_ts, event_id)` — both fields
  together provide a stable, unique cursor that avoids duplicates across pages.

  Token format: `"v1_" <> Base.url_encode64(ts_str <> ":" <> event_id, padding: false)`
  Empty token means "start from the beginning" (direction-dependent).

  Direction "b" (backward): newest first (DESC origin_server_ts, DESC event_id).
  Direction "f" (forward):  oldest first (ASC  origin_server_ts, ASC  event_id).

  Returns `{:ok, events, next_batch, prev_batch}` where:
  - `events` is a list of maps with string keys matching the `events` table columns
  - `next_batch` is the cursor for the next page (empty string if no more pages)
  - `prev_batch` is the cursor for the previous page (the from_token echoed back, or
    a token for the first event returned)
  """
  @spec fetch_events(String.t(), String.t(), integer(), String.t()) ::
          {:ok, [map()], String.t(), String.t()} | {:error, term()}
  def fetch_events(room_id, direction, limit, from_token) do
    {order, compare_op} =
      if direction == "f" do
        {"ASC", ">"}
      else
        {"DESC", "<"}
      end

    {where_clause, params} =
      case decode_token(from_token) do
        {:ok, cursor_ts, cursor_event_id} ->
          # Keyset: fetch events strictly before/after the cursor.
          # direction "b": WHERE (origin_server_ts, event_id) < (cursor_ts, cursor_event_id)
          # direction "f": WHERE (origin_server_ts, event_id) > (cursor_ts, cursor_event_id)
          clause = "(origin_server_ts, event_id) #{compare_op} ($2, $3)"
          {clause, [room_id, cursor_ts, cursor_event_id]}

        :empty ->
          {"TRUE", [room_id]}
      end

    param_offset = length(params)
    limit_param = "$#{param_offset + 1}"

    sql = """
    SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
    FROM events
    WHERE room_id = $1 AND #{where_clause}
    ORDER BY origin_server_ts #{order}, event_id #{order}
    LIMIT #{limit_param}
    """

    # Fetch limit+1 to detect whether a next page exists.
    all_params = params ++ [limit + 1]

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, all_params) do
      {:ok, %{columns: cols, rows: rows}} ->
        all_events =
          Enum.map(rows, fn row ->
            cols
            |> Enum.zip(row)
            |> Map.new()
          end)

        {page_events, has_more} =
          if length(all_events) > limit do
            {Enum.take(all_events, limit), true}
          else
            {all_events, false}
          end

        next_batch =
          if has_more do
            last = List.last(page_events)
            encode_token(last["origin_server_ts"], last["event_id"])
          else
            ""
          end

        prev_batch =
          case page_events do
            [] ->
              from_token

            events ->
              # Use the last event in the returned list as the prev_batch cursor.
              # For dir="b" (newest first), last = oldest; for dir="f" (oldest first),
              # last = newest. In both cases this is the "boundary" for the next page.
              last = List.last(events)
              encode_token(last["origin_server_ts"], last["event_id"])
          end

        {:ok, page_events, next_batch, prev_batch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_token(ts, event_id) when is_integer(ts) and is_binary(event_id) do
    raw = "#{ts}:#{event_id}"
    "v1_" <> Base.url_encode64(raw, padding: false)
  end

  defp decode_token(""), do: :empty
  defp decode_token(nil), do: :empty

  defp decode_token("v1_" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} ->
        case String.split(raw, ":", parts: 2) do
          [ts_str, event_id] ->
            case Integer.parse(ts_str) do
              {ts, ""} -> {:ok, ts, event_id}
              _ -> :empty
            end

          _ ->
            :empty
        end

      _ ->
        :empty
    end
  end

  defp decode_token(_), do: :empty

  @sql_load_room_settings """
  SELECT COALESCE(max_members, 0) FROM rooms WHERE room_id = $1
  """

  @doc """
  Loads mutable room settings (currently only max_members) for the given `room_id`.

  Returns `{:ok, max_members}` where max_members=0 means no limit.
  Returns `{:error, reason}` on DB error.

  Story 6.8: Called by Room.Server.init/1 to recover max_members after a GenServer restart.
  Fail-open: if this call fails, the GenServer defaults to 0 (no limit).
  """
  @spec load_room_settings(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_room_settings(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_room_settings, [room_id]) do
      {:ok, %{rows: [[max_members]]}} -> {:ok, max_members}
      {:ok, %{rows: []}} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  # room_id is the PRIMARY KEY of the rooms table — no LIMIT needed.
  @sql_get_room_status "SELECT COALESCE(status, 'active') FROM rooms WHERE room_id = $1"

  @doc """
  Returns the archival status of `room_id` from the `rooms` table.

  Returns `{:ok, "active"}` for active (non-archived) rooms.
  Returns `{:ok, "archived"}` for archived rooms.
  Returns `{:error, :not_found}` when the room does not exist in the table.
  Returns `{:error, reason}` on DB error.

  Story 6.9: Called by Room.Server.init/1 before initialising state.
  When the result is `{:ok, "archived"}`, init/1 returns `{:stop, :normal}`.
  """
  @spec get_room_status(String.t()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def get_room_status(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_room_status, [room_id]) do
      {:ok, %{rows: [[status]]}} -> {:ok, status}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Atomically checks if a room is archived using SELECT FOR UPDATE inside a transaction.

  Serialises this check with archive_room_atomic/1's UPDATE transaction, closing
  the TOCTOU race window between archive_room_atomic/1 and send_event insert.

  Returns `{:ok, "active"}` for active rooms.
  Returns `{:ok, "archived"}` for archived rooms.
  Returns `{:error, :not_found}` when the room does not exist.
  Returns `{:error, reason}` on DB error.

  Story 9-9: TOCTOU fix — called by Room.Server.handle_call({:send_event, ...})
  before building the event map on a cache miss.
  """
  @spec check_room_status_for_update(String.t()) ::
          {:ok, String.t()} | {:error, :not_found | term()}
  def check_room_status_for_update(room_id) do
    result =
      Nebu.Repo.transaction(fn ->
        case Ecto.Adapters.SQL.query!(
               Nebu.Repo,
               "SELECT COALESCE(status, 'active') FROM rooms WHERE room_id = $1 FOR UPDATE",
               [room_id]
             ) do
          %{rows: [[status]]} -> status
          %{rows: []} -> Nebu.Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, status} -> {:ok, status}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the room name from the most recent m.room.name event, or {:error, :not_found}.

  Content is stored as a JSONB string (Postgrex encodes the map as a JSON string before
  inserting, so the JSONB column contains a string value, not an object). The query handles
  both forms:
    - JSONB object  {"name": "…"}  → content->>'name' works directly
    - JSONB string  "{"name":"…"}" → (content#>>'{}')::jsonb->>'name' extracts via the
                                     text path operator first
  """
  @spec get_room_creator(String.t()) :: {:ok, String.t()} | {:error, :not_found | term()}
  def get_room_creator(room_id) do
    sql = """
    SELECT sender FROM events
    WHERE room_id = $1 AND event_type = 'm.room.create'
    ORDER BY origin_server_ts ASC LIMIT 1
    """
    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id]) do
      {:ok, %{rows: [[sender]]}} when not is_nil(sender) -> {:ok, sender}
      {:ok, _} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the content map of the authoritative m.room.create event for `room_id`,
  plus its real identity.

  Queries the events table for the first m.room.create event (ASC origin_server_ts)
  and decodes its JSONB content. Handles both Postgrex JSONB forms:
    - JSONB object  {"creator":"…","room_version":"10","predecessor":{…}}
    - JSONB string  "{\"creator\":\"…\"}"  — doubly-encoded JSON string

  Returns `{:ok, content_map, event_id, origin_server_ts}` on success. Bugfix
  sync-state-events-missing-fields (AC2): `event_id`/`origin_server_ts` are added
  to the SAME query (no extra DB round trip — this is a hot path called on every
  `/sync`) so `build_state_events/2` can thread real identity into the
  `m.room.create` state.events entry. Callers that only need the content
  (`check_parent_space_membership/2`, `parent_space_membership_ok?/2`) continue to
  work against the original `{:ok, content_map}` 2-tuple too, via
  `normalize_create_event_result/1` in EventDispatcher.Server — test fakes that
  predate this widening and still return the 2-tuple remain fully supported.
  Returns `{:error, :not_found}` when no m.room.create event exists.
  Returns `{:error, reason}` on DB / decode error.
  """
  @spec get_room_create_event(String.t()) ::
          {:ok, map(), String.t(), integer()} | {:error, :not_found | term()}
  def get_room_create_event(room_id) do
    sql = """
    SELECT CASE
      WHEN jsonb_typeof(content) = 'object' THEN content::text
      ELSE (content#>>'{}')
    END, event_id, origin_server_ts
    FROM events
    WHERE room_id = $1 AND event_type = 'm.room.create'
    ORDER BY origin_server_ts ASC LIMIT 1
    """
    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id]) do
      {:ok, %{rows: [[content_text, event_id, ts]]}} when not is_nil(content_text) ->
        case Jason.decode(content_text) do
          {:ok, map} when is_map(map) -> {:ok, map, event_id, ts}
          _                           -> {:error, :not_found}
        end

      {:ok, _} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the hero list and member counts for `room_id`, excluding `exclude_user_id`.

  Hero computation rules (Matrix CS API §11.2.2.5):
  - Pool: joined members (left_at IS NULL) + invited members (pending invitation).
  - Syncing user is excluded from the pool.
  - Joined members are listed first (by joined_at ASC), then invited members (by invited_at ASC).
  - Total capped at 5.
  - `joined` = COUNT of active members (left_at IS NULL).
  - `invited` = COUNT of pending invitations (accepted_at IS NULL AND rejected_at IS NULL).

  Returns `{:ok, %{heroes: [String.t()], joined: integer(), invited: integer()}}`.
  Returns `{:error, reason}` on DB error.

  Story direct-room-heroes: called by event_dispatcher/server.ex to populate SyncRoom.heroes,
  SyncRoom.joined_member_count, and SyncRoom.invited_member_count.
  """
  @spec get_room_heroes(String.t(), String.t()) ::
          {:ok, %{heroes: [String.t()], joined: integer(), invited: integer()}} | {:error, term()}
  def get_room_heroes(room_id, exclude_user_id) do
    heroes_sql = """
    (SELECT user_id, joined_at FROM room_members
     WHERE room_id = $1 AND user_id != $2 AND left_at IS NULL
     ORDER BY joined_at ASC LIMIT 5)
    UNION ALL
    (SELECT invitee_id AS user_id, invited_at AS joined_at FROM room_invitations
     WHERE room_id = $1 AND invitee_id != $2
       AND accepted_at IS NULL AND rejected_at IS NULL
     ORDER BY invited_at ASC)
    LIMIT 5
    """
    joined_sql = """
    SELECT COUNT(*) FROM room_members
    WHERE room_id = $1 AND left_at IS NULL
    """
    invited_sql = """
    SELECT COUNT(*) FROM room_invitations
    WHERE room_id = $1 AND accepted_at IS NULL AND rejected_at IS NULL
    """
    with {:ok, %{rows: hero_rows}} <-
           Ecto.Adapters.SQL.query(Nebu.Repo, heroes_sql, [room_id, exclude_user_id]),
         {:ok, %{rows: [[joined]]}} <-
           Ecto.Adapters.SQL.query(Nebu.Repo, joined_sql, [room_id]),
         {:ok, %{rows: [[invited]]}} <-
           Ecto.Adapters.SQL.query(Nebu.Repo, invited_sql, [room_id]) do
      heroes = Enum.map(hero_rows, fn [user_id, _joined_at] -> user_id end)
      {:ok, %{heroes: heroes, joined: joined, invited: invited}}
    end
  end

  @doc """
  Returns the room's current display name (from the most recent m.room.name
  event), plus its real identity.

  Bugfix sync-state-events-missing-fields (AC2): `event_id`/`origin_server_ts`
  are added to this SAME query (no extra DB round trip — hot path called on
  every `/sync`) so `build_state_events/2` can thread real identity into the
  `m.room.name` state.events entry. Code-review cycle 1 (MINOR-2): `sender` is
  added too (same query, still zero extra round trips) so `m.room.name`'s
  sender is no longer left as `""` once its event_id points at a real
  persisted row.

  Returns `{:ok, name, event_id, origin_server_ts, sender}` on success.
  Returns `{:error, :not_found}` if no m.room.name event exists.
  Returns `{:error, reason}` on DB error.

  Code-review cycle 1 (MINOR): `m.room.name` only ever has `state_key = ''`
  per the Matrix spec, but the generic `PUT /state/{eventType}` endpoint does
  not special-case that (`m.room.name` is on `@writable_state_types` with no
  per-type state_key restriction) — a client could in principle
  `PUT /state/m.room.name/<non-empty-state-key>`, landing a row at a
  DIFFERENT slot that this query, without the filter, would still pick up as
  "the" room name and feed into `build_state_events/2`'s
  `replaces_state` LATERAL chain for the wrong slot. The `AND state_key = ''`
  filter keeps this query scoped to the one slot `m.room.name` is actually
  meant to occupy.

  Code-review cycle 2 (bugfix unsigned-replaces-state) briefly changed this
  filter to `COALESCE(state_key, '') = ''`, on the premise that a legacy room's
  `m.room.name` event could have `state_key IS NULL` (pre-dating the
  `do_send_event/7` writer fix or migration 000036's backfill). Code-review
  cycle 3 (MAJOR-2) verified that premise FALSE: no genuine `m.room.name` row
  has ever had a NULL `state_key` — every writer of this event type
  (`do_create_room/3`, the generic `PUT /state/m.room.name` handler) always
  passes the literal `""`. Meanwhile, `state_key IS NULL` on an
  `m.room.name`-typed row is exactly what a NON-state write produces: the
  generic non-state `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.name/
  {txnId}` path (reachable by ANY joined member, gated only by the
  `:send_event` power level — not `set_room_state/2`'s `:change_state` check)
  always persists with `state_key = nil` (`do_send_event/7`'s `state_key`
  parameter is always `nil` on this path — see that function's own comment).
  The `COALESCE` therefore re-admitted exactly the row this filter exists to
  keep out: a bogus `m.room.name` sent through the non-state path would be
  picked up here (if more recent) and silently become "the" room name for
  every member, bypassing the power-level check the dedicated rename endpoint
  enforces. Reverted to a bare `state_key = ''` — a NULL `state_key` row is
  never a genuine `m.room.name` state event and must never match here.
  """
  @spec get_room_name(String.t()) ::
          {:ok, String.t(), String.t(), integer(), String.t()} | {:error, :not_found | term()}
  def get_room_name(room_id) do
    sql = """
    SELECT CASE
      WHEN jsonb_typeof(content) = 'object' THEN content->>'name'
      ELSE ((content#>>'{}')::jsonb)->>'name'
    END, event_id, origin_server_ts, sender
    FROM events
    WHERE room_id = $1 AND event_type = 'm.room.name' AND state_key = ''
    ORDER BY origin_server_ts DESC LIMIT 1
    """
    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id]) do
      {:ok, %{rows: [[name, event_id, ts, sender]]}} when not is_nil(name) ->
        {:ok, name, event_id, ts, sender}

      {:ok, _} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns events in `room_id` that relate to `event_id`, optionally filtered by `rel_type`.

  Story 9-28: original 4-arity variant — always filters by rel_type, newest-first (DESC).
  Story 9-29: 5-arity variant with opts map for extended behaviour:
    - `rel_type` empty string = no rel_type filter (return all relation types)
    - opts `event_type`: filter by event_type; empty = all event types
    - opts `dir`: "b" (DESC, default) or "f" (ASC)

  Returns `{:ok, [event_map]}` — empty list if no matching events.
  Returns `{:error, reason}` on DB error.

  Story 9-28: used by GetRelations gRPC handler and attach_thread_aggregations.
  Story 9-29: extended with opts for dir and event_type filtering.
  """
  @spec fetch_events_by_relation(String.t(), String.t(), String.t(), pos_integer(), map()) ::
          {:ok, [map()]} | {:error, term()}
  # `limit` is clamped to a minimum of 1 internally — a caller passing 0 yields LIMIT 1.
  def fetch_events_by_relation(room_id, event_id, rel_type, limit, opts \\ %{}) do
    limit      = max(1, limit)
    event_type = Map.get(opts, :event_type, "")

    # dir is sanitised here: only "f" produces ASC; any other value (including unexpected
    # values) defaults to "DESC" so the DB layer is never exposed to an invalid ORDER BY.
    order_dir  =
      case Map.get(opts, :dir, "b") do
        "f" -> "ASC"
        _   -> "DESC"
      end

    # Build WHERE clauses dynamically.
    # Fixed params: $1=room_id, $2=event_id. Optional filter params follow.
    # LIMIT param index is determined after all optional filters are assigned.
    {extra_where, base_params, limit_idx} =
      []
      |> add_rel_type_clause(rel_type)
      |> add_event_type_clause(event_type)
      |> build_where_and_params([room_id, event_id], 3)

    sql = """
    SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
    FROM events
    WHERE room_id = $1
      AND content->'m.relates_to'->>'event_id' = $2
      #{extra_where}
    ORDER BY origin_server_ts #{order_dir}, event_id #{order_dir}
    LIMIT $#{limit_idx}
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, base_params ++ [limit]) do
      {:ok, %{columns: cols, rows: rows}} ->
        events =
          Enum.map(rows, fn row ->
            cols |> Enum.zip(row) |> Map.new()
          end)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private helpers for fetch_events_by_relation SQL building ──────────────

  # Returns a clause list with a rel_type filter appended (unless rel_type is empty).
  defp add_rel_type_clause(clauses, ""), do: clauses
  defp add_rel_type_clause(clauses, rel_type), do: clauses ++ [{:rel_type, rel_type}]

  # Returns a clause list with an event_type filter appended (unless event_type is empty).
  defp add_event_type_clause(clauses, ""), do: clauses
  defp add_event_type_clause(clauses, event_type), do: clauses ++ [{:event_type, event_type}]

  # Converts a list of {kind, value} tuples into a SQL WHERE fragment and params list.
  # fixed_params contains the already-bound positional params ($1..$N-1).
  # next_idx starts as length(fixed_params) + 1.
  defp build_where_and_params(clauses, fixed_params, next_idx) do
    {where_parts, extra_params, final_idx} =
      Enum.reduce(clauses, {[], [], next_idx}, fn {kind, val}, {parts, params, idx} ->
        sql_fragment =
          case kind do
            :rel_type   -> "AND content->'m.relates_to'->>'rel_type' = $#{idx}"
            :event_type -> "AND event_type = $#{idx}"
          end
        {parts ++ [sql_fragment], params ++ [val], idx + 1}
      end)

    extra_sql = Enum.join(where_parts, "\n  ")
    {extra_sql, fixed_params ++ extra_params, final_idx}
  end

  @sql_count_thread_children """
  SELECT COUNT(*)
  FROM events
  WHERE room_id = $1
    AND content->'m.relates_to'->>'rel_type' = 'm.thread'
    AND content->'m.relates_to'->>'event_id' = $2
  """

  @doc """
  Returns the number of `m.thread` replies to `event_id` in `room_id`.

  Returns `{:ok, count}` — 0 when no thread replies exist.
  Returns `{:error, reason}` on DB error.

  Story 9-28: used by attach_thread_aggregations to build bundled aggregations.
  """
  @spec count_thread_children(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_thread_children(room_id, event_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_count_thread_children, [room_id, event_id]) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:ok, _} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Story personal-self-room: personal_room_id helpers ─────────────────────

  @sql_get_personal_room_id """
  SELECT personal_room_id FROM users WHERE user_id = $1
  """

  @doc """
  Returns the personal_room_id for the given `user_id`.

  Returns `{:ok, room_id}` when the column is set (non-nil).
  Returns `{:ok, nil}` when the user exists but has no personal self-room yet.
  Returns `{:error, reason}` on DB error.

  Story personal-self-room: called by ensure_personal_room/1 to check whether
  a self-room already exists (idempotency anchor).
  """
  @spec get_personal_room_id(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def get_personal_room_id(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_personal_room_id, [user_id]) do
      {:ok, %{rows: [[room_id]]}} -> {:ok, room_id}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_set_personal_room_id """
  UPDATE users SET personal_room_id = $2
  WHERE user_id = $1 AND personal_room_id IS NULL
  """

  @doc """
  Sets the personal_room_id for `user_id` to `room_id`, but only when it is currently NULL.

  The `WHERE personal_room_id IS NULL` guard prevents duplicate self-room creation in
  a concurrent-login race: the second UPDATE simply matches zero rows.

  Returns `:ok` when the row was claimed.
  Returns `{:ok, :already_set}` when another concurrent caller won the race (0 rows updated).
  Returns `{:error, reason}` on DB error.

  Callers that receive `{:ok, :already_set}` created an orphan room (no security impact —
  the user owns it — but it appears in /sync). Known race; see F-3 in the epic security review.
  """
  @spec set_personal_room_id(String.t(), String.t()) :: :ok | {:ok, :already_set} | {:error, term()}
  def set_personal_room_id(user_id, room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_set_personal_room_id, [user_id, room_id]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:ok, :already_set}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Story admin-auto-join-rooms: list_auto_join_rooms/0 ───────────────────

  # Spaces S5: SCOPED to non-spaces so plain rooms and spaces never double-process.
  # A Space (room_type = 'm.space') is auto-joined via list_auto_join_spaces/0 instead.
  # A plain room has room_type NULL (legacy/ordinary) or any non-space type.
  @sql_list_auto_join_rooms """
  SELECT room_id FROM rooms
  WHERE is_auto_join = true
    AND status = 'active'
    AND (room_type IS NULL OR room_type != 'm.space')
  """

  @doc """
  Returns all NON-SPACE room IDs that have is_auto_join=true and are active.

  Called by ensure_auto_join_memberships/1 in EventDispatcher.Server when a new
  user is provisioned on first login.

  Spaces S5: scoped to `room_type IS NULL OR room_type != 'm.space'` so a flagged
  Space is NOT returned here (it is handled by list_auto_join_spaces/0). This keeps
  the room and space auto-join paths from double-processing the same row.

  Returns `{:ok, [room_id]}` — empty list when no auto-join rooms exist.
  Returns `{:error, reason}` on DB error.
  """
  @spec list_auto_join_rooms() :: {:ok, [String.t()]} | {:error, term()}
  def list_auto_join_rooms do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_list_auto_join_rooms, []) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [rid] -> rid end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Spaces S5: list_auto_join_spaces/0 ────────────────────────────────────

  @sql_list_auto_join_spaces """
  SELECT room_id FROM rooms
  WHERE room_type = 'm.space'
    AND is_auto_join = true
    AND status = 'active'
  """

  @doc """
  Returns all Space room IDs (`room_type = 'm.space'`) that have is_auto_join=true
  and are active.

  Spaces S5 (AC6): called by ensure_auto_join_space_memberships/1 in
  EventDispatcher.Server when a new user is provisioned on first login. The
  complement of list_auto_join_rooms/0 — together they cover every auto-join row
  exactly once.

  Returns `{:ok, [room_id]}` — empty list when no auto-join spaces exist.
  Returns `{:error, reason}` on DB error.
  """
  @spec list_auto_join_spaces() :: {:ok, [String.t()]} | {:error, term()}
  def list_auto_join_spaces do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_list_auto_join_spaces, []) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [rid] -> rid end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Story rm5-personal-guards-optout: auto-join opt-out helpers ────────────

  @sql_auto_join_room """
  SELECT is_auto_join FROM rooms WHERE room_id = $1
  """

  @doc """
  Returns whether `room_id` is an auto-join room/space (`rooms.is_auto_join = true`).

  Story rm5: called by leave_room/2 after a successful leave to decide whether to
  record an auto-join opt-out for the leaving user. A Space is a room, so this
  single flag covers both plain auto-join rooms and auto-join Spaces.

  Returns `{:ok, true | false}` (false when the room does not exist) or
  `{:error, reason}` on DB error.
  """
  @spec auto_join_room?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def auto_join_room?(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_auto_join_room, [room_id]) do
      {:ok, %{rows: [[flag]]}} -> {:ok, flag == true}
      {:ok, %{rows: []}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_insert_auto_join_opt_out """
  INSERT INTO auto_join_opt_outs (room_id, user_id, opted_out_at)
  VALUES ($1, $2, $3)
  ON CONFLICT (room_id, user_id) DO NOTHING
  """

  @doc """
  Records that `user_id` has opted out of the auto-join room `room_id`.

  Story rm5: idempotent upsert (`ON CONFLICT (room_id, user_id) DO NOTHING`) so
  repeated leaves of the same auto-join room never raise or duplicate. The PK +
  FK on the table are the data-layer guarantees; the ON CONFLICT keeps the write
  side idempotent. `opted_out_at` is a BIGINT millisecond timestamp.

  Returns `:ok` on success or `{:error, reason}` on DB error.
  """
  @spec insert_auto_join_opt_out(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def insert_auto_join_opt_out(room_id, user_id, opted_out_at) do
    case Ecto.Adapters.SQL.query(
           Nebu.Repo,
           @sql_insert_auto_join_opt_out,
           [room_id, user_id, opted_out_at]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_opted_out """
  SELECT 1 FROM auto_join_opt_outs WHERE room_id = $1 AND user_id = $2
  """

  @doc """
  Returns whether `user_id` has opted out of auto-join room `room_id`.

  Story rm5: called by ensure_auto_join_memberships/1 and
  ensure_auto_join_space_memberships/1 to skip rooms/spaces the user has left.

  Returns `{:ok, true | false}` or `{:error, reason}` on DB error.
  """
  @spec opted_out?(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def opted_out?(room_id, user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_opted_out, [room_id, user_id]) do
      {:ok, %{num_rows: n}} -> {:ok, n > 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Bugfix unsigned-replaces-state (Matrix CS API v1.19): batched "what state
  event did THIS one replace at its (room_id, event_type, state_key) slot"
  lookup. ONE query for the WHOLE `slots` list (AC5 — MANDATORY: callers must
  never invoke this once per state event or once per response-item; always
  collect every slot that needs an answer first and call this once).

  `slots` is a list of `{event_id, room_id, event_type, state_key,
  origin_server_ts}` 5-tuples — one per CURRENT state event a caller wants a
  predecessor for. `event_id`/`origin_server_ts` identify the CURRENT event
  (the tie-break/ordering anchor); `room_id`/`event_type`/`state_key` identify
  its slot.

  Returns `%{event_id => predecessor_event_id}` — ONLY for slots that actually
  have an earlier row at that slot (AC3: a slot with no predecessor is simply
  ABSENT from the result map; callers must treat a missing key as "no
  replaces_state", never synthesize null/"").

  Same-`origin_server_ts` ties are broken by `event_id` (AC5/AC7): the
  predecessor is the row with the largest `(origin_server_ts, event_id)` tuple
  that is still strictly less than the current event's own tuple, via a
  `LATERAL` join against `events_room_state_idx
  (room_id, event_type, state_key, origin_server_ts DESC)`.

  Not part of `Nebu.Matrix.Room.DBBehaviour` (same precedent as
  `get_generic_state_events/1` / `get_space_children/1` below — a read helper,
  not part of the Room GenServer's persistence surface) — callers MUST guard
  with `function_exported?/3` before invoking an injected test double that may
  not implement it (see `Nebu.Matrix.EventDispatcher.Server`'s
  `fetch_replaces_state_batch/2` wrapper), so this never breaks a Repo-less
  FakeDB-based unit test.
  """
  @spec fetch_replaces_state([{String.t(), String.t(), String.t(), String.t(), integer()}]) ::
          %{String.t() => String.t()}
  def fetch_replaces_state([]), do: %{}

  def fetch_replaces_state(slots) when is_list(slots) do
    {event_ids, room_ids, event_types, state_keys, origin_server_ts_list} =
      Enum.reduce(slots, {[], [], [], [], []}, fn
        {event_id, room_id, event_type, state_key, ts}, {eids, rids, ets, sks, tss} ->
          {[event_id | eids], [room_id | rids], [event_type | ets], [state_key | sks], [ts | tss]}
      end)

    sql = """
    SELECT req.event_id, e.event_id AS replaces_state
    FROM UNNEST($1::text[], $2::text[], $3::text[], $4::text[], $5::bigint[])
         AS req(event_id, room_id, event_type, state_key, origin_server_ts)
    LEFT JOIN LATERAL (
      SELECT e2.event_id
      FROM events e2
      WHERE e2.room_id = req.room_id
        AND e2.event_type = req.event_type
        AND e2.state_key = req.state_key
        AND (e2.origin_server_ts, e2.event_id) < (req.origin_server_ts, req.event_id)
      ORDER BY e2.origin_server_ts DESC, e2.event_id DESC
      LIMIT 1
    ) e ON true
    """

    case Ecto.Adapters.SQL.query(
           Nebu.Repo,
           sql,
           [event_ids, room_ids, event_types, state_keys, origin_server_ts_list]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, %{}, fn
          [_event_id, nil], acc -> acc
          [event_id, replaces_state], acc -> Map.put(acc, event_id, replaces_state)
        end)

      {:error, reason} ->
        # Code-review cycle 1 (MINOR): a dropped index, missing GRANT, or
        # statement timeout here would otherwise silently disable
        # unsigned.replaces_state for every slot in `slots`, indistinguishable
        # from "no predecessor exists anywhere" (AC3's legitimate absent
        # case). Logger.warning makes a genuine DB failure observable instead.
        Logger.warning(
          "fetch_replaces_state: batched replaces_state lookup failed for " <>
            "#{length(slots)} slot(s), replaces_state disabled for this response: " <>
            "#{inspect(reason)}"
        )

        %{}
    end
  end

  @doc """
  Returns the most recent state event per (event_type, state_key) for `room_id`,
  excluding event types handled separately (m.room.member, m.room.power_levels,
  m.room.create, m.room.name — those have dedicated DB helpers or are assembled
  from GenServer state).

  Story 9-7: extends build_state_events in EventDispatcher.Server to include
  state events set via PUT /rooms/{roomId}/state/{eventType}.

  Returns `{:ok, [%{type, state_key, content_json, sender, event_id, origin_server_ts}]}`
  or `{:error, reason}`. Bugfix sync-state-events-missing-fields (AC2): `event_id`/
  `origin_server_ts` are the real persisted values (both columns already exist on
  `events` and are already used in the `ORDER BY` below) — added so `/sync`'s
  state.events entries carry real identity like timeline.events do.
  """
  @spec get_generic_state_events(String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def get_generic_state_events(room_id) do
    sql = """
    SELECT DISTINCT ON (event_type, state_key)
      event_type, state_key, content::text, sender, event_id, origin_server_ts
    FROM events
    WHERE room_id = $1
      AND state_key IS NOT NULL
      AND event_type NOT IN (
        'm.room.member',
        'm.room.power_levels',
        'm.room.create',
        'm.room.name'
      )
    ORDER BY event_type, state_key, origin_server_ts DESC
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id]) do
      {:ok, %{rows: rows}} ->
        events =
          Enum.map(rows, fn [event_type, state_key, content_json, sender, event_id, origin_server_ts] ->
            %{
              type: event_type,
              state_key: state_key || "",
              content_json: content_json || "{}",
              sender: sender || "",
              event_id: event_id || "",
              origin_server_ts: origin_server_ts || 0
            }
          end)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current `m.space.child` edges of `room_id` (Spaces S3 / MSC2946).

  Reads the latest `m.space.child` event per `state_key` (DISTINCT ON, newest
  origin_server_ts), backed by `idx_events_space_child`. The `state_key` is the
  child room id; `content` is decoded to a map (carries `order`, `via`,
  `suggested`). Children whose latest content is empty (`{}` — the S2 unlink) are
  dropped — they are no longer part of the space. Ordered by the MSC1772 `order`
  key (NULLs last) then by child room id, so the BFS is deterministic.

  Returns `{:ok, [{child_room_id, content_map}]}` or `{:error, reason}`.

  Not part of `Nebu.Matrix.Room.DBBehaviour` (that contract is the Room
  GenServer's persistence surface); this is a server-side read helper used only
  by the SpaceHierarchy traversal.
  """
  def get_space_children(room_id) do
    sql = """
    SELECT state_key, content_text FROM (
      SELECT DISTINCT ON (state_key)
        state_key,
        CASE
          WHEN jsonb_typeof(content) = 'object' THEN content::text
          ELSE (content#>>'{}')
        END AS content_text
      FROM events
      WHERE room_id = $1
        AND event_type = 'm.space.child'
        AND state_key IS NOT NULL
      ORDER BY state_key, origin_server_ts DESC
    ) latest
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id]) do
      {:ok, %{rows: rows}} ->
        children =
          rows
          |> Enum.map(fn [state_key, content_text] ->
            content =
              case content_text && Jason.decode(content_text) do
                {:ok, map} when is_map(map) -> map
                _ -> %{}
              end

            {state_key, content}
          end)
          # An empty-content child is an unlinked edge (S2 unlink semantics) — drop it.
          |> Enum.reject(fn {_child, content} -> content == %{} end)
          # Deterministic order: MSC1772 `order` key (string), then child room id.
          |> Enum.sort_by(fn {child, content} ->
            {to_string(Map.get(content, "order", "")), child}
          end)

        {:ok, children}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Room aliases (story room-canonical-alias-from-name) ─────────────────────

  @sql_insert_room_alias """
  INSERT INTO room_aliases (alias, room_id, created_at)
  VALUES ($1, $2, $3)
  """

  @doc """
  Registers `alias_str` (`#localpart:server`) for `room_id` in the server-wide
  room_aliases directory.

  The `alias` column is the PRIMARY KEY, so a second registration of the same alias is
  rejected by the unique constraint. We translate that into `{:error, :conflict}` so the
  caller can deterministically retry the next candidate (`#localpart-2:server`, …) — this
  is the race-safe collision scheme (ADR-020): no read-then-write, the DB decides the
  winner. Both `alias_str` and `room_id` are bound as query parameters (no SQL injection;
  the name is external input — see story SEC notes).

  Returns `:ok` on success, `{:error, :conflict}` on a unique-constraint violation, and
  `{:error, reason}` on any other DB failure.
  """
  @spec insert_room_alias(String.t(), String.t(), integer()) ::
          :ok | {:error, :conflict} | {:error, term()}
  def insert_room_alias(alias_str, room_id, created_at) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_insert_room_alias, [alias_str, room_id, created_at]) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        {:error, :conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sql_lookup_alias "SELECT room_id FROM room_aliases WHERE alias = $1"

  @doc """
  Resolves a room alias (`#localpart:server`) to its room id.

  Returns `{:ok, room_id}` if registered, `{:error, :not_found}` otherwise,
  `{:error, reason}` on a DB failure. `alias_str` is bound as a query parameter.
  """
  @spec lookup_alias(String.t()) :: {:ok, String.t()} | {:error, :not_found} | {:error, term()}
  def lookup_alias(alias_str) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lookup_alias, [alias_str]) do
      {:ok, %{rows: [[room_id]]}} -> {:ok, room_id}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

end
