defmodule Nebu.Matrix.EventDispatcher.CreateRoomInvitesTest do
  @moduledoc """
  Story `create-room-invites-direct` (epic oauth-broker, follow-up `eb`), unit part (no PostgreSQL): `Server.create_room/2` processes
  `invite`, `invite_3pid` and `is_direct` (D3, D5-D10, D14), writes one signed `m.room.member` invite event per invitee after the
  whole step 4-7 chain (D2, D8), gives the invitees of a `trusted_private_chat` the creator's level (D9) and refuses the creator
  lock-out that an `invite` level would cause (D10). The HTTP side (real users rows, `POST /invite`, `/join` after the invite, `/sync`,
  the real `Room.DB.delete_room/1` with an invitation row) is `create_room_invites_http_test.exs`; the shared invite path of
  `POST /rooms/{roomId}/invite` is `invite_user_test.exs`; the interim sync guard (D11) is `sync_test.exs`.

  Conventions (as the siblings `create_room_presets_test.exs` and `create_room_input_validation_test.exs`):

    * Every rejection is asserted through `Nebu.Matrix.Http.call_core/1` = the public `{:error, {http_status, errcode, message}}` mapping,
      and a rejected request must leave NO room behind (no new room, not even a created-then-cleaned-up one) and, for the validation
      cases, must not have written to any invitation table.
    * Requests are built with `struct/2`, never with a `%Core.CreateRoomRequest{invite: ...}` literal: the keys `invite` /
      `invite_3pid` do not exist yet, a literal would abort the compilation of the whole file. The first test of this file guards
      that the struct carries the new keys, because `struct/2` silently drops unknown ones.
    * The FakeDB stamps every inserted event with an insertion sequence (`__seq`). ORDER is asserted on `__seq`; the timestamp chain is
      asserted as "strictly greater than the predecessor in `__seq` order" (what makes `ORDER BY origin_server_ts DESC` deterministic).
    * The fakes model the real thing where the behaviour depends on it: `Room.Server.join/2` writes its own join event, the latest
      membership (`get_member_membership/2`) is the newest `m.room.member` event, `delete_room/1` deletes the events, the members, the
      aliases AND the invitation rows of the room (D8: the real SQL is pinned by the real-DB test of the HTTP file), a refused invitee
      is simply not returned by the eligibility reader (unknown and deactivated users look the same to the core, as the story says).
    * No helper returns "the" event of a type from the ETS :set: events are counted, looked up by content or by event id.
    * `async: false` - Horde, `:pg`, `Application.put_env` and the `:NebuTxnDedup` ETS table are process-global.

  Names the story leaves open are pinned HERE (see the report of the ATDD step): the eligibility reader of the rooms DB seam is
  `invitable_local_users(user_ids) :: {:ok, [user_id]} | {:error, term}` (the ids that are existing ACTIVE local accounts, any order).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Http

  @ets :create_room_invites_test_db
  @server "test.local"
  @creator "@alice:test.local"
  @b "@bob:test.local"
  @c "@carol:test.local"

  # ─── FakeDB: ETS-backed Room DB (events with insertion sequence, eligibility reader, per-test failure switches) ───
  defmodule FakeDB do
    @ets :create_room_invites_test_db

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
            if reject?, do: :ok = Nebu.Matrix.EventDispatcher.CreateRoomInvitesTest.FakeInviteDB.reject_invitation(room_id, user_id)
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
    @ets :create_room_invites_test_db

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
    @ets :create_room_invites_test_db

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

    # story rate-limits-join-invite-create-room (DATA adaptation of the fake, D8): the bounded counts of the PENDING rows of THIS fake's table
    # ({inviter, :pending} per (room, invitee)), like the real InviteDB.pending_invite_counts/3 (its SQL is pinned in room/invite_caps_db_test.exs)
    def pending_invite_counts(inviter, invitee_ids, limit) do
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
    @ets :create_room_invites_test_db

    def log(actor, action, target_type, target_id, metadata, outcome, _detail \\ nil) do
      :ets.insert(@ets, {{:audit, make_ref()}, {actor, action, target_type, target_id, metadata, outcome}})
      :ok
    end
  end

  # Security (Kassandra): no path provisions a `users` row for an invitee. Every upsert is recorded.
  defmodule SpyUserStore do
    @ets :create_room_invites_test_db

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
  defp user(n), do: "@u#{n}:#{@server}"

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

  # `{status, errcode}` and nothing left behind: no new room, no created-then-cleaned-up room, no invitation row, no invite call
  defp assert_rejected(attrs, errcode, label, status \\ 400) do
    before = room_snapshot()
    # relative, not absolute: a test may create a successful room (with invitation calls) before the rejected request
    calls_before = invite_calls()

    case create(attrs) do
      {:error, {^status, ^errcode, message}} ->
        assert is_binary(message) and message != "", "#{label}: a fixed, non-empty message"
        assert room_snapshot() == before, "#{label}: rejected BEFORE a room is created (no new room, no create-then-cleanup)"
        assert invite_calls() == calls_before, "#{label}: no invitation row was written"
        message

      {:ok, resp} ->
        flunk("#{label}: expected #{status} #{errcode}, but the room #{resp.room_id} was created")

      other ->
        flunk("#{label}: expected #{status} #{errcode}, got #{inspect(other)}")
    end
  end

  defp room_snapshot,
    do: {Enum.sort(:ets.match(@ets, {{:room, :"$1"}, :_})), Enum.sort(:ets.match(@ets, {{:deleted_room, :"$1"}, true}))}

  defp deleted_rooms, do: :ets.match(@ets, {{:deleted_room, :"$1"}, true}) |> List.flatten()
  defp invite_calls, do: :ets.match(@ets, {{:invite_call, :_}, :"$1"}) |> List.flatten()
  defp reject_calls, do: :ets.match(@ets, {{:reject_call, :_}, :"$1"}) |> List.flatten()
  defp eligibility_calls, do: :ets.match(@ets, {{:eligibility_call, :_}, :"$1"}) |> Enum.map(fn [ids] -> ids end)
  defp invitation_rows(room_id), do: :ets.match(@ets, {{:invitation, room_id, :"$1"}, :"$2"}) |> Enum.map(fn [who, state] -> {who, state} end) |> Enum.sort()
  defp invitation_state(room_id, user), do: (case :ets.lookup(@ets, {:invitation, room_id, user}) do [{_, {_inviter, state}}] -> state; [] -> :none end)
  defp upserts, do: :ets.match(@ets, {{:upsert, :_}, :"$1"}) |> List.flatten()
  defp audits(action), do: :ets.match(@ets, {{:audit, :_}, {:"$1", action, :"$2", :"$3", :"$4", :_}})

  defp events(room_id) do
    :ets.match(@ets, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.filter(&(&1["room_id"] == room_id))
  end

  defp state_events(room_id, type, state_key \\ ""),
    do: events(room_id) |> Enum.filter(&(&1["type"] == type and &1["state_key"] == state_key)) |> Enum.sort_by(& &1["__seq"])

  defp only_content(room_id, type) do
    assert [event] = state_events(room_id, type), "exactly one #{type} event expected, got #{length(state_events(room_id, type))}"
    event["content"]
  end

  defp seq_of(room_id, type, state_key \\ "") do
    assert [ev] = state_events(room_id, type, state_key)
    ev["__seq"]
  end

  # the invite member events of the room, in insertion order
  defp invite_events(room_id),
    do:
      events(room_id)
      |> Enum.filter(&(&1["type"] == "m.room.member" and get_in(&1, ["content", "membership"]) == "invite"))
      |> Enum.sort_by(& &1["__seq"])

  defp invited_users(room_id), do: room_id |> invite_events() |> Enum.map(& &1["state_key"])
  defp member_events(room_id, user), do: state_events(room_id, "m.room.member", user)

  defp persisted_power_levels(room_id) do
    [{_, json}] = :ets.lookup(@ets, {:power_levels, room_id})
    Jason.decode!(json)
  end

  defp default_levels(users), do: Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", users)

  defp initial_state(entries), do: Jason.encode!(entries)
  defp entry(type, content, key \\ ""), do: %{"type" => type, "state_key" => key, "content" => content}

  defp pg_error(marker) do
    %Postgrex.Error{
      message: "simulated 22P05 #{marker}",
      postgres: %{
        code: :untranslatable_character,
        pg_code: "22P05",
        severity: "ERROR",
        message: "unsupported Unicode escape sequence",
        where: "JSON data, line 1: {\"x\": \"#{marker}\"...}"
      }
    }
  end

  defp capture_create(attrs) do
    ref = make_ref()
    log = capture_log(fn -> send(self(), {ref, create(attrs)}) end)
    assert_received {^ref, result}
    {log, result}
  end

  # Element's exact DM body (AC1): trusted_private_chat, private, guest_access can_join, history_visibility invited, encryption
  defp element_dm(invitee, extra \\ []) do
    [
      preset: "trusted_private_chat",
      visibility: "private",
      invite: [invitee],
      is_direct: true,
      initial_state_json:
        initial_state([
          entry("m.room.guest_access", %{"guest_access" => "can_join"}),
          entry("m.room.encryption", %{"algorithm" => "m.megolm.v1.aes-sha2"}),
          entry("m.room.history_visibility", %{"history_visibility" => "invited"})
        ])
    ] ++ extra
  end

  # ─── guard ───────────────────────────────────────────────────────────────────

  describe "the request struct" do
    test "carries invite and invite_3pid (req/1 uses struct/2, which silently drops unknown keys: without this guard the other tests would test nothing)" do
      request = %Core.CreateRoomRequest{}

      fields = Map.from_struct(request)

      for key <- [:invite, :invite_3pid, :is_direct] do
        assert Map.has_key?(fields, key), "Core.CreateRoomRequest has the field #{key}"
      end

      assert {fields[:invite], fields[:invite_3pid]} == {nil, nil}, "D12: nil = no invites for every internal caller"
    end
  end

  # ─── AC1 (unit part) + AC2: the invite events ────────────────────────────────

  describe "AC1 / AC2 - Element's DM request and the invite events (D2)" do
    test "Element's DM body: ONE invite event for B (sender creator, content exactly invite + is_direct true), a pending row, B is not a member" do
      :pg.join("user:#{@b}", self())
      resp = create_ok(element_dm(@b))
      room = resp.room_id

      assert [event] = member_events(room, @b)
      assert event["sender"] == @creator
      assert event["content"] == %{"membership" => "invite", "is_direct" => true}
      assert is_binary(event["event_id"]) and String.starts_with?(event["event_id"], "$"), "an event id was generated"
      assert is_map(event["signatures"]) and event["signatures"] != %{}, "the invite event is signed (emit_state_event_at/6)"

      assert invite_calls() == [{room, @creator, @b}], "one insert_invitation/3 call: the creator invites B"
      assert invitation_state(room, @b) == :pending
      assert :ets.lookup(@ets, {:member, room, @b}) == [], "an invited user is not a member"
      assert_receive {:new_invite, ^room}, 500
    end

    test "the DM keeps the Element events: join rule invite, history_visibility invited, guest_access can_join, no encryption event (ADR-011)" do
      resp = create_ok(element_dm(@b))

      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert only_content(resp.room_id, "m.room.history_visibility") == %{"history_visibility" => "invited"}
      assert only_content(resp.room_id, "m.room.guest_access") == %{"guest_access" => "can_join"}
      assert state_events(resp.room_id, "m.room.encryption") == []
    end

    test "group DM / private room: invite [B, C], invite_3pid [] and no is_direct: two pending rows and two invite events with content exactly membership invite" do
      resp = create_ok(preset: "private_chat", invite: [@b, @c], invite_3pid: [])
      room = resp.room_id

      assert invited_users(room) == [@b, @c], "one event per invitee, in list order"
      for user <- [@b, @c], do: assert(hd(member_events(room, user))["content"] == %{"membership" => "invite"}, "#{user}: no is_direct key")
      assert invitation_rows(room) == [{@b, {@creator, :pending}}, {@c, {@creator, :pending}}]
    end

    test "is_direct true puts is_direct on EVERY invite event; false and nil put no is_direct key" do
      resp = create_ok(invite: [@b, @c], is_direct: true)
      for user <- [@b, @c], do: assert(hd(member_events(resp.room_id, user))["content"] == %{"membership" => "invite", "is_direct" => true})

      for is_direct <- [false, nil] do
        resp = create_ok(invite: [@b], is_direct: is_direct)
        assert hd(member_events(resp.room_id, @b))["content"] == %{"membership" => "invite"}, "is_direct #{inspect(is_direct)}"
      end
    end

    test "duplicates are dropped silently: first occurrence wins, list order kept, ONE invitation and ONE event per user" do
      resp = create_ok(invite: [@c, @b, @c, @b, @c])

      assert invited_users(resp.room_id) == [@c, @b]
      assert invitation_rows(resp.room_id) == [{@b, {@creator, :pending}}, {@c, {@creator, :pending}}]
      assert length(invite_calls()) == 2
      # ONE read for the whole de-duplicated list is required, not an order of its ids
      assert [ids] = eligibility_calls()
      assert MapSet.new(ids) == MapSet.new([@c, @b]) and length(ids) == 2
    end

    test "invite absent, nil and [] write no invitation, no invite event and read no eligibility; is_direct true without invite is a 200 without an invite event" do
      for {label, attrs} <- [absent: [], nil: [invite: nil], empty: [invite: []], no_invite_but_direct: [is_direct: true], direct_empty: [invite: [], is_direct: true]] do
        resp = create_ok(attrs, to_string(label))
        assert invited_users(resp.room_id) == [], to_string(label)
        assert member_events(resp.room_id, @creator) |> length() == 1, "#{label}: only the creator's own join event"
      end

      assert invite_calls() == []
      assert eligibility_calls() == []
    end

    test "every invite is broadcast to the invitee's user group (the sync wake-up of POST /invite), after the room exists" do
      :pg.join("user:#{@b}", self())
      :pg.join("user:#{@c}", self())
      resp = create_ok(invite: [@b, @c])
      room = resp.room_id

      assert_receive {:new_invite, ^room}, 500
      assert_receive {:new_invite, ^room}, 500
    end

    test "no users row is provisioned for an invitee: only the creator is upserted" do
      create_ok(invite: [@b, @c], is_direct: true)
      assert upserts() == [{@creator, "user"}]
    end

    test "the room_created audit row keeps its keys (is_direct, alias): the invite list is not recorded" do
      localpart = "audit-inv-" <> rand()
      resp = create_ok(invite: [@b], is_direct: true, room_alias_name: localpart)

      assert [[@creator, "room", room, metadata]] = audits("room_created")
      assert room == resp.room_id
      assert metadata == %{"is_direct" => true, "alias" => "#" <> localpart <> ":" <> @server}
    end
  end

  # ─── AC3: the invite list validation (D3, D5) ────────────────────────────────

  describe "AC3 - invite validation (D5, before any room exists)" do
    test "a non-list invite (a string, an object, a number, true) is 400 M_BAD_JSON, no room" do
      for invite <- ["@bob:#{@server}", %{}, 5, true, %{"a" => 1}] do
        assert_rejected([invite: invite], "M_BAD_JSON", "invite #{inspect(invite)}")
      end
    end

    test "an element that is not a string ([5], [nil], [[id]], [true], [{}]) is 400 M_BAD_JSON, no room" do
      for invite <- [[5], [nil], [[@b]], [true], [%{}], [@b, 5]] do
        assert_rejected([invite: invite], "M_BAD_JSON", "invite #{inspect(invite)}")
      end
    end

    test "more than 50 entries are 400 M_INVALID_PARAM (counted raw, before the de-duplication); exactly 50 are accepted" do
      assert_rejected([invite: Enum.map(1..51, &user/1)], "M_INVALID_PARAM", "51 distinct ids")
      assert_rejected([invite: List.duplicate(@b, 51)], "M_INVALID_PARAM", "51 times the same id")

      resp = create_ok(invite: Enum.map(1..50, &user/1))
      assert length(invited_users(resp.room_id)) == 50
      assert length(invitation_rows(resp.room_id)) == 50
      assert [ids] = eligibility_calls(), "one read for the whole list"
      assert MapSet.new(ids) == MapSet.new(Enum.map(1..50, &user/1)) and length(ids) == 50
    end

    test "a malformed user id (bob, @Bob:srv, @b, empty, no domain, spaces) is 400 M_INVALID_PARAM, no room" do
      for invite <- [["bob"], ["@Bob:#{@server}"], ["@b"], [""], ["@bob:"], ["@:#{@server}"], ["@bob smith:#{@server}"], [@b, "nope"]] do
        assert_rejected([invite: invite], "M_INVALID_PARAM", "invite #{inspect(invite)}")
      end
    end

    test "a user id longer than 255 bytes is 400 M_INVALID_PARAM, no room (review cycle 1, bounded input)" do
      long = "@" <> String.duplicate("a", 250) <> ":" <> @server
      assert_rejected([invite: [long]], "M_INVALID_PARAM", "256+ byte id")
    end

    test "the creator's own id in invite is 400 M_INVALID_PARAM 'invite must not contain the room creator' (also among others and twice)" do
      for invite <- [[@creator], [@b, @creator], [@creator, @creator]] do
        message = assert_rejected([invite: invite], "M_INVALID_PARAM", "invite #{inspect(invite)}")
        assert message == "invite must not contain the room creator"
      end
    end

    test "a foreign-domain id is 403 M_FORBIDDEN (no eligibility read), the fixed text names no id; two different foreign ids answer identically" do
      message_1 = assert_rejected([invite: ["@x:other.example"]], "M_FORBIDDEN", "foreign 1", 403)
      message_2 = assert_rejected([invite: ["@someone-else:elsewhere.example"]], "M_FORBIDDEN", "foreign 2", 403)

      assert message_1 == message_2, "byte-identical messages: no id echoed"
      assert message_1 == "Users of other servers cannot be invited: this server does not federate"
      assert eligibility_calls() == [], "the domain check is pure and runs before the existence read"
    end

    test "an unknown and a deactivated local id are the SAME 404 M_NOT_FOUND with the same fixed text, never M_FORBIDDEN / M_USER_NOT_FOUND / M_USER_DEACTIVATED" do
      :ets.insert(@ets, {{:user_missing, @b}, true})
      :ets.insert(@ets, {{:user_inactive, @c}, true})

      unknown = assert_rejected([invite: [@b]], "M_NOT_FOUND", "unknown", 404)
      deactivated = assert_rejected([invite: [@c]], "M_NOT_FOUND", "deactivated", 404)

      assert unknown == deactivated, "no distinction between an unknown and a deactivated account"
      assert unknown == "The user to invite does not exist on this server"
      refute unknown =~ @b
      refute deactivated =~ @c

      for invite <- [[@b], [@c], [user(1), @b]] do
        assert {:error, {404, errcode, _}} = create(invite: invite)
        assert errcode == "M_NOT_FOUND"
        refute errcode in ["M_FORBIDDEN", "M_USER_NOT_FOUND", "M_USER_DEACTIVATED"]
      end
    end

    test "all-or-nothing: one ineligible entry refuses the whole request, no room and no invitation for the eligible ones" do
      assert_rejected([invite: [@b, "@x:other.example"]], "M_FORBIDDEN", "valid + foreign", 403)

      :ets.insert(@ets, {{:user_missing, @c}, true})
      assert_rejected([invite: [@b, @c]], "M_NOT_FOUND", "valid + unknown", 404)
      assert_rejected([invite: [@c, @b]], "M_NOT_FOUND", "unknown + valid", 404)
      assert room_snapshot() == {[], []}
    end

    test "a failing existence read is a 500 (fail closed), no room, no invitation, and the log names no user id" do
      marker = "mkelig" <> rand()
      :ets.insert(@ets, {:fail_eligibility, pg_error(marker)})

      invitee = "@" <> marker <> ":" <> @server
      before = room_snapshot()
      {log, result} = capture_create(invite: [invitee])

      assert {:error, {500, _, message}} = result
      refute message =~ marker
      assert room_snapshot() == before
      assert invite_calls() == []
      refute String.downcase(log) =~ marker, "no invitee id and no database text in the log"
      refute log =~ invitee
      assert log =~ "postgres 22P05", "the error class is logged"
    end

    test "the client-facing messages are fixed text: no invitee id / domain is echoed (shape, creator, foreign, unknown)" do
      marker = "zzinv" <> rand()
      :ets.insert(@ets, {{:user_missing, "@" <> marker <> ":" <> @server}, true})

      for {label, invite, errcode, status} <- [
            {"malformed", [marker], "M_INVALID_PARAM", 400},
            {"malformed uppercase", ["@" <> String.upcase(marker) <> ":#{@server}"], "M_INVALID_PARAM", 400},
            {"foreign", ["@x:" <> marker <> ".example"], "M_FORBIDDEN", 403},
            {"unknown", ["@" <> marker <> ":" <> @server], "M_NOT_FOUND", 404}
          ] do
        message = assert_rejected([invite: invite], errcode, label, status)
        refute String.downcase(message) =~ marker, "#{label}: the message must not echo the client value"
      end
    end
  end

  # ─── AC4: invite_3pid (D6) ───────────────────────────────────────────────────

  describe "AC4 - invite_3pid (D6)" do
    @well_shaped %{"id_server" => "matrix.org", "id_access_token" => "t", "medium" => "email", "address" => "a@b.c"}

    test "[], nil and absent are accepted (Element's group DM always sends [])" do
      for attrs <- [[invite_3pid: []], [invite_3pid: nil], [], [invite: [@b], invite_3pid: []]] do
        create_ok(attrs, inspect(attrs))
      end
    end

    test "a non-list (\"x\", {}, 5, true) is 400 M_BAD_JSON, no room" do
      for value <- ["x", %{}, 5, true, @well_shaped] do
        assert_rejected([invite_3pid: value], "M_BAD_JSON", "invite_3pid #{inspect(value)}")
      end
    end

    test "malformed items (not an object, a missing required key, a non-string value, a mixed list) are 400 M_BAD_JSON, not 403" do
      for {label, value} <- [
            number: [5],
            null: [nil],
            string: ["a@b.c"],
            list: [[@well_shaped]],
            only_medium: [%{"medium" => "email"}],
            no_access_token: [Map.delete(@well_shaped, "id_access_token")],
            no_id_server: [Map.delete(@well_shaped, "id_server")],
            no_address: [Map.delete(@well_shaped, "address")],
            no_medium: [Map.delete(@well_shaped, "medium")],
            id_server_number: [%{@well_shaped | "id_server" => 5}],
            token_null: [%{@well_shaped | "id_access_token" => nil}],
            address_object: [%{@well_shaped | "address" => %{}}],
            medium_list: [%{@well_shaped | "medium" => ["email"]}],
            empty_object: [%{}],
            well_shaped_then_number: [@well_shaped, 5],
            number_then_well_shaped: [5, @well_shaped]
          ] do
        assert_rejected([invite_3pid: value], "M_BAD_JSON", "invite_3pid #{label}")
      end
    end

    test "a list of well-shaped items is 403 M_THREEPID_DENIED 'Third-party invites are not supported on this server', no room, the entries are not echoed" do
      marker = "mk3pid" <> rand()

      for value <- [[@well_shaped], [@well_shaped, @well_shaped], [%{@well_shaped | "address" => marker <> "@b.c"}]] do
        message = assert_rejected([invite_3pid: value], "M_THREEPID_DENIED", "invite_3pid #{length(value)} item(s)", 403)
        assert message == "Third-party invites are not supported on this server"
        refute message =~ marker
      end

      assert eligibility_calls() == []
    end

    test "unknown extra keys on a well-shaped item do not make it malformed (still 403, not 400)" do
      assert_rejected([invite_3pid: [Map.put(@well_shaped, "x", 1)]], "M_THREEPID_DENIED", "extra key", 403)
    end

    test "a non-empty invite_3pid never creates a room without the partner: invite [B] + a well-shaped 3pid item is refused as a whole, B is not invited" do
      assert_rejected([invite: [@b], invite_3pid: [@well_shaped]], "M_THREEPID_DENIED", "invite + 3pid", 403)
    end
  end

  # ─── AC6: order and timestamps (D8) ──────────────────────────────────────────

  # No frozen-clock seam exists (Nebu.DB.Helpers.now_ms/0 is System.system_time(:millisecond), emit_state_event_at/6 takes
  # max(now, not_before)): the strictness is exercised by repeating each scenario 10-15 times, so a same-millisecond tie would show.
  describe "AC6 - step 8: the invite events come last, one strictly increasing timestamp chain" do
    # story rate-limits-join-invite-create-room (DATA adaptation, AC9): these tests repeat a createRoom 10 - 15 times with the SAME creator and
    # the SAME invitees to catch a same-millisecond tie; the pending cap per (inviter, invitee) pair (default 10) would refuse the 11th run.
    # The cap is lifted for this describe only (test-scoped, restored): the order of the events is what is under test here, never a default.
    setup do
      previous = Application.fetch_env(:nebu, :invite_max_pending_per_pair)
      Application.put_env(:nebu, :invite_max_pending_per_pair, 1_000)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:nebu, :invite_max_pending_per_pair, value)
          :error -> Application.delete_env(:nebu, :invite_max_pending_per_pair)
        end
      end)

      :ok
    end

    defp chain_after_power_levels(room) do
      pl_seq = seq_of(room, "m.room.power_levels")
      events(room) |> Enum.filter(&(&1["__seq"] > pl_seq)) |> Enum.sort_by(& &1["__seq"])
    end

    defp assert_strictly_increasing(chain, label) do
      chain
      |> Enum.map(& &1["origin_server_ts"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, next] -> assert next > previous, "#{label}: origin_server_ts strictly increasing, got #{previous} then #{next}" end)
    end

    test "the full chain: create, creator join, power_levels, preset, initial_state, name, topic, derived alias, invite B, invite C (15 runs)" do
      for run <- 1..15 do
        name = "Chain #{run} #{rand()}"

        resp =
          create_ok(
            name: name,
            topic: "t #{rand()}",
            preset: "trusted_private_chat",
            invite: [@b, @c],
            initial_state_json: initial_state([entry("m.test.filler", %{"i" => run}, "k1"), entry("m.test.filler", %{"i" => run}, "k2")])
          )

        room = resp.room_id
        [invite_b, invite_c] = invite_events(room)
        assert [invite_b["state_key"], invite_c["state_key"]] == [@b, @c]

        creator_join = seq_of(room, "m.room.member", @creator)
        [%{"__seq" => filler_1}, %{"__seq" => filler_2}] = events(room) |> Enum.filter(&(&1["type"] == "m.test.filler")) |> Enum.sort_by(& &1["__seq"])

        assert seq_of(room, "m.room.create") < creator_join
        assert creator_join < seq_of(room, "m.room.power_levels")
        assert seq_of(room, "m.room.power_levels") < seq_of(room, "m.room.join_rules")
        assert seq_of(room, "m.room.guest_access") < filler_1, "preset events before initial_state"
        assert filler_1 < filler_2
        assert filler_2 < seq_of(room, "m.room.name")
        assert seq_of(room, "m.room.name") < seq_of(room, "m.room.topic")
        assert seq_of(room, "m.room.topic") < seq_of(room, "m.room.canonical_alias"), "the derived alias is the last event of steps 4-7"
        assert seq_of(room, "m.room.canonical_alias") < invite_b["__seq"], "the invites come after the derived alias"
        assert invite_b["__seq"] < invite_c["__seq"], "list order"

        # the whole chain from the first preset event to the last invite: strictly increasing origin_server_ts
        assert_strictly_increasing(chain_after_power_levels(room), "run #{run}")
        assert List.last(chain_after_power_levels(room))["state_key"] == @c, "the last event of the room is the last invite"
      end
    end

    test "without name and topic the invites follow the last initial_state / preset event; strictly increasing, 15 runs" do
      for run <- 1..15 do
        resp = create_ok(preset: "private_chat", invite: [@b, @c], initial_state_json: initial_state([entry("m.test.filler", %{"i" => run}, "k")]))
        room = resp.room_id
        chain = chain_after_power_levels(room)

        assert Enum.map(chain, &{&1["type"], &1["state_key"]}) |> Enum.take(-3) == [{"m.test.filler", "k"}, {"m.room.member", @b}, {"m.room.member", @c}]
        assert_strictly_increasing(chain, "run #{run}")
      end
    end

    test "with an explicit room_alias_name (step 4) and a name the invites are still last and the chain from the alias on is strictly increasing" do
      for run <- 1..10 do
        localpart = "inv-order-#{run}-" <> rand()
        resp = create_ok(room_alias_name: localpart, name: "Named #{rand()}", topic: "t", preset: "public_chat", invite: [@b])
        room = resp.room_id

        [invite_b] = invite_events(room)
        assert seq_of(room, "m.room.canonical_alias") < invite_b["__seq"]
        assert seq_of(room, "m.room.topic") < invite_b["__seq"]
        assert_strictly_increasing(chain_after_power_levels(room), "run #{run}")
        assert List.last(chain_after_power_levels(room))["state_key"] == @b
      end
    end

    test "a failing name / topic / derived alias write (all non-fatal) does not stop the invites: the room is created and B is invited" do
      :ets.insert(@ets, {{:fail_insert, "m.room.topic"}, :simulated_db_down})

      {_log, result} = capture_create(name: "Name #{rand()}", topic: "t", invite: [@b])
      assert {:ok, resp} = result
      assert invited_users(resp.room_id) == [@b]
      assert invitation_state(resp.room_id, @b) == :pending
    end
  end

  # ─── AC7: trusted_private_chat power levels (D9) ─────────────────────────────

  describe "AC7 - trusted_private_chat gives every invitee the creator's level (D9)" do
    test "trusted_private_chat + invite [B, C]: users exactly {A, B, C at 100}, every other key the default, one event, rooms.power_levels_json equal" do
      resp = create_ok(preset: "trusted_private_chat", invite: [@b, @c])
      expected = default_levels(%{@creator => 100, @b => 100, @c => 100})

      assert [event] = state_events(resp.room_id, "m.room.power_levels")
      assert event["content"] == expected
      assert persisted_power_levels(resp.room_id) == expected
    end

    test "private_chat and public_chat with the same invites keep users {A: 100}; trusted_private_chat without invite too" do
      for {label, attrs} <- [
            private_chat: [preset: "private_chat", invite: [@b, @c]],
            public_chat: [preset: "public_chat", invite: [@b, @c]],
            default_preset: [invite: [@b, @c]],
            trusted_no_invite: [preset: "trusted_private_chat"],
            trusted_empty_invite: [preset: "trusted_private_chat", invite: []],
            trusted_nil_invite: [preset: "trusted_private_chat", invite: nil],
            visibility_private_only: [visibility: "private", invite: [@b]]
          ] do
        resp = create_ok(attrs, to_string(label))
        assert only_content(resp.room_id, "m.room.power_levels") == default_levels(%{@creator => 100}), to_string(label)
      end
    end

    test "the effective preset counts: an explicit trusted_private_chat wins over visibility public, the invitee gets the creator's level" do
      resp = create_ok(preset: "trusted_private_chat", visibility: "public", invite: [@b])
      assert only_content(resp.room_id, "m.room.power_levels")["users"] == %{@creator => 100, @b => 100}
    end

    test "an override users map REPLACES the generated one: {A: 100} -> exactly {A: 100}, B and C are still invited" do
      resp = create_ok(preset: "trusted_private_chat", invite: [@b, @c], power_level_content_override: %{"users" => %{@creator => 100}})

      assert only_content(resp.room_id, "m.room.power_levels")["users"] == %{@creator => 100}
      assert invited_users(resp.room_id) == [@b, @c]
      assert invitation_rows(resp.room_id) == [{@b, {@creator, :pending}}, {@c, {@creator, :pending}}]
    end

    test "an override that does not touch users: events_default 50 keeps the invitees at 100 and sets events_default" do
      resp = create_ok(preset: "trusted_private_chat", invite: [@b, @c], power_level_content_override: %{"events_default" => 50})

      content = only_content(resp.room_id, "m.room.power_levels")
      assert content["users"] == %{@creator => 100, @b => 100, @c => 100}
      assert content["events_default"] == 50
      assert content == default_levels(%{@creator => 100, @b => 100, @c => 100}) |> Map.put("events_default", 50)
    end

    test "override users {A: 100, @x: 50} + invite [B, C]: users exactly that (the invitees are ABSENT), B and C are still invited" do
      other = "@x:#{@server}"
      resp = create_ok(preset: "trusted_private_chat", invite: [@b, @c], power_level_content_override: %{"users" => %{@creator => 100, other => 50}})

      assert only_content(resp.room_id, "m.room.power_levels")["users"] == %{@creator => 100, other => 50}
      refute Map.has_key?(only_content(resp.room_id, "m.room.power_levels")["users"], @b)
      assert invited_users(resp.room_id) == [@b, @c]
    end

    test "the lock-out check still runs on the merged map: users {A: 0, @x: 50} + invite [B] is 400 M_INVALID_ROOM_STATE, no room" do
      assert_rejected(
        [preset: "trusted_private_chat", invite: [@b], power_level_content_override: %{"users" => %{@creator => 0, "@x:#{@server}" => 50}}],
        "M_INVALID_ROOM_STATE",
        "lock-out on the merged map"
      )
    end

    test "an invitee level only goes to VALIDATED invitees: a refused list creates no room and no level for anyone" do
      :ets.insert(@ets, {{:user_missing, @c}, true})
      assert_rejected([preset: "trusted_private_chat", invite: [@b, @c]], "M_NOT_FOUND", "unknown invitee", 404)
      assert :ets.match(@ets, {{:power_levels, :_}, :_}) == []
    end

    test "equal levels in a DM (the documented consequence): neither can kick or ban the other, nothing is written, both stay members" do
      resp = create_ok(preset: "trusted_private_chat", invite: [@b])
      room = resp.room_id
      :ok = Nebu.Matrix.Room.Server.join(room, @b)
      before = length(events(room))

      for {caller, target} <- [{@creator, @b}, {@b, @creator}] do
        kick = %Core.KickUserRequest{room_id: room, target_id: target, reason: ""}
        ban = %Core.BanUserRequest{room_id: room, target_id: target, reason: ""}

        assert {:error, {403, "M_FORBIDDEN", _}} = Http.call_core(fn -> Server.kick_user(kick, stream(caller)) end), "kick #{caller} -> #{target}"
        assert {:error, {403, "M_FORBIDDEN", _}} = Http.call_core(fn -> Server.ban_user(ban, stream(caller)) end), "ban #{caller} -> #{target}"
      end

      state = Nebu.Matrix.Room.Server.get_state(room)
      assert MapSet.member?(state.members, @creator) and MapSet.member?(state.members, @b)
      assert length(events(room)) == before, "no leave / ban event was written"
    end

    test "control: in a private_chat DM the creator CAN kick the invitee who joined (100 vs 0); the equal-level refusal is the trusted_private_chat rule" do
      resp = create_ok(preset: "private_chat", invite: [@b])
      :ok = Nebu.Matrix.Room.Server.join(resp.room_id, @b)

      kick = %Core.KickUserRequest{room_id: resp.room_id, target_id: @b, reason: ""}
      assert {:ok, %Core.KickUserResponse{}} = Http.call_core(fn -> Server.kick_user(kick, stream(@creator)) end)
    end

    test "D9 (f): the creator cannot revoke the PENDING invitation of a trusted_private_chat invitee (refused, it stays pending, nothing is written)" do
      resp = create_ok(preset: "trusted_private_chat", invite: [@b])
      room = resp.room_id
      assert invitation_state(room, @b) == :pending, "precondition: B holds a pending invitation"
      before = length(events(room))

      kick = %Core.KickUserRequest{room_id: room, target_id: @b, reason: ""}
      # refused by the equal-level rule (room v10: the target's level is not lower), before anything is touched
      assert {:error, {403, "M_FORBIDDEN", _}} = Http.call_core(fn -> Server.kick_user(kick, stream(@creator)) end)

      assert invitation_state(room, @b) == :pending, "B's invitation stays pending"
      assert reject_calls() == [], "the invitation was not even rejected on the way"
      assert length(events(room)) == before
    end
  end

  # ─── AC8: the creator lock-out includes the invites (D10) ────────────────────

  describe "AC8 - the invite level is part of the creator lock-out (D10)" do
    test "override invite 101 + invite [B] is 400 M_INVALID_ROOM_STATE, no room; the same override without invite (absent, nil, []) is a 200" do
      override = %{"invite" => 101}
      assert_rejected([invite: [@b], power_level_content_override: override], "M_INVALID_ROOM_STATE", "invite 101 + invite")
      assert_rejected([preset: "trusted_private_chat", invite: [@b, @c], power_level_content_override: override], "M_INVALID_ROOM_STATE", "trusted + invite 101")

      for attrs <- [[], [invite: nil], [invite: []]] do
        resp = create_ok([power_level_content_override: override] ++ attrs, inspect(attrs))
        assert only_content(resp.room_id, "m.room.power_levels")["invite"] == 101, "the restriction only applies to LATER invites"
      end
    end

    test "planner table: creator at 100 reaches invite 100 (ok), 101 is refused; creator at 50 with state_default 50 reaches invite 50, not 51" do
      create_ok(invite: [@b], power_level_content_override: %{"invite" => 100})
      assert_rejected([invite: [@b], power_level_content_override: %{"invite" => 101}], "M_INVALID_ROOM_STATE", "100 vs 101")

      # story power-levels-enforcement (D12, AC16 re-pin): `"events": {}` replaces the default `events` map (its
      # m.room.history_visibility 100 would lock a creator at 50 out of the preset event before the invite level is reached)
      users_50 = %{"users" => %{@creator => 50}, "events" => %{}}
      create_ok(invite: [@b], power_level_content_override: Map.put(users_50, "invite", 50))
      assert_rejected([invite: [@b], power_level_content_override: Map.put(users_50, "invite", 51)], "M_INVALID_ROOM_STATE", "50 vs 51")
    end

    test "a non-integer invite level in the override is refused by the override shape (M_BAD_JSON) and never reaches the planner, also with an invite" do
      for value <- ["0", 1.5, nil, true, [], %{}] do
        assert_rejected([invite: [@b], power_level_content_override: %{"invite" => value}], "M_BAD_JSON", "invite level #{inspect(value)}")
      end
    end

    test "a demoted creator whose state events are still refused by the existing planner stays refused with an invite" do
      assert_rejected([invite: [@b], power_level_content_override: %{"users" => %{@creator => 0}, "invite" => 0}], "M_INVALID_ROOM_STATE", "users 0, invite 0")
    end

    test "the invite check does not weaken the others: users 0 with per-type exceptions for every state event but a LOW invite level is accepted with an invite" do
      override = %{
        "users" => %{@creator => 0},
        "invite" => 0,
        "events" => %{"m.room.join_rules" => 0, "m.room.history_visibility" => 0, "m.room.guest_access" => 0}
      }

      resp = create_ok(invite: [@b], power_level_content_override: override)
      assert invited_users(resp.room_id) == [@b]
    end
  end

  # ─── AC9: first failure (D14) ────────────────────────────────────────────────

  describe "AC9 - first failure wins, in the D14 order" do
    test "a malformed invitee together with a taken room_alias_name is M_INVALID_PARAM; the taken alias alone is M_ROOM_IN_USE" do
      taken = "taken-" <> rand()
      :ets.insert(@ets, {{:alias, "#" <> taken <> ":" <> @server}, "!first:#{@server}"})

      assert_rejected([invite: ["bob"], room_alias_name: taken], "M_INVALID_PARAM", "malformed invitee + taken alias")
      assert_rejected([invite: [@b], room_alias_name: taken], "M_ROOM_IN_USE", "valid invitee + taken alias")
    end

    test "an unknown local invitee together with a taken room_alias_name is M_ROOM_IN_USE: the existence read is the LAST read and is not reached" do
      taken = "taken-" <> rand()
      :ets.insert(@ets, {{:alias, "#" <> taken <> ":" <> @server}, "!first:#{@server}"})
      :ets.insert(@ets, {{:user_missing, @b}, true})

      assert_rejected([invite: [@b], room_alias_name: taken], "M_ROOM_IN_USE", "unknown invitee + taken alias")
      assert eligibility_calls() == [], "the alias is checked before the existence read"
    end

    test "a foreign invitee together with an invite 101 override is 403 M_FORBIDDEN (the pure domain check precedes the lock-out)" do
      assert_rejected([invite: ["@x:other.example"], power_level_content_override: %{"invite" => 101}], "M_FORBIDDEN", "foreign + lock-out", 403)
      assert_rejected([invite: [@b], power_level_content_override: %{"invite" => 101}], "M_INVALID_ROOM_STATE", "valid + lock-out")
    end

    test "a non-empty invite_3pid together with a malformed invite is M_INVALID_PARAM (invite shape precedes invite_3pid)" do
      item = %{"id_server" => "matrix.org", "id_access_token" => "t", "medium" => "email", "address" => "a@b.c"}
      assert_rejected([invite: ["bob"], invite_3pid: [item]], "M_INVALID_PARAM", "malformed invite + well-shaped 3pid")
      assert_rejected([invite: ["bob"], invite_3pid: "x"], "M_INVALID_PARAM", "malformed invite + malformed 3pid")
    end

    test "an invalid preset together with a malformed invitee is M_INVALID_PARAM from the PRESET check (the message of the preset)" do
      preset_message = assert_rejected([preset: "bogus"], "M_INVALID_PARAM", "the preset alone")
      combined = assert_rejected([preset: "bogus", invite: ["bob"]], "M_INVALID_PARAM", "preset + invitee")
      assert combined == preset_message, "the preset is checked first"

      invite_message = assert_rejected([invite: ["bob"]], "M_INVALID_PARAM", "the invitee alone")
      refute invite_message == preset_message, "the two messages differ, so the comparison above proves the order"
    end

    test "a bad override shape beats a malformed invite (M_BAD_JSON vs M_INVALID_PARAM); a malformed invite_3pid beats a foreign invitee and a lock-out" do
      assert_rejected([power_level_content_override: %{"ban" => "x"}, invite: ["bob"]], "M_BAD_JSON", "override shape first")
      assert_rejected([invite: ["@x:other.example"], invite_3pid: "x"], "M_BAD_JSON", "3pid shape before the domain check")
      assert_rejected([power_level_content_override: %{"state_default" => 101}, invite_3pid: "x"], "M_BAD_JSON", "3pid shape before the lock-out")
    end

    test "the invite shape (all entries) is checked before the domains: a malformed id after a foreign one is M_INVALID_PARAM" do
      assert_rejected([invite: ["@x:other.example", "bob"]], "M_INVALID_PARAM", "foreign then malformed")
      assert_rejected([invite: [@creator, "@x:other.example"]], "M_INVALID_PARAM", "creator then foreign")
    end

    test "the earlier checks of the previous stories still come first: name, room_version, bad alias and an initial_state alias error beat an invite error" do
      assert_rejected([name: String.duplicate("a", 256), invite: ["bob"]], "M_INVALID_PARAM", "name error")
      assert_rejected([room_version: "11", invite: ["bob"]], "M_UNSUPPORTED_ROOM_VERSION", "room_version")
      assert_rejected([room_alias_name: "a:b", invite: 5], "M_INVALID_PARAM", "bad room_alias_name beats a wrong-typed invite")
    end
  end

  # ─── AC10: step 8 is fatal and the cleanup works (D8) ────────────────────────

  describe "AC10 - a failing invite is fatal: 500 and the orphan room is cleaned up, invitation rows included" do
    defp assert_cleaned_up(room_snapshot_before, label) do
      assert [room] = deleted_rooms(), "#{label}: exactly one orphan room was deleted"
      assert room_snapshot_before == {[], []}
      assert :ets.lookup(@ets, {:room, room}) == [], "#{label}: no rooms row"
      assert events(room) == [], "#{label}: no events"
      assert :ets.match(@ets, {{:member, room, :_}, :_}) == [], "#{label}: no members"
      assert invitation_rows(room) == [], "#{label}: no invitation row (also not the first invitee's)"
      room
    end

    test "a failing invite ROW write for the SECOND invitee is a 500, the room is deleted with the first invitee's row" do
      :ets.insert(@ets, {{:fail_invite_row, @c}, :simulated_db_down})
      before = room_snapshot()

      assert {:error, {500, _errcode, _}} = create(invite: [@b, @c])
      room = assert_cleaned_up(before, "row write")
      assert {room, @creator, @b} in invite_calls(), "the first invitation was attempted (and is cleaned up with the room)"
    end

    test "a failing invite EVENT write for the SECOND invitee is a 500, the room is deleted, the first invitation row too" do
      :ets.insert(@ets, {{:fail_invite_event, @c}, :simulated_db_down})
      before = room_snapshot()

      assert {:error, {500, _errcode, _}} = create(invite: [@b, @c])
      assert_cleaned_up(before, "event write")
    end

    test "a failing invite event for the FIRST invitee: 500, no row left, the second invitee was never invited" do
      :ets.insert(@ets, {{:fail_invite_event, @b}, :simulated_db_down})
      before = room_snapshot()

      assert {:error, {500, _errcode, _}} = create(invite: [@b, @c])
      room = assert_cleaned_up(before, "first event")
      refute Enum.any?(invite_calls(), fn {_, _, invitee} -> invitee == @c end), "step 8 stops at the first failure (#{room})"
    end

    test "the cleanup runs for a DM too (is_direct true) and the creator's m.room.member event is gone with the events" do
      :ets.insert(@ets, {{:fail_invite_row, @b}, :simulated_db_down})
      before = room_snapshot()

      assert {:error, {500, _, _}} = create(element_dm(@b))
      assert_cleaned_up(before, "DM")
    end

    test "the logs name only the room id, event type and error class: no invitee, creator or database text (row and event failure)" do
      marker = "mkinv" <> rand()
      invitee = "@" <> marker <> ":" <> @server

      for {label, switch, needle} <- [
            {"row write", {{:fail_invite_row, invitee}, pg_error(marker)}, nil},
            {"event write", {{:fail_invite_event, invitee}, pg_error(marker)}, "m.room.member"}
          ] do
        :ets.delete_all_objects(@ets)
        :ets.insert(@ets, switch)

        {log, result} = capture_create(invite: [invitee])
        assert {:error, {500, _, message}} = result, label
        refute message =~ marker, "#{label}: no client value in the response"
        assert [room] = deleted_rooms(), label
        assert log =~ room, "#{label}: the room id is logged"
        assert log =~ "postgres 22P05", "#{label}: the error class is logged"
        if needle, do: assert(log =~ needle, "#{label}: the event type is logged")
        refute String.downcase(log) =~ marker, "#{label}: no invitee id / database text"
        refute log =~ @creator, "#{label}: no creator id"
      end
    end

    test "a failing cleanup (delete_room fails) logs a value-free warning and the ORIGINAL 500 is what the caller sees" do
      marker = "mkclean" <> rand()
      :ets.insert(@ets, {{:fail_invite_row, @c}, :simulated_db_down})
      :ets.insert(@ets, {:fail_delete_room, pg_error(marker)})

      {log, result} = capture_create(invite: [@b, @c])
      assert {:error, {500, _, message}} = result
      refute message =~ marker
      refute String.downcase(log) =~ marker
      refute log =~ @b
    end
  end

  # ─── AC13: unchanged paths (D12) ─────────────────────────────────────────────

  describe "AC13 - the Admin and Space wrappers send no invite (D12)" do
    test "Nebu.Matrix.create_room/2 and create_space/2: no invitation row, no invite event, no eligibility read, only the creator is provisioned" do
      assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, name: "Admin Room " <> rand())
      track_room(room_id)
      assert {:ok, space_id} = Nebu.Matrix.create_space(@creator, "Admin Space " <> rand())
      track_room(space_id)

      for room <- [room_id, space_id] do
        assert invite_events(room) == []
        assert invitation_rows(room) == []
        assert length(member_events(room, @creator)) == 1
      end

      assert invite_calls() == []
      assert eligibility_calls() == []
      assert Enum.uniq(upserts()) == [{@creator, "user"}]
    end

    test "Nebu.Matrix.create_room/2 keeps the default power levels with the admin at 100 and the audit metadata (is_direct only)" do
      assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, name: "Admin PL " <> rand())
      track_room(room_id)

      assert only_content(room_id, "m.room.power_levels") == default_levels(%{@creator => 100})
      assert [[@creator, "room", ^room_id, %{"is_direct" => false}]] = audits("room_created")
    end
  end

  # ─── AC15 (unit part): a Space created with invite ───────────────────────────

  describe "AC15 - the createRoom path works for a Space (Element's Space request) with invite" do
    test "a Space (creation_content type m.space) created with invite [B]: B invited, the Space type preserved" do
      resp =
        create_ok(
          creation_content_json: Jason.encode!(%{"type" => "m.space"}),
          room_type: "m.space",
          preset: "private_chat",
          power_level_content_override: %{"events_default" => 100, "invite" => 50},
          invite: [@b]
        )

      assert invited_users(resp.room_id) == [@b]
      assert only_content(resp.room_id, "m.room.create")["type"] == "m.space"
      assert :ets.lookup(@ets, {:room_type, resp.room_id}) == [{{:room_type, resp.room_id}, "m.space"}]
      assert only_content(resp.room_id, "m.room.power_levels")["invite"] == 50
    end
  end

  # ─── AC14: value-free logs of the success path ───────────────────────────────

  describe "AC14 - nothing about the invitees is logged" do
    test "a successful create with invitees logs no invitee id (warning level and above)" do
      marker = "mkok" <> rand()
      invitee = "@" <> marker <> ":" <> @server

      {log, result} = capture_create(invite: [invitee], is_direct: true, preset: "trusted_private_chat")
      assert {:ok, _} = result
      refute String.downcase(log) =~ marker
    end

    test "a rejected invite list logs no id, domain or item content (shape, creator, foreign, unknown, 3pid)" do
      marker = "mkrej" <> rand()
      :ets.insert(@ets, {{:user_missing, "@" <> marker <> ":" <> @server}, true})

      for attrs <- [
            [invite: [marker]],
            [invite: ["@x:" <> marker <> ".example"]],
            [invite: ["@" <> marker <> ":" <> @server]],
            [invite_3pid: [%{"id_server" => marker, "id_access_token" => "t", "medium" => "email", "address" => marker <> "@b.c"}]],
            [invite_3pid: [%{"medium" => marker}]]
          ] do
        {log, result} = capture_create(attrs)
        assert {:error, {status, _, _}} = result
        assert status in [400, 403, 404]
        refute String.downcase(log) =~ marker, "#{inspect(attrs)}: nothing of the request in the log"
      end
    end
  end
  # ─── story sync-membership-partition (D9, AC11): the createRoom wake-ups are deferred to after step 8 (Kassandra L-4) ───────────

  describe "AC11 (D9) - createRoom wake deferral" do
    test "invite [B, C]: no wake-up is sent while the invite events are written (the probe at C's event sees none of B); after the response both are woken once" do
      :pg.join("user:#{@b}", self())
      :pg.join("user:#{@c}", self())
      :ets.insert(@ets, {:probe_mailbox, self()})

      resp = create_ok(invite: [@b, @c], preset: "private_chat")
      room = resp.room_id

      assert [[0]] == :ets.match(@ets, {{:mailbox_probe, @b}, :"$1"}), "B's event was written with no wake-up sent yet"
      assert [[0]] == :ets.match(@ets, {{:mailbox_probe, @c}, :"$1"}), "when C's event was written, B had NOT been woken yet (before: sent right after B's event)"
      assert_receive {:new_invite, ^room}, 500
      assert_receive {:new_invite, ^room}, 500
      refute_receive {:new_invite, _}, 50, "exactly one wake-up per invitee"
    end

    test "a failing step 8 (the SECOND invitee's event cannot be written) sends NO wake-up at all, not the first invitee's either; the room is cleaned up" do
      :pg.join("user:#{@b}", self())
      :pg.join("user:#{@c}", self())
      :ets.insert(@ets, {{:fail_invite_event, @c}, :simulated_db_down})
      before = room_snapshot()

      assert {:error, {500, _errcode, _}} = create(invite: [@b, @c], preset: "private_chat")

      assert Enum.any?(invite_calls(), fn {_room, _inviter, invitee} -> invitee == @b end), "control: B's invitation WAS attempted before C's failure"
      assert room_snapshot() |> elem(0) == before |> elem(0), "no room left behind"
      refute_receive {:new_invite, _}, 100, "a room that is deleted again must not have woken anybody"
    end

    test "POST /rooms/{id}/invite keeps waking the invitee at once (the room exists)" do
      resp = create_ok(preset: "private_chat")
      room = resp.room_id
      :pg.join("user:#{@b}", self())

      assert {:ok, %Core.InviteUserResponse{}} =
               Http.call_core(fn -> Server.invite_user(%Core.InviteUserRequest{room_id: room, inviter_id: @creator, invitee_id: @b}, stream(@creator)) end)

      assert_receive {:new_invite, ^room}, 500
    end
  end

end
