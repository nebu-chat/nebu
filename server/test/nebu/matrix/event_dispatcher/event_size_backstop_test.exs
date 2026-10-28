defmodule Nebu.Matrix.EventDispatcher.EventSizeBackstopTest do
  @moduledoc """
  Story `event-size-limit` (epic oauth-broker, follow-up `ep`), AC5: the write-site BACKSTOPS (D4 (b), D5, D6 (b)) and the upgrade of legacy rows (D8),
  against the real database. The router pre-checks are bypassed on purpose: the core is called directly (`EventDispatcher.Server`, `Room.Server`,
  `Nebu.Matrix` Admin wrappers), exactly as every caller that is NOT the HTTP router does (the Admin UI, a future route).

  What the backstops guarantee: the signed canonical bytes (`event_json`) decide, BEFORE `insert_event`, the txn-dedup entry, the broadcast and (for the
  power levels) the `rooms.power_levels_json` column write. The core raises `Nebu.Matrix.Error` with status `:too_large` and a fixed message, or returns
  `{:error, :event_too_large}` (`Room.Server`).

  AC5 (e) / (e2), the upgrade (D8): a legacy oversized state event (written before this story, inserted with `Room.DB.insert_event/1` as the CURRENT event of
  its slot) is not copied (ONE value-free warning: counts only); the three ACCESS types are copied in a REDUCED form that is never more open than the old
  room (the Oracle caveat): `join_rules` -> only `join_rule` (a string of at most 255 bytes) else `"private"`, `history_visibility` -> only that key else
  `"joined"`, `guest_access` -> only that key else `"forbidden"`; `allow` is dropped.

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC5 (d) `Nebu.Matrix.create_room/2` / `create_space/2`: neither can carry a client `initial_state` / `creation_content` (the content is fixed), so the
      createRoom refusal is pinned at the core (`Server.create_room/2`, same code path); the Admin wrapper maps the raise to `{:error, message}` as
      `set_space_state/5` does (pinned below for that one).
    * The upgrade warning (D8 (a)): the story names no text. Pinned: ONE warning-level log entry for the whole upgrade, containing the word `skipped` with
      its count and the word `reduced` with its count (a count is next to its word), and no type name, no content marker.
    * The upgrade is driven over HTTP (`POST /rooms/{id}/upgrade`), the joins over `POST /join/{roomId}`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @t_event "Event exceeds the maximum size of 65536 bytes"
  @t_is_event "An initial_state event exceeds the maximum size of 65536 bytes"

  # the audit writer of the test environment is a no-op: a spy makes "no space-edit audit row" a real assertion
  defmodule AuditSpy do
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      pid = Application.get_env(:compliance, :__event_size_backstop_audit_pid__)
      if pid && Process.alive?(pid), do: send(pid, {:audit_log, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    prior = for key <- [:audit_writer, :__event_size_backstop_audit_pid__], do: {key, Application.fetch_env(:compliance, key)}
    Application.put_env(:compliance, :audit_writer, AuditSpy)
    Application.put_env(:compliance, :__event_size_backstop_audit_pid__, self())

    on_exit(fn ->
      T.restore_rate_limits()

      for {key, previous} <- prior do
        case previous do
          {:ok, value} -> Application.put_env(:compliance, key, value)
          :error -> Application.delete_env(:compliance, key)
        end
      end
    end)

    {:ok, a: user!("EBA"), m: user!("EBM"), x: user!("EBX")}
  end

  # ─── helpers ──────────────────────────────────────────────────────────────────────────────

  defp user!(device_prefix) do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3))).at}
  end

  defp server, do: Application.get_env(:event_dispatcher, :server_name, "nebu.local")
  defp enc(s), do: URI.encode_www_form(s)
  defp stream(user), do: Nebu.Matrix.Http.stream(user.uid)
  defp pad(n \\ 70_000), do: String.duplicate("p", n)

  defp make_room(user, body \\ %{"preset" => "private_chat"}) do
    conn = T.matrix_request(:post, "/_matrix/client/v3/createRoom", user.at, body: body)
    assert conn.status == 200, "createRoom: #{conn.status} #{conn.resp_body}"
    T.json(conn)["room_id"]
  end

  defp event_count(room), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()
  defp type_count(room, type), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2", [room, type]).rows |> hd() |> hd()

  defp content_of(c) when is_map(c), do: c

  defp content_of(c) when is_binary(c) do
    case Jason.decode!(c) do
      decoded when is_binary(decoded) -> content_of(decoded)
      decoded -> decoded
    end
  end

  # the CURRENT content of a state slot in a room (latest event), as stored
  defp current_content(room, type, key \\ "") do
    case T.sql!("SELECT content FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3 ORDER BY origin_server_ts DESC, event_id DESC LIMIT 1", [room, type, key]).rows do
      [[content]] -> content_of(content)
      [] -> nil
    end
  end

  defp flush_audit do
    receive do
      {:audit_log, _, _, _, _, _, _, _} -> flush_audit()
    after
      0 -> :ok
    end
  end

  # the fixed 413 of the core: Nebu.Matrix.Error with the :too_large status and the fixed text
  defp assert_too_large(fun, text, marker \\ nil) do
    err = assert_raise Nebu.Matrix.Error, fun
    assert err.status == :too_large, "status: #{inspect(err.status)}, message: #{inspect(err.message)}"
    assert err.message == text
    if marker, do: refute(String.contains?(err.message, marker), "the message echoes a client value")
    err
  end

  # ═══ AC5 (a): set_room_state/2 ═══════════════════════════════════════════════════════════════

  describe "AC5 (a) - EventDispatcher.Server.set_room_state/2" do
    test "an oversized content_json raises the :too_large error with the fixed text; no events row, nothing broadcast; a small content is accepted (positive control)", %{a: a} do
      room = make_room(a)
      marker = "MARK" <> T.rand(6)
      :ok = :pg.join("room:" <> room, self())
      events = event_count(room)

      req = %Core.SetRoomStateRequest{
        room_id: room,
        sender_id: a.uid,
        event_type: "m.space.child",
        state_key: "!c:" <> server(),
        content_json: Jason.encode!(%{"via" => [server()], "m" => marker, "pad" => pad()})
      }

      assert_too_large(fn -> Server.set_room_state(req, stream(a)) end, @t_event, marker)
      assert event_count(room) == events, "no events row"
      refute_receive {:new_event, _}, 200

      ok = Server.set_room_state(%{req | content_json: Jason.encode!(%{"via" => [server()]})}, stream(a))
      assert %Core.SetRoomStateResponse{event_id: id} = ok
      assert_receive {:new_event, %{"event_id" => ^id}}, 2_000
    end

    test "for m.room.name the rooms.name column is unchanged by a refused write", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat", "name" => "Original name"})
      assert T.sql!("SELECT name FROM rooms WHERE room_id = $1", [room]).rows == [["Original name"]]
      names = type_count(room, "m.room.name")

      req = %Core.SetRoomStateRequest{
        room_id: room,
        sender_id: a.uid,
        event_type: "m.room.name",
        state_key: "",
        content_json: Jason.encode!(%{"name" => "Renamed", "x.pad" => pad()})
      }

      assert_too_large(fn -> Server.set_room_state(req, stream(a)) end, @t_event)
      assert T.sql!("SELECT name FROM rooms WHERE room_id = $1", [room]).rows == [["Original name"]], "the denormalised name is untouched"
      assert type_count(room, "m.room.name") == names
    end
  end

  # ═══ AC5 (b): send_event/2 ═══════════════════════════════════════════════════════════════════

  describe "AC5 (b) - EventDispatcher.Server.send_event/2" do
    test "an oversized content raises :too_large; no events row, no :NebuTxnDedup entry for the txn (a retry is processed afresh), nothing broadcast", %{a: a} do
      room = make_room(a)
      marker = "MARK" <> T.rand(6)
      txn = "bs-" <> T.rand(4)
      :ok = :pg.join("room:" <> room, self())
      events = event_count(room)

      req = %Core.SendEventRequest{
        room_id: room,
        sender_id: a.uid,
        event_type: "m.room.message",
        txn_id: txn,
        content: Jason.encode!(%{"msgtype" => "m.text", "body" => pad(), "m" => marker}),
        is_state_event: false
      }

      assert_too_large(fn -> Server.send_event(req, stream(a)) end, @t_event, marker)
      assert event_count(room) == events
      # story state-writer-redaction (DELIBERATE re-pin, Kassandra #5; old -> new): the /send txn key is {room, user, {:send, event_type, txn}} (a txn id is scoped to its path incl. the event type); was {room, user, txn}
      key = {room, a.uid, {:send, "m.room.message", txn}}
      assert :ets.lookup(:NebuTxnDedup, key) == [], "no txn-dedup entry for the refused attempt"
      refute_receive {:new_event, _}, 200

      # the same txn id with a small body is processed afresh (positive control)
      ok = Server.send_event(%{req | content: Jason.encode!(%{"msgtype" => "m.text", "body" => "small"})}, stream(a))
      assert %Core.SendEventResponse{event_id: id} = ok
      assert :ets.lookup(:NebuTxnDedup, key) == [{key, id}]
    end
  end

  # ═══ AC5 (c): Room.Server.set_power_levels/3 ═════════════════════════════════════════════════

  describe "AC5 (c) - Nebu.Matrix.Room.Server.set_power_levels/3" do
    test "oversized levels -> {:error, :event_too_large}; rooms.power_levels_json, the room's in-memory power_levels and its m.room.power_levels events are unchanged", %{a: a} do
      room = make_room(a)
      column = fn -> T.sql!("SELECT power_levels_json::text FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd() end
      column_before = column.()
      memory_before = Nebu.Matrix.Room.Server.get_state(room).power_levels
      events_before = type_count(room, "m.room.power_levels")
      assert events_before >= 1, "premise: createRoom wrote a power levels event"

      big = memory_before |> Map.put("x.pad", pad())
      assert {:error, :event_too_large} = Nebu.Matrix.Room.Server.set_power_levels(room, a.uid, big)

      assert column.() == column_before, "the column write comes AFTER the size check"
      assert Nebu.Matrix.Room.Server.get_state(room).power_levels == memory_before
      assert type_count(room, "m.room.power_levels") == events_before

      # positive control: a normal change is applied
      small = Map.put(memory_before, "invite", 25)
      assert :ok = Nebu.Matrix.Room.Server.set_power_levels(room, a.uid, small)
      assert Nebu.Matrix.Room.Server.get_state(room).power_levels["invite"] == 25
      assert type_count(room, "m.room.power_levels") == events_before + 1
    end
  end

  describe "AC5 (c) - EventDispatcher.Server.set_power_levels/2 (test review MINOR-6)" do
    # no HTTP route calls it, but it is the core entry of Room.Server.set_power_levels/3 (the Admin / a future route): the backstop's error is mapped to the
    # same fixed 413 text as every other write site instead of the generic 500 with inspect(reason) (D2 (e), D5)
    test "oversized levels raise the :too_large error with the fixed text, nothing changes; normal levels are accepted", %{a: a} do
      room = make_room(a)
      before_levels = Nebu.Matrix.Room.Server.get_state(room).power_levels
      events = type_count(room, "m.room.power_levels")

      req = %Core.SetPowerLevelsRequest{room_id: room, power_levels_json: Jason.encode!(Map.put(before_levels, "x.pad", pad()))}
      assert_too_large(fn -> Server.set_power_levels(req, stream(a)) end, @t_event)
      assert Nebu.Matrix.Room.Server.get_state(room).power_levels == before_levels
      assert type_count(room, "m.room.power_levels") == events

      ok = Server.set_power_levels(%{req | power_levels_json: Jason.encode!(Map.put(before_levels, "invite", 20))}, stream(a))
      assert %Core.SetPowerLevelsResponse{} = ok
    end
  end

  # ═══ AC5 (d): the Admin paths and the createRoom core ════════════════════════════════════════

  describe "AC5 (d) - Admin paths" do
    test "Nebu.Matrix.set_space_state/5 with an oversized content -> {:error, fixed text}, no event, no space-edit audit row; a small child is {:ok, id} with its audit row", %{a: a} do
      assert {:ok, space} = Nebu.Matrix.create_space(a.uid, "Backstop space")
      flush_audit()
      events = event_count(space)

      assert {:error, @t_event} = Nebu.Matrix.set_space_state(space, a.uid, "m.space.child", "!child:" <> server(), %{"via" => [server()], "pad" => pad()})
      assert event_count(space) == events
      refute_received {:audit_log, _, "space_child_added", _, _, _, _, _}

      assert {:ok, _id} = Nebu.Matrix.set_space_state(space, a.uid, "m.space.child", "!child:" <> server(), %{"via" => [server()]})
      assert_received {:audit_log, _, "space_child_added", _, ^space, _, _, _}
    end

    test "createRoom at the core (the Admin wrappers create_room/2 and create_space/2 cannot carry a client initial_state): an oversized entry raises :too_large and no room exists afterwards", %{a: a} do
      created = fn -> T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [a.uid]).rows |> hd() |> hd() end
      rooms_before = created.()
      marker = "MARK" <> T.rand(6)
      entry = %{"type" => "m.space.child", "state_key" => "!x:" <> server(), "content" => %{"via" => [server()], "m" => marker, "pad" => pad()}}

      req = %Core.CreateRoomRequest{creator_id: a.uid, name: "", is_direct: false, room_type: "", creation_content_json: "", initial_state_json: Jason.encode!([entry])}
      assert_too_large(fn -> Server.create_room(req, stream(a)) end, @t_is_event, marker)
      assert created.() == rooms_before, "no room"

      # and the Admin wrapper keeps working for a normal room (positive control)
      assert {:ok, _room} = Nebu.Matrix.create_room(a.uid, name: "Fine")
    end
  end

  describe "code review cycle 1 (Kassandra #3) - a legacy user id above 255 bytes can still be REMOVED by an Admin, not added" do
    test "removal reaches a stored id of 300 bytes (valid_shape?/1); adding such an id stays refused (valid?/1)", %{a: a} do
      room = make_room(a)
      legacy = "@legacy" <> T.rand(6) <> String.duplicate("l", 300) <> ":" <> server()
      assert byte_size(legacy) > 255

      # an account of before the ids were bounded: the users row and the membership exist
      T.sql!("INSERT INTO users (user_id, created_at) VALUES ($1, 0)", [legacy])
      assert :ok = Nebu.Matrix.Room.Server.join(room, legacy)
      assert T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL", [room, legacy]).rows == [[1]]

      assert {:error, :invalid_user_id} = Nebu.Matrix.admin_add_room_member(room, legacy <> "x", a.uid)

      assert :ok = Nebu.Matrix.admin_remove_room_member(room, legacy, a.uid)
      assert T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL", [room, legacy]).rows == [[0]]

      # a malformed id is still refused for removal too (positive control)
      assert {:error, :invalid_user_id} = Nebu.Matrix.admin_remove_room_member(room, "not a user id", a.uid)
    end
  end

  # ═══ AC5 (e): upgrade_room skips legacy oversized state ═════════════════════════════════════════

  defp legacy_event!(room, sender, type, key, content), do: Nebu.Test.EventSizeSupport.legacy_event!(room, sender, type, key, content)

  # upgrades over HTTP, returns {new_room, log}
  defp upgrade!(user, room) do
    log =
      capture_log(fn ->
        conn = T.matrix_request(:post, "/_matrix/client/v3/rooms/#{enc(room)}/upgrade", user.at, body: %{"new_version" => "10"})
        send(self(), {:upgraded, conn})
      end)

    assert_received {:upgraded, conn}
    assert conn.status == 200, "upgrade: #{conn.status} #{conn.resp_body}"
    {T.json(conn)["replacement_room"], log}
  end

  # the [warning] entries of the capture window that are about legacy state (skipped | reduced): the D8 (a) contract. Unrelated warnings of the global
  # capture window (the OIDC claim notices, other processes) are not counted (test review MINOR-12).
  defp warnings(log), do: log |> String.split("[warning]") |> tl() |> Enum.count(&Regex.match?(~r/skipped|reduced/i, &1))


  # the word DIRECTLY next to its number ("skipped 2" / "skipped: 2" / "2 skipped"), no comma or other word in between: "1 skipped, 2 reduced" is not
  # "skipped 2" (test review MINOR-13)
  defp count_near?(log, word, n), do: Regex.match?(~r/(\b#{word}[: ]+#{n}\b|\b#{n}[ ]+#{word}\b)/i, log)

  describe "AC5 (e) - a legacy oversized state event is skipped by upgrade_room" do
    test "the legacy oversized topic is not copied, the normal name is; exactly ONE warning, with the number 1, naming neither the type nor a content marker", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat", "name" => "Name to keep"})
      marker = "LEGACYMARK" <> T.rand(6)
      legacy_event!(room, a.uid, "m.room.topic", "", %{"topic" => marker <> pad()})

      {new_room, log} = upgrade!(a, room)

      assert type_count(new_room, "m.room.topic") == 0, "the oversized topic is not copied"
      assert current_content(new_room, "m.room.name") == %{"name" => "Name to keep"}, "the normal name is"
      assert warnings(log) == 1, "exactly one warning: #{log}"
      assert count_near?(log, "skipped", 1), "the warning carries the count: #{log}"
      refute log =~ marker, "no content in the log"
      refute log =~ "m.room.topic", "no type in the log"
      refute log =~ "topic"
    end

    test "a normal topic IS copied (positive control), and no warning is logged for an upgrade without legacy rows", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat", "name" => "Plain"})
      legacy_event!(room, a.uid, "m.room.topic", "", %{"topic" => "a normal topic"})

      {new_room, log} = upgrade!(a, room)

      assert current_content(new_room, "m.room.topic") == %{"topic" => "a normal topic"}
      assert warnings(log) == 0, "no legacy row, no warning: #{log}"
    end

    test "the warning counts skipped and reduced events separately: 2 skipped (topic, avatar) and 1 reduced (join rules) in ONE warning without type or content", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat"})
      marker = "LEGACYMARK" <> T.rand(6)
      legacy_event!(room, a.uid, "m.room.topic", "", %{"topic" => marker <> pad()})
      legacy_event!(room, a.uid, "m.room.avatar", "", %{"url" => "mxc://test.local/abc", "x.pad" => marker <> pad()})
      legacy_event!(room, a.uid, "m.room.join_rules", "", %{"join_rule" => "invite", "allow" => [pad()]})

      {new_room, log} = upgrade!(a, room)

      assert type_count(new_room, "m.room.topic") == 0 and type_count(new_room, "m.room.avatar") == 0
      assert current_content(new_room, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert warnings(log) == 1, "exactly one warning: #{log}"
      assert count_near?(log, "skipped", 2), "2 skipped: #{log}"
      assert count_near?(log, "reduced", 1), "1 reduced: #{log}"
      refute log =~ marker
      refute log =~ "m.room."
      refute log =~ "join_rule"
    end
  end

  # ═══ AC5 (e2): never a more open new room ═════════════════════════════════════════════════════

  describe "AC5 (e2) - the access types are copied REDUCED, never more open" do
    # owner a, old member m (invited to the new room by the upgrade), outsider x (not invited)
    defp old_room_with_member!(a, m) do
      room = make_room(a, %{"preset" => "private_chat"})
      assert T.matrix_request(:post, "/_matrix/client/v3/rooms/#{enc(room)}/invite", a.at, body: %{"user_id" => m.uid}).status == 200
      assert T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", m.at).status == 200
      room
    end

    defp join(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", user.at)

    test "an oversized join rule invite with a 70 KB allow list -> {join_rule: invite} and a non-invited user's POST /join is 403", %{a: a, m: m, x: x} do
      room = old_room_with_member!(a, m)
      legacy_event!(room, a.uid, "m.room.join_rules", "", %{"join_rule" => "invite", "allow" => [pad()]})

      {new_room, _log} = upgrade!(a, room)
      assert current_content(new_room, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert join(x, new_room).status == 403
      assert join(m, new_room).status == 200, "positive control: the invited old member joins"
    end

    test "an oversized restricted join rule whose allow room the joiner is in -> restricted WITHOUT allow: the joiner is refused (403), an invited user can join", %{a: a, m: m, x: x} do
      allow_room = make_room(x, %{"preset" => "private_chat"})
      room = old_room_with_member!(a, m)

      legacy_event!(room, a.uid, "m.room.join_rules", "", %{
        "join_rule" => "restricted",
        "allow" => [%{"type" => "m.room_membership", "room_id" => allow_room}],
        "x.pad" => pad()
      })

      {new_room, _log} = upgrade!(a, room)
      assert current_content(new_room, "m.room.join_rules") == %{"join_rule" => "restricted"}
      assert join(x, new_room).status == 403, "x is a member of the allow room, but allow is dropped: invitations only"
      assert join(m, new_room).status == 200, "an invited user can join a restricted room"
    end

    test "an oversized MALFORMED join rule (join_rule 42 plus padding) -> {join_rule: private}; even an invited user is refused", %{a: a, m: m, x: x} do
      room = old_room_with_member!(a, m)
      legacy_event!(room, a.uid, "m.room.join_rules", "", %{"join_rule" => 42, "x.pad" => pad()})

      {new_room, _log} = upgrade!(a, room)
      assert current_content(new_room, "m.room.join_rules") == %{"join_rule" => "private"}
      assert join(m, new_room).status == 403, "private refuses every join, invited ones too"
      assert join(x, new_room).status == 403
    end

    test "an oversized unknown join rule string stays unknown (reduced to the key, refuses every join as before)", %{a: a, m: m} do
      room = old_room_with_member!(a, m)
      legacy_event!(room, a.uid, "m.room.join_rules", "", %{"join_rule" => "org.example.weird", "x.pad" => pad()})

      {new_room, _log} = upgrade!(a, room)
      assert current_content(new_room, "m.room.join_rules") == %{"join_rule" => "org.example.weird"}
      assert join(m, new_room).status == 403
    end

    test "oversized history_visibility joined -> {history_visibility: joined}; an oversized NON-string value -> joined (the most restrictive spec value)", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat"})
      legacy_event!(room, a.uid, "m.room.history_visibility", "", %{"history_visibility" => "joined", "x.pad" => pad()})
      {new_room, _} = upgrade!(a, room)
      assert current_content(new_room, "m.room.history_visibility") == %{"history_visibility" => "joined"}

      other = make_room(a, %{"preset" => "private_chat"})
      legacy_event!(other, a.uid, "m.room.history_visibility", "", %{"history_visibility" => 42, "x.pad" => pad()})
      {new_other, _} = upgrade!(a, other)
      assert current_content(new_other, "m.room.history_visibility") == %{"history_visibility" => "joined"}
    end

    test "an oversized guest_access \"can_join\" -> {guest_access: can_join}; an oversized NON-string value -> \"forbidden\"", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat"})
      legacy_event!(room, a.uid, "m.room.guest_access", "", %{"guest_access" => "can_join", "x.pad" => pad()})
      {new_room, _} = upgrade!(a, room)
      assert current_content(new_room, "m.room.guest_access") == %{"guest_access" => "can_join"}

      other = make_room(a, %{"preset" => "private_chat"})
      legacy_event!(other, a.uid, "m.room.guest_access", "", %{"guest_access" => ["can_join"], "x.pad" => pad()})
      {new_other, _} = upgrade!(a, other)
      assert current_content(new_other, "m.room.guest_access") == %{"guest_access" => "forbidden"}
    end

    test "a string value above 255 bytes is not kept either: an oversized join rule with a 300-byte join_rule -> private", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat"})
      legacy_event!(room, a.uid, "m.room.join_rules", "", %{"join_rule" => String.duplicate("j", 300), "x.pad" => pad()})

      {new_room, _} = upgrade!(a, room)
      assert current_content(new_room, "m.room.join_rules") == %{"join_rule" => "private"}
    end

    test "a NORMAL public join rule is copied unchanged (positive control): the content is identical and an outsider can join", %{a: a, x: x} do
      room = make_room(a, %{"preset" => "private_chat"})
      legacy_event!(room, a.uid, "m.room.join_rules", "", %{"join_rule" => "public"})

      {new_room, log} = upgrade!(a, room)
      assert current_content(new_room, "m.room.join_rules") == %{"join_rule" => "public"}
      assert join(x, new_room).status == 200
      assert warnings(log) == 0
    end
  end
end
