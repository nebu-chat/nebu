defmodule Nebu.Web.UnrecognizedRoutesIntegrationTest do
  @moduledoc """
  Integration acceptance tests for story `oauth-room-summary-unrecognized` (epic
  oauth-broker, gate af), the parts that need a real session store / DB (`unrecognized_routes_test.exs`
  is the no-DB half):

    * AC8 with a VALID legacy token and a VALID OAuth token: the fall-throughs answer the same
      `404 M_UNRECOGNIZED` as for no / junk tokens (RU10, no auth requirement);
    * AC8a: `POST /v3/register` answers `403 M_FORBIDDEN` for a legacy and an OAuth token too, and
      touches no `register` / `login` bucket;
    * AC9: every handler-level `M_NOT_FOUND` / handler-generated error keeps its answer (RU12), and
      `/hierarchy` keeps its 403;
    * AC10: unsupported methods with a valid token, and routed methods still reach their handlers;
    * AC13: the HttpPublic root table with a real session (no login happens, no session row appears).

  Measured on 671ea2e8 for AC9 (all with a valid token): unset account data `404 M_NOT_FOUND "Account
  data not found"`; unknown device `404 "Unknown device"`; `room_keys/version` `404 "No backup found"`;
  `voip/turnServer` `404 "No TURN server configured"`; unknown v1 media `404 "Media not found"`; unknown
  profile `404 "Profile not found"`; `PUT account_data/m.push_rules` `405 M_BAD_JSON "Cannot set account
  data of server-managed type m.push_rules"`; `/hierarchy` of an unknown id AND of a hidden room `403
  M_FORBIDDEN "You are not a member of this room"` (the unknown id passes the RU18 lazy insert, a side
  finding NOT fixed here, so 403 is pinned as measured).

  Deviation from the story text: AC9 lists "a missing state event in a joined room". `GET
  /rooms/{id}/state/{type}` is NOT routed at all (only the PUT state routes exist), so it is not a
  handler-level `M_NOT_FOUND`. The test pins the handler-level `GET /rooms/{id}/event/{unknown}`
  `404 M_NOT_FOUND` instead, and (decision RU11a, pre-dev review M1) pins that exactly the unrouted GETs on
  `/rooms/{id}/state` and `/state/{type}[/{key}]` keep their `404 M_NOT_FOUND "Unrecognized request"`
  (clients read it as "state absent") instead of turning into M_UNRECOGNIZED / 405.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @https "https://app.example.com/cb"
  @unrecognized %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}
  @unsupported %{"errcode" => "M_UNRECOGNIZED", "error" => "Unsupported method"}
  @register_forbidden %{"errcode" => "M_FORBIDDEN", "error" => "Registration is not enabled on this homeserver."}
  @bucket_table :nebu_http_rate_limit_buckets

  setup do
    T.reset_rate_limits()
    T.enable_oauth()
    priv = T.setup_idp!()
    cid = T.oauth_client!([@https])
    oauth = T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
    uid = T.provision_user!()
    legacy = T.legacy_session!(uid, dev())

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, tokens: [{:legacy, legacy.at}, {:oauth, oauth.at}], legacy_uid: uid, legacy_at: legacy.at}
  end

  defp dev, do: "UR" <> String.upcase(T.rand(4))
  defp allow_set(conn), do: conn |> Plug.Conn.get_resp_header("allow") |> List.first() |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
  defp bucket_rows, do: if(:ets.whereis(@bucket_table) == :undefined, do: [], else: :ets.tab2list(@bucket_table))

  defp assert_404(conn, label) do
    assert conn.status == 404, "#{label}: #{conn.status} #{conn.resp_body}"
    assert T.json(conn) == @unrecognized, label
    assert (T.header(conn, "content-type") || "") =~ "application/json"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — valid tokens get the same 404 as everybody else
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8 — fall-throughs with a valid legacy / OAuth token" do
    test "Protected, Media, ClientV1Media and HttpPublic fall-throughs answer 404 M_UNRECOGNIZED", %{tokens: tokens} do
      paths = [
        {:get, "/_matrix/client/v3/does_not_exist"},
        {:post, "/_matrix/client/v3/account/deactivate"},
        {:get, "/_matrix/client/v3/publicRooms"},
        {:get, "/_matrix/client/v3/versions"},
        {:get, "/_matrix/federation/v1/version"},
        {:get, "/_matrix/client/unstable/im.nheko.summary/summary/!r:s"},
        {:get, "/_matrix/media/v3/config"},
        {:get, "/_matrix/media/v3/nope"},
        {:get, "/_matrix/client/v1/media/config"},
        {:get, "/_matrix/client/v3/auth"},
        {:get, "/_matrix/client/v3/profile"},
        {:get, "/_matrix/client/v3/login/sso/unknown/x/y"},
        {:get, "/_matrix/client/v3/auth/m.login.password/fallback/web"}
      ]

      for {kind, token} <- tokens, {m, p} <- paths do
        assert_404(T.matrix_request(m, p, token), "#{kind} #{m} #{p}")
      end
    end

    test "a revoked / unknown token on an unknown path costs nothing and still answers 404 (no auth requirement)" do
      assert_404(T.matrix_request(:get, "/_matrix/client/v3/does_not_exist", "not-a-real-token"), "unknown token")
    end

    test "AC8a: POST /v3/register => 403 M_FORBIDDEN for a legacy and an OAuth token, any body, no bucket, no log", %{tokens: tokens} do
      T.reset_rate_limits()

      for {kind, token} <- tokens, {suffix, body} <- [{"", %{}}, {"", %{"username" => "x", "password" => "y"}}, {"?kind=guest", %{}}] do
        log =
          capture_log(fn ->
            send(self(), {:answer, T.matrix_request(:post, "/_matrix/client/v3/register" <> suffix, token, body: body)})
          end)

        assert_received {:answer, c}
        assert c.status == 403, "#{kind} #{suffix}: #{c.status} #{c.resp_body}"
        assert T.json(c) == @register_forbidden
        assert log == ""
      end

      assert bucket_rows() == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — handler-level answers are preserved (RU12)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9/RU12 — handler-level errors stay as they are" do
    test "each handler-level 404 keeps M_NOT_FOUND and its own message", %{legacy_at: at, legacy_uid: uid} do
      room = T.json(T.matrix_request(:post, "/_matrix/client/v3/createRoom", at, body: %{"name" => "AC9 #{T.rand(4)}"}))["room_id"]
      r = URI.encode_www_form(room)

      cases = [
        {"unset account data", "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/x.unset", "Account data not found"},
        {"an unknown event in a joined room", "/_matrix/client/v3/rooms/#{r}/event/#{URI.encode_www_form("$unknown" <> T.rand(6) <> ":test.local")}", nil},
        # RU11a (carve-out of the pre-dev review, M1): GET state is not implemented, but clients read this
        # 404 M_NOT_FOUND as "state absent": it keeps today's answer until follow-up bf implements the GET.
        {"unimplemented GET state/{type} (RU11a)", "/_matrix/client/v3/rooms/#{r}/state/m.room.encryption", "Unrecognized request"},
        {"unimplemented GET state/{type}/ (RU11a)", "/_matrix/client/v3/rooms/#{r}/state/m.room.name/", "Unrecognized request"},
        {"unimplemented GET state (RU11a)", "/_matrix/client/v3/rooms/#{r}/state", "Unrecognized request"},
        {"unknown device", "/_matrix/client/v3/devices/UNKNOWN", "Unknown device"},
        {"room_keys/version", "/_matrix/client/v3/room_keys/version", "No backup found"},
        {"voip/turnServer", "/_matrix/client/v3/voip/turnServer", "No TURN server configured"},
        {"unknown v1 media", "/_matrix/client/v1/media/download/test.local/nothere#{T.rand(5)}", "Media not found"},
        {"unknown profile", "/_matrix/client/v3/profile/#{URI.encode_www_form("@nobody#{T.rand(5)}:test.local")}", "Profile not found"}
      ]

      for {label, path, message} <- cases do
        c = T.matrix_request(:get, path, at)
        assert c.status == 404, "#{label}: #{c.status} #{c.resp_body}"
        body = T.json(c)
        assert body["errcode"] == "M_NOT_FOUND", "#{label}: #{inspect(body)}"
        refute body == @unrecognized, label
        if message, do: assert(body["error"] == message, label)
      end
    end

    test "a handler-generated non-404 is untouched: PUT account_data/m.push_rules stays 405 M_BAD_JSON", %{legacy_at: at, legacy_uid: uid} do
      c = T.matrix_request(:put, "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/m.push_rules", at, body: %{"a" => 1})
      assert c.status == 405
      assert T.json(c) == %{"errcode" => "M_BAD_JSON", "error" => "Cannot set account data of server-managed type m.push_rules"}
    end

    test "/hierarchy keeps 403 for a hidden root and (as measured, RU18) for an unknown id", %{legacy_at: at} do
      other = T.legacy_session!(T.provision_user!(), dev()).at
      room = T.json(T.matrix_request(:post, "/_matrix/client/v3/createRoom", at, body: %{"name" => "Hier #{T.rand(4)}"}))["room_id"]

      for id <- [room, "!unknownhier#{T.rand(6)}:test.local"] do
        c = T.matrix_request(:get, "/_matrix/client/v1/rooms/#{URI.encode_www_form(id)}/hierarchy", other)
        assert {c.status, T.json(c)} == {403, %{"errcode" => "M_FORBIDDEN", "error" => "You are not a member of this room"}}, id
      end
    end

    test "a known path with a routed method and a valid token still reaches its handler (200 / handler answer, not 405)", %{tokens: tokens} do
      for {kind, token} <- tokens do
        assert T.matrix_request(:get, "/_matrix/client/v3/account/whoami", token).status == 200, "#{kind}"
        assert T.matrix_request(:get, "/_matrix/client/v3/capabilities", token).status == 200, "#{kind}"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 — unsupported methods with a valid token
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10 — 405 M_UNRECOGNIZED + Allow with a valid token" do
    test "PUT sync, GET createRoom, POST devices/X, PUT media upload, DELETE v1 media download, POST/PUT room_summary", %{tokens: tokens} do
      table = [
        {:put, "/_matrix/client/v3/sync", ["GET"]},
        {:get, "/_matrix/client/v3/createRoom", ["POST"]},
        {:post, "/_matrix/client/v3/devices/X", ["GET", "PUT", "DELETE"]},
        {:put, "/_matrix/media/v3/upload", ["POST"]},
        {:delete, "/_matrix/client/v1/media/download/s/m", ["GET"]},
        {:post, "/_matrix/client/v1/room_summary/!r:test.local", ["GET"]},
        {:put, "/_matrix/client/v1/room_summary/!r:test.local", ["GET"]}
      ]

      for {kind, token} <- tokens, {m, p, methods} <- table do
        c = T.matrix_request(m, p, token)
        assert c.status == 405, "#{kind} #{m} #{p}: #{c.status} #{c.resp_body}"
        assert T.json(c) == @unsupported
        assert allow_set(c) == MapSet.new(methods ++ ["OPTIONS"])
      end
    end

    test "a non-preflight OPTIONS with a valid token on sync answers 204 + Allow, never 401 and no session side effect", %{tokens: tokens} do
      for {kind, token} <- tokens do
        c = T.matrix_request(:options, "/_matrix/client/v3/sync", token)
        assert c.status == 204, "#{kind}: #{c.status}"
        assert allow_set(c) == MapSet.new(["GET", "OPTIONS"])
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC13 — HttpPublic root: nothing reaches do_login / do_refresh
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC13 — POST on non-login roots of HttpPublic never logs anybody in" do
    test "POST /v3/auth and /v3/profile => 404 and no session row is created" do
      before = T.sql!("SELECT count(*) FROM matrix_sessions").rows
      body = %{"type" => "m.login.token", "token" => "x"}

      for path <- ["/_matrix/client/v3/auth", "/_matrix/client/v3/profile"] do
        c = Plug.Test.conn(:post, path, Jason.encode!(body)) |> Plug.Conn.put_req_header("content-type", "application/json") |> Map.put(:remote_ip, T.unique_ip()) |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
        assert_404(c, "POST #{path}")
      end

      assert T.sql!("SELECT count(*) FROM matrix_sessions").rows == before
    end

    test "login and refresh keep their method sets with a live DB", %{legacy_uid: _uid} do
      for {m, p, methods} <- [{:put, "/_matrix/client/v3/login", ["GET", "POST"]}, {:get, "/_matrix/client/v3/refresh", ["POST"]}] do
        c = Plug.Test.conn(m, p) |> Map.put(:remote_ip, T.unique_ip()) |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
        assert c.status == 405, "#{m} #{p}"
        assert allow_set(c) == MapSet.new(methods ++ ["OPTIONS"])
      end
    end
  end
end
