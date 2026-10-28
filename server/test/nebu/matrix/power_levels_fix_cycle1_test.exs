defmodule Nebu.Matrix.PowerLevelsFixCycle1Test do
  @moduledoc """
  Story `power-levels-enforcement`, fix cycle 1, REAL database through `Nebu.Web.Router`:

    * Kassandra L-1: after the freeze of an upgrade the requester's level is decided AGAIN on the authoritative levels (a demotion in
      the gap between the snapshot and the freeze is a post-freeze `500`), and that level is his initial level in the new room;
    * review I1: an object body that merely carries a top-level `"_json"` key is a content like any other (only the wrapper of a
      non-object JSON body, its ONLY key, is the `400`).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport

  alias Nebu.Matrix.PowerLevelsTestSupport.Hooks
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  @pl "m.room.power_levels"

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    prior_audit = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      T.restore_rate_limits()

      case prior_audit do
        {:ok, value} -> Application.put_env(:compliance, :audit_writer, value)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end
    end)

    {:ok, a: user!("PFA"), b: user!("PFB")}
  end

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  defp events_of(room, type),
    do: T.sql!("SELECT content FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts, event_id", [room, type]).rows |> Enum.map(fn [c] -> content_of(c) end)

  describe "Kassandra L-1 - the upgrader's level after the freeze" do
    test "an upgrader demoted below 100 in the gap (A 100, B 50; the gap sets A 0, B 100) is a post-freeze 500: archived, nothing carried, audited", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}, %{"events" => %{@pl => 100}}))
      install_env!(:event_dispatcher, :admin_db_module, Hooks.AdminDB)
      on_exit(&Hooks.disarm_before_archive/0)
      Hooks.arm_before_archive(room, fn -> seed!(room, a, levels(%{a.uid => 0, b.uid => 100}, %{"events" => %{@pl => 100}})) end)

      conn = upgrade(a, room)

      assert_err(conn, 500, "M_UNKNOWN")
      refute conn.resp_body =~ a.uid
      assert length(events_of(room, "m.room.tombstone")) == 1, "the tombstone was written before the freeze"
      assert T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows == [["archived"]]
      assert [%{metadata: metadata, outcome: "failure"}] = upgrade_audit(room)
      new_room = metadata["new_room_id"]
      assert is_binary(new_room)
      assert pl_events(new_room) == [], "the demoted upgrader got no levels in the new room"
      assert events_of(new_room, "m.room.join_rules") == [], "nothing was copied"
    end

    test "an upgrader whose level changed in the gap (A 150 -> 120) starts the new room at the authoritative 120, the copy carries the gap's levels", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 150, b.uid => 50}, %{"events" => %{@pl => 100}}))
      install_env!(:event_dispatcher, :admin_db_module, Hooks.AdminDB)
      on_exit(&Hooks.disarm_before_archive/0)
      gap = levels(%{a.uid => 120, b.uid => 110}, %{"events" => %{@pl => 100}})
      Hooks.arm_before_archive(room, fn -> seed!(room, a, gap) end)

      conn = upgrade(a, room)
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]

      assert [initial | _] = pl_events(new_room)
      assert initial.content["users"] == %{a.uid => 120}, "the initial levels use the authoritative level, not the snapshot's 150"
      assert column(new_room)["users"] == gap["users"]
    end
  end

  # fix cycle 2 (Kassandra D-L1): a creator whose id carries a server-name port (relaxed grammar, refused by the strict rule)
  defp port_user! do
    uid = "@pfport#{T.rand(6)}:#{T.server_name()}:8448"
    {:ok, _} = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "ATDD port id", T.rand(4) <> "@example.com")
    %{uid: uid, at: T.legacy_session!(uid, "PFP" <> String.upcase(T.rand(3)), expires_at: session_expiry()).at}
  end

  describe "Kassandra D-L1 - a creator with a port keeps working through the client writer and the upgrade" do
    test "a full-content PUT repeating his unchanged entry is 200; a NEW port-id entry is 400; the upgrade keeps his level 100" do
      p = port_user!()
      room = public_room(p)
      assert column(room)["users"][p.uid] == 100

      ok_event_id!(put_pl(p, room, Map.put(column(room), "events_default", 5)))
      assert column(room)["events_default"] == 5

      added = update_in(column(room), ["users"], &Map.put(&1, "@other#{T.rand(4)}:#{T.server_name()}:8448", 1))
      conn = unchanged(room, fn -> put_pl(p, room, added) end)
      assert_err(conn, 400, "M_BAD_JSON", "users keys must be valid user ids")

      conn = upgrade(p, room)
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]
      assert column(new_room)["users"][p.uid] == 100, "the upgrader keeps his level in the new room"
      assert column(new_room)["events_default"] == 5
    end
  end

  describe "review MINOR-1 (fix cycle 2) - the Admin facade set_space_state/5 on a real space" do
    test "a committed m.room.power_levels change through set_space_state/5 writes exactly one room_power_levels_changed row and no space_* row", %{a: a} do
      space = make_room(a, %{"preset" => "private_chat", "creation_content" => %{"type" => "m.space"}})
      new = Map.put(column(space), "events_default", 3)

      assert {:ok, event_id} = Nebu.Matrix.set_space_state(space, a.uid, @pl, "", new)
      assert latest_pl(space).event_id == event_id
      assert [%{actor: actor, metadata: %{"changed_keys" => ["events_default"]}}] = pl_audit(space)
      assert actor == a.uid
      assert T.sql!("SELECT count(*) FROM audit_log WHERE target_id = $1 AND action LIKE 'space_%'", [space]).rows == [[0]]
    end
  end

  describe "review I1 - a top-level \"_json\" key in an object body" do
    test "an object with a \"_json\" key among the levels keys is 200 and stored; the non-object wrapper (a JSON array) stays 400", %{a: a} do
      room = public_room(a)
      new = Map.put(column(room), "_json", %{"note" => "x"})

      ok_event_id!(put_pl(a, room, new))
      assert column(room)["_json"] == %{"note" => "x"}

      conn = unchanged(room, fn -> put_raw(a, pl_path(room), "[1, 2]") end)
      assert_err(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")
    end
  end
end
