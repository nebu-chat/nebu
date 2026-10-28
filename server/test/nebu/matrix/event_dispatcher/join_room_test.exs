defmodule Nebu.Matrix.EventDispatcher.JoinRoomTest do
  use ExUnit.Case, async: false

  # ─── Story 4-10: Elixir join_room/2 gRPC handler ─────────────────────────────
  #
  # These tests are written FIRST (ATDD gate), before implementation exists.
  # ALL tests in this module are expected to FAIL until Story 4-10 is implemented.
  #
  # async: false — Horde.Registry, Horde.DynamicSupervisor, Application.put_env,
  # and the ETS :NebuTxnDedup table are all process-global resources.
  #
  # Test strategy:
  #   - All tests call Nebu.Matrix.EventDispatcher.Server.join_room/2 directly
  #     (synchronous unary handler — no spawning needed).
  #   - Fake stream: minimal map matching the real gRPC stream contract.
  #   - DB injection: Room.Server.init/1 uses Application.get_env(:room_manager, :db_module).
  #     We inject FakeDB (same pattern as create_room_test.exs) to avoid PostgreSQL.
  #   - Rooms used in tests are started via Nebu.Matrix.Room.RoomSupervisor.start_room/1
  #     and tracked with on_exit cleanup to prevent cross-test Horde pollution.
  #   - The :NebuTxnDedup ETS table is cleared before each test.
  #   - join_room idempotency: calling join/2 on an already-member user must
  #     return {:ok, ...} (not an error) — the handler must propagate this as
  #     JoinRoomResponse (Matrix spec requirement, AC #7).

  alias Nebu.Matrix.EventDispatcher.Server

  # ─── FakeDB ──────────────────────────────────────────────────────────────────
  #
  # ETS-backed fake satisfying the Nebu.Matrix.Room.DB behaviour.
  # Injected via Application.put_env(:room_manager, :db_module, FakeDB).
  # No PostgreSQL connection is required.

  # No-op audit writer — Story 5-2 wired Server.join_room/2 to emit an
  # audit log entry; this test does not verify that emission (covered in
  # audit_room_ops_test.exs) and must not depend on Nebu.Repo.
  defmodule NoOpAuditWriter do
    # records the rows (story create-room-presets-power-levels-topic: a REFUSED join writes no `room_joined` row); the name is historic
    def log(actor, action, _target_type, target_id, _metadata, _outcome, _detail \\ nil) do
      if :ets.info(:join_room_test_db) != :undefined, do: :ets.insert(:join_room_test_db, {{:audit, make_ref()}, {actor, action, target_id}})
      :ok
    end
  end

  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:join_room_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members =
            :ets.match(:join_room_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:join_room_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:join_room_test_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:join_room_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    # review cycle 1 (F-2): `{:delete_fail, room_id}` makes the member removal fail
    def delete_member(room_id, user_id) do
      case :ets.lookup(:join_room_test_db, {:delete_fail, room_id}) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          :ets.delete(:join_room_test_db, {:member, room_id, user_id})
          :ok
      end
    end

    # Review cycle 2 (N-1): every m.room.member event updates the "latest membership" (`{:latest_member, room, user}`), which is what
    # get_member_membership/2 answers when nothing is seeded. THE JOIN WRITES ITS OWN JOIN EVENT (Room.Server.join/2 ->
    # emit_membership_event), which is newer than a ban written before it: a re-read after the join cannot see that ban.
    #
    # Story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): the `{:rejoin_on_ban, room, user}` /
    # `{:rejoin_then_fail_delete, room}` hooks are gone. They modelled the deleted two-removal ban (a join slipping in while the ban
    # event was written in the CALLER) and re-entered Room.Server from inside the write, which the room process now performs itself
    # (a deadlock). The race is proven on the real database instead (moderation_concurrency_test.exs, AC7 (a)).
    def insert_event(event) do
      member_event? = event["type"] == "m.room.member"
      membership = get_in(event, ["content", "membership"])

      :ets.insert(:join_room_test_db, {{:event, event["event_id"]}, event})

      if member_event?,
        do: :ets.insert(:join_room_test_db, {{:latest_member, event["room_id"], event["state_key"]}, membership})

      # story sync-membership-partition (D13, DATA adaptation of the fake): the latest member event WITH its timestamp and sender, which
      # latest_member_event/2 answers (an insertion counter when the event has no timestamp: never a clock tie)
      if member_event? do
        ts = event["origin_server_ts"] || :ets.update_counter(:join_room_test_db, :member_event_ts, 1, {:member_event_ts, 1_000})

        :ets.insert(
          :join_room_test_db,
          {{:member_event, event["room_id"], event["state_key"]},
           %{event_id: event["event_id"], membership: membership, origin_server_ts: ts, sender: event["sender"] || event["state_key"]}}
        )
      end

      :ok
    end

    # Story moderation-routes-atomic-ban (AC16 (b), DATA adaptation of the fake): the ONE transaction of Room.DB.apply_member_change/4, all
    # or nothing. The failure switches of the separate statements (`{:delete_fail, room}` for the member removal, `:reject_fail` /
    # `:reject_fail_once` for the invitation reject) fail the WHOLE change before anything is applied (the rollback); otherwise the member
    # row is closed, the pending invitation rejected (through FakeInviteDB) and the event stored (insert_event/1: the latest member event
    # follows it). Recorded like the other calls.
    def apply_member_change(room_id, user_id, event, opts) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:apply_member_change, room_id, user_id}})
      remove? = Keyword.get(opts, :remove_member, false)
      reject? = Keyword.get(opts, :reject_invitation, false)

      cond do
        remove? and :ets.lookup(:join_room_test_db, {:delete_fail, room_id}) != [] ->
          [{_, reason}] = :ets.lookup(:join_room_test_db, {:delete_fail, room_id})
          {:error, reason}

        reject? and :ets.lookup(:join_room_test_db, :reject_fail) != [] ->
          {:error, :db_down}

        reject? and :ets.lookup(:join_room_test_db, :reject_fail_once) != [] ->
          :ets.delete(:join_room_test_db, :reject_fail_once)
          {:error, :db_down}

        true ->
          if remove?, do: :ets.delete(:join_room_test_db, {:member, room_id, user_id})
          if reject?, do: :ok = Nebu.Matrix.EventDispatcher.JoinRoomTest.FakeInviteDB.reject_invitation(room_id, user_id)
          if is_map(event), do: :ok = insert_event(event)
          :ok
      end
    end

    # story moderation-routes-atomic-ban (D2 (4)): the room process reads the pending invitation through its own db module (Room.DB
    # delegates to InviteDB); the fake delegates to FakeInviteDB, the one store of this suite's invitations
    def pending_invitation(room_id, user_id), do: Nebu.Matrix.EventDispatcher.JoinRoomTest.FakeInviteDB.pending_invitation(room_id, user_id)

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(:join_room_test_db, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    # Story 6.8: load_room_settings/1 returns {:ok, 0} (no limit) for unit tests.
    def load_room_settings(_room_id), do: {:ok, 0}

    # Story 6.9: get_room_status/1 — returns {:ok, "active"} so normal rooms start correctly.
    def get_room_status(_room_id), do: {:ok, "active"}

    # Story 9-9: TOCTOU fix — returns {:ok, "active"} for normal rooms.
    def check_room_status_for_update(_room_id), do: {:ok, "active"}

    # GAP-LEAVE-UI: required by @behaviour Nebu.Matrix.Room.DBBehaviour.
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}

    # Story create-room-invites-direct (D3, DATA adaptation of the fake): invite_user/2 reads the existence of the invitee through
    # rooms_db_module().invitable_local_users/1 (the ids that are existing ACTIVE local accounts); every local id of this suite is one.
    def invitable_local_users(user_ids), do: {:ok, user_ids}
    # Story personal-self-room: personal room callbacks.
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    # Story direct-room-heroes + admin-auto-join-rooms: required stubs.
    def get_room_heroes(_room_id, _exclude_user_id), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
    def list_auto_join_rooms(), do: {:ok, []}

    # ── story create-room-presets-power-levels-topic (D1): the join decision reads the join rule state and the latest
    # membership of the joining user. Both reads are recorded (`calls/1` in the test) and can be made to fail / raise.
    #
    # get_generic_state_events/1 has the real Room.DB shape (`content_json` is the jsonb as text); seeded with seed_state/2.
    def get_generic_state_events(room_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:get_generic_state_events, room_id}})

      # review cycle 2 (N-1): `{:ban_on_state_read, room, user}` commits a ban (a ban event, newer than anything so far) right after
      # the ban read of the join decision, i.e. between authorize_join!/2 and Room.Server.join/2
      for [user] <- :ets.match(:join_room_test_db, {{:ban_on_state_read, room_id, :"$1"}, true}) do
        :ets.delete(:join_room_test_db, {:ban_on_state_read, room_id, user})

        insert_event(%{
          "event_id" => "$ban-#{System.unique_integer([:positive])}",
          "room_id" => room_id,
          "type" => "m.room.member",
          "state_key" => user,
          "sender" => "@admin:test.local",
          "content" => %{"membership" => "ban"}
        })
      end

      case :ets.lookup(:join_room_test_db, {:state_read, room_id}) do
        [{_, :raise}] -> raise "simulated state read crash"
        [{_, {:error, _} = err}] -> err
        [{_, events}] -> {:ok, events}
        [] -> {:ok, []}
      end
    end

    # get_member_membership/2: the latest m.room.member membership of the user ("join" | "leave" | "ban" | "invite" | nil).
    def get_member_membership(room_id, user_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:get_member_membership, room_id, user_id}})

      case :ets.lookup(:join_room_test_db, {:membership_read, room_id}) do
        [{_, :raise}] ->
          raise "simulated membership read crash"

        [{_, {:error, _} = err}] ->
          err

        [] ->
          # (no test scripts this since story member-event-prev-content: the room process reads latest_member_event/2 now; kept as a capability of the fake)
          # review cycle 1 (F-2): `{:membership_script, room, user} => [first, second, ...]` answers the reads in order (the
          # last value repeats): a membership that FLIPS to `ban` between the join decision and the re-read after the join
          case :ets.lookup(:join_room_test_db, {:membership_script, room_id, user_id}) do
            [{key, [value | rest]}] ->
              :ets.insert(:join_room_test_db, {key, if(rest == [], do: [value], else: rest)})
              if match?({:error, _}, value), do: value, else: {:ok, value}

            [] ->
              case :ets.lookup(:join_room_test_db, {:membership, room_id, user_id}) do
                [{_, membership}] ->
                  {:ok, membership}

                [] ->
                  # the latest member event the fake persisted (a join writes its own), else never a member
                  case :ets.lookup(:join_room_test_db, {:latest_member, room_id, user_id}) do
                    [{_, membership}] -> {:ok, membership}
                    [] -> {:ok, nil}
                  end
              end
          end
      end
    end

    # story sync-membership-partition (D13): `{:ok, %{membership, origin_server_ts, sender} | nil}` (Room.DB.latest_member_event/2, pinned by
    # room/membership_partition_db_test.exs). Seeded with seed_member_event!/5 (an exact timestamp and sender), else derived from what the
    # old seeds say: a seeded membership has timestamp 0 (OLDER than any invitation: the legacy row-only re-invite case), the latest member
    # event the fake persisted has its own. The read is recorded and can be made to fail / raise (`{:latest_event_read, room}`), and it
    # fails whenever the membership read of the room fails (one failing membership source).
    def latest_member_event(room_id, user_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:latest_member_event, room_id, user_id}})

      case {:ets.lookup(:join_room_test_db, {:latest_event_read, room_id}), :ets.lookup(:join_room_test_db, {:membership_read, room_id})} do
        {[{_, :raise}], _} ->
          raise "simulated latest member event read crash"

        {[{_, {:error, _} = err}], _} ->
          err

        {_, [{_, :raise}]} ->
          raise "simulated membership read crash"

        {_, [{_, {:error, _} = err}]} ->
          err

        _ ->
          # precedence as get_member_membership/2: an explicit seed, then a seeded membership (timestamp 0), then the persisted event
          seeded = :ets.lookup(:join_room_test_db, {:seeded_member_event, room_id, user_id})
          membership = :ets.lookup(:join_room_test_db, {:membership, room_id, user_id})
          persisted = :ets.lookup(:join_room_test_db, {:member_event, room_id, user_id})

          cond do
            seeded != [] -> {:ok, seeded |> hd() |> elem(1)}
            membership != [] -> {:ok, %{membership: membership |> hd() |> elem(1), origin_server_ts: 0, sender: user_id}}
            persisted != [] -> {:ok, persisted |> hd() |> elem(1)}
            true -> {:ok, nil}
          end
      end
    end
  end

  # ─── FakeInviteDB ─────────────────────────────────────────────────────────────
  #
  # ETS-backed fake for invitation persistence. Injected via
  # Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB).
  # No PostgreSQL FK constraint enforcement in tests.

  defmodule FakeInviteDB do
    # One row per insert in the bag table; accepted / rejected markers live in the main table, so that
    # get_pending_invite_rooms_for_user/1 has the semantics of the real InviteDB (neither accepted nor rejected).
    # A (re-)invite clears the markers: the pending invitation exists again (the real InviteDB needs the same
    # semantics for `invite -> join -> leave -> invite -> join`; see the HTTP test of the story).
    def insert_invitation(room_id, inviter_id, invitee_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:insert_invitation, room_id, inviter_id, invitee_id}})
      :ets.insert(:join_room_test_invitations, {room_id, inviter_id, invitee_id})
      :ets.delete(:join_room_test_db, {:invite_state, room_id, invitee_id})
      # story sync-membership-partition (D13, DATA adaptation): the row's invited_at, from the same insertion counter as the member events
      # (a re-arm refreshes it, like the real InviteDB); never a clock
      ts = :ets.update_counter(:join_room_test_db, :member_event_ts, 1, {:member_event_ts, 1_000})
      :ets.insert(:join_room_test_db, {{:invited_at, room_id, invitee_id}, ts})
      :ok
    end

    # story sync-membership-partition (D13): `{:ok, invited_at | nil}` for a PENDING row (InviteDB.pending_invitation/2, pinned by
    # room/membership_partition_db_test.exs). Recorded; fails / raises like the other pending read (`:pending_read`).
    def pending_invitation(room_id, invitee_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:pending_invitation, room_id, invitee_id}})

      case :ets.lookup(:join_room_test_db, :pending_read) do
        [{_, :raise}] ->
          raise "simulated pending invitation read crash"

        [{_, {:error, _} = err}] ->
          err

        [] ->
          if pending?(room_id, invitee_id) do
            case :ets.lookup(:join_room_test_db, {:invited_at, room_id, invitee_id}) do
              [{_, ts}] -> {:ok, ts}
              [] -> {:ok, 1}
            end
          else
            {:ok, nil}
          end
      end
    end

    # Story 5.29d AC1 (FB-E5-03): accept_invitation/2 satisfies the Nebu.Matrix.Room.InviteDB interface used by Server.join_room/2
    # when joining an invited room. Marks a pending invitation as accepted (a no-op without one).
    def accept_invitation(room_id, invitee_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:accept_invitation, room_id, invitee_id}})

      case :ets.lookup(:join_room_test_db, :accept_fail) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          if pending?(room_id, invitee_id), do: :ets.insert(:join_room_test_db, {{:invite_state, room_id, invitee_id}, :accepted})
          :ok
      end
    end

    # review cycle 2 (N-5): `:reject_fail` makes every rejection fail, `:reject_fail_once` only the first one
    def reject_invitation(room_id, invitee_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:reject_invitation, room_id, invitee_id}})

      cond do
        :ets.lookup(:join_room_test_db, :reject_fail) != [] ->
          {:error, :db_down}

        :ets.lookup(:join_room_test_db, :reject_fail_once) != [] ->
          :ets.delete(:join_room_test_db, :reject_fail_once)
          {:error, :db_down}

        true ->
          if pending?(room_id, invitee_id), do: :ets.insert(:join_room_test_db, {{:invite_state, room_id, invitee_id}, :rejected})
          :ok
      end
    end

    def get_pending_invite_rooms_for_user(invitee_id) do
      :ets.insert(:join_room_test_db, {{:call, make_ref()}, {:get_pending_invite_rooms_for_user, invitee_id}})

      case :ets.lookup(:join_room_test_db, :pending_read) do
        [{_, :raise}] ->
          raise "simulated pending invite read crash"

        [{_, {:error, _} = err}] ->
          err

        [] ->
          rooms =
            :ets.match(:join_room_test_invitations, {:"$1", :_, invitee_id})
            |> Enum.map(fn [room_id] -> room_id end)
            |> Enum.uniq()
            |> Enum.filter(&pending?(&1, invitee_id))

          {:ok, rooms}
      end
    end

    # create-room-invites-direct review cycle 1 (DATA adaptation): invite_user/2 reads the pending state BEFORE its insert (the
    # compensation of a failed invite event only undoes a row this call created), like the real InviteDB.pending_invite?/2
    def pending_invite?(room_id, invitee_id), do: {:ok, pending?(room_id, invitee_id)}

    # story rate-limits-join-invite-create-room (DATA adaptation of the fake, D8): the bounded counts of the PENDING rows of THIS fake's bag
    # table ({room, inviter, invitee}; a re-arm adds a row: distinct (room, invitee) pairs are counted once, an inviter owns the pair when ANY
    # of its rows names him); the real SQL is pinned in room/invite_caps_db_test.exs
    def pending_invite_counts(inviter, invitee_ids, limit) do
      pending = :join_room_test_invitations |> :ets.tab2list() |> Enum.filter(fn {room, _by, invitee} -> pending?(room, invitee) end)
      pairs = fn pred -> pending |> Enum.filter(pred) |> Enum.map(fn {room, _by, invitee} -> {room, invitee} end) |> Enum.uniq() |> length() end
      bound = fn n -> min(n, limit) end

      invitees =
        Map.new(invitee_ids, fn id ->
          {id,
           %{
             total: bound.(pairs.(fn {_room, _by, invitee} -> invitee == id end)),
             from_inviter: bound.(pairs.(fn {_room, by, invitee} -> invitee == id and by == inviter end))
           }}
        end)

      {:ok, %{inviter: bound.(pairs.(fn {_room, by, _invitee} -> by == inviter end)), invitees: invitees}}
    end

    defp pending?(room_id, invitee_id) do
      :ets.match(:join_room_test_invitations, {room_id, :_, invitee_id}) != [] and
        :ets.lookup(:join_room_test_db, {:invite_state, room_id, invitee_id}) == []
    end
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    # Create the ETS table for FakeDB (public so Room GenServer processes can
    # access it). Guard against stale tables from --watch reruns.
    if :ets.info(:join_room_test_db) != :undefined do
      :ets.delete(:join_room_test_db)
    end

    :ets.new(:join_room_test_db, [:named_table, :public, :set])

    # Create the ETS table for FakeInviteDB.
    if :ets.info(:join_room_test_invitations) != :undefined do
      :ets.delete(:join_room_test_invitations)
    end

    :ets.new(:join_room_test_invitations, [:named_table, :public, :bag])

    # Snapshot the env keys this suite overrides and restore them afterwards (config/runtime.exs sets some of them).
    snapshot =
      for {app, key} <- [
            {:room_manager, :db_module},
            {:event_dispatcher, :invite_db_module},
            {:event_dispatcher, :messages_db_module},
            {:event_dispatcher, :rooms_db_module},
            {:event_dispatcher, :server_name},
            {:compliance, :audit_writer}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    # Inject fake DB modules so Room GenServers and invite handler don't need PostgreSQL.
    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)

    # Story 5.29d AC1 (FB-E5-03): also inject FakeDB as the messages_db_module so
    # Server.join_room/2's insert_event call does not hit Nebu.Repo.
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)

    # Story create-room-presets-power-levels-topic (D1): join_room/2 and invite_user/2 read the latest membership of the
    # user through rooms_db_module() (get_member_membership/2); the fake must serve it (data adaptation of this suite).
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")

    # Story 5-2: Server.join_room/2 now calls Nebu.Compliance.AuditWriter.log/6
    # on the :ok branch. Inject NoOpAuditWriter here so this test does not
    # depend on Nebu.Repo being started in the :test env.
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    # Initialise :pg (built-in OTP, idempotent).
    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Clear :NebuTxnDedup between tests to prevent idempotency state leakage.
    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      for {app, key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      if :ets.info(:join_room_test_db) != :undefined do
        :ets.delete(:join_room_test_db)
      end

      if :ets.info(:join_room_test_invitations) != :undefined do
        :ets.delete(:join_room_test_invitations)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  # ─── Fake gRPC stream ─────────────────────────────────────────────────────────

  defp build_stream do
    %{http_request_headers: %{}}
  end

  # ─── Room GenServer tracking ──────────────────────────────────────────────────
  #
  # Registers an on_exit callback to stop the Room GenServer for room_id.
  # Prevents Horde-managed GenServers from accumulating across tests.

  defp start_and_track_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, _pid} ->
        on_exit(fn ->
          if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
            case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
              {:ok, pid} ->
                Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)

              _ ->
                :ok
            end
          end
        end)

        :ok

      error ->
        error
    end
  end

  # Horde.Registry uses DeltaCrdt which can propagate asynchronously even on a
  # single node. Retry the lookup until the entry appears or we time out.
  defp wait_for_registry(room_id, retries \\ 20) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} when is_pid(pid) ->
        :ok

      _ when retries > 0 ->
        Process.sleep(10)
        wait_for_registry(room_id, retries - 1)

      _ ->
        raise "Horde.Registry did not register #{room_id} within timeout"
    end
  end

  # ─── Helper: start a room and join a user into it directly ───────────────────
  #
  # Uses RoomSupervisor.start_room/1 + Room.Server.join/2 to put the system
  # in the desired pre-condition state without going through the gRPC handler.

  defp setup_room_with_member(room_id, user_id) do
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
    :ok = wait_for_registry(room_id)
    start_and_track_room(room_id)
    :ok = Nebu.Matrix.Room.Server.join(room_id, user_id)
    :ok
  end

  # ─── story create-room-presets-power-levels-topic: helpers for the join decision ────────────────

  # Seeds the room's current generic state as Room.DB.get_generic_state_events/1 returns it. `content` is a map (encoded as the
  # jsonb text the real read returns) or a raw binary (e.g. undecodable text); `nil` is the read of a NULL / missing content.
  defp seed_state(room_id, specs) do
    events =
      for {type, key, content} <- specs do
        json = if is_binary(content) or is_nil(content), do: content, else: Jason.encode!(content)
        %{type: type, state_key: key, content_json: json, sender: "@creator:test.local", event_id: "$" <> type <> key <> ":test.local", origin_server_ts: 1}
      end

    :ets.insert(:join_room_test_db, {{:state_read, room_id}, events})
  end

  defp seed_rule(room_id, content), do: seed_state(room_id, [{"m.room.join_rules", "", content}])

  defp seed_membership(room_id, user_id, membership), do: :ets.insert(:join_room_test_db, {{:membership, room_id, user_id}, membership})

  # story sync-membership-partition (D13): the latest member event of the user WITH its timestamp and author, and the invited_at of the
  # pending row (both explicit, so a decision at an exact boundary is built without a clock)
  defp seed_member_event(room_id, user_id, membership, ts, sender),
    do: :ets.insert(:join_room_test_db, {{:seeded_member_event, room_id, user_id}, %{membership: membership, origin_server_ts: ts, sender: sender}})

  defp set_invited_at(room_id, invitee_id, ts), do: :ets.insert(:join_room_test_db, {{:invited_at, room_id, invitee_id}, ts})

  # a room GenServer, started and registered, with the given members joined directly (the internal bypass: creator join, auto-join)
  defp start_room_with(room_id, members) do
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
    :ok = wait_for_registry(room_id)
    start_and_track_room(room_id)
    for user <- members, do: :ok = Nebu.Matrix.Room.Server.join(room_id, user)
    room_id
  end

  defp new_room_id(label), do: "!#{label}-#{System.unique_integer([:positive])}:test.local"

  defp rand_hex, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  # A room in which the join rule is `content` (a map / raw text, or :absent for no m.room.join_rules event at all).
  defp room_with_rule(label, :absent), do: start_room_with(new_room_id(label), [])

  defp room_with_rule(label, content) do
    room_id = start_room_with(new_room_id(label), [])
    seed_rule(room_id, content)
    room_id
  end

  # `{:ok, response}` | `{:error, {http_status, errcode, message}}`: the public mapping of the core error (HTTP status + Matrix errcode)
  defp join_as(user_id, room_id) do
    Nebu.Matrix.Http.call_core(fn ->
      Server.join_room(%Core.JoinRoomRequest{user_id: user_id, room_id_or_alias: room_id}, build_stream())
    end)
  end

  defp invite!(room_id, inviter, invitee), do: :ok = FakeInviteDB.insert_invitation(room_id, inviter, invitee)

  defp member?(room_id, user_id), do: MapSet.member?(Nebu.Matrix.Room.Server.get_state(room_id).members, user_id)

  # every call the fakes recorded, as `{function, args...}` tuples (the table is a :set: counts and membership tests only, no order)
  defp calls(function) do
    :ets.match(:join_room_test_db, {{:call, :_}, :"$1"})
    |> List.flatten()
    |> Enum.filter(&(elem(&1, 0) == function))
  end

  defp pending_rooms(user_id) do
    {:ok, rooms} = FakeInviteDB.get_pending_invite_rooms_for_user(user_id)
    :ets.match_delete(:join_room_test_db, {{:call, :_}, {:get_pending_invite_rooms_for_user, user_id}})
    rooms
  end

  # m.room.member join events the room server persisted for the user (looked up by type / state_key, counted)
  defp join_events(user_id) do
    :ets.match(:join_room_test_db, {{:event, :_}, :"$1"})
    |> List.flatten()
    |> Enum.filter(&(&1["type"] == "m.room.member" and &1["state_key"] == user_id and get_in(&1, ["content", "membership"]) == "join"))
  end

  defp pg_error(marker) do
    %Postgrex.Error{
      message: "simulated 22P05 #{marker}",
      postgres: %{
        code: :untranslatable_character,
        pg_code: "22P05",
        severity: "ERROR",
        message: "unsupported Unicode escape sequence",
        where: "JSON data, line 1: {\"join_rule\": \"#{marker}\"...}"
      }
    }
  end

  # ─── AT #7: join_room happy path → JoinRoomResponse, member list updated ─────
  #
  # AC #10 — join_room/2 looks up the Room GenServer, calls Room.Server.join/2,
  # and returns %Core.JoinRoomResponse{room_id: room_id}.
  # Post-condition: state.members contains the joining user.
  #
  # Given: Room GenServer running for "!jointest:test.local", @alice not yet a member
  # When: Server.join_room/2 is called for @alice
  # Then: returns %Core.JoinRoomResponse{room_id: "!jointest:test.local"} AND
  #       Nebu.Matrix.Room.Server.get_state/1 shows @alice in members

  describe "Server.join_room/2 — happy path" do
    test "returns JoinRoomResponse and adds user to room members" do
      room_id = "!jointest:test.local"

      # Start the room first (no members yet).
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      start_and_track_room(room_id)

      # Story create-room-presets-power-levels-topic (AC16, DATA adaptation): this test is about the join MECHANICS (response,
      # membership), not about who may join. A room without an m.room.join_rules event is invite-only now (D1, tested below), so the
      # room gets the public rule a `public_chat` createRoom writes.
      seed_rule(room_id, %{"join_rule" => "public"})

      request = %Core.JoinRoomRequest{
        user_id: "@alice:test.local",
        room_id_or_alias: room_id
      }

      response = Server.join_room(request, build_stream())

      assert %Core.JoinRoomResponse{} = response
      assert response.room_id == room_id

      # Post-condition: @alice is now a member.
      state = Nebu.Matrix.Room.Server.get_state(room_id)

      assert MapSet.member?(state.members, "@alice:test.local"),
             "expected @alice:test.local in members after join, got: #{inspect(state.members)}"
    end
  end

  # ─── AT #8: join_room room not found → Nebu.Matrix.Error NOT_FOUND ───────────────
  #
  # AC #3 (Elixir side) — when no Room GenServer is running for the given
  # room_id, join_room/2 must raise Nebu.Matrix.Error with status not_found.
  #
  # Given: no Room GenServer running for "!missing:test.local"
  # When: Server.join_room/2 is called
  # Then: raises %Nebu.Matrix.Error{status: Nebu.Matrix.Status.not_found()}

  describe "Server.join_room/2 — room not found" do
    test "raises Nebu.Matrix.Error with not_found status when room does not exist" do
      request = %Core.JoinRoomRequest{
        user_id: "@alice:test.local",
        room_id_or_alias: "!missing:test.local"
      }

      assert_raise Nebu.Matrix.Error, fn ->
        Server.join_room(request, build_stream())
      end
    end

    test "raised error has not_found status code" do
      request = %Core.JoinRoomRequest{
        user_id: "@alice:test.local",
        room_id_or_alias: "!nonexistent:test.local"
      }

      error =
        try do
          Server.join_room(request, build_stream())
          flunk("expected Nebu.Matrix.Error to be raised, but no exception was raised")
        rescue
          e in Nebu.Matrix.Error -> e
        end

      assert error.status == Nebu.Matrix.Status.not_found(),
             "expected status not_found (#{Nebu.Matrix.Status.not_found()}), got: #{error.status}"
    end
  end

  # ─── AT #9: join_room already member → idempotent success ────────────────────
  #
  # AC #7 — if the user is already a member of the room, join_room/2 must NOT
  # raise an error. It returns %Core.JoinRoomResponse{room_id: room_id} as per
  # the Matrix spec idempotency requirement.
  #
  # Given: @alice:test.local is already a member of "!idempotent:test.local"
  # When: Server.join_room/2 is called again for @alice
  # Then: returns %Core.JoinRoomResponse{room_id: "!idempotent:test.local"} (no error)

  describe "Server.join_room/2 — idempotent join" do
    test "returns JoinRoomResponse when user is already a member (no error)" do
      room_id = "!idempotent:test.local"
      user_id = "@alice:test.local"

      # Pre-condition: Alice is already a member.
      :ok = setup_room_with_member(room_id, user_id)

      request = %Core.JoinRoomRequest{
        user_id: user_id,
        room_id_or_alias: room_id
      }

      # Must not raise — idempotent join returns success.
      response = Server.join_room(request, build_stream())

      assert %Core.JoinRoomResponse{} = response
      assert response.room_id == room_id
    end

    test "member list still contains user after duplicate join" do
      room_id = "!idempotent2:test.local"
      user_id = "@bob:test.local"

      :ok = setup_room_with_member(room_id, user_id)

      request = %Core.JoinRoomRequest{
        user_id: user_id,
        room_id_or_alias: room_id
      }

      _response = Server.join_room(request, build_stream())

      state = Nebu.Matrix.Room.Server.get_state(room_id)

      assert MapSet.member?(state.members, user_id),
             "expected #{user_id} to remain in members after duplicate join"

      # Idempotent — member count must not increase.
      assert MapSet.size(state.members) == 1,
             "expected exactly 1 member after duplicate join, got: #{MapSet.size(state.members)}"
    end
  end

  # ─── AT #10: invite_user stores invitation ────────────────────────────────────
  #
  # AC #11 — invite_user/2 validates caller is a member, inserts invitation record,
  # and returns %Core.InviteUserResponse{}.
  #
  # Given: @alice:test.local is a member of "!invite:test.local", @bob is not
  # When: Server.invite_user/2 is called with caller=alice, invitee=bob
  # Then: returns %Core.InviteUserResponse{} and invitation exists in FakeInviteDB

  describe "Server.invite_user/2 — happy path" do
    test "returns InviteUserResponse and stores invitation when caller is a member" do
      room_id = "!invite:test.local"
      alice = "@alice:test.local"
      bob = "@bob:test.local"

      # Pre-condition: alice is already a member.
      :ok = setup_room_with_member(room_id, alice)

      request = %Core.InviteUserRequest{
        room_id: room_id,
        inviter_id: alice,
        invitee_id: bob
      }

      response = Server.invite_user(request, build_stream())

      assert %Core.InviteUserResponse{} = response

      # Verify invitation was stored in FakeInviteDB.
      invitations = :ets.lookup(:join_room_test_invitations, room_id)

      assert Enum.any?(invitations, fn {_rid, inviter, invitee} ->
               inviter == alice and invitee == bob
             end),
             "expected invitation for #{bob} from #{alice} in #{room_id}, got: #{inspect(invitations)}"
    end

    test "raises Nebu.Matrix.Error permission_denied if caller is not a member" do
      room_id = "!invite_no_perm:test.local"
      non_member = "@stranger:test.local"
      bob = "@bob:test.local"

      # Start room but do NOT add non_member.
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      start_and_track_room(room_id)

      request = %Core.InviteUserRequest{
        room_id: room_id,
        inviter_id: non_member,
        invitee_id: bob
      }

      error =
        try do
          Server.invite_user(request, build_stream())
          flunk("expected Nebu.Matrix.Error to be raised, but no exception was raised")
        rescue
          e in Nebu.Matrix.Error -> e
        end

      assert error.status == Nebu.Matrix.Status.permission_denied(),
             "expected status permission_denied (#{Nebu.Matrix.Status.permission_denied()}), got: #{error.status}"
    end

    test "raises Nebu.Matrix.Error not_found when room does not exist" do
      request = %Core.InviteUserRequest{
        room_id: "!nonexistent_invite:test.local",
        inviter_id: "@alice:test.local",
        invitee_id: "@bob:test.local"
      }

      error =
        try do
          Server.invite_user(request, build_stream())
          flunk("expected Nebu.Matrix.Error to be raised, but no exception was raised")
        rescue
          e in Nebu.Matrix.Error -> e
        end

      assert error.status == Nebu.Matrix.Status.not_found(),
             "expected status not_found (#{Nebu.Matrix.Status.not_found()}), got: #{error.status}"
    end
  end

  # ─── MAJOR-1: invite_user — insufficient power level for invite ───────────────
  #
  # AC #6 (Story 4-13) — invite_user/2 checks power levels after membership check.
  # When the room has `invite` threshold set to 50 but the inviter has power level 0,
  # the handler must raise Nebu.Matrix.Error with permission_denied status.
  #
  # Given: Room GenServer with power_levels where "invite" threshold is 50;
  #        @alice:test.local is a member at default power 0
  # When: Server.invite_user/2 called with alice as inviter
  # Then: raises Nebu.Matrix.Error with status: Nebu.Matrix.Status.permission_denied()

  describe "Server.invite_user/2 — power level check for invite" do
    test "raises Nebu.Matrix.Error permission_denied when inviter lacks invite power level" do
      room_id = "!invite_pl_check:test.local"
      alice = "@alice:test.local"
      bob = "@bob:test.local"

      # Start room and add alice as member.
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, alice)

      # Set power levels so invite threshold is 50 (alice has default power 0).
      # The bootstrapping path allows set_power_levels when power_levels is %{}.
      elevated_pl = %{
        "ban" => 50,
        "kick" => 50,
        "invite" => 50,
        "redact" => 50,
        "state_default" => 50,
        "events_default" => 0,
        "users_default" => 0,
        "users" => %{"@admin:test.local" => 100},
        "events" => %{}
      }

      :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, alice, elevated_pl)

      request = %Core.InviteUserRequest{
        room_id: room_id,
        inviter_id: alice,
        invitee_id: bob
      }

      error =
        try do
          Server.invite_user(request, build_stream())
          flunk("expected Nebu.Matrix.Error to be raised, but no exception was raised")
        rescue
          e in Nebu.Matrix.Error -> e
        end

      assert error.status == Nebu.Matrix.Status.permission_denied(),
             "expected status permission_denied (#{Nebu.Matrix.Status.permission_denied()}), got: #{error.status}"
    end

    test "invite_user succeeds when inviter has sufficient invite power level" do
      room_id = "!invite_pl_allow:test.local"
      admin = "@admin:test.local"
      bob = "@bob:test.local"

      # Start room and add admin as member.
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, admin)

      # Set power levels so invite threshold is 50 and admin has power 100.
      elevated_pl = %{
        "ban" => 50,
        "kick" => 50,
        "invite" => 50,
        "redact" => 50,
        "state_default" => 50,
        "events_default" => 0,
        "users_default" => 0,
        "users" => %{admin => 100},
        "events" => %{}
      }

      :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, admin, elevated_pl)

      request = %Core.InviteUserRequest{
        room_id: room_id,
        inviter_id: admin,
        invitee_id: bob
      }

      # Admin (power 100) can invite even when threshold is 50.
      response = Server.invite_user(request, build_stream())
      assert %Core.InviteUserResponse{} = response
    end
  end

  # ─── Story 9-19 Fix 1 (GAP-JOIN-PUBLIC): join_room broadcasts {:new_join} ─────
  #
  # AC: When a user joins a public room, join_room/2 must broadcast {:new_join, room_id}
  # to the "user:#{user_id}" :pg group so the long-polling sync task wakes immediately.
  #
  # Given: test process subscribed to "user:@newjoin-user:test.local" :pg group
  # When:  Server.join_room/2 called for @newjoin-user
  # Then:  {:new_join, room_id} received within 200 ms
  #
  # Note: only the actual new join triggers the broadcast — the :already_member branch does NOT.

  describe "Server.join_room/2 — :pg broadcast to joining user (GAP-JOIN-PUBLIC)" do
    test "broadcasts {:new_join, room_id} to user :pg group on successful join" do
      room_id = "!pgbroadcast-#{System.unique_integer([:positive])}:test.local"
      user_id = "@newjoin-user:test.local"

      # Start room.
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      :ok = wait_for_registry(room_id)
      start_and_track_room(room_id)

      # Story create-room-presets-power-levels-topic (AC16, DATA adaptation): GAP-JOIN-PUBLIC is about a PUBLIC room, which now has
      # to say so (the public_chat preset writes this rule); without a join rule the room is invite-only (D1).
      seed_rule(room_id, %{"join_rule" => "public"})

      # Subscribe to user's :pg group (simulates sync task entering long-poll).
      :ok = :pg.join("user:#{user_id}", self())
      on_exit(fn -> :pg.leave("user:#{user_id}", self()) end)

      request = %Core.JoinRoomRequest{
        user_id: user_id,
        room_id_or_alias: room_id
      }

      Server.join_room(request, build_stream())

      assert_receive {:new_join, ^room_id}, 200,
        "Expected {:new_join, #{room_id}} broadcast from join_room within 200 ms (GAP-JOIN-PUBLIC fix)."
    end

    test "does NOT broadcast {:new_join} when user is already a member (:already_member path)" do
      room_id = "!pgbroadcast-already-#{System.unique_integer([:positive])}:test.local"
      user_id = "@already-joined-user:test.local"

      # Start room and add user as member first.
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      :ok = wait_for_registry(room_id)
      start_and_track_room(room_id)
      :ok = Nebu.Matrix.Room.Server.join(room_id, user_id)

      # Subscribe to user's :pg group.
      :ok = :pg.join("user:#{user_id}", self())
      on_exit(fn -> :pg.leave("user:#{user_id}", self()) end)

      request = %Core.JoinRoomRequest{
        user_id: user_id,
        room_id_or_alias: room_id
      }

      # Second join — idempotent, must return success but NOT broadcast.
      assert %Core.JoinRoomResponse{} = Server.join_room(request, build_stream())

      refute_receive {:new_join, _}, 100,
        "Must NOT broadcast {:new_join, _} when user is already a member (idempotent path)"
    end
  end

  # ═══ Story create-room-presets-power-levels-topic (epic oauth-broker, follow-up `ec`), decision D1 ═══════════════════════
  #
  # join_room/2 decides BEFORE Room.Server.join/2: 1. already a member -> idempotent 200 (no read at all), 2. the latest membership is
  # `ban` -> 403, 3. the effective join rule (the pure Nebu.Matrix.Room.JoinRules table). A failing read is a 500 (fail closed), never
  # "no state = open". Rooms here are real Room GenServers with fake persistence; the join rule is seeded into the fake state read.

  describe "AC1(a)/(d)/(e) - a room without a join rule, with invite / knock is invite-only" do
    test "a LEGACY room without any m.room.join_rules event: 403 without an invite, 200 with a pending invite (accepted by the join)" do
      room_id = room_with_rule("legacy", :absent)
      mallory = "@mallory:test.local"

      assert {:error, {403, "M_FORBIDDEN", _}} = join_as(mallory, room_id)
      refute member?(room_id, mallory)
      assert join_events(mallory) == [], "no m.room.member join event for the refused user"

      invite!(room_id, "@creator:test.local", mallory)
      assert {:ok, %Core.JoinRoomResponse{room_id: ^room_id}} = join_as(mallory, room_id)
      assert member?(room_id, mallory)
      assert pending_rooms(mallory) == [], "the invitation is accepted by the join"
      assert length(join_events(mallory)) == 1
    end

    test "explicit invite and knock: 403 without an invite, 200 with a pending invite" do
      for rule <- ["invite", "knock"] do
        room_id = room_with_rule("rule-#{rule}", %{"join_rule" => rule})
        user = "@#{rule}-user-#{rand_hex()}:test.local"

        assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, room_id), "#{rule} without an invite"
        refute member?(room_id, user), "#{rule}: not a member after the refusal"

        invite!(room_id, "@creator:test.local", user)
        assert {:ok, _} = join_as(user, room_id), "#{rule} with an invite"
        assert member?(room_id, user)
      end
    end

    test "public: 200 without any invite" do
      room_id = room_with_rule("public", %{"join_rule" => "public"})
      user = "@pub-#{rand_hex()}:test.local"

      assert {:ok, %Core.JoinRoomResponse{}} = join_as(user, room_id)
      assert member?(room_id, user)
    end
  end

  describe "AC1(e) - private, unknown and malformed rules deny even an invited user (strict room v10)" do
    test "private, \"foo\", \"\", 5, {} and undecodable content: 403 WITHOUT and WITH a pending invite, never a member" do
      for {label, content} <- [
            private: %{"join_rule" => "private"},
            unknown: %{"join_rule" => "foo"},
            empty_rule: %{"join_rule" => ""},
            number_rule: %{"join_rule" => 5},
            empty_content: %{},
            not_json: "this is not json",
            truncated: ~s({"join_rule":"inv),
            null_content: nil
          ] do
        room_id = room_with_rule("deny-#{label}", content)
        user = "@deny-#{rand_hex()}:test.local"

        assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, room_id), "#{label} without an invite"

        invite!(room_id, "@creator:test.local", user)
        assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, room_id), "#{label} WITH a pending invite"

        refute member?(room_id, user), "#{label}: not a member"
        assert join_events(user) == [], "#{label}: no join event"
        assert pending_rooms(user) == [room_id], "#{label}: the invitation is still pending (it was not accepted)"
      end
    end
  end

  describe "AC1(g) - the refusal reveals no state" do
    test "the 403 text is one fixed text for every rule refusal (no rule, no room id, no user id in it)" do
      user = "@fixed-#{rand_hex()}:test.local"

      messages =
        for {label, content} <- [absent: :absent, invite: %{"join_rule" => "invite"}, knock: %{"join_rule" => "knock"}, private: %{"join_rule" => "private"}, unknown: %{"join_rule" => "secretrule#{rand_hex()}"}, malformed: %{}] do
          room_id = room_with_rule("fixed-#{label}", content)
          assert {:error, {403, "M_FORBIDDEN", message}} = join_as(user, room_id), "#{label}"

          assert is_binary(message) and message != ""
          refute message =~ room_id, "#{label}: no room id"
          refute message =~ user, "#{label}: no user id"
          refute message =~ "secretrule", "#{label}: no join rule value"
          message
        end

      assert Enum.uniq(messages) == ["You are not invited to this room"], "all rule refusals answer the same fixed text, got #{inspect(Enum.uniq(messages))}"
    end

    test "the ban refusal is a 403 M_FORBIDDEN with a fixed text that names neither the room nor the user" do
      room_id = room_with_rule("ban-text", %{"join_rule" => "public"})
      user = "@banned-#{rand_hex()}:test.local"
      seed_membership(room_id, user, "ban")

      assert {:error, {403, "M_FORBIDDEN", message}} = join_as(user, room_id)
      assert message == "You are banned from this room", "the fixed ban text (differs from the rule refusal text)"
      refute message =~ room_id
      refute message =~ user
    end

    test "a refused join (rule or ban) writes no room_joined audit row; the successful join writes exactly one" do
      refused = room_with_rule("audit-refused", %{"join_rule" => "invite"})
      banned = room_with_rule("audit-banned", %{"join_rule" => "public"})
      seed_membership(banned, "@mallory:test.local", "ban")
      open = room_with_rule("audit-open", %{"join_rule" => "public"})

      assert {:error, {403, _, _}} = join_as("@mallory:test.local", refused)
      assert {:error, {403, _, _}} = join_as("@mallory:test.local", banned)
      assert :ets.match(:join_room_test_db, {{:audit, :_}, {:_, "room_joined", :_}}) == [], "no row for a refusal"

      assert {:ok, _} = join_as("@mallory:test.local", open)
      assert :ets.match(:join_room_test_db, {{:audit, :_}, {:"$1", "room_joined", :"$2"}}) == [["@mallory:test.local", open]]
    end

    test "an unknown room stays 404 M_NOT_FOUND, and no state or membership is read for it" do
      assert {:error, {404, "M_NOT_FOUND", _}} = join_as("@alice:test.local", "!nowhere#{rand_hex()}:test.local")
      assert calls(:get_generic_state_events) == []
      assert calls(:get_member_membership) == []
    end
  end

  describe "AC2(a) - a ban is decided before the rule" do
    test "a banned user is refused in a public room, in an invite room even with a pending invite, in a restricted room while a member of the allow-room" do
      allow_room = start_room_with(new_room_id("allow"), ["@banned-r:test.local"])

      restricted = %{"join_rule" => "restricted", "allow" => [%{"type" => "m.room_membership", "room_id" => allow_room}]}
      knock_restricted = %{"join_rule" => "knock_restricted", "allow" => [%{"type" => "m.room_membership", "room_id" => allow_room}]}

      # the user's join into the allow-room (above) is a join event of its own: the refused rooms must add none
      joins_before = length(join_events("@banned-r:test.local"))

      for {label, content} <- [public: %{"join_rule" => "public"}, invite: %{"join_rule" => "invite"}, restricted: restricted, knock_restricted: knock_restricted, absent: :absent] do
        room_id = room_with_rule("banned-#{label}", content)
        user = "@banned-r:test.local"
        seed_membership(room_id, user, "ban")
        invite!(room_id, "@creator:test.local", user)

        assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, room_id), "#{label}: banned, with a pending invite and (restricted) an allow-room membership"
        refute member?(room_id, user), "#{label}: not a member"
        assert length(join_events(user)) == joins_before, "#{label}: no join event"
        # the user holds a pending invitation in every room of this loop, so "not accepted" = this room is still pending
        assert room_id in pending_rooms(user), "#{label}: the invitation was not accepted"
      end
    end

    test "after the ban is lifted (latest membership leave): public 200; invite-only 403 without a NEW invite, 200 with one" do
      user = "@unbanned:test.local"

      public = room_with_rule("unban-public", %{"join_rule" => "public"})
      seed_membership(public, user, "leave")
      assert {:ok, _} = join_as(user, public)

      invite_only = room_with_rule("unban-invite", %{"join_rule" => "invite"})
      # the invitation was accepted when the user first joined, then the user was banned and unbanned
      invite!(invite_only, "@creator:test.local", user)
      :ok = FakeInviteDB.accept_invitation(invite_only, user)
      seed_membership(invite_only, user, "leave")

      assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, invite_only), "unban alone does not re-invite"

      invite!(invite_only, "@creator:test.local", user)
      assert {:ok, _} = join_as(user, invite_only), "a new invite does"
    end

    test "a kicked or self-left user (latest membership leave): invite-only 403 without a new invite, public 200" do
      user = "@returner:test.local"

      for rule <- ["invite", "knock"] do
        room_id = room_with_rule("left-#{rule}", %{"join_rule" => rule})
        invite!(room_id, "@creator:test.local", user)
        :ok = FakeInviteDB.accept_invitation(room_id, user)
        seed_membership(room_id, user, "leave")
        assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, room_id), rule
      end

      public = room_with_rule("left-public", %{"join_rule" => "public"})
      seed_membership(public, user, "leave")
      assert {:ok, _} = join_as(user, public)
    end

    test "a REJECTED invitation: join 403 in an invite room, 200 in a public room" do
      user = "@decliner:test.local"

      invite_only = room_with_rule("rejected-invite", %{"join_rule" => "invite"})
      invite!(invite_only, "@creator:test.local", user)
      :ok = FakeInviteDB.reject_invitation(invite_only, user)
      seed_membership(invite_only, user, "leave")
      assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, invite_only)

      public = room_with_rule("rejected-public", %{"join_rule" => "public"})
      invite!(public, "@creator:test.local", user)
      :ok = FakeInviteDB.reject_invitation(public, user)
      seed_membership(public, user, "leave")
      assert {:ok, _} = join_as(user, public)
    end

    test "the membership of ANOTHER user does not matter: only the joining user's ban counts" do
      room_id = room_with_rule("other-ban", %{"join_rule" => "public"})
      seed_membership(room_id, "@banned-other:test.local", "ban")
      assert {:ok, _} = join_as("@innocent:test.local", room_id)
    end
  end

  describe "AC2(c) - a member re-joining is idempotent and reads nothing" do
    test "a member of an invite-only room joins again: 200, no second join event, no state / membership / invitation read" do
      room_id = start_room_with(new_room_id("member-rejoin"), ["@member:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})
      # even an inconsistent record (ban) must not matter: a member is never refused (Element re-joins its own rooms)
      seed_membership(room_id, "@member:test.local", "ban")
      before_joins = length(join_events("@member:test.local"))
      # the setup join above went through Room.Server.join/2, whose atomic ban check (review cycle 2, N-1) reads the membership: only the
      # reads of the join_room/2 call under test count
      :ets.match_delete(:join_room_test_db, {{:call, :_}, {:get_member_membership, :_, :_}})
      # story member-event-prev-content (DELIBERATE re-pin, D4 (a); old -> new): that ban check reads latest_member_event/2 now (ONE read for the ban
      # check and the strictly increasing stamp, instead of get_member_membership/2): the setup join's read is not a read of the call under test
      :ets.match_delete(:join_room_test_db, {{:call, :_}, {:latest_member_event, :_, :_}})

      assert {:ok, %Core.JoinRoomResponse{room_id: ^room_id}} = join_as("@member:test.local", room_id)

      assert length(join_events("@member:test.local")) == before_joins, "no second join event"
      assert calls(:get_generic_state_events) == [], "the join rule is not read for a member"
      assert calls(:get_member_membership) == [], "the membership is not read for a member"
      assert calls(:get_pending_invite_rooms_for_user) == [], "the invitations are not read for a member"
      # story sync-membership-partition (D13): the join decision reads the invitation through pending_invitation/2 and the latest member
      # event through latest_member_event/2: a member reads neither (the old assertions above stay)
      assert calls(:pending_invitation) == [], "the invitation (with invited_at) is not read for a member"
      assert calls(:latest_member_event) == [], "the latest member event is not read for a member"
    end
  end

  describe "AC2(d) - fail closed: a failing read is a 500, nobody joins" do
    defp assert_500_no_join(room_id, user, label) do
      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, join_as(user, room_id)}) end)
      assert_received {:result, result}
      assert {:error, {500, _errcode, message}} = result, "#{label}: expected 500, got #{inspect(result)}"
      assert is_binary(message)
      refute member?(room_id, user), "#{label}: Room.Server.join/2 must not have been called"
      assert join_events(user) == [], "#{label}: no join event"
      log
    end

    test "the join rule state read returns {:error, _}: 500 in a public room too (error is not open), the log has the room id and error class only" do
      marker = "mkstate" <> rand_hex()

      for {label, rule} <- [public: %{"join_rule" => "public"}, absent: :absent] do
        room_id = room_with_rule("state-error-#{label}", rule)
        :ets.insert(:join_room_test_db, {{:state_read, room_id}, {:error, pg_error(marker)}})
        user = "@reader-#{rand_hex()}:test.local"

        log = assert_500_no_join(room_id, user, "state read error (#{label})")
        assert log =~ room_id, "the log names the room id"
        assert log =~ "postgres 22P05", "the log names the error class"
        refute String.downcase(log) =~ marker, "no database error text in the log"
        refute log =~ user, "no user id in the log"
      end
    end

    test "the join rule state read RAISES: 500, nobody joins" do
      room_id = room_with_rule("state-raise", %{"join_rule" => "public"})
      :ets.insert(:join_room_test_db, {{:state_read, room_id}, :raise})
      assert_500_no_join(room_id, "@reader-raise:test.local", "state read raise")
    end

    test "the latest membership read returns {:error, _}: 500 in a public room, nobody joins; the log has the room id and the error class only" do
      marker = "mkmember" <> rand_hex()
      room_id = room_with_rule("member-error", %{"join_rule" => "public"})
      :ets.insert(:join_room_test_db, {{:membership_read, room_id}, {:error, pg_error(marker)}})

      log = assert_500_no_join(room_id, "@mreader:test.local", "membership read error")
      assert log =~ room_id
      assert log =~ "postgres 22P05"
      refute String.downcase(log) =~ marker
    end

    # story sync-membership-partition (D13, DELIBERATE re-pin): the join decision reads the invitation through pending_invitation/2, which
    # fails CLOSED like every other read of the decision (500; before the story a failing pending-invite read meant "no invite" = 403).
    # Unchanged: a public room reads no invitation at all (an invitation only ever grants), so it is still 200.
    test "a failing pending-invitation read is a 500 in an invite room (fail closed, D13), nobody joins; a public room is still 200" do
      :ets.insert(:join_room_test_db, {:pending_read, {:error, :db_down}})

      invite_only = room_with_rule("pending-error-invite", %{"join_rule" => "invite"})
      user = "@pending-reader:test.local"
      invite!(invite_only, "@creator:test.local", user)
      assert_500_no_join(invite_only, user, "pending invitation read error")

      public = room_with_rule("pending-error-public", %{"join_rule" => "public"})
      assert {:ok, _} = join_as(user, public)
    end
  end

  describe "AC2(b2) - inviting a banned user" do
    defp invite_via_core(room_id, inviter, invitee) do
      Nebu.Matrix.Http.call_core(fn ->
        Server.invite_user(%Core.InviteUserRequest{room_id: room_id, inviter_id: inviter, invitee_id: invitee}, build_stream())
      end)
    end

    test "a banned target is 403 M_FORBIDDEN, no invitation row is written, the user's join is still 403" do
      room_id = start_room_with(new_room_id("invite-banned"), ["@alice:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})
      seed_membership(room_id, "@bob:test.local", "ban")

      assert {:error, {403, "M_FORBIDDEN", message}} = invite_via_core(room_id, "@alice:test.local", "@bob:test.local")
      refute message =~ "@bob:test.local"
      assert calls(:insert_invitation) == [], "insert_invitation/3 is not called"
      assert :ets.lookup(:join_room_test_invitations, room_id) == []

      assert {:error, {403, "M_FORBIDDEN", _}} = join_as("@bob:test.local", room_id)
    end

    test "a target that is not banned (never a member, or latest membership leave) is invited as before" do
      room_id = start_room_with(new_room_id("invite-ok"), ["@alice:test.local"])
      seed_membership(room_id, "@left:test.local", "leave")

      assert {:ok, %Core.InviteUserResponse{}} = invite_via_core(room_id, "@alice:test.local", "@fresh:test.local")
      assert {:ok, %Core.InviteUserResponse{}} = invite_via_core(room_id, "@alice:test.local", "@left:test.local")
      assert length(calls(:insert_invitation)) == 2
    end

    test "a ban does not turn the inviter's own refusals into a leak: a non-member inviter is refused whatever the target's membership" do
      room_id = start_room_with(new_room_id("invite-banned-nonmember"), ["@alice:test.local"])
      seed_membership(room_id, "@bob:test.local", "ban")

      assert {:error, {403, "M_FORBIDDEN", _}} = invite_via_core(room_id, "@stranger:test.local", "@bob:test.local")
      assert {:error, {403, "M_FORBIDDEN", _}} = invite_via_core(room_id, "@stranger:test.local", "@carol:test.local")
      assert calls(:insert_invitation) == []
    end
  end

  describe "AC2(e) - admin_add_room_member/3 goes through the invite and cannot bypass a ban" do
    test "a non-banned local user is added to an invite-only room (invite, then join)" do
      room_id = start_room_with(new_room_id("admin-add"), ["@admin:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})

      assert {:ok, ^room_id} = Server.admin_add_room_member(room_id, "@target:test.local", "@admin:test.local")
      assert member?(room_id, "@target:test.local")
      assert pending_rooms("@target:test.local") == [], "the force-add invitation is accepted"
    end

    test "a BANNED target is an error: not a member, no pending invitation left behind" do
      room_id = start_room_with(new_room_id("admin-add-banned"), ["@admin:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})
      seed_membership(room_id, "@target:test.local", "ban")

      assert {:error, reason} = Server.admin_add_room_member(room_id, "@target:test.local", "@admin:test.local")
      assert reason != :not_found
      refute member?(room_id, "@target:test.local")
      assert join_events("@target:test.local") == []
      assert pending_rooms("@target:test.local") == [], "the invitation of the failed add is dropped (no dangling invite)"
    end
  end

  # ═══ Review cycle 1 (Kassandra F-1 / F-2 / F-3 / F-5 / F-8, code review M-1 / M-2 / m-2 / m-4 / m-5) ═════════════════════
  #
  # Moderation and membership paths around the join decision: a leave must not lift a ban, a member holds no invitation, the ban is
  # not lost to a concurrent join, a moderator must outrank the target. The fakes above serve the reads; `moderate/4` goes through the
  # public Http.call_core mapping (kick / ban / unban have no HTTP route).

  defp leave_core(user_id, room_id) do
    Nebu.Matrix.Http.call_core(fn ->
      Server.leave_room(%Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}, build_stream())
    end)
  end

  defp moderate(kind, room_id, caller, target) do
    Nebu.Matrix.Http.call_core(fn ->
      stream = Nebu.Matrix.Http.stream(caller)

      case kind do
        :ban -> Server.ban_user(%Core.BanUserRequest{room_id: room_id, target_id: target, reason: ""}, stream)
        :kick -> Server.kick_user(%Core.KickUserRequest{room_id: room_id, target_id: target, reason: ""}, stream)
        :unban -> Server.unban_user(%Core.UnbanUserRequest{room_id: room_id, target_id: target}, stream)
      end
    end)
  end

  # every m.room.member event of the user the fakes persisted (any membership)
  defp member_events(user_id) do
    :ets.match(:join_room_test_db, {{:event, :_}, :"$1"})
    |> List.flatten()
    |> Enum.filter(&(&1["type"] == "m.room.member" and &1["state_key"] == user_id))
  end

  defp leave_events(user_id), do: Enum.filter(member_events(user_id), &(get_in(&1, ["content", "membership"]) == "leave"))

  # a room whose creator (first member) holds 100, `levels` more users with their level, and the given join rule
  defp room_with_levels(label, members, user_levels, rule \\ %{"join_rule" => "invite"}) do
    room_id = start_room_with(new_room_id(label), members)
    levels = Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", user_levels)
    :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, hd(members), levels)
    seed_rule(room_id, rule)
    room_id
  end

  describe "F-1 - a leave never lifts a ban and writes an event only for a real leave / decline" do
    test "a banned user's /leave is 403 M_FORBIDDEN (fixed text) and writes NOTHING: no member event, a pending invitation is left alone" do
      room_id = room_with_rule("leave-banned", %{"join_rule" => "public"})
      user = "@leave-banned-#{rand_hex()}:test.local"
      seed_membership(room_id, user, "ban")
      invite!(room_id, "@creator:test.local", user)

      assert {:error, {403, "M_FORBIDDEN", message}} = leave_core(user, room_id)
      assert message == "You are banned from this room"
      refute message =~ user
      assert member_events(user) == [], "no self-authored leave event that would be newer than the ban"
      assert pending_rooms(user) == [room_id], "nothing was rejected either"

      assert {:error, {403, "M_FORBIDDEN", _}} = join_as(user, room_id), "the join is still refused"
    end

    test "a banned user of a room whose room process is not running is refused as well, nothing written" do
      # a registered-looking room id without a started GenServer: the not_found branch of leave_room/2
      room_id = new_room_id("leave-banned-norun")
      user = "@leave-banned-norun-#{rand_hex()}:test.local"
      seed_membership(room_id, user, "ban")

      assert {:error, {403, "M_FORBIDDEN", "You are banned from this room"}} = leave_core(user, room_id)
      assert member_events(user) == []
    end

    test "an unreadable membership is a 500 (fail closed) and nothing is written" do
      room_id = room_with_rule("leave-read-error", %{"join_rule" => "public"})
      user = "@leave-read-error-#{rand_hex()}:test.local"
      :ets.insert(:join_room_test_db, {{:membership_read, room_id}, {:error, :db_down}})
      invite!(room_id, "@creator:test.local", user)

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, leave_core(user, room_id)}) end)
      assert_received {:result, {:error, {500, _, _}}}
      assert member_events(user) == []
      assert log =~ room_id
      refute log =~ user
    end

    test "the decline of a REAL pending invitation still works: 200, the invitation is rejected, ONE leave event by the user is written" do
      room_id = room_with_rule("leave-decline", %{"join_rule" => "invite"})
      user = "@decliner-#{rand_hex()}:test.local"
      invite!(room_id, "@creator:test.local", user)

      assert {:ok, %Core.LeaveRoomResponse{room_id: ^room_id}} = leave_core(user, room_id)
      assert pending_rooms(user) == []
      assert [%{"sender" => ^user}] = leave_events(user)
    end

    test "a leave by a user with neither an invitation nor a join writes no event (nothing to leave); the response is still 200" do
      room_id = room_with_rule("leave-nothing", %{"join_rule" => "public"})
      stranger = "@stranger-#{rand_hex()}:test.local"
      seed_membership(room_id, stranger, "leave")

      assert {:ok, %Core.LeaveRoomResponse{}} = leave_core(stranger, room_id)
      assert member_events(stranger) == []
    end

    test "a member whose room process was not running (latest membership join) still gets the leave event" do
      room_id = new_room_id("leave-join-norun")
      user = "@dbmember-#{rand_hex()}:test.local"
      seed_membership(room_id, user, "join")

      assert {:ok, %Core.LeaveRoomResponse{}} = leave_core(user, room_id)
      assert [%{"sender" => ^user}] = leave_events(user)
    end
  end

  describe "M-2 - a member holds no invitation" do
    test "invite_user refuses an invitee who is already a member (and a self-invite): 403 M_FORBIDDEN, no invitation row" do
      room_id = start_room_with(new_room_id("invite-member"), ["@alice:test.local", "@bob:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})

      assert {:error, {403, "M_FORBIDDEN", message}} = invite_via_core(room_id, "@alice:test.local", "@bob:test.local")
      refute message =~ "@bob:test.local"
      assert {:error, {403, "M_FORBIDDEN", _}} = invite_via_core(room_id, "@bob:test.local", "@bob:test.local"), "self-invite"
      assert calls(:insert_invitation) == []
      assert pending_rooms("@bob:test.local") == []
    end

    test "admin_add_room_member of a user who is already a member is a no-op: {:ok, room}, no invitation written, no member_added audit row" do
      room_id = start_room_with(new_room_id("admin-add-member"), ["@admin:test.local", "@target:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})

      assert {:ok, ^room_id} = Server.admin_add_room_member(room_id, "@target:test.local", "@admin:test.local")
      assert calls(:insert_invitation) == []
      assert :ets.match(:join_room_test_db, {{:audit, :_}, {:_, "member_added", :_}}) == []
    end

    test "the :already_member branch of a join closes a pending invitation (a member's pre-armed invite does not survive)" do
      room_id = room_with_rule("already-accept", %{"join_rule" => "invite"})
      :ok = Nebu.Matrix.Room.Server.join(room_id, "@bob:test.local")
      invite!(room_id, "@creator:test.local", "@bob:test.local")
      assert pending_rooms("@bob:test.local") == [room_id]

      assert {:ok, _} = join_as("@bob:test.local", room_id)
      assert pending_rooms("@bob:test.local") == []
    end

    test "a failing accept_invitation is a value-free warning (room id and error class), the join stands" do
      marker = "mkaccept" <> rand_hex()
      room_id = room_with_rule("accept-fails", %{"join_rule" => "public"})
      :ets.insert(:join_room_test_db, {:accept_fail, pg_error(marker)})

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, join_as("@acc-#{rand_hex()}:test.local", room_id)}) end)
      assert_received {:result, {:ok, _}}
      assert log =~ room_id
      assert log =~ "postgres 22P05"
      refute String.downcase(log) =~ marker
    end

    test "member pre-arm -> kick -> /join is 403: a kick rejects the pending invitation (invite and knock rooms)" do
      for rule <- ["invite", "knock"] do
        room_id = room_with_levels("prearm-kick-#{rule}", ["@alice:test.local", "@bob:test.local"], %{"@alice:test.local" => 100}, %{"join_rule" => rule})
        invite!(room_id, "@bob:test.local", "@bob:test.local")

        assert {:ok, %Core.KickUserResponse{}} = moderate(:kick, room_id, "@alice:test.local", "@bob:test.local")
        assert pending_rooms("@bob:test.local") == [], "#{rule}: the pending invitation is rejected by the kick"
        assert {:error, {403, "M_FORBIDDEN", _}} = join_as("@bob:test.local", room_id), rule
      end
    end

    test "member pre-arm -> admin remove -> /join is 403: a leave rejects the pending invitation" do
      room_id = room_with_levels("prearm-remove", ["@alice:test.local", "@bob:test.local"], %{"@alice:test.local" => 100})
      invite!(room_id, "@bob:test.local", "@bob:test.local")

      assert :ok = Server.admin_remove_room_member(room_id, "@bob:test.local", "@alice:test.local")
      assert pending_rooms("@bob:test.local") == []
      assert {:error, {403, "M_FORBIDDEN", _}} = join_as("@bob:test.local", room_id)
    end
  end

  describe "F-8 / F-5 - the banned target of a force-add and the invitation of an unbanned user" do
    test "a force-add of a banned target is refused BEFORE anything is written: no invitation row, an earlier accepted invitation is not re-armed" do
      room_id = start_room_with(new_room_id("admin-banned-prewrite"), ["@admin:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})
      invite!(room_id, "@admin:test.local", "@target:test.local")
      :ok = FakeInviteDB.accept_invitation(room_id, "@target:test.local")
      seed_membership(room_id, "@target:test.local", "ban")
      inserts_before = length(calls(:insert_invitation))

      assert {:error, reason} = Server.admin_add_room_member(room_id, "@target:test.local", "@admin:test.local")
      assert reason == "You are banned from this room"
      assert length(calls(:insert_invitation)) == inserts_before, "insert_invitation/3 was not called again"
      assert pending_rooms("@target:test.local") == []
    end

    test "unban rejects a pending invitation of the target: it must not admit the user without a fresh invitation" do
      room_id = room_with_levels("unban-invite", ["@alice:test.local"], %{"@alice:test.local" => 100})
      # a stale invitation that survived the ban (read-before-insert race of invite_user)
      invite!(room_id, "@alice:test.local", "@banned:test.local")
      seed_membership(room_id, "@banned:test.local", "ban")

      assert {:ok, %Core.UnbanUserResponse{}} = moderate(:unban, room_id, "@alice:test.local", "@banned:test.local")
      assert pending_rooms("@banned:test.local") == []

      seed_membership(room_id, "@banned:test.local", "leave")
      assert {:error, {403, "M_FORBIDDEN", _}} = join_as("@banned:test.local", room_id)
    end
  end

  describe "F-2 - the ban is not lost to a concurrent join" do
    test "the fake models the real thing: a join writes its OWN join event, which becomes the latest membership (a re-read after the join would see 'join')" do
      room_id = room_with_rule("race-model", %{"join_rule" => "public"})
      user = "@modeled-#{rand_hex()}:test.local"

      assert {:ok, _} = join_as(user, room_id)
      assert {:ok, "join"} = FakeDB.get_member_membership(room_id, user)
      assert length(join_events(user)) == 1
    end

    test "N-1: a ban that commits AFTER the join decision and BEFORE Room.Server.join lands is not lost: the join is refused (403), no join event is written, the ban stays the latest membership" do
      room_id = room_with_rule("race-atomic", %{"join_rule" => "public"})
      user = "@racer-#{rand_hex()}:test.local"
      # the ban event is written right after the decision's ban read (the join's read of the rule state)
      :ets.insert(:join_room_test_db, {{:ban_on_state_read, room_id, user}, true})

      assert {:error, {403, "M_FORBIDDEN", "You are banned from this room"}} = join_as(user, room_id)
      refute member?(room_id, user)
      assert join_events(user) == [], "the refused join wrote no join event of its own that would hide the ban"
      assert {:ok, "ban"} = FakeDB.get_member_membership(room_id, user)
      assert :ets.match(:join_room_test_db, {{:audit, :_}, {:_, "room_joined", :_}}) == []
      assert calls(:accept_invitation) == [], "the invitation of a refused join is not accepted"
    end

    test "N-1: the atomic check is Room.Server.join/2 itself: every join is refused for a banned user, also the internal ones (creator, auto-join, upgrade)" do
      room_id = start_room_with(new_room_id("atomic-direct"), [])
      user = "@banned-direct-#{rand_hex()}:test.local"
      seed_membership(room_id, user, "ban")

      assert {:error, :banned} = Nebu.Matrix.Room.Server.join(room_id, user)
      refute member?(room_id, user)
      assert join_events(user) == []

      # a user without a ban joins as before
      assert :ok = Nebu.Matrix.Room.Server.join(room_id, "@fine-#{rand_hex()}:test.local")
    end

    test "N-1: a failing membership read inside the join refuses it (fail closed, value-free log), the user is not a member" do
      marker = "mkatomic" <> rand_hex()
      room_id = start_room_with(new_room_id("atomic-read-error"), [])
      user = "@atomic-#{rand_hex()}:test.local"
      :ets.insert(:join_room_test_db, {{:membership_read, room_id}, {:error, pg_error(marker)}})

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, Nebu.Matrix.Room.Server.join(room_id, user)}) end)
      assert_received {:result, {:error, :membership_unavailable}}
      refute member?(room_id, user)
      assert log =~ room_id
      refute String.downcase(log) =~ marker
      refute log =~ user
    end

    test "N-1: a join through join_room/2 with an unreadable membership inside the room process is a 500" do
      room_id = room_with_rule("atomic-500", %{"join_rule" => "public"})
      user = "@atomic-500-#{rand_hex()}:test.local"
      # the decision's own read passes, the read inside the room process fails.
      # story member-event-prev-content (DELIBERATE re-pin, D4 (a); old -> new): the room process reads latest_member_event/2 now (it was the
      # second get_member_membership/2 of a `:membership_script`): the failing read is scripted on that function, the decision's read is untouched
      :ets.insert(:join_room_test_db, {{:latest_event_read, room_id}, {:error, :db_down}})

      capture = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, join_as(user, room_id)}) end)
      assert_received {:result, {:error, {500, _, _}}}
      assert is_binary(capture)
      refute member?(room_id, user)
      # the re-pin keeps the isolation of the old test: exactly ONE latest_member_event read of this room, the one inside the room process
      assert calls(:latest_member_event) |> Enum.filter(&(elem(&1, 1) == room_id)) |> length() == 1, "only the room process reads the latest member event (decision: get_member_membership/2)"
    end

    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): the two tests of the two-removal ban ("ban_user removes the
    # member, writes the ban event and removes AGAIN ..." and "a member that cannot be removed fails the ban ... after a join slipped in and
    # the second removal fails") are deleted: the ban is ONE room-process call now (no second removal exists), and the race they modelled
    # is proven on the real database by moderation_concurrency_test.exs AC7 (a) (ban against 10 concurrent joins, 50 rounds).

    test "a failing first removal fails the ban before the ban event is written" do
      room_id = room_with_levels("ban-delete-fails", ["@alice:test.local", "@bob:test.local"], %{"@alice:test.local" => 100})
      :ets.insert(:join_room_test_db, {{:delete_fail, room_id}, :db_down})

      capture = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, moderate(:ban, room_id, "@alice:test.local", "@bob:test.local")}) end)
      assert_received {:result, {:error, {500, _, _}}}
      assert member_events("@bob:test.local") |> Enum.filter(&(get_in(&1, ["content", "membership"]) == "ban")) == []
      assert is_binary(capture)
    end
  end

  describe "m-2 / m-4 - an unanswering room process is a 503, a public join reads no invitations" do
    defmodule DeadRegistry do
      def get_state(_room_id), do: exit({:noproc, {GenServer, :call, [:dead, :get_state, 5000]}})
    end

    test "a room process that does not answer is 503 M_UNAVAILABLE, not a misleading 403 'not invited'" do
      room_id = room_with_rule("registry-dead", %{"join_rule" => "invite"})
      Application.put_env(:event_dispatcher, :room_registry_module, DeadRegistry)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :room_registry_module) end)

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, join_as("@member:test.local", room_id)}) end)
      assert_received {:result, {:error, {503, "M_UNAVAILABLE", _}}}
      assert log =~ room_id
    end

    test "a public room is joined without reading the invitations of the user (an invitation only ever grants)" do
      room_id = room_with_rule("public-no-invite-read", %{"join_rule" => "public"})
      assert {:ok, _} = join_as("@pub-reader-#{rand_hex()}:test.local", room_id)
      assert calls(:get_pending_invite_rooms_for_user) == []
      assert calls(:pending_invitation) == [], "story sync-membership-partition (D13): the new invitation read is not made either"
    end

    test "an invite room reads them exactly when the rule alone refuses" do
      room_id = room_with_rule("invite-reads", %{"join_rule" => "invite"})
      user = "@invite-reader-#{rand_hex()}:test.local"
      invite!(room_id, "@creator:test.local", user)
      assert {:ok, _} = join_as(user, room_id)
      # story sync-membership-partition (D13, DELIBERATE re-pin): the decision's invitation read is pending_invitation/2 now (it also
      # returns invited_at); get_pending_invite_rooms_for_user/1 is no longer part of the join decision
      assert length(calls(:pending_invitation)) == 1
    end
  end

  describe "F-3 - a moderator must outrank the target (room v10)" do
    @admin "@admin:test.local"
    @mod "@mod:test.local"
    @mod2 "@mod2:test.local"

    defp moderated_room(label), do: room_with_levels(label, [@admin, @mod, @mod2], %{@admin => 100, @mod => 50, @mod2 => 50}, %{"join_rule" => "public"})

    test "a PL-50 moderator can neither ban nor kick nor unban the PL-100 creator: 403 M_FORBIDDEN, nothing changes" do
      room_id = moderated_room("pl-lower")

      for kind <- [:ban, :kick, :unban] do
        assert {:error, {403, "M_FORBIDDEN", message}} = moderate(kind, room_id, @mod, @admin), Atom.to_string(kind)
        refute message =~ @admin
      end

      assert member?(room_id, @admin)
      assert member_events(@admin) |> Enum.filter(&(&1["sender"] == @mod)) == []
    end

    test "EQUAL levels are refused (PL-50 against PL-50) for ban, kick and unban" do
      room_id = moderated_room("pl-equal")

      for kind <- [:ban, :kick, :unban] do
        assert {:error, {403, "M_FORBIDDEN", _}} = moderate(kind, room_id, @mod, @mod2), Atom.to_string(kind)
      end

      assert member?(room_id, @mod2)
    end

    test "the creator (100) bans and kicks a PL-50 moderator, a PL-50 moderator bans a PL-0 member" do
      room_id = moderated_room("pl-higher")
      :ok = Nebu.Matrix.Room.Server.join(room_id, "@plain:test.local")

      assert {:ok, %Core.BanUserResponse{}} = moderate(:ban, room_id, @mod, "@plain:test.local")
      assert {:ok, %Core.KickUserResponse{}} = moderate(:kick, room_id, @admin, @mod2)
      assert {:ok, %Core.BanUserResponse{}} = moderate(:ban, room_id, @admin, @mod)
    end
  end

  # ═══ Review cycle 2 (Kassandra delta gate N-2 / N-4 / N-5) ═══════════════════════════════════════════════════════════

  describe "N-2 - a member whose latest membership is ban cannot lift the ban by leaving" do
    test "a user the room process still lists as a member (failed removal) but whose latest membership is ban: /leave is 403, the member stays listed, no leave event" do
      room_id = start_room_with(new_room_id("leave-member-banned"), ["@alice:test.local", "@bob:test.local"])
      seed_membership(room_id, "@bob:test.local", "ban")
      before = length(leave_events("@bob:test.local"))

      assert {:error, {403, "M_FORBIDDEN", "You are banned from this room"}} = leave_core("@bob:test.local", room_id)
      assert member?(room_id, "@bob:test.local"), "nothing was removed"
      assert length(leave_events("@bob:test.local")) == before, "no self-authored leave event"
    end

    test "an ordinary member still leaves (200, one leave event, no longer a member)" do
      room_id = start_room_with(new_room_id("leave-member-ok"), ["@alice:test.local", "@bob:test.local"])

      assert {:ok, %Core.LeaveRoomResponse{}} = leave_core("@bob:test.local", room_id)
      refute member?(room_id, "@bob:test.local")
      assert [%{"sender" => "@bob:test.local"}] = leave_events("@bob:test.local")
    end

    test "an unreadable membership is a 500 for a member's leave too, nothing changes" do
      room_id = start_room_with(new_room_id("leave-member-read-error"), ["@alice:test.local", "@bob:test.local"])
      :ets.insert(:join_room_test_db, {{:membership_read, room_id}, {:error, :db_down}})

      capture = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, leave_core("@bob:test.local", room_id)}) end)
      assert_received {:result, {:error, {500, _, _}}}
      assert is_binary(capture)
      assert member?(room_id, "@bob:test.local")
    end
  end

  describe "N-4 - a failed force-add keeps a legitimate pending invitation" do
    test "a target with a pending invitation: the force-add USES it (no second insert, the inviter is not overwritten); when the join fails for another reason the invitation survives" do
      room_id = start_room_with(new_room_id("admin-add-keeps"), ["@admin:test.local"])
      seed_rule(room_id, %{"join_rule" => "private"})
      invite!(room_id, "@inviter:test.local", "@target:test.local")
      inserts_before = length(calls(:insert_invitation))

      # `private` refuses even an invited user: the force-add fails for a reason that is not a ban
      assert {:error, _} = Server.admin_add_room_member(room_id, "@target:test.local", "@admin:test.local")
      assert length(calls(:insert_invitation)) == inserts_before, "the pending invitation was not re-armed"
      assert pending_rooms("@target:test.local") == [room_id], "the legitimate invitation survived the failed force-add"
    end

    test "a target WITHOUT an invitation: the invitation this call created is dropped again when the join fails" do
      room_id = start_room_with(new_room_id("admin-add-drops"), ["@admin:test.local"])
      seed_rule(room_id, %{"join_rule" => "private"})

      assert {:error, _} = Server.admin_add_room_member(room_id, "@target:test.local", "@admin:test.local")
      assert pending_rooms("@target:test.local") == []
      assert length(calls(:insert_invitation)) == 1
    end

    test "a pending invitation makes the force-add succeed and is accepted" do
      room_id = start_room_with(new_room_id("admin-add-uses"), ["@admin:test.local"])
      seed_rule(room_id, %{"join_rule" => "invite"})
      invite!(room_id, "@inviter:test.local", "@target:test.local")

      assert {:ok, ^room_id} = Server.admin_add_room_member(room_id, "@target:test.local", "@admin:test.local")
      assert member?(room_id, "@target:test.local")
      assert pending_rooms("@target:test.local") == []
    end
  end

  describe "N-5 - kick and unban fail (500) when the pending invitation cannot be rejected" do
    test "kick: a failing rejection is a 500 and rolls the whole kick back (one transaction); a retry succeeds" do
      room_id = room_with_levels("kick-reject-fails", ["@alice:test.local", "@bob:test.local", "@carol:test.local"], %{"@alice:test.local" => 100})
      invite!(room_id, "@bob:test.local", "@bob:test.local")

      :ets.insert(:join_room_test_db, {:reject_fail, true})
      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, moderate(:kick, room_id, "@alice:test.local", "@bob:test.local")}) end)
      assert_received {:result, {:error, {500, _, _}}}
      assert log =~ room_id
      assert log =~ ":db_down"
      refute log =~ "@bob:test.local"
      # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): the reject is a statement of the ONE transaction of the
      # kick now (Room.DB.apply_member_change/4), so a failing reject rolls the whole kick back and there is no retry of the reject alone
      # (was: `calls(:reject_invitation) == 2, "one retry"` and a `:reject_fail_once` kick that succeeded on the retry)
      assert calls(:apply_member_change) |> Enum.filter(&(elem(&1, 1) == room_id)) |> length() == 1, "one transaction, no retry"
      # N-7: the 500 left everything untouched: still a member, no kick event, the invitation still pending, a retry works
      assert member?(room_id, "@bob:test.local")
      assert Enum.filter(leave_events("@bob:test.local"), &(&1["sender"] == "@alice:test.local")) == []
      assert pending_rooms("@bob:test.local") == [room_id]
      :ets.delete(:join_room_test_db, :reject_fail)
      assert {:ok, %Core.KickUserResponse{}} = moderate(:kick, room_id, "@alice:test.local", "@bob:test.local")
      refute member?(room_id, "@bob:test.local")
      assert pending_rooms("@bob:test.local") == []
    end

    test "unban: a failing rejection is a 500 and NO unban event is written; a retry succeeds" do
      room_id = room_with_levels("unban-reject-fails", ["@alice:test.local"], %{"@alice:test.local" => 100})
      invite!(room_id, "@alice:test.local", "@banned:test.local")
      seed_membership(room_id, "@banned:test.local", "ban")
      :ets.insert(:join_room_test_db, {:reject_fail, true})

      capture = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, moderate(:unban, room_id, "@alice:test.local", "@banned:test.local")}) end)
      assert_received {:result, {:error, {500, _, _}}}
      assert is_binary(capture)
      assert leave_events("@banned:test.local") == [], "the unban event was not written"

      :ets.delete(:join_room_test_db, :reject_fail)
      assert {:ok, %Core.UnbanUserResponse{}} = moderate(:unban, room_id, "@alice:test.local", "@banned:test.local")
      assert pending_rooms("@banned:test.local") == []
    end
  end
  # ─── story sync-membership-partition (D13, AC19 (b) (c) (d) (f)): the join decision honours a taken-back invitation ──────────────
  #
  # authorize_join!/2 granted an invite-only room on a PENDING ROW alone. Every writer that ends an invitation rejects the row, but several
  # only best effort (a failed reject leaves a row that is still pending behind a `leave` member event): such a user must not stay
  # joinable. The decision counts the invitation only when the row is pending AND the user's latest member event is not a `leave` with
  # `origin_server_ts >= invited_at` (a tie is a taken-back invitation, the most restrictive reading). A row-only invitation (upgrade_room,
  # every legacy invitation: no member event, or an OLDER leave) stays valid. Both reads fail closed (500).

  describe "AC19 - join decision, taken-back invitation (D13)" do
    @creator "@creator:test.local"
    @not_invited "You are not invited to this room"

    defp invite_only(label), do: room_with_rule(label, %{"join_rule" => "invite"})

    defp assert_refused_not_invited(room_id, user, label) do
      assert {:error, {403, "M_FORBIDDEN", message}} = join_as(user, room_id), "#{label}: 403 M_FORBIDDEN"
      assert message == @not_invited, "#{label}: the fixed text, got #{inspect(message)}"
      refute member?(room_id, user), "#{label}: nobody joined"
      assert join_events(user) == [], "#{label}: no join event"
    end

    test "(b) pending row, latest member event a leave NEWER than invited_at (by the inviter: removal, by the invitee: decline): 403 not invited" do
      for {label, sender_of} <- [removal: fn _user -> @creator end, decline: fn user -> user end] do
        room_id = invite_only("taken-back-#{label}")
        user = "@taken-back-#{label}-#{rand_hex()}:test.local"
        invite!(room_id, @creator, user)
        set_invited_at(room_id, user, 100)
        seed_member_event(room_id, user, "leave", 101, sender_of.(user))

        assert_refused_not_invited(room_id, user, to_string(label))
        assert calls(:accept_invitation) == [], "#{label}: the invitation is not accepted"
      end
    end

    test "(c) a leave in the SAME millisecond as invited_at counts as taken back (the most restrictive reading): 403" do
      room_id = invite_only("taken-back-tie")
      user = "@tie-#{rand_hex()}:test.local"
      invite!(room_id, @creator, user)
      set_invited_at(room_id, user, 100)
      seed_member_event(room_id, user, "leave", 100, @creator)

      assert_refused_not_invited(room_id, user, "tie")
    end

    test "(d) a leave OLDER than invited_at (re-invited former member, legacy row-only re-invite) is a valid invitation: 200, accepted" do
      room_id = invite_only("older-leave")
      user = "@older-#{rand_hex()}:test.local"
      invite!(room_id, @creator, user)
      set_invited_at(room_id, user, 100)
      seed_member_event(room_id, user, "leave", 99, user)

      assert {:ok, %Core.JoinRoomResponse{room_id: ^room_id}} = join_as(user, room_id)
      assert member?(room_id, user)
      assert length(calls(:accept_invitation)) == 1
    end

    test "(d) a row-only invitation WITHOUT any member event (upgrade, legacy) and an invite event newer than a leave are valid: 200" do
      row_only = invite_only("row-only")
      user = "@rowonly-#{rand_hex()}:test.local"
      invite!(row_only, @creator, user)
      assert {:ok, _} = join_as(user, row_only)

      invited = invite_only("event-backed")
      other = "@eventbacked-#{rand_hex()}:test.local"
      invite!(invited, @creator, other)
      set_invited_at(invited, other, 100)
      seed_member_event(invited, other, "invite", 101, @creator)
      assert {:ok, _} = join_as(other, invited)
    end

    test "(e) after a NEW invitation (the row is re-armed, a newer invite event) the former taken-back invitee joins: 403 first, then 200" do
      room_id = invite_only("re-invite")
      user = "@reinvite-#{rand_hex()}:test.local"
      invite!(room_id, @creator, user)
      set_invited_at(room_id, user, 100)
      seed_member_event(room_id, user, "leave", 101, @creator)
      assert_refused_not_invited(room_id, user, "before the new invitation")

      invite!(room_id, @creator, user)
      set_invited_at(room_id, user, 200)
      seed_member_event(room_id, user, "invite", 201, @creator)

      assert {:ok, _} = join_as(user, room_id)
      assert member?(room_id, user)
    end

    test "a ban is still decided before the invitation (403 'banned' text), and a REJECTED invitation behind a leave stays a refusal" do
      room_id = invite_only("ban-first")
      user = "@banfirst-#{rand_hex()}:test.local"
      invite!(room_id, @creator, user)
      set_invited_at(room_id, user, 100)
      seed_membership(room_id, user, "ban")
      seed_member_event(room_id, user, "ban", 101, @creator)
      assert {:error, {403, "M_FORBIDDEN", "You are banned from this room"}} = join_as(user, room_id)

      rejected = invite_only("rejected-leave")
      other = "@rejected-#{rand_hex()}:test.local"
      invite!(rejected, @creator, other)
      :ok = FakeInviteDB.reject_invitation(rejected, other)
      seed_member_event(rejected, other, "leave", 101, other)
      assert_refused_not_invited(rejected, other, "rejected row")
    end

    test "(f) a failing latest-member-event read (error, raise) is a 500, nobody joins, the log has room id and error class only; a public join fails closed too" do
      for {label, failure} <- [error: {:error, pg_error("mkevent#{rand_hex()}")}, raise: :raise] do
        room_id = invite_only("latest-event-#{label}")
        user = "@latest-#{label}-#{rand_hex()}:test.local"
        invite!(room_id, @creator, user)
        :ets.insert(:join_room_test_db, {{:latest_event_read, room_id}, failure})

        log = assert_500_no_join(room_id, user, "latest member event read #{label}")

        assert log =~ room_id, "#{label}: the log names the room id"
        refute log =~ user, "#{label}: no user id in the log"
      end

      public = room_with_rule("latest-event-public", %{"join_rule" => "public"})
      # story member-event-prev-content (DELIBERATE re-pin, D4 (a); old -> new): the ban check INSIDE the room process reads latest_member_event/2 now
      # (the same read yields the stamp), so a failing read refuses EVERY join, a public one too (fail closed, as for the membership read before):
      # `{:ok, _}` -> a 500. The decision itself still does not read it for a public room: exactly ONE read, the one of the room process.
      public_marker = "mkpublic#{rand_hex()}"
      :ets.insert(:join_room_test_db, {{:latest_event_read, public}, {:error, pg_error(public_marker)}})

      public_log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:public, join_as("@public-#{rand_hex()}:test.local", public)}) end)
      assert_received {:public, {:error, {500, _, _}}}
      assert public_log =~ public, "the log names the room id"
      refute String.downcase(public_log) =~ public_marker, "the log carries no value of the error"
      assert calls(:latest_member_event) |> Enum.filter(&(elem(&1, 1) == public)) |> length() == 1, "only the room process reads the latest member event of a public room (ban check + stamp)"
    end

    test "(f) a failing or raising pending-invitation read is a 500 in an invite room (fail closed), nobody joins" do
      for failure <- [{:error, :db_down}, :raise] do
        :ets.insert(:join_room_test_db, {:pending_read, failure})
        room_id = invite_only("pending-read-#{System.unique_integer([:positive])}")
        user = "@pendingread-#{rand_hex()}:test.local"
        invite!(room_id, @creator, user)

        assert_500_no_join(room_id, user, "pending invitation read #{inspect(failure)}")
      end
    end
  end

end
