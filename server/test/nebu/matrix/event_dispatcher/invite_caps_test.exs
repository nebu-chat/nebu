defmodule Nebu.Matrix.EventDispatcher.InviteCapsTest do
  @moduledoc """
  Story `rate-limits-join-invite-create-room` (epic oauth-broker, follow-up `ey`), AC7 (unit, no PostgreSQL): the core seam of the
  pending-invitation caps (D6, D7, D8) with unit fakes of `invite_db_module` / `rooms_db_module` as in `create_room_invites_test.exs`
  (the scaffolding of that suite is copied, as the sibling suites did: `defmodule`s inside a test file cannot be shared).

  What is pinned here (the SQL itself, the real counts and the HTTP answers are pinned on the real DB in `invite_caps_db_test.exs` and
  `membership_write_limits_http_test.exs`; a fake that returns ready counts proves nothing about the SQL, so this suite only pins WHEN the
  count read is made, with WHAT, and what the core does with the answer):

    * the count read `InviteDB.pending_invite_counts(inviter_id, invitee_ids, limit)` (the name and shape are the story's D8) is called ONCE
      per createRoom that has invitees, with the DE-DUPLICATED list and `limit = max cap + 1`, AFTER every earlier check (shape, domain,
      creator lock-out, alias, existence), ONCE per `POST /invite` that would ADD a pending row, with `[invitee]`; and NOT: for a createRoom
      without invitees, for step 8 (`caps: :prechecked`: no second read per invitee), for the already-invited no-op, for a target who
      already holds a PENDING row (`pending_before`: no row is added), for a member / banned target (their refusals come first);
    * `k` of createRoom is the de-duplicated count: `inviter_pending + k > per_inviter` refuses, `pair_pending + 1 > per_pair` and
      `invitee_pending + 1 > per_invitee` refuse per invitee; first failure wins: inviter, then the invitees in list order, the pair
      before the invitee total; the answers are `403 M_FORBIDDEN` with the three fixed texts;
    * a failing (or raising) count read is FAIL CLOSED: `500`, before the room exists (createRoom) / before the write (`POST /invite`),
      and the log line is value-free (no user id).

  Names pinned by this suite (the story leaves them open, see the report of the ATDD step): the cap keys `:nebu, :invite_max_pending_per_inviter |
  _per_invitee | _per_pair` (the nine variables of D4), the read through `db_module_invite().pending_invite_counts/3`.

  The Admin force-add and `upgrade_room` (never capped, never reading the counts) are pinned over HTTP with a statement capture in
  `membership_write_limits_http_test.exs` (AC5 (f)): both need the real room / membership SQL.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Http

  @ets :invite_caps_test_db
  @server "test.local"
  @creator "@alice:test.local"
  @b "@bob:test.local"
  @c "@carol:test.local"
  @d "@dave:test.local"
  @cap_keys [:invite_max_pending_per_inviter, :invite_max_pending_per_invitee, :invite_max_pending_per_pair]
  @inviter_text "You have too many pending invitations: wait until some of them are accepted or declined"
  @pair_text "You have too many pending invitations to this user"
  @invitee_text "The invited user has too many pending invitations"

  # ─── FakeDB: ETS-backed Room DB (events with insertion sequence, eligibility reader, per-test failure switches) ───
  defmodule FakeDB do
    @ets :invite_caps_test_db

    def load_members(room_id) do
      case :ets.lookup(@ets, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(@ets, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(@ets, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(@ets, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(@ets, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(@ets, {:member, room_id, user_id})
      :ok
    end

    # `{:fail_insert, type}` -> persisting that event type fails (every event of the type).
    # `{:fail_invite_event, invitee}` -> persisting the INVITE member event of that invitee fails (the creator's join does not).
    def insert_event(%{"type" => type} = event) when is_binary(type) do
      invite_failure =
        type == "m.room.member" and get_in(event, ["content", "membership"]) == "invite" and
          :ets.lookup(@ets, {:fail_invite_event, event["state_key"]})

      cond do
        match?([{_, _}], :ets.lookup(@ets, {:fail_insert, type})) ->
          [{_, reason}] = :ets.lookup(@ets, {:fail_insert, type})
          {:error, reason}

        match?([{_, _}], invite_failure) ->
          [{_, reason}] = invite_failure
          {:error, reason}

        true ->
          # story sync-membership-partition (D9, DATA adaptation: observation only): `{:probe_mailbox, pid}` records how many
          # `{:new_invite, _}` wake-ups the subscribed process holds when an INVITE member event is persisted (the wake-ups of the
          # earlier invitees must not have been sent yet: they are sent after step 8 has succeeded)
          for [pid] <- :ets.match(@ets, {:probe_mailbox, :"$1"}),
              event["type"] == "m.room.member" and get_in(event, ["content", "membership"]) == "invite" do
            {:messages, messages} = Process.info(pid, :messages)
            :ets.insert(@ets, {{:mailbox_probe, event["state_key"]}, Enum.count(messages, &match?({:new_invite, _}, &1))})
          end

          seq = :ets.update_counter(@ets, :event_seq, {2, 1}, {:event_seq, 0})
          :ets.insert(@ets, {{:event, event["event_id"]}, Map.put(event, "__seq", seq)})
          :ok
      end
    end

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(@ets, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def update_room_name(room_id, name) do
      :ets.insert(@ets, {{:room_name, room_id}, name})
      :ok
    end

    def update_room_type(room_id, room_type) do
      :ets.insert(@ets, {{:room_type, room_id}, room_type})
      :ok
    end

    # `{:fail_delete_room, reason}` -> the orphan cleanup itself fails (the room stays, as after a correlated DB outage)
    def delete_room(room_id) do
      case :ets.lookup(@ets, :fail_delete_room) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          :ets.insert(@ets, {{:deleted_room, room_id}, true})
          :ets.delete(@ets, {:room, room_id})
          :ets.match_delete(@ets, {{:member, room_id, :_}, :_})
          :ets.match_delete(@ets, {{:alias, :_}, room_id})
          # DOCUMENTATION ONLY: the real Room.DB.delete_room/1 deletes the events and (story create-room-invites-direct, D8) the invitation
          # rows. That the real SQL does so (the FK room_invitations.room_id) is proven by the real-DB tests of
          # create_room_invites_http_test.exs (AC10), NOT by `assert_cleaned_up/2` of this file, which a fake that models D8 cannot falsify.
          :ets.match_delete(@ets, {{:invitation, room_id, :_}, :_})

          for [id, event] <- :ets.match(@ets, {{:event, :"$1"}, :"$2"}), event["room_id"] == room_id do
            :ets.delete(@ets, {:event, id})
          end

          :ok
      end
    end

    def get_room_create_event(room_id) do
      :ets.match(@ets, {{:event, :_}, :"$1"})
      |> Enum.map(fn [e] -> e end)
      |> Enum.find(&(&1["room_id"] == room_id and &1["type"] == "m.room.create"))
      |> case do
        nil -> {:error, :not_found}
        create -> {:ok, create["content"]}
      end
    end

    # The latest membership of the user = the newest m.room.member event the fake persisted (a join writes its own, an invite
    # writes its own): the real reader orders by origin_server_ts, the insertion sequence is its deterministic equivalent.
    def get_member_membership(room_id, user_id) do
      case :ets.lookup(@ets, :membership_read_error) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          latest =
            :ets.match(@ets, {{:event, :_}, :"$1"})
            |> Enum.map(fn [e] -> e end)
            |> Enum.filter(&(&1["room_id"] == room_id and &1["type"] == "m.room.member" and &1["state_key"] == user_id))
            |> Enum.max_by(& &1["__seq"], fn -> nil end)

          {:ok, latest && get_in(latest, ["content", "membership"])}
      end
    end

    # D3 (pinned by this suite): the ids of `user_ids` that are existing ACTIVE local accounts. Every call is recorded. Absent from
    # the answer = unknown or deactivated (`{:user_missing, id}` / `{:user_inactive, id}`); `:fail_eligibility` = the read fails.
    def invitable_local_users(user_ids) do
      :ets.insert(@ets, {{:eligibility_call, make_ref()}, user_ids})

      case :ets.lookup(@ets, :fail_eligibility) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          {:ok,
           Enum.filter(user_ids, fn id ->
             :ets.lookup(@ets, {:user_missing, id}) == [] and :ets.lookup(@ets, {:user_inactive, id}) == []
           end)}
      end
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}

    # Story moderation-routes-atomic-ban (AC16 (b), DATA adaptation of the fake): the invite events (Room.Server.write_invite/5) and kick /
    # ban / unban are written in the ONE transaction of Room.DB.apply_member_change/4, all or nothing: a failing event write (the
    # `{:fail_insert, type}` / `{:fail_invite_event, invitee}` switches of insert_event/1) or a failing reject (`:fail_reject`) applies
    # NOTHING; otherwise the event is stored (insert_event/1), the member row closed and the pending row rejected (FakeInviteDB, recorded).
    def apply_member_change(room_id, user_id, event, opts) do
      reject? = Keyword.get(opts, :reject_invitation, false)

      case :ets.lookup(@ets, :fail_reject) do
        [{_, reason}] when reject? ->
          {:error, reason}

        _ ->
          with :ok <- if(is_map(event), do: insert_event(event), else: :ok) do
            if Keyword.get(opts, :remove_member, false), do: delete_member(room_id, user_id)
            if reject?, do: :ok = Nebu.Matrix.EventDispatcher.InviteCapsTest.FakeInviteDB.reject_invitation(room_id, user_id)
            :ok
          end
      end
    end

    # story moderation-routes-atomic-ban (D2 (4)): the room process reads the pending invitation through its own db module; this fake's
    # one store of invitations is FakeInviteDB's table (`invited_at` is not modelled: no member event of this fake carries a timestamp)
    def pending_invitation(room_id, user_id) do
      case :ets.lookup(@ets, {:invitation, room_id, user_id}) do
        [{_, {_inviter, :pending}}] -> {:ok, 1}
        _ -> {:ok, nil}
      end
    end
  end

  defmodule FakeAliasDB do
    @ets :invite_caps_test_db

    def insert_room_alias(alias_str, room_id, _created_at) do
      case :ets.lookup(@ets, {:alias, alias_str}) do
        [] ->
          :ets.insert(@ets, {{:alias, alias_str}, room_id})
          :ok

        _existing ->
          {:error, :conflict}
      end
    end

    def lookup_alias(alias_str) do
      case :ets.lookup(@ets, {:alias, alias_str}) do
        [{_, room_id}] -> {:ok, room_id}
        [] -> {:error, :not_found}
      end
    end
  end

  # One row per (room, invitee) like the real table: `{inviter, :pending | :accepted | :rejected}`; every call is recorded.
  # `{:fail_invite_row, invitee}` -> the row write fails; `:fail_reject` -> every rejection fails.
  defmodule FakeInviteDB do
    @ets :invite_caps_test_db

    def insert_invitation(room_id, inviter, invitee) do
      :ets.insert(@ets, {{:invite_call, make_ref()}, {room_id, inviter, invitee}})

      case :ets.lookup(@ets, {:fail_invite_row, invitee}) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          :ets.insert(@ets, {{:invitation, room_id, invitee}, {inviter, :pending}})
          :ok
      end
    end

    def reject_invitation(room_id, invitee) do
      :ets.insert(@ets, {{:reject_call, make_ref()}, {room_id, invitee}})

      case :ets.lookup(@ets, :fail_reject) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          case :ets.lookup(@ets, {:invitation, room_id, invitee}) do
            [{key, {inviter, :pending}}] -> :ets.insert(@ets, {key, {inviter, :rejected}})
            _ -> :ok
          end

          :ok
      end
    end

    def accept_invitation(room_id, invitee) do
      case :ets.lookup(@ets, {:invitation, room_id, invitee}) do
        [{key, {inviter, :pending}}] -> :ets.insert(@ets, {key, {inviter, :accepted}})
        _ -> :ok
      end

      :ok
    end

    def pending_invite?(room_id, invitee) do
      {:ok, match?([{_, {_, :pending}}], :ets.lookup(@ets, {:invitation, room_id, invitee}))}
    end

    # D8 (the seam of the story: `invite_db_module`): the bounded counts of PENDING rows, modelled on the fake's own table (one row per
    # (room, invitee), `{inviter, state}`); every call is recorded as {inviter, invitee_ids, limit}.
    # `{:fail_counts, reason}` -> `{:error, reason}`, `{:fail_counts, :raise}` -> the read raises.
    def pending_invite_counts(inviter, invitee_ids, limit) do
      :ets.insert(@ets, {{:count_call, make_ref()}, {inviter, invitee_ids, limit}})

      case :ets.lookup(@ets, :fail_counts) do
        [{_, :raise}] ->
          raise "atdd: the count read raised"

        [{_, reason}] ->
          {:error, reason}

        [] ->
          pending = :ets.match(@ets, {{:invitation, :"$1", :"$2"}, {:"$3", :pending}})
          bound = fn n -> min(n, limit) end

          invitees =
            Map.new(invitee_ids, fn id ->
              {id,
               %{
                 total: bound.(Enum.count(pending, fn [_room, invitee, _by] -> invitee == id end)),
                 from_inviter: bound.(Enum.count(pending, fn [_room, invitee, by] -> invitee == id and by == inviter end))
               }}
            end)

          {:ok, %{inviter: bound.(Enum.count(pending, fn [_room, _invitee, by] -> by == inviter end)), invitees: invitees}}
      end
    end

    def get_pending_invite_rooms_for_user(user_id) do
      {:ok, :ets.match(@ets, {{:invitation, :"$1", user_id}, {:_, :pending}}) |> List.flatten()}
    end

    def get_declined_invite_rooms_for_user(user_id) do
      {:ok, :ets.match(@ets, {{:invitation, :"$1", user_id}, {:_, :rejected}}) |> List.flatten()}
    end
  end

  # the directory flag goes through admin_db_module().update_room_visibility/2 (visibility "public"): accepted, not asserted here
  defmodule FakeAdminDB do
    def update_room_visibility(_room_id, _visibility), do: :ok
  end

  defmodule SpyAuditWriter do
    @ets :invite_caps_test_db

    def log(actor, action, target_type, target_id, metadata, outcome, _detail \\ nil) do
      :ets.insert(@ets, {{:audit, make_ref()}, {actor, action, target_type, target_id, metadata, outcome}})
      :ok
    end
  end

  # Security (Kassandra): no path provisions a `users` row for an invitee. Every upsert is recorded.
  defmodule SpyUserStore do
    @ets :invite_caps_test_db

    def upsert_user(user_id, role) do
      :ets.insert(@ets, {{:upsert, make_ref()}, {user_id, role}})
      {:ok, user_id}
    end
  end

  setup do
    if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    :ets.new(@ets, [:named_table, :public, :set])

    snapshot =
      for {app, key} <- [
            {:room_manager, :db_module},
            {:event_dispatcher, :messages_db_module},
            {:event_dispatcher, :rooms_db_module},
            {:event_dispatcher, :alias_db_module},
            {:event_dispatcher, :invite_db_module},
            {:event_dispatcher, :admin_db_module},
            {:event_dispatcher, :user_store_module},
            {:compliance, :audit_writer}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :alias_db_module, FakeAliasDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB)
    Application.put_env(:event_dispatcher, :user_store_module, SpyUserStore)
    Nebu.Test.ServerName.pin!(@server)
    Application.put_env(:compliance, :audit_writer, SpyAuditWriter)

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
      if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)
    end)

    :ok
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp stream(user_id), do: Http.stream(user_id)
  defp track_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        on_exit(fn -> if Process.alive?(pid), do: (try do GenServer.stop(pid, :normal, 5_000) catch :exit, _ -> :ok end) end)

      _ ->
        :ok
    end
  end

  defp req(attrs), do: struct(Core.CreateRoomRequest, Keyword.merge([creator_id: @creator], attrs))

  defp create(attrs) do
    result = Http.call_core(fn -> Server.create_room(req(attrs), stream(@creator)) end)

    case result do
      {:ok, resp} -> track_room(resp.room_id)
      _ -> :ok
    end

    result
  end

  defp create_ok(attrs, label \\ "create") do
    case create(attrs) do
      {:ok, resp} -> resp
      other -> flunk("#{label}: expected the room to be created, got #{inspect(other)}")
    end
  end

  defp room_snapshot,
    do: {Enum.sort(:ets.match(@ets, {{:room, :"$1"}, :_})), Enum.sort(:ets.match(@ets, {{:deleted_room, :"$1"}, true}))}

  defp deleted_rooms, do: :ets.match(@ets, {{:deleted_room, :"$1"}, true}) |> List.flatten()
  defp invite_calls, do: :ets.match(@ets, {{:invite_call, :_}, :"$1"}) |> List.flatten()
  defp eligibility_calls, do: :ets.match(@ets, {{:eligibility_call, :_}, :"$1"}) |> Enum.map(fn [ids] -> ids end)
  defp invitation_rows(room_id), do: :ets.match(@ets, {{:invitation, room_id, :"$1"}, :"$2"}) |> Enum.map(fn [who, state] -> {who, state} end) |> Enum.sort()
  defp invitation_state(room_id, user), do: (case :ets.lookup(@ets, {:invitation, room_id, user}) do [{_, {_inviter, state}}] -> state; [] -> :none end)

  defp events(room_id) do
    :ets.match(@ets, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.filter(&(&1["room_id"] == room_id))
  end

  # the invite member events of the room, in insertion order
  defp invite_events(room_id),
    do:
      events(room_id)
      |> Enum.filter(&(&1["type"] == "m.room.member" and get_in(&1, ["content", "membership"]) == "invite"))
      |> Enum.sort_by(& &1["__seq"])

  defp invited_users(room_id), do: room_id |> invite_events() |> Enum.map(& &1["state_key"])
  defp capture_create(attrs) do
    ref = make_ref()
    log = capture_log(fn -> send(self(), {ref, create(attrs)}) end)
    assert_received {^ref, result}
    {log, result}
  end

  setup do
    snapshot = for key <- @cap_keys, do: {key, Application.fetch_env(:nebu, key)}
    for key <- @cap_keys, do: Application.delete_env(:nebu, key)

    on_exit(fn ->
      for {key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(:nebu, key, value)
          :error -> Application.delete_env(:nebu, key)
        end
      end
    end)

    :ok
  end

  # ─── extra helpers ───────────────────────────────────────────────────────────

  defp count_calls, do: :ets.match(@ets, {{:count_call, :_}, :"$1"}) |> List.flatten()
  defp put_cap(key, value), do: Application.put_env(:nebu, key, value)

  # `n` PENDING rows of `inviter` to `invitee` in synthetic rooms (rows older than the request: what an earlier invitation left behind)
  defp seed_pending(inviter, invitee, n) do
    for _ <- 1..n//1, do: :ets.insert(@ets, {{:invitation, "!seed#{rand()}:#{@server}", invitee}, {inviter, :pending}})
    :ok
  end

  defp invite_req(room, inviter, invitee), do: %Core.InviteUserRequest{room_id: room, inviter_id: inviter, invitee_id: invitee}
  defp invite_user(room, inviter, invitee), do: Http.call_core(fn -> Server.invite_user(invite_req(room, inviter, invitee), stream(inviter)) end)

  defp forbidden(text), do: {:error, {403, "M_FORBIDDEN", text}}

  # the number of rooms a refused request must NOT have created, and the invitation rows it must not have written
  defp nothing_written?(before_rooms, calls_before), do: room_snapshot() == before_rooms and invite_calls() == calls_before

  # ═══ the count read: when, with what ═════════════════════════════════════════════

  describe "AC7 - createRoom reads the counts ONCE, with the de-duplicated list" do
    test "invite [B, B, C, B] is ONE read by the creator over [B, C] (not four, not three), with limit >= max cap + 1 (501 with the defaults)" do
      resp = create_ok(invite: [@b, @b, @c, @b])

      assert [{@creator, invitees, limit}] = count_calls()
      assert limit >= 501, "the bound is at least max cap + 1 (a larger bound is allowed), got #{limit}"
      assert invitees == [@b, @c], "the de-duplicated list, first occurrence wins, list order kept"
      assert invited_users(resp.room_id) == [@b, @c]
    end

    test "step 8 does NOT read again (caps: :prechecked): three invitees are still ONE read in total, and the rows are written" do
      resp = create_ok(invite: [@b, @c, @d])

      assert length(count_calls()) == 1
      assert length(invite_calls()) == 3
      assert invitation_rows(resp.room_id) |> Enum.map(&elem(&1, 0)) == [@b, @c, @d]
    end

    test "the limit follows the configured caps: at least max(cap) + 1" do
      put_cap(:invite_max_pending_per_inviter, 5)
      put_cap(:invite_max_pending_per_invitee, 2)
      put_cap(:invite_max_pending_per_pair, 1)
      create_ok(invite: [@b])

      assert [{@creator, [@b], limit}] = count_calls()
      assert limit >= 6, "at least max(cap) + 1, got #{limit}"
    end

    test "a createRoom WITHOUT invitees (absent, nil, []) makes no count read at all" do
      for attrs <- [[], [invite: nil], [invite: []], [is_direct: true]] do
        create_ok(attrs)
      end

      assert count_calls() == []

      # positive control: with one invitee the same path DOES read (the matcher and the seam see reads)
      create_ok(invite: [@b])
      assert length(count_calls()) == 1
    end

    test "the read comes AFTER every earlier check: an unknown invitee (404), a foreign one (403), a malformed id and 51 entries (400) never reach it" do
      :ets.insert(@ets, {{:user_missing, @c}, true})

      for {attrs, status} <- [
            {[invite: [@b, @c]], 404},
            {[invite: [@b, "@x:other.example"]], 403},
            {[invite: ["bob"]], 400},
            {[invite: for(n <- 1..51, do: "@n#{n}:#{@server}")], 400}
          ] do
        assert {:error, {^status, _, _}} = create(attrs)
      end

      assert count_calls() == [], "no count read before the invitees passed every earlier check"
      assert eligibility_calls() != [], "the existence read DID happen (the matcher sees reads at all)"

      create_ok(invite: [@b])
      assert length(count_calls()) == 1, "positive control: a fully valid request reads the counts once"
    end
  end

  describe "AC7 - POST /invite reads the counts only when it would ADD a pending row" do
    test "a first invitation is ONE read by the inviter over [invitee] with a limit of at least 501" do
      room = create_ok(preset: "private_chat").room_id

      assert {:ok, %Core.InviteUserResponse{}} = invite_user(room, @creator, @b)
      assert [{@creator, [@b], limit}] = count_calls()
      assert limit >= 501
      assert invitation_state(room, @b) == :pending
    end

    test "the already-invited no-op (pending row AND latest membership invite) makes NO read and writes nothing" do
      room = create_ok(invite: [@b]).room_id
      reads = length(count_calls())
      assert reads == 1, "positive control: the createRoom invitation itself WAS read"
      calls = invite_calls()
      events = length(invite_events(room))

      assert {:ok, %Core.InviteUserResponse{}} = invite_user(room, @creator, @b)

      assert length(count_calls()) == reads, "no read for the no-op"
      assert invite_calls() == calls, "nothing written"
      assert length(invite_events(room)) == events
    end

    test "a target who already holds a PENDING row (a row-only / legacy invitation, no invite event) makes NO read and is written (pending_before: no row is added)" do
      room = create_ok(preset: "private_chat").room_id
      :ets.insert(@ets, {{:invitation, room, @b}, {@creator, :pending}})

      # a cap of 1 per pair and a second pending row of the pair elsewhere: a NEW row would be refused, this one adds none
      put_cap(:invite_max_pending_per_pair, 1)
      seed_pending(@creator, @b, 1)

      assert {:ok, %Core.InviteUserResponse{}} = invite_user(room, @creator, @b)
      assert count_calls() == [], "pending_before: no read, always proceeds"
      assert [_] = invite_events(room) |> Enum.filter(&(&1["state_key"] == @b)), "the invite event was written for the legacy invitation"

      # positive control: a NEW target of the same room (no pending row) IS read (and the pair cap of the creator does not apply to C)
      assert {:ok, %Core.InviteUserResponse{}} = invite_user(room, @creator, @c)
      assert [{@creator, [@c], _limit}] = count_calls()
    end

    test "a MEMBER target and a BANNED target are refused by their own checks, before any read" do
      room = create_ok(preset: "private_chat").room_id

      member = invite_user(room, @creator, @creator)
      assert {:error, {403, "M_FORBIDDEN", "The invited user is already in this room"}} = member

      :ok = FakeDB.insert_event(%{"event_id" => "$ban#{rand()}", "room_id" => room, "sender" => @creator, "type" => "m.room.member", "state_key" => @c, "content" => %{"membership" => "ban"}, "origin_server_ts" => System.system_time(:millisecond)})
      banned = invite_user(room, @creator, @c)
      assert {:error, {403, "M_FORBIDDEN", "The invited user is banned from this room"}} = banned

      assert count_calls() == []

      # positive control: a plain new target of the same room IS read
      assert {:ok, %Core.InviteUserResponse{}} = invite_user(room, @creator, @d)
      assert [{@creator, [@d], _limit}] = count_calls()
    end

    test "caps are the LAST check of POST /invite: non-member inviter, low invite level, foreign and unknown invitee each get their OWN error and no read" do
      # every cap is at its limit for the creator, so that a read (if it happened) would end in a cap 403
      put_cap(:invite_max_pending_per_inviter, 1)
      seed_pending(@creator, @d, 1)
      room = create_ok(preset: "private_chat", power_level_content_override: %{"invite" => 50}).room_id
      :ok = Nebu.Matrix.Room.Server.join(room, @c)

      # not a member of the room
      assert {:error, {403, _, not_member}} = invite_user(room, @d, @b)
      refute not_member =~ "pending invitations", "its own error, not a cap: #{not_member}"
      assert not_member =~ ~r/not a member/i
      # a member below the invite level (50)
      assert {:error, {403, _, low_level}} = invite_user(room, @c, @b)
      refute low_level =~ "pending invitations", "its own error, not a cap: #{low_level}"
      # a foreign invitee (local domain check) and an unknown / deactivated one (existence read)
      assert {:error, {403, "M_FORBIDDEN", foreign}} = invite_user(room, @creator, "@far:other.example")
      refute foreign =~ "pending invitations"
      :ets.insert(@ets, {{:user_missing, @b}, true})
      assert {:error, {404, "M_NOT_FOUND", _}} = invite_user(room, @creator, @b)

      assert count_calls() == [], "none of the earlier checks reads the counts"
      assert eligibility_calls() != [], "the existence read DID happen (the matcher sees reads)"

      # positive control: a valid new target at the cap IS read and refused by the inviter cap
      assert forbidden(@inviter_text) == invite_user(room, @creator, "@erin:#{@server}")
      assert length(count_calls()) == 1
    end

    test "a re-arm of a DECLINED row adds a pending row, so it IS read and checked (the cap decides)" do
      room = create_ok(invite: [@b]).room_id
      :ets.insert(@ets, {{:invitation, room, @b}, {@creator, :rejected}})
      :ets.insert(@ets, {{:event, "$leave#{rand()}"}, %{"event_id" => "$l", "room_id" => room, "sender" => @b, "type" => "m.room.member", "state_key" => @b, "content" => %{"membership" => "leave"}, "__seq" => 10_000}})
      put_cap(:invite_max_pending_per_pair, 1)
      seed_pending(@creator, @b, 1)
      reads = length(count_calls())

      assert forbidden(@pair_text) == invite_user(room, @creator, @b)
      assert length(count_calls()) == reads + 1, "the re-arm IS read"
      assert invitation_state(room, @b) == :rejected, "the refused re-arm did not touch the row"
    end
  end

  # ═══ the decision ═══════════════════════════════════════════════════════════════

  describe "AC7 - the three caps and their boundaries (createRoom: all or nothing)" do
    test "per inviter: pending + k > cap refuses, pending + k == cap passes; k is the DE-DUPLICATED count" do
      put_cap(:invite_max_pending_per_inviter, 5)
      seed_pending(@creator, @d, 3)

      before = room_snapshot()
      calls = invite_calls()
      assert forbidden(@inviter_text) == create(invite: [@b, @c, @d, "@erin:#{@server}"])
      assert nothing_written?(before, calls), "refused: no room, no row"

      # 3 pending + 3 distinct ([b, b, b, c, d]) = 6 > 5; [b, b, b, c] = k 2 -> 5 <= 5
      assert forbidden(@inviter_text) == create(invite: [@b, @b, @b, @c, @d])
      assert {:ok, _} = create(invite: [@b, @b, @b, @c])
    end

    test "per inviter: a single invitee with pending == cap is refused, pending == cap - 1 passes (the boundary)" do
      put_cap(:invite_max_pending_per_inviter, 4)
      seed_pending(@creator, @d, 3)
      assert {:ok, _} = create(invite: [@b])
      assert forbidden(@inviter_text) == create(invite: [@c])
    end

    test "per pair: pair_pending + 1 > cap refuses (at the cap), cap - 1 passes; another inviter's rows do not count towards the pair" do
      put_cap(:invite_max_pending_per_pair, 3)
      seed_pending(@creator, @b, 2)
      seed_pending(@d, @c, 3)

      assert {:ok, _} = create(invite: [@b])
      assert forbidden(@pair_text) == create(invite: [@b]), "3 pending of the pair now"
      assert {:ok, _} = create(invite: [@c]), "the rows of D to C are not the creator's pair"
    end

    test "per invitee: invitee_pending + 1 > cap refuses, over EVERY inviter's rows; cap - 1 passes" do
      put_cap(:invite_max_pending_per_invitee, 3)
      seed_pending(@d, @b, 2)
      assert {:ok, _} = create(invite: [@b])
      assert forbidden(@invitee_text) == create(invite: [@b])
    end

    test "the same three caps decide POST /invite (the first failure wins there as well)" do
      put_cap(:invite_max_pending_per_pair, 1)
      room = create_ok(preset: "private_chat").room_id
      seed_pending(@creator, @b, 1)
      assert forbidden(@pair_text) == invite_user(room, @creator, @b)
      assert invitation_state(room, @b) == :none

      put_cap(:invite_max_pending_per_pair, 10)
      put_cap(:invite_max_pending_per_invitee, 1)
      assert forbidden(@invitee_text) == invite_user(room, @creator, @b)

      put_cap(:invite_max_pending_per_invitee, 100)
      put_cap(:invite_max_pending_per_inviter, 1)
      assert forbidden(@inviter_text) == invite_user(room, @creator, @b)

      put_cap(:invite_max_pending_per_inviter, 500)
      assert {:ok, _} = invite_user(room, @creator, @c), "positive control: below every cap the invitation passes"
    end
  end

  describe "AC7 - first failure wins (D6): inviter, then the invitees in list order, the pair before the invitee total" do
    setup do
      put_cap(:invite_max_pending_per_inviter, 100)
      put_cap(:invite_max_pending_per_invitee, 2)
      put_cap(:invite_max_pending_per_pair, 1)
      # B: at the invitee cap (2 rows of D); C: at the pair cap with the creator (and one more row of D: at the invitee cap too)
      seed_pending(@d, @b, 2)
      seed_pending(@creator, @c, 1)
      seed_pending(@d, @c, 1)
      :ok
    end

    test "[B, C]: B violates the invitee total first (list order), [C, B]: C violates the PAIR first" do
      assert forbidden(@invitee_text) == create(invite: [@b, @c])
      assert forbidden(@pair_text) == create(invite: [@c, @b])
    end

    test "an invitee that violates BOTH is answered with the pair text; the inviter cap beats both" do
      assert forbidden(@pair_text) == create(invite: [@c])

      put_cap(:invite_max_pending_per_inviter, 1)
      assert forbidden(@inviter_text) == create(invite: [@c]), "the creator holds 1 pending row = the inviter cap"
    end
  end

  # ═══ fail closed ═════════════════════════════════════════════════════════════════

  describe "AC7 - a failing count read is fail-closed: 500, nothing written, value-free log" do
    test "createRoom: {:error, _} and a raise are both 500 BEFORE the room exists; no room, no row, no wake-up; the log names no user id" do
      for failure <- [:db_down, :raise] do
        :ets.insert(@ets, {:fail_counts, failure})
        :pg.join("user:#{@b}", self())
        before = room_snapshot()
        calls = invite_calls()

        {log, result} = capture_create(invite: [@b])

        assert {:error, {500, _, _}} = result, "#{failure}: #{inspect(result)}"
        assert nothing_written?(before, calls), "#{failure}: no room (not even a created-then-cleaned-up one), no row"
        assert deleted_rooms() == [], "#{failure}: the read failed before the room existed: nothing to clean up"
        refute_receive {:new_invite, _}, 50
        assert log =~ "[error]", "#{failure}: the failure is logged at ERROR"
        refute log =~ "alice", "#{failure}: no user id in the log"
        refute log =~ "bob", "#{failure}: no user id in the log"
      end
    end

    test "POST /invite: a failing read is 500 BEFORE the write: no insert_invitation call, no invite event, no wake-up; value-free log" do
      room = create_ok(preset: "private_chat").room_id
      :ets.insert(@ets, {:fail_counts, :db_down})
      :pg.join("user:#{@b}", self())
      calls = invite_calls()
      events = length(invite_events(room))

      log = capture_log(fn -> send(self(), {:result, invite_user(room, @creator, @b)}) end)
      assert_received {:result, result}

      assert {:error, {500, _, _}} = result
      assert invite_calls() == calls
      assert length(invite_events(room)) == events
      assert invitation_state(room, @b) == :none
      refute_receive {:new_invite, _}, 50
      assert log =~ "[error]"
      refute log =~ "alice"
      refute log =~ "bob"
    end
  end
end
