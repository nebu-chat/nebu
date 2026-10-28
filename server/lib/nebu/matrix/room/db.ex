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
  # identity for the room's current m.room.power_levels event — see the power-level
  # writer of Room.Server (story power-levels-enforcement), which emits this event.
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
  # room_invitations.room_id REFERENCES rooms(room_id) (no ON DELETE CASCADE): story create-room-invites-direct (D8)
  @sql_delete_invitations_for_room "DELETE FROM room_invitations WHERE room_id = $1"
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
  Hard-deletes a room and everything that references it (events, members, aliases, invitations), in
  one transaction. Used by the failed-create rollback (story
  admin-room-creator-provisioning, AC3) so a create that fails after `m.room.create`
  leaves no orphan room. Idempotent: deleting an absent room returns `:ok`.

  Child rows are deleted before the parent `rooms` row to satisfy the FK constraints
  — this includes `room_aliases` (story room-canonical-alias-from-name), whose
  `room_id` FK has no ON DELETE CASCADE; omitting it would FK-fail the rollback and
  leave the orphan room. The same holds for `room_invitations` (story create-room-invites-direct, D8: a createRoom
  whose step 8 fails after the first invitation row must still be cleaned up), whatever the state of the row
  (pending, accepted, rejected).

  Returns `:ok` on success, `{:error, reason}` on DB failure.
  """
  @spec delete_room(String.t()) :: :ok | {:error, term()}
  def delete_room(room_id) do
    Nebu.Repo.transaction(fn ->
      with {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_events_for_room, [room_id]),
           {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_members_for_room, [room_id]),
           {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_aliases_for_room, [room_id]),
           {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_delete_invitations_for_room, [room_id]),
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

  NOT used by the sync since story sync-membership-partition: the sync classifies rooms with `membership_candidates/1` and
  `latest_member_events/2` (a left room is no longer re-fetched on every sync). Kept (and in `DBBehaviour`) so the
  behaviour and the existing fakes stay unchanged.

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

  @doc """
  ONE power-level change of `room_id` in ONE `Nebu.Repo.transaction/1` (story power-levels-enforcement, D10; the only caller
  is the room process, `Nebu.Matrix.Room.Server`): `SET LOCAL lock_timeout = '1s'`, the archived check (`FOR NO KEY UPDATE`: the
  row is updated right after, so it is locked for the update at once instead of a share lock upgraded later; review cycle 0 I7; an
  archived room is `{:error, :room_archived}`), the `rooms.power_levels_json` column (`content_json`), then the signed
  `m.room.power_levels` event. Any failing statement rolls BOTH back: `:ok` | `{:error, reason}` (a raised database error
  included, never re-raised), so the column can never change without its event (the F-1 hazard of the former two writes).

  NOT a `DBBehaviour` callback: the room process calls it only when the db module exports it and otherwise refuses the change
  (`:unsupported_db_module`, never a fallback to separate statements).
  """
  @spec apply_power_levels_change(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def apply_power_levels_change(room_id, content_json, signed_event) do
    result =
      Nebu.Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_active_room_for_update(room_id),
             :ok <- set_power_levels(room_id, content_json),
             :ok <- insert_event(signed_event) do
          :ok
        else
          {:error, reason} -> Nebu.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  The identity `{event_id, origin_server_ts, sender}` of the latest `m.room.power_levels` event of the room (the statement
  `do_init/1` loads it with), `{:ok, nil}` without one: the stamp and the "previous event" rule of the power-level writer
  when its in-memory identity is `nil` (story power-levels-enforcement, D1 / D2 (4)).
  """
  @spec latest_power_levels_identity(String.t()) :: {:ok, {String.t(), integer(), String.t()} | nil} | {:error, term()}
  def latest_power_levels_identity(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_power_levels_identity, [room_id]) do
      {:ok, %{rows: [[event_id, ts, sender]]}} -> {:ok, {event_id, ts, sender}}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ONE redaction of `room_id` in ONE `Nebu.Repo.transaction/1` (story state-writer-redaction, D9; the only caller is the room
  process): `SET LOCAL lock_timeout = '1s'`, the archived check (`FOR NO KEY UPDATE`, as apply_power_levels_change/3; an archived
  room is `{:error, :room_archived}`), then the signed redaction event with its `redacts` column (insert_event/1). The target row
  is never touched. `:ok` | `{:error, reason}` (a raised database error included, never re-raised).

  NOT a `DBBehaviour` callback: the room process refuses a db module without it (`:unsupported_db_module`).
  """
  @spec apply_redaction(String.t(), map()) :: :ok | {:error, term()}
  def apply_redaction(room_id, signed_event), do: room_write_transaction(room_id, fn -> insert_event(signed_event) end)

  @doc """
  ONE generic state change of `room_id` in ONE transaction (story state-writer-redaction, D8, D9): lock timeout, the archived check,
  the signed state event and, with `room_name: name` in `opts` (only for an `m.room.name` event with the EMPTY state key), the
  `rooms.name` denormalisation: both or neither. `:ok` | `{:error, :room_archived}` | `{:error, reason}`, never raising. NOT a
  `DBBehaviour` callback (see apply_redaction/2).
  """
  @spec apply_state_change(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def apply_state_change(room_id, signed_event, opts) do
    room_write_transaction(room_id, fn ->
      with :ok <- insert_event(signed_event) do
        case Keyword.get(opts, :room_name) do
          name when is_binary(name) -> update_room_name(room_id, name)
          _none -> :ok
        end
      end
    end)
  end

  # the shared transaction of apply_redaction/2 and apply_state_change/3: the lock timeout, the archived check, then `writes`
  # (`:ok` | `{:error, reason}`); any failure rolls everything back
  defp room_write_transaction(room_id, writes) do
    result =
      Nebu.Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_active_room_for_update(room_id),
             :ok <- writes.() do
          :ok
        else
          {:error, reason} -> Nebu.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @sql_latest_state_identity """
  SELECT event_id, origin_server_ts, sender FROM events
  WHERE room_id = $1 AND event_type = $2 AND state_key = $3
  ORDER BY origin_server_ts DESC, event_id DESC LIMIT 1
  """

  @doc """
  The identity `{event_id, origin_server_ts, sender}` of the latest event of the state slot `(type, state_key)`, `{:ok, nil}`
  without one: the stamp floor of the generic state writer (story state-writer-redaction, D8), ONE read of `events_room_state_idx`.
  """
  @spec latest_state_identity(String.t(), String.t(), String.t()) :: {:ok, {String.t(), integer(), String.t()} | nil} | {:error, term()}
  def latest_state_identity(room_id, type, state_key) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_latest_state_identity, [room_id, type, state_key]) do
      {:ok, %{rows: [[event_id, ts, sender]]}} -> {:ok, {event_id, ts, sender}}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # story state-writer-redaction (D6, security cycle 1, Kassandra #1): bounded in SQL. The EARLIEST writer-made redaction per target
  # (DISTINCT ON over events_redacts_idx (redacts, origin_server_ts, event_id): one row per target however many rows exist), UNION
  # the writer-made redaction events among the ids (one row per id: the primary key). Never "load every redaction, keep one".
  @sql_redactions_for """
  SELECT event_id, room_id, sender, origin_server_ts, content, redacts FROM (
    SELECT DISTINCT ON (redacts) event_id, room_id, sender, origin_server_ts, content, redacts
    FROM events
    WHERE redacts IS NOT NULL AND redacts = ANY($1)
    ORDER BY redacts, origin_server_ts, event_id
  ) earliest_per_target
  UNION
  SELECT event_id, room_id, sender, origin_server_ts, content, redacts
  FROM events
  WHERE redacts IS NOT NULL AND event_id = ANY($1)
  ORDER BY origin_server_ts ASC, event_id ASC
  """

  @doc """
  The writer-made redaction rows of ONE response (story state-writer-redaction, D6): for each given event id AT MOST ONE redaction
  of it (the earliest by `(origin_server_ts, event_id)`) and the redaction events AMONG the ids, ONE statement.
  `{:ok, [%{"event_id", "room_id", "sender", "origin_server_ts", "content", "redacts"}]}` oldest first; a legacy row (`redacts`
  NULL) is never returned. The result is bounded by twice the number of ids (security cycle 1, Kassandra #1).
  """
  @spec redactions_for([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def redactions_for([]), do: {:ok, []}

  def redactions_for(event_ids) when is_list(event_ids) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_redactions_for, [event_ids]) do
      {:ok, %{columns: cols, rows: rows}} -> {:ok, Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_get_power_levels_json "SELECT power_levels_json FROM rooms WHERE room_id = $1"

  @doc """
  The stored `rooms.power_levels_json` of a room, the authoritative content an upgrade carries after the freeze (story
  power-levels-enforcement, D8): `{:ok, json | nil}`, `{:error, :not_found}` without a row, `{:error, reason}`.
  """
  @spec get_power_levels_json(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def get_power_levels_json(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_power_levels_json, [room_id]) do
      {:ok, %{rows: [[json]]}} -> {:ok, json}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_insert_event """
  INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key, redacts)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
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
             state_key,
             Map.get(event, "redacts")
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
        all_events = Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
        page_answer(all_events, limit, from_token)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The answer of a page read (`fetch_events/4`, `fetch_visible_events/5`) from its `limit + 1` rows: `{:ok, events, next_batch,
  # prev_batch}`.
  defp page_answer(all_events, limit, from_token) do
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
      AND NOT EXISTS (SELECT 1 FROM events r WHERE r.room_id = events.room_id AND r.redacts = events.event_id)
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
    AND NOT EXISTS (SELECT 1 FROM events r WHERE r.room_id = events.room_id AND r.redacts = events.event_id)
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

  # The `membership` of an `m.room.member` row: the content column holds a JSONB object or (Postgrex double encoding) a JSONB
  # string that contains the JSON text; both forms are read, as `get_room_name/1` does. A missing key, a non-object body or
  # an unparseable string is NULL (never an error: `pg_input_is_valid/2`, PostgreSQL 16+, guards the cast), a non-string value
  # is its text form (and so an unknown membership, see `@sql_membership_normalised`).
  @sql_member_membership_raw """
  CASE jsonb_typeof(content)
    WHEN 'object' THEN content->>'membership'
    WHEN 'string' THEN CASE WHEN pg_input_is_valid(content #>> '{}', 'jsonb') THEN ((content #>> '{}')::jsonb)->>'membership' END
  END
  """

  # Story sync-membership-partition (D3): the tie order of two member events of one user in the SAME millisecond: the MOST
  # RESTRICTIVE membership is the latest (ban < leave < invite < knock < join); an unknown membership ranks as `leave`.
  # `origin_server_ts DESC, rank ASC, event_id DESC` is applied to every read of the latest member event (the sync
  # partition, the join decision, the ban check, the room summary), so they all agree.
  @sql_member_rank """
  CASE membership WHEN 'ban' THEN 0 WHEN 'leave' THEN 1 WHEN 'invite' THEN 2 WHEN 'knock' THEN 3 WHEN 'join' THEN 4 ELSE 1 END
  """

  # unknown / non-string / missing / unparseable membership -> `leave` (the most restrictive known value short of a ban)
  @sql_membership_normalised """
  CASE WHEN membership IN ('ban', 'leave', 'invite', 'knock', 'join') THEN membership ELSE 'leave' END
  """

  # Index (room_id, event_type, state_key, origin_server_ts DESC) serves this lookup. The membership is NORMALISED like
  # `latest_member_events/2` (review cycle 1, MINOR-2): an unknown / non-string / missing / unparseable membership is `leave`, so
  # the two readers of "the latest member event" agree and a corrupt row is never read as "never a member".
  @sql_get_member_membership """
  SELECT #{@sql_membership_normalised} AS membership FROM (
    SELECT event_id, origin_server_ts, #{@sql_member_membership_raw} AS membership
    FROM events
    WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2
  ) member_events
  ORDER BY origin_server_ts DESC, #{@sql_member_rank} ASC, event_id DESC
  LIMIT 1
  """

  @doc """
  The `membership` value of the LATEST `m.room.member` event of `user_id` in `room_id` (story
  oauth-room-summary-unrecognized, room_summary): `{:ok, "join" | "leave" | "ban" | "knock" | "invite" |
  nil}`, `nil` ONLY when the user never had a member event in the room. The value is NORMALISED as in
  `latest_member_events/2` (story sync-membership-partition, review cycle 1): an unknown, non-string, missing or unparseable
  membership is `"leave"`, and a same-millisecond tie is read most restrictive first (D3). `{:error, reason}` on a DB failure.
  Read-only: touches no Room process and creates no row.
  """
  @spec get_member_membership(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def get_member_membership(room_id, user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_member_membership, [room_id, user_id]) do
      {:ok, %{rows: [[membership]]}} when is_binary(membership) -> {:ok, membership}
      {:ok, %{rows: _}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # Story create-room-invites-direct (D3): ONE query for a whole createRoom list. Active local accounts only; an unknown
  # id and a deactivated one are both simply absent from the answer (the core cannot and must not tell them apart).
  @sql_invitable_local_users "SELECT user_id FROM users WHERE user_id = ANY($1) AND is_active AND deletion_status IS NULL"

  @doc """
  The subset of `user_ids` that are existing ACTIVE accounts (`users.is_active`), in any order (story
  create-room-invites-direct, D3). An id missing from the answer is unknown or deactivated: the two are
  indistinguishable by design. Read-only: it never creates a `users` row. `{:error, reason}` on a DB failure
  (the caller fails closed).
  """
  @spec invitable_local_users([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def invitable_local_users([]), do: {:ok, []}

  def invitable_local_users(user_ids) when is_list(user_ids) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_invitable_local_users, [user_ids]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [user_id] -> user_id end)}
      {:error, reason} -> {:error, reason}
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

  # ─── story sync-membership-partition: the membership reads of the /sync partition (D2, D2a) ─────────────────────
  # ADR-018: inline, parameter-bound SQL. These reads are NOT `DBBehaviour` callbacks: the sync reaches them through
  # `rooms_db_module()` and treats a module without one of them as unavailable (D10, fail closed). Every read answers
  # `{:ok, value}` | `{:error, reason}`. NO migration: each statement is served by an existing index.

  # (a) ONE statement over both membership row tables of the user (served by `room_members_user_id_idx` and
  # `room_invitations_invitee_idx`). An ACCEPTED invitation is not a candidate (the member row carries the join).
  @sql_membership_candidates """
  SELECT room_id, 'member' AS kind, (left_at IS NULL) AS active, false AS pending,
         NULL::text AS inviter_id, NULL::bigint AS invited_at, left_at, joined_at
  FROM room_members
  WHERE user_id = $1
  UNION ALL
  SELECT room_id, 'invitation' AS kind, false AS active, (rejected_at IS NULL) AS pending, inviter_id, invited_at,
         NULL::bigint AS left_at, NULL::bigint AS joined_at
  FROM room_invitations
  WHERE invitee_id = $1 AND accepted_at IS NULL
  """

  @doc """
  The candidate rooms of `user_id` for the sync partition (D2 (a)): one map per ROW, so a re-invited former member is TWO
  candidates of one room:

    * a `room_members` row: `%{room_id, kind: :member, active: left_at IS NULL, pending: false, inviter_id: nil, invited_at: nil,
      left_at, joined_at}` (`left_at`, ms, is nil while the row is active: the end of the membership as the ROW knows it, which
      bounds the leave window when no leave event was written, review cycle 1, Kassandra M-1; `joined_at` is the start of the
      latest membership as the row knows it, which bounds the window from below, review cycle 2, Kassandra I-1);
    * a `room_invitations` row that is not accepted: `%{room_id, kind: :invitation, active: false, pending: neither
      rejected, inviter_id, invited_at, left_at: nil, joined_at: nil}`.

  Another user's rows are never returned. `{:error, reason}` on a DB failure (the caller fails closed).
  """
  @spec membership_candidates(String.t()) :: {:ok, [map()]} | {:error, term()}
  def membership_candidates(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_membership_candidates, [user_id]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [room_id, kind, active, pending, inviter_id, invited_at, left_at, joined_at] ->
           %{
             room_id: room_id,
             kind: if(kind == "member", do: :member, else: :invitation),
             active: active,
             pending: pending,
             inviter_id: inviter_id,
             invited_at: invited_at,
             left_at: left_at,
             joined_at: joined_at
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # (b) ONE statement for every candidate room: the two newest member events of the user per room, in the D3 tie order.
  # `events_room_state_idx` serves the inner scan (one small range per room: the user's own member events).
  @sql_latest_member_events """
  SELECT room_id, event_id, origin_server_ts, sender, membership, content, room_pos
  FROM (
    SELECT room_id, event_id, origin_server_ts, sender, content, membership, room_pos,
           row_number() OVER (
             PARTITION BY room_id
             ORDER BY origin_server_ts DESC, #{@sql_member_rank} ASC, event_id DESC
           ) AS rn
    FROM (
      SELECT room_id, event_id, origin_server_ts, sender, content, room_pos, #{@sql_membership_normalised} AS membership
      FROM (
        SELECT room_id, event_id, origin_server_ts, sender, content, room_pos, #{@sql_member_membership_raw} AS membership
        FROM events
        WHERE room_id = ANY($1) AND event_type = 'm.room.member' AND state_key = $2
      ) raw_member_events
    ) member_events
  ) ranked
  WHERE rn <= 2
  ORDER BY room_id, rn
  """

  @doc """
  The two newest `m.room.member` events of `user_id` (the AUTHOR is `sender`; the user is the `state_key`) in each of
  `room_ids`, newest first, as `[L, P]` (D2 (b)): `{:ok, %{room_id => [%{event_id, origin_server_ts, sender, membership,
  content, room_pos}]}}` (`room_pos` is the event's room position, story sync-stream-position D9 / D10: nil for an event stored before
  migration 000053). One statement for all rooms. The order is `origin_server_ts DESC`, then the most restrictive membership
  (D3), then `event_id DESC`. `membership` is normalised to ban / leave / invite / knock / join: anything else, a
  non-string, a missing key or an unparseable body is `"leave"` (and never makes the statement fail); `content` is the decoded
  map from either JSONB form (`%{}` when it is no object). A room without a member event of the user is absent from the map.
  `[]` as the room list answers `{:ok, %{}}` without a statement.
  """
  @spec latest_member_events([String.t()], String.t()) :: {:ok, %{String.t() => [map()]}} | {:error, term()}
  def latest_member_events([], _user_id), do: {:ok, %{}}

  def latest_member_events(room_ids, user_id) when is_list(room_ids) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_latest_member_events, [room_ids, user_id]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         rows
         |> Enum.map(fn [room_id, event_id, ts, sender, membership, content, room_pos] ->
           {room_id,
            %{
              event_id: event_id,
              origin_server_ts: ts,
              sender: sender,
              membership: membership,
              content: decode_json_object(content),
              room_pos: room_pos
            }}
         end)
         |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The latest member event of `user_id` in `room_id` (D13, the join decision): `{:ok, %{event_id, membership, origin_server_ts,
  sender}}` in the D3 tie order with the normalised membership, `{:ok, nil}` when the user never had a member event there,
  `{:error, reason}` on a DB failure. The `event_id` is the basis of a join decision (story moderation-routes-atomic-ban, D9: the
  room process compares it with the latest member event it reads right before the member insert).
  """
  @spec latest_member_event(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def latest_member_event(room_id, user_id) do
    with {:ok, by_room} <- latest_member_events([room_id], user_id) do
      case Map.get(by_room, room_id, []) do
        [latest | _] -> {:ok, Map.take(latest, [:event_id, :membership, :origin_server_ts, :sender])}
        [] -> {:ok, nil}
      end
    end
  end

  @doc """
  The pending invitation of `user_id` to `room_id` through the room db module (story moderation-routes-atomic-ban, D2 (4)): the
  room process reads every fact of a moderation through ONE module (`:room_manager, :db_module`), so a unit fake models the whole
  decision. Delegates to `Nebu.Matrix.Room.InviteDB.pending_invitation/2`: `{:ok, invited_at | nil}` | `{:error, reason}`.
  """
  @spec pending_invitation(String.t(), String.t()) :: {:ok, integer() | nil} | {:error, term()}
  def pending_invitation(room_id, user_id), do: Nebu.Matrix.Room.InviteDB.pending_invitation(room_id, user_id)

  @doc """
  ONE membership change of `user_id` in `room_id` in ONE `Nebu.Repo.transaction/1` (story moderation-routes-atomic-ban, D3; the
  only caller is the room process, `Nebu.Matrix.Room.Server`): `remove_member: true` closes the active `room_members` row (the
  soft delete of `delete_member/2`; "not a member" is no error), `reject_invitation: true` rejects the pending invitation (the
  statement of `InviteDB.reject_invitation/2`, a no-op without one), then `signed_event` is inserted (`nil`: no event). Any failing
  statement rolls the WHOLE change back: `:ok` | `{:error, reason}` (a raised database error included, never re-raised), so a
  kick, ban, unban, invite or decline is applied completely or not at all. `require_pending_invitation: true` (the invite event)
  first locks the pending invitation row and answers `{:error, :invitation_gone}` without one. Every lock wait of the transaction
  is bounded by `lock_timeout` 1 s (review cycles 1 / 2, Kassandra I-6 / I-11). An archived room refuses every moderation, invite-event and decline write
  (`{:error, :room_archived}`, review cycle 2, Kassandra L-5; joins and member leaves do not pass here).

  NOT a `DBBehaviour` callback: the room process calls it only when the db module exports it and otherwise refuses the change
  (never a fallback to separate statements). The statements share the transaction's connection because they run in the calling
  process (`Ecto.Adapters.SQL.query/3` on `Nebu.Repo`).
  """
  @spec apply_member_change(String.t(), String.t(), map() | nil, keyword()) :: :ok | {:error, term()}
  def apply_member_change(room_id, user_id, signed_event, opts) do
    result =
      Nebu.Repo.transaction(fn ->
        with :ok <- set_lock_timeout(),
             :ok <- lock_active_room_for_update(room_id),
             :ok <- if(Keyword.get(opts, :require_pending_invitation, false), do: lock_pending_invitation(room_id, user_id), else: :ok),
             :ok <- if(Keyword.get(opts, :remove_member, false), do: close_member_row(room_id, user_id), else: :ok),
             :ok <- if(Keyword.get(opts, :reject_invitation, false), do: Nebu.Matrix.Room.InviteDB.reject_invitation(room_id, user_id), else: :ok),
             :ok <- if(is_map(signed_event), do: insert_event(signed_event), else: :ok) do
          :ok
        else
          {:error, reason} -> Nebu.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # review cycle 1 (Kassandra I-6): a row lock held by another transaction (a capped invite of the same invitee) must not stall
  # the room process beyond its 5 s call: each lock wait is at most 1 s (review cycle 2, I-11), then the change fails (55P03, rolled
  # back, `:write_failed`). The bound is per wait: one transaction can wait up to 4-5 times (review cycle 3, I-5; follow-up `fs`).
  defp set_lock_timeout do
    case Ecto.Adapters.SQL.query(Nebu.Repo, "SET LOCAL lock_timeout = '1s'", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The archived check of the room write transactions (apply_member_change/4, apply_power_levels_change/3, ...). Review cycle 2
  # (Kassandra L-5, defence in depth): an ARCHIVED room takes no moderation, invite-event, decline or power-level write, even from
  # a room process that still runs (the row lock serialises with `Nebu.Admin.DB.archive_room_atomic/1`, which locks the row FOR
  # UPDATE). A room without a row is left to the statements that follow (their foreign keys). The row is locked FOR NO KEY UPDATE
  # at once: every such transaction inserts an event afterwards, and the position trigger of migration 000053 (story
  # events-room-position, D1) UPDATEs the rooms row on every insert. A share lock would be UPGRADED there, so two transactions
  # holding it on one room would deadlock (D2; apply_member_change/4 used FOR SHARE until then).
  @sql_room_status_for_no_key_update "SELECT status FROM rooms WHERE room_id = $1 FOR NO KEY UPDATE"

  defp lock_active_room_for_update(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_room_status_for_no_key_update, [room_id]) do
      {:ok, %{rows: [["archived"]]}} -> {:error, :room_archived}
      {:ok, _active_or_none} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_lock_pending_invitation """
  SELECT 1 FROM room_invitations
  WHERE room_id = $1 AND invitee_id = $2 AND accepted_at IS NULL AND rejected_at IS NULL
  FOR UPDATE
  """

  # review cycle 1 (M5, `require_pending_invitation: true`, the invite event): the invitation row must still be pending, locked
  # until the commit, else `{:error, :invitation_gone}` (a revocation or a decline committed after the caller wrote the row)
  defp lock_pending_invitation(room_id, user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lock_pending_invitation, [room_id, user_id]) do
      {:ok, %{rows: [_ | _]}} -> :ok
      {:ok, %{rows: []}} -> {:error, :invitation_gone}
      {:error, reason} -> {:error, reason}
    end
  end

  # the soft delete inside apply_member_change/4: a user without an active row is no error (a pending invitee, a pre-emptive ban)
  defp close_member_row(room_id, user_id) do
    case delete_member(room_id, user_id) do
      {:error, :not_member} -> :ok
      other -> other
    end
  end

  # only the `reason` of a member event goes through the sort of @sql_banned_members (review cycle 1, Kassandra L-3), from both
  # JSONB forms like the membership: a JSONB value (a string reason arrives as a string), NULL when absent or unparseable
  @sql_member_reason_raw """
  CASE jsonb_typeof(content)
    WHEN 'object' THEN content->'reason'
    WHEN 'string' THEN CASE WHEN pg_input_is_valid(content #>> '{}', 'jsonb') THEN ((content #>> '{}')::jsonb)->'reason' END
  END
  """

  # Story moderation-routes-atomic-ban (D11): the users whose LATEST member event in a room is `ban`, ONE statement over the
  # room's member events with the same fragments and the same D3 order as every other latest-membership read (both JSONB forms,
  # a same-millisecond tie most restrictive first). `events_room_state_idx` serves the scan of the room's member events.
  @sql_banned_members """
  SELECT state_key, reason FROM (
    SELECT DISTINCT ON (state_key) state_key, reason, #{@sql_membership_normalised} AS membership
    FROM (
      SELECT state_key, event_id, origin_server_ts, #{@sql_member_reason_raw} AS reason, #{@sql_member_membership_raw} AS membership
      FROM events
      WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key IS NOT NULL
    ) member_events
    ORDER BY state_key, origin_server_ts DESC, #{@sql_member_rank} ASC, event_id DESC
  ) latest
  WHERE membership = 'ban'
  ORDER BY state_key
  """

  @doc """
  The users of `room_id` whose latest member event is a ban (story moderation-routes-atomic-ban, D11: the bans an upgrade carries
  into the new room): `{:ok, [%{user_id, reason}]}`, ordered by user id; `reason` is the ban's `reason` when it is a string,
  else `nil` (the caller decides whether it may be copied). `{:error, reason}` on a DB failure. Read-only.
  """
  @spec banned_members(String.t()) :: {:ok, [%{user_id: String.t(), reason: String.t() | nil}]} | {:error, term()}
  def banned_members(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_banned_members, [room_id]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [user_id, reason] ->
           %{user_id: user_id, reason: if(is_binary(reason), do: reason)}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Story history-visibility-enforcement (D1): the ONE history visibility fragment ────────────────────────────────────────────
  #
  # A list of CTEs over `hv_in(rooms text[], viewer text)`: a CTE the CONSUMER statement defines first, from its own bound
  # parameters (`WITH hv_in AS (SELECT ... AS rooms, $n::text AS viewer), <fragment> ...`). The text is a constant built from
  # module attributes only: no value is ever interpolated. Per room of `rooms` it yields
  #
  #   * `hv_segments(room_id, lo, hi, vis)`: closed millisecond ranges that cover the whole time axis, each with the verdict for an
  #     ORDINARY event stamped inside it (D2). The boundaries are the timestamps of the room's hv state events and of the viewer's
  #     member events (plus the D4 synthetic join); a boundary millisecond is a segment of its own, visible only when the state just
  #     before AND just after it allow (D2 (c), the most restrictive same-millisecond rule); the range before the first boundary is
  #     `shared` without a membership (visible: the createRoom chain, D3). `hv_seg_arr(room_id, los, vis)` holds the same segments
  #     as two sorted arrays per room: a consumer finds the segment of a millisecond by binary search (`width_bucket`).
  #   * `hv_special(event_id, vis)`: the D5 verdict of the hv state events (the setting before OR after them) and of the viewer's
  #     own member events (his membership before OR after them), each judged on both sides of its millisecond.
  #
  # `hv_allow` is the ONE definition of the rule (S3, D2 (d)): `world_readable` and `shared` allow every reader because every
  # reader is currently joined (the gates of the callers). The viewer's membership comes from the existing member fragments (both
  # JSONB forms, unknown -> `leave`, the D3 tie order); the setting from `@sql_hv_value_raw` (unknown / missing -> `shared`, S4).
  # Only hv rows with `state_key = ''` count: a row of that type sent through /send (`state_key` NULL) is never state.
  #
  # Cost (security cycle 1, follow-up `gk`): with B boundaries (hv events of the rooms + the viewer's member events in them) the
  # fragment is O(B log B), sorts and window functions only (no join whose plan depends on the row estimates of the CTEs): the
  # state at each boundary is the winner of its millisecond carried forward (`count(...) OVER` groups + `first_value`), the
  # state before it is the previous boundary's (`lag`); a special event takes the state of its boundary from the same kind of
  # carry over the merged stream of boundaries and special events, the membership before a member event is the previous row of
  # the member stream (`lag`); every input is read once through `events_room_state_idx`. A consumer decides "the event `e` is
  # visible" with `@sql_hv_visible` after joining `@sql_hv_join` (the segment arrays of `e`'s room): a binary search per
  # candidate row. Measured (3 000 hv events in one room, a later joiner's backward page): 5.2 s before, 46 ms after. No cache,
  # no table: read per statement from the committed events (cluster-safety).

  # The `history_visibility` of an `m.room.history_visibility` row, both JSONB forms (as `@sql_member_membership_raw`).
  @sql_hv_value_raw """
  CASE jsonb_typeof(content)
    WHEN 'object' THEN content->>'history_visibility'
    WHEN 'string' THEN CASE WHEN pg_input_is_valid(content #>> '{}', 'jsonb') THEN ((content #>> '{}')::jsonb)->>'history_visibility' END
  END
  """

  @sql_history_visibility """
  /* history_visibility */
  hv_allow AS (
    SELECT hs.h, ms.m, (hs.h IN ('world_readable', 'shared') OR ms.m = 'join' OR (ms.m = 'invite' AND hs.h = 'invited')) AS ok
    FROM unnest(ARRAY['world_readable', 'shared', 'invited', 'joined']) AS hs(h)
    CROSS JOIN unnest(ARRAY['ban', 'leave', 'invite', 'knock', 'join', 'none']) AS ms(m)
  ),
  hv_state AS MATERIALIZED (
    SELECT x.room_id, x.event_id, x.ts,
           CASE WHEN x.raw IN ('world_readable', 'shared', 'invited', 'joined') THEN x.raw ELSE 'shared' END AS val
    FROM (
      SELECT room_id, event_id, origin_server_ts AS ts, #{@sql_hv_value_raw} AS raw
      FROM events
      WHERE room_id = ANY((SELECT rooms FROM hv_in)::text[]) AND event_type = 'm.room.history_visibility' AND state_key = ''
    ) x
  ),
  hv_mem_events AS MATERIALIZED (
    SELECT x.room_id, x.event_id, x.ts, #{@sql_membership_normalised} AS m, #{@sql_member_rank} AS rank
    FROM (
      SELECT room_id, event_id, origin_server_ts AS ts, #{@sql_member_membership_raw} AS membership
      FROM events
      WHERE room_id = ANY((SELECT rooms FROM hv_in)::text[]) AND event_type = 'm.room.member' AND state_key = (SELECT viewer FROM hv_in)
    ) x
  ),
  hv_mem AS MATERIALIZED (
    SELECT room_id, event_id, ts, m, rank FROM hv_mem_events
    UNION ALL
    SELECT rm.room_id, '', rm.joined_at, 'join', 4
    FROM room_members rm
    LEFT JOIN (
      SELECT DISTINCT ON (room_id) room_id, m FROM hv_mem_events ORDER BY room_id, ts DESC, rank ASC, event_id DESC
    ) latest ON latest.room_id = rm.room_id
    WHERE rm.room_id = ANY((SELECT rooms FROM hv_in)::text[]) AND rm.user_id = (SELECT viewer FROM hv_in) AND rm.left_at IS NULL
      AND COALESCE(latest.m, 'none') <> 'join'
  ),
  hv_points AS MATERIALIZED (
    SELECT c.room_id, c.ts, lead(c.ts) OVER w AS next_ts,
           COALESCE(lag(c.h_at) OVER w, 'shared') AS h_bef, c.h_at,
           COALESCE(lag(c.m_at) OVER w, 'none') AS m_bef, c.m_at
    FROM (
      SELECT g.room_id, g.ts,
             COALESCE(first_value(g.h) OVER (PARTITION BY g.room_id, g.gh ORDER BY g.ts), 'shared') AS h_at,
             COALESCE(first_value(g.m) OVER (PARTITION BY g.room_id, g.gm ORDER BY g.ts), 'none') AS m_at
      FROM (
        SELECT b.room_id, b.ts, b.h, b.m,
               count(b.h) OVER (PARTITION BY b.room_id ORDER BY b.ts) AS gh,
               count(b.m) OVER (PARTITION BY b.room_id ORDER BY b.ts) AS gm
        FROM (
          SELECT COALESCE(hs.room_id, ms.room_id) AS room_id, COALESCE(hs.ts, ms.ts) AS ts, hs.val AS h, ms.m
          FROM (SELECT DISTINCT ON (room_id, ts) room_id, ts, val FROM hv_state ORDER BY room_id, ts, event_id DESC) hs
          FULL JOIN (SELECT DISTINCT ON (room_id, ts) room_id, ts, m FROM hv_mem ORDER BY room_id, ts, rank ASC, event_id DESC) ms
            ON ms.room_id = hs.room_id AND ms.ts = hs.ts
        ) b
      ) g
    ) c
    WINDOW w AS (PARTITION BY c.room_id ORDER BY c.ts)
  ),
  hv_segments AS MATERIALIZED (
    SELECT r.room_id, (-9223372036854775807)::bigint AS lo, COALESCE(f.first_ts - 1, 9223372036854775807)::bigint AS hi, TRUE AS vis
    FROM unnest((SELECT rooms FROM hv_in)) AS r(room_id)
    LEFT JOIN (SELECT room_id, min(ts) AS first_ts FROM hv_points GROUP BY room_id) f ON f.room_id = r.room_id
    UNION ALL
    SELECT p.room_id, p.ts, p.ts, bef.ok AND aft.ok
    FROM hv_points p
    JOIN hv_allow bef ON bef.h = p.h_bef AND bef.m = p.m_bef
    JOIN hv_allow aft ON aft.h = p.h_at AND aft.m = p.m_at
    UNION ALL
    SELECT p.room_id, p.ts + 1, COALESCE(p.next_ts - 1, 9223372036854775807)::bigint, aft.ok
    FROM hv_points p
    JOIN hv_allow aft ON aft.h = p.h_at AND aft.m = p.m_at
    WHERE p.next_ts IS NULL OR p.next_ts > p.ts + 1
  ),
  hv_seg_arr AS MATERIALIZED (
    SELECT room_id, array_agg(lo ORDER BY lo) AS los, array_agg(vis ORDER BY lo) AS vis
    FROM hv_segments
    GROUP BY room_id
  ),
  hv_special AS MATERIALIZED (
    SELECT q.event_id,
           CASE q.kind
             WHEN 1 THEN ((SELECT al.ok FROM hv_allow al WHERE al.h = q.p_h_bef AND al.m = q.p_m_bef)
                          OR (SELECT al.ok FROM hv_allow al WHERE al.h = q.val AND al.m = q.p_m_bef))
                         AND ((SELECT al.ok FROM hv_allow al WHERE al.h = q.p_h_bef AND al.m = q.p_m_at)
                          OR (SELECT al.ok FROM hv_allow al WHERE al.h = q.val AND al.m = q.p_m_at))
             ELSE ((SELECT al.ok FROM hv_allow al WHERE al.h = q.p_h_bef AND al.m = q.prev_m)
                   OR (SELECT al.ok FROM hv_allow al WHERE al.h = q.p_h_bef AND al.m = q.m))
                  AND ((SELECT al.ok FROM hv_allow al WHERE al.h = q.p_h_at AND al.m = q.prev_m)
                   OR (SELECT al.ok FROM hv_allow al WHERE al.h = q.p_h_at AND al.m = q.m))
           END AS vis
    FROM (
      SELECT v.event_id, v.kind, v.val, v.m, v.prev_m,
             first_value(v.h_bef) OVER g AS p_h_bef, first_value(v.h_at) OVER g AS p_h_at,
             first_value(v.m_bef) OVER g AS p_m_bef, first_value(v.m_at) OVER g AS p_m_at
      FROM (
        SELECT u.*, count(*) FILTER (WHERE u.kind = 0) OVER (PARTITION BY u.room_id ORDER BY u.ts, u.kind ROWS UNBOUNDED PRECEDING) AS grp
        FROM (
          SELECT room_id, ts, 0 AS kind, NULL::text AS event_id, h_bef, h_at, m_bef, m_at, NULL::text AS val, NULL::text AS m,
                 NULL::text AS prev_m
          FROM hv_points
          UNION ALL
          SELECT room_id, ts, 1, event_id, NULL, NULL, NULL, NULL, val, NULL, NULL FROM hv_state
          UNION ALL
          SELECT room_id, ts, 2, event_id, NULL, NULL, NULL, NULL, NULL, m, prev_m
          FROM (
            SELECT room_id, event_id, ts, m,
                   COALESCE(lag(m) OVER (PARTITION BY room_id ORDER BY ts ASC, rank DESC, event_id ASC), 'none') AS prev_m
            FROM hv_mem
          ) mem
          WHERE event_id <> ''
        ) u
      ) v
      WINDOW g AS (PARTITION BY v.room_id, v.grp ORDER BY v.ts, v.kind)
    ) q
    WHERE q.kind > 0
  ),
  hv_spec_arr AS MATERIALIZED (
    SELECT array_agg(event_id ORDER BY event_id) AS ids, array_agg(vis ORDER BY event_id) AS vis FROM hv_special
  )
  """

  # D5: is the event `e` one of the special events (an hv STATE event, a member event of the viewer)? Never NULL.
  @sql_hv_special_event """
  COALESCE((e.event_type = 'm.room.history_visibility' AND e.state_key = '')
           OR (e.event_type = 'm.room.member' AND e.state_key = (SELECT viewer FROM hv_in)), FALSE)
  """

  # The join a consumer adds right after `FROM events e` (or after the item that exposes `e`): the segment arrays of `e`'s room
  # (one row per room: no row is duplicated; no match leaves NULLs, read as invisible).
  @sql_hv_join """
  LEFT JOIN hv_seg_arr hv_a ON hv_a.room_id = e.room_id
  """

  # The ONE predicate shape of a consumer statement: "the event `e` (columns event_id, room_id, event_type, state_key,
  # origin_server_ts) is visible to the viewer": a special event by its D5 verdict, any other by the segment of its millisecond
  # (both by binary search: `width_bucket` over the sorted special ids / segment lower bounds; no join whose plan depends on row
  # estimates of the CTEs). No verdict (an unknown room, a NULL column) is FALSE: fail closed.
  @sql_hv_visible """
  (CASE WHEN #{@sql_hv_special_event}
        THEN COALESCE((SELECT CASE WHEN sa.ids[k.i] = e.event_id THEN sa.vis[k.i] END
                       FROM hv_spec_arr sa CROSS JOIN LATERAL (SELECT width_bucket(e.event_id, sa.ids) AS i) k), FALSE)
        ELSE COALESCE(hv_a.vis[width_bucket(e.origin_server_ts, hv_a.los)], FALSE)
   END)
  """

  @doc false
  # The fragment (story history-visibility-enforcement, D1) for `Nebu.Matrix.Search.DB` (interpolated at compile time; ONE definition).
  @spec history_visibility_sql() :: String.t()
  def history_visibility_sql, do: @sql_history_visibility

  @doc false
  # The consumer predicate over `e` that belongs to the fragment (`Nebu.Matrix.Search.DB`).
  @spec history_visibility_predicate() :: String.t()
  def history_visibility_predicate, do: @sql_hv_visible

  @doc false
  # The consumer joins the predicate needs (`Nebu.Matrix.Search.DB`).
  @spec history_visibility_join() :: String.t()
  def history_visibility_join, do: @sql_hv_join

  # Story member-event-prev-content (D3): ONE statement, the predecessor of every requested state event.
  #
  # The order of a slot is the D3 key `(origin_server_ts, r, event_id)`, the exact reverse of the partition's
  # `ORDER BY origin_server_ts DESC, rank ASC, event_id DESC`: `r = 4 - rank(membership)` for `m.room.member` (a
  # same-millisecond ban is the LATEST, a join the earliest) and `r = 0` for every other type (which reduces to the
  # `(origin_server_ts, event_id)` order of the earlier replaces_state lookup). The rank comes from the SAME three SQL
  # fragments as every other membership read (no copy of the rank logic in Elixir). The own `r` of a requested event is read
  # from its row by the primary key; a requested id without a row ranks as an unknown membership (rank 1, the D3 rule).
  # `e2.origin_server_ts <= req.origin_server_ts` is an index-friendly upper bound for `events_room_state_idx`
  # (room_id, event_type, state_key, origin_server_ts DESC): only rows at or before the requested event are candidates.
  # Only rows with a `state_key` take part (`state_key = req.state_key` never matches NULL): a non-state event of a state type
  # is never a predecessor. The leading marker comment is a pinned name: telemetry consumers (the statement-count tests) find
  # the statement by it. `@sql_state_predecessor_rows` is the FROM part shared with the viewer-aware statement below.
  @sql_state_predecessor_rows """
  FROM (
    SELECT r0.event_id, r0.room_id, r0.event_type, r0.state_key, r0.origin_server_ts,
           CASE WHEN r0.event_type = 'm.room.member' THEN
             4 - COALESCE((
               SELECT #{@sql_member_rank}
               FROM (SELECT #{@sql_member_membership_raw} AS membership FROM events WHERE event_id = r0.event_id) own_raw
             ), 1)
           ELSE 0 END AS r
    FROM UNNEST($1::text[], $2::text[], $3::text[], $4::text[], $5::bigint[])
         AS r0(event_id, room_id, event_type, state_key, origin_server_ts)
  ) req
  LEFT JOIN LATERAL (
    SELECT c.event_id, c.content, c.sender, c.origin_server_ts
    FROM (
      SELECT cand.event_id, cand.content, cand.sender, cand.origin_server_ts,
             CASE WHEN req.event_type = 'm.room.member' THEN 4 - (#{@sql_member_rank}) ELSE 0 END AS r
      FROM (
        SELECT e2.event_id, e2.content, e2.sender, e2.origin_server_ts,
               #{@sql_member_membership_raw} AS membership
        FROM events e2
        WHERE e2.room_id = req.room_id
          AND e2.event_type = req.event_type
          AND e2.state_key = req.state_key
          AND e2.origin_server_ts <= req.origin_server_ts
      ) cand
    ) c
    WHERE (c.origin_server_ts, c.r, c.event_id) < (req.origin_server_ts, req.r, req.event_id)
    ORDER BY c.origin_server_ts DESC, c.r DESC, c.event_id DESC
    LIMIT 1
  ) p ON true
  """

  @sql_state_predecessors """
  /* state_predecessors */
  SELECT req.event_id, p.event_id, p.content, p.sender
  #{@sql_state_predecessor_rows}
  """

  # Story history-visibility-enforcement (D10): the SAME predecessor (the rows above, unchanged), served only when it is visible
  # to the viewer ($6) under the fragment: an invisible predecessor answers NULL like "no predecessor" (all three keys omitted),
  # never an older visible row. `e` exposes the predecessor's columns to `@sql_hv_visible`. ONE statement for all slot rooms.
  @sql_state_predecessors_visible """
  /* state_predecessors */
  WITH hv_in AS (SELECT ARRAY(SELECT DISTINCT unnest($2::text[])) AS rooms, $6::text AS viewer),
  #{@sql_history_visibility}
  SELECT req.event_id, CASE WHEN v.ok THEN p.event_id END, CASE WHEN v.ok THEN p.content END, CASE WHEN v.ok THEN p.sender END
  #{@sql_state_predecessor_rows}
  CROSS JOIN LATERAL (SELECT p.event_id, req.room_id, req.event_type, req.state_key, p.origin_server_ts)
    AS e(event_id, room_id, event_type, state_key, origin_server_ts)
  #{@sql_hv_join}
  CROSS JOIN LATERAL (SELECT p.event_id IS NOT NULL AND #{@sql_hv_visible} AS ok) v
  """

  @doc """
  Story member-event-prev-content (D3), the widened bugfix unsigned-replaces-state lookup: what state event did each
  of the given ones replace at its `(room_id, event_type, state_key)` slot, and what did it say. ONE statement for the WHOLE
  `slots` list (callers must never invoke this once per event: collect every slot of a response first).

  `slots` is a list of `{event_id, room_id, event_type, state_key, origin_server_ts}` 5-tuples. `event_id` /
  `origin_server_ts` identify the CURRENT event, `room_id` / `event_type` / `state_key` its slot.

  Returns `%{event_id => %{event_id: predecessor_event_id, content: map, sender: predecessor_sender}}`, ONLY for the events that
  have an earlier row in their slot: an event without a predecessor is simply absent (callers render nothing for it, never a
  null). `content` is the decoded map of either JSONB form (`%{}` when it is no object).

  The predecessor of `X` is the row of `X`'s slot with the largest key `(origin_server_ts, r, event_id)` strictly below `X`'s
  own key (see `@sql_state_predecessors`): the D3 tie order of the sync partition for `m.room.member` slots, the
  `(origin_server_ts, event_id)` order for every other type. That order is a Nebu rule, not a spec rule.

  `[]` answers `%{}` without a statement. On a DB error the answer is `%{}` and ONE warning is logged that names the slot
  count and the SQLSTATE code only (never a content, a row, a parameter or a sender: No Sensitive Data in Logs).

  Not part of `Nebu.Matrix.Room.DBBehaviour` (a read helper, like `get_generic_state_events/1`): callers MUST guard with
  `function_exported?/3` before invoking an injected test double that may not implement it (see
  `Nebu.Matrix.EventDispatcher.Server`'s `fetch_state_predecessors_batch/2`).
  """
  @spec fetch_state_predecessors([{String.t(), String.t(), String.t(), String.t() | nil, integer()}]) ::
          %{String.t() => %{event_id: String.t(), content: map(), sender: String.t()}}
  def fetch_state_predecessors([]), do: %{}

  def fetch_state_predecessors(slots) when is_list(slots) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_state_predecessors, predecessor_params(slots)) do
      {:ok, %{rows: rows}} ->
        predecessor_map(rows)

      {:error, reason} ->
        # A dropped index, a missing GRANT or a statement timeout would otherwise silently disable the predecessor keys
        # for every slot, indistinguishable from "no predecessor anywhere": make it observable. The text carries the slot
        # count and the SQLSTATE code ONLY, never the whole error term (a driver error can echo parameters / content). Keep in sync with
        # `lenient_visible_predecessors/3`.
        code =
          case reason do
            %{postgres: %{code: c}} -> c
            _ -> :unknown
          end

        Logger.warning(
          "fetch_state_predecessors: batched predecessor lookup failed for #{length(slots)} slot(s), " <>
            "unsigned predecessor keys disabled for this response (SQLSTATE code #{inspect(code)})"
        )

        %{}
    end
  end

  @doc """
  `fetch_state_predecessors/1` with options. `strict: true` (story membership-state-model, security cycle 2, MINOR 2: the
  `/members` and `/initialSync` state events): the lookup runs in ONE transaction after `SET LOCAL statement_timeout = '2s'` (its
  cost is O(member events) for a member slice) and answers `{:ok, map}` or `{:error, reason}` (a timeout is SQLSTATE `57014`),
  never a silent `%{}`. Without `strict` it is the lenient `/sync` lookup of `fetch_state_predecessors/1` (one statement).

  `viewer: user_id` (story history-visibility-enforcement, D10; every client-serving caller passes it): the SAME predecessor,
  served only when it is visible to `user_id` under the room's history visibility (`@sql_state_predecessors_visible`, still
  ONE statement); an invisible predecessor is absent from the answer like "no predecessor". `viewer: nil` / `viewer: ""` serves
  NO predecessor at all (`%{}` / `{:ok, %{}}` without a statement: fail closed, never the unfiltered statement); only a call
  WITHOUT the `viewer:` option reads the unfiltered statement (internal callers).
  """
  @spec fetch_state_predecessors([tuple()], keyword()) :: {:ok, map()} | {:error, term()} | map()
  def fetch_state_predecessors(slots, opts) when is_list(slots) and is_list(opts) do
    strict? = Keyword.get(opts, :strict, false)

    statement =
      case Keyword.fetch(opts, :viewer) do
        :error -> {@sql_state_predecessors, predecessor_params(slots)}
        {:ok, viewer} when is_binary(viewer) and viewer != "" -> {@sql_state_predecessors_visible, predecessor_params(slots) ++ [viewer]}
        {:ok, _no_viewer} -> :none
      end

    cond do
      statement == :none or slots == [] ->
        if strict?, do: {:ok, %{}}, else: %{}

      not strict? and not Keyword.has_key?(opts, :viewer) ->
        fetch_state_predecessors(slots)

      not strict? ->
        {sql, params} = statement
        lenient_visible_predecessors(slots, sql, params)

      true ->
        {sql, params} = statement

        Nebu.Repo.transaction(fn ->
          with {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, "SET LOCAL statement_timeout = '2s'", []),
               {:ok, %{rows: rows}} <- Ecto.Adapters.SQL.query(Nebu.Repo, sql, params) do
            predecessor_map(rows)
          else
            {:error, reason} -> Nebu.Repo.rollback(reason)
          end
        end)
    end
  end

  # the lenient viewer-aware lookup: a DB error answers no keys (the conservative direction) with the value-free warning of
  # fetch_state_predecessors/1 (slot count and SQLSTATE code only). Keep the two warnings in sync (the source pin of
  # state_predecessors_db_test.exs needs the literal in the body of /1).
  defp lenient_visible_predecessors(slots, sql, params) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, params) do
      {:ok, %{rows: rows}} ->
        predecessor_map(rows)

      {:error, reason} ->
        code =
          case reason do
            %{postgres: %{code: c}} -> c
            _ -> :unknown
          end

        Logger.warning(
          "fetch_state_predecessors: batched predecessor lookup failed for #{length(slots)} slot(s), " <>
            "unsigned predecessor keys disabled for this response (SQLSTATE code #{inspect(code)})"
        )

        %{}
    end
  end

  # the five parallel arrays of the UNNEST of `@sql_state_predecessors`, in slot order
  defp predecessor_params(slots) do
    {event_ids, room_ids, event_types, state_keys, tss} =
      slots
      |> Enum.reverse()
      |> Enum.reduce({[], [], [], [], []}, fn {event_id, room_id, event_type, state_key, ts}, {eids, rids, ets, sks, tss} ->
        {[event_id | eids], [room_id | rids], [event_type | ets], [state_key | sks], [ts | tss]}
      end)

    [event_ids, room_ids, event_types, state_keys, tss]
  end

  defp predecessor_map(rows) do
    Enum.reduce(rows, %{}, fn
      [_event_id, nil, _content, _sender], acc -> acc
      [event_id, pred_id, content, sender], acc -> Map.put(acc, event_id, %{event_id: pred_id, content: decode_json_object(content), sender: sender})
    end)
  end

  # (b') the inviters' member events of the invite rooms: ONE statement for all (room, inviter) pairs (the stripped state of an
  # invitation carries the inviter's own member event). `unnest` turns the two arrays into the pair list, the join is served by
  # `events_room_state_idx` (one small range per pair); the newest event per pair in the D3 order.
  @sql_inviter_member_events """
  SELECT DISTINCT ON (room_id, state_key) room_id, state_key, event_id, origin_server_ts, sender, membership, content
  FROM (
    SELECT e.room_id, e.state_key, e.event_id, e.origin_server_ts, e.sender, e.content,
           #{@sql_membership_normalised} AS membership
    FROM (
      SELECT ev.room_id, ev.state_key, ev.event_id, ev.origin_server_ts, ev.sender, ev.content,
             #{@sql_member_membership_raw} AS membership
      FROM unnest($1::text[], $2::text[]) AS pair(room_id, user_id)
      JOIN events ev ON ev.room_id = pair.room_id AND ev.event_type = 'm.room.member' AND ev.state_key = pair.user_id
    ) e
  ) member_events
  ORDER BY room_id, state_key, origin_server_ts DESC, #{@sql_member_rank} ASC, event_id DESC
  """

  @doc """
  The newest member event of each `{room_id, user_id}` pair in `pairs` (the inviter of each invite room), in ONE statement
  (review cycle 1, MINOR-4 / Kassandra L-3: no statement per inviter): `{:ok, %{{room_id, user_id} => %{event_id,
  origin_server_ts, sender, membership, content}}}` with the same normalisation and tie order as `latest_member_events/2`; a pair
  without a member event is absent. `[]` answers `{:ok, %{}}` without a statement. Optional for the sync: a rooms module that does
  not export it is served by `latest_member_events/2` per inviter (the unit fakes).
  """
  @spec inviter_member_events([{String.t(), String.t()}]) :: {:ok, %{{String.t(), String.t()} => map()}} | {:error, term()}
  def inviter_member_events([]), do: {:ok, %{}}

  def inviter_member_events(pairs) when is_list(pairs) do
    {room_ids, user_ids} = Enum.unzip(pairs)

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_inviter_member_events, [room_ids, user_ids]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Map.new(rows, fn [room_id, user_id, event_id, ts, sender, membership, content] ->
           {{room_id, user_id},
            %{event_id: event_id, origin_server_ts: ts, sender: sender, membership: membership, content: decode_json_object(content)}}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # (c) ONE statement for every invite room: the room's FIRST `m.room.create` and the LATEST `state_key = ''` event of each of
  # six stripped-state types (DISTINCT ON picks one row per (room, type); only the create event is read oldest-first).
  @invite_state_types ~w(m.room.create m.room.name m.room.avatar m.room.topic m.room.canonical_alias m.room.join_rules m.room.encryption)

  @sql_invite_state_events """
  SELECT DISTINCT ON (room_id, event_type) room_id, event_type, state_key, sender, content
  FROM events
  WHERE room_id = ANY($1) AND state_key = '' AND event_type = ANY($2)
  ORDER BY room_id, event_type,
           CASE WHEN event_type = 'm.room.create' THEN origin_server_ts END ASC NULLS LAST,
           origin_server_ts DESC, event_id DESC
  """

  @doc """
  The stripped-state candidates of the invite rooms (D2 (c), D4): `{:ok, %{room_id => [%{"type", "state_key", "sender",
  "content"}]}}`: the first `m.room.create`, then the latest `state_key = ""` event of `m.room.name`, `m.room.avatar`,
  `m.room.topic`, `m.room.canonical_alias`, `m.room.join_rules`, `m.room.encryption` in this order, those that exist.
  A room without a create event gets none invented (the core synthesizes it); the inviter's and the invitee's member events
  are read with `latest_member_events/2`. `content` is decoded from either JSONB form. One statement for all rooms.
  """
  @spec invite_state_events([String.t()]) :: {:ok, %{String.t() => [map()]}} | {:error, term()}
  def invite_state_events([]), do: {:ok, %{}}

  def invite_state_events(room_ids) when is_list(room_ids) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_invite_state_events, [room_ids, @invite_state_types]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         rows
         |> Enum.sort_by(fn [_room_id, type | _] -> Enum.find_index(@invite_state_types, &(&1 == type)) end)
         |> Enum.map(fn [room_id, type, state_key, sender, content] ->
           {room_id,
            %{"type" => type, "state_key" => state_key, "sender" => sender, "content" => decode_json_object(content)}}
         end)
         |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # (d) the leave window: the events of ONE room strictly between two room positions (story sync-stream-position, D10), further
  # restricted by the member row's clocks, newest 21 (`events_room_pos_idx`: one backward index range).
  @sql_leave_window_events """
  SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
  FROM events
  WHERE room_id = $1 AND room_pos > $2 AND room_pos < $3 AND origin_server_ts > $4 AND origin_server_ts < $5
  ORDER BY room_pos DESC
  LIMIT 21
  """

  @doc """
  The timeline window of a leave entry (story sync-membership-partition D6, story sync-stream-position D10): the events of
  `room_id` with `after_pos < room_pos < before_pos` AND `after_ts < origin_server_ts < before_ts`, all four bounds strict, the
  NEWEST 21 (the caller delivers 20; a 21st means `limited`), newest first by position, with the columns of `fetch_events_since/3`.

  The positions are the bounds (the cursor or the join event P below, the leave / kick / ban event L above): nothing at or after
  L's position is ever read, whatever its timestamp. The clocks are the member row's `joined_at` / `left_at` (pass `0` and
  `9_223_372_036_854_775_807` for "no bound"): they can only SHRINK the window (fail closed under clock skew), never widen it. An
  event without a position (stored before migration 000053) is never part of a window. `{:error, reason}` on a DB failure.
  """
  @spec leave_window_events(String.t(), integer(), integer(), integer(), integer()) :: {:ok, [map()]} | {:error, term()}
  def leave_window_events(room_id, after_pos, before_pos, after_ts, before_ts) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_leave_window_events, [room_id, after_pos, before_pos, after_ts, before_ts]) do
      {:ok, %{columns: cols, rows: rows}} -> {:ok, row_maps(cols, rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Story membership-state-model (D1, D4): the latest member event per user of ONE room (the fragments and the D3 order of every
  # latest-membership read), then the `/members` filters ($2 must match AND $3 must not, normalised), then the cap ($4) of the
  # NON-joined slots by a window rank (invite > ban > knock > leave, newest first, `state_key` last); joined slots are never capped.
  # `events_room_state_idx` serves the scan; the leading marker comment is a pinned name (the statement-count tests).
  @sql_member_state_slice """
  /* member_state_slice */
  SELECT event_id, state_key, sender, content, origin_server_ts, membership FROM (
    SELECT event_id, state_key, sender, content, origin_server_ts, membership,
           row_number() OVER (
             PARTITION BY (membership = 'join')
             ORDER BY CASE membership WHEN 'invite' THEN 0 WHEN 'ban' THEN 1 WHEN 'knock' THEN 2 ELSE 3 END,
                      origin_server_ts DESC, state_key ASC
           ) AS rn
    FROM (
      SELECT DISTINCT ON (state_key) event_id, state_key, sender, content, origin_server_ts, #{@sql_membership_normalised} AS membership
      FROM (
        SELECT event_id, state_key, sender, content, origin_server_ts, #{@sql_member_membership_raw} AS membership
        FROM events
        WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key IS NOT NULL
      ) member_events
      ORDER BY state_key, origin_server_ts DESC, #{@sql_member_rank} ASC, event_id DESC
    ) latest
    WHERE ($2::text IS NULL OR membership = $2::text) AND ($3::text IS NULL OR membership <> $3::text)
  ) ranked
  WHERE membership = 'join' OR rn <= $4
  """

  # D4: the bound of the non-joined member slots per room and response (a Nebu bound; operator query Q-ms of 07-deployment)
  @member_slice_other_cap 10_000

  @doc "The D6 order of the member slots (join, invite, ban, knock, leave; then `state_key`): the ONE definition, also for the dispatcher."
  @spec member_slice_class(String.t()) :: 0..4
  def member_slice_class("join"), do: 0
  def member_slice_class("invite"), do: 1
  def member_slice_class("ban"), do: 2
  def member_slice_class("knock"), do: 3
  def member_slice_class(_leave), do: 4

  @doc """
  The member slice of `room_id` (story membership-state-model, D1), one slice statement inside a timed transaction (`SET LOCAL
  statement_timeout = '2s'`, D15): the latest `m.room.member` event of every user
  in the D3 order, `{:ok, [%{event_id, state_key, sender, content, origin_server_ts, membership}]}` ordered join, invite, ban,
  knock, leave, then `state_key`; `membership` normalised (unknown -> `"leave"`), `content` the stored object (`%{}` if none).
  Options: `:membership` / `:not_membership` (match the first AND not the second), `:other_cap` (default 10 000, the bound of the
  non-joined slots, after the filters). `{:error, reason}` on a DB failure. Read-only.
  """
  @spec member_state_slice(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def member_state_slice(room_id, opts \\ []) do
    params = [
      room_id,
      Keyword.get(opts, :membership),
      Keyword.get(opts, :not_membership),
      Keyword.get(opts, :other_cap, @member_slice_other_cap)
    ]

    # D15 (security cycle 1, Kassandra M-1): the slice reads every member event of the room (O(member events), not O(users)), so it
    # is bounded in time: ONE transaction whose `SET LOCAL` ends with it; a read beyond 2 s fails with SQLSTATE 57014 (the caller: 503)
    result =
      Nebu.Repo.transaction(fn ->
        with {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, "SET LOCAL statement_timeout = '2s'", []),
             {:ok, %{rows: rows}} <- Ecto.Adapters.SQL.query(Nebu.Repo, @sql_member_state_slice, params) do
          rows
        else
          {:error, reason} -> Nebu.Repo.rollback(reason)
        end
      end)

    with {:ok, rows} <- result do
      slice =
        rows
        |> Enum.map(fn [event_id, state_key, sender, content, ts, membership] ->
          %{event_id: event_id, state_key: state_key, sender: sender, content: decode_json_object(content), origin_server_ts: ts, membership: membership}
        end)
        |> Enum.sort_by(&{member_slice_class(&1.membership), &1.state_key})

      {:ok, slice}
    end
  end

  # Story membership-state-model (D9): the latest `invite` event of every user of a room (both JSONB forms), for the `is_direct`
  # an upgrade carries into the replacement room.
  @sql_direct_invitees """
  SELECT DISTINCT ON (state_key) state_key, content
  FROM (
    SELECT state_key, content, origin_server_ts, event_id, #{@sql_member_membership_raw} AS membership
    FROM events
    WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key IS NOT NULL
  ) member_events
  WHERE membership = 'invite'
  ORDER BY state_key, origin_server_ts DESC, event_id DESC
  """

  @doc """
  The users of `room_id` whose OWN latest `invite` event carried `"is_direct": true` (a JSON boolean), in ONE statement (story
  membership-state-model, D9): `{:ok, MapSet.t(String.t())}`; `{:error, reason}` on a DB failure. Read-only.
  """
  @spec direct_invitees(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def direct_invitees(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_direct_invitees, [room_id]) do
      {:ok, %{rows: rows}} ->
        {:ok, for([user_id, content] <- rows, decode_json_object(content)["is_direct"] == true, into: MapSet.new(), do: user_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An event body as a map: a JSONB object arrives as a map, the double-encoded form as a binary that holds the JSON text
  # (possibly nested again). Anything that is no object is `%{}`.
  defp decode_json_object(content) when is_map(content), do: content

  defp decode_json_object(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} when is_binary(decoded) -> decode_json_object(decoded)
      _ -> %{}
    end
  end

  defp decode_json_object(_content), do: %{}

  # ─── Story history-visibility-enforcement: the viewer-aware reads (D6, D7, D8) ───────────────────────────────────────────────
  #
  # Each is ONE statement: `hv_in` from the bound room and viewer, the fragment, the read. The page reads are DRIVEN by the visible
  # segments (one LATERAL index range per visible segment over `events_room_id_ts_idx`, `LIMIT` inside, plus the visible special
  # events), never "scan the room in order and filter": a backward page of a `joined` room never reads the invisible history before
  # the viewer's join. The single-event and relation reads filter with `@sql_hv_visible` (their own filter bounds the scan).

  @hv_event_columns "e.event_id, e.room_id, e.sender, e.event_type, e.content, e.origin_server_ts, e.state_key"

  @doc """
  The viewer-aware `fetch_events/4` (story history-visibility-enforcement, D6): the same keyset `(origin_server_ts, event_id)`,
  order, tokens and answer `{:ok, events, next_batch, prev_batch}`, over the events `viewer` may see. The `limit + 1` look-ahead
  counts visible events only, so a page is filled from visible events and `next_batch` is `""` when no visible event remains; a
  `from_token` inside an invisible region is accepted and never yields an invisible event.
  """
  @spec fetch_visible_events(String.t(), String.t(), String.t(), integer(), String.t()) ::
          {:ok, [map()], String.t(), String.t()} | {:error, term()}
  def fetch_visible_events(room_id, viewer, direction, limit, from_token),
    do: fetch_visible_events(room_id, viewer, direction, limit, from_token, nil)

  @doc """
  `fetch_visible_events/5` bounded by a room position (story sync-stream-position, D12: the initial `/sync` page): only the events
  with `room_pos <= head` or without a position (stored before migration 000053) are read, on every page. An event committed after
  the caller read `head` has a higher position and is left to the next incremental sync. `head = nil` is the unbounded read.
  """
  @spec fetch_visible_events(String.t(), String.t(), String.t(), integer(), String.t(), integer() | nil) ::
          {:ok, [map()], String.t(), String.t()} | {:error, term()}
  def fetch_visible_events(room_id, viewer, direction, limit, from_token, head) when is_integer(head) or is_nil(head) do
    case decode_token(from_token) do
      # a NUL is not storable: no event can be at that position (security cycle 1: answered like an unknown event, before any read)
      {:ok, _ts, event_id} when is_binary(event_id) and byte_size(event_id) > 0 ->
        if String.contains?(event_id, <<0>>), do: {:error, :not_found}, else: read_visible_page(room_id, viewer, direction, limit, from_token, head)

      _empty ->
        read_visible_page(room_id, viewer, direction, limit, from_token, head)
    end
  end

  defp read_visible_page(room_id, viewer, direction, limit, from_token, head) do
    order = if direction == "f", do: "ASC", else: "DESC"

    {range, cursor, cursor_params} =
      case decode_token(from_token) do
        {:ok, ts, event_id} when order == "DESC" ->
          {"BETWEEN s.lo AND LEAST(s.hi, $4::bigint)", "AND (e.origin_server_ts, e.event_id) < ($4::bigint, $5::text)", [ts, event_id]}

        {:ok, ts, event_id} ->
          {"BETWEEN GREATEST(s.lo, $4::bigint) AND s.hi", "AND (e.origin_server_ts, e.event_id) > ($4::bigint, $5::text)", [ts, event_id]}

        :empty ->
          {"BETWEEN s.lo AND s.hi", "", []}
      end

    # D12: the head bound is the parameter after the cursor's (never a value in the statement text)
    {head_bound, head_params} =
      if is_integer(head),
        do: {"AND (e.room_pos <= $#{4 + length(cursor_params)}::bigint OR e.room_pos IS NULL)", [head]},
        else: {"", []}

    sql = """
    WITH hv_in AS (SELECT ARRAY[$1::text] AS rooms, $2::text AS viewer),
    #{@sql_history_visibility},
    hv_page AS (
      SELECT x.* FROM hv_segments s
      CROSS JOIN LATERAL (
        SELECT #{@hv_event_columns}
        FROM events e
        WHERE e.room_id = $1 AND e.origin_server_ts #{range} #{cursor} #{head_bound} AND NOT #{@sql_hv_special_event}
        ORDER BY e.origin_server_ts #{order}, e.event_id #{order}
        LIMIT $3
      ) x
      WHERE s.vis
      UNION ALL
      SELECT #{@hv_event_columns}
      FROM hv_special sp JOIN events e ON e.event_id = sp.event_id
      WHERE sp.vis AND e.room_id = $1 #{cursor} #{head_bound}
    )
    SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
    FROM hv_page
    ORDER BY origin_server_ts #{order}, event_id #{order}
    LIMIT $3
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id, viewer, limit + 1] ++ cursor_params ++ head_params) do
      {:ok, %{columns: cols, rows: rows}} -> page_answer(row_maps(cols, rows), limit, from_token)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The viewer-aware `fetch_events_since/3` (D6, the incremental `/sync`): the OLDEST `limit` events after the anchor's timestamp
  that `viewer` may see, ascending (segment-driven: a gap of invisible events never starves the room). A nil / `""` anchor and an
  unknown anchor id read from the start, as `fetch_events_since/3` does. `{:ok, events}` | `{:error, reason}`.
  """
  @spec fetch_visible_events_since(String.t(), String.t(), String.t() | nil, pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def fetch_visible_events_since(room_id, viewer, last_event_id, limit) do
    case since_anchor(last_event_id) do
      {:ok, since_ts} -> read_visible_since(room_id, viewer, limit, since_ts)
      {:error, reason} -> {:error, reason}
    end
  end

  # the anchor's timestamp: nil / "" / an unknown id read from the start (0, as fetch_events_since/3); a failing lookup is an error
  # (security cycle 1, INFO-3: never "read from the start" because of a DB error)
  defp since_anchor(last_event_id) when is_binary(last_event_id) and last_event_id != "" do
    case get_event_timestamp(last_event_id) do
      {:ok, ts} -> {:ok, ts}
      {:error, :not_found} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp since_anchor(_none), do: {:ok, 0}

  # The fragment's inputs are conditional INSIDE the statement (security cycle 1, MINOR-1): a room without any event after the
  # anchor reads zero rows in every CTE (one index probe of `events_room_id_ts_idx`), so the incremental /sync of a quiet room
  # costs no visibility computation.
  defp read_visible_since(room_id, viewer, limit, since_ts) do
    sql = """
    WITH hv_in AS (
      SELECT CASE WHEN EXISTS (SELECT 1 FROM events WHERE room_id = $1 AND origin_server_ts > $4::bigint)
                  THEN ARRAY[$1::text] ELSE ARRAY[]::text[] END AS rooms,
             $2::text AS viewer
    ),
    #{@sql_history_visibility},
    hv_page AS (
      SELECT x.* FROM hv_segments s
      CROSS JOIN LATERAL (
        SELECT #{@hv_event_columns}
        FROM events e
        WHERE e.room_id = $1 AND e.origin_server_ts BETWEEN GREATEST(s.lo, $4::bigint + 1) AND s.hi AND NOT #{@sql_hv_special_event}
        ORDER BY e.origin_server_ts ASC, e.event_id ASC
        LIMIT $3
      ) x
      WHERE s.vis
      UNION ALL
      SELECT #{@hv_event_columns}
      FROM hv_special sp JOIN events e ON e.event_id = sp.event_id
      WHERE sp.vis AND e.room_id = $1 AND e.origin_server_ts > $4::bigint
    )
    SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
    FROM hv_page
    ORDER BY origin_server_ts ASC, event_id ASC
    LIMIT $3
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id, viewer, limit, since_ts]) do
      {:ok, %{columns: cols, rows: rows}} -> {:ok, row_maps(cols, rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Story sync-stream-position: the position reads of /sync (D4, D5, D12) ───────────────────────────────────────────────────
  # Not `DBBehaviour` callbacks: the dispatcher treats a db module without them as unavailable (the 503 of the sync, fail closed).

  # ONE statement for all rooms: the committed head of each room and the device's cursor row (primary key lookup per room)
  @sql_room_heads """
  SELECT r.room_id, r.event_pos, c.gen, c.pos, c.class, c.invite_marker, c.prev_pos, c.prev_class, c.prev_invite_marker
  FROM rooms r
  LEFT JOIN sync_room_cursors c ON c.user_id = $2 AND c.device_id = $3 AND c.room_id = r.room_id
  WHERE r.room_id = ANY($1)
  """

  @doc """
  The committed head (`rooms.event_pos`, story events-room-position) of each of `room_ids` and the cursor row of `(user_id,
  device_id)` for it (`device_id` `""` is the device-less key), in ONE statement (story sync-stream-position, D4 / D12):
  `{:ok, %{room_id => %{head: integer, cursor: nil | %{gen, pos, class, invite_marker, prev_pos, prev_class,
  prev_invite_marker}}}}`. A room without a `rooms` row is absent; the cursor rows of other users and devices are never read. `[]`
  answers `{:ok, %{}}` without a statement. `{:error, reason}` on a DB failure. Read-only.
  """
  @spec room_heads([String.t()], String.t(), String.t()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def room_heads([], _user_id, _device_id), do: {:ok, %{}}

  def room_heads(room_ids, user_id, device_id) when is_list(room_ids) and is_binary(user_id) and is_binary(device_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_room_heads, [room_ids, user_id, device_id]) do
      {:ok, %{rows: rows}} ->
        {:ok, Map.new(rows, fn [room_id, head | cursor] -> {room_id, %{head: head, cursor: cursor_row(cursor)}} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `pos` is NOT NULL in the table: a NULL is the LEFT JOIN without a row
  defp cursor_row([_gen, nil | _]), do: nil

  defp cursor_row([gen, pos, class, invite_marker, prev_pos, prev_class, prev_invite_marker]) do
    %{gen: gen, pos: pos, class: class, invite_marker: invite_marker, prev_pos: prev_pos, prev_class: prev_class, prev_invite_marker: prev_invite_marker}
  end

  @doc """
  The incremental `/sync` read of ONE room by position (story sync-stream-position, D4 / D5): the NEWEST `limit + 1` events with
  `after_pos < room_pos <= head` that `viewer` may see, newest first by position (stream order, never by timestamp; the caller
  delivers `limit` and reads the extra row as `limited`). An event without a position (stored before migration 000053) is never
  part of a range. The visibility fragment judges each candidate row by its `origin_server_ts` exactly as the page reads do, and a
  hidden row does not count towards the limit. `{:ok, events}` | `{:error, reason}`. Read-only.
  """
  @spec fetch_visible_events_in_range(String.t(), String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_visible_events_in_range(room_id, viewer, after_pos, head, limit)
      when is_integer(after_pos) and is_integer(head) and is_integer(limit) and limit > 0 do
    sql = """
    WITH hv_in AS (SELECT ARRAY[$1::text] AS rooms, $2::text AS viewer),
    #{@sql_history_visibility}
    SELECT #{@hv_event_columns}
    FROM events e
    #{@sql_hv_join}
    WHERE e.room_id = $1 AND e.room_pos > $3::bigint AND e.room_pos <= $4::bigint AND #{@sql_hv_visible}
    ORDER BY e.room_pos DESC
    LIMIT $5
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id, viewer, after_pos, head, limit + 1]) do
      {:ok, %{columns: cols, rows: rows}} -> {:ok, row_maps(cols, rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  # How many positions below the base the time floor of the segmented range read looks at (story sync-rejoin-range-scan-bound, D2).
  @rejoin_floor_lookback 64

  @doc """
  The segmented range read (story sync-rejoin-range-scan-bound, D1 / D2): the answer of `fetch_visible_events_in_range/5`
  (`{:ok, newest_first}`, the NEWEST `limit + 1` visible events with `after_pos < room_pos <= head`, newest first by position)
  for a room whose cursor base is an invitation / leave or whose viewer changed membership since the base. The plain read walks
  the positions and meets every hidden row between the base and the head; this one is driven by the visible history-visibility
  SEGMENTS like the page reads (one `LATERAL` index range over `events_room_id_ts_idx` per visible segment, `LIMIT limit + 1`
  inside, plus the visible special events). No hidden row is RETURNED, and no hidden ordinary row is walked: the only hidden rows
  read are the at most 64 rows of the floor window or, when that is empty, of its fallback range (their `origin_server_ts` only),
  so the cost does not depend on the hidden history.

  Bounds: `after_pos < room_pos <= head` in both branches (no `OR room_pos IS NULL`: an event without a position is never part of
  a position range) and, for the ordinary events only, the time floor `origin_server_ts >= floor` (none for `after_pos = 0`: no
  event to anchor it). The floor is `min(origin_server_ts)` of the events at the positions `after_pos - 63 .. after_pos`. It keeps
  the scan off the already delivered history below the base (a segment ordered by timestamp would otherwise be walked down below
  the base); a late commit or a clock skew inside the time spread of those 64 events stays inside the read. Positions are gapless
  per room, so the window holds the 64 newest events at the base. A PARTIAL gap (an event without a position, a deleted event)
  only makes the window hold fewer events: the floor rises, the read returns fewer rows, never a hidden one (the verdicts are the
  fragment's, the bounds only shrink the candidates). An EMPTY window (all 64 positions gone, `after_pos > 0`) would make `min()`
  NULL and `GREATEST` ignores NULL, i.e. the floor would disappear and the walk over the delivered history would be unbounded; the
  floor therefore falls back to the oldest `origin_server_ts` over the position RANGE `after_pos + 1 .. min(after_pos + 64, head)`
  (the same lookback on the other side of the base, a range like the window, no `ORDER BY` / `LIMIT`, behind its own `OFFSET 0`
  fence). That fallback is only evaluated for an empty window. When both ranges are empty (all positions gone by gaps, or no
  positioned event in `(after_pos, head]`) the floor is NULL, i.e. none: the position bounds still keep the answer correct and
  empty where nothing is above the base, and the cost is the only thing at risk (never a lost event: fail safe).

  Accepted residuals (same class as follow-up `cq` (b), the event stays reachable through `/messages`): an event committed after
  the cursor with a timestamp older than all events of the window is below the floor (the trigger is a TIME span: the clock skew
  must exceed the time spread of the newest 64 events at the base, which is short in a busy room); and the per-segment cut is by
  timestamp while the final cut is by position, so when ONE visible segment holds `limit + 1` or more newer-by-timestamp events a
  late commit with the highest position but an old timestamp is not read (only in a `limited` window). The cost of NEW visible
  events since the base is plan dependent (up to O(M) rows for M new visible events in the worst plan; for a `shared` /
  `world_readable` room the plain read was cheap, about 21 rows, so this is a regression there), never a function of the hidden
  history.

  The statement is written so that the bound holds whatever the planner picks (decision D-A1): the position bounds are
  `COALESCE(room_pos, 0)` expressions (a plain bound lets the planner walk the partial position index over the hidden stretch), the
  special events are fetched by a `LATERAL ... LIMIT 1` on the primary key with the room checked afterwards, and the floor is a
  `min()` over a position RANGE (a `ORDER BY room_pos DESC LIMIT 64` is turned into a bitmap scan of the whole room under stale
  statistics; the empty-window fallback is a range for the same reason) behind an `OFFSET 0` fence (without it the planner may rewrite `min(origin_server_ts)` into a walk of
  `events_room_id_ts_idx`, a read of the room's history below the window; pinned by the plan-shape tests). Not a `DBBehaviour`
  callback. `{:ok, events}` | `{:error, reason}`. Read-only.
  """
  @spec fetch_visible_events_in_range_segmented(String.t(), String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_visible_events_in_range_segmented(room_id, viewer, after_pos, head, limit)
      when is_integer(after_pos) and is_integer(head) and is_integer(limit) and limit > 0 do
    sql = """
    WITH hv_in AS (SELECT ARRAY[$1::text] AS rooms, $2::text AS viewer),
    #{@sql_history_visibility},
    rj_floor AS MATERIALIZED (
      SELECT CASE WHEN $3::bigint <= 0 THEN NULL::bigint
        ELSE COALESCE(
          (SELECT min(f.origin_server_ts)
           FROM (
             SELECT origin_server_ts FROM events
             WHERE room_id = $1 AND room_pos BETWEEN $3::bigint - #{@rejoin_floor_lookback - 1} AND $3::bigint
             OFFSET 0
           ) f),
          (SELECT min(n.origin_server_ts)
           FROM (
             SELECT origin_server_ts FROM events
             WHERE room_id = $1 AND room_pos BETWEEN $3::bigint + 1 AND LEAST($3::bigint + #{@rejoin_floor_lookback}, $4::bigint)
             OFFSET 0
           ) n))
      END AS ts
    ),
    rj_page AS (
      SELECT x.* FROM hv_segments s
      CROSS JOIN LATERAL (
        SELECT #{@hv_event_columns}, e.room_pos
        FROM events e
        WHERE e.room_id = $1 AND e.origin_server_ts BETWEEN GREATEST(s.lo, (SELECT ts FROM rj_floor)) AND s.hi
          AND COALESCE(e.room_pos, 0) > $3::bigint AND COALESCE(e.room_pos, 0) <= $4::bigint AND NOT #{@sql_hv_special_event}
        ORDER BY e.origin_server_ts DESC, e.room_pos DESC
        LIMIT $5
      ) x
      WHERE s.vis
      UNION ALL
      SELECT y.*
      FROM hv_special sp
      CROSS JOIN LATERAL (
        SELECT #{@hv_event_columns}, e.room_pos
        FROM events e
        WHERE e.event_id = sp.event_id AND COALESCE(e.room_pos, 0) > $3::bigint AND COALESCE(e.room_pos, 0) <= $4::bigint
        LIMIT 1
      ) y
      WHERE sp.vis AND y.room_id = $1
    )
    SELECT event_id, room_id, sender, event_type, content, origin_server_ts, state_key
    FROM rj_page
    ORDER BY room_pos DESC
    LIMIT $5
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, [room_id, viewer, after_pos, head, limit + 1]) do
      {:ok, %{columns: cols, rows: rows}} -> {:ok, row_maps(cols, rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The `/messages` pagination token (`v1_`, the encoder of the page reads) of an event map: `GET /messages?dir=b&from=<token>` pages
  backwards from just before that event. The `prev_batch` of a limited incremental `/sync` timeline (story sync-stream-position, D5).
  """
  @spec pagination_token(map()) :: String.t()
  def pagination_token(%{"origin_server_ts" => ts, "event_id" => event_id}), do: encode_token(ts, event_id)

  @sql_fetch_visible_event """
  WITH hv_in AS (SELECT ARRAY[$2::text] AS rooms, $3::text AS viewer),
  #{@sql_history_visibility}
  SELECT #{@hv_event_columns}
  FROM events e
  #{@sql_hv_join}
  WHERE e.event_id = $1 AND e.room_id = $2 AND #{@sql_hv_visible}
  LIMIT 1
  """

  @doc """
  The viewer-aware `fetch_event/2` (D7): `{:ok, event_map}` for an event of `room_id` that `viewer` may see, `{:error,
  :not_found}` for an unknown AND for an invisible event (indistinguishable: no existence oracle), `{:error, reason}` on a DB error.
  """
  @spec fetch_visible_event(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def fetch_visible_event(event_id, room_id, viewer) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_fetch_visible_event, [event_id, room_id, viewer]) do
      {:ok, %{columns: cols, rows: [row]}} -> {:ok, cols |> Enum.zip(row) |> Map.new()}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The viewer-aware `fetch_events_by_relation/5` (D8): the same filters, order and `limit`, over the relations `viewer` may see
  (the limit counts visible children only). `{:ok, events}` | `{:error, reason}`.
  """
  @spec fetch_visible_events_by_relation(String.t(), String.t(), String.t(), String.t(), pos_integer(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_visible_events_by_relation(room_id, viewer, event_id, rel_type, limit, opts) do
    order_dir = if Map.get(opts, :dir, "b") == "f", do: "ASC", else: "DESC"

    # $1 room, $2 parent, the optional filters, then the limit and the viewer
    {extra_where, base_params, limit_idx} =
      []
      |> add_rel_type_clause(rel_type)
      |> add_event_type_clause(Map.get(opts, :event_type, ""))
      |> build_where_and_params([room_id, event_id], 3)

    sql = """
    WITH hv_in AS (SELECT ARRAY[$1::text] AS rooms, $#{limit_idx + 1}::text AS viewer),
    #{@sql_history_visibility}
    SELECT #{@hv_event_columns}
    FROM events e
    #{@sql_hv_join}
    WHERE e.room_id = $1
      AND e.content->'m.relates_to'->>'event_id' = $2
      AND NOT EXISTS (SELECT 1 FROM events r WHERE r.room_id = e.room_id AND r.redacts = e.event_id)
      #{extra_where}
      AND #{@sql_hv_visible}
    ORDER BY e.origin_server_ts #{order_dir}, e.event_id #{order_dir}
    LIMIT $#{limit_idx}
    """

    case Ecto.Adapters.SQL.query(Nebu.Repo, sql, base_params ++ [max(1, limit), viewer]) do
      {:ok, %{columns: cols, rows: rows}} -> {:ok, row_maps(cols, rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_maps(cols, rows), do: Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)

  @doc """
  Not part of `Nebu.Matrix.Room.DBBehaviour`: callers must guard with `function_exported?/3` (test doubles may not implement it).

  Story history-visibility-enforcement (security cycle 1, HIGH #1 (d)): runs the visibility-filtered reads of ONE client request
  (`/messages`, `/event`, `/relations`, `/search`) in a transaction under `SET LOCAL statement_timeout = '2s'`, so one costly room
  cannot hold a pool connection for long. `fun` answers like the read it wraps; an `{:error, reason}` of it, of the `SET LOCAL` or
  a timeout (SQLSTATE `57014`) answers `{:error, reason}` (the caller's handled 500). Never used for `/sync` (a room whose reads
  always time out would fail every member's sync).
  """
  @spec with_read_timeout((-> term())) :: term()
  def with_read_timeout(fun) when is_function(fun, 0) do
    result =
      Nebu.Repo.transaction(fn ->
        with {:ok, _} <- Ecto.Adapters.SQL.query(Nebu.Repo, "SET LOCAL statement_timeout = '2s'", []) do
          case fun.() do
            {:error, reason} -> Nebu.Repo.rollback({:read_failed, reason})
            answer -> answer
          end
        else
          {:error, reason} -> Nebu.Repo.rollback({:read_failed, reason})
        end
      end)

    case result do
      {:ok, answer} -> answer
      {:error, {:read_failed, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_count_state_slot "SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3"

  @doc """
  The number of state events stored in the slot `(room_id, event_type, state_key)` (index-served: `events_room_state_idx`).
  Story history-visibility-enforcement (security cycle 1): the room process caps the `m.room.history_visibility` events of a
  room with it. `{:ok, count}` | `{:error, reason}`. Not part of `Nebu.Matrix.Room.DBBehaviour`: callers must guard with
  `function_exported?/3` (test doubles may not implement it).
  """
  @spec count_state_events(String.t(), String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_state_events(room_id, event_type, state_key) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_count_state_slot, [room_id, event_type, state_key]) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # the setting of the latest hv STATE event (ties event_id DESC, as the fragment), normalised like the fragment reads it
  @sql_current_history_visibility """
  SELECT CASE WHEN x.raw IN ('world_readable', 'shared', 'invited', 'joined') THEN x.raw ELSE 'shared' END
  FROM (
    SELECT #{@sql_hv_value_raw} AS raw
    FROM events
    WHERE room_id = $1 AND event_type = 'm.room.history_visibility' AND state_key = ''
    ORDER BY origin_server_ts DESC, event_id DESC
    LIMIT 1
  ) x
  """

  @doc """
  The CURRENT `history_visibility` of `room_id` as the visibility fragment reads it (an unknown / missing value and a room without
  the event read as `shared`). Story history-visibility-enforcement (security cycle 2, N1): the cap of the room process lets a
  strictly more restrictive change through. `{:ok, value}` | `{:error, reason}`. Not part of `Nebu.Matrix.Room.DBBehaviour`:
  callers must guard with `function_exported?/3`.
  """
  @spec current_history_visibility(String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_history_visibility(room_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_current_history_visibility, [room_id]) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      {:ok, %{rows: []}} -> {:ok, "shared"}
      {:error, reason} -> {:error, reason}
    end
  end
end
