defmodule Nebu.Matrix.EventDispatcher.SpacesCreateRoomTest do
  use ExUnit.Case, async: false

  # ─── Spaces S1 — createRoom honours creation_content + room_type persistence ──
  #
  # Story: spaces-elixir / s1-spaces-foundation.
  # A Space is a normal room whose m.room.create content.type == "m.space" (MSC1772).
  #
  # These unit-level tests drive Server.create_room/2 directly with a FakeDB (no
  # PostgreSQL) and assert the handler-level behaviour for:
  #   AC1 — creation_content.type lands in the stored m.room.create content.type.
  #   AC2 — room_type is persisted via update_room_type/2 (captured by FakeDB).
  #   AC4 — a regular room (no creation_content/room_type) gets NO type key in the
  #         create content and NO update_room_type/2 call (so the column stays NULL).
  #   AC5 — extra creation_content keys are merged into create content, but the
  #         server-controlled creator/room_version cannot be overridden by the client.
  #
  # The full DB-column + /sync assertions (AC2 DB, AC3) live in the :integration
  # suite (spaces_foundation_integration_test.exs) which runs against real Postgres.
  #
  # async: false — Horde, :pg, Application.put_env and the :NebuTxnDedup ETS table
  # are process-global. Mirrors create_room_test.exs.

  alias Nebu.Matrix.EventDispatcher.Server

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # ETS-backed fake satisfying the Room DB surface used by create_room/2.
  # Captures insert_event payloads and update_room_type/2 calls so the tests can
  # inspect the stored m.room.create content and whether the type was persisted.
  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:spaces_create_room_db, {:room, room_id}) do
        [] -> {:error, :not_found}
        [{_, created_at_ms}] ->
          members = :ets.match(:spaces_create_room_db, {{:member, room_id, :"$1"}, :active})
          pl_json =
            case :ets.lookup(:spaces_create_room_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end
          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:spaces_create_room_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:spaces_create_room_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:spaces_create_room_db, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(:spaces_create_room_db, {{:event, event["event_id"]}, event})
      :ok
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(:spaces_create_room_db, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    # Capture the room_type write so tests can assert AC2 / AC4.
    def update_room_type(room_id, room_type) do
      :ets.insert(:spaces_create_room_db, {{:room_type, room_id}, room_type})
      :ok
    end

    # rooms.name write is routed through the injectable rooms_db_module too (so the
    # name-persistence path does not require a live Repo in unit tests).
    def update_room_name(room_id, name) do
      :ets.insert(:spaces_create_room_db, {{:room_name, room_id}, name})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  setup do
    if :ets.info(:spaces_create_room_db) != :undefined do
      :ets.delete(:spaces_create_room_db)
    end
    :ets.new(:spaces_create_room_db, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    # rooms_db_module() is how create_room/2 reaches update_room_type/2 — inject FakeDB
    # so the room_type write is captured and never hits Nebu.Repo.
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      Application.delete_env(:room_manager, :db_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:compliance, :audit_writer)

      if :ets.info(:spaces_create_room_db) != :undefined do
        :ets.delete(:spaces_create_room_db)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  defp build_stream, do: %{http_request_headers: %{}}

  defp track_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)
        :ok

      _ ->
        :ok
    end
  end

  # Fetch the stored m.room.create content for a room.
  defp create_content(room_id) do
    :ets.match(:spaces_create_room_db, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.find(fn ev -> ev["room_id"] == room_id and ev["type"] == "m.room.create" end)
    |> case do
      nil -> nil
      ev -> ev["content"]
    end
  end

  defp persisted_room_type(room_id) do
    case :ets.lookup(:spaces_create_room_db, {:room_type, room_id}) do
      [{_, type}] -> type
      [] -> nil
    end
  end

  # ─── AC1 — creation_content.type == "m.space" → stored create content.type ───
  describe "create_room/2 — Space creation" do
    test "creation_content.type=m.space lands in m.room.create content.type" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "My Space",
        room_type: "m.space",
        creation_content_json: Jason.encode!(%{"type" => "m.space"})
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      content = create_content(resp.room_id)
      assert content["type"] == "m.space",
             "expected m.room.create content.type == m.space, got: #{inspect(content)}"

      # Server-controlled fields are still present and correct.
      assert content["creator"] == "@alice:test.local"
      assert content["room_version"] == "10"
    end

    # ─── AC2 — room_type persisted via update_room_type/2 ──────────────────────
    test "room_type is persisted to rooms.room_type via update_room_type/2" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Persisted Space",
        room_type: "m.space",
        creation_content_json: Jason.encode!(%{"type" => "m.space"})
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert persisted_room_type(resp.room_id) == "m.space"
    end
  end

  # ─── AC4 — backward compatibility (regular room) ────────────────────────────
  describe "create_room/2 — regular room (no creation_content)" do
    test "regular room has NO type key in create content and NO room_type write" do
      req = %Core.CreateRoomRequest{
        creator_id: "@bob:test.local",
        name: "Plain Room"
        # room_type defaults to "", creation_content_json defaults to ""
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      content = create_content(resp.room_id)
      refute Map.has_key?(content, "type"),
             "regular room must not have a type key in create content, got: #{inspect(content)}"

      assert content["creator"] == "@bob:test.local"
      assert content["room_version"] == "10"

      # update_room_type/2 must NOT be called → rooms.room_type stays NULL.
      assert persisted_room_type(resp.room_id) == nil,
             "regular room must not persist a room_type"
    end
  end

  # ─── AC5 — extra creation_content keys merged; creator/room_version protected ─
  describe "create_room/2 — creation_content merge semantics" do
    test "extra creation_content keys are merged into create content" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Extra Keys Space",
        room_type: "m.space",
        creation_content_json:
          Jason.encode!(%{"type" => "m.space", "m.federate" => false, "custom_flag" => "x"})
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      content = create_content(resp.room_id)
      assert content["type"] == "m.space"
      assert content["m.federate"] == false
      assert content["custom_flag"] == "x"
    end

    test "client cannot override server-controlled creator/room_version" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Override Attempt",
        room_type: "m.space",
        creation_content_json:
          Jason.encode!(%{
            "type" => "m.space",
            "creator" => "@evil:test.local",
            "room_version" => "1"
          })
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      content = create_content(resp.room_id)
      assert content["creator"] == "@alice:test.local",
             "server must keep creator authoritative, got: #{inspect(content["creator"])}"

      assert content["room_version"] == "10",
             "server must keep room_version authoritative, got: #{inspect(content["room_version"])}"

      # The legitimate type key still merges.
      assert content["type"] == "m.space"
    end
  end
end
