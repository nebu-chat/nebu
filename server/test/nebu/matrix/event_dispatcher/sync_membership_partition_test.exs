defmodule Nebu.Matrix.EventDispatcher.SyncMembershipPartitionTest do
  @moduledoc """
  Story `sync-membership-partition` (epic oauth-broker, follow-ups `ev` + `ez`), unit part (the orchestration of the core, no PostgreSQL
  needed for the world; the rooms are real `Room.Server` processes like in `sync_test.exs`): the partition of `get_initial_sync/2` /
  `get_sync_delta/2` into `rooms` (joined rooms with events) + `join_room_ids` (the whole join class) + `invite_rooms` + `leave_rooms`, the
  classification table (AC6), the stripped `invite_state` (D4), newness and the anchor (D5), the leave window (D6), the wake rules (AC7),
  fail closed (D10). The SQL half of every rule (tie order, JSONB forms, window bounds, candidate union) is pinned on the REAL database by
  `room/membership_partition_db_test.exs`; the HTTP half (wire shape, ignored users, `full_state`, 503 body, createRoom, join decision) by
  `sync_membership_partition_http_test.exs`.

  ## The seams (names the story leaves open, PINNED here and in `room/membership_partition_db_test.exs`)

  The sync reaches the four new reads through `rooms_db_module()` (they are NOT in `DBBehaviour`): `membership_candidates/1`,
  `latest_member_events/2`, `invite_state_events/1`, `leave_window_events/3` with the shapes documented in the DB test. The response
  structs carry (proto-shaped, hand-edited, `content` a JSON string like the other structs):

      Core.GetInitialSyncResponse / Core.GetSyncDeltaResponse:
        rooms:          [%Core.SyncRoom{}]            the DELIVERED join rooms (every existing reader keeps working)
        join_room_ids:  [room_id]                     the WHOLE join class, delivered or not (account-data-only rooms, full_state)
        invite_rooms:   [%Core.SyncInviteRoom{room_id, invite_state: [%Core.StrippedStateEvent{type, state_key, sender, content}]}]
        leave_rooms:    [%Core.SyncRoom{}]            state_events [], timeline = the leave window

  The ignored-user list (D8) is covered at HTTP level only (the real `AccountDataStore` needs a Repo); this suite runs the partition with
  "no ignore list". The new struct fields are read through `field/2` (a missing key is a readable assertion failure, not a compile abort);
  no `%Core.SyncInviteRoom{}` literal appears.

  ## How the world is modelled (the fakes model the real thing)

  `FakeDB` keeps ROWS (`room_members`, `room_invitations`, `forgotten_rooms`) and EVENTS like the real tables: a join through
  `Room.Server.join/2` writes its own join event and its row, an invite writes a row AND an event (unless the test says row-only), a decline
  rejects the row and writes a leave event authored by the invitee, a kick / ban removes the member and writes the event authored by the
  moderator, a self-leave writes a leave event. Every event is stamped by an INSERTION COUNTER (never a clock, never a tie): order is
  deterministic. Timestamp ties are produced deliberately with explicit `ts:` options (the tie ORDER itself is the DB test's job; the fake
  implements the documented contract). The pg store keeps the stored token like the real one and records every persist call, so a test
  walks `get_initial_sync/2` -> `get_sync_delta/2` with the token that was really issued.

  `async: false`: Horde, `:pg`, `Application.put_env` and ETS are process-global. Waits are bounded polls / `assert_receive`, never fixed sleeps.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Http

  @ets :smp_unit_db

  # ─── FakeDB ──────────────────────────────────────────────────────────────────

  defmodule FakeDB do
    @ets :smp_unit_db
    @base_ts 1_700_000_000_000
    @step 10
    @rank %{"ban" => 0, "leave" => 1, "invite" => 2, "knock" => 3, "join" => 4}
    @six ~w(m.room.name m.room.avatar m.room.topic m.room.canonical_alias m.room.join_rules m.room.encryption)

    # ── the insertion counter ──
    def next_ts, do: :ets.update_counter(@ets, :ts, @step, {:ts, @base_ts})
    def next_id(prefix \\ "ev"), do: "$#{prefix}#{:ets.update_counter(@ets, :seq, 1, {:seq, 0})}:test.local"

    # every write that goes through here is an `events` row; `__ts` forces a timestamp (a deliberate tie / fixed time)
    def write_event(map) do
      {fixed, map} = Map.pop(map, "__ts")
      ts = fixed || next_ts()
      type = map["type"] || map["event_type"]
      id = map["event_id"] || next_id()

      stored = %{
        "event_id" => id,
        "room_id" => map["room_id"],
        "sender" => map["sender"],
        "event_type" => type,
        "content" => map["content"] || %{},
        "origin_server_ts" => ts,
        "state_key" => Map.get(map, "state_key"),
        # story sync-stream-position (DELIBERATE amendment): every event row carries the per-room insertion position the trigger of story events-room-position stamps
        "room_pos" => :ets.update_counter(@ets, {:room_pos, map["room_id"]}, 1, {{:room_pos, map["room_id"]}, 0})
      }

      :ets.insert(@ets, {{:event, id}, stored})
      stored
    end

    def events(room_id) do
      :ets.match(@ets, {{:event, :_}, :"$1"}) |> List.flatten() |> Enum.filter(&(&1["room_id"] == room_id))
    end

    defp all_events, do: :ets.match(@ets, {{:event, :_}, :"$1"}) |> List.flatten()

    # ── switches ──
    defp failing?(read), do: :ets.lookup(@ets, {:fail, read}) != []

    # ── Room.Server / existing reads ──
    # story sync-wakeups-cluster-wide D5: `{:init_fail, room}` makes the (re)start of a room process fail transiently (a failing read in init/1)
    def load_members(room_id) do
      if :ets.lookup(@ets, {:init_fail, room_id}) != [], do: {:error, :db_down}, else: load_members_of(room_id)
    end

    defp load_members_of(room_id) do
      case :ets.lookup(@ets, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created}] ->
          active = :ets.match(@ets, {{:member_row, room_id, :"$1"}, :active}) |> List.flatten()
          {:ok, active, created, "{}"}
      end
    end

    def insert_room(room_id) do
      now = next_ts()
      :ets.insert(@ets, {{:room, room_id}, now})
      {:ok, now}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(@ets, {{:member_row, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      case :ets.lookup(@ets, {:member_row, room_id, user_id}) do
        [{_, :active}] ->
          :ets.insert(@ets, {{:member_row, room_id, user_id}, :left})
          :ok

        _ ->
          {:error, :not_member}
      end
    end

    def insert_event(event) do
      write_event(event)
      :ok
    end

    # Story moderation-routes-atomic-ban (AC16 (b), DATA adaptation of the fake): kick / ban / unban, the invite event and the decline are
    # written by the room process in the ONE transaction of Room.DB.apply_member_change/4: the member row is closed (`remove_member`; a
    # user without an active row is no error), the pending invitation rejected through FakeInviteDB (whose reject is a no-op in this
    # suite, as before) and the event stored (insert_event/1). `{:fail, :apply_member_change}` makes the whole change fail.
    def apply_member_change(room_id, user_id, event, opts) do
      if failing?(:apply_member_change) do
        {:error, :simulated}
      else
        if Keyword.get(opts, :remove_member, false), do: _ = delete_member(room_id, user_id)
        if Keyword.get(opts, :reject_invitation, false), do: :ok = Nebu.Matrix.EventDispatcher.SyncMembershipPartitionTest.FakeInviteDB.reject_invitation(room_id, user_id)
        if is_map(event), do: :ok = insert_event(event)
        :ok
      end
    end

    # story moderation-routes-atomic-ban (D2 (4)): the pending invitation through the room db module, like Room.DB (delegates to the invite store)
    def pending_invitation(room_id, user_id), do: Nebu.Matrix.EventDispatcher.SyncMembershipPartitionTest.FakeInviteDB.pending_invitation(room_id, user_id)

    def set_power_levels(_room_id, _json), do: :ok
    def load_room_settings(_room_id), do: {:ok, 0}
    # D5: `{:archived, room}` = an archived room (an upgraded room: its process cannot start), `{:status_missing, room}` = no `rooms` row
    def get_room_status(room_id) do
      cond do
        :ets.lookup(@ets, {:archived, room_id}) != [] -> {:ok, "archived"}
        :ets.lookup(@ets, {:status_missing, room_id}) != [] -> {:error, :not_found}
        true -> {:ok, "active"}
      end
    end
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: true
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def list_auto_join_rooms, do: {:ok, []}

    def get_rooms_for_user(user_id) do
      {:ok, :ets.match(@ets, {{:member_row, :"$1", user_id}, :active}) |> List.flatten()}
    end

    def get_recently_left_rooms_for_user(user_id) do
      {:ok, :ets.match(@ets, {{:member_row, :"$1", user_id}, :left}) |> List.flatten()}
    end

    def get_forgotten_room_ids(user_id) do
      {:ok, :ets.match(@ets, {{:forgotten, user_id, :"$1"}, true}) |> List.flatten()}
    end

    def get_event_timestamp(event_id) do
      if failing?(:get_event_timestamp) do
        {:error, :simulated}
      else
        case :ets.lookup(@ets, {:event, event_id}) do
          [{_, ev}] -> {:ok, ev["origin_server_ts"]}
          [] -> {:error, :not_found}
        end
      end
    end

    def fetch_event(event_id, room_id) do
      case :ets.lookup(@ets, {:event, event_id}) do
        [{_, ev}] -> if ev["room_id"] == room_id, do: {:ok, ev}, else: {:error, :not_found}
        [] -> {:error, :not_found}
      end
    end

    def fetch_events(room_id, _direction, limit, _from) do
      events =
        room_id
        |> events()
        |> Enum.sort_by(&{&1["origin_server_ts"], &1["event_id"]}, :desc)
        |> Enum.take(limit)

      {:ok, events, "", if(length(events) >= limit, do: List.last(events)["event_id"], else: "")}
    end

    def fetch_events_since(room_id, last_event_id, limit) do
      # review cycle 1: a join-room fetch that blows up INSIDE the sync Task (not a Nebu.Matrix.Error): raise / throw / exit
      case :ets.lookup(@ets, {:blow_up, :fetch_events_since}) do
        [{_, :raise}] -> raise "simulated fetch failure"
        [{_, :throw}] -> throw(:simulated_throw)
        [{_, :exit}] -> exit(:simulated_exit)
        [] -> :ok
      end

      since =
        case last_event_id do
          id when id in [nil, ""] -> 0
          id -> with({:ok, ts} <- get_event_timestamp(id), do: ts, else: (_ -> 0))
        end

      result =
        {:ok,
         room_id
         |> events()
         |> Enum.filter(&(&1["origin_server_ts"] > since))
         |> Enum.sort_by(&{&1["origin_server_ts"], &1["event_id"]})
         |> Enum.take(limit)}

      # review cycle 2 (Kassandra N-1): `{:after_fetch_hook, fun}` runs ONCE, right after the FIRST join-room fetch answered (the
      # answer is the world before it): a removal that lands between the fetch of one room and the fetch of the next. `fun.(room_id)`.
      case :ets.take(@ets, :after_fetch_hook) do
        [{_, fun}] -> fun.(room_id)
        [] -> :ok
      end

      result
    end

    # ── story sync-stream-position (DELIBERATE amendment, old -> new): the delta reads by POSITION ──
    # `room_heads/3`: the head and the device's cursor of every room (the cursors live in the fake pg store's table); `fetch_visible_events_in_range/5` is the old
    # `fetch_events_since/3` over `(base, head]` (its blow-up switch and the once-only after-fetch hook of review cycles 1 / 2 move here unchanged: they are keyed
    # `:fetch_events_since` in the ETS of the tests that arm them, a name the tests keep).
    def room_heads(room_ids, user_id, device_id) do
      if failing?(:room_heads) do
        {:error, :simulated}
      else
        Nebu.Matrix.SyncPositionsFake.room_heads(&events/1, &Nebu.Matrix.SyncPositionsFake.Store.cursor(@ets, user_id, device_id, &1), room_ids)
      end
    end

    def fetch_visible_events_in_range(room_id, _viewer, after_pos, head, limit) do
      case :ets.lookup(@ets, {:blow_up, :fetch_events_since}) do
        [{_, :raise}] -> raise "simulated fetch failure"
        [{_, :throw}] -> throw(:simulated_throw)
        [{_, :exit}] -> exit(:simulated_exit)
        [] -> :ok
      end

      result = {:ok, Nebu.Matrix.SyncPositionsFake.in_range(events(room_id), after_pos, head, limit)}

      case :ets.take(@ets, :after_fetch_hook) do
        [{_, fun}] -> fun.(room_id)
        [] -> :ok
      end

      result
    end

    def get_room_name(room_id) do
      named =
        room_id |> events() |> Enum.filter(&(&1["event_type"] == "m.room.name")) |> Enum.sort_by(& &1["origin_server_ts"], :desc)

      case named do
        [ev | _] -> {:ok, ev["content"]["name"], ev["event_id"], ev["origin_server_ts"], ev["sender"]}
        [] -> {:error, :not_found}
      end
    end

    def get_room_create_event(room_id) do
      creates = room_id |> events() |> Enum.filter(&(&1["event_type"] == "m.room.create")) |> Enum.sort_by(& &1["origin_server_ts"])

      case creates do
        [ev | _] -> {:ok, ev["content"], ev["event_id"], ev["origin_server_ts"]}
        [] -> {:error, :not_found}
      end
    end

    # `{:legacy_creator, room}` makes get_room_creator answer for a room WITHOUT a create event (the migrated legacy rooms)
    def get_room_creator(room_id) do
      case room_id |> events() |> Enum.filter(&(&1["event_type"] == "m.room.create")) |> Enum.sort_by(& &1["origin_server_ts"]) do
        [ev | _] ->
          {:ok, ev["sender"]}

        [] ->
          case :ets.lookup(@ets, {:legacy_creator, room_id}) do
            [{_, creator}] -> {:ok, creator}
            [] -> {:error, :not_found}
          end
      end
    end

    # the latest membership of the user: the newest member event in the TIE ORDER of D3 (the contract, see the DB test)
    def get_member_membership(room_id, user_id) do
      case member_events_ordered([room_id], user_id) |> Map.get(room_id, []) do
        [%{membership: m} | _] -> {:ok, m}
        [] -> {:ok, nil}
      end
    end

    # ── the four NEW reads (pinned contract) ──
    # the end of the membership as the ROW knows it (review cycle 1, Kassandra M-1); a test sets it where it matters, the default
    # is nil (the module does not tell: the window ends at L)
    def set_left_at(room_id, user_id, ts), do: :ets.insert(@ets, {{:left_at, room_id, user_id}, ts})
    # the start of the (latest) membership as the ROW knows it (review cycle 2, Kassandra I-1); default nil
    def set_joined_at(room_id, user_id, ts), do: :ets.insert(@ets, {{:joined_at, room_id, user_id}, ts})

    defp joined_at(room_id, user_id) do
      case :ets.lookup(@ets, {:joined_at, room_id, user_id}) do
        [{_, ts}] -> ts
        [] -> nil
      end
    end

    defp left_at(room_id, user_id) do
      case :ets.lookup(@ets, {:left_at, room_id, user_id}) do
        [{_, ts}] -> ts
        [] -> nil
      end
    end

    # review cycle 1 (Kassandra L-1): `{:candidates_hook, fun}` runs AFTER a read of the candidates answered (the answer is the world
    # BEFORE the hook): a kick / ban that lands between the partition read and the fetch of the join rooms. `fun.(call_number)`.
    defp run_candidates_hook do
      n = :ets.update_counter(@ets, :candidates_calls, 1, {:candidates_calls, 0})

      case :ets.lookup(@ets, :candidates_hook) do
        [{_, fun}] -> fun.(n)
        [] -> :ok
      end
    end

    def membership_candidates(user_id) do
      if failing?(:membership_candidates) do
        {:error, :simulated}
      else
        members =
          for [room, state] <- :ets.match(@ets, {{:member_row, :"$1", user_id}, :"$2"}) do
            %{room_id: room, kind: :member, active: state == :active, pending: false, inviter_id: nil, invited_at: nil, left_at: left_at(room, user_id), joined_at: joined_at(room, user_id)}
          end

        invitations =
          for [room, row] <- :ets.match(@ets, {{:invitation, :"$1", user_id}, :"$2"}), row.state in [:pending, :rejected] do
            %{room_id: room, kind: :invitation, active: false, pending: row.state == :pending, inviter_id: row.inviter, invited_at: row.invited_at}
          end

        result = {:ok, members ++ invitations}
        run_candidates_hook()
        result
      end
    end

    def latest_member_events(room_ids, user_id) do
      if failing?(:latest_member_events) do
        {:error, :simulated}
      else
        {:ok, Nebu.Matrix.SyncPositionsFake.put_member_positions(member_events_ordered(room_ids, user_id), &events/1)}
      end
    end

    def invite_state_events(room_ids) do
      if failing?(:invite_state_events) do
        {:error, :simulated}
      else
        {:ok,
         Map.new(room_ids, fn room ->
           evs = events(room)
           create = evs |> Enum.filter(&(&1["event_type"] == "m.room.create")) |> Enum.sort_by(& &1["origin_server_ts"]) |> Enum.take(1)

           others =
             for type <- @six,
                 ev <- evs |> Enum.filter(&(&1["event_type"] == type and &1["state_key"] == "")) |> Enum.sort_by(&{&1["origin_server_ts"], &1["event_id"]}, :desc) |> Enum.take(1),
                 do: ev

           {room, Enum.map(create ++ others, &%{"type" => &1["event_type"], "state_key" => &1["state_key"], "sender" => &1["sender"], "content" => &1["content"]})}
         end)}
      end
    end

    # records every call (the bounds are what the story pins: strictly inside, never an event at or after L)
    # story sync-stream-position (DELIBERATE amendment, D10), old -> new: `leave_window_events(room, after_ts, before_ts)` is now `(room, after_pos, before_pos, after_ts,
    # before_ts)`: strictly between two POSITIONS and, as an extra restriction, two clocks; the newest 21 rows (the core keeps 20 and reads the 21st as `limited`).
    def leave_window_events(room_id, after_pos, before_pos, after_ts, before_ts) do
      :ets.insert(@ets, {{:window_call, :erlang.unique_integer([:monotonic])}, {room_id, after_pos, before_pos, after_ts, before_ts}})

      if failing?(:leave_window_events) do
        {:error, :simulated}
      else
        {:ok, Nebu.Matrix.SyncPositionsFake.leave_window(events(room_id), after_pos, before_pos, after_ts, before_ts)}
      end
    end

    def window_calls do
      :ets.match(@ets, {{:window_call, :"$1"}, :"$2"}) |> Enum.sort_by(&hd/1) |> Enum.map(&List.last/1)
    end

    def latest_member_event(room_id, user_id) do
      case member_events_ordered([room_id], user_id) |> Map.get(room_id, []) do
        [e | _] -> {:ok, %{event_id: e.event_id, membership: e.membership, origin_server_ts: e.origin_server_ts, sender: e.sender}}
        [] -> {:ok, nil}
      end
    end

    defp normalise("ban"), do: "ban"
    defp normalise("leave"), do: "leave"
    defp normalise("invite"), do: "invite"
    defp normalise("knock"), do: "knock"
    defp normalise("join"), do: "join"
    defp normalise(_), do: "leave"

    defp member_events_ordered(room_ids, user_id) do
      all_events()
      |> Enum.filter(&(&1["room_id"] in room_ids and &1["event_type"] == "m.room.member" and &1["state_key"] == user_id))
      |> Enum.map(fn ev ->
        m = normalise(get_in(ev, ["content", "membership"]))

        {ev["room_id"], %{event_id: ev["event_id"], origin_server_ts: ev["origin_server_ts"], sender: ev["sender"], membership: m, content: ev["content"]}}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {room, evs} ->
        sorted = Enum.sort_by(evs, &{-&1.origin_server_ts, @rank[&1.membership], inverse(&1.event_id)})
        {room, Enum.take(sorted, 2)}
      end)
    end

    # event_id DESC as the third key of an ascending sort: invert the binary
    defp inverse(id), do: id |> :binary.bin_to_list() |> Enum.map(&(255 - &1))
  end

  # the same fake WITHOUT the four new reads: a core that needs them must fail closed (D10), never read "no memberships"
  defmodule NoNewReadsDB do
    # story sync-stream-position (DELIBERATE amendment): leave_window_events/3 -> /5, and the position reads are new reads a core without them must fail closed on, too
    new = [membership_candidates: 1, latest_member_events: 2, invite_state_events: 1, leave_window_events: 5, latest_member_event: 2, room_heads: 3, fetch_visible_events_in_range: 5]

    for {name, arity} <- FakeDB.__info__(:functions), {name, arity} not in new do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(FakeDB, unquote(name), [unquote_splicing(args)])
    end
  end

  defmodule FakeInviteDB do
    @ets :smp_unit_db

    def insert_invitation(_room, _inviter, _invitee), do: :ok
    def accept_invitation(_room, _invitee), do: :ok
    def reject_invitation(_room, _invitee), do: :ok

    def get_pending_invite_rooms_for_user(user_id), do: {:ok, rooms(user_id, :pending)}
    def get_declined_invite_rooms_for_user(user_id), do: {:ok, rooms(user_id, :rejected)}
    def pending_invite?(room, user_id), do: {:ok, room in rooms(user_id, :pending)}

    def pending_invitation(room, user_id) do
      case :ets.lookup(@ets, {:invitation, room, user_id}) do
        [{_, %{state: :pending, invited_at: at}}] -> {:ok, at}
        _ -> {:ok, nil}
      end
    end

    defp rooms(user_id, state), do: for([room, row] <- :ets.match(@ets, {{:invitation, :"$1", user_id}, :"$2"}), row.state == state, do: room)
  end

  # the stored token like the real PgStore (per user, device_id ""), every persist call recorded in order
  # story sync-stream-position (DELIBERATE amendment, old -> new): the ONE write of a response is the guarded persist of the new story (token row + cursor rows, the ETS twin
  # `SyncPositionsFake.Store`); a call is recorded as `{user, token, last_event_id}` exactly as the old `persist_since_token` calls were, so every `persisted()` assertion keeps
  # its meaning ("how many writes, which token"); `last_event_id` is the newest delivered event id (informational since the story).
  defmodule FakePgStore do
    @ets :smp_unit_db
    alias Nebu.Matrix.SyncPositionsFake.Store

    def get_since_token(user_id), do: get_since_token(user_id, "")
    def get_since_token(user_id, device_id), do: Store.get_since_token(@ets, user_id, device_id)

    def persist_sync_position(user_id, device_id, spec) do
      with :ok <- Store.persist(@ets, user_id, device_id, spec) do
        :ets.insert(@ets, {{:persist, :erlang.unique_integer([:monotonic])}, {user_id, spec.new_token, spec.last_event_id}})
        :ok
      end
    end

    def invalidate_session(_user_id), do: :ok
    def invalidate_session(_user_id, _device_id), do: :ok

    def recorded_calls do
      :ets.match(@ets, {{:persist, :"$1"}, :"$2"}) |> Enum.sort_by(&hd/1) |> Enum.map(&List.last/1)
    end
  end

  # ─── setup ───────────────────────────────────────────────────────────────────

  setup do
    if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    :ets.new(@ets, [:named_table, :public, :set])

    snapshot =
      for {app, key} <- [
            {:room_manager, :db_module},
            {:event_dispatcher, :messages_db_module},
            {:event_dispatcher, :rooms_db_module},
            {:event_dispatcher, :invite_db_module},
            {:event_dispatcher, :pg_store_module}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:room_manager, :db_module, FakeDB)
    use_db(FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :pg_store_module, FakePgStore)
    Nebu.Test.ServerName.pin!("test.local")

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)

    on_exit(fn ->
      for {app, key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    end)

    n = System.unique_integer([:positive])
    {:ok, a: "@alice#{n}:test.local", b: "@bob#{n}:test.local", c: "@carol#{n}:test.local", x: "@xena#{n}:test.local"}
  end

  defp use_db(mod) do
    Application.put_env(:event_dispatcher, :messages_db_module, mod)
    Application.put_env(:event_dispatcher, :rooms_db_module, mod)
  end

  defp stream, do: %{http_request_headers: %{}}

  # ─── the world: writers that model the real writers ─────────────────────────────

  defp start_room!(room) do
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room)

    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
          {:ok, pid} -> Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
          _ -> :ok
        end
      end
    end)

    :ok
  end

  # createRoom as far as the sync can see it: the room row, the create event, the creator's join (through the real Room.Server)
  defp room!(creator, opts \\ []) do
    room = "!smp#{System.unique_integer([:positive])}:test.local"
    {:ok, _} = FakeDB.insert_room(room)
    :ok = start_room!(room)

    unless Keyword.get(opts, :no_create, false) do
      content = Map.merge(%{"creator" => creator, "room_version" => "10"}, Keyword.get(opts, :create_content, %{}))
      state!(room, creator, "m.room.create", "", content)
    end

    if name = Keyword.get(opts, :name), do: state!(room, creator, "m.room.name", "", %{"name" => name})
    if Keyword.get(opts, :rule, true), do: state!(room, creator, "m.room.join_rules", "", %{"join_rule" => "invite"})
    :ok = Nebu.Matrix.Room.Server.join(room, creator)
    room
  end

  defp state!(room, sender, type, key, content, opts \\ []) do
    ev = FakeDB.write_event(%{"room_id" => room, "sender" => sender, "type" => type, "state_key" => key, "content" => content, "__ts" => opts[:ts]})
    broadcast(ev)
    ev
  end

  # a message of `sender` (what send_event writes and fans out)
  defp msg!(room, sender, body, opts \\ []) do

    ev =
      FakeDB.write_event(%{
        "room_id" => room,
        "sender" => sender,
        "type" => "m.room.message",
        "content" => %{"msgtype" => "m.text", "body" => body},
        "__ts" => opts[:ts]
      })

    broadcast(ev)
    ev
  end

  defp broadcast(ev) do
    wire = Map.put(ev, "type", ev["event_type"])
    Enum.each(:pg.get_local_members("room:#{ev["room_id"]}"), &send(&1, {:new_event, wire}))
  end

  defp member_event!(room, user, membership, sender, opts) do
    content = Map.merge(%{"membership" => membership}, Keyword.get(opts, :extra, %{}))
    state!(room, sender, "m.room.member", user, content, ts: opts[:ts])
  end

  # the real join: the room process writes the member row and the join event, join_room/2 accepts the pending invitation
  defp join!(room, user) do
    :ok = Nebu.Matrix.Room.Server.join(room, user)
    accept_row!(room, user)
  end

  defp accept_row!(room, user) do
    case :ets.lookup(@ets, {:invitation, room, user}) do
      [{key, %{state: :pending} = row}] -> :ets.insert(@ets, {key, %{row | state: :accepted}})
      _ -> :ok
    end

    :ets.delete(@ets, {:forgotten, user, room})
    :ok
  end

  defp self_leave!(room, user), do: :ok = Nebu.Matrix.Room.Server.leave(room, user)

  # a join WITHOUT a room process (the member row and the join event, with an optional fixed timestamp): for rooms the sync never fetches
  defp row_join!(room, user, opts) do
    :ok = FakeDB.insert_member(room, user)
    accept_row!(room, user)
    member_event!(room, user, "join", user, ts: opts[:ts])
  end

  # a pending invitation: the row (invited_at from the counter, BEFORE the event like the real writer) and the invite event
  # (`row_only: true`: the row alone, an upgrade / legacy invitation; `invited_at:` pins the row time; `ts:` the event time)
  defp invite!(room, inviter, invitee, opts \\ []) do
    invited_at = opts[:invited_at] || FakeDB.next_ts()
    :ets.insert(@ets, {{:invitation, room, invitee}, %{inviter: inviter, invited_at: invited_at, state: :pending}})
    :ets.delete(@ets, {:forgotten, invitee, room})

    if Keyword.get(opts, :row_only, false) do
      nil
    else
      extra = if Keyword.get(opts, :is_direct, false), do: %{"is_direct" => true}, else: %{}
      ev = member_event!(room, invitee, "invite", inviter, extra: extra, ts: opts[:ts])
      Enum.each(:pg.get_local_members("user:#{invitee}"), &send(&1, {:new_invite, room}))
      ev
    end
  end

  defp reject_row!(room, invitee) do
    case :ets.lookup(@ets, {:invitation, room, invitee}) do
      [{key, %{state: :pending} = row}] -> :ets.insert(@ets, {key, %{row | state: :rejected}})
      _ -> :ok
    end
  end

  # the decline: the row is rejected, the leave event is authored by the invitee
  defp decline!(room, user, opts \\ []) do
    reject_row!(room, user)
    member_event!(room, user, "leave", user, ts: opts[:ts])
  end

  # an invitation taken back whose row reject FAILED: the leave event only, the row stays pending
  defp taken_back!(room, user, sender, opts \\ []), do: member_event!(room, user, "leave", sender, ts: opts[:ts])

  defp kick!(room, user, by, opts \\ []) do
    remove_member!(room, user)
    reject_row!(room, user)
    member_event!(room, user, "leave", by, ts: opts[:ts])
  end

  # `remove: false` is the `ex` N-6 half state: the ban event is written, the member row stays active
  defp ban!(room, user, by, opts \\ []) do
    if Keyword.get(opts, :remove, true), do: remove_member!(room, user)
    reject_row!(room, user)
    member_event!(room, user, "ban", by, ts: opts[:ts])
  end

  # the member set of the room process (when there is one) and the row. Story moderation-routes-atomic-ban (review cycle 1, M2; old ->
  # new): Room.Server.remove_member/2 is gone (no production writer removes a member without its event any more); this helper models
  # a removal with a FIXED event timestamp, so it closes the fake's row and drops the member from the running room process directly.
  defp remove_member!(room, user) do
    _ = FakeDB.delete_member(room, user)

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
      {:ok, pid} ->
        :sys.replace_state(pid, fn state ->
          %{state | members: MapSet.delete(state.members, user), member_identity: Map.delete(state.member_identity, user)}
        end)

      _ ->
        :ok
    end

    :ok
  end

  defp unban!(room, user, by, opts \\ []) do
    reject_row!(room, user)
    member_event!(room, user, "leave", by, ts: opts[:ts])
  end

  defp forget!(user, room), do: :ets.insert(@ets, {{:forgotten, user, room}, true})

  # an anchor room per user: its newest message is the anchor of the first token (events written later are NEW)
  defp anchor_room!(user), do: room!(user)

  defp snapshot!(user, anchor_room) do
    msg!(anchor_room, user, "anchor #{System.unique_integer([:positive])}")
    initial(user).since_token
  end

  # ─── the calls ───────────────────────────────────────────────────────────────

  defp initial(user), do: Server.get_initial_sync(%Core.GetInitialSyncRequest{user_id: user}, stream())

  defp delta(user, token, timeout),
    do: Server.get_sync_delta(%Core.GetSyncDeltaRequest{user_id: user, since_token: token, timeout_ms: timeout}, stream())

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  # a missing struct field is a readable assertion failure
  defp field(response, key) do
    case Map.fetch(response, key) do
      {:ok, value} -> value
      :error -> flunk("#{inspect(response.__struct__)} has no field #{inspect(key)} (story sync-membership-partition D11)")
    end
  end

  defp join_ids(response), do: response.rooms |> Enum.map(& &1.room_id) |> Enum.sort()
  defp invite_ids(response), do: response |> field(:invite_rooms) |> Enum.map(& &1.room_id) |> Enum.sort()
  defp leave_ids(response), do: response |> field(:leave_rooms) |> Enum.map(& &1.room_id) |> Enum.sort()
  defp join_class(response), do: response |> field(:join_room_ids) |> Enum.sort()
  defp leave_room(response, room), do: response |> field(:leave_rooms) |> Enum.find(&(&1.room_id == room))
  defp invite_room(response, room), do: response |> field(:invite_rooms) |> Enum.find(&(&1.room_id == room))
  defp tl_ids(room), do: Enum.map(room.timeline_events, & &1.event_id)
  defp all_section_ids(response), do: join_ids(response) ++ invite_ids(response) ++ leave_ids(response)

  defp stripped(room_struct) do
    Enum.map(room_struct.invite_state, fn ev ->
      assert Enum.sort(Map.keys(Map.from_struct(ev))) == [:content, :sender, :state_key, :type], "a stripped event has exactly type, state_key, sender, content"
      %{type: ev.type, state_key: ev.state_key, sender: ev.sender, content: Jason.decode!(ev.content)}
    end)
  end

  defp persisted, do: FakePgStore.recorded_calls()

  # story sync-stream-position (DELIBERATE amendment): the device's cursor row of a room in the fake store (nil = none), the head of a room
  defp cursor(user, room), do: Nebu.Matrix.SyncPositionsFake.Store.cursor(@ets, user, "", room)
  defp cursor_rows(user), do: Nebu.Matrix.SyncPositionsFake.Store.cursor_rows(@ets, user, "")
  defp head_of(room), do: room |> FakeDB.events() |> Enum.map(& &1["room_pos"]) |> Enum.max(fn -> 0 end)

  # ─── waits (bounded polls, never a fixed sleep) ─────────────────────────────────

  defp wait_until(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) >= deadline -> :timeout
        true -> (Process.sleep(2); :again)
      end
    end)
    |> Enum.find(&(&1 != :again))
  end

  # starts a (long-polling) incremental sync in a task and waits until its sync process joined the user's pg group
  defp start_sync(user, token, timeout) do
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> delta(user, token, timeout) end)
    assert :ok = wait_until(fn -> :pg.get_local_members("user:#{user}") != [] end), "the sync process never subscribed to user:#{user}"
    {task, started}
  end

  defp sync_pid(user), do: :pg.get_local_members("user:#{user}") |> hd()
  defp send_to_sync(user, message), do: Enum.each(:pg.get_local_members("user:#{user}"), &send(&1, message))

  # waits until the sync process is in the room's pg group (the subscription happens BEFORE the first DB check)
  defp wait_subscribed(user, room), do: assert(:ok = wait_until(fn -> sync_pid(user) in :pg.get_local_members("room:#{room}") end), "not subscribed to room:#{room}")

  # asserts that the sync process of `user` is NOT in the room's group (a bounded observation window, the sync is already subscribed to its other groups)
  defp refute_subscribed(user, room) do
    pid = sync_pid(user)
    assert :timeout == wait_until(fn -> pid in :pg.get_local_members("room:#{room}") end, 120), "the sync must NOT be subscribed to room:#{room}"
  end

  # a failed sync leaves no pg group behind (a leaked subscription would confuse the next wait and wake a dead sync)
  defp assert_no_groups(user), do: assert(:ok = wait_until(fn -> :pg.get_local_members("user:#{user}") == [] end, 1_000), "user:#{user} still has a member after the failed sync")

  defp finish(task, started) do
    response = Task.await(task, 10_000)
    {response, System.monotonic_time(:millisecond) - started}
  end

  # ═══ initial sync ════════════════════════════════════════════════════════════════

  describe "initial sync (AC2)" do
    test "rooms = joined rooms, invite_rooms = event-backed and row-only invitations; left, declined, forgotten, ban-override rooms are in NO section", %{a: a, b: b} do
      anchor = anchor_room!(b)

      joined = room!(a)
      invite!(joined, a, b)
      join!(joined, b)

      event_backed = room!(a)
      invite!(event_backed, a, b)
      row_only = room!(a)
      invite!(row_only, a, b, row_only: true)

      left = room!(a)
      invite!(left, a, b)
      join!(left, b)
      self_leave!(left, b)

      declined = room!(a)
      invite!(declined, a, b)
      decline!(declined, b)

      forgotten = room!(a)
      invite!(forgotten, a, b)
      join!(forgotten, b)
      self_leave!(forgotten, b)
      forget!(b, forgotten)

      banned_active = room!(a)
      invite!(banned_active, a, b)
      join!(banned_active, b)
      ban!(banned_active, b, a, remove: false)

      msg!(anchor, b, "newest")
      response = initial(b)

      assert join_ids(response) == Enum.sort([anchor, joined]), "only joined rooms with events are delivered in rooms"
      assert join_class(response) == Enum.sort([anchor, joined]), "the join class excludes the ban-override room although its row is active"
      assert invite_ids(response) == Enum.sort([event_backed, row_only])
      assert leave_ids(response) == [], "no include_leave filter support: an initial sync never has rooms.leave"

      ids = all_section_ids(response)
      assert ids == Enum.uniq(ids), "a room id is in at most ONE section"
      for hidden <- [left, declined, forgotten, banned_active], do: refute(hidden in ids)
    end

    test "initial sync of a user with joined rooms is unchanged: state events and the last 20 timeline events of the joined room are delivered as before", %{a: a, b: b} do
      room = room!(a, name: "Joined")
      invite!(room, a, b)
      join!(room, b)
      messages = for n <- 1..3, do: msg!(room, a, "m#{n}")

      response = initial(b)

      assert [delivered] = Enum.filter(response.rooms, &(&1.room_id == room))
      assert Enum.map(messages, & &1["event_id"]) -- tl_ids(delivered) == []
      assert Enum.any?(delivered.state_events, &(&1.type == "m.room.create"))
      assert Enum.any?(delivered.state_events, &(&1.type == "m.room.power_levels"))
      assert persisted() |> List.last() |> elem(1) == response.since_token
    end
  end

  # ═══ invite_state (D4) ═══════════════════════════════════════════════════════════

  describe "invite_state (D4, AC3, AC22 a)" do
    test "the stripped events in order: create, name, avatar, topic, canonical_alias, join_rules, encryption, the inviter's member event, the invitee's own invite event with is_direct", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, name: "Old name")
      state!(room, a, "m.room.name", "", %{"name" => "Current name"})
      state!(room, a, "m.room.avatar", "", %{"url" => "mxc://test.local/avatar"})
      state!(room, a, "m.room.topic", "", %{"topic" => "Topic"})
      state!(room, a, "m.room.canonical_alias", "", %{"alias" => "#r:test.local"})
      state!(room, a, "m.room.encryption", "", %{"algorithm" => "m.megolm.v1.aes-sha2"})
      state!(room, a, "m.room.power_levels", "", %{"users" => %{a => 100}})
      state!(room, a, "m.room.history_visibility", "", %{"history_visibility" => "invited"})
      state!(room, a, "m.room.guest_access", "", %{"guest_access" => "can_join"})
      msg!(room, a, "history that must not leak")
      invite!(room, a, b, is_direct: true)
      msg!(anchor, b, "newest")

      response = initial(b)
      events = stripped(invite_room(response, room))

      assert Enum.map(events, &{&1.type, &1.state_key}) == [
               {"m.room.create", ""},
               {"m.room.name", ""},
               {"m.room.avatar", ""},
               {"m.room.topic", ""},
               {"m.room.canonical_alias", ""},
               {"m.room.join_rules", ""},
               {"m.room.encryption", ""},
               {"m.room.member", a},
               {"m.room.member", b}
             ]

      by_type = Map.new(events, &{{&1.type, &1.state_key}, &1})
      assert by_type[{"m.room.create", ""}].content["creator"] == a
      assert by_type[{"m.room.name", ""}].content == %{"name" => "Current name"}, "the CURRENT name"
      assert by_type[{"m.room.member", a}].content == %{"membership" => "join"} and by_type[{"m.room.member", a}].sender == a
      assert by_type[{"m.room.member", b}].content == %{"membership" => "invite", "is_direct" => true}
      assert by_type[{"m.room.member", b}].sender == a, "the invite event keeps its real sender"
      refute Enum.any?(events, &(&1.type in ["m.room.power_levels", "m.room.history_visibility", "m.room.guest_access", "m.room.message"]))
      refute Jason.encode!(events) =~ "history that must not leak"
    end

    test "a room WITHOUT any create event (legacy) gets a synthesized m.room.create FIRST: sender and creator from get_room_creator/1, room_version the default, four keys", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, no_create: true)
      :ets.insert(@ets, {{:legacy_creator, room}, a})
      invite!(room, a, b)
      msg!(anchor, b, "newest")

      events = stripped(invite_room(initial(b), room))

      assert [%{type: "m.room.create", state_key: "", sender: ^a, content: content} | rest] = events
      assert content == %{"creator" => a, "room_version" => Nebu.Matrix.RoomVersions.default()}
      assert List.last(rest).type == "m.room.member" and List.last(rest).state_key == b
    end

    test "a legacy room whose creator is unknown: the synthesized create event is authored by the INVITER", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, no_create: true)
      invite!(room, a, b)
      msg!(anchor, b, "newest")

      assert [%{type: "m.room.create", sender: ^a, content: %{"creator" => ^a}} | _] = stripped(invite_room(initial(b), room))
    end

    test "a row-only invitation: the invitee's own member event is synthesized from the row (sender = inviter_id, content exactly membership invite), every event has four keys", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, name: "Upgraded")
      invite!(room, a, b, row_only: true)
      msg!(anchor, b, "newest")

      events = stripped(invite_room(initial(b), room))
      own = List.last(events)

      assert own == %{type: "m.room.member", state_key: b, sender: a, content: %{"membership" => "invite"}}
      assert hd(events).type == "m.room.create"
    end

    test "the inviter's member event is his LATEST one (a left inviter: leave), and absent when the inviter has none (D4)", %{a: a, b: b, c: c} do
      anchor = anchor_room!(b)
      left_inviter = room!(a)
      invite!(left_inviter, a, b)
      self_leave!(left_inviter, a)
      stranger_room = room!(a)
      invite!(stranger_room, c, b, row_only: true)
      msg!(anchor, b, "newest")

      response = initial(b)

      assert Enum.find(stripped(invite_room(response, left_inviter)), &(&1.type == "m.room.member" and &1.state_key == a)).content == %{"membership" => "leave"}
      events = stripped(invite_room(response, stranger_room))
      assert Enum.filter(events, &(&1.type == "m.room.member" and &1.state_key == c)) == [], "no member event of the inviter exists: none is invented"
      assert List.last(events) == %{type: "m.room.member", state_key: b, sender: c, content: %{"membership" => "invite"}}
    end

    test "a Space: the create content's type m.space is passed through unchanged", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, create_content: %{"type" => "m.space"})
      invite!(room, a, b)
      msg!(anchor, b, "newest")

      assert [%{type: "m.room.create", content: %{"type" => "m.space"}} | _] = stripped(invite_room(initial(b), room))
    end

    test "the room's FIRST create event is used when there are two", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, create_content: %{"marker" => "first"})
      state!(room, a, "m.room.create", "", %{"creator" => a, "room_version" => "10", "marker" => "second"})
      invite!(room, a, b)
      msg!(anchor, b, "newest")

      assert [%{type: "m.room.create", content: %{"marker" => "first"}} | _] = stripped(invite_room(initial(b), room))
    end
  end

  # ═══ incremental invite delivery (AC4, D5) ═══════════════════════════════════════

  describe "incremental invite delivery (AC4, D5)" do
    test "a new event-backed invitation is in invite_rooms (not in rooms / join_room_ids), the sync returns at once, the NEXT sync delivers nothing and WAITS", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = room!(a)
      invite!(room, a, b, is_direct: true)

      {first, ms} = timed(fn -> delta(b, token, 5_000) end)

      assert invite_ids(first) == [room]
      assert room not in join_ids(first) and room not in join_class(first)
      assert leave_ids(first) == []
      assert ms < 1_000, "an available invitation ends the wait at once, took #{ms} ms"
      assert first.fallback_to_initial == false
      assert [{_, _, last_event_id}] = persisted() |> Enum.take(-1)
      assert last_event_id == (room |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b)) |> hd())["event_id"], "the delivered invite event moved the anchor"

      {second, ms2} = timed(fn -> delta(b, first.since_token, 200) end)
      assert invite_ids(second) == [] and join_ids(second) == []
      assert ms2 >= 150, "no hot loop: the invitation was delivered once and the next sync waits, took #{ms2} ms"
    end

    test "an invitation that is OLDER than the token is not delivered again (it appears with the next initial sync)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      token = snapshot!(b, anchor)

      {response, ms} = timed(fn -> delta(b, token, 200) end)

      assert invite_ids(response) == []
      assert ms >= 150
      assert invite_ids(initial(b)) == [room], "a fresh initial sync shows it"
    end

    test "a ROW-ONLY invitation newer than the token is delivered but does not end a wait by itself; an older one is not delivered", %{a: a, b: b} do
      anchor = anchor_room!(b)
      older = room!(a)
      invite!(older, a, b, row_only: true)
      token = snapshot!(b, anchor)
      newer = room!(a)
      invite!(newer, a, b, row_only: true)

      {response, ms} = timed(fn -> delta(b, token, 200) end)

      assert invite_ids(response) == [newer], "newer than the anchor only"
      assert ms >= 150, "a row-only invitation never ends the wait (no event id to anchor on), took #{ms} ms"
      assert [%{type: "m.room.member", state_key: ^b, sender: ^a, content: %{"membership" => "invite"}}] = response |> invite_room(newer) |> stripped() |> Enum.take(-1)
    end

    test "a row-only invitation is remembered by its cursor row (class invite) and never becomes the last event id", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      [{_, _, anchor_event}] = persisted() |> Enum.take(-1)
      room = room!(a)
      invite!(room, a, b, row_only: true)

      response = delta(b, token, 0)

      assert invite_ids(response) == [room], "control: the row-only invitation WAS delivered"
      assert [{_, _, last_event_id}] = persisted() |> Enum.take(-1)
      # DELIBERATE amendment by story sync-stream-position, old -> new: `last_event_id` is informational (the newest DELIVERED event id) and no longer an anchor that is
      # "kept": with no event delivered it is nil or the previous value. A row-only invite has no event id and never becomes one.
      assert last_event_id in [nil, anchor_event], "a row-only invite never becomes the last event id"
      assert cursor(b, room).class == "invite", "its delivery is remembered by the cursor row (class invite, the row's invited_at as the marker)"
    end

    test "{:new_invite, _} wakes the long-poll and the REBUILT response carries the invitation; the token is persisted exactly once for the wake", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = room!(a)
      before = length(persisted())

      {task, started} = start_sync(b, token, 5_000)
      # the sync has finished its first build and is waiting (subscribed to its anchor room): the write below is NEW to the wait, not to the first build
      wait_subscribed(b, anchor)
      invite!(room, a, b)
      send_to_sync(b, {:new_invite, room})
      {response, ms} = finish(task, started)

      assert invite_ids(response) == [room]
      assert ms < 2_500, "woken early, took #{ms} ms of 5000"
      assert length(persisted()) == before + 1
    end

    test "messages in a pending invitation room neither wake the long-poll nor appear anywhere (L-3); the invite room stays subscribed", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      token = snapshot!(b, anchor)
      before = length(persisted())

      {task, started} = start_sync(b, token, 500)
      wait_subscribed(b, room)

      for n <- 1..3 do
        msg!(room, a, "dm message #{n}")
        FakeDB.write_event(%{"room_id" => room, "sender" => a, "type" => "m.room.member", "state_key" => a, "content" => %{"membership" => "join"}}) |> broadcast()
      end

      {response, ms} = finish(task, started)

      assert join_ids(response) == [] and invite_ids(response) == [] and leave_ids(response) == []
      assert ms >= 450, "the events of an invitation room must not end the wait (the ORIGINAL timer keeps running), took #{ms} ms of 500"
      assert ms < 3_000
      assert length(persisted()) == before + 1
    end
  end

  # ═══ leave delivery (AC5, D6) ════════════════════════════════════════════════════

  describe "leave delivery, the ez fix (AC5, D6)" do
    test "joined before the token, then left: rooms.leave has the messages up to the leave and the leave event LAST, nothing after it, empty state, not in rooms / join_room_ids", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      m1 = msg!(room, a, "m1")
      m2 = msg!(room, a, "m2")
      self_leave!(room, b)
      leave_event = room |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b)) |> Enum.max_by(& &1["origin_server_ts"])
      after_leave = msg!(room, a, "after the leave")

      response = delta(b, token, 0)
      entry = leave_room(response, room)

      assert leave_ids(response) == [room] and room not in join_ids(response) and room not in invite_ids(response) and room not in join_class(response)
      assert tl_ids(entry) == [m1["event_id"], m2["event_id"], leave_event["event_id"]]
      refute after_leave["event_id"] in tl_ids(entry)
      assert entry.state_events == []
      assert entry.limited == false
      assert entry.heroes == [] and entry.joined_member_count == 0
      assert List.last(entry.timeline_events) |> then(&{&1.event_type, &1.state_key, &1.sender_id}) == {"m.room.member", b, b}
      assert Jason.decode!(List.last(entry.timeline_events).content) == %{"membership" => "leave"}
    end

    test "a kick (sender = the kicker), a ban (sender = the banner) and an Admin removal (a self-leave) each end the timeline at the removal event", %{a: a, b: b} do
      for {label, remover, expected_sender, membership} <- [
            {:kick, fn room -> kick!(room, b, a) end, a, "leave"},
            {:ban, fn room -> ban!(room, b, a) end, a, "ban"},
            {:admin_removal, fn room -> self_leave!(room, b) end, b, "leave"}
          ] do
        anchor = anchor_room!(b)
        room = room!(a)
        invite!(room, a, b)
        join!(room, b)
        token = snapshot!(b, anchor)
        before_removal = msg!(room, a, "before #{label}")
        remover.(room)
        after_removal = msg!(room, a, "after #{label}")

        entry = leave_room(delta(b, token, 0), room)

        assert entry, "#{label}: rooms.leave has the room"
        assert before_removal["event_id"] in tl_ids(entry)
        refute after_removal["event_id"] in tl_ids(entry), "#{label}: nothing after the removal"
        last = List.last(entry.timeline_events)
        assert {last.event_type, last.state_key, last.sender_id} == {"m.room.member", b, expected_sender}, "#{label}"
        assert Jason.decode!(last.content)["membership"] == membership
      end
    end

    test "joined AFTER the token, then left: the join event first, the events between, the leave event last", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      token = snapshot!(b, anchor)
      invite!(room, a, b)
      join!(room, b)
      join_event = room |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b and &1["content"]["membership"] == "join")) |> hd()
      between = msg!(room, a, "between")
      self_leave!(room, b)
      leave_event = room |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b and &1["content"]["membership"] == "leave")) |> hd()

      entry = leave_room(delta(b, token, 0), room)

      assert tl_ids(entry) == [join_event["event_id"], between["event_id"], leave_event["event_id"]]
      assert entry.limited == false
    end

    test "a declined invitation: the timeline is exactly the decline event (no message of the room, before or after the invitation)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      token = snapshot!(b, anchor)
      msg!(room, a, "before the invite")
      invite!(room, a, b)
      msg!(room, a, "after the invite")
      decline_event = decline!(room, b)
      msg!(room, a, "after the decline")

      response = delta(b, token, 0)
      entry = leave_room(response, room)

      assert leave_ids(response) == [room] and invite_ids(response) == [] and room not in join_ids(response)
      assert tl_ids(entry) == [decline_event["event_id"]]
      assert entry.limited == false and entry.state_events == []
      assert List.last(entry.timeline_events).sender_id == b, "sender == state_key == the invitee"
    end

    test "invited, then banned: the timeline is exactly the ban event (sender = the banner)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      token = snapshot!(b, anchor)
      invite!(room, a, b)
      ban_event = ban!(room, b, a)

      entry = leave_room(delta(b, token, 0), room)

      assert tl_ids(entry) == [ban_event["event_id"]]
      assert List.last(entry.timeline_events).sender_id == a
    end

    test "after the leave was delivered the room is in NO section again, A's messages and a rename appear nowhere, and they do not wake the long-poll (the room is not subscribed)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      self_leave!(room, b)
      first = delta(b, token, 0)
      assert leave_ids(first) == [room]

      secret = "secret-#{System.unique_integer([:positive])}"
      before = length(persisted())
      {task, started} = start_sync(b, first.since_token, 500)
      refute_subscribed(b, room)

      for n <- 1..3, do: msg!(room, a, "#{secret} #{n}")
      state!(room, a, "m.room.name", "", %{"name" => "renamed #{secret}"})
      {response, ms} = finish(task, started)

      assert all_section_ids(response) == []
      assert ms >= 450, "events of a left room must not wake the long-poll, took #{ms} ms of 500"
      assert length(persisted()) == before + 1
      refute inspect(response) =~ secret
    end

    test "rooms the user left or declined BEFORE the token, and a pending invitation delivered before it, stay silent when new messages arrive", %{a: a, b: b} do
      anchor = anchor_room!(b)
      left = room!(a)
      invite!(left, a, b)
      join!(left, b)
      self_leave!(left, b)
      declined = room!(a)
      invite!(declined, a, b)
      decline!(declined, b)
      pending = room!(a)
      invite!(pending, a, b)
      token = snapshot!(b, anchor)

      for room <- [left, declined, pending], do: msg!(room, a, "news #{System.unique_integer([:positive])}")
      {response, ms} = timed(fn -> delta(b, token, 200) end)

      assert all_section_ids(response) == []
      assert ms >= 150, "no section, no early return: took #{ms} ms"
    end

    test "a limited leave window: the newest 20 events and the leave event, limited true, prev_batch = the oldest delivered event, state empty, the join event is NOT prepended", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      messages = for n <- 1..25, do: msg!(room, a, "window #{n}")
      self_leave!(room, b)
      leave_event = room |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b and &1["content"]["membership"] == "leave")) |> hd()

      entry = leave_room(delta(b, token, 0), room)
      newest_twenty = messages |> Enum.take(-20) |> Enum.map(& &1["event_id"])

      assert tl_ids(entry) == newest_twenty ++ [leave_event["event_id"]]
      assert entry.limited == true
      # DELIBERATE amendment by story sync-stream-position (D5 / D10), old -> new: `prev_batch` is the real `/messages` token (`v1_`) of the oldest delivered event, no longer its id
      oldest = Enum.at(messages, 5)
      assert entry.prev_batch == "v1_" <> Base.url_encode64("#{oldest["origin_server_ts"]}:#{oldest["event_id"]}", padding: false), "the /messages token of the oldest delivered event"
      assert hd(newest_twenty) == oldest["event_id"]
      assert entry.state_events == []
    end

    # DELIBERATE amendment by story sync-stream-position (D5 / D10), old -> new: "a window of EXACTLY 20 events is limited (the middle read returned 20)" is now "limited
    # when a 21st row exists", as the join path decides: 20 events are not limited, 21 are (the read answers the newest 21 rows).
    test "a window of EXACTLY 20 events is NOT limited; a 21st event makes it limited (D5: a 21st row), as the join path decides", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      messages = for n <- 1..20, do: msg!(room, a, "exact #{n}")
      self_leave!(room, b)

      entry = leave_room(delta(b, token, 0), room)

      assert entry.limited == false
      assert entry.prev_batch == ""
      assert length(entry.timeline_events) == 21
      assert Enum.map(Enum.take(entry.timeline_events, 20), & &1.event_id) == Enum.map(messages, & &1["event_id"])

      room21 = room!(a)
      invite!(room21, a, b)
      join!(room21, b)
      token21 = snapshot!(b, anchor)
      messages21 = for n <- 1..21, do: msg!(room21, a, "twenty-one #{n}")
      self_leave!(room21, b)

      entry21 = leave_room(delta(b, token21, 0), room21)
      assert entry21.limited == true
      oldest = Enum.at(messages21, 1)
      assert entry21.prev_batch == "v1_" <> Base.url_encode64("#{oldest["origin_server_ts"]}:#{oldest["event_id"]}", padding: false)
      assert length(entry21.timeline_events) == 21, "the newest 20 and the leave event"
    end

    test "a window of exactly 19 events is not limited (the middle read returned less than 20): prev_batch stays empty and the join event is prepended when newer than the token", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      token = snapshot!(b, anchor)
      invite!(room, a, b)
      join!(room, b)
      messages = for n <- 1..19, do: msg!(room, a, "w#{n}")
      self_leave!(room, b)

      entry = leave_room(delta(b, token, 0), room)

      assert entry.limited == false
      assert entry.prev_batch == ""
      assert length(entry.timeline_events) == 1 + 19 + 1, "P + the 19 messages + L"
      assert Enum.map(Enum.slice(entry.timeline_events, 1, 19), & &1.event_id) == Enum.map(messages, & &1["event_id"])
    end

    # DELIBERATE amendment by story sync-stream-position (D10), old -> new: the bounds are POSITIONS: (max(the device's cursor, P.room_pos), L.room_pos), strictly, with no clock
    # bound while the row tells none. "An event of another user in the SAME millisecond as the kick" is excluded because it is written AFTER the kick (a higher position), not
    # because of its timestamp.
    test "the window is read with the position bounds (max(cursor, P.pos), L.pos) and never reaches L: an event of another user in the SAME millisecond as the kick is excluded", %{a: a, b: b, c: c} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      base_pos = cursor(b, room).pos
      join_event = room |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b and &1["content"]["membership"] == "join")) |> hd()
      inside = msg!(room, a, "inside")
      kick_ts = FakeDB.next_ts()
      kick = kick!(room, b, a, ts: kick_ts)
      same_ms = msg!(room, c, "same millisecond as the kick", ts: kick_ts)
      msg!(room, c, "one millisecond later", ts: kick_ts + 1)

      entry = leave_room(delta(b, token, 0), room)

      assert tl_ids(entry) == [inside["event_id"], kick["event_id"]]
      refute same_ms["event_id"] in tl_ids(entry)
      assert join_event["room_pos"] <= base_pos, "(the user was joined before the token: the lower bound is the device's cursor)"
      # the facts of D10 (not the sentinel values): strictly inside (cursor, L) by position, and no clock bound in play (the member row tells none): the bounds are "unset" or not tighter than L
      assert Enum.any?(FakeDB.window_calls(), fn {r, lo, hi, after_ts, before_ts} -> r == room and lo == base_pos and hi == kick["room_pos"] and after_ts <= kick_ts and before_ts >= kick_ts end),
             "the read is strictly inside (cursor, L); calls: #{inspect(FakeDB.window_calls())}"
      assert Enum.all?(FakeDB.window_calls(), fn {_room, _lo, hi, _, _} -> hi <= kick["room_pos"] end), "no read reaches a position at or after L"
    end

    # DELIBERATE amendment by story sync-stream-position (D10), old -> new: the lower bound is the JOIN event's POSITION; the clock bound `origin_server_ts > joined_at` is the
    # member row's (`set_joined_at`, what the real row carries and the old fake did not tell), strict, and it is what excludes the event in the same millisecond as the join
    # (it can only SHRINK the window).
    test "the window's lower bound is the JOIN event when the user joined after the token: an event in the same millisecond as the join is excluded (row clock)", %{a: a, b: b, c: c} do
      anchor = anchor_room!(b)
      room = room!(a)
      token = snapshot!(b, anchor)
      invite!(room, a, b)
      join_ts = FakeDB.next_ts()
      join_event = row_join!(room, b, ts: join_ts)
      FakeDB.set_joined_at(room, b, join_ts)
      same_ms_as_join = msg!(room, c, "same millisecond as the join", ts: join_ts)
      inside = msg!(room, a, "inside")
      kick_ts = FakeDB.next_ts()
      kick_event = kick!(room, b, a, ts: kick_ts)

      entry = leave_room(delta(b, token, 0), room)

      assert tl_ids(entry) == [join_event["event_id"], inside["event_id"], kick_event["event_id"]]
      refute same_ms_as_join["event_id"] in tl_ids(entry)
      assert Enum.any?(FakeDB.window_calls(), fn {r, lo, hi, after_ts, before_ts} -> r == room and lo == join_event["room_pos"] and hi == kick_event["room_pos"] and after_ts == join_ts and before_ts >= kick_ts end),
             "the window is strictly inside (P, L) and starts at the row's joined_at; calls: #{inspect(FakeDB.window_calls())}"
    end

    test "a rename written right after the kick (1 ms later, fixed timestamp) is not in the leave entry and not in any later sync; state.events is empty", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, name: "Before")
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      kick_ts = FakeDB.next_ts()
      kick!(room, b, a, ts: kick_ts)
      rename = state!(room, a, "m.room.name", "", %{"name" => "After the kick"}, ts: kick_ts + 1)

      first = delta(b, token, 0)
      entry = leave_room(first, room)

      refute rename["event_id"] in tl_ids(entry)
      assert entry.state_events == []
      refute inspect(first) =~ "After the kick"
      second = delta(b, first.since_token, 0)
      refute inspect(second) =~ "After the kick"
    end
  end

  # ═══ the edge-case table (AC6) ═══════════════════════════════════════════════════

  describe "edge-case table (AC6)" do
    test "invited, then joined: rooms.join with the invite and the join event in the timeline, no invite section", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = room!(a)
      invite_event = invite!(room, a, b)
      join!(room, b)

      response = delta(b, token, 0)

      assert join_ids(response) == [room] and invite_ids(response) == [] and leave_ids(response) == []
      ids = response.rooms |> Enum.find(&(&1.room_id == room)) |> tl_ids()
      assert invite_event["event_id"] in ids
      assert Enum.any?(response.rooms |> hd() |> Map.fetch!(:timeline_events), &(&1.event_type == "m.room.member" and &1.state_key == b and Jason.decode!(&1.content)["membership"] == "join"))
    end

    test "joined before the token, left, re-invited: rooms.invite only (the leave is superseded)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      self_leave!(room, b)
      invite!(room, a, b)

      response = delta(b, token, 0)

      assert invite_ids(response) == [room]
      assert join_ids(response) == [] and leave_ids(response) == [] and room not in join_class(response)
      assert List.last(stripped(invite_room(response, room))) |> Map.take([:state_key, :sender]) == %{state_key: b, sender: a}
    end

    test "joined before the token, left, re-joined (public room): rooms.join with the events of the gap", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a, rule: false)
      state!(room, a, "m.room.join_rules", "", %{"join_rule" => "public"})
      join!(room, b)
      token = snapshot!(b, anchor)
      self_leave!(room, b)
      gap = msg!(room, a, "while away")
      join!(room, b)

      response = delta(b, token, 0)

      assert join_ids(response) == [room] and leave_ids(response) == [] and invite_ids(response) == []
      assert gap["event_id"] in tl_ids(Enum.find(response.rooms, &(&1.room_id == room)))
    end

    test "active row, latest member event a ban (ex half state): rooms.leave once with window and ban, then NO section, never rooms.join", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      before = msg!(room, a, "before the ban")
      ban_event = ban!(room, b, a, remove: false)
      msg!(room, a, "after the ban")

      first = delta(b, token, 0)

      assert leave_ids(first) == [room] and room not in join_ids(first) and room not in join_class(first)
      assert tl_ids(leave_room(first, room)) == [before["event_id"], ban_event["event_id"]]

      msg!(room, a, "much later")
      {second, ms} = timed(fn -> delta(b, first.since_token, 200) end)
      assert all_section_ids(second) == [] and room not in join_class(second)
      assert ms >= 150
    end

    test "a forgotten room is in no section, also when the leave was not delivered yet; a forgotten PENDING invitation is hidden (rule 1)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      left = room!(a)
      invite!(left, a, b)
      join!(left, b)
      token = snapshot!(b, anchor)
      self_leave!(left, b)
      forget!(b, left)
      pending = room!(a)
      invite!(pending, a, b)
      forget!(b, pending)

      response = delta(b, token, 0)

      assert all_section_ids(response) == []
      assert invite_ids(initial(b)) == [], "the initial sync hides the forgotten pending invitation as well"
    end

    test "ban and join in the SAME millisecond: ban is the latest, the room is a leave entry (fixed timestamps)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      tie = FakeDB.next_ts()
      ban_event = ban!(room, b, a, remove: false, ts: tie)
      FakeDB.write_event(%{"room_id" => room, "sender" => b, "type" => "m.room.member", "state_key" => b, "content" => %{"membership" => "join"}, "__ts" => tie})

      response = delta(b, token, 0)

      assert leave_ids(response) == [room] and room not in join_class(response)
      assert List.last(leave_room(response, room).timeline_events).event_id == ban_event["event_id"]
    end

    test "invited, then taken back (leave event written, row reject failed: still pending): rooms.leave [L] once, then nothing, never rooms.invite", %{a: a, b: b} do
      for {label, sender} <- [removal_by_inviter: a, decline_by_invitee: b] do
        anchor = anchor_room!(b)
        token = snapshot!(b, anchor)
        room = room!(a)
        invite!(room, a, b)
        leave_event = taken_back!(room, b, sender)

        first = delta(b, token, 0)

        assert leave_ids(first) == [room], "#{label}"
        assert invite_ids(first) == [], "#{label}: a taken-back invitation is not shown again"
        assert tl_ids(leave_room(first, room)) == [leave_event["event_id"]]
        assert List.last(leave_room(first, room).timeline_events).sender_id == sender
        assert persisted() |> List.last() |> elem(1) == first.since_token

        {second, ms} = timed(fn -> delta(b, first.since_token, 200) end)
        assert all_section_ids(second) == [] and ms >= 150, "#{label}: then nothing"
        assert invite_ids(initial(b)) == [], "#{label}: the initial sync does not list it either"
      end
    end

    test "a leave in the SAME millisecond as invited_at is taken back (most restrictive); an OLDER leave is a valid invitation", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)

      tie_room = room!(a)
      t = FakeDB.next_ts()
      invite!(tie_room, a, b, row_only: true, invited_at: t)
      leave_event = taken_back!(tie_room, b, a, ts: t)

      older_room = room!(a)
      member_event!(older_room, b, "leave", b, ts: FakeDB.next_ts())
      invite!(older_room, a, b, row_only: true)

      response = delta(b, token, 0)

      assert leave_ids(response) == [tie_room]
      assert tl_ids(leave_room(response, tie_room)) == [leave_event["event_id"]]
      assert invite_ids(response) == [older_room], "a legacy re-invite (row-only, an OLDER leave) stays an invitation"
      assert tie_room not in invite_ids(response)
    end

    test "invited, banned, then unbanned: one leave entry per NEW latest event ([ban], then [unban leave]), never join or invite", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = room!(a)
      invite!(room, a, b)
      ban_event = ban!(room, b, a)

      first = delta(b, token, 0)
      assert tl_ids(leave_room(first, room)) == [ban_event["event_id"]]

      unban_event = unban!(room, b, a)
      second = delta(b, first.since_token, 0)

      assert leave_ids(second) == [room]
      assert tl_ids(leave_room(second, room)) == [unban_event["event_id"]], "the window of the second entry does not repeat the ban"
      assert join_ids(second) == [] and invite_ids(second) == [] and room not in join_class(second)

      third = delta(b, second.since_token, 0)
      assert all_section_ids(third) == []
    end

    test "left, declined, invited and joined rooms in one window: every room id is in at most one section", %{a: a, b: b} do
      anchor = anchor_room!(b)
      left = room!(a)
      invite!(left, a, b)
      join!(left, b)
      token = snapshot!(b, anchor)
      self_leave!(left, b)
      declined = room!(a)
      invite!(declined, a, b)
      decline!(declined, b)
      invited = room!(a)
      invite!(invited, a, b)
      joined = room!(a)
      invite!(joined, a, b)
      join!(joined, b)

      response = delta(b, token, 0)
      ids = all_section_ids(response)

      assert ids == Enum.uniq(ids)
      assert leave_ids(response) == Enum.sort([left, declined]) and invite_ids(response) == [invited] and joined in join_ids(response)
    end
  end

  # ═══ the rule table, rows 3 and 6 (test review m2): the row decides for members, a missing event never invents a leave ═══════════════

  describe "rule table rows 3 and 6 (D1)" do
    test "an ACTIVE row without any member event (a legacy room) stays in rooms.join and join_room_ids: the row decides, initial and incremental", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = room!(a, rule: false)
      :ok = FakeDB.insert_member(room, b)
      msg!(room, a, "news")

      response = delta(b, token, 0)

      assert room in join_ids(response) and room in join_class(response)
      assert leave_ids(response) == [] and invite_ids(response) == []
      assert room in join_class(initial(b)), "the initial sync agrees"
    end

    test "an ACTIVE row whose latest member event is a STALE leave (the join event write failed) is not demoted: still rooms.join, never rooms.leave", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = room!(a)
      member_event!(room, b, "leave", b, [])
      :ok = FakeDB.insert_member(room, b)
      msg!(room, a, "news")

      response = delta(b, token, 0)

      assert room in join_class(response) and room in join_ids(response)
      assert leave_ids(response) == [], "only a ban demotes an active row (rule 2); a stale leave does not"
    end

    test "a LEFT row and a REJECTED invitation row whose leave event is missing (the write failed) are in no section (rule 6); a latest knock too", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)

      left_no_event = room!(a)
      :ok = FakeDB.insert_member(left_no_event, b)
      :ok = FakeDB.delete_member(left_no_event, b)

      rejected_no_event = room!(a)
      invite!(rejected_no_event, a, b, row_only: true)
      reject_row!(rejected_no_event, b)

      knock = room!(a)
      :ok = FakeDB.insert_member(knock, b)
      :ok = FakeDB.delete_member(knock, b)
      member_event!(knock, b, "knock", b, [])

      response = delta(b, token, 0)

      for room <- [left_no_event, rejected_no_event, knock], do: refute(room in all_section_ids(response) or room in join_class(response), "#{room} is in no section")
    end

    test "an unknown / unparseable latest membership counts as leave: a LEFT row then makes it a rooms.leave entry", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      remove_member!(room, b)
      bad = state!(room, b, "m.room.member", b, %{"membership" => "foo"})

      response = delta(b, token, 0)

      assert leave_ids(response) == [room]
      assert List.last(leave_room(response, room).timeline_events).event_id == bad["event_id"]
    end

    test "member events WITHOUT any row (no candidate) are in no section", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = room!(a)
      member_event!(room, b, "join", b, [])
      msg!(room, a, "news")

      response = delta(b, token, 0)

      assert all_section_ids(response) == [] and room not in join_class(response)
    end
  end

  # ═══ the wake rules (AC7) ════════════════════════════════════════════════════════

  describe "the long-poll wake rules (AC7)" do
    setup %{a: a, b: b} do
      anchor = anchor_room!(b)
      joined = room!(a)
      invite!(joined, a, b)
      join!(joined, b)

      invited = room!(a)
      invite!(invited, a, b)

      left = room!(a)
      invite!(left, a, b)
      join!(left, b)
      self_leave!(left, b)

      token = snapshot!(b, anchor)
      {:ok, anchor: anchor, joined: joined, invited: invited, left: left, token: token}
    end

    test "the sync subscribes to the join and the invite room, never to the left room; a new event in the left room and a non-member event in the invite room do NOT wake it",
         %{a: a, b: b, joined: joined, invited: invited, left: left, token: token} do
      before = length(persisted())
      {task, started} = start_sync(b, token, 500)
      wait_subscribed(b, joined)
      wait_subscribed(b, invited)
      refute_subscribed(b, left)

      msg!(left, a, "left room news")
      # even a message that REACHES the sync process (a stale / mis-routed fan-out of the left room) must not end the wait
      send_to_sync(b, {:new_event, %{"room_id" => left, "type" => "m.room.message", "sender" => a, "content" => %{"body" => "stale"}}})
      msg!(invited, a, "invite room news")
      member_event!(invited, "@someone:test.local", "join", "@someone:test.local", [])

      {response, ms} = finish(task, started)

      assert all_section_ids(response) == []
      assert ms >= 450 and ms < 3_000, "ignored messages keep the ORIGINAL timer, took #{ms} ms of 500"
      assert length(persisted()) == before + 1
    end

    test "an m.room.member event with state_key = the user in the invite room wakes the sync, and the rebuilt response classifies the room by the NEW state (a decline: rooms.leave [L])",
         %{b: b, invited: invited, token: token} do
      before = length(persisted())
      {task, started} = start_sync(b, token, 5_000)
      wait_subscribed(b, invited)

      decline_event = decline!(invited, b)
      {response, ms} = finish(task, started)

      assert ms < 2_500, "woken by the decline, took #{ms} ms"
      assert leave_ids(response) == [invited] and invite_ids(response) == []
      assert tl_ids(leave_room(response, invited)) == [decline_event["event_id"]]
      assert length(persisted()) == before + 1
    end

    test "a new event in a joined room wakes the sync and the room's events are delivered", %{a: a, b: b, joined: joined, token: token} do
      before = length(persisted())
      {task, started} = start_sync(b, token, 5_000)
      wait_subscribed(b, joined)

      news = msg!(joined, a, "news")
      {response, ms} = finish(task, started)

      assert ms < 2_500
      assert join_ids(response) == [joined]
      assert news["event_id"] in tl_ids(Enum.find(response.rooms, &(&1.room_id == joined)))
      assert length(persisted()) == before + 1
    end

    test "{:new_join, X} wakes the sync and X is in rooms.join; {:new_leave, J} wakes it and J is in rooms.leave", %{a: a, b: b, joined: joined, token: token} do
      public = room!(a, rule: false)
      state!(public, a, "m.room.join_rules", "", %{"join_rule" => "public"})
      before = length(persisted())

      {task, started} = start_sync(b, token, 5_000)
      wait_subscribed(b, joined)
      join!(public, b)
      send_to_sync(b, {:new_join, public})
      {joined_response, ms} = finish(task, started)

      assert ms < 2_500
      assert public in join_ids(joined_response)
      assert length(persisted()) == before + 1

      {task, started} = start_sync(b, joined_response.since_token, 5_000)
      wait_subscribed(b, joined)
      self_leave!(joined, b)
      send_to_sync(b, {:new_leave, joined})
      {left_response, ms} = finish(task, started)

      assert ms < 2_500
      assert leave_ids(left_response) == [joined] and joined not in join_ids(left_response)
      assert length(persisted()) == before + 2
    end

    test "{:account_data_changed, _} wakes the sync (an empty delta: the HTTP layer re-reads the account data)", %{b: b, token: token} do
      {task, started} = start_sync(b, token, 5_000)
      send_to_sync(b, {:account_data_changed, "!any:test.local"})
      {response, ms} = finish(task, started)

      assert ms < 2_500
      assert all_section_ids(response) == []
    end

    test "the timeout ends the wait with an empty response and exactly one persisted token", %{b: b, token: token} do
      before = length(persisted())
      {response, ms} = timed(fn -> delta(b, token, 200) end)

      assert ms >= 150 and all_section_ids(response) == []
      assert length(persisted()) == before + 1
    end
  end

  # ═══ ban override (AC9, unit part) ═══════════════════════════════════════════════

  describe "ban override (AC9)" do
    test "a room with an active row and a ban event never reaches rooms.join, join_room_ids or an empty join entry, incremental and initial; the leave is delivered once when the ban is new", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      ban!(room, b, a, remove: false)

      response = delta(b, token, 0)
      assert leave_ids(response) == [room]
      assert room not in join_class(response) and room not in join_ids(response)

      msg!(anchor, b, "newest")
      fresh = initial(b)
      assert room not in join_class(fresh) and room not in join_ids(fresh) and room not in leave_ids(fresh)
    end
  end

  # ═══ anchor and fail closed (AC8) ════════════════════════════════════════════════

  describe "anchor (D5), fail closed (D10)" do
    # one world with a joined room (news), a room the user is about to leave and a room that invites him; the LAST write decides the anchor
    defp anchor_world(a, b) do
      anchor = anchor_room!(b)
      joined = room!(a)
      invite!(joined, a, b)
      join!(joined, b)
      leaving = room!(a)
      invite!(leaving, a, b)
      join!(leaving, b)
      invited = room!(a)
      token = snapshot!(b, anchor)
      %{joined: joined, leaving: leaving, invited: invited, token: token}
    end

    defp anchored_event_id, do: persisted() |> List.last() |> elem(2)

    test "the persisted last_event_id is the event-backed INVITE event when it is the newest delivered event", %{a: a, b: b} do
      %{joined: joined, leaving: leaving, invited: invited, token: token} = anchor_world(a, b)
      msg!(joined, a, "join news")
      self_leave!(leaving, b)
      invite_event = invite!(invited, a, b)

      response = delta(b, token, 0)

      assert invite_ids(response) == [invited] and leave_ids(response) == [leaving] and joined in join_ids(response)
      assert anchored_event_id() == invite_event["event_id"]
    end

    test "the persisted last_event_id is the LEAVE event L when it is the newest delivered event", %{a: a, b: b} do
      %{joined: joined, leaving: leaving, invited: invited, token: token} = anchor_world(a, b)
      msg!(joined, a, "join news")
      invite!(invited, a, b)
      self_leave!(leaving, b)
      leave_event = leaving |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b and &1["content"]["membership"] == "leave")) |> hd()

      response = delta(b, token, 0)

      assert leave_ids(response) == [leaving]
      assert anchored_event_id() == leave_event["event_id"]
    end

    test "the persisted last_event_id is the newest JOIN timeline event when it is the newest delivered event", %{a: a, b: b} do
      %{joined: joined, leaving: leaving, invited: invited, token: token} = anchor_world(a, b)
      self_leave!(leaving, b)
      invite!(invited, a, b)
      news = msg!(joined, a, "join news")

      _response = delta(b, token, 0)

      assert anchored_event_id() == news["event_id"]
    end

    # DELIBERATE amendment by story sync-stream-position (D3 / D6), old -> new: "the previous anchor is kept" is gone (the token has no anchor); what stays is "the token
    # is a new one", and the cursor rows of a delta without news are not rewritten (only rows whose value changed are written, D3).
    test "with nothing delivered the token is a new one and no cursor row is rewritten", %{b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      rows_before = cursor_rows(b)
      assert map_size(rows_before) >= 1

      response = delta(b, token, 0)

      assert response.since_token != token
      assert persisted() |> List.last() |> elem(1) == response.since_token
      assert cursor_rows(b) == rows_before, "nothing changed: the rows are the same"
    end

    test "a failing candidates / membership / stripped-state / leave-window read is 503 M_UNAVAILABLE, persists NO token, a retry with the SAME since is incremental", %{a: a, b: b} do
      for read <- [:membership_candidates, :latest_member_events, :invite_state_events, :leave_window_events] do
        anchor = anchor_room!(b)
        left = room!(a)
        invite!(left, a, b)
        join!(left, b)
        token = snapshot!(b, anchor)
        self_leave!(left, b)
        invited = room!(a)
        invite!(invited, a, b)
        before = persisted()

        :ets.insert(@ets, {{:fail, read}, true})

        assert {:error, {503, "M_UNAVAILABLE", _}} = Http.call_core(fn -> delta(b, token, 0) end), "#{read}: the whole sync is unavailable"
        assert persisted() == before, "#{read}: no token persisted on failure"
        assert_no_groups(b)

        :ets.delete(@ets, {:fail, read})
        retry = delta(b, token, 0)

        assert retry.fallback_to_initial == false, "#{read}: the stored token is still valid, the retry is incremental"
        assert leave_ids(retry) == [left] and invite_ids(retry) == [invited]
      end
    end

    test "the initial sync fails closed as well: a failing candidates or membership read is 503, no token persisted", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      msg!(anchor, b, "newest")
      before = persisted()

      for read <- [:membership_candidates, :latest_member_events, :invite_state_events] do
        :ets.insert(@ets, {{:fail, read}, true})
        assert {:error, {503, "M_UNAVAILABLE", _}} = Http.call_core(fn -> initial(b) end), to_string(read)
        :ets.delete(@ets, {:fail, read})
      end

      assert persisted() == before
    end

    test "a DB module WITHOUT the new reads is unavailable (503), never read as 'no memberships': initial and incremental", %{b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      use_db(NoNewReadsDB)
      before = persisted()

      assert {:error, {503, "M_UNAVAILABLE", _}} = Http.call_core(fn -> initial(b) end)
      assert {:error, {503, "M_UNAVAILABLE", _}} = Http.call_core(fn -> delta(b, token, 0) end)
      assert persisted() == before
      assert_no_groups(b)
    end
  end
  # ═══ code review cycle 1: Kassandra M-1 / L-1 / L-2, MINOR-8 ═══════════════════════════════════════════════

  describe "review cycle 1 M-1: the leave window ends at the row left_at" do
    test "a left row WITHOUT a leave event (failed event write), messages after it, then a ban: the window ends at the row's left_at, the ban is last", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      before_removal = msg!(room, a, "before the removal")

      # the removal whose leave event write FAILED: the member row ended, no event
      remove_member!(room, b)
      left_at = FakeDB.next_ts()
      FakeDB.set_left_at(room, b, left_at)

      after_one = msg!(room, a, "after the removal one")
      after_two = msg!(room, a, "after the removal two, the moderators discuss the ban")
      ban_event = ban!(room, b, a)

      response = delta(b, token, 0)
      entry = leave_room(response, room)

      assert entry, "the ban is a new leave"
      assert before_removal["event_id"] in tl_ids(entry)
      refute after_one["event_id"] in tl_ids(entry), "nothing after left_at"
      refute after_two["event_id"] in tl_ids(entry), "nothing after left_at"
      assert List.last(tl_ids(entry)) == ban_event["event_id"]
      # DELIBERATE amendment (D10): the call is `(room, after_pos, before_pos, after_ts, before_ts)`; the row's left_at is the clock bound, which can only shrink the window
      assert {^room, _after_pos, before_pos, _after_ts, window_end} = List.last(FakeDB.window_calls())
      assert window_end <= left_at, "the clock bound is the row's left_at, got #{window_end} for left_at #{left_at}"
      assert before_pos == ban_event["room_pos"], "and the position bound is L"
    end

    test "without a left_at (the module does not tell) or with a row that ended AFTER L the bound is still L", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      m = msg!(room, a, "m")
      self_leave!(room, b)
      FakeDB.set_left_at(room, b, FakeDB.next_ts() + 1_000_000)

      entry = leave_room(delta(b, token, 0), room)
      leave_event = room |> FakeDB.events() |> Enum.filter(&(&1["state_key"] == b)) |> Enum.max_by(& &1["origin_server_ts"])

      assert tl_ids(entry) == [m["event_id"], leave_event["event_id"]]
      # DELIBERATE amendment (D10), old -> new: the upper bound is L's POSITION; a row that ended AFTER L is only a (weaker) clock bound and never widens the window
      assert {^room, _after_pos, before_pos, _after_ts, _before_ts} = List.last(FakeDB.window_calls())
      assert before_pos == leave_event["room_pos"]
    end
  end

  describe "review cycle 2 I-1: the leave window starts at the row joined_at" do
    test "a join event older than the membership the row knows (a re-join whose join event write failed): the window starts at joined_at", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      while_away = msg!(room, a, "while the user was away")
      FakeDB.set_joined_at(room, b, FakeDB.next_ts())
      as_member = msg!(room, a, "after the re-join")
      self_leave!(room, b)

      entry = leave_room(delta(b, token, 0), room)

      refute while_away["event_id"] in tl_ids(entry), "nothing from before the membership the row knows"
      assert as_member["event_id"] in tl_ids(entry)
    end
  end

  describe "review cycle 1 L-1: no event after a removal reaches rooms.join" do
    test "incremental: a kick between the partition read and the fetch: the room is a NEW leave of this very sync, the message after the kick is nowhere", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      legit = msg!(room, a, "legit, before the kick")
      test_pid = self()

      :ets.insert(@ets, {:candidates_calls, 0})
      :ets.insert(@ets, {:candidates_hook, fn
        1 ->
          kick!(room, b, a)
          send(test_pid, {:after_kick, msg!(room, a, "posted AFTER the kick, before the room is fetched")})

        _ ->
          :ok
      end})

      response = delta(b, token, 0)
      assert_receive {:after_kick, after_kick}

      assert room not in join_ids(response) and room not in join_class(response), "the demoted room is not a join room"
      assert leave_ids(response) == [room], "it is delivered as a leave of THIS sync (the anchor passes the kick, so no later sync could)"
      entry = leave_room(response, room)
      assert legit["event_id"] in tl_ids(entry)
      refute after_kick["event_id"] in tl_ids(entry)
      refute after_kick["event_id"] in Enum.flat_map(response.rooms, &tl_ids/1)
      assert List.last(entry.timeline_events) |> then(&{&1.event_type, &1.state_key, &1.sender_id}) == {"m.room.member", b, a}
    end

    test "initial sync: a kick between the partition read and the fetch: the room is in no section and none of its events is delivered", %{a: a, b: b} do
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      other = anchor_room!(b)
      msg!(other, b, "another joined room")

      :ets.insert(@ets, {:candidates_calls, 0})
      :ets.insert(@ets, {:candidates_hook, fn
        1 ->
          kick!(room, b, a)
          msg!(room, a, "posted AFTER the kick")

        _ ->
          :ok
      end})

      response = initial(b)

      assert join_ids(response) == [other]
      assert join_class(response) == [other]
      assert leave_ids(response) == [] and invite_ids(response) == []
      refute Enum.any?(response.rooms, &(&1.room_id == room))
    end

    test "demotions that keep coming: after the bounded rebuilds the sync is 503 (no token, no pg group), never a silent drop; the retry delivers every leave", %{a: a, b: b} do
      anchor = anchor_room!(b)
      rooms = for _ <- 1..3, do: room!(a)

      for room <- rooms do
        invite!(room, a, b)
        join!(room, b)
      end

      token = snapshot!(b, anchor)
      for room <- rooms, do: msg!(room, a, "before the kicks")
      before = persisted()
      test_pid = self()

      # every read of the candidates is followed by the removal of one more room: the delivery never becomes stable
      :ets.insert(@ets, {:candidates_calls, 0})
      :ets.insert(@ets, {:candidates_hook, fn n when n in 1..3 ->
        room = Enum.at(rooms, n - 1)
        kick!(room, b, a)
        send(test_pid, {:late, room, msg!(room, a, "posted after the kick of #{n}")})

        _ ->
          :ok
      end})

      assert {:error, {503, "M_UNAVAILABLE", _}} = Http.call_core(fn -> delta(b, token, 0) end)
      assert persisted() == before, "no token persisted: the anchor did not pass any leave"
      assert_no_groups(b)

      late = for room <- rooms, into: %{}, do: (assert_receive({:late, ^room, ev}); {room, ev})

      # the retry (the world is stable now) delivers EVERY leave, bounded at its kick
      :ets.delete(@ets, :candidates_hook)
      retry = delta(b, token, 0)
      assert leave_ids(retry) == Enum.sort(rooms)
      assert join_class(retry) == [anchor]

      for room <- rooms do
        assert room in leave_ids(retry)
        refute late[room]["event_id"] in tl_ids(leave_room(retry, room))
      end
    end

    # DELIBERATE amendment by story sync-stream-position (D4), old -> new: a quiet room is not fetched at all any more (it costs no statement), so the fetch hook fires only for
    # rooms WITH news. Both rooms have news here; the first fetched room is kicked (a demotion during the fetch) and a newer message lands in the other: the demotion rebuilds the
    # delivery from fresh reads (heads included), so the kick is a leave of this very sync and the newer message is in the rebuilt timeline of the other room.
    test "N-1 case 1: a joined room is kicked during the fetch of another room that gets a newer message: the leave is delivered in the same sync", %{a: a, b: b} do
      anchor_b = anchor_room!(b)
      x = room!(a)
      invite!(x, a, b)
      join!(x, b)
      y = room!(a)
      invite!(y, a, b)
      join!(y, b)
      token = snapshot!(b, anchor_b)
      msg!(x, a, "news in x")
      msg!(y, a, "news in y")
      test_pid = self()

      # after the FIRST fetched room answered (no new events anywhere yet): the user is kicked from THAT room and a message
      # (newer than the kick) lands in the other one, which is fetched next and moves the anchor past the kick
      :ets.insert(@ets, {:after_fetch_hook, fn fetched ->
        other = Enum.find([x, y], &(&1 != fetched))
        kick!(fetched, b, a)
        send(test_pid, {:hooked, fetched, other, msg!(other, a, "newer than the kick")})
      end})

      response = delta(b, token, 0)
      assert_receive {:hooked, kicked, other, newer}

      assert kicked in leave_ids(response), "the kick is a NEW leave of this very sync (a later sync could not deliver it: the anchor passed it)"
      assert kicked not in join_class(response) and kicked not in join_ids(response)
      assert other in join_ids(response)
      assert newer["event_id"] in (response.rooms |> Enum.find(&(&1.room_id == other)) |> tl_ids())

      # and nothing is lost later either
      assert leave_ids(delta(b, response.since_token, 0)) == []
    end

    # B-1 (test review): the case of the ORIGINAL title, kept: the demoted room is QUIET (never fetched, D4) while the delivery fetched another room; the re-read of the partition
    # still compares the WHOLE join class of the build, so the kick is a leave of this very sync and nothing after it is delivered
    test "N-1 case 1 (quiet room): a joined room WITHOUT news is kicked during the fetch of another room: the leave is delivered in the same sync", %{a: a, b: b} do
      anchor_b = anchor_room!(b)
      quiet = room!(a)
      invite!(quiet, a, b)
      join!(quiet, b)
      busy = room!(a)
      invite!(busy, a, b)
      join!(busy, b)
      token = snapshot!(b, anchor_b)
      news = msg!(busy, a, "news in the busy room")
      test_pid = self()

      :ets.insert(@ets, {:after_fetch_hook, fn fetched ->
        kick!(quiet, b, a)
        send(test_pid, {:hooked, fetched, msg!(quiet, a, "posted after the kick")})
      end})

      response = delta(b, token, 0)
      assert_receive {:hooked, fetched, after_kick}

      assert fetched == busy, "fixture: only the room with news is fetched"
      assert quiet in leave_ids(response), "the kick of the quiet room is a NEW leave of this very sync"
      assert quiet not in join_class(response) and quiet not in join_ids(response)
      assert news["event_id"] in (response.rooms |> Enum.find(&(&1.room_id == busy)) |> tl_ids())
      refute after_kick["event_id"] in tl_ids(leave_room(response, quiet)), "nothing after the kick is delivered"
      assert leave_ids(delta(b, response.since_token, 0)) == []
    end

    test "N-1 (b): a delivered new invitation moves the anchor although no join room carries an event: a kick of a joined room during the fetch is still a leave of the same sync", %{a: a, b: b} do
      anchor = anchor_room!(b)
      x = room!(a)
      invite!(x, a, b)
      join!(x, b)
      token = snapshot!(b, anchor)
      # (story sync-stream-position: only a room with news is fetched, so the fetch hook needs one)
      msg!(x, a, "news in x")

      # an event-backed invitation stamped AHEAD of the clock (createRoom stamps its chain ahead, follow-up eu): the invitation is delivered whatever its timestamp
      invited = room!(a)
      invite!(invited, a, b, ts: FakeDB.next_ts() + 1_000_000)

      test_pid = self()

      :ets.insert(@ets, {:after_fetch_hook, fn fetched ->
        kick!(fetched, b, a)
        send(test_pid, {:kicked, fetched})
      end})

      response = delta(b, token, 0)
      assert_receive {:kicked, kicked}

      assert invited in invite_ids(response)
      assert kicked in leave_ids(response), "the removal during the fetch is delivered together with the invitation that moves the anchor"
      assert kicked not in join_class(response)
    end
  end

  # DELIBERATE amendment by story sync-stream-position (D6 / D4, premise "fc (f) moot"), old -> new: there is no anchor event and no anchor read any more. "an anchor event that is
  # gone is an initial-sync fallback" and "a failing anchor read is 503" described reads that no longer exist; what they guarded stays pinned: an event that is gone changes
  # nothing (the sync is incremental, the old leaves and invitations are not delivered again), and a failing READ of the incremental sync (now the head read) is the 503 of D16
  # with no token persisted.
  describe "review cycle 1 L-2: no anchor read: a gone last_event_id event changes nothing, a failing head read is 503" do
    test "a last_event_id event that is gone is no fallback: no rooms.leave of the old leaves, no re-delivered invitation", %{a: a, b: b} do
      anchor = anchor_room!(b)
      old_left = room!(a)
      invite!(old_left, a, b)
      join!(old_left, b)
      self_leave!(old_left, b)
      token = snapshot!(b, anchor)
      {_, _, anchor_event} = List.last(persisted())
      :ets.delete(@ets, {:event, anchor_event})

      response = delta(b, token, 0)

      assert response.fallback_to_initial == false, "the token carries no anchor event: nothing to fall back from"
      assert leave_ids(response) == [], "the old leave is not delivered again"
      assert old_left not in all_section_ids(response)
    end

    test "a failing head read is 503 M_UNAVAILABLE, persists no token and leaves no pg group; the retry is incremental", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      before = persisted()

      :ets.insert(@ets, {{:fail, :room_heads}, true})
      assert {:error, {503, "M_UNAVAILABLE", _}} = Http.call_core(fn -> delta(b, token, 0) end)
      assert persisted() == before
      assert_no_groups(b)

      :ets.delete(@ets, {:fail, :room_heads})
      assert delta(b, token, 0).fallback_to_initial == false
    end
  end

  describe "review cycle 1 MINOR-8: Task failures are re-raised" do
    setup %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room!(a)
      invite!(room, a, b)
      join!(room, b)
      token = snapshot!(b, anchor)
      # story sync-stream-position (D4): a quiet room is not fetched, so the failing fetch needs a room with news
      msg!(room, a, "news")
      {:ok, token: token}
    end

    test "an exception is re-raised with a stacktrace without argument lists (value-free logs)", %{b: b, token: token} do
      :ets.insert(@ets, {{:blow_up, :fetch_events_since}, :raise})

      {error, stacktrace} =
        try do
          delta(b, token, 0)
          flunk("must raise")
        rescue
          e in RuntimeError -> {e, __STACKTRACE__}
        end

      assert error.message == "simulated fetch failure"

      assert Enum.all?(stacktrace, fn
               {_m, _f, arity, _loc} -> is_integer(arity)
               {_fun, arity, _loc} -> is_integer(arity)
             end),
             "every frame carries an arity, not the argument list"

      assert_no_groups(b)
    end

    test "a throw and an exit are re-raised in the caller as well", %{b: b, token: token} do
      :ets.insert(@ets, {{:blow_up, :fetch_events_since}, :throw})
      assert catch_throw(delta(b, token, 0)) == :simulated_throw
      assert_no_groups(b)

      :ets.insert(@ets, {{:blow_up, :fetch_events_since}, :exit})
      assert catch_exit(delta(b, token, 0)) == :simulated_exit
      assert_no_groups(b)
    end
  end

  # ═══ story sync-wakeups-cluster-wide, D5: the registry of Horde lags behind a cluster-wide wake-up ═══════════════════════════
  #
  # Once the wake-ups of createRoom (the creator's `{:new_join}`) and `join_room` are cluster-wide, a sync task on ANOTHER node wakes within
  # milliseconds and rebuilds from the database. `fetch_delta_rooms/3` then asks the room process of the new room through
  # `room_registry_module().get_state/1` (the Horde via-name); Horde replicates registrations by delta-CRDT (sync_interval 300 ms) and
  # `RoomSupervisor.await_registry/3` waits only on the STARTING node, so the call exits `:noproc` there. Before D5 that dropped the room
  # silently from `rooms.join` while the anchor (`newest_event_id/2`) moved past its create / member / power-level events when another joined
  # room had a newer event: an incremental `/sync` never delivered them again. Without distribution the lag is simulated through the
  # `room_registry_module` seam: `LaggingRegistry` exits `:noproc` for the first N calls for a room (`{:registry_lag, room}` = N | :never) and
  # delegates to the real room process afterwards.
  #
  # D5 (the contract these tests pin, revised after code review cycle 1): a rebuild whose joined room has events but no resolvable process on this
  # node (1) first asks `rooms_db_module().get_room_status/1`: `archived` (an upgraded room: its process cannot start) or `:not_found` is DEAD at
  # once: no polling, not counted as unresolved, the anchor advances as before the story; (2) otherwise polls the registry in small steps, one
  # deadline of about one second per BUILD shared by the rooms, only for a room that has events to deliver, and delivers the room as soon as it
  # resolves; (3) when the bound has passed it starts the room ONCE on demand (`RoomSupervisor.start_room/1`, as the initial sync and
  # `full_state_rooms` do) and asks once more: a process that was really down is delivered in the SAME response; (4) only a room that is still
  # unresolvable (a transient start failure, a registry that does not answer) is not delivered, raises NO error and keeps the PREVIOUS anchor
  # (the token is a new one), so the next sync delivers its events. Timing bounds are loose for a loaded CI machine; the tightest is the
  # archived / not_found room (under 700 ms against the 1 s poll bound it must not pay) and the lower bound of the start-on-demand test (at least 800 ms:
  # the room is polled for the bound BEFORE it is started).

  defmodule LaggingRegistry do
    @moduledoc false
    @ets :smp_unit_db

    def get_state(room_id) do
      :ets.update_counter(@ets, {:registry_calls, room_id}, 1, {{:registry_calls, room_id}, 0})

      case :ets.lookup(@ets, {:registry_lag, room_id}) do
        [{_, :never}] ->
          noproc(room_id)

        [{key, n}] when is_integer(n) and n > 0 ->
          :ets.insert(@ets, {key, n - 1})
          noproc(room_id)

        _ ->
          Nebu.Matrix.Room.Server.get_state(room_id)
      end
    end

    def calls(room_id) do
      case :ets.lookup(@ets, {:registry_calls, room_id}) do
        [{_, n}] -> n
        [] -> 0
      end
    end

    # what GenServer.call/2 on a Horde via-name that this node's registry replica does not know yet exits with
    defp noproc(room_id), do: exit({:noproc, {GenServer, :call, [{:via, Horde.Registry, {Nebu.Matrix.Room.Registry, room_id}}, :get_state, 5_000]}})
  end

  # DELIBERATE amendment by story sync-stream-position (D13), old -> new: "the PREVIOUS anchor is kept" (one global anchor, so the other joined rooms' events were delivered again
  # and again, follow-up `bp`) became "an unresolved joined room keeps ITS cursor": the room is not delivered and its cursor is neither advanced nor created, every other room
  # advances and is NOT delivered again. The registry / start / bound behaviour of D5 (polling, the one start on demand, the shared deadline, dead rooms) is unchanged.
  describe "D5 - a joined room whose process is not yet resolvable" do
    # `fresh` = the room that was just created / joined on another node (its events are NEWER than the anchor of the token); `other` = a joined
    # room whose newer message makes the build's anchor jump past the events of `fresh`
    defp d5_world(a, b) do
      anchor = anchor_room!(b)
      other = room!(a)
      invite!(other, a, b)
      join!(other, b)
      token = snapshot!(b, anchor)
      old_anchor = anchored_event_id()

      fresh = room!(a)
      invite!(fresh, a, b)
      join!(fresh, b)
      news = msg!(other, a, "a newer event of another joined room")

      %{other: other, fresh: fresh, token: token, old_anchor: old_anchor, news: news}
    end

    # the registry lags for `room`: N calls (an integer) or forever (:never); installed AFTER the world and the first token exist
    defp lag!(room, n_or_never) do
      :ets.insert(@ets, {{:registry_lag, room}, n_or_never})
      Application.put_env(:event_dispatcher, :room_registry_module, LaggingRegistry)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :room_registry_module) end)
    end

    defp room_of(response, room), do: Enum.find(response.rooms, &(&1.room_id == room))

    test "a room whose registration lags a few calls is retried and delivered in the same response, the anchor advances", %{a: a, b: b} do
      %{other: other, fresh: fresh, token: token, news: news} = d5_world(a, b)
      lag!(fresh, 3)

      {response, ms} = timed(fn -> delta(b, token, 0) end)

      assert fresh in join_ids(response), "the new room is delivered, not dropped silently"
      assert other in join_ids(response)
      assert LaggingRegistry.calls(fresh) >= 4, "the registry was asked again until it answered (3 lagging calls + the answer)"
      create_id = fresh |> FakeDB.events() |> Enum.find(&(&1["event_type"] == "m.room.create")) |> Map.fetch!("event_id")
      assert create_id in tl_ids(room_of(response, fresh)), "its create event is in the timeline"
      assert anchored_event_id() == news["event_id"], "everything was delivered: the anchor is the newest event"
      assert ms < 1_500, "the retry is bounded (#{ms} ms)"
    end

    test "a room that never resolves keeps ITS cursor (none) and is delivered by the next sync once it resolves; the other room advances and is not delivered again", %{a: a, b: b} do
      %{other: other, fresh: fresh, token: token} = d5_world(a, b)
      lag!(fresh, :never)

      response = delta(b, token, 0)

      assert other in join_ids(response), "the other joined room is delivered as usual"
      refute fresh in join_ids(response), "the unresolvable room is not delivered"
      assert cursor(b, fresh) == nil, "its cursor was not created: the next sync delivers it from the start"
      assert cursor(b, other).pos == head_of(other), "every other room advances"

      # the registry catches up (Horde converged): the next sync, with the token of the first response, delivers the room with its events
      :ets.delete(@ets, {:registry_lag, fresh})
      second = delta(b, response.since_token, 0)

      assert fresh in join_ids(second), "the next sync delivers the room"
      assert room_of(second, other) == nil, "and the other room's events are NOT delivered again (follow-up bp)"
      fresh_events = fresh |> FakeDB.events() |> Enum.map(& &1["event_id"])
      create_id = fresh |> FakeDB.events() |> Enum.find(&(&1["event_type"] == "m.room.create")) |> Map.fetch!("event_id")
      assert create_id in tl_ids(room_of(second, fresh)), "its create event is delivered, not skipped (events of the room: #{length(fresh_events)})"
    end

    # dev step of story sync-stream-position, fix cycle 1 (code review cycle 0, MINOR-5: the dev's deviation 2.3): an unresolved joined room keeps its BASE, not the
    # stored value. Here the stored value is the one of a LOST response (request 1 advanced the room), and the retry with the previous token cannot resolve the room:
    # its cursor must go back to what the client really has, so the next sync delivers the events only the lost response carried.
    test "a retry with the PREVIOUS token while a joined room is unresolvable keeps that room at the client's base, not at the lost response's position; the next sync delivers its events", %{a: a, b: b} do
      %{other: other, token: token, news: news} = d5_world(a, b)
      base_pos = cursor(b, other).pos

      lost = delta(b, token, 0)
      assert other in join_ids(lost), "the lost response carried the news of the room"
      assert cursor(b, other).pos == head_of(other)

      lag!(other, :never)
      retry = delta(b, token, 0)
      assert retry.fallback_to_initial == false, "the previous token continues incrementally"
      refute other in join_ids(retry), "the room is unresolvable during the retry"
      assert cursor(b, other).pos == base_pos, "its cursor is back at the client's base (the lost response's position is not the base)"

      :ets.delete(@ets, {:registry_lag, other})
      after_retry = delta(b, retry.since_token, 0)
      assert other in join_ids(after_retry)
      assert news["event_id"] in tl_ids(room_of(after_retry, other)), "the event only the lost response carried is delivered"
    end

    # dev step of story sync-stream-position, fix cycle 1 (code review cycle 0, MINOR-1): an initial sync that drops a joined room (its fetch failed) writes NO
    # cursor row for it, so the next delta reads it as a newly joined room instead of only the events after a head the client never received
    test "an initial sync whose fetch of a joined room fails writes no cursor row for that room; the next delta delivers it as newly joined with its history", %{a: a, b: b} do
      dropped = room!(a)
      invite!(dropped, a, b)
      join!(dropped, b)
      msg!(dropped, a, "before the initial sync")
      kept = room!(a)
      invite!(kept, a, b)
      join!(kept, b)
      lag!(dropped, :never)

      first = initial(b)
      assert kept in join_ids(first)
      refute dropped in join_ids(first), "the room's fetch failed: it is not in the initial response"
      assert cursor(b, dropped) == nil, "and it has no cursor row"
      assert cursor(b, kept).pos == head_of(kept)

      :ets.delete(@ets, {:registry_lag, dropped})
      second = delta(b, first.since_token, 0)
      assert second.fallback_to_initial == false
      assert dropped in join_ids(second), "the next delta delivers the room"
      assert dropped in second.newly_joined_room_ids, "as a newly joined room (all of its room account data)"
      create_id = dropped |> FakeDB.events() |> Enum.find(&(&1["event_type"] == "m.room.create")) |> Map.fetch!("event_id")
      assert create_id in tl_ids(room_of(second, dropped)), "with its history, not only the events after the head"
      refute kept in join_ids(second)
    end

    # a room whose registry never answers although a start succeeds (the live process is found by start_room, get_state still exits :noproc): the
    # TRANSIENT-unresolved case, the only one that may keep the anchor (and so re-deliver the other room)
    test "a transiently unresolvable room is no failure: syncs in a row answer without error or fallback, its cursor is kept, the other room is delivered once", %{a: a, b: b} do
      %{other: other, fresh: fresh, token: token} = d5_world(a, b)
      lag!(fresh, :never)

      {first, ms} = timed(fn -> delta(b, token, 0) end)
      second = delta(b, first.since_token, 0)

      for response <- [first, second] do
        assert response.fallback_to_initial == false, "no initial-sync fallback"
        refute fresh in join_ids(response)
      end

      assert other in join_ids(first), "the other room is delivered by the first sync"
      assert room_of(second, other) == nil, "and NOT again by the second: the global anchor that re-delivered it is gone (bp)"
      assert cursor(b, fresh) == nil
      assert ms < 2_500, "bounded (#{ms} ms)"
      assert_no_groups(b)
    end

    test "an unresolvable room without events to deliver is never polled: no latency, the anchor advances", %{a: a, b: b} do
      anchor = anchor_room!(b)
      other = room!(a)
      invite!(other, a, b)
      join!(other, b)
      idle = room!(a)
      invite!(idle, a, b)
      join!(idle, b)
      token = snapshot!(b, anchor)
      lag!(idle, :never)
      news = msg!(other, a, "news in the other room only")

      {response, ms} = timed(fn -> delta(b, token, 0) end)

      assert other in join_ids(response)
      assert LaggingRegistry.calls(idle) == 0, "the registry is not asked for a room with nothing new"
      assert anchored_event_id() == news["event_id"]
      assert ms < 500, "no polling: #{ms} ms"
    end

    test "the retry is bounded per build: two unresolvable rooms with events cost about one second together", %{a: a, b: b} do
      %{other: other, fresh: fresh, token: token} = d5_world(a, b)
      second_fresh = room!(a)
      invite!(second_fresh, a, b)
      join!(second_fresh, b)
      msg!(other, a, "newest")
      lag!(fresh, :never)
      :ets.insert(@ets, {{:registry_lag, second_fresh}, :never})

      {response, ms} = timed(fn -> delta(b, token, 0) end)

      assert other in join_ids(response)
      assert Enum.sort(join_ids(response)) == Enum.sort([other]), "neither unresolvable room is delivered"
      assert cursor(b, fresh) == nil and cursor(b, second_fresh) == nil, "neither of them got a cursor"
      assert ms < 1_800, "one bound per build, not per room (#{ms} ms)"
    end

    # ── cycle 1: a room whose process stays DOWN (the process was stopped, or cannot start: an archived / upgraded room) ──

    # stops the real room process the way an upgrade / restart does; the registry then answers :noproc honestly
    defp kill_room!(room) do
      {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      :ok = Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
      assert :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end), "the room process is down"
    end

    # counts the registry calls per room (no lag entry: it delegates to the real room process)
    defp count_registry! do
      Application.put_env(:event_dispatcher, :room_registry_module, LaggingRegistry)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :room_registry_module) end)
    end

    test "a room whose process is down is polled for the bound, then started on demand and delivered in the same response", %{a: a, b: b} do
      %{other: other, fresh: fresh, token: token, news: news} = d5_world(a, b)
      kill_room!(fresh)
      count_registry!()

      {response, ms} = timed(fn -> delta(b, token, 0) end)

      assert fresh in join_ids(response), "the room was started on demand and delivered"
      assert other in join_ids(response)
      create_id = fresh |> FakeDB.events() |> Enum.find(&(&1["event_type"] == "m.room.create")) |> Map.fetch!("event_id")
      assert create_id in tl_ids(room_of(response, fresh))
      assert anchored_event_id() == news["event_id"], "everything was delivered: the anchor advances"
      assert LaggingRegistry.calls(fresh) >= 3, "the registry was polled before the start"
      assert ms >= 800, "the room is polled for the bound BEFORE it is started (#{ms} ms)"
      assert ms < 3_000, "bounded (#{ms} ms)"
    end

    for {label, flag} <- [{"an archived", :archived}, {"a not_found", :status_missing}] do
      test "#{label} room with a newer event is dead at once: not polled, not delivered, the anchor advances and nothing is re-delivered", %{a: a, b: b} do
        %{other: other, fresh: fresh, token: token, news: news} = d5_world(a, b)
        kill_room!(fresh)
        :ets.insert(@ets, {{unquote(flag), fresh}, true})
        count_registry!()

        {response, ms} = timed(fn -> delta(b, token, 0) end)

        assert other in join_ids(response)
        refute fresh in join_ids(response)
        assert LaggingRegistry.calls(fresh) == 1, "asked once, never polled"
        assert anchored_event_id() == news["event_id"], "a dead room does not pin the anchor"
        assert ms < 700, "no polling (#{ms} ms)"

        second = delta(b, response.since_token, 0)
        assert join_ids(second) == [], "the other room is NOT delivered again"
        assert second.fallback_to_initial == false
        assert_no_groups(b)
      end
    end

    test "a room that cannot be started (transient failure) is unresolved: no error, its cursor is kept (none), the next sync delivers it once it starts", %{a: a, b: b} do
      %{other: other, fresh: fresh, token: token} = d5_world(a, b)
      kill_room!(fresh)
      :ets.insert(@ets, {{:init_fail, fresh}, true})
      count_registry!()

      {response, ms} = timed(fn -> delta(b, token, 0) end)

      assert other in join_ids(response)
      refute fresh in join_ids(response)
      assert response.fallback_to_initial == false
      assert cursor(b, fresh) == nil, "unresolved after the start attempt: its cursor is kept (none)"
      assert ms < 3_000, "bounded (#{ms} ms)"

      :ets.delete(@ets, {:init_fail, fresh})
      second = delta(b, response.since_token, 0)

      create_id = fresh |> FakeDB.events() |> Enum.find(&(&1["event_type"] == "m.room.create")) |> Map.fetch!("event_id")
      assert fresh in join_ids(second)
      assert create_id in tl_ids(room_of(second, fresh)), "its events are delivered, not skipped"
    end

    # the upgrade freeze, modelled (not upgrade_room/2 itself): the old room is archived and its process stopped, its newest event is the
    # tombstone. Pre-existing gap, a follow-up row: the tombstone is never delivered to a member whose sync did not read the old room before it was
    # frozen; D5 only stops the frozen room from pinning the anchor of every sync.
    test "an upgraded (archived, stopped) room with a tombstone does not pin the anchor: the sync returns normally and nothing is re-delivered", %{a: a, b: b} do
      %{other: other, fresh: old_room, token: token, news: news} = d5_world(a, b)
      state!(old_room, a, "m.room.tombstone", "", %{"body" => "upgraded", "replacement_room" => "!new:test.local"})
      kill_room!(old_room)
      :ets.insert(@ets, {{:archived, old_room}, true})
      count_registry!()

      {response, ms} = timed(fn -> delta(b, token, 0) end)

      assert other in join_ids(response)
      refute old_room in join_ids(response)
      assert anchored_event_id() == news["event_id"], "the frozen room does not pin the anchor"
      assert ms < 700, "no polling (#{ms} ms)"
      assert join_ids(delta(b, response.since_token, 0)) == [], "no 1 req/s re-delivery loop"
    end
  end
end
