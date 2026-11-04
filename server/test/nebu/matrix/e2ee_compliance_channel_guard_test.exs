defmodule Nebu.Matrix.E2eeComplianceChannelGuardTest do
  @moduledoc """
  ATDD for story `e2ee-compliance-channel-guard` (REQ-2026-015) — E2EE compliance channel guard: no encrypted room events, to-device allowlist, documented residual.

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`; the tests tagged `oracle-...` pin MUSTs of the oracle context and decisions that no scenario covers.
  Red until the story is implemented.

  Everything runs through the full `Nebu.Web.Router` (real database, real rooms, real sessions) with the helpers of the sibling suites (`ToDeviceTestSupport`,
  `ModerationTestSupport`, `RedactionTestSupport`); the dispatcher-level test calls `EventDispatcher.Server.send_event/2` directly (defence in depth, D1).
  The database tests are tagged `:integration` like the siblings, the docs test needs neither a database nor a network.

  Decisions pinned (story `## Decisions`):

    * D1: `m.room.encrypted` is `403 M_FORBIDDEN` (the fixed text of the `m.room.encryption` rejection) on the room send route, the state PUT and (skipped, like
      `m.room.encryption`) in `initial_state`, and is refused by the dispatcher; the answer does not depend on the room; nothing is stored.
    * D2: the to-device allowlist (13 types), everything else `400 M_INVALID_PARAM` BEFORE the rate limit, the body, the recipient and the budgets.
    * D4: `keys/device_signing/upload` joins the key-material shape (`RawBodyReader.key_material_shape?/1`): its body is never logged.
    * D3 / D5: the documents.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.MembershipStateTestSupport, as: MS
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.RedactionTestSupport, as: R
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @root Path.expand("../../../..", __DIR__)
  @lib Path.join(@root, "server/lib")
  @adr Path.join(@root, "docs/architecture/adr/ADR-011-managed-e2ee-key-escrow.md")
  @risks Path.join(@root, "docs/architecture/11-risks.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @http_to_device Path.join(@lib, "nebu/matrix/http_to_device.ex")
  @story "e2ee-compliance-channel-guard"

  @refusal %{"errcode" => "M_FORBIDDEN", "error" => "End-to-end encryption is not supported on this server"}
  @bucket_table :nebu_http_rate_limit_buckets

  @verification ~w(m.key.verification.request m.key.verification.ready m.key.verification.start m.key.verification.accept m.key.verification.key
                   m.key.verification.mac m.key.verification.done m.key.verification.cancel)
  @allowlist @verification ++ ~w(m.room.encrypted m.room_key_request m.room_key.withheld m.secret.request m.dummy)
  @in_room_verification ~w(m.key.verification.ready m.key.verification.start m.key.verification.accept m.key.verification.key m.key.verification.mac
                           m.key.verification.done m.key.verification.cancel)
  @refused ~w(com.example.chat m.room_key m.forwarded_room_key m.secret.send org.matrix.room_key.withheld)

  # D2 is an EXACT match: near misses of the allowlist (prefix / suffix / family / case) and the documented Element Call / MSC types are refused like any other type
  @near_misses ~w(m.key.verification.foo m.key.verification m.room.encrypted.x m.dummy2 m.room_key_request.x M.DUMMY M.ROOM.ENCRYPTED M.KEY.VERIFICATION.REQUEST
                  io.element.call.encryption_keys m.call.invite org.matrix.msc3814.dehydrated_device)

  # already percent-encoded path segments: com.example.%63hat is com.example.chat, m.room_k%65y is m.room_key, m.dum%256dy is the literal type `m.dum%6dy` (the path is decoded ONCE)
  @refused_encoded ~w(com.example.%63hat m.room_k%65y m.dum%256dy)
  @refused_all @refused ++ @near_misses ++ @refused_encoded

  setup context do
    if context[:integration] do
      T.reset_rate_limits()
      Nebu.Test.ServerName.pin!(T.server_name())
      TD.disable_rate_limit()
      on_exit(fn -> T.restore_rate_limits() end)
    end

    :ok
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp pair!, do: {TD.user!("CGA"), TD.user!("CGB")}

  defp ghost_room, do: "!ghost#{T.rand(6)}:#{T.server_name()}"

  defp send_room(user, room, type, txn, content), do: T.matrix_request(:put, S.path(room, "send/#{type}/#{txn}"), user.at, body: content)

  defp typed_count(room, type), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2", [room, type]).rows |> hd() |> hd()

  defp row_count(event_id), do: T.sql!("SELECT count(*) FROM events WHERE event_id = $1", [event_id]).rows |> hd() |> hd()

  defp ciphertext(canary) do
    %{"algorithm" => "m.megolm.v1.aes-sha2", "ciphertext" => "ct-#{canary}", "device_id" => "DEV", "sender_key" => "sk-#{canary}", "session_id" => "sid-#{canary}"}
  end

  # PUT /sendToDevice/{type}/{txn}: a type that contains `%` is an ALREADY percent-encoded path segment (sent verbatim, TD.seg would encode the `%` again)
  defp put_type(sender, type, txn_id, body) do
    segment = if String.contains?(type, "%"), do: type, else: TD.seg(type)

    payload =
      case body do
        {:raw, _} -> body
        {:body, term} -> term
        messages when is_map(messages) -> %{"messages" => messages}
      end

    TD.req(:put, "#{TD.prefix()}/#{segment}/#{TD.seg(txn_id)}", sender.at, payload)
  end

  defp assert_refusal(conn, label) do
    assert conn.status == 403, "#{label}: expected 403, got #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    assert T.json(conn) == @refusal, "#{label}: #{conn.resp_body}"
    assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}
    conn
  end

  # the limiter rows of one user in the ETS table of the rate limiter (any tier)
  defp bucket_rows(uid) do
    if :ets.whereis(@bucket_table) == :undefined, do: [], else: :ets.match_object(@bucket_table, {{:_, uid}, :_, :_})
  end

  defp logged(fun), do: TD.with_log_level(:debug, fn -> capture_log([level: :debug], fun) end)

  defp content_for("m.key.verification.start"), do: %{"method" => "m.reciprocate.v1", "from_device" => "ALICEDEV", "transaction_id" => "qr-1", "secret" => "c2VjcmV0"}
  defp content_for("m.key.verification.done"), do: %{"transaction_id" => "qr-1"}
  defp content_for("m.room.encrypted"), do: %{"algorithm" => "m.olm.v1.curve25519-aes-sha2", "sender_key" => "SK", "ciphertext" => %{"RECIPIENTKEY" => %{"type" => 0, "body" => "AwogE+/=="}}}
  defp content_for(type), do: %{"transaction_id" => "tx-1", "type_marker" => type}

  # a dispatcher call (the in-process command layer behind the route): {:ok, response} | {:error, %Nebu.Matrix.Error{}}
  defp dispatch(room, sender, type, state?) do
    req = %Core.SendEventRequest{
      room_id: room,
      sender_id: sender.uid,
      event_type: type,
      txn_id: "dtx-" <> T.rand(4),
      content: Jason.encode!(%{"ciphertext" => "dispatcher-#{T.rand(4)}"}),
      is_state_event: state?,
      state_key: "",
      origin_ts: System.system_time(:millisecond)
    }

    try do
      {:ok, Server.send_event(req, Nebu.Matrix.Http.stream(sender.uid))}
    rescue
      e in Nebu.Matrix.Error -> {:error, e}
    end
  end

  # ═══ Scenario 1: an encrypted room event is refused ════════════════════════════════════════════════════════════════════════

  # Scenario: An encrypted room event is refused
  #   Given I am a member of a room
  #   When I PUT /rooms/{roomId}/send/m.room.encrypted/{txnId} with an opaque ciphertext content
  #   Then the answer is 403 M_FORBIDDEN, no event is stored and the same answer comes for an unknown room
  @tag :integration
  @tag ac: "an-encrypted-room-event-is-refused"
  test "Scenario: An encrypted room event is refused" do
    {alice, bob} = pair!()
    stranger = TD.user!("CGC")
    room = S.invite_room(alice, [bob])
    foreign_room = S.make_room(stranger, %{"preset" => "private_chat"})
    canary = "CANARY-" <> T.rand(6)
    txn = "enc-" <> T.rand(4)
    before = S.event_count(room)

    member = send_room(alice, room, "m.room.encrypted", txn, ciphertext(canary))
    assert_refusal(member, "member room")
    refute member.resp_body =~ canary, "the content is not echoed"
    refute member.resp_body =~ room, "no room id is echoed"
    refute member.resp_body =~ "$", "no event id is echoed"

    assert S.event_count(room) == before, "nothing was stored"
    assert typed_count(room, "m.room.encrypted") == 0

    unknown = send_room(alice, ghost_room(), "m.room.encrypted", txn, ciphertext(canary))
    assert_refusal(unknown, "unknown room")
    assert unknown.resp_body == member.resp_body, "a member room and an unknown room give the byte-identical answer"
    assert TD.shape(unknown) == TD.shape(member)

    not_member = send_room(alice, foreign_room, "m.room.encrypted", txn, ciphertext(canary))
    assert_refusal(not_member, "a room I am not a member of")
    assert not_member.resp_body == member.resp_body, "no membership oracle"

    # a relation (edit / annotation) is not a way around the type check
    related = send_room(alice, room, "m.room.encrypted", "rel-" <> T.rand(4), Map.put(ciphertext(canary), "m.relates_to", %{"rel_type" => "m.annotation", "event_id" => "$x", "key" => "k"}))
    assert_refusal(related, "with m.relates_to")

    # a percent-encoded spelling of the type is the same type
    encoded = send_room(alice, room, "m.room.%65ncrypted", "pct-" <> T.rand(4), ciphertext(canary))
    assert_refusal(encoded, "percent-encoded type")

    assert S.event_count(room) == before, "still nothing stored"

    # the refusal happened before the txn-dedup entry: the same txn id is free for a different event, which is stored as a new event
    ok = send_room(alice, room, "m.room.message", txn, %{"msgtype" => "m.text", "body" => "after the refusal"})
    assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
    assert S.event_count(room) == before + 1

    # not delivered to anyone: the timeline of the other member has no m.room.encrypted
    types = bob |> S.messages(room) |> Enum.map(& &1["type"])
    refute "m.room.encrypted" in types
    assert "m.room.message" in types
  end

  # Scenario: Other room events still work, including in-room verification and redaction
  #   Given I am a member of a room
  #   When I send an m.room.message event, an m.room.redaction and the in-room verification events m.key.verification.ready, .start, .accept, .key, .mac, .done and .cancel
  #   Then each is stored and delivered as before (only m.room.encrypted is refused)
  @tag :integration
  @tag ac: "other-room-events-still-work-including-in-room-verification-and"
  test "Scenario: Other room events still work, including in-room verification and redaction" do
    {alice, bob} = pair!()
    room = S.invite_room(alice, [bob])

    msg = send_room(alice, room, "m.room.message", "m-" <> T.rand(4), %{"msgtype" => "m.text", "body" => "hello"})
    assert msg.status == 200, "m.room.message: #{msg.status} #{msg.resp_body}"
    message_id = T.json(msg)["event_id"]
    assert row_count(message_id) == 1

    request = send_room(alice, room, "m.room.message", "vr-" <> T.rand(4), %{"msgtype" => "m.key.verification.request", "body" => "verify", "to" => bob.uid, "from_device" => alice.dev, "methods" => ["m.sas.v1"]})
    assert request.status == 200, "in-room verification request: #{request.status} #{request.resp_body}"

    ids =
      for type <- @in_room_verification do
        content = %{"m.relates_to" => %{"rel_type" => "m.reference", "event_id" => T.json(request)["event_id"]}, "method" => "m.sas.v1", "from_device" => bob.dev}
        c = send_room(bob, room, type, "v-" <> T.rand(4), content)
        assert c.status == 200, "#{type}: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
        id = T.json(c)["event_id"]
        assert is_binary(id) and String.starts_with?(id, "$"), "#{type}: an event id comes back"
        assert row_count(id) == 1, "#{type} is stored"
        {type, id}
      end

    custom = send_room(alice, room, "com.example.note", "c-" <> T.rand(4), %{"note" => "custom types are not touched by the guard"})
    assert custom.status == 200, "a custom room event type: #{custom.status} #{custom.resp_body}"

    # only the EXACT m.room.encrypted is guarded (no prefix match): the near misses are other event types, stored like any custom type
    # (a differently cased M.ROOM.ENCRYPTED is deliberately not pinned here: it is a different type no client decrypts)
    for type <- ~w(m.room.encrypted.x m.room.encrypted_x) do
      near = send_room(alice, room, type, "n-" <> T.rand(4), %{"note" => "near miss of the guarded type"})
      assert near.status == 200, "#{type}: only the exact m.room.encrypted is refused, got #{near.status} #{near.resp_body}"
      assert row_count(T.json(near)["event_id"]) == 1, "#{type} is stored"
      assert typed_count(room, type) == 1
    end

    redaction = R.send_redaction(alice, room, %{"redacts" => message_id}, "r-" <> T.rand(4))
    assert redaction.status == 200, "m.room.redaction: #{redaction.status} #{redaction.resp_body}"
    redaction_id = T.json(redaction)["event_id"]
    assert row_count(redaction_id) == 1, "the redaction is stored"

    # delivered as before: the other member's timeline has all the verification events
    timeline = S.messages(bob, room)
    delivered = Enum.map(timeline, & &1["event_id"])

    for {type, id} <- ids do
      assert id in delivered, "#{type} is not delivered to the other member"
      assert Enum.find(timeline, &(&1["event_id"] == id))["type"] == type
    end

    assert typed_count(room, "m.room.encrypted") == 0
  end

  # Scenario: No other write path takes an encrypted room event
  #   Given a room creation with initial_state of type m.room.encrypted and a state PUT of that type
  #   When the requests are sent
  #   Then they are refused or the event is skipped and nothing of that type is stored
  @tag :integration
  @tag ac: "no-other-write-path-takes-an-encrypted-room-event"
  test "Scenario: No other write path takes an encrypted room event" do
    {alice, bob} = pair!()
    room = S.invite_room(alice, [bob])

    # createRoom initial_state: the entry is skipped like m.room.encryption (the room is created, the other entries apply)
    created =
      S.create(alice, %{
        "name" => "guard #{T.rand(3)}",
        "initial_state" => [
          %{"type" => "m.room.encrypted", "state_key" => "", "content" => ciphertext("init")},
          %{"type" => "m.room.encrypted", "state_key" => "some-key", "content" => ciphertext("init2")},
          %{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "kept"}}
        ]
      })

    assert created.status == 200, "createRoom: #{created.status} #{created.resp_body}"
    new_room = T.json(created)["room_id"]
    assert typed_count(new_room, "m.room.encrypted") == 0, "initial_state must not persist m.room.encrypted"
    assert typed_count(new_room, "m.room.topic") == 1, "the plain entry still applies"

    # PUT state: refused with the fixed text, for a state key or none, for a member room and for an unknown room alike
    before = S.event_count(room)
    plain = S.put_state(alice, room, "m.room.encrypted", ciphertext("state"))
    assert_refusal(plain, "state PUT, no state key")
    assert_refusal(T.matrix_request(:put, S.path(room, "state/m.room.encrypted/"), alice.at, body: ciphertext("state")), "state PUT, empty state key")
    assert_refusal(T.matrix_request(:put, S.path(room, "state/m.room.encrypted/some-key"), alice.at, body: ciphertext("state")), "state PUT, a state key")
    unknown = S.put_state(alice, ghost_room(), "m.room.encrypted", ciphertext("state"))
    assert_refusal(unknown, "state PUT, unknown room")
    assert unknown.resp_body == plain.resp_body, "the answer does not depend on the room"

    # a percent-encoded spelling (also double-encoded) is the same type or at least never stored as m.room.encrypted
    assert_refusal(T.matrix_request(:put, S.path(room, "state/m.room.%65ncrypted"), alice.at, body: ciphertext("state")), "state PUT, percent-encoded type")
    T.matrix_request(:put, S.path(room, "state/m.room.%2565ncrypted"), alice.at, body: ciphertext("state"))

    assert typed_count(room, "m.room.encrypted") == 0, "nothing of the type is stored by the state paths"

    # the dispatcher (defence in depth): no caller of it can store one, whether message or state event, whatever the room
    member_msg = dispatch(room, alice, "m.room.encrypted", false)
    member_state = dispatch(room, alice, "m.room.encrypted", true)
    ghost_msg = dispatch(ghost_room(), alice, "m.room.encrypted", false)

    for {label, result} <- [{"member room message", member_msg}, {"member room state event", member_state}, {"unknown room", ghost_msg}] do
      assert {:error, %Nebu.Matrix.Error{} = err} = result, "#{label}: the dispatcher refuses (got #{inspect(result)})"
      assert err.status == Nebu.Matrix.Status.permission_denied(), "#{label}: permission denied, not #{inspect(err.status)}"
      refute err.message =~ room, "#{label}: no room id echoed"
    end

    assert elem(member_msg, 1).message == elem(ghost_msg, 1).message, "the dispatcher's refusal does not depend on the room"
    assert typed_count(room, "m.room.encrypted") == 0
    assert S.event_count(room) == before, "the dispatcher stored nothing"
  end

  # Scenario: No other write path takes an encrypted room event (the room upgrade copy, review LOW 1)
  #   Given a room that holds a LEGACY m.room.encrypted state event (stored by an initial_state of before this story, seeded below the API)
  #   When the room is upgraded
  #   Then the upgrade is 200, the other state (name, topic) is copied and the new room holds no m.room.encrypted event
  @tag :integration
  @tag ac: "no-other-write-path-takes-an-encrypted-room-event"
  test "Scenario: No other write path takes an encrypted room event: the room upgrade does not copy a legacy m.room.encrypted state event" do
    alice = TD.user!("CGU")
    room = S.make_room(alice, %{"preset" => "private_chat", "name" => "old room"})
    topic = S.put_state(alice, room, "m.room.topic", %{"topic" => "kept topic"})
    assert topic.status == 200, "#{topic.status} #{topic.resp_body}"

    # the legacy rows go in below the API (the guard refuses every API path now): the empty state key and a named one
    Nebu.Test.EventSizeSupport.legacy_event!(room, alice.uid, "m.room.encrypted", "", ciphertext("legacy"))
    Nebu.Test.EventSizeSupport.legacy_event!(room, alice.uid, "m.room.encrypted", "some-key", ciphertext("legacy2"))
    assert typed_count(room, "m.room.encrypted") == 2, "precondition: the legacy state rows exist in the old room"

    conn = T.matrix_request(:post, S.path(room, "upgrade"), alice.at, body: %{"new_version" => "10"})
    assert conn.status == 200, "upgrade: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    new_room = T.json(conn)["replacement_room"]
    assert is_binary(new_room) and new_room != room

    assert typed_count(new_room, "m.room.encrypted") == 0, "the upgrade copy must not re-store a legacy m.room.encrypted state event"
    assert typed_count(new_room, "m.room.topic") == 1, "the other state is still copied (topic)"
    assert typed_count(new_room, "m.room.name") == 1, "the other state is still copied (name)"
    assert typed_count(room, "m.room.encrypted") == 2, "the old room keeps its rows (nothing is deleted)"
  end

  # ═══ to-device ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

  # Scenario: Allowlisted to-device types are delivered
  #   Given I share a joined room with another user
  #   When I send every allowlisted type (the eight m.key.verification.* types incl. the QR flow m.key.verification.start with method m.reciprocate.v1 and m.key.verification.done, m.room.encrypted, m.room_key_request, m.room_key.withheld, m.secret.request, m.dummy) to its device
  #   Then each is accepted with 200 and delivered in the recipient's next sync
  @tag :integration
  @tag ac: "allowlisted-to-device-types-are-delivered"
  test "Scenario: Allowlisted to-device types are delivered" do
    {alice, bob} = pair!()
    TD.share!(alice, bob)
    assert length(@allowlist) == 13

    sent =
      for type <- @allowlist do
        content = content_for(type)
        c = TD.put_send(alice, type, TD.txn(), TD.msg(bob, content))
        assert c.status == 200, "#{type}: expected 200, got #{c.status} #{String.slice(c.resp_body, 0, 200)}"
        assert c.resp_body == "{}", "#{type}: the answer is exactly {}"
        {type, content}
      end

    # the QR flow starts with m.key.verification.start (method m.reciprocate.v1) and ends with .done: both are in the list above; the SAS start too
    sas_start = %{"method" => "m.sas.v1", "from_device" => "ALICEDEV", "transaction_id" => "sas-1"}
    TD.send!(alice, "m.key.verification.start", TD.txn(), TD.msg(bob, sas_start))

    expected = Enum.map(sent, fn {type, content} -> TD.ev(alice, type, content) end) ++ [TD.ev(alice, "m.key.verification.start", sas_start)]
    assert TD.events(TD.sync(bob)) == expected, "every allowlisted type is delivered unchanged, in order, in the next sync"

    assert Enum.any?(expected, &(&1["type"] == "m.key.verification.start" and &1["content"]["method"] == "m.reciprocate.v1")), "the QR start is part of what was delivered"
  end

  # Scenario: A to-device type outside the allowlist is refused before anything is consumed
  #   Given I share a joined room with another user
  #   When I send a to-device message with the made-up type com.example.chat, and with the inner-only types m.room_key, m.forwarded_room_key, m.secret.send and the unstable alias org.matrix.room_key.withheld
  #   Then each answer is 400 M_INVALID_PARAM, no row is stored, no rate or byte budget is consumed
  @tag :integration
  @tag ac: "a-to-device-type-outside-the-allowlist-is-refused-before-anything-is"
  test "Scenario: A to-device type outside the allowlist is refused before anything is consumed" do
    {alice, bob} = pair!()
    TD.share!(alice, bob)
    TD.enable_rate_limit()
    content = fn n -> %{"n" => n, "pad" => "p"} end
    TD.seam(:rate_bytes_burst, 3 * TD.cost(content.(1)))
    TD.seam(:rate_bytes_per_min, 6 * TD.cost(content.(1)))

    assert bucket_rows(alice.uid) == [], "precondition: no limiter bucket of the sender"

    # the refused types (the made-up and inner-only ones, the near misses of the allowlist, the percent-encoded spellings) twice: more than the burst of 30 of the rate limit,
    # none is 429, so none consumed a token
    requests = Enum.flat_map(1..2, fn _ -> @refused_all end)
    assert length(requests) > 30

    bodies =
      for type <- requests do
        c = put_type(alice, type, TD.txn(), TD.msg(bob, content.(1)))
        TD.assert_error(c, 400, "M_INVALID_PARAM")
        refute c.resp_body =~ type, "#{type}: the type is not echoed in the answer"
        c.resp_body
      end

    assert bodies |> Enum.uniq() |> length() == 1, "one fixed text for every refused type"

    # before the body, the recipients and the budgets: a malformed or an oversize body is still the type error, and the body is never read
    for {label, body} <- [{"not JSON", {:raw, "{nope"}}, {"oversize", {:raw, ~s({"messages":{},"pad":"#{String.duplicate("a", 70_000)}"})}}, {"wrong shape", {:body, %{"messages" => 5}}}] do
      c = put_type(alice, "m.room_key", TD.txn(), body)
      TD.assert_error(c, 400, "M_INVALID_PARAM")
      assert match?(%Plug.Conn.Unfetched{}, c.body_params), "#{label}: the body was never read"
    end

    assert TD.queue_count(bob.uid) == 0, "no row is stored"
    assert TD.txn_count(alice.uid) == 0, "no transaction record"
    assert TD.sent_count(alice.uid) == 0
    assert bucket_rows(alice.uid) == [], "no ETS bucket was created for the sender (the type check is before the limiter)"

    # the byte budget is untouched too: the burst of exactly three rows is still there
    for n <- 1..3, do: TD.send!(alice, "m.dummy", TD.txn(), TD.msg(bob, content.(n)))
    TD.assert_429(TD.put_send(alice, "m.dummy", TD.txn(), TD.msg(bob, content.(4))), "the fourth allowed row exhausts the byte burst")
    assert TD.queue_count(bob.uid) == 3
  end

  # Scenario: The refusal does not reveal anything about the recipient
  #   Given a non-allowlisted type
  #   When I send it to an existing peer, to a stranger and to an unknown user
  #   Then the three answers are byte-identical
  @tag :integration
  @tag ac: "the-refusal-does-not-reveal-anything-about-the-recipient"
  test "Scenario: The refusal does not reveal anything about the recipient" do
    {alice, bob} = pair!()
    TD.share!(alice, bob)
    stranger = TD.user!("CGS")
    unknown = {"@nobody-#{T.rand(5)}:#{T.server_name()}", "NOPE"}
    content = %{"secret" => "c-#{T.rand(4)}"}

    shapes =
      for type <- @refused_all do
        targets = [TD.msg(bob, content), TD.msg({bob.uid, "NO-SUCH-DEVICE"}, content), TD.star(bob, content), TD.msg(stranger, content), TD.msg(unknown, content)]
        answers = for m <- targets, do: put_type(alice, type, TD.txn(), m)

        for c <- answers, do: TD.assert_error(c, 400, "M_INVALID_PARAM")
        [peer | rest] = Enum.map(answers, &TD.shape/1)
        assert Enum.all?(rest, &(&1 == peer)), "#{type}: peer, unknown device, `*`, stranger and unknown user are answered byte-identically"
        peer
      end

    assert shapes |> Enum.uniq() |> length() == 1, "and the answer is the same for every refused type"
    assert TD.queue_count(bob.uid) == 0
    assert TD.queue_count(stranger.uid) == 0
  end

  # ═══ oracle: exact match, percent-encoding, guard order ══════════════════════════════════════════════════════════════════════

  @tag :integration
  @tag ac: "oracle-to-device-allowlist-exact-match"
  test "oracle D2: every allowlisted type has near misses (case, prefix, suffix, encoded space) that are refused with the one fixed 400 M_INVALID_PARAM" do
    {alice, bob} = pair!()
    TD.share!(alice, bob)

    variants =
      for type <- @allowlist, variant <- [String.upcase(type), type <> ".x", type <> "2", "x." <> type, type <> ".", type <> "%20"], do: {type, variant}

    assert length(variants) == 6 * length(@allowlist)
    assert variants |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == length(variants)

    bodies =
      for {type, variant} <- variants do
        refute variant in @allowlist
        c = put_type(alice, variant, TD.txn(), TD.msg(bob, content_for(type)))
        TD.assert_error(c, 400, "M_INVALID_PARAM")
        c.resp_body
      end

    assert bodies |> Enum.uniq() |> length() == 1, "one fixed text for every refused spelling"
    assert TD.queue_count(bob.uid) == 0, "no row is stored"
    assert TD.txn_count(alice.uid) == 0, "no transaction record"
    assert TD.sent_count(alice.uid) == 0

    # control: the exact spelling of the very same type is accepted (the refusals above are about the type only)
    ok = put_type(alice, "m.dummy", TD.txn(), TD.msg(bob, content_for("m.dummy")))
    assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
    assert TD.queue_count(bob.uid) == 1
  end

  @tag :integration
  @tag ac: "oracle-to-device-percent-encoded-allowlisted-type-accepted"
  test "oracle D2: the path is decoded before the match: m.dum%6dy and m%2Edummy are m.dummy (accepted, stored and delivered as m.dummy)" do
    {alice, bob} = pair!()
    TD.share!(alice, bob)
    first = %{"transaction_id" => "enc-1"}
    second = %{"transaction_id" => "enc-2"}

    for {type, content} <- [{"m.dum%6dy", first}, {"m%2Edummy", second}] do
      c = put_type(alice, type, TD.txn(), TD.msg(bob, content))
      assert c.status == 200, "#{type}: expected 200, got #{c.status} #{String.slice(c.resp_body, 0, 200)}"
      assert c.resp_body == "{}"
    end

    assert TD.queue_count(bob.uid) == 2
    assert TD.events(TD.sync(bob)) == [TD.ev(alice, "m.dummy", first), TD.ev(alice, "m.dummy", second)], "delivered under the decoded type"
  end

  @tag :integration
  @tag ac: "oracle-room-guard-runs-before-txn-dedup-and-db-work"
  test "oracle D1: the room guard runs before any room query and before the txn-dedup entry; a replay of the refused (type, txn) changes nothing" do
    {alice, bob} = pair!()
    room = S.invite_room(alice, [bob])
    refused_txn = "rp-" <> T.rand(4)
    refused_key = Nebu.Matrix.Room.Server.send_txn_key(room, alice.uid, "m.room.encrypted", refused_txn)
    assert :ets.whereis(:NebuTxnDedup) != :undefined, "precondition: the dedup table exists (the lookups below are not vacuous)"

    # control: an accepted send does issue room statements and does record its dedup entry (so the two checks below can fail)
    ctl_txn = "ctl-" <> T.rand(4)
    {ok, ok_statements} = MS.count_statements(fn -> send_room(alice, room, "m.room.message", ctl_txn, %{"msgtype" => "m.text", "body" => "control"}) end, [room])
    assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
    assert MS.room_statements(ok_statements) != [], "control: a stored event is written through the room tables"
    assert [{_, _event_id}] = :ets.lookup(:NebuTxnDedup, Nebu.Matrix.Room.Server.send_txn_key(room, alice.uid, "m.room.message", ctl_txn)), "control: the dedup entry is recorded"

    before = S.event_count(room)

    # the same refused (type, txn) twice, then an unknown room and the state route: no room/events/room_members statement, no dedup entry, no row
    answers =
      for {label, fun} <- [
            {"first", fn -> send_room(alice, room, "m.room.encrypted", refused_txn, ciphertext("replay")) end},
            {"replay", fn -> send_room(alice, room, "m.room.encrypted", refused_txn, ciphertext("replay")) end},
            {"unknown room", fn -> send_room(alice, ghost_room(), "m.room.encrypted", refused_txn, ciphertext("replay")) end},
            {"state PUT", fn -> S.put_state(alice, room, "m.room.encrypted", ciphertext("replay")) end}
          ] do
        {c, statements} = MS.count_statements(fun, [room])
        assert_refusal(c, label)
        assert MS.room_statements(statements) == [], "#{label}: the refusal issued room statements:\n" <> MS.listing(MS.room_statements(statements))
        assert :ets.lookup(:NebuTxnDedup, refused_key) == [], "#{label}: the refused request left a txn-dedup entry"
        c.resp_body
      end

    assert answers |> Enum.uniq() |> length() == 1, "the first answer, the replay, the unknown room and the state PUT are byte-identical"
    assert S.event_count(room) == before, "nothing was stored"
    assert typed_count(room, "m.room.encrypted") == 0
  end

  @tag :integration
  @tag ac: "oracle-to-device-guard-runs-before-db-work"
  test "oracle D2: a refused to-device type issues no statement of the to-device tables and no room statement" do
    {alice, bob} = pair!()
    TD.share!(alice, bob)
    content = %{"n" => 1}
    work = fn statements -> Enum.filter(statements, &Regex.match?(~r/to_device|\b(events|rooms|room_members)\b/, &1)) end

    # control: an accepted send does touch those tables (the filter is not vacuous)
    {_ok, ok_statements} = TD.statements(fn -> TD.send!(alice, "m.dummy", TD.txn(), TD.msg(bob, content)) end, "")
    assert work.(ok_statements) != [], "control: an accepted send issues to-device / room statements"

    for type <- ["com.example.chat", "m.room_key", "M.DUMMY", "m.dummy2", "com.example.%63hat"] do
      {c, statements} = TD.statements(fn -> put_type(alice, type, TD.txn(), TD.msg(bob, content)) end, "")
      TD.assert_error(c, 400, "M_INVALID_PARAM")
      assert work.(statements) == [], "#{type}: the refusal issued statements:\n" <> Enum.join(work.(statements), "\n")
    end

    assert TD.queue_count(bob.uid) == 1, "only the control row"
  end

  # ═══ logging ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

  # Scenario: The cross-signing upload body is not logged
  #   Given the debug capture is on
  #   When I POST /keys/device_signing/upload with key material
  #   Then no key material reaches a log line
  @tag :integration
  @tag ac: "the-cross-signing-upload-body-is-not-logged"
  test "Scenario: The cross-signing upload body is not logged" do
    alice = TD.user!("CGL")
    canary = "CANARY-" <> T.rand(8)
    key = fn usage -> %{"user_id" => alice.uid, "usage" => [usage], "keys" => %{"ed25519:K-#{canary}-#{usage}" => "pub-#{canary}-#{usage}"}, "signatures" => %{alice.uid => %{"ed25519:S-#{canary}" => "sig-#{canary}"}}} end

    body = %{
      "master_key" => key.("master"),
      "self_signing_key" => key.("self_signing"),
      "user_signing_key" => key.("user_signing"),
      "auth" => %{"type" => "m.login.password", "session" => "sess-#{canary}", "password" => "pw-#{canary}"}
    }

    # Why this is red before the fix (read from RequestLogger / PayloadRedactor): the DEBUG payload line logs `request_body` through the key-NAME redactor, which masks
    # `password` and the UIA `auth.session` (so those two canaries are NOT the red part: they pin that the masking stays) but NOT `keys`, `signatures`, `master_key`,
    # `self_signing_key`, `user_signing_key` values; the whole body is dropped only for the paths of `RawBodyReader.key_material_shape?/1`, which does not name
    # keys/device_signing/upload yet. So the key ids, public keys and signatures below are the canaries that go through the path that is NOT masked today.
    log =
      logged(fn ->
        TD.req(:post, "/_matrix/client/v3/keys/device_signing/upload", alice.at, body)
        TD.req(:post, "/_matrix/client/unstable/keys/device_signing/upload", alice.at, body)
      end)

    assert log =~ "device_signing", "precondition: the request line is in the log (the check is not vacuous): #{String.slice(log, 0, 300)}"
    assert log =~ "request_body", "precondition: the DEBUG payload line (the one that carries the request body) is in the capture: #{String.slice(log, 0, 300)}"
    refute log =~ canary, "key material of the request body reached a log line: " <> (Regex.scan(~r/.{0,80}#{canary}.{0,40}/, log) |> Enum.map(&hd/1) |> Enum.join("\n"))
    refute log =~ alice.at, "the access token reached the log"
  end

  @tag ac: "oracle-key-material-shape-list"
  test "oracle D4: RawBodyReader.key_material_shape?/1 names keys/device_signing/upload (every version, normalised) and keeps the existing members" do
    shape = &Nebu.Web.Plugs.RawBodyReader.key_material_shape?/1

    for version <- ~w(v3 r0 unstable v1) do
      assert shape.("/_matrix/client/#{version}/keys/device_signing/upload"), "#{version}/keys/device_signing/upload"
    end

    assert shape.("/_matrix/client/v3/keys/device_signing/upload/"), "a trailing slash"
    assert shape.("/_matrix/client/v3//keys//device_signing//upload"), "doubled slashes"

    for path <- ~w(claim upload query signatures/upload) do
      assert shape.("/_matrix/client/v3/keys/#{path}"), "the existing member keys/#{path} stays"
    end

    refute shape.("/_matrix/client/v3/keys/device_signing"), "the shape is the upload route only"
    refute shape.("/_matrix/client/v3/keys/device_signing/upload/more")
    refute shape.("/_matrix/client/v3/keys/changes")
    refute shape.("/_matrix/client/v3/rooms/x/send/m.room.message/1")
  end

  # ═══ documents ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

  # Scenario: The architecture documents state the accepted residual and the release precondition
  #   Given the ADR-011 update and the risk register
  #   When they are read
  #   Then they name the to-device channel as an accepted non-archived opaque channel, the migration order precondition and the other epic residuals
  @tag ac: "the-architecture-documents-state-the-accepted-residual-and-the"
  test "Scenario: The architecture documents state the accepted residual and the release precondition" do
    squash = fn text -> String.replace(text, ~r/\s+/, " ") end
    adr = @adr |> File.read!() |> squash.()
    risks = @risks |> File.read!() |> squash.()
    deploy = @deploy |> File.read!() |> squash.()
    risk_rows = @risks |> File.read!() |> String.split("\n") |> Enum.filter(&(&1 =~ @story)) |> Enum.join("\n") |> squash.()
    all_docs = adr <> " " <> risks <> " " <> deploy

    # ADR-011: the update of 2026-11-03
    assert adr =~ ~r/Update 2026-11-03[^>]{0,80}#{@story}/, "ADR-011 has a dated update naming the story"
    [_, update] = Regex.run(~r/(Update 2026-11-03.{0,3500})/s, adr)
    assert update =~ "m.room.encrypted" and update =~ ~r/403|M_FORBIDDEN/, "m.room.encrypted is refused on every room write path"
    assert update =~ ~r/sendToDevice|to-device/i and update =~ ~r/opak|opaque/i, "the to-device channel is named as opaque"
    assert update =~ ~r/nicht archiv|not archived|non-archived|ohne Archiv|kein(e)? Archiv/i, "and as not archived"
    assert update =~ ~r/akzeptiert|accepted|Restrisiko|residual/i, "an accepted residual"
    assert update =~ ~r/Audit|audit/, "there is no per-send audit"
    assert update =~ ~r/Owner|owner|Eigentuemer|Eigentümer|signed off|abgenommen|freigegeben/, "signed off by the owner"
    assert update =~ ~r/Allowlist|allowlist|Positivliste|Whitelist/, "the allowlist is named"
    assert update =~ ~r/Key-?Backup|key backup|Schluessel-?Backup|Schlüssel-?Backup/i, "the key-backup blobs are named as opaque client data"
    assert update =~ ~r/Cross-?Signing|Kreuzsignatur/i, "the cross-signing signatures too"

    # the allowlist constant and the documented list
    code = File.read!(@http_to_device)
    assert code =~ ~r/@\w*allow\w*\s/i, "one named constant list in http_to_device.ex"
    for type <- @allowlist, do: assert(code =~ ~s("#{type}"), "#{type} is in the allowlist constant of http_to_device.ex")
    for type <- @allowlist, do: assert(all_docs =~ type, "#{type} is documented (ADR-011 / 11-risks / 07-deployment)")

    # the deliberately refused types as WHOLE tokens: a plain substring match is vacuous for m.room_key (it is part of m.room_key_request and m.room_key.withheld)
    token = fn text, type -> Regex.match?(~r/(?<![\w.])#{Regex.escape(type)}(?![_\w]|\.\w)/, text) end

    for type <- ~w(m.room_key m.forwarded_room_key m.secret.send org.matrix.room_key.withheld), do: assert(token.(all_docs, type), "the deliberately refused #{type} is documented as a standalone token")

    assert token.("a m.room_key. b", "m.room_key") and token.("`m.room_key`", "m.room_key"), "(the token matcher accepts a sentence end and a code span)"
    refute token.("m.room_key_request and m.room_key.withheld", "m.room_key"), "(the token matcher is not fooled by the allowlisted neighbours)"

    # the Element Call exclusion
    assert all_docs =~ "io.element.call.encryption_keys", "the Element Call key transport is named as a known exclusion"
    assert all_docs =~ ~r/Element Call/ and all_docs =~ ~r/MatrixRTC|m\.call\.\*/

    # 11-risks: the row of this story, the accepted residual and the other epic findings
    assert risk_rows =~ @story, "11-risks has a row for the story"
    assert risk_rows =~ ~r/to-device/i and risk_rows =~ ~r/akzeptiert|accepted|Restrisiko|residual/i
    assert risk_rows =~ ~r/Audit|audit/, "no per-send audit (an operator who needs one opens a new story)"
    assert risk_rows =~ ~r/non-archived|nicht archiv|not archived/i
    assert risks =~ "000056" and risks =~ "000057" and risks =~ ~r/000058/ and risks =~ ~r/000061/, "the migration order precondition (OAuth 000056/000057 before 000058-000061)"
    assert risks =~ ~r/ReleaseTest/ and risks =~ ~r/contiguity|zusammenhaengend|lueckenlos|Kontiguit/i
    assert risks =~ ~r/400 MiB/ and risks =~ ~r/2 GiB/ and risks =~ ~r/10-20 MB|10 - 20 MB|10–20 MB/, "the epic aggregate memory residual with its numbers"
    assert risks =~ "40P01" and risks =~ ~r/to_device_messages/ and risks =~ ~r/cross_signing_user_signatures/, "the concurrent-erasure deadlock"
    assert risks =~ ~r/keys_changes/ and risks =~ ~r/4760/, "the /sync device-list scan reaches the global lock through the per-IP sync tier"
    assert risks =~ "Element Call", "the Element Call exclusion"

    # 07-deployment: the release precondition for the operator
    # anchored on the paragraph of this epic: 000056 is also named earlier in the file (session lifetime, a different story),
    # so "the first 000056" is no longer the precondition paragraph
    [_, window] = Regex.run(~r/(Migration order precondition.{0,1500})/s, deploy)
    assert window =~ "000056", "07-deployment names the migrations 000056/000057 and 000058-000061"
    assert window =~ "000057" and window =~ ~r/000058/ and window =~ ~r/000061/, "07-deployment names the migrations 000056/000057 and 000058-000061"
    assert window =~ ~r/nach|after|AFTER|erst|only/, "as an order (the OAuth migrations first)"
    assert window =~ ~r/ReleaseTest/ and window =~ ~r/OAuth/, "the guard and the branch"
    assert deploy =~ ~r/Element Call/ and deploy =~ ~r/allowlist|Allowlist/, "07-deployment names the Element Call exclusion and the allowlist (a new type is a reviewed one-line change)"
  end
end
