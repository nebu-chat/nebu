defmodule Nebu.Web.JsonBodyTooLargeTest do
  @moduledoc """
  Story `event-size-limit` (epic oauth-broker, follow-up `ep`), AC7 / D7: bodies over the 1 MB parser cap of `Nebu.Web.Plugs.JsonBody` get a MATRIX error
  envelope on every `/_matrix/*` route.

  Today `Plug.Parsers.RequestTooLargeError` is caught only for the account-data / room-tag PUT shapes (`:body_too_large`, answered by the handler) and for
  `/oauth2/register` (OAuth shape); every other route RE-RAISES, and Bandit answers a 413 with NO body, no errcode, no CORS headers (`Plug.Test` shows the
  raise itself). The Matrix spec wants an errcode envelope on every error (Oracle: "fixes a MUST violation").

  D7: the cap (`length: 1_000_000`) is not changed. In the rescue, a request whose `path_info` starts with `"_matrix"` and that is NOT an opaque-content PUT
  and not `/oauth2/register` is answered directly: `413`, `application/json`, `{"errcode": "M_TOO_LARGE", "error": "Request body is too large"}`,
  `Plug.Conn.halt/1` (no route runs, nothing is written; the CORS headers set by `:cors` stay, so a browser client can read the error). All other paths keep
  the re-raise.

  Two halves: the PURE half needs no database (the plug runs before the authentication and answers before any route: no `Authorization` header at all),
  the `:integration` half writes through the real stack (real room, real session) and pins "nothing written" and the unchanged handlers.

  Helpers are local (`defp`): the shared `T.matrix_request/4` JSON-encodes its body, these tests need verbatim bytes.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Nebu.OAuth.TestSupport, as: T

  @router_opts Nebu.Web.Router.init([])
  @cap 1_000_000
  @error %{"errcode" => "M_TOO_LARGE", "error" => "Request body is too large"}
  @origin "https://client.example.com"

  # ─── helpers ──────────────────────────────────────────────────────────────────────

  # a syntactically valid JSON object of EXACTLY `total` bytes
  defp padded_json(total) do
    prefix = ~s({"pad":")
    suffix = ~s("})
    prefix <> String.duplicate("a", total - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  # `json` followed by insignificant whitespace up to exactly `total` bytes
  defp whitespace_padded(json, total), do: json <> String.duplicate(" ", total - byte_size(json))

  defp raw(method, path, body, opts \\ []) do
    c = conn(method, path, body) |> put_req_header("content-type", Keyword.get(opts, :content_type, "application/json"))
    c = if token = opts[:token], do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    c = if origin = opts[:origin], do: put_req_header(c, "origin", origin), else: c
    Nebu.Web.Router.call(%{c | remote_ip: T.unique_ip()}, @router_opts)
  end

  defp enc(s), do: URI.encode_www_form(s)

  defp cors_headers(conn), do: conn.resp_headers |> Enum.filter(fn {k, _} -> String.starts_with?(k, "access-control-") end) |> Enum.sort()

  defp assert_envelope(conn, label) do
    assert conn.status == 413, "#{label}: expected 413, got #{conn.status} #{String.slice(conn.resp_body || "", 0, 200)}"
    assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}, "#{label}: content-type #{inspect(T.header(conn, "content-type"))}"
    assert Jason.decode!(conn.resp_body) == @error, "#{label}: #{conn.resp_body}"
    assert conn.halted, "#{label}: no route may run after the answer"
  end

  # Plug.Test propagates a raised Plug.Parsers.RequestTooLargeError (the real server renders it as an empty 413)
  defp assert_raises_too_large(fun) do
    assert_raise Plug.Parsers.RequestTooLargeError, fun
  end

  # ═══ AC7 (a), pure half: no database, no Authorization header ═══════════════════════════════

  describe "AC7 (a) - 1_000_001 bytes on /_matrix: the M_TOO_LARGE envelope" do
    @routes [
      {:put, "/_matrix/client/v3/rooms/%21r%3Atest.local/state/m.room.topic"},
      {:put, "/_matrix/client/v3/rooms/%21r%3Atest.local/state/m.space.child/%21child%3Atest.local"},
      {:put, "/_matrix/client/v3/rooms/%21r%3Atest.local/send/m.room.message/txn1"},
      {:post, "/_matrix/client/v3/createRoom"},
      {:post, "/_matrix/client/v3/rooms/%21r%3Atest.local/invite"}
    ]

    test "PUT state, /send, createRoom and invite without an Authorization header: 413, application/json, exactly the envelope" do
      body = padded_json(@cap + 1)
      assert byte_size(body) == 1_000_001

      for {method, path} <- @routes do
        assert_envelope(raw(method, path, body), "#{method} #{path}")
      end
    end

    test "code review cycle 1 (Kassandra #2): the 413 closes the connection (the unread rest of the body is not drained)" do
      for {method, path} <- @routes do
        conn = raw(method, path, padded_json(@cap + 1))
        assert T.header(conn, "connection") == "close", "#{method} #{path}: #{inspect(T.header(conn, "connection"))}"
      end
    end

    test "other /_matrix routes get it too: POST /login and a JSON-typed media upload (the spec's 413 M_TOO_LARGE)" do
      body = padded_json(@cap + 1)

      assert_envelope(raw(:post, "/_matrix/client/v3/login", body), "login")
      assert_envelope(raw(:post, "/_matrix/media/v3/upload", body), "media upload")
    end

    test "a body of more than twice the cap is the same envelope (the parser stops at the cap)" do
      assert_envelope(raw(:put, "/_matrix/client/v3/rooms/%21r%3Atest.local/send/m.room.message/txn2", padded_json(2 * @cap + 7)), "2 MB")
    end

    test "the CORS headers stay on the 413 of all five routes and equal those of a normal answer of the same route for the same Origin" do
      routes =
        @routes ++ [{:post, "/_matrix/client/v3/login"}]

      for {method, path} <- routes do
        big = raw(method, path, padded_json(@cap + 1), origin: @origin)
        assert_envelope(big, "with origin: #{method} #{path}")
        normal = raw(method, path, "{}", origin: @origin)

        assert T.header(big, "access-control-allow-origin") in ["*", @origin], "#{path}: got #{inspect(T.header(big, "access-control-allow-origin"))}"
        assert cors_headers(big) == cors_headers(normal), "#{path}: #{inspect(cors_headers(big))} vs #{inspect(cors_headers(normal))}"
      end
    end

    test "AC7 (c) a non-/_matrix path (/oauth2/jwks) still raises Plug.Parsers.RequestTooLargeError (Bandit's empty 413)" do
      assert_raises_too_large(fn -> raw(:post, "/oauth2/jwks", padded_json(@cap + 1)) end)
    end

    test "AC7 (c) /oauth2/register keeps its OAuth error shape: 413 invalid_request, not the Matrix envelope" do
      T.enable_oauth()
      T.reset_rate_limits()

      on_exit(fn ->
        T.clear_oauth_config()
        T.restore_rate_limits()
      end)

      conn = T.register(T.web_body(%{"client_name" => String.duplicate("A", 140_000)}))
      T.assert_oauth_error(conn, 413, "invalid_request")
      refute conn.resp_body =~ "M_TOO_LARGE"
    end
  end

  # ═══ AC7 (a), (b), (c), integration half ══════════════════════════════════════════════════

  describe "AC7 (a) - nothing is written, authenticated, real stack" do
    @describetag :integration

    setup do
      T.reset_rate_limits()
      Nebu.Test.ServerName.pin!(T.server_name())
      on_exit(fn -> T.restore_rate_limits() end)

      uid = T.provision_user!()
      at = T.legacy_session!(uid, "JBT" <> String.upcase(T.rand(3))).at
      conn = T.matrix_request(:post, "/_matrix/client/v3/createRoom", at, body: %{"preset" => "private_chat"})
      assert conn.status == 200, conn.resp_body
      {:ok, uid: uid, at: at, room: T.json(conn)["room_id"]}
    end

    defp event_count(room), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()
    defp created_rooms(uid), do: T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [uid]).rows |> hd() |> hd()

    test "an authenticated oversized PUT state, PUT /send, POST /createRoom and POST /invite: the envelope, no events row, no new room, no invitation", %{uid: uid, at: at, room: room} do
      body = padded_json(@cap + 1)
      events = event_count(room)
      rooms = created_rooms(uid)
      invitations = T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [room]).rows

      assert_envelope(raw(:put, "/_matrix/client/v3/rooms/#{enc(room)}/state/m.room.topic", body, token: at), "state")
      assert_envelope(raw(:put, "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/jbt1", body, token: at), "send")
      assert_envelope(raw(:post, "/_matrix/client/v3/createRoom", body, token: at), "createRoom")
      assert_envelope(raw(:post, "/_matrix/client/v3/rooms/#{enc(room)}/invite", body, token: at), "invite")

      assert event_count(room) == events, "no events row"
      assert created_rooms(uid) == rooms, "no room"
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [room]).rows == invitations

      # positive control: the same user, the same routes, a small body: everything works
      ok = raw(:put, "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/jbt2", ~s({"msgtype":"m.text","body":"hi"}), token: at)
      assert ok.status == 200, ok.resp_body
    end

    test "the 413 does not spend the createRoom token: the plug answers before the router charges anything", %{at: at, uid: uid} do
      table = :nebu_http_rate_limit_buckets
      Nebu.Web.Plugs.RateLimit.init_table()
      tokens = fn -> case :ets.lookup(table, {"create_room", uid}) do [{_k, t, _}] -> t; [] -> 20.0 end end
      before = tokens.()
      assert_envelope(raw(:post, "/_matrix/client/v3/createRoom", padded_json(@cap + 1), token: at), "createRoom")
      assert tokens.() == before
    end

    test "AC7 (b) exactly 1_000_000 bytes passes the parser: a whitespace-padded small valid /send body is 200 and the event is stored", %{at: at, room: room} do
      small = ~s({"msgtype":"m.text","body":"padded"})
      body = whitespace_padded(small, @cap)
      assert byte_size(body) == 1_000_000

      conn = raw(:put, "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/jbt3", body, token: at)
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      event_id = T.json(conn)["event_id"]
      assert T.sql!("SELECT count(*) FROM events WHERE event_id = $1", [event_id]).rows == [[1]]
    end

    test "AC7 (c) unchanged: the account-data and room-tag PUTs keep their handler texts for a body over 1 MB", %{uid: uid, at: at, room: room} do
      big = padded_json(@cap + 1)

      global = raw(:put, "/_matrix/client/v3/user/#{enc(uid)}/account_data/m.jbt.test", big, token: at)
      assert global.status == 413
      assert T.json(global) == %{"errcode" => "M_TOO_LARGE", "error" => "Account data content too large"}

      scoped = raw(:put, "/_matrix/client/v3/user/#{enc(uid)}/rooms/#{enc(room)}/account_data/m.jbt.test", big, token: at)
      assert scoped.status == 413
      assert T.json(scoped) == %{"errcode" => "M_TOO_LARGE", "error" => "Account data content too large"}

      tag = raw(:put, "/_matrix/client/v3/user/#{enc(uid)}/rooms/#{enc(room)}/tags/u.jbt", big, token: at)
      assert tag.status == 413
      assert T.json(tag) == %{"errcode" => "M_TOO_LARGE", "error" => "Tag content too large"}
    end

    test "AC7 (c) a path that merely CONTAINS an account_data segment is no account-data shape: send/.../account_data over 1 MB is the Matrix envelope", %{at: at, room: room} do
      conn = raw(:put, "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/account_data", padded_json(@cap + 1), token: at)
      assert_envelope(conn, "send with an account_data txn id")
      refute conn.resp_body =~ "Account data"
    end
  end
end
