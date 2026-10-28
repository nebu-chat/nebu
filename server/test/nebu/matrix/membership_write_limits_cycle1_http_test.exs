defmodule Nebu.Matrix.MembershipWriteLimitsCycle1HttpTest do
  @moduledoc """
  Story `rate-limits-join-invite-create-room`, review cycle 1 (HTTP, real stack and real database, `async: false`):

    * (Kassandra L-1 / code review MINOR-4) `POST /rooms/{roomId}/upgrade` creates a NEW room, so it spends one `create_room` unit
      of the user (charged first, 429 before any body check, nothing created when refused);
    * (Kassandra M-1c) the pair cap is HARD under concurrency over `POST /invite`: concurrent invitations of one inviter into many
      rooms for one victim never exceed it (the count-then-write overshoot of the first cut);
    * (Kassandra M-1a) the victim's slots: rows of an inviter the victim ignores and of a deactivated inviter do not fill the
      invitee cap, so a legitimate inviter can still invite;
    * (Kassandra M-2) the byte budget of `rooms.invite`: an oversized optional stripped event (a 70 KiB topic) is left out of the
      `invite_state`, the invitation itself and the small events stay.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @create "/_matrix/client/v3/createRoom"
  @table :nebu_http_rate_limit_buckets
  @cap_keys [:invite_max_pending_per_inviter, :invite_max_pending_per_invitee, :invite_max_pending_per_pair]

  setup do
    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true",
           "this suite requires the limiter ENABLED: NEBU_RATE_LIMIT_DISABLED must not be \"true\" in the test harness"

    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    caps = for key <- @cap_keys, do: {key, Application.fetch_env(:nebu, key)}

    on_exit(fn ->
      T.restore_rate_limits()

      for {key, previous} <- caps do
        case previous do
          {:ok, value} -> Application.put_env(:nebu, key, value)
          :error -> Application.delete_env(:nebu, key)
        end
      end
    end)

    {:ok, a: user!("MC1A"), b: user!("MC1B"), c: user!("MC1C")}
  end

  defp user!(device_prefix) do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3))).at}
  end

  defp enc(room_id), do: URI.encode_www_form(room_id)
  defp path(room, suffix), do: "/_matrix/client/v3/rooms/#{enc(room)}/#{suffix}"
  defp put_cap(key, value), do: Application.put_env(:nebu, key, value)

  defp make_room(user, body \\ %{}) do
    conn = T.matrix_request(:post, @create, user.at, body: body)
    assert conn.status == 200, "createRoom: #{conn.status} #{conn.resp_body}"
    T.json(conn)["room_id"]
  end

  defp upgrade(user, room, body), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: body)
  defp invite(owner, room, target), do: T.matrix_request(:post, path(room, "invite"), owner.at, body: %{"user_id" => target.uid})

  defp sync(user) do
    conn = T.matrix_request(:get, "/_matrix/client/v3/sync?timeout=0", user.at)
    assert conn.status == 200, "sync: #{conn.status} #{conn.resp_body}"
    T.json(conn)
  end

  defp seed(tier, user, tokens) do
    Nebu.Web.Plugs.RateLimit.init_table()
    :ets.insert(@table, {{tier, user.uid}, tokens * 1.0, Application.get_env(:nebu_http, :rate_limit_clock_fn).()})
  end

  defp tokens(tier, user) do
    case :ets.lookup(@table, {tier, user.uid}) do
      [{_key, tokens, _}] -> tokens
      [] -> nil
    end
  end

  defp room_count(uid), do: T.sql!("SELECT count(*) FROM room_members WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  defp pending_rows(inviter_uid), do: T.sql!("SELECT count(*) FROM room_invitations WHERE inviter_id = $1 AND accepted_at IS NULL AND rejected_at IS NULL", [inviter_uid]).rows |> hd() |> hd()

  # ═══ upgrade is charged ═════════════════════════════════════════════════════════

  describe "upgrade charges the create_room bucket" do
    test "an upgrade spends exactly one create_room unit and a refused upgrade (empty bucket) is the 429 envelope BEFORE the body check and creates no room", %{a: a} do
      room = make_room(a)
      before = tokens("create_room", a)
      assert before == 19.0, "the createRoom above took one of 20"

      conn = upgrade(a, room, %{"new_version" => "10"})
      assert conn.status == 200, conn.resp_body
      assert tokens("create_room", a) == 18.0, "the upgrade took one create_room unit"

      seed("create_room", a, 0)
      rooms = room_count(a.uid)

      # even a body that would be a 400 is answered 429 first (charge before validation, like createRoom)
      for body <- [%{"new_version" => "10"}, %{}, %{"new_version" => 5}] do
        refused = upgrade(a, room, body)
        assert refused.status == 429, "body #{inspect(body)}: #{refused.status} #{refused.resp_body}"
        assert T.json(refused)["errcode"] == "M_LIMIT_EXCEEDED"
        assert {secs, ""} = Integer.parse(T.header(refused, "retry-after") || "")
        assert T.json(refused)["retry_after_ms"] == secs * 1000
      end

      assert room_count(a.uid) == rooms, "the refused upgrades created nothing"

      # positive control: with a token the same request is accepted again
      seed("create_room", a, 1)
      refute upgrade(a, room, %{"new_version" => "10"}).status == 429, "with a token the request is no longer rate limited"
    end

    test "createRoom and upgrade draw from the SAME bucket: 20 creates leave no unit for an upgrade, other users are unaffected", %{a: a, b: b} do
      room = make_room(a)
      for _ <- 1..19, do: make_room(a)

      assert upgrade(a, room, %{"new_version" => "10"}).status == 429
      assert T.matrix_request(:post, @create, a.at, body: %{}).status == 429

      other = make_room(b)
      assert upgrade(b, other, %{"new_version" => "10"}).status == 200
    end

    test "a refused upgrade of a room the user does not own is still charged (the charge is first: it costs the caller, not the owner)", %{a: a, b: b} do
      room = make_room(a)
      before = tokens("create_room", b, 20)
      conn = upgrade(b, room, %{"new_version" => "10"})
      assert conn.status == 403
      assert tokens("create_room", b, 20) == before - 1
    end
  end

  defp tokens(tier, user, burst), do: tokens(tier, user) || burst * 1.0

  # ═══ the hard pair cap over HTTP ═════════════════════════════════════════════════

  describe "the pair cap is hard under concurrency (POST /invite)" do
    test "16 invitations of A into 16 rooms for B, 8 at a time, pair cap 3: exactly 3 are 200, the others the pair 403, 3 rows", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_pair, 3)
      rooms = for _ <- 1..16, do: make_room(a)
      # 16 invitations at once need 16 invite units (burst 50): fine

      results =
        rooms
        |> Task.async_stream(fn room -> invite(a, room, b) end, max_concurrency: 8, ordered: false, timeout: 60_000)
        |> Enum.map(fn {:ok, conn} -> {conn.status, conn.resp_body} end)

      ok = Enum.count(results, &match?({200, _}, &1))
      refused = Enum.filter(results, &match?({403, _}, &1))

      assert ok == 3, "exactly the cap: #{inspect(results)}"
      assert length(refused) == 13

      for {403, body} <- refused do
        assert Jason.decode!(body) == %{"errcode" => "M_FORBIDDEN", "error" => "You have too many pending invitations to this user"}
      end

      assert T.sql!("SELECT count(*) FROM room_invitations WHERE inviter_id = $1 AND invitee_id = $2 AND accepted_at IS NULL AND rejected_at IS NULL", [a.uid, b.uid]).rows == [[3]]
      assert map_size(get_in(sync(b), ["rooms", "invite"]) || %{}) == 3, "B sees exactly the three invitations"
    end

    test "the refused concurrent invitations wrote no invite event and no row (only the winners did)", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_pair, 2)
      rooms = for _ <- 1..8, do: make_room(a)
      rooms |> Task.async_stream(fn room -> invite(a, room, b) end, max_concurrency: 8, ordered: false, timeout: 60_000) |> Stream.run()

      events = T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.member' AND state_key = $1 AND content::text LIKE '%invite%'", [b.uid]).rows
      assert events == [[2]]
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE invitee_id = $1", [b.uid]).rows == [[2]]
    end
  end

  # ═══ the victim's slots ═════════════════════════════════════════════════════════

  describe "the invitee cap is not filled by ignored or deactivated inviters" do
    test "B ignores the pest P: P's invitations do not take B's slots, C can still invite B; without the ignore the cap would refuse C", %{a: p, b: b, c: c} do
      put_cap(:invite_max_pending_per_invitee, 2)
      rooms = for _ <- 1..2, do: make_room(p)
      for room <- rooms, do: assert(invite(p, room, b).status == 200)

      croom = make_room(c)
      refused = invite(c, croom, b)
      assert refused.status == 403 and T.json(refused)["error"] == "The invited user has too many pending invitations", "the slots are full"

      assert T.matrix_request(:put, "/_matrix/client/v3/user/#{enc(b.uid)}/account_data/m.ignored_user_list", b.at, body: %{"ignored_users" => %{p.uid => %{}}}).status == 200

      assert invite(c, croom, b).status == 200, "the ignored pest's rows no longer count"
      assert map_size(get_in(sync(b), ["rooms", "invite"]) || %{}) == 1, "and B does not see the pest's invitations at all"
    end

    test "P is deactivated: P's invitations do not take B's slots (and they come back on reactivation)", %{a: p, b: b, c: c} do
      put_cap(:invite_max_pending_per_invitee, 2)
      for _ <- 1..2, do: assert(invite(p, make_room(p), b).status == 200)
      croom = make_room(c)
      assert invite(c, croom, b).status == 403

      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [p.uid])
      assert invite(c, croom, b).status == 200
      T.sql!("UPDATE users SET is_active = true WHERE user_id = $1", [p.uid])

      # P's two rows count again: a third inviter now finds B at 3 of 2
      d = user!("MC1D")
      assert invite(d, make_room(d), b).status == 403
      assert pending_rows(p.uid) == 2, "nothing was rejected: the rows stayed pending"
    end
  end

  # ═══ the invite_state byte budget ═══════════════════════════════════════════════

  describe "rooms.invite: an oversized optional stripped event is left out, the invitation stays" do
    test "a 70 KiB topic is not in invite_state, the small name and the invitation are; a 1 KiB topic of another room stays", %{a: a, b: b} do
      big = make_room(a, %{"name" => "Big", "preset" => "private_chat"})
      small = make_room(a, %{"name" => "Small", "preset" => "private_chat"})

      for {room, topic} <- [{big, String.duplicate("t", 70_000)}, {small, String.duplicate("t", 1_000)}] do
        assert :ok =
                 DB.insert_event(%{
                   "event_id" => "$" <> T.rand(12),
                   "room_id" => room,
                   "sender" => a.uid,
                   "type" => "m.room.topic",
                   "state_key" => "",
                   "content" => %{"topic" => topic},
                   "origin_server_ts" => System.system_time(:millisecond) + 5
                 })
      end

      assert invite(a, big, b).status == 200
      assert invite(a, small, b).status == 200

      invites = get_in(sync(b), ["rooms", "invite"])
      assert Map.keys(invites) |> Enum.sort() == Enum.sort([big, small]), "BOTH invitations are listed"

      types = fn room -> invites[room]["invite_state"]["events"] |> Enum.map(& &1["type"]) end
      assert "m.room.topic" in types.(small), "positive control: a small topic is delivered"
      refute "m.room.topic" in types.(big), "the 70 KiB topic is not"
      assert "m.room.name" in types.(big) and "m.room.create" in types.(big)
      assert Enum.any?(invites[big]["invite_state"]["events"], &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid)), "the invitee's own invite event stays"
    end
  end

  # ═══ delta gate: the create event of a stripped invite state ═════════════════════

  describe "rooms.invite: an m.room.create above 64 KiB is reduced to its spec keys" do
    # story event-size-limit (DELIBERATE re-pin, AC8 (c); old -> new): a 100 KB `creation_content` is refused by createRoom now (`413 M_TOO_LARGE`, see the
    # next test), so the oversized create content of this read-side test is a LEGACY row (written before the story): the room is created with a SMALL
    # creation_content and a second, oversized `m.room.create` (100 KB `junk`, `type: "m.space"`) is inserted with `Room.DB.insert_event/1`. The stripped-state
    # read (`Room.DB.invite_state_events/1`) picks the OLDEST `m.room.create` of a room (`ORDER BY origin_server_ts ASC` for that type), so the legacy row is
    # stamped one millisecond BEFORE the real create event of its room (a past stamp in a room the test owns: no future-stamped event, follow-up `fj`).
    # The reduction above 64 KiB (defence in depth for such rows) is still exercised, unchanged.
    test "a LEGACY 100 KB create content is not travelling into the invitee's sync (creator, room_version and type stay), a small one is untouched", %{a: a, b: b} do
      big = make_room(a, %{"preset" => "private_chat", "creation_content" => %{"junk" => "small", "m.federate" => false}})
      small = make_room(a, %{"preset" => "private_chat", "creation_content" => %{"junk" => "small", "m.federate" => false}})

      first_create_ts = T.sql!("SELECT min(origin_server_ts) FROM events WHERE room_id = $1 AND event_type = 'm.room.create'", [big]).rows |> hd() |> hd()

      assert :ok =
               DB.insert_event(%{
                 "event_id" => "$" <> T.rand(12),
                 "room_id" => big,
                 "sender" => a.uid,
                 "type" => "m.room.create",
                 "state_key" => "",
                 "content" => %{"creator" => a.uid, "room_version" => "10", "type" => "m.space", "junk" => String.duplicate("j", 100_000), "m.federate" => false},
                 "origin_server_ts" => first_create_ts - 1
               })

      assert invite(a, big, b).status == 200
      assert invite(a, small, b).status == 200

      invites = get_in(sync(b), ["rooms", "invite"])
      create = fn room -> Enum.find(invites[room]["invite_state"]["events"], &(&1["type"] == "m.room.create"))["content"] end

      assert create.(small)["junk"] == "small", "positive control: a small create content is delivered as written"
      assert Map.keys(create.(big)) |> Enum.sort() == ["creator", "room_version", "type"]
      assert create.(big)["type"] == "m.space" and create.(big)["creator"] == a.uid
      assert Enum.any?(invites[big]["invite_state"]["events"], &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid)), "the invitation stays"
    end

    # story event-size-limit (AC8 (c), the new assertion of the same describe): the OLD request of this test is refused at the door now
    test "the old request (createRoom with a 100 KB creation_content) is now 413 M_TOO_LARGE and creates no room", %{a: a} do
      rooms = T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [a.uid]).rows |> hd() |> hd()

      conn = T.matrix_request(:post, @create, a.at, body: %{"preset" => "private_chat", "creation_content" => %{"type" => "m.space", "junk" => String.duplicate("j", 100_000), "m.federate" => false}})

      assert conn.status == 413, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      assert T.json(conn) == %{"errcode" => "M_TOO_LARGE", "error" => "creation_content makes the m.room.create event exceed the maximum size of 65536 bytes"}
      assert T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [a.uid]).rows |> hd() |> hd() == rooms
    end
  end

  # ═══ delta gate L-2: busy locks are a 503 M_LIMIT_EXCEEDED ══════════════════════

  describe "busy invitation locks" do
    test "POST /invite is 503 M_LIMIT_EXCEEDED while the invitee lock stays busy, writes nothing, works when it is free", %{a: a, b: b} do
      room = make_room(a)
      parent = self()

      holder =
        spawn_link(fn ->
          Nebu.Repo.transaction(fn ->
            %{rows: [[key]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT hashtextextended($1, 0)", ["nebu:invite:invitee:" <> b.uid])
            Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT pg_advisory_xact_lock($1)", [key])
            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:conn, invite(a, room, b)}) end)
      assert_received {:conn, conn}

      assert conn.status == 503, "#{conn.status} #{conn.resp_body}"
      body = T.json(conn)
      assert body["errcode"] == "M_LIMIT_EXCEEDED" and is_binary(body["error"])
      refute conn.resp_body =~ a.uid or conn.resp_body =~ b.uid
      assert log =~ "lock_timeout"
      refute log =~ a.uid or log =~ b.uid
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [room]).rows == [[0]]
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2", [room, b.uid]).rows == [[0]]

      send(holder, :release)
      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 5_000

      assert invite(a, room, b).status == 200, "positive control: the same invitation passes when the lock is free"
    end
  end
end
