defmodule Nebu.Matrix.EventDispatcher.PersonalRoomArchiveGuardTest do
  use ExUnit.Case, async: false

  # ─── Story rm5-personal-guards-optout — AC2 + AC6 ───────────────────────────
  #
  # ATDD — written FIRST (before the archive-guard implementation).
  #
  # AC2: archive_room/2 for a room_id matching ANY user's personal_room_id raises
  #      Nebu.Matrix.Error permission_denied (→ HTTP 403 M_FORBIDDEN). rooms.status
  #      stays 'active' — archive_room_atomic/1 is NEVER called. Holds even when
  #      the request bypasses the Admin UI guard (this is a direct handler call).
  #
  # AC6 (regression): archiving a NORMAL room still works — archive_room_atomic/1
  #      is called and ok=true is returned.
  #
  # The guard must run BEFORE archive_room_atomic/1. We prove that by recording
  # every archive_room_atomic/1 call in ETS and asserting it stays empty on reject.
  #
  # async: false — Application.put_env/3 + Horde are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @personal_room_id "!alice_self:nebu.local"
  @normal_room_id "!general:nebu.local"

  # ─── Fake admin DB: get_personal_room_owner is the guard input ──────────────
  # NOTE: nested modules do NOT inherit the outer module's @attributes — the ids
  # are inlined as literals (must stay in sync with @personal_room_id / @owner_id).
  defmodule FakeAdminDB do
    def get_personal_room_owner("!alice_self:nebu.local"), do: {:ok, "@alice:nebu.local"}
    def get_personal_room_owner(_), do: {:error, :not_found}

    def archive_room_atomic(room_id) do
      :ets.insert(:archive_guard_test, {{:archived, room_id}, true})
      :ok
    end
  end

  setup do
    if :ets.info(:archive_guard_test) != :undefined, do: :ets.delete(:archive_guard_test)
    :ets.new(:archive_guard_test, [:named_table, :public, :set])

    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB)
    Application.put_env(:compliance, :audit_writer, __MODULE__.NoOpAuditWriter)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :admin_db_module)
      Application.delete_env(:compliance, :audit_writer)
      if :ets.info(:archive_guard_test) != :undefined, do: :ets.delete(:archive_guard_test)
    end)

    :ok
  end

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  defp stream, do: %{http_request_headers: %{"x-user-id" => "@admin:nebu.local"}}

  test "AC2: archiving a personal room raises permission_denied" do
    err =
      assert_raise Nebu.Matrix.Error, fn ->
        Server.archive_room(%Core.ArchiveRoomRequest{room_id: @personal_room_id}, stream())
      end

    assert err.status == Nebu.Matrix.Status.permission_denied()
    assert err.message =~ "personal room"
  end

  test "AC2: rooms.status stays active — archive_room_atomic is never called" do
    assert_raise Nebu.Matrix.Error, fn ->
      Server.archive_room(%Core.ArchiveRoomRequest{room_id: @personal_room_id}, stream())
    end

    assert :ets.lookup(:archive_guard_test, {:archived, @personal_room_id}) == []
  end

  test "AC6: archiving a NORMAL (non-personal) room still succeeds" do
    resp = Server.archive_room(%Core.ArchiveRoomRequest{room_id: @normal_room_id}, stream())
    assert %Core.ArchiveRoomResponse{ok: true} = resp
    assert :ets.lookup(:archive_guard_test, {:archived, @normal_room_id}) != []
  end
end
