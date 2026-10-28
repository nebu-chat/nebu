defmodule Nebu.Web.UnrecognizedRoutesTest do
  @moduledoc """
  Unit acceptance tests (router level, no DB) for story `oauth-room-summary-unrecognized`
  (epic oauth-broker, gate af): spec `M_UNRECOGNIZED` answers for unrouted Matrix endpoints (404) and
  unsupported methods (405), WITHOUT an authentication requirement for unknown endpoints (RU10), the
  explicit `POST /v3/register` => `403 M_FORBIDDEN` (RU10a), the HttpPublic root table (RU13) and the
  live-only 405 of the OAuth discovery paths (RU14).

  Covers AC8, AC8a, AC10, AC11, AC12, AC13, AC14 and AC15 (no log line), and RU11a (GET on the unimplemented
  `/rooms/{id}/state[/{type}[/{key}]]` keeps `404 M_NOT_FOUND`, pre-dev review M1). The integration variant with
  legacy / OAuth tokens and the handler-level `M_NOT_FOUND` regression list (AC9) is
  `unrecognized_routes_integration_test.exs`.

  ## Contracts pinned here (the implementation MUST honour them)

    * `Nebu.Web.Unrecognized` (new, shared): `not_found(conn)`, `method_not_allowed(conn, methods)`,
      `options(conn, methods)`; `methods` EXCLUDES `OPTIONS`, the `Allow` header always appends it.
    * `Nebu.Web.Router.Protected`, `Nebu.Web.Router.Media`, `Nebu.Web.Router.ClientV1Media` expose a
      PUBLIC plug function `authenticate(conn, opts)` (RU10): it runs `Nebu.Web.Plugs.OidcPlug` unless
      `conn.private[:nebu_unrecognized] === true` (`false`, `"true"`, absent: OidcPlug runs). The
      pipeline order is `:match` -> `:authenticate` -> `:dispatch`.
    * A non-preflight `OPTIONS` on a known path answers `204` + `Allow` + `access-control-allow-origin`
      (the story's RU15 / AC10.3: `CORSPlug` adds nothing for an OPTIONS without
      `access-control-request-method`, so `Unrecognized.options/2` sets the header itself).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Nebu.OAuth.TestSupport, as: T

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "unrecognized-routes-key-1"
  @router_opts Nebu.Web.Router.init([])
  @bucket_table :nebu_http_rate_limit_buckets

  @unrecognized %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}
  @unsupported %{"errcode" => "M_UNRECOGNIZED", "error" => "Unsupported method"}
  @register_forbidden %{"errcode" => "M_FORBIDDEN", "error" => "Registration is not enabled on this homeserver."}

  setup do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.merge(%{"kid" => @kid, "alg" => "RS256", "use" => "sig"})

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    T.reset_rate_limits()

    on_exit(fn ->
      for k <- [:server_name, :oidc_jwks], do: Application.delete_env(:nebu_http, k)
      Nebu.Web.OidcTestSupport.clear()
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "unrec-user",
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second)
    }

    signed = JOSE.JWT.sign(JOSE.JWK.from_map(Map.put(priv_map, "kid", @kid)), %{"alg" => "RS256", "kid" => @kid}, claims)
    {_, valid} = JOSE.JWS.compact(signed)

    {:ok, valid: valid}
  end

  # {label, bearer}: no token, a junk token, a valid IdP JWT.
  defp token_modes(valid), do: [{:none, nil}, {:junk, "junk-token"}, {:valid, valid}]

  defp req(method, path, token \\ nil, opts \\ []) do
    c =
      conn(method, path, Keyword.get(opts, :body, nil))
      |> put_req_header("origin", "https://app.example.com")
      |> Map.put(:remote_ip, Keyword.get(opts, :ip, T.unique_ip()))

    c = if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    c = if Keyword.get(opts, :body), do: put_req_header(c, "content-type", "application/json"), else: c
    Nebu.Web.Router.call(c, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp ctype(conn), do: conn |> get_resp_header("content-type") |> List.first() |> to_string()
  defp cors?(conn), do: get_resp_header(conn, "access-control-allow-origin") != []

  defp allow_set(conn) do
    conn |> get_resp_header("allow") |> List.first() |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
  end

  defp allow(methods), do: MapSet.new(methods ++ ["OPTIONS"])
  defp bucket_rows, do: if(:ets.whereis(@bucket_table) == :undefined, do: [], else: :ets.tab2list(@bucket_table))

  defp assert_404(c, label) do
    assert c.status == 404, "#{label}: expected 404, got #{c.status} #{inspect(c.resp_body)}"
    assert json(c) == @unrecognized, label
    assert ctype(c) =~ "application/json", label
    assert cors?(c), "#{label}: access-control-allow-origin missing"
  end

  defp assert_405(c, methods, label) do
    assert c.status == 405, "#{label}: expected 405, got #{c.status} #{inspect(c.resp_body)}"
    assert json(c) == @unsupported, label
    assert allow_set(c) == allow(methods), "#{label}: Allow #{inspect(get_resp_header(c, "allow"))}"
    assert ctype(c) =~ "application/json", label
    assert cors?(c), "#{label}: access-control-allow-origin missing"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 / RU9, RU10, RU15 — unknown endpoints: 404 M_UNRECOGNIZED, no auth requirement
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8 — fall-throughs answer 404 M_UNRECOGNIZED for no token, a junk token and a valid token" do
    @protected_unknown [
      {:get, "/_matrix/client/v3/does_not_exist"},
      {:post, "/_matrix/client/v3/account/deactivate"},
      {:get, "/_matrix/client/v3/publicRooms"},
      {:get, "/_matrix/client/v3/versions"},
      {:get, "/_matrix/federation/v1/version"},
      {:get, "/_matrix/client/unstable/im.nheko.summary/summary/!r:s"}
    ]

    @media_unknown [
      {:get, "/_matrix/media/v3/config"},
      {:get, "/_matrix/media/v3/nope"},
      {:get, "/_matrix/client/v1/media/config"}
    ]

    @http_public_unknown [
      {:get, "/_matrix/client/v3/auth"},
      {:get, "/_matrix/client/v3/profile"},
      {:get, "/_matrix/client/v3/login/sso/unknown/x/y"},
      {:get, "/_matrix/client/v3/auth/m.login.password/fallback/web"}
    ]

    for {name, list} <- [protected: @protected_unknown, media: @media_unknown, http_public: @http_public_unknown] do
      test "AC8.#{name}: every listed path", %{valid: valid} do
        for {method, path} <- unquote(Macro.escape(list)), {mode, token} <- token_modes(valid) do
          assert_404(req(method, path, token), "#{method} #{path} (#{mode})")
        end
      end
    end

    test "AC8.4 unchanged: a non-Matrix unknown path keeps the plain 404 \"not found\"" do
      c = req(:get, "/nope")
      assert {c.status, c.resp_body} == {404, "not found"}
      # /admin is dispatched to the Admin endpoint (running in the integration environment, a plain 404
      # without it): either way never a Matrix M_UNRECOGNIZED answer.
      refute req(:get, "/admin").resp_body =~ "M_UNRECOGNIZED"
    end

    test "AC8.5: a junk token on an unknown path is no 401: no auth requirement, no token verdict in the answer" do
      # A junk token on an UNKNOWN path used to answer 401 M_UNKNOWN_TOKEN (OidcPlug ran before the match).
      # Unknown endpoints have no auth requirement (RU10): the answer is the plain 404 for everybody, with no
      # `WWW-Authenticate` challenge and no rate-limit hint. (The "no token lookup" claim is proven by
      # AC12.3: `authenticate/2` skips the OidcPlug for the marker, nothing else touches the token.)
      c = req(:get, "/_matrix/client/v3/does_not_exist", "junk-token")
      assert {c.status, json(c)} == {404, @unrecognized}
      assert get_resp_header(c, "www-authenticate") == []
      refute Map.has_key?(json(c), "retry_after_ms")
    end

    test "AC15: a fall-through writes no log line of its own" do
      assert capture_log(fn -> req(:get, "/_matrix/client/v3/does_not_exist", "junk-token") end) == ""
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8a / RU10a — POST /v3/register => 403 M_FORBIDDEN for everybody
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8a/RU10a — registration is not enabled" do
    test "POST /v3/register => 403 + body + JSON + CORS for no / junk / valid token and any body or kind; no bucket, no log", %{valid: valid} do
      for {mode, token} <- token_modes(valid),
          {suffix, body} <- [{"", "{}"}, {"", ~s({"username":"x","password":"y"})}, {"?kind=guest", "{}"}, {"", "not-json{"}] do
        log =
          capture_log(fn ->
            c = req(:post, "/_matrix/client/v3/register" <> suffix, token, body: body)
            send(self(), {:answer, c})
          end)

        assert_received {:answer, c}
        assert c.status == 403, "#{mode} #{suffix} #{body}: got #{c.status} #{inspect(c.resp_body)}"
        assert json(c) == @register_forbidden
        assert ctype(c) =~ "application/json"
        assert cors?(c)
        assert log == ""
      end

      assert bucket_rows() == [], "no register / login rate-limit bucket may be touched"
    end

    test "GET / PUT / DELETE on /v3/register => 405 + Allow: POST, OPTIONS; a non-preflight OPTIONS => 204 + Allow" do
      for method <- [:get, :put, :delete, :patch], do: assert_405(req(method, "/_matrix/client/v3/register"), ["POST"], "#{method} register")

      c = req(:options, "/_matrix/client/v3/register")
      assert c.status == 204
      assert allow_set(c) == allow(["POST"])
      assert cors?(c)
      assert bucket_rows() == []
    end

    test "sub-paths of /v3/register stay fall-throughs (404 M_UNRECOGNIZED)" do
      assert_404(req(:get, "/_matrix/client/v3/register/available?username=x"), "register/available")
      assert_404(req(:post, "/_matrix/client/v3/register/email/requestToken", nil, body: "{}"), "register/email/requestToken")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 / RU11 — unsupported methods => 405 + Allow, HEAD, OPTIONS
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10.1/AC10.4 — unsupported methods answer 405 M_UNRECOGNIZED + Allow (with and without a token)" do
    @method_table [
      {:put, "/_matrix/client/v3/sync", ["GET"]},
      {:put, "/_matrix/client/v3/room_keys/version", ["GET", "POST"]},
      {:delete, "/_matrix/client/v3/room_keys/version", ["GET", "POST"]},
      {:get, "/_matrix/client/v3/createRoom", ["POST"]},
      {:post, "/_matrix/client/v3/devices/X", ["GET", "PUT", "DELETE"]},
      {:put, "/_matrix/media/v3/upload", ["POST"]},
      {:delete, "/_matrix/client/v1/media/download/s/m", ["GET"]},
      {:post, "/_matrix/client/v3/login/sso/redirect/oidc", ["GET"]},
      {:delete, "/_matrix/client/v3/profile/@u:test.local/displayname", ["GET", "PUT"]}
    ]

    test "the table of the story", %{valid: valid} do
      for {method, path, methods} <- @method_table, {mode, token} <- token_modes(valid) do
        assert_405(req(method, path, token), methods, "#{method} #{path} (#{mode})")
      end
    end

    test "AC10.4: Allow lists exactly the methods that really route" do
      for {path, routed} <- [
            {"/_matrix/client/v3/sync", ["GET"]},
            {"/_matrix/client/v3/devices/X", ["GET", "PUT", "DELETE"]},
            {"/_matrix/client/v3/createRoom", ["POST"]},
            {"/_matrix/media/v3/upload", ["POST"]},
            {"/_matrix/client/v1/media/download/s/m", ["GET"]}
          ],
          method <- [:get, :put, :post, :delete, :patch] do
        c = req(method, path)
        verb = method |> Atom.to_string() |> String.upcase()

        if verb in routed do
          assert {c.status, json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{verb} #{path} is routed and must reach the auth gate"
        else
          assert_405(c, routed, "#{verb} #{path}")
        end
      end
    end
  end

  # RU11a (orchestrator decision of the pre-dev test review, M1): `GET /rooms/{id}/state` and
  # `GET /rooms/{id}/state/{type}[/{key}]` are NOT implemented (only the PUT state routes exist). Clients
  # (matrix-js-sdk getStateEvent, Element, Dart SDK) read `404 M_NOT_FOUND` as "state absent", so exactly
  # these GETs keep today's `404 M_NOT_FOUND "Unrecognized request"` (not M_UNRECOGNIZED, never a 405) until
  # follow-up bf implements them. Other methods on the paths follow the normal rules.
  describe "RU11a — GET on /rooms/{id}/state and /state/{type}[/{key}] keeps 404 M_NOT_FOUND" do
    @legacy_not_found %{"errcode" => "M_NOT_FOUND", "error" => "Unrecognized request"}

    test "GET /state, /state/{type}, /state/{type}/ and /state/{type}/{key} => 404 M_NOT_FOUND for no / junk / valid token", %{valid: valid} do
      for path <- [
            "/_matrix/client/v3/rooms/!r:test.local/state",
            "/_matrix/client/v3/rooms/!r:test.local/state/m.room.encryption",
            "/_matrix/client/v3/rooms/!r:test.local/state/m.room.name/",
            "/_matrix/client/v3/rooms/!r:test.local/state/m.room.member/@u:test.local"
          ],
          {mode, token} <- token_modes(valid) do
        c = req(:get, path, token)
        assert {c.status, json(c)} == {404, @legacy_not_found}, "GET #{path} (#{mode}): #{c.status} #{c.resp_body}"
        assert ctype(c) =~ "application/json"
        assert cors?(c)
      end
    end

    test "the carve-out is GET only and state only: DELETE on a routed PUT path => 405 + Allow: PUT; PUT keeps its auth gate" do
      for path <- ["/_matrix/client/v3/rooms/!r:test.local/state/m.room.name", "/_matrix/client/v3/rooms/!r:test.local/state/m.room.name/k"] do
        assert_405(req(:delete, path), ["PUT"], "DELETE #{path}")
        c = req(:put, path, nil, body: "{}")
        assert {c.status, json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "PUT #{path} is routed and authenticated"
      end

      # a GET on another unrouted path of the same router is NOT carved out
      assert_404(req(:get, "/_matrix/client/v3/rooms/!r:test.local/statex"), "GET rooms/{id}/statex")
      assert_404(req(:get, "/_matrix/client/v3/rooms/!r:test.local/nope"), "GET rooms/{id}/nope")
    end
  end

  describe "AC10.2/AC10.3 — HEAD and OPTIONS" do
    test "HEAD on a GET-only path answers 405 with an empty body" do
      c = req(:head, "/_matrix/client/v3/sync")
      assert c.status == 405
      assert c.resp_body == ""
      assert allow_set(c) == allow(["GET"])
      assert cors?(c)
    end

    test "a non-preflight OPTIONS on a known path answers 204 + Allow + CORS, never 401, no rate-limit token" do
      for {path, methods} <- [
            {"/_matrix/client/v3/sync", ["GET"]},
            {"/_matrix/client/v3/createRoom", ["POST"]},
            {"/_matrix/client/versions", ["GET"]},
            {"/_matrix/media/v3/upload", ["POST"]},
            {"/_matrix/client/v3/devices/X", ["GET", "PUT", "DELETE"]}
          ] do
        c = req(:options, path)
        assert c.status == 204, "#{path}: #{c.status}"
        assert allow_set(c) == allow(methods), path
        assert cors?(c), "#{path}: access-control-allow-origin missing"
      end

      assert bucket_rows() == []
    end

    test "a non-preflight OPTIONS on an unknown path answers 404 M_UNRECOGNIZED, never 405" do
      c = req(:options, "/_matrix/client/v3/does_not_exist")
      assert {c.status, json(c)} == {404, @unrecognized}
    end

    test "a CORS preflight is unchanged: 204 from CORSPlug, known or unknown path (Must #39 style)" do
      for path <- ["/_matrix/client/v3/sync", "/_matrix/client/v3/does_not_exist"] do
        c =
          conn(:options, path)
          |> put_req_header("origin", "https://app.example.com")
          |> put_req_header("access-control-request-method", "GET")
          |> put_req_header("access-control-request-headers", "authorization")
          |> Nebu.Web.Router.call(@router_opts)

        assert c.status == 204
        assert (c |> get_resp_header("access-control-allow-headers") |> List.first()) =~ ~r/authorization/i
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 / V19 — /_matrix/client/versions
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11 — /_matrix/client/versions answers 405 for every method but GET, in both OAuth states" do
    for {state, setup_fun} <- [enabled: :enable_oauth, disabled: :disable_oauth] do
      test "non-GET methods => 405 M_UNRECOGNIZED + Allow: GET, OPTIONS (OAuth #{state}, any Authorization)", %{valid: valid} do
        apply(T, unquote(setup_fun), [])

        for method <- [:post, :put, :delete, :patch, :head], {mode, token} <- token_modes(valid), path <- ["/_matrix/client/versions", "/_matrix/client/versions/"] do
          c = req(method, path, token)
          label = "#{method} #{path} (#{mode})"
          assert c.status == 405, "#{label}: got #{c.status}"
          assert allow_set(c) == allow(["GET"]), label
          assert cors?(c), label

          if method == :head,
            do: assert(c.resp_body == "", label),
            else: assert(json(c) == @unsupported, label)
        end
      end
    end

    test "/_matrix/client/v3/versions stays unrouted: 404 M_UNRECOGNIZED instead of 401 (RU16)", %{valid: valid} do
      for {_mode, token} <- token_modes(valid), do: assert_404(req(:get, "/_matrix/client/v3/versions", token), "v3/versions")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12 / RU10 — no route lost its authentication
  # ════════════════════════════════════════════════════════════════════════════

  # One entry per route clause of the three routers (clause pattern, params normalised to `:p`).
  @protected_clauses [
    {:get, "/client/v3/sync"},
    {:post, "/client/v3/logout"},
    {:post, "/client/v3/logout/all"},
    {:get, "/client/v3/account/whoami"},
    {:get, "/client/v3/thirdparty/protocols"},
    {:get, "/client/v3/voip/turnServer"},
    {:get, "/client/v3/room_keys/version"},
    {:post, "/client/v3/room_keys/version"},
    {:get, "/client/unstable/org.matrix.msc3814.v1/dehydrated_device"},
    {:get, "/client/unstable/org.matrix.msc4143/rtc/transports"},
    {:post, "/client/v3/keys/device_signing/upload"},
    {:get, "/client/v3/capabilities"},
    {:get, "/client/v3/pushrules/"},
    {:post, "/client/v3/keys/query"},
    {:post, "/client/v3/keys/signatures/upload"},
    {:post, "/client/v3/keys/upload"},
    {:get, "/client/v3/devices"},
    {:get, "/client/v3/devices/:p"},
    {:put, "/client/v3/devices/:p"},
    {:delete, "/client/v3/devices/:p"},
    {:post, "/client/v3/delete_devices"},
    {:post, "/client/v3/user/:p/filter"},
    {:get, "/client/v3/user/:p/filter/:p"},
    {:put, "/client/v3/user/:p/account_data/:p"},
    {:put, "/client/v3/user/:p/rooms/:p/account_data/:p"},
    {:get, "/client/v3/user/:p/rooms/:p/account_data/:p"},
    {:get, "/client/v3/user/:p/rooms/:p/tags"},
    {:put, "/client/v3/user/:p/rooms/:p/tags"},
    {:delete, "/client/v3/user/:p/rooms/:p/tags"},
    {:put, "/client/v3/user/:p/rooms/:p/tags/:p"},
    {:delete, "/client/v3/user/:p/rooms/:p/tags/:p"},
    {:get, "/client/v3/user/:p/account_data/:p"},
    {:post, "/client/v3/createRoom"},
    {:post, "/client/v3/join/:p"},
    {:post, "/client/v3/rooms/:p/invite"},
    # story moderation-routes-atomic-ban (DELIBERATE re-pin: three new route clauses, behind the same auth plug)
    {:post, "/client/v3/rooms/:p/kick"},
    {:post, "/client/v3/rooms/:p/ban"},
    {:post, "/client/v3/rooms/:p/unban"},
    {:put, "/client/v3/rooms/:p/send/:p/:p"},
    # story state-writer-redaction (DELIBERATE re-pin, test review STORY-1; old -> new): one new route clause, behind the same auth plug (before: unrouted, answered by the fall-through)
    {:put, "/client/v3/rooms/:p/redact/:p/:p"},
    {:get, "/client/v3/rooms/:p/messages"},
    {:get, "/client/v3/rooms/:p/initialSync"},
    {:put, "/client/v3/rooms/:p/typing/:p"},
    {:post, "/client/v3/rooms/:p/receipt/:p/:p"},
    {:get, "/client/v3/presence/:p/status"},
    {:put, "/client/v3/presence/:p/status"},
    {:post, "/client/v3/rooms/:p/leave"},
    {:post, "/client/v3/rooms/:p/forget"},
    {:get, "/client/v1/rooms/:p/relations/:p"},
    {:get, "/client/v1/rooms/:p/relations/:p/:p"},
    {:get, "/client/v1/rooms/:p/relations/:p/:p/:p"},
    {:get, "/client/v1/rooms/:p/hierarchy"},
    {:get, "/client/v1/mutual_rooms"},
    {:get, "/client/unstable/uk.half-shot.msc2666/user/mutual_rooms"},
    {:get, "/client/v3/rooms/:p/members"},
    {:get, "/client/v3/rooms/:p/event/:p"},
    {:post, "/client/v3/rooms/:p/read_markers"},
    {:post, "/client/v3/rooms/:p/upgrade"},
    {:post, "/client/v3/search"},
    {:put, "/client/v3/profile/:p/displayname"},
    {:put, "/client/v3/profile/:p/avatar_url"},
    {:put, "/client/v3/rooms/:p/state/:p/:p"},
    {:put, "/client/v3/rooms/:p/state/:p"},
    # story oauth-room-summary-unrecognized (ac): the new route
    {:get, "/client/v1/room_summary/:p"}
  ]

  @media_clauses [
    {:post, "/v3/upload"},
    {:put, "/v3/upload/:p/:p"},
    {:post, "/v1/create"},
    {:get, "/v3/download/:p/:p/:p"},
    {:get, "/v3/download/:p/:p"},
    {:get, "/v3/thumbnail/:p/:p"},
    {:get, "/v3/preview_url"}
  ]

  @client_v1_media_clauses [
    {:get, "/download/:p/:p/:p"},
    {:get, "/download/:p/:p"},
    {:get, "/thumbnail/:p/:p"}
  ]

  @routers [
    {"Protected", "lib/nebu/web/router/protected.ex", "/_matrix", @protected_clauses},
    {"Media", "lib/nebu/web/router/media.ex", "/_matrix/media", @media_clauses},
    {"ClientV1Media", "lib/nebu/web/router/client_v1_media.ex", "/_matrix/client/v1/media", @client_v1_media_clauses}
  ]

  # The source without heredocs / docstrings (comment lines never start with a macro name, so the line
  # regexes below skip them).
  defp source_without_heredocs(rel) do
    path = Path.expand("../../../" <> rel, __DIR__)
    Regex.replace(~r/"""[\s\S]*?"""/, File.read!(path), "")
  end

  defp source_clauses(rel) do
    ~r/^\s*(get|post|put|delete|patch)\s+"([^"]+)"/m
    |> Regex.scan(source_without_heredocs(rel))
    |> Enum.map(fn [_, m, p] -> {String.to_atom(m), Regex.replace(~r/:\w+/, p, ":p")} end)
  end

  # AC12 guard (review m7): any route macro that the clause regex above would NOT count (`match`, `options`,
  # `head`, `forward`, a parenthesised `get("/x")`) would add a route this test never exercises. The ONLY
  # accepted exception is the catch-all `match _`.
  defp uncounted_route_macros(rel) do
    for line <- String.split(source_without_heredocs(rel), "\n"),
        line =~ ~r/^\s*(match|options|head|forward|get|post|put|delete|patch)\s*(\(|\s+["~:@\[\w_])/,
        not (line =~ ~r/^\s*(get|post|put|delete|patch)\s+"/),
        not (line =~ ~r/^\s*match\s+_\s*(,|do)/),
        do: String.trim(line)
  end

  describe "AC12.1/AC12.2 — every route clause still answers 401 M_MISSING_TOKEN without a token" do
    for {name, rel, prefix, clauses} <- @routers do
      test "#{name}: one unauthenticated request per clause" do
        for {method, pattern} <- unquote(Macro.escape(clauses)) do
          path = unquote(prefix) <> Regex.replace(~r/:p/, pattern, "X1")
          c = req(method, path)
          assert {c.status, json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}, "#{method} #{path}: got #{c.status} #{inspect(c.resp_body)}"
        end
      end

      test "#{name}: the list above is exactly the set of route clauses in the source" do
        listed = unquote(Macro.escape(clauses))
        found = source_clauses(unquote(rel))

        assert length(found) == length(listed), "#{unquote(name)}: #{length(found)} clauses in source, #{length(listed)} listed"
        assert Enum.sort(found) == Enum.sort(listed)
      end

      test "#{name}: no other route macro (match / options / head / forward / parenthesised verb) besides the catch-all" do
        assert uncounted_route_macros(unquote(rel)) == []
      end
    end
  end

  describe "AC12.3 — :authenticate skips the OidcPlug ONLY for the boolean marker true" do
    for mod <- ["Protected", "Media", "ClientV1Media"] do
      test "#{mod}.authenticate/2: absent, false and \"true\" run the OidcPlug (401); true does not" do
        mod = Module.concat(["Nebu", "Web", "Router", unquote(mod)])

        for marker <- [:absent, false, "true", nil, 1] do
          c = conn(:get, "/x")
          c = if marker == :absent, do: c, else: put_private(c, :nebu_unrecognized, marker)
          out = apply(mod, :authenticate, [c, []])
          assert out.halted, "marker #{inspect(marker)} must not skip authentication"
          assert {out.status, Jason.decode!(out.resp_body)["errcode"]} == {401, "M_MISSING_TOKEN"}
        end

        out = apply(mod, :authenticate, [put_private(conn(:get, "/x"), :nebu_unrecognized, true), []])
        refute out.halted
        assert out.status == nil
      end
    end
  end

  describe "AC12.4 — profile PUT keeps its authentication" do
    test "PUT /v3/profile/{u}/displayname without a token => 401 M_MISSING_TOKEN" do
      c = req(:put, "/_matrix/client/v3/profile/@unrec-user:test.local/displayname", nil, body: ~s({"displayname":"x"}))
      assert {c.status, json(c)["errcode"]} == {401, "M_MISSING_TOKEN"}
    end
  end

  describe "shared responses (Nebu.Web.Unrecognized)" do
    test "not_found/1, method_not_allowed/2 and options/2 build the RU15 answers" do
      nf = Nebu.Web.Unrecognized.not_found(conn(:get, "/_matrix/x"))
      assert {nf.status, Jason.decode!(nf.resp_body)} == {404, @unrecognized}
      assert ctype(nf) =~ "application/json"

      na = Nebu.Web.Unrecognized.method_not_allowed(conn(:put, "/_matrix/x"), ["GET", "POST"])
      assert {na.status, Jason.decode!(na.resp_body)} == {405, @unsupported}
      assert allow_set(na) == allow(["GET", "POST"])

      op = Nebu.Web.Unrecognized.options(conn(:options, "/_matrix/x"), ["GET"])
      assert op.status == 204
      assert allow_set(op) == allow(["GET"])
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC13 / RU13 — HttpPublic root by forward prefix
  # ════════════════════════════════════════════════════════════════════════════

  # AC13.1, measured on 671ea2e8 BEFORE the change (OAuth disabled, `{}` body): every one of
  # `POST /v3/auth`, `POST /v3/profile`, `POST /v1/auth_issuer`, `POST unstable/org.matrix.msc2965/auth_issuer`
  # and `.../auth_metadata` answered `400 M_UNKNOWN "Unsupported login type"` (do_login ran: the pre-existing
  # bug); `PUT /login` and `GET /refresh` answered `404 M_NOT_FOUND "Not found"`.
  describe "AC13 — HttpPublic root table (login GET POST, refresh POST, discovery GET, auth/profile none)" do
    test "POST /v3/auth and /v3/profile => 404 M_UNRECOGNIZED (they used to attempt a login)", %{valid: valid} do
      for path <- ["/_matrix/client/v3/auth", "/_matrix/client/v3/profile"], {mode, token} <- token_modes(valid) do
        log = capture_log(fn -> send(self(), {:a, req(:post, path, token, body: ~s({"type":"m.login.password"}))}) end)
        assert_received {:a, c}
        assert_404(c, "POST #{path} (#{mode})")
        assert log == "", "no login log line"
      end

      assert bucket_rows() == [], "the login bucket is untouched"
    end

    test "POST on legacy discovery paths (OAuth disabled) => 405 + Allow: GET, OPTIONS" do
      T.disable_oauth()

      for path <- ["/_matrix/client/v1/auth_issuer", "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer", "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata"] do
        log = capture_log(fn -> send(self(), {:a, req(:post, path, nil, body: "{}")}) end)
        assert_received {:a, c}
        assert_405(c, ["GET"], "POST #{path}")
        assert log == ""
      end

      assert bucket_rows() == []
    end

    test "wrong methods on /login (Allow GET, POST) and /refresh (Allow POST) => 405" do
      for method <- [:put, :delete, :patch], do: assert_405(req(method, "/_matrix/client/v3/login", nil, body: "{}"), ["GET", "POST"], "#{method} login")
      for method <- [:get, :put, :delete], do: assert_405(req(method, "/_matrix/client/v3/refresh"), ["POST"], "#{method} refresh")
      assert bucket_rows() == [], "neither do_login nor do_refresh was reached"
    end

    test "non-root HttpPublic paths use the probe: wrong method on SSO / UIA GET routes => 405" do
      assert_405(req(:post, "/_matrix/client/v3/login/sso/redirect"), ["GET"], "POST sso/redirect")
      assert_405(req(:post, "/_matrix/client/v3/auth/m.login.sso/fallback/web"), ["GET"], "POST uia fallback")
    end

    test "a trailing slash does not change the root table: GET /login/ lists flows, GET /refresh/ => 405 Allow POST (review cycle 1, MINOR 1)" do
      c = req(:get, "/_matrix/client/v3/login/")
      assert c.status == 200
      assert is_list(json(c)["flows"])

      assert_405(req(:get, "/_matrix/client/v3/refresh/"), ["POST"], "GET refresh/")
      assert_405(req(:put, "/_matrix/client/v3/login/", nil, body: "{}"), ["GET", "POST"], "PUT login/")

      # legacy discovery with a trailing slash, OAuth disabled: reaches the discovery handler, never a 405
      T.disable_oauth()
      refute req(:get, "/_matrix/client/v1/auth_issuer/").status == 405
    end

    test "AC13.3 unchanged: GET /login lists flows, POST /login and /refresh reach their handlers" do
      c = req(:get, "/_matrix/client/v3/login")
      assert c.status == 200
      assert is_list(json(c)["flows"])

      # Measured on 671ea2e8 (AC13.1) and unchanged by the story: an empty JSON object is rejected by the
      # LOGIN handler itself ("Unsupported login type") and by the REFRESH handler (refresh_token missing).
      login = req(:post, "/_matrix/client/v3/login", nil, body: "{}")
      assert {login.status, json(login)} == {400, %{"errcode" => "M_UNKNOWN", "error" => "Unsupported login type"}}
      refresh = req(:post, "/_matrix/client/v3/refresh", nil, body: "{}")
      assert {refresh.status, json(refresh)} == {400, %{"errcode" => "M_MISSING_PARAM", "error" => "refresh_token is required"}}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC14 / RU14 — OAuth discovery methods while OAuth is live
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14 — non-GET on auth_metadata / auth_issuer" do
    @discovery [
      "/_matrix/client/v1/auth_metadata",
      "/_matrix/client/v1/auth_issuer",
      "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata",
      "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer"
    ]

    test "OAuth live: POST / PUT / DELETE => 405 M_UNRECOGNIZED + Allow: GET, OPTIONS" do
      T.enable_oauth()

      for path <- @discovery, method <- [:post, :put, :delete] do
        c = req(method, path, nil, body: "{}")
        assert c.status == 405, "#{method} #{path}: #{c.status}"
        assert json(c)["errcode"] == "M_UNRECOGNIZED"
        assert allow_set(c) == allow(["GET"]), path
        assert ctype(c) =~ "application/json"
      end
    end

    test "OAuth disabled or an invalid issuer: POST answers the 404 M_UNRECOGNIZED it answers today (v1 paths)" do
      for set <- [fn -> T.disable_oauth() end, fn -> T.enable_oauth("http://nebu.example.com") end] do
        set.()

        for path <- ["/_matrix/client/v1/auth_metadata"] do
          T.assert_unrecognized_404(req(:post, path, nil, body: "{}"))
        end
      end
    end

    test "GET is unchanged while live (200)" do
      T.enable_oauth()
      assert req(:get, "/_matrix/client/v1/auth_metadata").status == 200
      assert req(:get, "/_matrix/client/v1/auth_issuer").status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # story legacy-sso-redirect-confirmation (G3-3), AC12: the confirmation page route
  # `/_matrix/client/v3/login/sso/confirm` (GET renders, POST decides) is browser navigation: no CORSPlug, so no
  # `access-control-*` header at all (also not on the fall-through answers) and a preflight is not answered.
  # ════════════════════════════════════════════════════════════════════════════

  describe "legacy-sso-redirect-confirmation AC12 — /_matrix/client/v3/login/sso/confirm" do
    @confirm "/_matrix/client/v3/login/sso/confirm"

    defp no_cors?(c), do: not Enum.any?(c.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)

    test "PUT / DELETE / PATCH on the exact path => 405 M_UNRECOGNIZED + Allow: GET, POST, OPTIONS; no CORS header", %{valid: valid} do
      for method <- [:put, :delete, :patch], {mode, token} <- token_modes(valid) do
        c = req(method, @confirm, token, body: "{}")
        assert c.status == 405, "#{method} (#{mode}): #{c.status} #{inspect(c.resp_body)}"
        assert json(c) == @unsupported
        assert allow_set(c) == allow(["GET", "POST"]), "Allow: #{inspect(get_resp_header(c, "allow"))}"
        assert no_cors?(c), "no access-control-* header on the confirm route (browser navigation)"
      end
    end

    test "HEAD => 405 with an empty body and the same Allow" do
      c = req(:head, @confirm)
      assert c.status == 405
      assert c.resp_body == ""
      assert allow_set(c) == allow(["GET", "POST"])
    end

    test "a non-preflight OPTIONS => 204 + the same Allow" do
      c = conn(:options, @confirm) |> Map.put(:remote_ip, T.unique_ip()) |> Nebu.Web.Router.call(@router_opts)
      assert c.status == 204
      assert allow_set(c) == allow(["GET", "POST"])
    end

    test "a CORS preflight is not answered by CORSPlug: 204 + Allow GET, POST, and none of the CORS grant headers" do
      c =
        conn(:options, @confirm)
        |> put_req_header("origin", "https://app.example.com")
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "content-type")
        |> Map.put(:remote_ip, T.unique_ip())
        |> Nebu.Web.Router.call(@router_opts)

      # the shared Unrecognized.options/2 may add `access-control-allow-origin: *` (a bare OPTIONS answer); what a
      # preflight needs to GRANT a cross-origin request must never appear on this browser-navigation route
      assert c.status == 204
      assert allow_set(c) == allow(["GET", "POST"])

      for h <- ~w(access-control-allow-methods access-control-allow-headers access-control-allow-credentials access-control-max-age access-control-expose-headers) do
        assert get_resp_header(c, h) == [], "#{h} must not be answered on the confirm route: #{inspect(c.resp_headers)}"
      end
    end

    test "a sub-path => 404 M_UNRECOGNIZED" do
      for path <- [@confirm <> "/x", @confirm <> "/a/b"] do
        c = req(:get, path)
        assert {c.status, json(c)} == {404, @unrecognized}, path
      end
    end

    test "no token is required and none is looked at: a junk Bearer token does not change the answer (RU10)" do
      c = req(:put, @confirm, "junk-token", body: "{}")
      assert c.status == 405
      assert get_resp_header(c, "www-authenticate") == []
    end

    test "the sibling paths are unchanged: /sso/redirect/confirm is an idp id, /sso/unknown/x/y stays 404" do
      assert_404(req(:get, "/_matrix/client/v3/login/sso/unknown/x/y"), "sso/unknown/x/y")
      # a POST on the callback keeps its 405 (the new route did not widen the redirect routes)
      assert_405(req(:post, "/_matrix/client/v3/login/sso/redirect/oidc"), ["GET"], "POST sso/redirect/oidc")
    end
  end
end
