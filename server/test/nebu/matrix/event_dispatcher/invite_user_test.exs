defmodule Nebu.Matrix.EventDispatcher.InviteUserTest do
  use ExUnit.Case, async: false

  # ─── Story 8-10a: invite_user :pg broadcast to invitee ───────────────────────
  #
  # Root cause: invite_user/2 inserts the DB row but never sends
  # {:new_invite, room_id} to the invitee's sync task via :pg group
  # "user:#{invitee}". The invitee's long-polling sync task therefore
  # sleeps for the full 30-second timeout instead of waking immediately.
  #
  # Fix: after db_module_invite().insert_invitation returns :ok, broadcast
  # {:new_invite, room_id} to :pg.get_local_members("user:#{invitee}").
  #
  # async: false — Horde.Registry, Application.put_env, and :pg are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  # ─── FakeDB (room_manager) ───────────────────────────────────────────────────
  #
  # ETS-backed fake satisfying Nebu.Matrix.Room.DB behaviour.
  # Injected via Application.put_env(:room_manager, :db_module, FakeDB).

  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:invite_user_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members =
            :ets.match(:invite_user_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:invite_user_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:invite_user_test_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:invite_user_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:invite_user_test_db, {:member, room_id, user_id})
      :ok
    end

    # Story create-room-invites-direct (D1, DATA adaptation of the fake): invite_user/2 now writes an `m.room.member` invite event.
    # Every event gets an insertion sequence (`__seq`, shared with the invitation rows of FakeInviteDB), `:fail_invite_event` makes
    # the write of an INVITE member event fail, and the test process is told about every write in order (`{:event_written, ...}`).
    def insert_event(event) do
      if event["type"] == "m.room.member" and get_in(event, ["content", "membership"]) == "invite" and
           :ets.lookup(:invite_user_test_db, :fail_invite_event) != [] do
        [{_, reason}] = :ets.lookup(:invite_user_test_db, :fail_invite_event)
        {:error, reason}
      else
        seq = :ets.update_counter(:invite_user_test_db, :seq, {2, 1}, {:seq, 0})
        :ets.insert(:invite_user_test_db, {{:event, event["event_id"]}, Map.put(event, "__seq", seq)})
        notify({:event_written, event["state_key"], get_in(event, ["content", "membership"])})
        :ok
      end
    end

    # Room.Server persists the power levels through the rooms DB seam (the invite-level tests set them)
    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(:invite_user_test_db, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def notify(message) do
      case :ets.lookup(:invite_user_test_db, :observer) do
        [{_, pid}] -> send(pid, message)
        [] -> :ok
      end
    end

    # Story create-room-invites-direct (D3, pinned by create_room_invites_test.exs): the ids of `user_ids` that are existing ACTIVE
    # local accounts. Absent from the answer = unknown or deactivated (`{:user_missing, id}` / `{:user_inactive, id}`).
    def invitable_local_users(user_ids) do
      :ets.insert(:invite_user_test_db, {{:eligibility_call, make_ref()}, user_ids})

      case :ets.lookup(:invite_user_test_db, :fail_eligibility) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          {:ok,
           Enum.filter(user_ids, fn id ->
             :ets.lookup(:invite_user_test_db, {:user_missing, id}) == [] and :ets.lookup(:invite_user_test_db, {:user_inactive, id}) == []
           end)}
      end
    end

    # Story 6.8: load_room_settings/1 returns {:ok, 0} (no limit) for unit tests.
    def load_room_settings(_room_id), do: {:ok, 0}

    # Story 6.9: get_room_status/1 — returns {:ok, "active"} so normal rooms start correctly.
    def get_room_status(_room_id), do: {:ok, "active"}

    # Story create-room-presets-power-levels-topic (D1, DATA adaptation of the fake): invite_user/2 reads the target's latest membership
    # through rooms_db_module() (a banned target is refused). Never a member before = nil; `:membership_read_error` makes the read fail.
    def get_member_membership(room_id, user_id) do
      case :ets.lookup(:invite_user_test_db, :membership_read_error) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          case :ets.lookup(:invite_user_test_db, {:membership, room_id, user_id}) do
            [{_, membership}] ->
              {:ok, membership}

            [] ->
              latest =
                :ets.match(:invite_user_test_db, {{:event, :_}, :"$1"})
                |> Enum.map(fn [e] -> e end)
                |> Enum.filter(&(&1["room_id"] == room_id and &1["type"] == "m.room.member" and &1["state_key"] == user_id))
                |> Enum.max_by(& &1["__seq"], fn -> nil end)

              {:ok, latest && get_in(latest, ["content", "membership"])}
          end
      end
    end

    # Story moderation-routes-atomic-ban (AC16 (b), DATA adaptation of the fake): the invite event (Room.Server.write_invite/5) and the
    # reject of a banned invitee's row go through the ONE transaction of Room.DB.apply_member_change/4, all or nothing: a failing reject
    # (`:fail_reject`) or event write (`:fail_invite_event`) applies NOTHING; otherwise the event is stored (insert_event/1), the member
    # row closed and the pending row rejected (FakeInviteDB.reject_invitation/2, recorded as before).
    def apply_member_change(room_id, user_id, event, opts) do
      reject? = Keyword.get(opts, :reject_invitation, false)

      case :ets.lookup(:invite_user_test_db, :fail_reject) do
        [{_, reason}] when reject? ->
          {:error, reason}

        _ ->
          with :ok <- if(is_map(event), do: insert_event(event), else: :ok) do
            if Keyword.get(opts, :remove_member, false), do: delete_member(room_id, user_id)
            if reject?, do: :ok = Nebu.Matrix.EventDispatcher.InviteUserTest.FakeInviteDB.reject_invitation(room_id, user_id)
            :ok
          end
      end
    end
  end

  # ─── FakeInviteDB ────────────────────────────────────────────────────────────

  defmodule FakeInviteDB do
    # Story create-room-invites-direct (D1, DATA adaptation of the fake): one row per (room, invitee) like the real table
    # (`{inviter, :pending | :rejected}`), `reject_invitation/2` is recorded and can fail (`:fail_reject`), and the test process is told
    # about every row write in order (`{:row_written, ...}`) so the order row -> event -> broadcast can be asserted.
    def insert_invitation(room_id, inviter, invitee) do
      :ets.insert(:invite_user_test_db, {{:inserted, make_ref()}, {room_id, inviter, invitee}})
      :ets.insert(:invite_user_test_db, {{:invitation, room_id, invitee}, {inviter, :pending}})
      FakeDB.notify({:row_written, invitee})
      :ok
    end

    def accept_invitation(_room_id, _invitee_id), do: :ok

    def reject_invitation(room_id, invitee_id) do
      :ets.insert(:invite_user_test_db, {{:rejected, make_ref()}, {room_id, invitee_id}})

      case :ets.lookup(:invite_user_test_db, :fail_reject) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          case :ets.lookup(:invite_user_test_db, {:invitation, room_id, invitee_id}) do
            [{key, {inviter, :pending}}] -> :ets.insert(:invite_user_test_db, {key, {inviter, :rejected}})
            _ -> :ok
          end

          :ok
      end
    end

    def pending_invite?(room_id, invitee_id) do
      {:ok, match?([{_, {_, :pending}}], :ets.lookup(:invite_user_test_db, {:invitation, room_id, invitee_id}))}
    end

    # story rate-limits-join-invite-create-room (DATA adaptation of the fake, D8): the bounded counts of the PENDING rows of THIS fake's table
    # ({inviter, :pending} per (room, invitee)), like the real InviteDB.pending_invite_counts/3 (its SQL is pinned in room/invite_caps_db_test.exs)
    def pending_invite_counts(inviter, invitee_ids, limit) do
      pending = :ets.match(:invite_user_test_db, {{:invitation, :"$1", :"$2"}, {:"$3", :pending}})
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

    def get_pending_invite_rooms_for_user(_user_id), do: {:ok, []}
    def get_declined_invite_rooms_for_user(_user_id), do: {:ok, []}
  end

  defmodule FailingInviteDB do
    def insert_invitation(_room_id, _inviter, _invitee), do: {:error, :db_error}
    def accept_invitation(_room_id, _invitee_id), do: :ok
    def reject_invitation(_room_id, _invitee_id), do: :ok

    # story rate-limits-join-invite-create-room (DATA adaptation of the fake): this fake models a failing row WRITE; the count read of the caps
    # (which comes before the write) finds nothing pending
    def pending_invite_counts(_inviter, invitee_ids, _limit),
      do: {:ok, %{inviter: 0, invitees: Map.new(invitee_ids, &{&1, %{total: 0, from_inviter: 0}})}}

    def get_pending_invite_rooms_for_user(_user_id), do: {:ok, []}
    def get_declined_invite_rooms_for_user(_user_id), do: {:ok, []}
  end

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    # ETS table for FakeDB (public so Room GenServer processes can access it).
    if :ets.info(:invite_user_test_db) != :undefined do
      :ets.delete(:invite_user_test_db)
    end

    :ets.new(:invite_user_test_db, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    # Story create-room-presets-power-levels-topic (D1): invite_user/2 reads the target's membership through rooms_db_module()
    prior_rooms_db = Application.fetch_env(:event_dispatcher, :rooms_db_module)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)

    # Story create-room-invites-direct (D3, DATA adaptation): invite_user/2 refuses foreign-domain invitees, so the server name is pinned
    # to the domain of the invitees used here (many older suites DELETE :server_name on exit, which falls back to "localhost").
    Nebu.Test.ServerName.pin!("test.local")
    :ets.insert(:invite_user_test_db, {:observer, self()})

    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      case prior_rooms_db do
        {:ok, value} -> Application.put_env(:event_dispatcher, :rooms_db_module, value)
        :error -> Application.delete_env(:event_dispatcher, :rooms_db_module)
      end

      Application.delete_env(:room_manager, :db_module)
      Application.delete_env(:event_dispatcher, :invite_db_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:compliance, :audit_writer)

      if :ets.info(:invite_user_test_db) != :undefined do
        :ets.delete(:invite_user_test_db)
      end
    end)

    :ok
  end

  defp build_stream do
    %{http_request_headers: %{"x-user-id" => "@marie:test.local", "x-system-role" => "user"}}
  end

  # Starts a room via Horde and registers on_exit cleanup.
  defp start_and_track_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, _pid} -> :ok
      _ -> {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
    end

    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
          {:ok, pid} ->
            Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
          _ -> :ok
        end
      end
    end)

    :ok
  end

  # ─── AC1: invite_user broadcasts {:new_invite, room_id} to "user:#{invitee}" ──
  #
  # Given: test process subscribes to :pg group "user:@alex:test.local"
  # When: invite_user called with room_id + inviter=marie + invitee=alex
  # Then: test process receives {:new_invite, room_id} within 200 ms

  describe "invite_user/2 — :pg notification to invitee" do
    test "broadcasts {:new_invite, room_id} to user-level :pg group for invitee" do
      room_id = "!inv-test-#{System.unique_integer([:positive])}:test.local"
      invitee = "@alex:test.local"

      # Start room and make marie a member (she must be a member to invite).
      :ok = start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, "@marie:test.local")

      # Subscribe to invitee's user-level :pg group (simulates sync task).
      :ok = :pg.join("user:#{invitee}", self())
      on_exit(fn -> :pg.leave("user:#{invitee}", self()) end)

      request = %Core.InviteUserRequest{
        room_id: room_id,
        inviter_id: "@marie:test.local",
        invitee_id: invitee
      }

      Server.invite_user(request, build_stream())

      assert_receive {:new_invite, ^room_id}, 200,
        "Expected {:new_invite, #{room_id}} from invite_user broadcast within 200 ms."
    end

    test "does NOT broadcast when insert_invitation fails" do
      Application.put_env(:event_dispatcher, :invite_db_module, FailingInviteDB)

      room_id = "!inv-fail-#{System.unique_integer([:positive])}:test.local"
      invitee = "@bob:test.local"

      :ok = start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, "@marie:test.local")

      :ok = :pg.join("user:#{invitee}", self())
      on_exit(fn -> :pg.leave("user:#{invitee}", self()) end)

      request = %Core.InviteUserRequest{
        room_id: room_id,
        inviter_id: "@marie:test.local",
        invitee_id: invitee
      }

      assert_raise Nebu.Matrix.Error, fn ->
        Server.invite_user(request, build_stream())
      end

      refute_receive {:new_invite, _}, 100,
        "Must NOT broadcast {:new_invite, _} when insert_invitation fails"
    end

    test "does nothing when no process is subscribed to invitee user group" do
      room_id = "!inv-nosub-#{System.unique_integer([:positive])}:test.local"
      invitee = "@charlie:test.local"

      :ok = start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, "@marie:test.local")

      # No subscription to "user:#{invitee}" — broadcast should be a no-op (no crash).
      request = %Core.InviteUserRequest{
        room_id: room_id,
        inviter_id: "@marie:test.local",
        invitee_id: invitee
      }

      assert %Core.InviteUserResponse{} = Server.invite_user(request, build_stream())
    end
  end

  # ─── Story create-room-presets-power-levels-topic (D1): the target's membership is read, fail closed ─────────────

  describe "invite_user/2 — the target's latest membership (D1)" do
    test "a failing membership read is a 500 (fail closed): Nebu.Matrix.Error internal, no invitation row, no broadcast" do
      room_id = "!inv-memberr-#{System.unique_integer([:positive])}:test.local"
      invitee = "@dora:test.local"
      :ok = start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, "@marie:test.local")
      :ets.insert(:invite_user_test_db, {:membership_read_error, :db_down})

      :ok = :pg.join("user:#{invitee}", self())
      on_exit(fn -> :pg.leave("user:#{invitee}", self()) end)

      request = %Core.InviteUserRequest{room_id: room_id, inviter_id: "@marie:test.local", invitee_id: invitee}

      assert {:error, {500, _errcode, _}} = Nebu.Matrix.Http.call_core(fn -> Server.invite_user(request, build_stream()) end)
      assert :ets.match(:invite_user_test_db, {{:inserted, :_}, :_}) == [], "insert_invitation/3 was not called"
      refute_receive {:new_invite, _}, 100
    end

    test "a banned target is 403 and no invitation row is written; a target who left is invited" do
      room_id = "!inv-banned-#{System.unique_integer([:positive])}:test.local"
      :ok = start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, "@marie:test.local")
      :ets.insert(:invite_user_test_db, {{:membership, room_id, "@banned:test.local"}, "ban"})
      :ets.insert(:invite_user_test_db, {{:membership, room_id, "@left:test.local"}, "leave"})

      invite = fn invitee ->
        Nebu.Matrix.Http.call_core(fn ->
          Server.invite_user(%Core.InviteUserRequest{room_id: room_id, inviter_id: "@marie:test.local", invitee_id: invitee}, build_stream())
        end)
      end

      assert {:error, {403, "M_FORBIDDEN", _}} = invite.("@banned:test.local")
      assert :ets.match(:invite_user_test_db, {{:inserted, :_}, :"$1"}) == []
      assert {:ok, %Core.InviteUserResponse{}} = invite.("@left:test.local")
      assert [[{^room_id, "@marie:test.local", "@left:test.local"}]] = :ets.match(:invite_user_test_db, {{:inserted, :_}, :"$1"})
    end
  end

  # ═══ Story create-room-invites-direct (D1-D3): the shared invite path of POST /rooms/{roomId}/invite ═══════════════════════════
  #
  # invite_user/2 = the request part (room running, inviter member, inviter `invite` level: unchanged order and texts) + D3 (the
  # invitee is a LOCAL, existing, ACTIVE account) + the shared helper of createRoom step 8 (member -> ban -> already invited -> row ->
  # signed invite event -> broadcast). The body checks of the route (D4) are the HTTP test (create_room_invites_http_test.exs).

  import ExUnit.CaptureLog

  alias Nebu.Matrix.Http

  @marie "@marie:test.local"
  @bob "@bob:test.local"

  defp new_room(label) do
    room_id = "!inv-#{label}-#{System.unique_integer([:positive])}:test.local"
    :ok = start_and_track_room(room_id)
    :ok = Nebu.Matrix.Room.Server.join(room_id, @marie)
    room_id
  end

  defp invite_core(room_id, inviter, invitee) do
    request = %Core.InviteUserRequest{room_id: room_id, inviter_id: inviter, invitee_id: invitee}
    Http.call_core(fn -> Server.invite_user(request, %{http_request_headers: %{"x-user-id" => inviter, "x-system-role" => "user"}}) end)
  end

  defp ets_events(room_id) do
    :ets.match(:invite_user_test_db, {{:event, :_}, :"$1"})
    |> Enum.map(fn [e] -> e end)
    |> Enum.filter(&(&1["room_id"] == room_id))
    |> Enum.sort_by(& &1["__seq"])
  end

  defp invite_events(room_id, user),
    do: Enum.filter(ets_events(room_id), &(&1["type"] == "m.room.member" and &1["state_key"] == user and get_in(&1, ["content", "membership"]) == "invite"))

  defp row_writes, do: :ets.match(:invite_user_test_db, {{:inserted, :_}, :"$1"}) |> List.flatten()
  defp reject_writes, do: :ets.match(:invite_user_test_db, {{:rejected, :_}, :"$1"}) |> List.flatten()
  defp eligibility_reads, do: :ets.match(:invite_user_test_db, {{:eligibility_call, :_}, :"$1"}) |> Enum.map(fn [ids] -> ids end)
  defp row_state(room_id, user), do: (case :ets.lookup(:invite_user_test_db, {:invitation, room_id, user}) do [{_, {_, state}}] -> state; [] -> :none end)

  # the ordered notifications of ONE invite. invite_user/2 runs in the TEST process and writes the row, the event and the broadcast
  # from it, so the messages it sends to itself arrive in the order of the writes (a mailbox of one sender is ordered). The joins of the
  # room fixture come from the Room.Server process and are filtered out. If the implementation ever moved a write into another
  # process this helper would no longer prove an order: then assert only "row before broadcast" with a timestamp from the fake.
  defp ordered_notifications(user) do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.flat_map(messages, fn
      {:row_written, ^user} -> [:row]
      {:event_written, ^user, "invite"} -> [:event]
      {:new_invite, _room} -> [:broadcast]
      _ -> []
    end)
  end

  describe "invite_user/2 - the shared path (D1, D2): row, then a signed invite event, then the broadcast" do
    test "a valid invite writes the row, THEN one invite event (sender inviter, content exactly invite), THEN broadcasts" do
      room_id = new_room("order")
      :ok = :pg.join("user:#{@bob}", self())

      assert {:ok, %Core.InviteUserResponse{}} = invite_core(room_id, @marie, @bob)

      assert [event] = invite_events(room_id, @bob)
      assert event["sender"] == @marie
      assert event["content"] == %{"membership" => "invite"}
      assert is_map(event["signatures"]) and event["signatures"] != %{}, "the event is signed"
      assert row_writes() == [{room_id, @marie, @bob}]
      assert row_state(room_id, @bob) == :pending
      assert ordered_notifications(@bob) == [:row, :event, :broadcast]
      assert eligibility_reads() == [[@bob]], "ONE existence read for the invitee"
    end

    test "the invite event is fanned out to the room's :pg group (members' sync tasks wake up) like every state event" do
      room_id = new_room("fanout")
      :ok = :pg.join("room:#{room_id}", self())

      assert {:ok, _} = invite_core(room_id, @marie, @bob)

      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => @bob, "content" => %{"membership" => "invite"}}}, 500
    end

    test "POST /invite never sets is_direct and never writes a reason on its event (D2, known deviation)" do
      room_id = new_room("nodirect")
      assert {:ok, _} = invite_core(room_id, @marie, @bob)
      assert [%{"content" => content}] = invite_events(room_id, @bob)
      refute Map.has_key?(content, "is_direct")
      refute Map.has_key?(content, "reason")
    end

    test "the same invite again while pending is a 200 no-op: no second row write, no second event, no second broadcast" do
      room_id = new_room("again")
      :ok = :pg.join("user:#{@bob}", self())

      assert {:ok, _} = invite_core(room_id, @marie, @bob)
      assert {:ok, %Core.InviteUserResponse{}} = invite_core(room_id, @marie, @bob)

      assert length(row_writes()) == 1, "the row is not refreshed"
      assert length(invite_events(room_id, @bob)) == 1, "no second invite event"
      assert ordered_notifications(@bob) == [:row, :event, :broadcast], "no second broadcast"
    end

    test "a pending row WITHOUT an invite event (older invitation / upgrade) is not 'already invited': the event is written now" do
      room_id = new_room("legacy")
      :ets.insert(:invite_user_test_db, {{:invitation, room_id, @bob}, {@marie, :pending}})

      assert {:ok, _} = invite_core(room_id, @marie, @bob)
      assert length(invite_events(room_id, @bob)) == 1
      assert length(row_writes()) == 1, "the row is refreshed (insert_invitation/3 re-arms a pending row)"
    end

    test "the no-op needs BOTH: a latest membership invite with a REJECTED row is re-armed and gets a new event" do
      room_id = new_room("stale")
      :ets.insert(:invite_user_test_db, {{:membership, room_id, @bob}, "invite"})
      :ets.insert(:invite_user_test_db, {{:invitation, room_id, @bob}, {@marie, :rejected}})

      assert {:ok, _} = invite_core(room_id, @marie, @bob)
      assert row_state(room_id, @bob) == :pending
      assert length(invite_events(room_id, @bob)) == 1
    end

    test "after a decline (latest membership leave, rejected row) a new invite is 200: row re-armed, a NEW invite event" do
      room_id = new_room("redo")
      :ets.insert(:invite_user_test_db, {{:membership, room_id, @bob}, "leave"})
      :ets.insert(:invite_user_test_db, {{:invitation, room_id, @bob}, {@marie, :rejected}})

      assert {:ok, _} = invite_core(room_id, @marie, @bob)
      assert row_state(room_id, @bob) == :pending
      assert length(invite_events(room_id, @bob)) == 1
    end

    test "a member (self-invite included) is 403 'The invited user is already in this room': nothing is written" do
      room_id = new_room("member")
      assert {:error, {403, "M_FORBIDDEN", "The invited user is already in this room"}} = invite_core(room_id, @marie, @marie)
      assert row_writes() == [] and invite_events(room_id, @marie) == []
    end
  end

  describe "invite_user/2 - failures write nothing half-way (D1)" do
    test "a failing invite EVENT write after the row is a 500, the row is rejected again, no broadcast, the invitation cannot be used" do
      room_id = new_room("evfail")
      :ok = :pg.join("user:#{@bob}", self())
      :ets.insert(:invite_user_test_db, {:fail_invite_event, :simulated_db_down})

      assert {:error, {500, _errcode, _}} = invite_core(room_id, @marie, @bob)

      assert reject_writes() == [{room_id, @bob}], "reject_invitation/2 was called for the invitee"
      assert row_state(room_id, @bob) == :rejected
      assert {:ok, false} = FakeInviteDB.pending_invite?(room_id, @bob), "no half invitation that is joinable but invisible"
      assert invite_events(room_id, @bob) == []
      refute_receive {:new_invite, _}, 100
    end

    test "when the re-reject fails too the answer is still a 500, the logs name only the room id and the error class" do
      marker = "mkrej" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      invitee = "@" <> marker <> ":test.local"
      room_id = new_room("rejfail")

      pg = fn ->
        %Postgrex.Error{message: "simulated #{marker}", postgres: %{code: :untranslatable_character, pg_code: "22P05", severity: "ERROR", message: "x", where: marker}}
      end

      :ets.insert(:invite_user_test_db, {:fail_invite_event, pg.()})
      :ets.insert(:invite_user_test_db, {:fail_reject, pg.()})

      ref = make_ref()
      log = capture_log(fn -> send(self(), {ref, invite_core(room_id, @marie, invitee)}) end)
      assert_received {^ref, result}

      assert {:error, {500, _, message}} = result
      refute message =~ marker
      assert log =~ room_id
      assert log =~ "postgres 22P05"
      refute String.downcase(log) =~ marker, "no invitee id / database text in the log"
      refute log =~ @marie
    end

    test "a failing existence read is a 500 (fail closed): nothing written, no broadcast, the log carries no invitee id" do
      marker = "mkelig" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      invitee = "@" <> marker <> ":test.local"
      room_id = new_room("eligfail")
      :ok = :pg.join("user:#{invitee}", self())
      :ets.insert(:invite_user_test_db, {:fail_eligibility, :db_down})

      ref = make_ref()
      log = capture_log(fn -> send(self(), {ref, invite_core(room_id, @marie, invitee)}) end)
      assert_received {^ref, result}

      assert {:error, {500, _, _}} = result
      assert row_writes() == [] and invite_events(room_id, invitee) == []
      refute_receive {:new_invite, _}, 100
      refute String.downcase(log) =~ marker
    end
  end

  # ═══ Review cycle 1 (code review M1 / M2 / M3 = Kassandra L-2): the compensation of a failed invite event is CONDITIONAL ═══════════

  describe "invite_user/2 - the compensating reject only undoes what THIS call created (review cycle 1)" do
    defp unique_violation do
      %Postgrex.Error{
        message: "simulated unique_violation",
        postgres: %{code: :unique_violation, pg_code: "23505", severity: "ERROR", message: "duplicate key value violates unique constraint", where: "x"}
      }
    end

    test "a concurrent identical invite: a unique violation on the event insert is 'already invited' (200), the winner's row is NOT rejected" do
      room_id = new_room("race")
      :ok = :pg.join("user:#{@bob}", self())
      # the winner's event is already there when the loser re-reads the membership after its failed insert
      :ets.insert(:invite_user_test_db, {{:membership, room_id, @bob}, "invite"})
      :ets.insert(:invite_user_test_db, {:fail_invite_event, unique_violation()})

      assert {:ok, %Core.InviteUserResponse{}} = invite_core(room_id, @marie, @bob)

      assert reject_writes() == [], "the winner's invitation must survive"
      assert row_state(room_id, @bob) == :pending
      refute_receive {:new_invite, _}, 100
    end

    test "a unique violation while the latest membership is NOT invite is no 'already invited': 500 and the row this call created is rejected" do
      room_id = new_room("racebad")
      :ets.insert(:invite_user_test_db, {:fail_invite_event, unique_violation()})

      assert {:error, {500, _, _}} = invite_core(room_id, @marie, @bob)
      assert reject_writes() == [{room_id, @bob}]
      assert row_state(room_id, @bob) == :rejected
    end

    test "a legacy PENDING row without an invite event survives a failing event write: 500, no reject, the row stays pending (joinable)" do
      room_id = new_room("legacyfail")
      :ets.insert(:invite_user_test_db, {{:invitation, room_id, @bob}, {@marie, :pending}})
      :ets.insert(:invite_user_test_db, {:fail_invite_event, :simulated_db_down})

      assert {:error, {500, _, _}} = invite_core(room_id, @marie, @bob)

      assert reject_writes() == [], "a pre-existing valid invitation is not this call's to undo"
      assert row_state(room_id, @bob) == :pending
      assert {:ok, true} = FakeInviteDB.pending_invite?(room_id, @bob)
      assert invite_events(room_id, @bob) == []
    end

    test "a rejected / accepted (formerly valid) row that this call re-armed IS rejected again when the event write fails" do
      room_id = new_room("rearmfail")
      :ets.insert(:invite_user_test_db, {{:invitation, room_id, @bob}, {@marie, :rejected}})
      :ets.insert(:invite_user_test_db, {:fail_invite_event, :simulated_db_down})

      assert {:error, {500, _, _}} = invite_core(room_id, @marie, @bob)
      assert reject_writes() == [{room_id, @bob}]
      assert row_state(room_id, @bob) == :rejected
    end

    test "a failing reject on POST /invite is retried ONCE and logged at ERROR 'half invitation remains' (room id and error class only)" do
      marker = "mkhalf" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      invitee = "@" <> marker <> ":test.local"
      room_id = new_room("halfrej")

      pg = fn ->
        %Postgrex.Error{message: "simulated #{marker}", postgres: %{code: :untranslatable_character, pg_code: "22P05", severity: "ERROR", message: "x", where: marker}}
      end

      :ets.insert(:invite_user_test_db, {:fail_invite_event, pg.()})
      :ets.insert(:invite_user_test_db, {:fail_reject, pg.()})

      ref = make_ref()
      log = capture_log([level: :error], fn -> send(self(), {ref, invite_core(room_id, @marie, invitee)}) end)
      assert_received {^ref, result}

      assert {:error, {500, _, message}} = result
      refute message =~ marker
      assert length(reject_writes()) == 2, "one retry of the reject"
      assert log =~ "half invitation remains"
      assert log =~ room_id
      assert log =~ "postgres 22P05"
      refute String.downcase(log) =~ marker
      refute log =~ @marie
    end

    test "an invitee id longer than 255 bytes is 400 M_INVALID_PARAM before any room read" do
      long = "@" <> String.duplicate("a", 250) <> ":test.local"
      assert {:error, {400, "M_INVALID_PARAM", _}} = invite_core("!nope-long:test.local", @marie, long)
      assert eligibility_reads() == []
    end
  end

  describe "invite_user/2 - who can be invited (D3) and the order of the checks" do
    test "a foreign-domain invitee is 403 M_FORBIDDEN with the fixed no-federation text (no read, nothing written, no id echoed)" do
      room_id = new_room("foreign")
      assert {:error, {403, "M_FORBIDDEN", message}} = invite_core(room_id, @marie, "@x:other.example")

      assert message == "Users of other servers cannot be invited: this server does not federate"
      assert eligibility_reads() == [], "the domain check is pure"
      assert row_writes() == [] and invite_events(room_id, "@x:other.example") == []
    end

    test "an unknown and a deactivated local invitee are the SAME 404 M_NOT_FOUND with the fixed text: nothing written" do
      room_id = new_room("unknown")
      :ets.insert(:invite_user_test_db, {{:user_missing, "@ghost:test.local"}, true})
      :ets.insert(:invite_user_test_db, {{:user_inactive, "@gone:test.local"}, true})

      assert {:error, {404, "M_NOT_FOUND", unknown}} = invite_core(room_id, @marie, "@ghost:test.local")
      assert {:error, {404, "M_NOT_FOUND", deactivated}} = invite_core(room_id, @marie, "@gone:test.local")

      assert unknown == deactivated
      assert unknown == "The user to invite does not exist on this server"
      assert row_writes() == []
      assert invite_events(room_id, "@ghost:test.local") == [] and invite_events(room_id, "@gone:test.local") == []
    end

    test "the inviter's checks come FIRST: a non-member inviting an unknown user is the inviter 403, a missing room the room 404, no existence read" do
      room_id = new_room("order2")
      :ets.insert(:invite_user_test_db, {{:user_missing, "@ghost:test.local"}, true})

      assert {:error, {403, "M_FORBIDDEN", "You are not a member of this room"}} = invite_core(room_id, "@stranger:test.local", "@ghost:test.local")
      assert {:error, {404, "M_NOT_FOUND", "Room not found"}} = invite_core("!nope-#{System.unique_integer([:positive])}:test.local", @marie, "@ghost:test.local")
      assert {:error, {403, "M_FORBIDDEN", _}} = invite_core(room_id, "@stranger:test.local", "@x:other.example")
      assert eligibility_reads() == []
    end

    test "(i) an inviter below the invite level (override invite 50, member at level 0) is 403 before the existence read: no row, no event" do
      room_id = "!inv-lowpl-#{System.unique_integer([:positive])}:test.local"
      :ok = start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, @marie)
      levels = Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.merge(%{"invite" => 50, "users" => %{"@admin:test.local" => 100}})
      :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, @marie, levels)
      :ets.insert(:invite_user_test_db, {{:user_missing, "@ghost:test.local"}, true})

      assert {:error, {403, "M_FORBIDDEN", _}} = invite_core(room_id, @marie, @bob)
      assert {:error, {403, "M_FORBIDDEN", _}} = invite_core(room_id, @marie, "@ghost:test.local")
      assert row_writes() == [] and invite_events(room_id, @bob) == []
      assert eligibility_reads() == []
    end

    test "(j) re-invite after a BAN (internal ban_user/2) is 403, no row, no event; a target who left voluntarily is invited again with a new event" do
      room_id = "!inv-ban-#{System.unique_integer([:positive])}:test.local"
      :ok = start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, @marie)
      levels = Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", %{@marie => 100})
      :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, @marie, levels)

      ban = %Core.BanUserRequest{room_id: room_id, target_id: @bob, reason: ""}
      assert {:ok, %Core.BanUserResponse{}} = Http.call_core(fn -> Server.ban_user(ban, Http.stream(@marie)) end)

      assert {:error, {403, "M_FORBIDDEN", _}} = invite_core(room_id, @marie, @bob)
      assert row_writes() == []
      assert invite_events(room_id, @bob) == []

      :ets.insert(:invite_user_test_db, {{:membership, room_id, "@left:test.local"}, "leave"})
      assert {:ok, _} = invite_core(room_id, @marie, "@left:test.local")
      assert length(invite_events(room_id, "@left:test.local")) == 1
    end
  end
end
