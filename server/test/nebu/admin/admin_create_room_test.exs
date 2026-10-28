defmodule Nebu.Admin.AdminCreateRoomTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  # ─── Story rm3-admin-create-archive (AC2/AC4) ────────────────────────────────
  #
  # Verifies the admin "Create room" path through the Matrix public API
  # `Nebu.Matrix.create_room/2`:
  #   - the creator becomes the room creator (m.room.create) and first member
  #     (m.room.member join) — AC4
  #   - visibility "public" is persisted (rooms.visibility) via the audited
  #     set_room_visibility path — AC2
  #   - a `room_created` audit row is written with the admin actor — AC4
  #
  # ATDD: written FIRST, expected to FAIL until Nebu.Matrix.create_room/2 exists.
  #
  # async: false — Horde, :pg, Application.put_env, ETS are process-global.
  #
  # Test seams mirror create_room_test.exs / audit_archive_ops_test.exs:
  #   - :room_manager/:db_module + :event_dispatcher/:messages_db_module → FakeDB (no Postgres)
  #   - :event_dispatcher/:admin_db_module → FakeAdminDB (captures update_room_visibility)
  #   - :compliance/:audit_writer → FakeAuditWriter (Process.send spy)
  #
  # ─── AC3 of story fix-bootstrap-admin-session-identity ───────────────────────
  #
  # The describe block "AC3: room-creator after bootstrap ..." below drives the
  # REAL Admin HTTP pipeline (Nebu.Admin.Endpoint → router → RoomsController.create/2
  # → actor_id/1) instead of calling Nebu.Matrix.create_room/2 directly with a
  # hardcoded "@admin:test.local" string, exactly because the tests ABOVE that call
  # Matrix.create_room/2 directly bypass actor_id/1 entirely and therefore CANNOT
  # catch the bug this story fixes (session missing matrix_user_id → actor_id/1
  # falls back to the raw OIDC sub). Verified via code read of
  # server/lib/nebu/admin/rooms_controller.ex:503-509 (actor_id/1) and
  # server/test/nebu/admin/admin_http_controllers_test.exs (build_admin_conn/
  # endpoint_call pattern, the only other test file in this repo that dispatches
  # through the real Nebu.Admin.Endpoint for RoomsController).

  alias Nebu.Matrix

  # Spy that records every audit log/6 (and log/7) to the test pid.
  defmodule FakeAuditWriter do
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      pid = Application.get_env(:compliance, :__audit_test_pid__)

      if pid && Process.alive?(pid) do
        send(pid, {:audit_log, actor, action, target_type, target_id, metadata, outcome, error_detail})
      end

      :ok
    end
  end

  # ETS-backed Room.DB fake (subset used by create_room/2) — no Postgres.
  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:admin_create_room_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(:admin_create_room_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:admin_create_room_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:admin_create_room_test_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:admin_create_room_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:admin_create_room_test_db, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(:admin_create_room_test_db, {{:event, event["event_id"]}, event})
      send_to_test({:event_inserted, event["type"], event["state_key"], event["sender"]})
      :ok
    end

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, json) do
      :ets.insert(:admin_create_room_test_db, {{:power_levels, room_id}, json})
      :ok
    end

    def update_room_name(room_id, name) do
      :ets.insert(:admin_create_room_test_db, {{:room_name, room_id}, name})
      :ok
    end

    def update_room_type(_room_id, _type), do: :ok

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}

    defp send_to_test(msg) do
      pid = Application.get_env(:event_dispatcher, :__create_room_test_pid__)
      if pid && Process.alive?(pid), do: send(pid, msg)
      :ok
    end
  end

  # Captures the visibility write driven by set_room_visibility/3 → admin_db.
  defmodule FakeAdminDB do
    def update_room_visibility(room_id, visibility) do
      :ets.insert(:admin_create_room_test_db, {{:visibility, room_id}, visibility})
      pid = Application.get_env(:event_dispatcher, :__create_room_test_pid__)
      if pid && Process.alive?(pid), do: send(pid, {:visibility_written, room_id, visibility})
      :ok
    end
  end

  setup do
    if :ets.info(:admin_create_room_test_db) != :undefined do
      :ets.delete(:admin_create_room_test_db)
    end

    :ets.new(:admin_create_room_test_db, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:event_dispatcher, :__create_room_test_pid__, self())
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter)
    Application.put_env(:compliance, :__audit_test_pid__, self())

    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      Application.delete_env(:room_manager, :db_module)
      Application.delete_env(:event_dispatcher, :user_store_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :admin_db_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:event_dispatcher, :__create_room_test_pid__)
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:compliance, :__audit_test_pid__)

      if :ets.info(:admin_create_room_test_db) != :undefined do
        :ets.delete(:admin_create_room_test_db)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  defp stop_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        if Process.alive?(pid),
          do: Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)

      _ ->
        :ok
    end
  end

  describe "Nebu.Matrix.create_room/2 — admin create path (AC2/AC4)" do
    test "creates a public room: create + member-join events, visibility, audit row" do
      admin = "@admin:test.local"

      assert {:ok, room_id} = Matrix.create_room(admin, name: "General", visibility: "public")
      on_exit(fn -> stop_room(room_id) end)

      assert is_binary(room_id) and room_id != ""

      # AC4 — the admin is the creator (m.room.create) and first member (m.room.member join).
      assert_receive {:event_inserted, "m.room.create", "", ^admin}, 500
      state = Nebu.Matrix.Room.Server.get_state(room_id)
      assert MapSet.member?(state.members, admin)

      # AC2 — visibility "public" persisted via the audited set_room_visibility path.
      assert_receive {:visibility_written, ^room_id, "public"}, 500

      # AC4 — a room_created audit row with the admin actor.
      assert_receive {:audit_log, ^admin, "room_created", "room", ^room_id, _meta, "success", _}, 500
    end

    test "private (default) does not write visibility but still creates + audits" do
      admin = "@admin:test.local"

      assert {:ok, room_id} = Matrix.create_room(admin, name: "Secret")
      on_exit(fn -> stop_room(room_id) end)

      assert_receive {:event_inserted, "m.room.create", "", ^admin}, 500
      assert_receive {:audit_log, ^admin, "room_created", "room", ^room_id, _meta, "success", _}, 500

      # private is the default — no visibility flip.
      refute_received {:visibility_written, _, _}
    end

    test "an invalid visibility is rejected before any room is created (default-deny)" do
      assert {:error, :invalid_visibility} =
               Matrix.create_room("@admin:test.local", name: "Nope", visibility: "bogus")

      refute_received {:event_inserted, "m.room.create", _, _}
      refute_received {:audit_log, _, "room_created", _, _, _, _, _}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 (story fix-bootstrap-admin-session-identity) — room-creator after a
  # bootstrap-completion login is the canonical Matrix user_id, NOT the raw OIDC
  # sub. Driven through the REAL Admin HTTP pipeline (Endpoint → Router →
  # RoomsController.create/2 → actor_id/1) with a session minted via the REAL
  # Nebu.Admin.Auth.put_current_user/2 — the exact builder bootstrap_confirm_claim/2
  # now shares (AC1) — not a hand-rolled map. Before this story's fix,
  # bootstrap_confirm_claim/2 minted sessions with sub/email but no "matrix_user_id",
  # which made actor_id/1 fall back to the raw sub; that shape can no longer occur
  # from the real bootstrap-completion path (verified below), and RoomsController
  # deliberately has no defense-in-depth fallback for a stale/malformed session
  # missing matrix_user_id — see code-review-findings.md MAJOR-1 for why that
  # fallback was rejected (silent mis-derivation risk when a non-default
  # oidc_user_id_claim is configured, plus an ADR-020 concern).
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3: room-creator after bootstrap is the Matrix user_id, not the raw sub" do
    @endpoint Nebu.Admin.Endpoint
    @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)

    setup do
      Application.put_env(:nebu_http, :admin_csrf_bypass, true)

      test_pid = self()

      # Capture the actor_id RoomsController.create/2 actually passed to the room
      # creator, without needing a live Matrix room/Repo stack for this assertion.
      Application.put_env(:nebu_http, :admin_room_creator, fn actor_id, _opts ->
        send(test_pid, {:create_room_called, actor_id})
        {:ok, "!captured:test.local"}
      end)

      on_exit(fn ->
        Application.delete_env(:nebu_http, :admin_csrf_bypass)
        Application.delete_env(:nebu_http, :admin_room_creator)
      end)

      :ok
    end

    defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

    # Mints the session via the REAL Nebu.Admin.Auth.put_current_user/2 — the exact
    # function bootstrap_confirm_claim/2 now calls internally (story
    # fix-bootstrap-admin-session-identity, AC1) — rather than a hand-rolled map. This
    # is the accurate reproduction of what a freshly-completed bootstrap session
    # contains today: put_current_user/2 always sets "matrix_user_id" via
    # Nebu.Matrix.UserId.from_claims/2, so this fixture exercises the FIXED path, not
    # the pre-fix bug. (The pre-fix bug — a session with sub/email but no
    # matrix_user_id — cannot occur from bootstrap_confirm_claim/2 anymore; RoomsController
    # deliberately has no defense-in-depth fallback for that shape, by design decision
    # during this story's code review, to avoid silently mis-deriving matrix_user_id for
    # a claim configuration it can't see — see code-review-findings.md MAJOR-1.)
    defp bootstrap_session_conn(method, path, claims) do
      %{conn(method, path) | secret_key_base: @secret_key_base}
      |> Nebu.Admin.Endpoint.admin_session([])
      |> fetch_session()
      |> Nebu.Admin.Auth.put_current_user(claims)
    end

    test "operator who never logged in via Matrix creates a room → creator is the canonical Matrix user_id" do
      claims = %{
        "sub" => "01923abf-raw-oidc-sub-value",
        "email" => "operator@example.com",
        # admin_claim?/1 (auth.ex) must resolve true for this session to pass the
        # router's admin-guard plug — "instance_admin" is the default admin_group_claim.
        "groups" => ["instance_admin"]
      }

      conn =
        bootstrap_session_conn(:post, "/admin/rooms", claims)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        # story admin-forms-gate-sweep: the strict fetch metadata of a user-clicked submit
        |> Nebu.OAuth.TestSupport.put_strict_fetch_headers()
        |> Map.put(:body_params, %{"name" => "Ops Room", "visibility" => "private"})
        |> Map.put(:params, %{"name" => "Ops Room", "visibility" => "private"})
        |> endpoint_call()

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/rooms/%21captured%3Atest.local"]

      assert_receive {:create_room_called, actor_id}, 500

      refute actor_id == "01923abf-raw-oidc-sub-value",
             "regression: actor_id/1 must not fall back to the raw OIDC sub for a " <>
               "session minted by put_current_user/2 (the builder bootstrap_confirm_claim/2 " <>
               "now shares) — this is exactly the live bug " <>
               "fix-bootstrap-admin-session-identity fixes. Room creator must be the " <>
               "canonical Matrix user_id (@localpart:server), never the opaque sub."

      assert Nebu.Matrix.UserId.valid?(actor_id),
             "the room creator actor_id must be a syntactically valid Matrix user_id " <>
               "(@localpart:server); got: #{inspect(actor_id)}"

      assert actor_id == Nebu.Matrix.UserId.from_claims(claims, "localhost")
    end

    test "a session WITH matrix_user_id (post-fix shape) is used as-is — sanity/contrast case" do
      now = System.system_time(:second)

      conn =
        %{conn(:post, "/admin/rooms") | secret_key_base: @secret_key_base}
        |> Nebu.Admin.Endpoint.admin_session([])
        |> fetch_session()
        |> put_session("current_user", %{
          "sub" => "01923abf-raw-oidc-sub-value",
          "email" => "operator@example.com",
          "admin" => true,
          "matrix_user_id" => "@operator:test.local",
          "session_exp" => now + 8 * 3600,
          "refresh_grace_exp" => now + 8 * 3600 + 180
        })
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        # story admin-forms-gate-sweep: the strict fetch metadata of a user-clicked submit
        |> Nebu.OAuth.TestSupport.put_strict_fetch_headers()
        |> Map.put(:body_params, %{"name" => "Ops Room", "visibility" => "private"})
        |> Map.put(:params, %{"name" => "Ops Room", "visibility" => "private"})
        |> endpoint_call()

      assert conn.status == 302
      assert_receive {:create_room_called, actor_id}, 500
      assert actor_id == "@operator:test.local"
    end
  end
end
