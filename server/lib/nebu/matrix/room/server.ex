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
  - `send_event/5` enforces the send level before processing (since story power-levels-enforcement: `events[type]`, else
    `events_default` / `state_default`).
  - `set_power_levels/3` is the internal writer (since story power-levels-enforcement: bootstrap or the level of the levels event).
  - `default_power_levels/0` is a public function for use by EventDispatcher.

  Story power-levels-enforcement (follow-ups `eq`, `er`, `fr`) makes this process the ONE power-level writer:
  - `change_power_levels/4` (`mode: :client`: membership, level, strict v10 shape, the v10 change rules, the idempotent no-op;
    `mode: :internal`: `set_power_levels/3`), stamped max(now, not_before, latest levels ts + 1) and committed in ONE
    transaction of the db module (`apply_power_levels_change/3`: the column AND the event);
  - `send_event/6` re-checks the sender's membership and enforces `events[type]` (else `events_default` / `state_default`);
  - every check reads the levels through the normalised view of `Nebu.Matrix.Room.PowerLevels`.

  Story state-writer-redaction (follow-ups `fw`, `fv`, `fz`, `fx`) adds two more writers of this process, each one transaction
  of the db module:
  - `redact/5`: the ONE redaction writer (membership, the redaction event level, idempotency, the target, `redact` for another
    sender's event; `apply_redaction/2`); `send_event/6` refuses the redaction type;
  - `write_state/5`: the ONE generic state writer (PUT state, the Admin Space form and the upgrade tombstone, `mode: :tombstone`),
    stamped max(now, not_before, latest slot ts + 1) (`latest_state_identity/3`, `apply_state_change/3`).

  Story 4-17 adds ephemeral typing state:
  - `set_typing/4` manages `typing_users: MapSet` in GenServer state.
  - Typing state is EPHEMERAL — Persistence Strategy: Option C (Stateless).
  - Auto-expiry via `Process.send_after/3` → `{:typing_expire, user_id}`.
  - Broadcasts `{:typing_update, user_id, typing}` via :pg room group.

  Story moderation-routes-atomic-ban adds the member writer (follow-up `ex`): every membership change that a ban can race is
  decided and written in this process, stamped max(now, latest member ts + 1) and committed in ONE transaction of the db module
  (`apply_member_change/4`):
  - `moderate/6`: kick (incl. the revocation of a pending invitation), ban (incl. pre-emptive and idempotent bans) and unban;
  - `write_invite/5`: the invite event of `POST /invite` and createRoom (the caller keeps the caps and the invitation row);
  - `write_decline/2`: the self-leave of a declined invitation;
  - `join/3`: the join with the basis of the caller's decision (`:membership_changed` when it is stale).

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
                        # m.room.power_levels event, captured when the power-level writer
                        # commits a change (story power-levels-enforcement). Restored on restart.
      created_at:       DateTime.t(),
      typing_users:     MapSet.t(String.t()),  # ephemeral — resets on restart
      max_members:      non_neg_integer()      # 0 = no limit; Story 6.8
    }

  ## Fail-open semantics of `member_identity` / `power_levels_event` (code-review
  ## cycle 1, MINOR-5)

  Both fields are BEST-EFFORT caches of real event identity, not guaranteed-present
  invariants. Each can legitimately be absent (a member with no entry in
  `member_identity`, or `power_levels_event: nil`) or STALE (pointing at an older
  event than the member's actual current state) whenever the backing
  `insert_event` write failed — `emit_membership_event/4` is deliberately
  non-fatal: if persistence fails, the membership change is still applied to
  `members` (the user is still joined), the identity update is simply skipped,
  and only a warning is logged. The power levels are no longer fail-open (story
  power-levels-enforcement, D10): the column and the event are ONE transaction,
  so `power_levels_event` is `nil` only for a legacy room without a levels event.
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

  require Logger

  alias Nebu.Matrix.Room.PowerLevels

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
  def join(room_id, user_id), do: join(room_id, user_id, :any)

  @doc """
  `join/2` with the BASIS of the caller's join decision (story moderation-routes-atomic-ban, D9): `:any` when the decision needed
  no invitation (a public rule, an allow-room membership, the internal joins of `join/2`), `{:invited, event_id | nil}` when it
  rested on an invitation: the id of the latest member event the decision read (`nil`: a row-only invitation without any member
  event). The room process compares it with the latest member event it reads right before the member insert; a difference (a
  revocation, a ban, a re-invite or an unban in between) is `{:error, :membership_changed}` and nothing is written, the caller
  decides again on fresh data. A ban is refused first (`{:error, :banned}`).
  """
  @spec join(String.t(), String.t(), :any | {:invited, String.t() | nil}) :: :ok | {:error, term()}
  def join(room_id, user_id, basis), do: GenServer.call(via(room_id), {:join, user_id, basis})

  @typedoc "The outcome of a committed moderation (`moderate/6` with `outcome: true`)."
  @type moderation_outcome :: %{event_written: boolean(), invitation_revoked: boolean()}

  @doc """
  Kick, ban or unban `target` on behalf of `sender` (story moderation-routes-atomic-ban, D1-D4): decided AND written in this room
  process, so every membership change that a ban can race is serialised per room.

  The decision, first failure wins (`{:error, atom}`): the sender is joined (`:sender_not_joined`); the sender has the action
  level (kick: `kick`, ban: `ban`, unban: `ban` AND `kick`; `:insufficient_level`); the target's level is strictly lower than the
  sender's (`:target_not_lower`; a self-moderation is always refused); ONE read of the target's latest member event (and, for a
  kick of a non-member, of the pending invitation; a failing read is `:membership_unavailable`); the target state:

    * kick: a member is kicked, a pending invitee is REVOKED (the leave has `sender != state_key`), a banned user is
      `:target_banned`, anyone else `:target_not_in_room`;
    * ban: every state is banned (pre-emptive bans included); an already banned user is an idempotent success WITHOUT a new event;
    * unban: only a banned user (`:not_banned` otherwise).

  The event (`{"membership": "leave" | "ban"}` plus `reason` when given) is stamped max(now, latest member ts + 1) and size-checked
  before anything is written (`:event_too_large`, or the key refusals of `Nebu.Matrix.EventSize.check_keys/3`). The write is ONE
  transaction (`apply_member_change/4` of the db module: member removal, invitation reject, the event); a failure is
  `:write_failed` (or `:unsupported_db_module` for a db module without it) and changes nothing. The member set, the broadcast and
  the `user:<target>` wake-up follow the commit only. An archived room refuses every moderation (`:room_archived`, also while
  this process still runs).

  Answers `:ok`; with `outcome: true` `{:ok, moderation_outcome}` (the dispatcher's audit row needs it, the idempotent ban is not
  audited). Not rate-charged here: the routes charge, internal callers (the ban copy of `upgrade_room`) do not.
  """
  @spec moderate(String.t(), :kick | :ban | :unban, String.t(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:ok, moderation_outcome()} | {:error, atom()}
  def moderate(room_id, action, sender, target, reason, opts \\ []) when action in [:kick, :ban, :unban] do
    case GenServer.call(via(room_id), {:moderate, action, sender, target, reason}) do
      {:ok, outcome} -> if Keyword.get(opts, :outcome, false), do: {:ok, outcome}, else: :ok
      {:error, _reason} = refusal -> refusal
    end
  end

  @doc """
  The invite EVENT of `POST /invite` and createRoom step 8 (story moderation-routes-atomic-ban, D7; Kassandra M-1): the caller
  keeps its checks, the caps and the invitation row, this process decides the rest on fresh state and writes the event. The
  inviter is joined and has the `invite` level (`:inviter_not_joined` / `:insufficient_level`), the invitee is not a member
  (`:already_member`), ONE read of the invitee's latest member event (`:membership_unavailable`): a `ban` rejects the pending row
  (a banned user never holds one, also not one the caller just re-armed) and is `{:error, :banned}`. Otherwise the event is stamped
  max(now, `not_before`, latest member ts + 1), size-checked and inserted: `{:ok, event_id, origin_server_ts}`, but only while the
  invitation row is still pending (review cycle 1, M5: `:invitation_gone` when a revocation or a decline took it back in
  between, nothing written); an archived room is `:room_archived`; a failing insert is `:write_failed` (`:duplicate_event` for a
  unique violation).
  """
  @spec write_invite(String.t(), String.t(), String.t(), map(), non_neg_integer()) ::
          {:ok, String.t(), integer()} | {:error, atom()}
  def write_invite(room_id, inviter, invitee, content, not_before) do
    GenServer.call(via(room_id), {:write_invite, inviter, invitee, content, not_before})
  end

  @doc """
  The self-leave of a DECLINED invitation (story moderation-routes-atomic-ban, D8): ONE read of the user's latest member event
  (`:membership_unavailable`); a `ban` is `{:error, :banned}` and nothing is written (a self-leave newer than the ban would lift
  it), a member is `{:error, :member}` (his leave is `leave/2`); nothing left to decline (the latest membership is `leave` and no
  pending invitation remains: a revocation or another decline won the race) is `:ok` WITHOUT a new event (review cycle 1, M6; a
  taken-back row that is still pending is rejected); otherwise the leave is stamped max(now, latest member ts + 1) and written
  together with the reject of the pending invitation in ONE transaction. `:ok` | `{:error, :write_failed | :room_archived | ..}`.
  """
  @spec write_decline(String.t(), String.t()) :: :ok | {:error, atom()}
  def write_decline(room_id, user_id), do: GenServer.call(via(room_id), {:write_decline, user_id})

  @doc """
  Removes `user_id` from the room's member set (soft-delete in DB).

  Returns `:ok` on success, `{:error, :not_member}` if not currently joined,
  or `{:error, reason}` on DB failure (state unchanged).
  """
  @spec leave(String.t(), String.t()) :: :ok | {:error, term()}
  def leave(room_id, user_id), do: GenServer.call(via(room_id), {:leave, user_id})

  @doc """
  Returns the default Matrix power levels map.

  Public so that EventDispatcher.Server and tests can build creator-boosted maps
  without duplicating the defaults. String keys throughout (architecture rule).
  """
  @spec default_power_levels() :: map()
  def default_power_levels, do: Nebu.Matrix.Room.PowerLevels.default_levels()

  @doc """
  The INTERNAL power-level writer: `change_power_levels/4` with `mode: :internal` (createRoom step 3, the initial levels of an
  upgraded room, test seeds; never reachable from a client request). Its authorisation is the one it always had: any caller
  while the in-memory levels are `%{}` (the bootstrap of a new room), else the caller's level must reach
  `events["m.room.power_levels"]` (else `state_default`); NO v10 change rules. The content must pass the strict shape.

  Returns `:ok`, `{:error, :forbidden}` if the caller lacks power, or `{:error, reason}` (`{:invalid, text}`, `:event_too_large`,
  `:write_failed`, `:unsupported_db_module`, `:room_archived`); nothing is written on an error.
  """
  @spec set_power_levels(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def set_power_levels(room_id, caller_id, new_levels) do
    case change_power_levels(room_id, caller_id, new_levels, mode: :internal) do
      {:ok, _event_id, _outcome} -> :ok
      {:error, _reason} = refusal -> refusal
    end
  end

  @typedoc "The outcome of a power-level change: whether an event was written, the content it replaced and its stamp."
  @type power_levels_outcome :: %{changed: boolean(), previous: map(), ts: integer() | nil}

  @doc """
  The ONE power-level writer (story power-levels-enforcement, D1, D2, D10): every `m.room.power_levels` event and every write of
  the `rooms.power_levels_json` column is decided AND written in this process, serialised with kick / ban / invite / send.

  `mode: :client` (the PUT route, the createRoom `initial_state` entry, the upgrade copy, the unrouted dispatcher writer), first
  failure wins: the sender is joined (`:sender_not_joined`); his level reaches `events["m.room.power_levels"]` else
  `state_default` (`:insufficient_level`); the content passes `PowerLevels.validate_content/1` (`{:invalid, fixed text}`); with a
  previous levels event the v10 change rules against the CURRENT stored content (`:above_own_level`, `:grant_above_own_level`,
  `:target_not_lower`; v10 rule 4 allows only without an event AND without stored levels); identical content is an idempotent success with the CURRENT event id and
  nothing written (a Nebu choice). `mode: :internal`: see `set_power_levels/3`.

  The event is stamped max(now, `not_before`, latest levels event ts + 1) (the latest is the in-memory identity, else ONE read
  through the db module; a failing read fails closed), size-checked (`:event_too_large`) and written in ONE transaction
  (`apply_power_levels_change/3` of the db module: `:write_failed`, `:room_archived`, `:unsupported_db_module` for a db module
  without it). The in-memory levels, the identity and the broadcast follow the commit only.

  Answers `{:ok, event_id, power_levels_outcome}` or `{:error, reason}`.
  """
  @spec change_power_levels(String.t(), String.t(), map(), keyword()) :: {:ok, String.t(), power_levels_outcome()} | {:error, term()}
  def change_power_levels(room_id, sender, content, opts \\ []) do
    GenServer.call(via(room_id), {:change_power_levels, sender, content, opts})
  end

  @typedoc "The outcome of a committed (or replayed) redaction: whether it was an idempotent replay and the sender of the target."
  @type redaction_outcome :: %{replayed: boolean(), target_sender: String.t() | nil}

  @doc """
  The ONE redaction writer (story state-writer-redaction, D1, D2, D7): every `m.room.redaction` Nebu writes is decided AND written
  in this room process, serialised with power-level changes, kicks, bans and state writes. `txn_key` is the idempotency key of the
  caller (`send_txn_key/4` for `/send`, `{room_id, user_id, {:redact, event_id, txn_id}}` for `PUT /redact`).

  The decision, first failure wins: the sender is joined (`:sender_not_joined`); his level reaches `events["m.room.redaction"]`
  else `events_default` (`:forbidden`); a cached event id for `txn_key` is answered (`replayed: true`, nothing written); the
  target is read through the db module (`:target_not_found` in another room or unknown, `:not_redactable` for a state event or
  a redaction, `:write_failed` for a failing read); the target of ANOTHER sender needs the `redact` level
  (`:insufficient_redact_level`); a target that already has a writer-made redaction is answered with the EARLIEST one
  (`replayed: true`, nothing written, nothing remembered: security cycle 1, Kassandra #1; `redactions_for/1`, a failing read is
  `:write_failed`); the event is built for the room version (`:unsupported_room_version`), size-checked
  (`:event_too_large`) and written in ONE transaction (`apply_redaction/2`: `:room_archived`, `:write_failed`,
  `:unsupported_db_module`). ETS, broadcast and the answer follow the commit.

  Answers `{:ok, event_id, redaction_outcome}` or `{:error, reason}`.
  """
  @spec redact(String.t(), String.t(), String.t(), map(), term()) :: {:ok, String.t(), redaction_outcome()} | {:error, atom()}
  def redact(room_id, sender, target_event_id, content, txn_key) do
    GenServer.call(via(room_id), {:redact, sender, target_event_id, content, txn_key})
  end

  @doc """
  The redaction event of a room version (D5 guard): the v10 PDU shape, a top-level `redacts` and the client content WITHOUT a
  `redacts` key. Any other room version is `{:error, :unsupported_room_version}` until a story stores `content.redacts` (v11).
  """
  @spec redaction_event(String.t(), String.t(), String.t(), String.t(), map(), integer()) :: {:ok, map()} | {:error, :unsupported_room_version}
  def redaction_event("10", room_id, sender, target, content, ts) do
    {:ok,
     %{
       "room_id" => room_id,
       "type" => "m.room.redaction",
       "state_key" => nil,
       "sender" => sender,
       "content" => Map.delete(content, "redacts"),
       "redacts" => target,
       "origin_server_ts" => ts
     }}
  end

  def redaction_event(_other_version, _room_id, _sender, _target, _content, _ts), do: {:error, :unsupported_room_version}

  @doc """
  The ONE generic state writer (story state-writer-redaction, D8, D11): decided and written in this room process. `opts`:
  `mode: :client` (default) or `:tombstone` (the level is `max(events["m.room.tombstone"] else state_default, 100)`),
  `not_before:` (a stamp floor). First failure wins: `:sender_not_joined`, `:insufficient_level`, `:foreign_user_key` (a state
  key starting with `@` that is not the sender's); the stamp is `max(now, not_before, latest slot ts + 1)` with the latest read
  through the db module (`latest_state_identity/3`; a failing read is `:write_failed`, a db module without it
  `:unsupported_db_module`); the event is size-checked and written in ONE transaction (`apply_state_change/3`: the event and,
  for `m.room.name` with the empty state key, `rooms.name`; `:room_archived`, `:write_failed`). Broadcast after the commit.

  Answers `{:ok, event_id}` or `{:error, reason}`.
  """
  @spec write_state(String.t(), String.t(), {String.t(), String.t()}, map(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def write_state(room_id, sender, {type, state_key}, content, opts \\ []) do
    GenServer.call(via(room_id), {:write_state, sender, {type, state_key}, content, opts})
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

  Checks txn_id idempotency via ETS `NebuTxnDedup` after the authorisation. On cache hit,
  returns the existing event_id immediately without re-processing.

  On cache miss: builds the event map, generates a content-hash event_id
  via `Nebu.Matrix.EventId.generate/1`, signs the canonical JSON with the server
  Ed25519 key, persists to PostgreSQL `events`, inserts into ETS, and
  broadcasts `{:new_event, signed_event}` via `:pg` room group.

  Returns `{:ok, event_id}` on success or `{:error, reason}` on DB failure.
  On DB failure: ETS is NOT updated and NO broadcast is sent.

  `state_key` is optional (default `nil`). For state events, pass the Matrix
  state_key as a string (e.g. `""` for m.room.name, user_id for m.room.member).
  A non-nil `state_key` (including `""`) signals that this is a state event: its level is
  `events[type]` else `state_default` (Story 9-7 / SEC Gate 1 fix); a message event needs
  `events[type]` else `events_default` (story power-levels-enforcement, D5).

  The order (D5 (d)): the sender must be joined (`{:error, :sender_not_joined}`, re-checked in
  this process), then the level (`{:error, :forbidden}`), then the idempotency lookup, then the
  archived check (`{:error, :room_archived}`).
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
  def handle_call({:join, user_id, basis}, _from, %{members: members} = state) do
    cond do
      MapSet.member?(members, user_id) ->
        # :already_member check comes first — even a full room must return :already_member
        # for an existing member (test: "room_full check does not block already_member re-join").
        {:reply, {:error, :already_member}, state}

      state.max_members > 0 and MapSet.size(members) >= state.max_members ->
        # Story 6.8: room is at capacity — reject the join.
        {:reply, {:error, :room_full}, state}

      true ->
        inserted =
          with {:ok, latest} <- check_not_banned(state.room_id, user_id, basis),
               :ok <- db_module().insert_member(state.room_id, user_id) do
            {:ok, latest}
          end

        case inserted do
          {:ok, latest} ->
            # Emit m.room.member state event so incremental sync (GetSyncDelta)
            # detects the join (its partition and its position range) — without this event,
            # the room never appeared in rooms.join on the next delta sync
            # ("stuck on Joining…" in Element Web — GAP-1 fix).
            #
            # Bugfix sync-state-events-missing-fields (AC2): capture the real
            # event_id/origin_server_ts into member_identity at the moment the join
            # is applied, so /sync can thread real identity into m.room.member
            # state.events entries without a per-sync DB round trip.
            #
            # Story member-event-prev-content (D4 (a)): the join is stamped max(now, ts of the user's latest member event
            # + 1) (`latest` is that event, read by the ban check), so it is strictly newer than the invite it answers.
            identity = emit_membership_event(state.room_id, user_id, "join", latest)

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
          #
          # Story member-event-prev-content (D4 (b)): stamped max(now, latest member event ts + 1).
          emit_membership_event(state.room_id, user_id, "leave", latest_member_or_nil(state.room_id, user_id))

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

  # ─── the member writer (story moderation-routes-atomic-ban, D1-D4, D7, D8) ──────────────────────────────────────
  #
  # Every member event that a ban can race is decided and written HERE: kick / ban / unban (`moderate/6`), the invite event
  # (`write_invite/5`), the decline (`write_decline/2`) and the join (`{:join, ..}`). The facts of a decision are read inside the
  # call, right before the write (the caller's reads are fast-path refusals only); the stamp is max(now, latest member ts + 1) of
  # that read; the write is ONE transaction; the member set, broadcasts and wake-ups follow the commit. A failure leaves the state
  # as it was, so a retry starts from scratch. Never call this process from inside one of these calls (a db hook that does would
  # deadlock).

  @impl GenServer
  def handle_call({:moderate, action, sender, target, reason}, _from, state) do
    with {:ok, plan} <- moderation_plan(state, action, sender, target),
         {:ok, signed} <- moderation_event(state.room_id, action, sender, target, reason, plan) do
      # one transaction for every outcome: the target is no member and holds no pending invitation afterwards (the idempotent
      # ban included: it closes a legacy half state, D4 (b))
      case commit_member_change(state.room_id, target, signed, remove_member: true, reject_invitation: true) do
        :ok ->
          if signed, do: broadcast_room(state.room_id, signed)
          if action in [:kick, :ban], do: wake_user(target, {:new_leave, state.room_id})
          outcome = %{event_written: signed != nil, invitation_revoked: plan.target_state == :invite}
          {:reply, {:ok, outcome}, drop_member(state, target)}

        {:error, _reason} = failure ->
          {:reply, failure, state}
      end
    else
      {:error, _reason} = refusal -> {:reply, refusal, state}
    end
  end

  @impl GenServer
  def handle_call({:write_invite, inviter, invitee, content, not_before}, _from, state) do
    room_id = state.room_id

    reply =
      cond do
        not MapSet.member?(state.members, inviter) -> {:error, :inviter_not_joined}
        not PowerLevels.can?(state.power_levels, inviter, :invite) -> {:error, :insufficient_level}
        MapSet.member?(state.members, invitee) -> {:error, :already_member}
        true -> invite_on_fresh_state(room_id, inviter, invitee, content, not_before)
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:write_decline, user_id}, _from, state) do
    room_id = state.room_id

    reply =
      with {:ok, latest} <- read_latest_member(room_id, user_id) do
        cond do
          membership_of(latest) == "ban" ->
            {:error, :banned}

          MapSet.member?(state.members, user_id) ->
            {:error, :member}

          # review cycle 1 (M6): nothing left to decline (a revocation or another decline won the race): no second leave event,
          # which would replace the kicker's revocation as the latest membership; a taken-back row that is still pending is closed
          membership_of(latest) == "leave" and not pending_or_unknown?(room_id, user_id, latest) ->
            # review cycle 3 (Kassandra I-3): an archived room refuses the reject; there is nothing to decline either way, so the
            # answer stays the no-op (the caller must not fall back to writing a second leave)
            case commit_member_change(room_id, user_id, nil, reject_invitation: true) do
              {:error, :room_archived} -> :ok
              other -> other
            end

          true ->
            # no key check: the decline of a legacy user id above 255 bytes must stay possible (as the leave of a member)
            with {:ok, signed} <- member_event(room_id, user_id, user_id, %{"membership" => "leave"}, stamp(latest, 0)),
                 :ok <- commit_member_change(room_id, user_id, signed, reject_invitation: true) do
              broadcast_room(room_id, signed)
              :ok
            end
        end
      end

    {:reply, reply, state}
  end

  # the ONE power-level writer (story power-levels-enforcement, D1): see change_power_levels/4 and the writer section below
  @impl GenServer
  def handle_call({:change_power_levels, sender, content, opts}, _from, state) do
    mode = Keyword.get(opts, :mode, :client)

    case power_levels_decision(state, mode, sender, content) do
      {:noop, event_id} ->
        {:reply, {:ok, event_id, %{changed: false, previous: state.power_levels, ts: nil}}, state}

      {:write, latest} ->
        write_power_levels(state, sender, content, latest, Keyword.get(opts, :not_before, 0))

      {:error, _reason} = refusal ->
        {:reply, refusal, state}
    end
  end

  # the ONE redaction writer (story state-writer-redaction, D1): see redact/5 and the writer section below
  @impl GenServer
  def handle_call({:redact, sender, target, content, txn_key}, _from, state) do
    {:reply, decide_and_write_redaction(state, sender, target, content, txn_key), state}
  end

  # the ONE generic state writer (story state-writer-redaction, D8): see write_state/5 and the writer section below
  @impl GenServer
  def handle_call({:write_state, sender, slot, content, opts}, _from, state) do
    {:reply, decide_and_write_state(state, sender, slot, content, opts), state}
  end

  # Backward-compat 5-arg clause: forwards to the 6-arg implementation with state_key=nil.
  # nil signals a regular (non-state) event → its level is `events[type]`, else `events_default` (story power-levels-enforcement).
  # Kept so any internal callers that still use the 5-arg GenServer.call tuple continue to work.
  @impl GenServer
  def handle_call({:send_event, user_id, event_type, content, txn_id}, from, state) do
    handle_call({:send_event, user_id, event_type, content, txn_id, nil}, from, state)
  end

  @impl GenServer
  def handle_call({:send_event, user_id, event_type, content, txn_id, state_key}, _from, state) do
    room_id = state.room_id

    # The order (story power-levels-enforcement, D5 (d)): membership, level, idempotency, archived check. Authorisation comes
    # first: a non-member or an unauthorised user never receives an event id (not even a cached one) and never causes the
    # locking status read, and a non-member learns nothing about the archived state.
    #
    # Step 0a — the membership, re-checked HERE (the caller's check runs on a snapshot): a send decided just before a kick /
    # ban is refused after it.
    #
    # Step 0b — the level of THIS event type (D5 (a)): `events[type]`, else `events_default` for a message event (state_key ==
    # nil) and `state_default` for a state event (SEC Gate 1 fix of story 9-7: a state event never passes at events_default).
    kind = if is_nil(state_key), do: :message, else: :state

    cond do
      # story state-writer-redaction (D1, defence in depth): a redaction has ONE writer, redact/5
      event_type == "m.room.redaction" ->
        {:reply, {:error, :forbidden}, state}

      not MapSet.member?(state.members, user_id) ->
        {:reply, {:error, :sender_not_joined}, state}

      not PowerLevels.can?(state.power_levels, user_id, {kind, event_type}) ->
        {:reply, {:error, :forbidden}, state}

      true ->
        send_authorised_event(room_id, user_id, event_type, content, txn_id, state_key, state)
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

  # Parses power_levels_json from DB into an Elixir map with string keys: the RAW stored content (story power-levels-enforcement,
  # D4: every check reads it through the normalised view of PowerLevels, /sync and the change rules see it as stored). Anything
  # that is not a JSON object reads as %{} (nobody reaches a level then).
  defp parse_power_levels(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp parse_power_levels(_), do: %{}

  # The ban check of EVERY join (the internal ones too: creator, upgrade, auto-join), inside this process right before the member
  # insert (review cycle 2 of create-room-presets-power-levels-topic, Kassandra N-1 / N-1b). Story moderation-routes-atomic-ban
  # (follow-up `ex` CLOSED): kick, ban and unban, the invite event and the decline are decided and written in this process too,
  # stamped max(now, latest member ts + 1) and committed in ONE transaction, so a join can no longer slip its event behind a ban
  # (the member set AND the event order are protected). The join also carries the BASIS of the caller's decision (D9): a decision
  # that rested on an invitation names the latest member event it read; when the latest member event is another one now (a
  # revocation, a re-invite, an unban in between), the join is `:membership_changed` and nothing is written. A ban is refused
  # first, whatever the basis. Answers `{:ok, latest}` (the event the join is stamped after, nil when there is none). Reader: see
  # `read_latest_member/2`; a failing read refuses the join (fail closed).
  defp check_not_banned(room_id, user_id, basis) do
    with {:ok, latest} <- read_latest_member(room_id, user_id) do
      cond do
        membership_of(latest) == "ban" -> {:error, :banned}
        basis_changed?(basis, latest) -> {:error, :membership_changed}
        true -> {:ok, latest}
      end
    end
  end

  # a decision on an invitation is stale when the latest member event is not the one it read (`nil`: it read none); a reader
  # without event ids (an injected fake with only get_member_membership/2) cannot tell, the ban check still applies
  defp basis_changed?({:invited, event_id}, nil), do: event_id != nil
  defp basis_changed?({:invited, event_id}, %{event_id: current}), do: current != event_id
  defp basis_changed?(_basis, _latest), do: false

  # The latest member event of the user, ONE read through the db module: `{:ok, %{membership, origin_server_ts, event_id, ..} |
  # nil}`. latest_member_event/2 (Room.DB, story member-event-prev-content), else get_member_membership/2 (an injected fake: no
  # stamp, no event id), else no state at all (`{:ok, nil}`, a fake without either). A failing read is
  # `{:error, :membership_unavailable}` (fail closed: no decision of the member writer is taken on unknown state).
  defp read_latest_member(room_id, user_id) do
    mod = db_module()

    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, :latest_member_event, 2) ->
        case guarded_read(fn -> mod.latest_member_event(room_id, user_id) end) do
          {:ok, latest} when is_map(latest) or is_nil(latest) -> {:ok, latest}
          _other -> membership_unavailable(room_id)
        end

      Code.ensure_loaded?(mod) and function_exported?(mod, :get_member_membership, 2) ->
        case guarded_read(fn -> mod.get_member_membership(room_id, user_id) end) do
          {:ok, nil} -> {:ok, nil}
          {:ok, membership} when is_binary(membership) -> {:ok, %{membership: membership}}
          _other -> membership_unavailable(room_id)
        end

      true ->
        {:ok, nil}
    end
  end

  # the leave of a member: its event is stamped after the latest member event; a failing read never refuses the leave
  defp latest_member_or_nil(room_id, user_id) do
    case read_latest_member(room_id, user_id) do
      {:ok, latest} -> latest
      {:error, _reason} -> nil
    end
  end

  defp membership_of(%{membership: membership}), do: membership
  defp membership_of(_latest), do: nil

  # Story member-event-prev-content (D4) and moderation-routes-atomic-ban (D2 (6), the binding stamp rule of `ex`): a member event
  # is stamped max(now, not_before, ts of the user's latest member event + 1), so the slot order stays strict and every writer of
  # this process lands after the event its decision read.
  defp stamp(latest, not_before) do
    after_latest =
      case latest do
        %{origin_server_ts: ts} when is_integer(ts) -> ts + 1
        _ -> 0
      end

    Enum.max([Nebu.DB.Helpers.now_ms(), not_before, after_latest])
  end

  defp membership_unavailable(room_id) do
    Logger.error("room #{room_id}: failed to read the membership state")
    {:error, :membership_unavailable}
  end

  defp guarded_read(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # ─── kick / ban / unban: the decision (D2, D4) ─────────────────────────────────────────────────────────────────

  # first failure wins; the levels come from this process (the authority: every power-level change is committed here too,
  # story power-levels-enforcement, so a demoted moderator's next moderation is decided on the new levels)
  defp moderation_plan(state, action, sender, target) do
    levels = state.power_levels

    cond do
      not MapSet.member?(state.members, sender) ->
        {:error, :sender_not_joined}

      not moderation_level?(levels, sender, action) ->
        {:error, :insufficient_level}

      # room v10: the target's level (a non-member's too: `users` or `users_default`) must be strictly lower; a self-moderation
      # is therefore always refused (a self-KICK is a Nebu choice, v10 would allow a self-leave: `POST /leave` is that path)
      PowerLevels.get_user_level(levels, target) >= PowerLevels.get_user_level(levels, sender) ->
        {:error, :target_not_lower}

      true ->
        with {:ok, latest} <- read_latest_member(state.room_id, target),
             {:ok, target_state} <- target_state(state, action, target, latest),
             {:ok, membership} <- moderation_rule(action, target_state) do
          {:ok, %{latest: latest, target_state: target_state, membership: membership}}
        end
    end
  end

  # room v10: kick needs `kick`, ban needs `ban`, an unban (ban -> leave by another user) needs BOTH: the leave rule checks the
  # ban level for a banned target before the kick level
  defp moderation_level?(levels, sender, :unban), do: PowerLevels.can?(levels, sender, :ban) and PowerLevels.can?(levels, sender, :kick)
  defp moderation_level?(levels, sender, action), do: PowerLevels.can?(levels, sender, action)

  # :join | :invite | :ban | :none. The latest `ban` decides first for every action (review cycle 1, Kassandra L-2): a kick of a
  # member behind a ban (a half state) would write a newer `leave`, i.e. lift the ban with only the kick level; it is refused
  # ("unban them instead") and a repeated ban repairs the half state. The pending invitation is read only for a kick of a non-member.
  defp target_state(state, action, target, latest) do
    member? = MapSet.member?(state.members, target)
    banned? = membership_of(latest) == "ban"

    cond do
      banned? -> {:ok, :ban}
      member? -> {:ok, :join}
      action == :kick -> with {:ok, pending?} <- invitation_pending?(state.room_id, target, latest), do: {:ok, if(pending?, do: :invite, else: :none)}
      true -> {:ok, :none}
    end
  end

  # the target-state rules (D4): the membership of the event to write, `nil` for the idempotent ban (no new event)
  defp moderation_rule(:kick, :ban), do: {:error, :target_banned}
  defp moderation_rule(:kick, :none), do: {:error, :target_not_in_room}
  defp moderation_rule(:kick, _joined_or_invited), do: {:ok, "leave"}
  defp moderation_rule(:ban, :ban), do: {:ok, nil}
  defp moderation_rule(:ban, _any), do: {:ok, "ban"}
  defp moderation_rule(:unban, :ban), do: {:ok, "leave"}
  defp moderation_rule(:unban, _not_banned), do: {:error, :not_banned}

  # Story sync-membership-partition (D13), the predicate of the join decision: a pending row counts only when it was not TAKEN
  # BACK by a `leave` member event at least as new as the invitation. A db module without the read has no invitations.
  defp invitation_pending?(room_id, user_id, latest) do
    mod = db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :pending_invitation, 2) do
      case guarded_read(fn -> mod.pending_invitation(room_id, user_id) end) do
        {:ok, nil} ->
          {:ok, false}

        {:ok, invited_at} when is_integer(invited_at) ->
          case latest do
            %{membership: "leave", origin_server_ts: ts} when is_integer(ts) and ts >= invited_at -> {:ok, false}
            _ -> {:ok, true}
          end

        _other ->
          membership_unavailable(room_id)
      end
    else
      {:ok, false}
    end
  end

  # a pending invitation that was not taken back; a failing read counts as pending (the decline then writes, as before)
  defp pending_or_unknown?(room_id, user_id, latest) do
    case invitation_pending?(room_id, user_id, latest) do
      {:ok, pending?} -> pending?
      {:error, _reason} -> true
    end
  end

  # the event of a moderation: none for the idempotent ban, else `{"membership": ..}` plus the reason, sent by the moderator
  defp moderation_event(_room_id, _action, _sender, _target, _reason, %{membership: nil}), do: {:ok, nil}

  defp moderation_event(room_id, _action, sender, target, reason, %{membership: membership, latest: latest}) do
    content = if is_binary(reason) and reason != "", do: %{"membership" => membership, "reason" => reason}, else: %{"membership" => membership}
    checked_member_event(room_id, sender, target, content, stamp(latest, 0))
  end

  # the invite event on the state of THIS call (D7): a ban seen here rejects the pending row
  defp invite_on_fresh_state(room_id, inviter, invitee, content, not_before) do
    with {:ok, latest} <- read_latest_member(room_id, invitee) do
      if membership_of(latest) == "ban" do
        _ = commit_member_change(room_id, invitee, nil, reject_invitation: true)
        {:error, :banned}
      else
        ts = stamp(latest, not_before)

        # review cycle 1 (M5): the event is inserted only while the row the caller wrote is still pending (a revocation or a
        # decline between the row and this call leaves no usable invitation: `:invitation_gone`, nothing written)
        with {:ok, signed} <- checked_member_event(room_id, inviter, invitee, content, ts),
             :ok <- commit_member_change(room_id, invitee, signed, require_pending_invitation: true) do
          broadcast_room(room_id, signed)
          {:ok, signed["event_id"], ts}
        end
      end
    end
  end

  # ─── the member event and its write ──────────────────────────────────────────────────────────────────────────────

  # the key limits of story event-size-limit (D2) on the event of a moderation, an invite or a decline (`sender` / `state_key`
  # at most 255 bytes), then the event
  defp checked_member_event(room_id, sender, state_key, content, ts) do
    with :ok <- Nebu.Matrix.EventSize.check_keys("m.room.member", state_key, sender) do
      member_event(room_id, sender, state_key, content, ts)
    end
  end

  # The member events of this process (see signed_state_event/6).
  defp member_event(room_id, sender, state_key, content, ts), do: signed_state_event(room_id, "m.room.member", sender, state_key, content, ts)

  # The ONE builder of the state events of this process (member events, the levels event): the event map, the size backstop of
  # story event-size-limit on the canonical bytes BEFORE the signature (`{:error, :event_too_large}`, nothing is written), the
  # content-hash id, the Ed25519 signature of the server key.
  defp signed_state_event(room_id, type, sender, state_key, content, ts) do
    signed_event(%{
      "room_id"          => room_id,
      "type"             => type,
      "state_key"        => state_key,
      "sender"           => sender,
      "content"          => content,
      "origin_server_ts" => ts
    })
  end

  # the size backstop, the content-hash id and the signature of ANY event map of this process (the state events above, the
  # redaction event of redaction_event/6)
  defp signed_event(event_map) do
    event_json = Nebu.Matrix.CanonicalJson.encode!(event_map)

    with :ok <- Nebu.Matrix.EventSize.check_stored(event_json) do
      {_pub, priv} = :persistent_term.get(:nebu_signing_key)
      signature = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])

      {:ok,
       event_map
       |> Map.put("event_id", Nebu.Matrix.EventId.generate(event_map))
       |> Map.put("signatures", %{"nebu" => Base.encode64(signature)})}
    end
  end

  # D3: the write of a membership change, ONE transaction of the db module (`apply_member_change/4`). A db module without it is
  # refused (`:unsupported_db_module`), NEVER served by separate statements; a failure is value-free logged (room id and error
  # class) and changes nothing: `:write_failed` (`:duplicate_event` for a unique violation of the event id).
  defp commit_member_change(room_id, user_id, signed, opts) do
    mod = db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :apply_member_change, 4) do
      case guarded_read(fn -> mod.apply_member_change(room_id, user_id, signed, opts) end) do
        :ok ->
          :ok

        {:error, refusal} when refusal in [:invitation_gone, :room_archived] ->
          {:error, refusal}

        other ->
          reason = with {:error, reason} <- other, do: reason
          Logger.error("room #{room_id}: the membership change was rolled back (#{db_error_class(reason)})")
          {:error, if(unique_violation?(reason), do: :duplicate_event, else: :write_failed)}
      end
    else
      Logger.error("room #{room_id}: the db module has no apply_member_change/4, the membership change is refused")
      {:error, :unsupported_db_module}
    end
  end

  defp unique_violation?(%Postgrex.Error{postgres: %{pg_code: "23505"}}), do: true
  defp unique_violation?(_reason), do: false

  # the class of a failure for a log line, never the reason itself (a database error can carry a snippet of the content)
  defp db_error_class(%Postgrex.Error{postgres: %{pg_code: code}}), do: "postgres #{code}"
  defp db_error_class(%{__struct__: module}), do: inspect(module)
  defp db_error_class(reason) when is_atom(reason), do: inspect(reason)
  defp db_error_class(_reason), do: "unknown"

  # cluster-safety: the subscribers of the room and the long-poll tasks of a user may run on another node
  defp broadcast_room(room_id, signed), do: Enum.each(:pg.get_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
  defp wake_user(user_id, message), do: Enum.each(:pg.get_members("user:#{user_id}"), &send(&1, message))

  defp drop_member(state, user_id) do
    %{state | members: MapSet.delete(state.members, user_id), member_identity: Map.delete(state.member_identity, user_id)}
  end

  # The self-authored member event of a join / leave of this process (non-fatal: if the write fails, the membership is still
  # applied, we log and continue). Called after successful join/leave DB operations so that incremental sync
  # (GetSyncDelta: the partition and the room's position range) can detect the membership change.
  #
  # Bugfix sync-state-events-missing-fields (AC2): returns `{event_id, origin_server_ts}` on success (nil on failure) so the caller
  # can capture the real identity into member_identity — /sync threads this into m.room.member state.events entries instead of
  # synthesizing fake values.
  #
  # Story member-event-prev-content (D4): `latest` is the user's latest member event in this room (nil when unknown); the event is
  # stamped after it (`stamp/2`), so the slot order of the member events stays strict.
  defp emit_membership_event(room_id, user_id, membership, latest) do
    with {:ok, signed} <- member_event(room_id, user_id, user_id, %{"membership" => membership}, stamp(latest, 0)),
         :ok <- db_module().insert_event(signed) do
      # Broadcast to :pg subscribers so long-poll sync wakes up immediately.
      # Mirrors send_event broadcast — prevents a sync delay of up to the long-poll timeout (25 s) after join/leave. Cluster-wide (story sync-wakeups-cluster-wide).
      broadcast_room(room_id, signed)
      {signed["event_id"], signed["origin_server_ts"]}
    else
      {:error, reason} ->
        # Non-fatal: membership already applied; log but don't roll back.
        Logger.warning("room #{room_id}: the #{membership} event could not be written (#{db_error_class(reason)})")
        nil
    end
  end

  # ─── the ONE power-level writer (story power-levels-enforcement, D1, D2, D10) ──────────────────────────────────────
  #
  # Every m.room.power_levels event and every write of the rooms.power_levels_json column is decided and written HERE, on the
  # levels of this process (`state.power_levels`: the RAW stored content, what /sync delivers and what the change rules compare;
  # every check reads it through the normalised view of PowerLevels). Because kick / ban / unban, the invite event and
  # send_event run in the same process, every decision sees the levels of every change committed before it. The write is ONE
  # transaction (`apply_power_levels_change/3` of the db module); the in-memory levels, the identity and the broadcast follow
  # the commit only. Never call this process from inside one of these calls (a db hook that does would deadlock).

  @levels_type "m.room.power_levels"

  # The decision, first failure wins: `{:write, latest}` (the identity the stamp follows), `{:noop, event_id}` or `{:error, _}`.
  #
  # :internal (createRoom step 3, the upgrade's initial levels, test seeds; never a client request): the bootstrap (ANY caller
  # while the levels are %{}), else the level of the levels event; no membership check, NO change rules.
  defp power_levels_decision(state, :internal, sender, content) do
    if state.power_levels == %{} or PowerLevels.can?(state.power_levels, sender, {:state, @levels_type}) do
      with :ok <- power_levels_shape(content, users_keys: :grammar),
           {:ok, latest} <- latest_power_levels(state) do
        {:write, latest}
      end
    else
      {:error, :forbidden}
    end
  end

  # :client (D2): membership, level, shape, the v10 change rules (none only without a previous levels event AND without stored
  # levels: v10 rule 4), then the
  # idempotent no-op for identical content (checked last, Oracle Q2)
  defp power_levels_decision(state, :client, sender, content) do
    levels = state.power_levels

    cond do
      not MapSet.member?(state.members, sender) ->
        {:error, :sender_not_joined}

      not PowerLevels.can?(levels, sender, {:state, @levels_type}) ->
        {:error, :insufficient_level}

      true ->
        # fix cycle 2 (Kassandra D-L1): an UNCHANGED stored `users` entry of a relaxed-grammar id (a creator with a port or a
        # long id) does not refuse a full-content PUT; added / changed keys stay strict
        with :ok <- power_levels_shape(content, stored_users: levels["users"]),
             {:ok, latest} <- latest_power_levels(state),
             :ok <- power_levels_change_rules(levels, content, sender, latest) do
          # the no-op compares STRICTLY (fix cycle 3, Kassandra C2-L1: 100.0 is not 100 at any depth)
          case latest do
            {event_id, _ts, _sender} -> if PowerLevels.same_json?(content, levels), do: {:noop, event_id}, else: {:write, latest}
            _other -> {:write, latest}
          end
        end
    end
  end

  # :client is strict (except unchanged stored entries, `stored_users`); :internal accepts the relaxed user-id grammar for its
  # server-chosen ids (review M4)
  defp power_levels_shape(content, opts) do
    case PowerLevels.validate_content(content, opts) do
      :ok -> :ok
      {:error, text} -> {:error, {:invalid, text}}
    end
  end

  # v10 rule 4 (no previous levels event: every content that passed the shape is allowed) only when there are no stored levels
  # either (review cycle 0 M1 / Kassandra L-2): a room whose column holds levels but whose event row is missing (an emit failure of
  # the former non-transactional writer) keeps the change rules; unreachable through the route today (empty levels deny, D4 (c))
  defp power_levels_change_rules(levels, _content, _sender, nil) when levels == %{}, do: :ok
  defp power_levels_change_rules(levels, content, sender, _latest), do: PowerLevels.check_change(levels, content, sender)

  # The identity `{event_id, origin_server_ts, sender}` of the latest levels event: the in-memory one, else ONE read through the
  # db module (`{:ok, nil}`: there is none). A db module without the read cannot tell (`:unknown`: the change rules apply, the
  # stamp has no floor); a failing read fails closed (`:write_failed`, nothing is written).
  defp latest_power_levels(%{power_levels_event: {event_id, ts, sender}}), do: {:ok, {event_id, ts, sender}}

  defp latest_power_levels(state) do
    mod = db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :latest_power_levels_identity, 1) do
      case guarded_read(fn -> mod.latest_power_levels_identity(state.room_id) end) do
        {:ok, {event_id, ts, sender}} when is_binary(event_id) and is_integer(ts) -> {:ok, {event_id, ts, sender}}
        {:ok, nil} -> {:ok, nil}
        _other ->
          Logger.error("room #{state.room_id}: failed to read the latest power-level event, the change is refused")
          {:error, :write_failed}
      end
    else
      {:ok, :unknown}
    end
  end

  # D1: stamped max(now, not_before, latest levels ts + 1), size-checked and signed, then ONE transaction; the state follows
  defp write_power_levels(state, sender, content, latest, not_before) do
    room_id = state.room_id

    after_latest =
      case latest do
        {_event_id, ts, _sender} when is_integer(ts) -> ts + 1
        _none_or_unknown -> 0
      end

    ts = Enum.max([Nebu.DB.Helpers.now_ms(), not_before, after_latest])

    with {:ok, signed} <- signed_state_event(room_id, @levels_type, sender, "", content, ts),
         :ok <- commit_power_levels(room_id, content, signed) do
      broadcast_room(room_id, signed)
      event_id = signed["event_id"]
      outcome = %{changed: true, previous: state.power_levels, ts: ts}
      {:reply, {:ok, event_id, outcome}, %{state | power_levels: content, power_levels_event: {event_id, ts, sender}}}
    else
      {:error, _reason} = failure -> {:reply, failure, state}
    end
  end

  # D10: the write of a power-level change, ONE transaction of the db module (`apply_power_levels_change/3`: the column AND the
  # event). A db module without it is refused (`:unsupported_db_module`), NEVER served by separate statements; a failure is
  # value-free logged (room id and error class) and changes nothing: `:write_failed` (`:room_archived` for an archived room).
  defp commit_power_levels(room_id, content, signed) do
    mod = db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :apply_power_levels_change, 3) do
      case guarded_read(fn -> mod.apply_power_levels_change(room_id, Jason.encode!(content), signed) end) do
        :ok ->
          :ok

        {:error, :room_archived} ->
          {:error, :room_archived}

        other ->
          reason = with {:error, reason} <- other, do: reason
          Logger.error("room #{room_id}: the power-level change was rolled back (#{db_error_class(reason)})")
          {:error, :write_failed}
      end
    else
      Logger.error("room #{room_id}: the db module has no apply_power_levels_change/3, the power-level change is refused")
      {:error, :unsupported_db_module}
    end
  end

  # ─── the ONE redaction writer and the ONE generic state writer (story state-writer-redaction, D1, D2, D8, D9) ───────────

  # D2, first failure wins: membership and the level of the redaction event need no read; the idempotency lookup comes AFTER them
  # (a retry after a kick / demotion is refused: authorisation is always re-evaluated), BEFORE the target (a committed redaction is
  # answered with its id even when the target rule would now refuse); the target before `redact` (own event needs its sender)
  defp decide_and_write_redaction(state, sender, target_id, content, txn_key) do
    room_id = state.room_id
    levels = state.power_levels

    cond do
      not MapSet.member?(state.members, sender) ->
        {:error, :sender_not_joined}

      not PowerLevels.can?(levels, sender, {:message, "m.room.redaction"}) ->
        {:error, :forbidden}

      true ->
        case :ets.lookup(:NebuTxnDedup, txn_key) do
          [{_key, existing_event_id}] ->
            {:ok, existing_event_id, %{replayed: true, target_sender: nil}}

          [] ->
            with {:ok, target} <- redaction_target(room_id, target_id),
                 :ok <- redact_level(levels, sender, target),
                 {:ok, nil} <- existing_redaction(room_id, target_id) do
              write_redaction(state, sender, target, content, txn_key)
            else
              # security cycle 1 (Kassandra #1): an already redacted target is answered with its EXISTING earliest redaction: no row,
              # no ETS entry, no broadcast, no audit (replayed); at most one writer-made redaction per target is ever written
              {:ok, existing_id} when is_binary(existing_id) -> {:ok, existing_id, %{replayed: true, target_sender: nil}}
              {:error, _reason} = refusal -> refusal
            end
        end
    end
  end

  # D2 (4), D4: ONE read of the target in THIS room; only a message event can be redacted (a state event changes the room state, a
  # redacted redaction would lose its `redacts`: Nebu restriction, follow-up `ga`); a failing read fails closed
  defp redaction_target(room_id, target_id) do
    mod = db_module()

    case guarded_read(fn -> mod.fetch_event(target_id, room_id) end) do
      {:ok, %{"state_key" => nil, "event_type" => type} = target} when type != "m.room.redaction" -> {:ok, target}
      {:ok, _state_event_or_redaction} -> {:error, :not_redactable}
      {:error, :not_found} -> {:error, :target_not_found}

      _other ->
        Logger.error("room #{room_id}: the redaction target could not be read, the redaction is refused")
        {:error, :write_failed}
    end
  end

  # the event id of the earliest writer-made redaction of the target (`{:ok, nil}`: none; a legacy unchecked row never counts:
  # `redactions_for/1` returns writer-made rows only); a failing read fails closed, a db module without it is refused
  defp existing_redaction(room_id, target_id) do
    mod = db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :redactions_for, 1) do
      case guarded_read(fn -> mod.redactions_for([target_id]) end) do
        {:ok, rows} when is_list(rows) ->
          {:ok, Enum.find_value(rows, fn row -> if row["redacts"] == target_id, do: row["event_id"] end)}

        _other ->
          Logger.error("room #{room_id}: the redactions of the target could not be read, the redaction is refused")
          {:error, :write_failed}
      end
    else
      Logger.error("room #{room_id}: the db module has no redactions_for/1, the redaction is refused")
      {:error, :unsupported_db_module}
    end
  end

  defp redact_level(levels, sender, target) do
    if target["sender"] == sender or PowerLevels.can?(levels, sender, :redact), do: :ok, else: {:error, :insufficient_redact_level}
  end

  defp write_redaction(state, sender, target, content, txn_key) do
    room_id = state.room_id
    ts = Nebu.DB.Helpers.now_ms()

    # every room of this server has the one supported version (`RoomVersions.default/0`: createRoom and upgrade accept no other)
    with {:ok, event_map} <- redaction_event(Nebu.Matrix.RoomVersions.default(), room_id, sender, target["event_id"], content, ts),
         {:ok, signed} <- signed_event(event_map),
         :ok <- commit_atomic(room_id, :apply_redaction, [room_id, signed], "the redaction") do
      event_id = signed["event_id"]
      :ets.insert(:NebuTxnDedup, {txn_key, event_id})
      broadcast_room(room_id, signed)
      {:ok, event_id, %{replayed: false, target_sender: target["sender"]}}
    end
  end

  # D9: the write of a redaction / a state change, ONE transaction of the db module (`apply_redaction/2`, `apply_state_change/3`:
  # the archived check and the event, for `m.room.name` also `rooms.name`). A db module without it is refused
  # (`:unsupported_db_module`), NEVER a fallback to insert_event/1; a failure is value-free logged (room id and error class) and
  # changes nothing: `:write_failed` (`:room_archived` for an archived room).
  defp commit_atomic(room_id, fun, args, label) do
    mod = db_module()
    arity = length(args)

    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity) do
      case guarded_read(fn -> apply(mod, fun, args) end) do
        :ok ->
          :ok

        {:error, :room_archived} ->
          {:error, :room_archived}

        other ->
          reason = with {:error, reason} <- other, do: reason
          Logger.error("room #{room_id}: #{label} was rolled back (#{db_error_class(reason)})")
          {:error, :write_failed}
      end
    else
      Logger.error("room #{room_id}: the db module has no #{fun}/#{arity}, #{label} is refused")
      {:error, :unsupported_db_module}
    end
  end

  # D8: membership, the level (`:client`: events[type] else state_default; `:tombstone`: D11), the v10 `@` rule; then the slot stamp
  # max(now, not_before, latest slot ts + 1) read from the database (no cache: also right after a restart) and ONE transaction. The
  # in-memory state is not changed (no cached state for these slots); the broadcast follows the commit.
  defp decide_and_write_state(state, sender, {type, state_key}, content, opts) do
    room_id = state.room_id
    mode = Keyword.get(opts, :mode, :client)

    cond do
      not MapSet.member?(state.members, sender) ->
        {:error, :sender_not_joined}

      not state_level_ok?(state.power_levels, sender, type, mode) ->
        {:error, :insufficient_level}

      String.starts_with?(state_key, "@") and state_key != sender ->
        {:error, :foreign_user_key}

      true ->
        with :ok <- check_hv_cap(room_id, type, state_key, content),
             {:ok, latest} <- latest_slot(room_id, type, state_key),
             ts = Enum.max([Nebu.DB.Helpers.now_ms(), Keyword.get(opts, :not_before, 0), slot_floor(latest)]),
             {:ok, signed} <- signed_state_event(room_id, type, sender, state_key, content, ts),
             :ok <- commit_atomic(room_id, :apply_state_change, [room_id, signed, state_write_opts(type, state_key, content)], "the state change") do
          broadcast_room(room_id, signed)
          {:ok, signed["event_id"]}
        end
    end
  end

  # Story history-visibility-enforcement (security cycle 1, HIGH #1 (a); security cycle 2, N1): every member's reads compute the
  # visibility from the room's `m.room.history_visibility` state events, so their number is capped per room (default 256,
  # `:nebu, :hv_event_cap`): a write at or above the cap is refused (`:hv_event_cap`, nothing written) UNLESS it is STRICTLY MORE
  # RESTRICTIVE than the current setting (world_readable < shared < invited < joined; a stored unknown value reads as `shared`):
  # the cap never blocks tightening, so a room can never be frozen at a weaker value; above the cap at most 3 more rows can be
  # added (each one tighter than the last). The count (and, only at the cap, the current value) is read in this process right
  # before the write (the writers of the slot are serialised here: no race). A failing read refuses the write (fail closed,
  # value-free log). Not counted: the createRoom chain (the preset event plus at most 64 `initial_state` entries, written before
  # the room is reachable).
  @hv_type "m.room.history_visibility"
  @hv_rank %{"world_readable" => 0, "shared" => 1, "invited" => 2, "joined" => 3}

  defp check_hv_cap(room_id, @hv_type, "", content) do
    mod = db_module()
    cap = Application.get_env(:nebu, :hv_event_cap, 256)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :count_state_events, 3) and function_exported?(mod, :current_history_visibility, 1) do
      case guarded_read(fn -> mod.count_state_events(room_id, @hv_type, "") end) do
        {:ok, count} when is_integer(count) and count < cap ->
          :ok

        {:ok, count} when is_integer(count) ->
          tightening_above_cap(mod, room_id, content, count, cap)

        _other ->
          Logger.error("room #{room_id}: failed to count the history visibility events, the state change is refused")
          {:error, :write_failed}
      end
    else
      Logger.error("room #{room_id}: the db module cannot count the history visibility events, the change is refused")
      {:error, :unsupported_db_module}
    end
  end

  defp check_hv_cap(_room_id, _type, _state_key, _content), do: :ok

  defp tightening_above_cap(mod, room_id, content, count, cap) do
    case guarded_read(fn -> mod.current_history_visibility(room_id) end) do
      {:ok, current} when is_binary(current) ->
        new_rank = Map.get(@hv_rank, content["history_visibility"], -1)

        if new_rank > Map.get(@hv_rank, current, 1) do
          :ok
        else
          Logger.warning("room #{room_id}: the history visibility change is refused, the room has #{count} of at most #{cap}")
          {:error, :hv_event_cap}
        end

      _other ->
        Logger.error("room #{room_id}: failed to read the current history visibility, the state change is refused")
        {:error, :write_failed}
    end
  end

  defp state_level_ok?(levels, sender, type, :client), do: PowerLevels.can?(levels, sender, {:state, type})

  # D11: the tombstone of an upgrade needs the tombstone level with the floor of 100 (`PowerLevels.upgrade_level/1`)
  defp state_level_ok?(levels, sender, _type, :tombstone), do: PowerLevels.get_user_level(levels, sender) >= PowerLevels.upgrade_level(levels)

  defp slot_floor({_event_id, ts, _sender}) when is_integer(ts), do: ts + 1
  defp slot_floor(_none), do: 0

  defp latest_slot(room_id, type, state_key) do
    mod = db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :latest_state_identity, 3) do
      case guarded_read(fn -> mod.latest_state_identity(room_id, type, state_key) end) do
        {:ok, {_event_id, ts, _sender} = identity} when is_integer(ts) -> {:ok, identity}
        {:ok, nil} -> {:ok, nil}

        _other ->
          Logger.error("room #{room_id}: failed to read the latest event of the state slot, the state change is refused")
          {:error, :write_failed}
      end
    else
      Logger.error("room #{room_id}: the db module has no latest_state_identity/3, the state change is refused")
      {:error, :unsupported_db_module}
    end
  end

  # `rooms.name` follows an `m.room.name` event with the EMPTY state key only, in the same transaction
  defp state_write_opts("m.room.name", "", content), do: [room_name: if(is_binary(content["name"]), do: content["name"], else: "")]
  defp state_write_opts(_type, _state_key, _content), do: []

  # Stores `identity` (an {event_id, origin_server_ts} tuple) for `user_id` in
  # `map`, or leaves `map` unchanged when `identity` is `nil` (emit failed —
  # non-fatal, matches emit_membership_event/4's fail-open philosophy).
  defp put_identity(map, _user_id, nil), do: map
  defp put_identity(map, user_id, identity), do: Map.put(map, user_id, identity)

  @doc """
  The `NebuTxnDedup` key of a `PUT /send/{eventType}/{txnId}` (story state-writer-redaction, D7, Kassandra #5): `{room_id, user_id,
  {:send, event_type, txn_id}}`, so the same txn id on two event types (two HTTP paths) is two requests. Still per user and
  node-local (follow-up `bd`). The `/redact` key is `{room_id, user_id, {:redact, event_id, txn_id}}`.
  """
  @spec send_txn_key(String.t(), String.t(), String.t(), String.t()) :: tuple()
  def send_txn_key(room_id, user_id, event_type, txn_id), do: {room_id, user_id, {:send, event_type, txn_id}}

  # Steps 1 and 1.5 of send_event, for a sender that passed the membership and level checks: the idempotency lookup, then the
  # archived-status check.
  defp send_authorised_event(room_id, user_id, event_type, content, txn_id, state_key, state) do
    # Step 1 — Idempotency check: return existing event_id immediately if found (the key carries the event type: a txn id is
    # scoped to its HTTP path, story state-writer-redaction D7 / Kassandra #5).
    case :ets.lookup(:NebuTxnDedup, send_txn_key(room_id, user_id, event_type, txn_id)) do
      [{_, existing_event_id}] ->
        {:reply, {:ok, existing_event_id}, state}

      [] ->
        # Step 1.5 — Archived-status check (TOCTOU fix, Story 9-9).
        # SELECT FOR UPDATE serialises this check with archive_room_atomic/1.
        # Fail-open for {:error, :not_found} — let Core return its existing NOT_FOUND guard.
        # Fail-open for DB errors (log + proceed) — same philosophy as init/1 fail-open.
        case db_module().check_room_status_for_update(room_id) do
          {:ok, "archived"} ->
            {:reply, {:error, :room_archived}, state}

          {:error, reason} ->
            # Fail-open: DB error on status check — log and proceed.
            # Same philosophy as init/1 fail-open: don't block active rooms on a transient DB error.
            Logger.warning("check_room_status_for_update failed for #{room_id} (#{db_error_class(reason)}) — proceeding (fail-open)")
            do_send_event(room_id, user_id, event_type, content, txn_id, state_key, state)

          _ ->
            do_send_event(room_id, user_id, event_type, content, txn_id, state_key, state)
        end
    end
  end

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

    # Story event-size-limit (D5 backstop): the SIGNED canonical bytes decide, before anything is persisted, remembered or
    # broadcast: no `events` row, no txn-dedup entry (a retry of this txn id is processed afresh, never answered with a cached id).
    case Nebu.Matrix.EventSize.check_stored(event_json) do
      {:error, :event_too_large} ->
        {:reply, {:error, :event_too_large}, state}

      :ok ->
        sign_and_persist_event(event_with_id, event_json, priv, user_id, txn_id, state)
    end
  end

  # The signature and steps 5-6 of send_event, for an event within the size limit.
  defp sign_and_persist_event(%{"event_id" => event_id} = event_with_id, event_json, priv, user_id, txn_id, state) do
    room_id = state.room_id
    signature = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
    sig_b64 = Base.encode64(signature)
    signed_event = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

    # Step 5 — Persist to DB (append-only).
    case db_module().insert_event(signed_event) do
      :ok ->
        # Step 6 — Only on DB success: update ETS, broadcast, return ok.
        # TODO(Story 4-X): Add TTL-based pruning for NebuTxnDedup entries.
        # Currently entries grow unbounded over the lifetime of the VM.
        :ets.insert(:NebuTxnDedup, {send_txn_key(room_id, user_id, event_with_id["type"], txn_id), event_id})

        # Broadcast to all processes subscribed to this room's :pg group.
        # Fire-and-forget: no subscribers is a no-op (correct for MVP). Cluster-wide (story sync-wakeups-cluster-wide).
        broadcast_room(room_id, signed_event)

        {:reply, {:ok, event_id}, state}

      {:error, reason} ->
        # AC #3: On DB failure — do NOT insert ETS, do NOT broadcast.
        {:reply, {:error, reason}, state}
    end
  end
end
