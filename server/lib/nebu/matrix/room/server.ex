defmodule Nebu.Matrix.Room.Server do
  @moduledoc """
  Room GenServer — lifecycle + send-event + power-level enforcement + typing indicators
  (Stories 4-2, 4-4, 4-13, 4-17).

  Manages room membership state with PostgreSQL persistence.
  Rooms can be created, users can join and leave, and the current member
  list is always available in memory via a MapSet.

  Story 4-4 adds `send_event/5`: processes, signs (Ed25519), and persists send-event
  requests with full txnId idempotency via ETS `NebuTxnDedup`.

  Story 4-13 adds power level support:
  - `power_levels` map is loaded from DB on init (string keys throughout).
  - `send_event/5` enforces `events_default` threshold before processing.
  - `set_power_levels/3` validates caller has `change_state` power before persisting.
  - `default_power_levels/0` is a public function for use by EventDispatcher.

  Story 4-17 adds ephemeral typing state:
  - `set_typing/4` manages `typing_users: MapSet` in GenServer state.
  - Typing state is EPHEMERAL — Persistence Strategy: Option C (Stateless).
  - Auto-expiry via `Process.send_after/3` → `{:typing_expire, user_id}`.
  - Broadcasts `{:typing_update, user_id, typing}` via :pg room group.

  Story 6-8 adds max_members enforcement:
  - `max_members` field added to GenServer state (0 = no limit).
  - Loaded from DB on init via `db_module().load_room_settings/1` (fail-open: defaults to 0).
  - `join/2` returns `{:error, :room_full}` when member_count >= max_members > 0.
  - `update_settings/2` is a fire-and-forget cast to update max_members in-memory.

  State structure:
    %{
      room_id:          String.t(),
      members:          MapSet.t(String.t()),
      member_identity:  %{String.t() => {event_id :: String.t(), origin_server_ts :: integer()}},
                        # bugfix sync-state-events-missing-fields: real identity of each
                        # member's join event, captured at the moment the join is applied
                        # (not re-derived via a per-sync DB round trip). Restored from the
                        # DB on every GenServer restart (cluster-safety) by do_init/1.
      power_levels:     map(),          # string-key map — see Nebu.Matrix.Room.PowerLevels
      power_levels_event: {event_id :: String.t(), origin_server_ts :: integer(), sender :: String.t()} | nil,
                        # bugfix sync-state-events-missing-fields (AC2 addendum): real
                        # identity (+ sender, code-review cycle 1 MINOR-2) of the backing
                        # m.room.power_levels event, captured when set_power_levels applies
                        # the change. Restored on restart.
      created_at:       DateTime.t(),
      typing_users:     MapSet.t(String.t()),  # ephemeral — resets on restart
      max_members:      non_neg_integer()      # 0 = no limit; Story 6.8
    }

  ## Fail-open semantics of `member_identity` / `power_levels_event` (code-review
  ## cycle 1, MINOR-5)

  Both fields are BEST-EFFORT caches of real event identity, not guaranteed-present
  invariants. Each can legitimately be absent (a member with no entry in
  `member_identity`, or `power_levels_event: nil`) or STALE (pointing at an older
  event than the member's/room's actual current state) whenever the backing
  `insert_event` write failed — `emit_membership_event/3` and
  `emit_power_levels_event/3` are both deliberately non-fatal: if persistence
  fails, the membership/power-levels change is still applied to `members`/
  `power_levels` (the user is still joined; the new power levels still take
  effect), the identity update is simply skipped, and only a warning is logged.
  This mirrors the project's general fail-open philosophy for secondary writes
  (see e.g. `init/1`'s own fail-open DB-error handling above).

  `build_state_events/2` (event_dispatcher/server.ex) relies on this being
  possible: it defaults to `{"", 0, ""}` / `{"", 0}` identity whenever
  `member_identity`/`power_levels_event` has no entry for the relevant key, which
  is exactly how a pre-fix legacy room (no backing event ever written — see the
  `000035_backfill_power_levels_events` migration) and a post-fix room with a
  failed event write both present themselves. Do not assume either field is
  always populated once a member has joined or power levels have been set.

  DB writes go through the configurable db_module/0 helper (defaults to Nebu.Matrix.Room.DB).
  Inject a fake via `Application.put_env(:room_manager, :db_module, FakeDB)` in tests.
  """

  use GenServer

  # Resolve DB module at runtime so tests can override via Application.put_env.
  # Using a private function instead of a compile-time attribute enables injection.
  defp db_module, do: Application.get_env(:room_manager, :db_module, Nebu.Matrix.Room.DB)

  # ─── Public API ────────────────────────────────────────────────────────────

  @doc "Returns the full state map for `room_id`."
  @spec get_state(String.t()) :: map()
  def get_state(room_id), do: GenServer.call(via(room_id), :get_state)

  @doc """
  Adds `user_id` to the room's member set.

  Returns `:ok` on success, `{:error, :already_member}` if already joined,
  or `{:error, reason}` on DB failure (state unchanged).
  """
  @spec join(String.t(), String.t()) :: :ok | {:error, term()}
  def join(room_id, user_id), do: GenServer.call(via(room_id), {:join, user_id})

  @doc """
  Removes `user_id` from the room's member set (soft-delete in DB).

  Returns `:ok` on success, `{:error, :not_member}` if not currently joined,
  or `{:error, reason}` on DB failure (state unchanged).
  """
  @spec leave(String.t(), String.t()) :: :ok | {:error, term()}
  def leave(room_id, user_id), do: GenServer.call(via(room_id), {:leave, user_id})

  @doc """
  Removes `user_id` from the room's member set without emitting a membership event.

  Used by kick and ban, which emit their own event with the correct sender (caller_id).
  Returns `:ok` on success, `{:error, :not_member}` if not joined, or `{:error, reason}`.
  """
  @spec remove_member(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_member(room_id, user_id), do: GenServer.call(via(room_id), {:remove_member, user_id})

  @doc """
  Returns the default Matrix power levels map.

  Public so that EventDispatcher.Server and tests can build creator-boosted maps
  without duplicating the defaults. String keys throughout (architecture rule).
  """
  @spec default_power_levels() :: map()
  def default_power_levels, do: Nebu.Matrix.Room.PowerLevels.default_levels()

  @doc """
  Updates the power levels for `room_id`.

  The `caller_id` must have `change_state` power (level >= `state_default`).
  Returns `:ok` on success, `{:error, :forbidden}` if the caller lacks power,
  or `{:error, reason}` on DB failure (state unchanged on DB error).
  """
  @spec set_power_levels(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def set_power_levels(room_id, caller_id, new_levels) do
    GenServer.call(via(room_id), {:set_power_levels, new_levels, caller_id})
  end

  @doc """
  Sets or clears the typing indicator for `user_id` in `room_id`.

  When `typing: true`, schedules auto-clear after `timeout_ms` via `Process.send_after`.
  When `typing: false`, clears immediately.
  Broadcasts `{:typing_update, user_id, typing}` to all :pg room subscribers.
  State is ephemeral — NOT persisted to DB. No crash/restart recovery needed.
  (Persistence Strategy: Option C — Stateless)
  """
  @spec set_typing(String.t(), String.t(), boolean(), integer()) :: :ok
  def set_typing(room_id, user_id, typing, timeout_ms) do
    GenServer.call(via(room_id), {:set_typing, user_id, typing, timeout_ms})
  end

  @doc """
  Updates mutable room settings in the GenServer state (fire-and-forget cast).

  Supported keys in `settings` map:
  - `:max_members` — non-negative integer; 0 = no limit.

  Returns `:ok` immediately (GenServer.cast semantics).
  Story 6.8: Called by the gRPC UpdateRoomSettings handler after the Admin DB update.
  """
  @spec update_settings(String.t(), map()) :: :ok
  def update_settings(room_id, settings) do
    GenServer.cast(via(room_id), {:update_settings, settings})
  end

  @doc """
  Processes a send-event request for the given `room_id`.

  Checks txn_id idempotency via ETS `NebuTxnDedup` first. On cache hit,
  returns the existing event_id immediately without re-processing.

  On cache miss: builds the event map, generates a content-hash event_id
  via `Nebu.Matrix.EventId.generate/1`, signs the canonical JSON with the server
  Ed25519 key, persists to PostgreSQL `events`, inserts into ETS, and
  broadcasts `{:new_event, signed_event}` via `:pg` room group.

  Returns `{:ok, event_id}` on success or `{:error, reason}` on DB failure.
  On DB failure: ETS is NOT updated and NO broadcast is sent.

  `state_key` is optional (default `nil`). For state events, pass the Matrix
  state_key as a string (e.g. `""` for m.room.name, user_id for m.room.member).
  A non-nil `state_key` (including `""`) signals that this is a state event and
  triggers the `:change_state` power level check (state_default = 50) instead of
  the `:send_event` check (events_default = 0). Story 9-7 / SEC Gate 1 fix.
  """
  @spec send_event(String.t(), String.t(), String.t(), map(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def send_event(room_id, user_id, event_type, content, txn_id, state_key \\ nil) do
    GenServer.call(via(room_id), {:send_event, user_id, event_type, content, txn_id, state_key})
  end

  # ─── Child Spec ────────────────────────────────────────────────────────────

  @doc """
  Overrides the default child spec so that each Room GenServer has a unique
  child id based on `room_id`. Without this override all rooms would share the
  id `Nebu.Matrix.Room.Server` and Horde would refuse to start a second one.
  """
  def child_spec(room_id) do
    %{
      id: {__MODULE__, room_id},
      start: {__MODULE__, :start_link, [room_id]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc """
  Starts the Room GenServer, registering it in `Nebu.Matrix.Room.Registry` under `room_id`.
  """
  def start_link(room_id) do
    GenServer.start_link(
      __MODULE__,
      room_id,
      name: via(room_id)
    )
  end

  # ─── GenServer Callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init(room_id) do
    # NOTE: Room.Server intentionally does NOT join the "room:#{room_id}" :pg group.
    # The :pg group is used by external subscribers (EventBus handler, get_sync_delta
    # handler) to receive broadcast events. The Room GenServer itself broadcasts TO the
    # group but does not need to receive its own broadcasts (handle_info ignores them).
    # Keeping the Room GenServer out of the group prevents interference with tests that
    # assert the group is empty after sync handlers clean up.

    # Story 6.9: Archived room guard — check room status BEFORE loading state.
    # If the room is archived, stop with :normal so Horde's :transient restart strategy
    # does not restart the GenServer. This prevents a restart loop on cluster rejoin.
    # Fail-open: if get_room_status fails, we proceed (don't block active rooms on DB error).
    case db_module().get_room_status(room_id) do
      {:ok, "archived"} ->
        {:stop, :normal}

      _ ->
        do_init(room_id)
    end
  end

  defp do_init(room_id) do
    case db_module().load_members(room_id) do
      {:ok, user_ids, created_at_ms, power_levels_json, identity} ->
        {:ok, build_init_state(room_id, user_ids, created_at_ms, power_levels_json, identity)}

      # Legacy 4-tuple shape (test fakes that predate the cluster-safety identity
      # widening, bugfix sync-state-events-missing-fields) — no identity available,
      # fall back to empty member_identity / nil power_levels_event.
      {:ok, user_ids, created_at_ms, power_levels_json} ->
        {:ok,
         build_init_state(room_id, user_ids, created_at_ms, power_levels_json, %{
           members: %{},
           power_levels: nil
         })}

      {:error, :not_found} ->
        case db_module().insert_room(room_id) do
          {:ok, created_at_ms} ->
            # Story 6.8: load max_members even for new rooms (fail-open: default 0).
            # FakeDBWithMaxMembers test verifies this is called even on first start.
            {:ok,
             build_init_state(room_id, [], created_at_ms, "{}", %{
               members: %{},
               power_levels: nil
             })}

          {:error, :not_found} ->
            # Stop with :normal so Horde's :transient strategy does not retry — same
            # pattern as the archived-room guard above. The caller (start_room) gets
            # {:error, _} and maps it to NOT_FOUND; no restart loop is triggered.
            {:stop, :normal}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Shared GenServer-state builder for both the "room exists" and "brand new room"
  # do_init/1 branches. `identity` is `%{members: %{user_id => {event_id, ts}}
  # , power_levels: {event_id, ts} | nil}` (bugfix sync-state-events-missing-fields,
  # cluster-safety) — empty/nil for a brand-new room or a legacy 4-tuple load_members
  # result.
  defp build_init_state(room_id, user_ids, created_at_ms, power_levels_json, identity) do
    created_at = DateTime.from_unix!(created_at_ms, :millisecond)
    power_levels = parse_power_levels(power_levels_json)
    # Story 6.8: load max_members from DB; fail-open (default 0 = no limit).
    max_members =
      case db_module().load_room_settings(room_id) do
        {:ok, n} -> n
        {:error, _} -> 0
      end

    %{
      room_id: room_id,
      members: MapSet.new(user_ids),
      member_identity: Map.get(identity, :members, %{}),
      power_levels: power_levels,
      power_levels_event: Map.get(identity, :power_levels),
      created_at: created_at,
      typing_users: MapSet.new(),
      max_members: max_members
    }
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call({:join, user_id}, _from, %{members: members} = state) do
    cond do
      MapSet.member?(members, user_id) ->
        # :already_member check comes first — even a full room must return :already_member
        # for an existing member (test: "room_full check does not block already_member re-join").
        {:reply, {:error, :already_member}, state}

      state.max_members > 0 and MapSet.size(members) >= state.max_members ->
        # Story 6.8: room is at capacity — reject the join.
        {:reply, {:error, :room_full}, state}

      true ->
        case db_module().insert_member(state.room_id, user_id) do
          :ok ->
            # Emit m.room.member state event so incremental sync (GetSyncDelta)
            # detects the join via fetch_events_since — without this event,
            # the room never appeared in rooms.join on the next delta sync
            # ("stuck on Joining…" in Element Web — GAP-1 fix).
            #
            # Bugfix sync-state-events-missing-fields (AC2): capture the real
            # event_id/origin_server_ts into member_identity at the moment the join
            # is applied, so /sync can thread real identity into m.room.member
            # state.events entries without a per-sync DB round trip.
            identity = emit_membership_event(state.room_id, user_id, "join")

            new_state = %{
              state
              | members: MapSet.put(members, user_id),
                member_identity: put_identity(state.member_identity, user_id, identity)
            }

            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:leave, user_id}, _from, %{members: members} = state) do
    if not MapSet.member?(members, user_id) do
      {:reply, {:error, :not_member}, state}
    else
      case db_module().delete_member(state.room_id, user_id) do
        :ok ->
          # Emit m.room.member leave event so sync delta includes the left room.
          emit_membership_event(state.room_id, user_id, "leave")

          new_state = %{
            state
            | members: MapSet.delete(members, user_id),
              member_identity: Map.delete(state.member_identity, user_id)
          }

          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:remove_member, user_id}, _from, %{members: members} = state) do
    if not MapSet.member?(members, user_id) do
      {:reply, {:error, :not_member}, state}
    else
      case db_module().delete_member(state.room_id, user_id) do
        :ok ->
          new_state = %{
            state
            | members: MapSet.delete(members, user_id),
              member_identity: Map.delete(state.member_identity, user_id)
          }

          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:set_power_levels, new_levels, caller_id}, _from, state) do
    # Allow the call when power_levels is empty (bootstrapping — new room, first assignment).
    # After initial power levels are set, the normal change_state check applies.
    allowed =
      state.power_levels == %{} or
        Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, caller_id, :change_state)

    if allowed do
      case db_module().set_power_levels(state.room_id, Jason.encode!(new_levels)) do
        :ok ->
          # Bugfix sync-state-events-missing-fields (AC2 addendum): m.room.power_levels
          # previously had NO backing persisted event at all — unlike :join's
          # emit_membership_event/3, this call only ever wrote the denormalised
          # rooms.power_levels_json column. Without a real event here,
          # m.room.power_levels can never acquire a real event_id/origin_server_ts
          # for /sync no matter how the read side is implemented. Non-fatal on
          # failure (mirrors emit_membership_event's fail-open philosophy): the
          # power-levels change is still applied. Security review F-1 (2026-10-04):
          # the content update (power_levels_json) and the event write are two
          # separate, non-transactional writes — on emit failure we must nil out
          # the identity rather than keep the PREVIOUS event's identity attached to
          # the NEW content, which would ship a real-looking event_id that
          # dereferences to stale content and lets an event_id-deduping client
          # silently discard the permission change.
          identity = emit_power_levels_event(state.room_id, caller_id, new_levels)

          new_state = %{
            state
            | power_levels: new_levels,
              power_levels_event: identity
          }

          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :forbidden}, state}
    end
  end

  # Backward-compat 5-arg clause: forwards to the 6-arg implementation with state_key=nil.
  # nil signals a regular (non-state) event → `:send_event` power level check (events_default = 0).
  # Kept so any internal callers that still use the 5-arg GenServer.call tuple continue to work.
  @impl GenServer
  def handle_call({:send_event, user_id, event_type, content, txn_id}, from, state) do
    handle_call({:send_event, user_id, event_type, content, txn_id, nil}, from, state)
  end

  @impl GenServer
  def handle_call({:send_event, user_id, event_type, content, txn_id, state_key}, _from, state) do
    room_id = state.room_id

    # Step 0 — Power level check: reject before idempotency lookup.
    # An unauthorized user must not receive an event_id — not even a cached one.
    #
    # SEC Gate 1 fix (Story 9-7): state events (state_key != nil) must be gated through
    # the `:change_state` power level (state_default = 50, Matrix spec default), NOT the
    # `:send_event` check (events_default = 0). Without this distinction, any joined
    # room member could change m.room.name, m.room.topic, m.room.join_rules, etc.
    # Regular events (state_key == nil) continue to use the `:send_event` check.
    power_level_action = if is_nil(state_key), do: :send_event, else: :change_state

    unless Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, user_id, power_level_action) do
      {:reply, {:error, :forbidden}, state}
    else

    # Step 1 — Idempotency check: return existing event_id immediately if found.
    case :ets.lookup(:NebuTxnDedup, {room_id, user_id, txn_id}) do
      [{_, existing_event_id}] ->
        {:reply, {:ok, existing_event_id}, state}

      [] ->
        # Step 1.5 — Archived-status check (TOCTOU fix, Story 9-9).
        # SELECT FOR UPDATE serialises this check with archive_room_atomic/1.
        # Fail-open for {:error, :not_found} — let Core return its existing NOT_FOUND guard.
        # Fail-open for DB errors (log + proceed) — same philosophy as init/1 fail-open.
        archived_check = db_module().check_room_status_for_update(room_id)

        case archived_check do
          {:ok, "archived"} ->
            {:reply, {:error, :room_archived}, state}

          {:error, reason} ->
            # Fail-open: DB error on status check — log and proceed.
            # Same philosophy as init/1 fail-open: don't block active rooms on a transient DB error.
            require Logger
            Logger.warning("check_room_status_for_update failed for #{room_id}: #{inspect(reason)} — proceeding (fail-open)")
            do_send_event(room_id, user_id, event_type, content, txn_id, state_key, state)

          _ ->
            do_send_event(room_id, user_id, event_type, content, txn_id, state_key, state)
        end
    end
    end
  end

  # ─── handle_call for :set_typing ──────────────────────────────────────────

  @impl GenServer
  def handle_call({:set_typing, user_id, typing, timeout_ms}, _from, state) do
    new_typing_users =
      if typing do
        # Schedule auto-expire. Fire-and-forget: stale expire messages are
        # handled gracefully in handle_info({:typing_expire, ...}) below.
        Process.send_after(self(), {:typing_expire, user_id}, timeout_ms)
        MapSet.put(state.typing_users, user_id)
      else
        MapSet.delete(state.typing_users, user_id)
      end

    # Broadcast to :pg room group subscribers.
    members = :pg.get_local_members("room:#{state.room_id}")
    Enum.each(members, fn pid -> send(pid, {:typing_update, user_id, typing}) end)

    {:reply, :ok, %{state | typing_users: new_typing_users}}
  end

  # Story 6.8: update mutable room settings in-memory (fire-and-forget cast).
  # Supported keys: :max_members (non-negative integer; 0 = no limit).
  # This cast is triggered by the gRPC UpdateRoomSettings handler after the Admin DB update.
  @impl GenServer
  def handle_cast({:update_settings, settings}, state) do
    new_state =
      case Map.get(settings, :max_members) do
        nil -> state
        n when is_integer(n) and n >= 0 -> %{state | max_members: n}
        _ -> state
      end

    {:noreply, new_state}
  end

  # Handle incoming :new_event broadcasts from :pg group members (including self).
  # Story 4-4: fire-and-forget — Room GenServer receives its own broadcast.
  # Story 4-8 will add a real subscriber that forwards events to gRPC streams.
  @impl GenServer
  def handle_info({:new_event, _event}, state) do
    {:noreply, state}
  end

  # Handle :typing_expire — auto-clear a user's typing indicator after timeout.
  # Only broadcasts if the user is still in the typing set (prevents double-expire
  # from stale timer messages when typing was already cleared via set_typing=false).
  @impl GenServer
  def handle_info({:typing_expire, user_id}, state) do
    if MapSet.member?(state.typing_users, user_id) do
      new_typing_users = MapSet.delete(state.typing_users, user_id)
      members = :pg.get_local_members("room:#{state.room_id}")
      Enum.each(members, fn pid -> send(pid, {:typing_update, user_id, false}) end)
      {:noreply, %{state | typing_users: new_typing_users}}
    else
      # Stale timer message (user already cleared typing) — no-op.
      {:noreply, state}
    end
  end

  # ─── Private ───────────────────────────────────────────────────────────────

  defp via(room_id), do: {:via, Horde.Registry, {Nebu.Matrix.Room.Registry, room_id}}

  # Parses power_levels_json from DB into an Elixir map with string keys.
  # Returns the defaults map when json is empty ("{}") or blank.
  defp parse_power_levels(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when map == %{} -> %{}
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  defp parse_power_levels(_), do: %{}

  # Builds, signs, and persists an m.room.member state event.
  # Called after successful join/leave DB operations so that incremental sync
  # (GetSyncDelta / fetch_events_since) can detect the membership change.
  # Non-fatal: if event write fails, membership is still applied — we log and continue.
  #
  # Bugfix sync-state-events-missing-fields (AC2): returns `{event_id,
  # origin_server_ts}` on success (nil on failure) so the caller can capture the
  # real identity into member_identity — /sync threads this into m.room.member
  # state.events entries instead of synthesizing fake values.
  defp emit_membership_event(room_id, user_id, membership) do
    event_map = %{
      "room_id"          => room_id,
      "type"             => "m.room.member",
      "state_key"        => user_id,
      "sender"           => user_id,
      "content"          => %{"membership" => membership},
      "origin_server_ts" => Nebu.DB.Helpers.now_ms()
    }

    event_id    = Nebu.Matrix.EventId.generate(event_map)
    event_with_id = Map.put(event_map, "event_id", event_id)

    {_pub, priv} = :persistent_term.get(:nebu_signing_key)
    event_json  = Nebu.Matrix.CanonicalJson.encode!(event_map)
    signature   = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
    sig_b64     = Base.encode64(signature)
    signed      = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

    case db_module().insert_event(signed) do
      :ok ->
        # Broadcast to :pg subscribers so long-poll sync wakes up immediately.
        # Mirrors send_event broadcast — prevents 30-second sync delay after join/leave.
        members = :pg.get_local_members("room:#{room_id}")
        Enum.each(members, fn pid -> send(pid, {:new_event, signed}) end)
        {event_id, event_map["origin_server_ts"]}

      {:error, reason} ->
        # Non-fatal: membership already applied; log but don't roll back.
        require Logger
        Logger.warning("emit_membership_event: failed to write #{membership} event for #{user_id} in #{room_id}: #{inspect(reason)}")
        nil
    end
  end

  # Builds, signs, and persists an m.room.power_levels state event.
  #
  # Bugfix sync-state-events-missing-fields (AC2 addendum): mirrors
  # emit_membership_event/3's pattern — before this fix, set_power_levels only
  # wrote the denormalised rooms.power_levels_json column, so m.room.power_levels
  # had no backing event at all and could never acquire a real event_id/
  # origin_server_ts. Returns `{event_id, origin_server_ts, sender}` on success
  # (nil on failure, non-fatal — the power-levels change is still applied).
  # Code-review cycle 1 (MINOR-2): sender (= caller_id, already a parameter here)
  # is carried in the returned tuple so build_state_events/2 can stop leaving
  # m.room.power_levels.sender as "".
  defp emit_power_levels_event(room_id, caller_id, new_levels) do
    event_map = %{
      "room_id"          => room_id,
      "type"             => "m.room.power_levels",
      "state_key"        => "",
      "sender"           => caller_id,
      "content"          => new_levels,
      "origin_server_ts" => Nebu.DB.Helpers.now_ms()
    }

    event_id      = Nebu.Matrix.EventId.generate(event_map)
    event_with_id = Map.put(event_map, "event_id", event_id)

    {_pub, priv} = :persistent_term.get(:nebu_signing_key)
    event_json  = Nebu.Matrix.CanonicalJson.encode!(event_map)
    signature   = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
    sig_b64     = Base.encode64(signature)
    signed      = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

    case db_module().insert_event(signed) do
      :ok ->
        members = :pg.get_local_members("room:#{room_id}")
        Enum.each(members, fn pid -> send(pid, {:new_event, signed}) end)
        {event_id, event_map["origin_server_ts"], caller_id}

      {:error, reason} ->
        require Logger
        Logger.warning("emit_power_levels_event: failed to write power_levels event for #{room_id}: #{inspect(reason)}")
        nil
    end
  end

  # Stores `identity` (an {event_id, origin_server_ts} tuple) for `user_id` in
  # `map`, or leaves `map` unchanged when `identity` is `nil` (emit failed —
  # non-fatal, matches emit_membership_event/3's fail-open philosophy).
  defp put_identity(map, _user_id, nil), do: map
  defp put_identity(map, user_id, identity), do: Map.put(map, user_id, identity)

  # Steps 2–6 of send_event: build, sign, persist, broadcast.
  # Extracted to keep handle_call({:send_event, ...}) readable after the Step 1.5
  # archived-status check was added (Story 9-9 TOCTOU fix).
  defp do_send_event(room_id, user_id, event_type, content, txn_id, state_key, state) do
    # Step 2 — Build event map with string keys only (architecture rule: no atom keys).
    # Story 9-7: include state_key so state events are correctly persisted and
    # returned by GET /rooms/{roomId}/state/{eventType}.
    #
    # Bugfix unsigned-replaces-state, code-review cycle 2 (MAJOR fix): `state_key`
    # is passed through UNCHANGED, never `|| ""`. The caller (event_dispatcher/
    # server.ex's send_event/2, ~line 169) already computes the correct value:
    # `nil` for a genuine non-state event (e.g. m.room.message via POST /send —
    # the only caller of this function, which always passes is_state_event:
    # false, so `state_key` here is in practice always `nil` today) and a real
    # string (possibly "", e.g. m.room.name) for a genuine state event. The
    # previous `state_key || ""` collapsed that `nil` to `""` BEFORE the DB
    # INSERT, which `Room.DB.insert_event/1` then faithfully (and correctly,
    # per ITS OWN "pass state_key through unchanged" contract) persisted as the
    # literal empty string rather than SQL NULL — corrupting the one signal
    # (`events.state_key IS NULL`) that `event_map_to_core_event/1`'s
    # `is_state_event` field depends on to tell "not a state event" apart from
    # "a state event whose real state_key is empty". Every non-state event ever
    # sent through this path therefore got misclassified as a state event,
    # shipping a spurious `state_key: ""` and — from the 2nd event at that
    # bogus (type, "") slot onward — a bogus `unsigned.replaces_state`. See
    # priv/migrations/000036_backfill_nonstate_events_null_state_key for the
    # historical-data correction this bug also requires.
    event_map = %{
      "room_id"          => room_id,
      "type"             => event_type,
      "state_key"        => state_key,
      "sender"           => user_id,
      "content"          => content,
      "origin_server_ts" => Nebu.DB.Helpers.now_ms()
    }

    # Step 3 — Generate content-hash event_id (architecture rule #7: always via Nebu.Matrix.EventId).
    event_id = Nebu.Matrix.EventId.generate(event_map)
    event_with_id = Map.put(event_map, "event_id", event_id)

    # Step 4 — Sign the canonical event JSON with server Ed25519 key.
    # Key is generated once at Application boot and stored in persistent_term.
    # Sign event_map (WITHOUT event_id and signatures) — Matrix convention:
    # event_id is the content hash, so signing must cover the same payload
    # that was hashed (without event_id). Verifiers rebuild the signed bytes
    # from the event fields, excluding event_id/signatures/unsigned.
    {_pub, priv} = :persistent_term.get(:nebu_signing_key)
    event_json = Nebu.Matrix.CanonicalJson.encode!(event_map)
    signature = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
    sig_b64 = Base.encode64(signature)
    signed_event = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

    # Step 5 — Persist to DB (append-only).
    case db_module().insert_event(signed_event) do
      :ok ->
        # Step 6 — Only on DB success: update ETS, broadcast, return ok.
        # TODO(Story 4-X): Add TTL-based pruning for NebuTxnDedup entries.
        # Currently entries grow unbounded over the lifetime of the VM.
        :ets.insert(:NebuTxnDedup, {{room_id, user_id, txn_id}, event_id})

        # Broadcast to all processes subscribed to this room's :pg group.
        # Fire-and-forget: no subscribers is a no-op (correct for MVP).
        members = :pg.get_local_members("room:#{room_id}")
        Enum.each(members, fn pid -> send(pid, {:new_event, signed_event}) end)

        {:reply, {:ok, event_id}, state}

      {:error, reason} ->
        # AC #3: On DB failure — do NOT insert ETS, do NOT broadcast.
        {:reply, {:error, reason}, state}
    end
  end
end
