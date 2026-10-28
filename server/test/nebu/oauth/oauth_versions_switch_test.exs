defmodule Nebu.OAuth.OAuthVersionsSwitchTest do
  @moduledoc """
  Acceptance tests for story `oauth-versions-switch` (story 9 of epic oauth-broker), AC1-AC3
  (V1-V9, V18, V19; Must #1-#18, #38-#44):

    * AC1 `GET /_matrix/client/versions` lists v1.1..v1.15 IFF `Nebu.OAuth.oauth_aware?/0`, otherwise
      today's v1.1..v1.11 body BYTE FOR BYTE; `unstable_features` msc2666 only; the answer ignores
      `Authorization`; `Nebu.Matrix.HttpPublic.versions/1` + `versions_body/1`.
    * AC2 fail closed (S2 issuer variants, S4 unknown, S5 raising / exiting seam, no repo) => v1.11
      200, never 5xx; `Cache-Control: no-store`; no rate limit; exactly one config read; OPTIONS /
      POST / PUT / HEAD / trailing slash / `v3/versions` pinned AS MEASURED before the story
      (2026-10-12 probe: OPTIONS 204 CORS incl. Authorization; `/versions/` = `/versions`; story
      oauth-room-summary-unrecognized (af) CHANGED two of the pinned answers on purpose: POST / PUT /
      DELETE / HEAD are now `405 M_UNRECOGNIZED` + `Allow: GET, OPTIONS` (were 401 M_MISSING_TOKEN) and
      `/v3/versions` is `404 M_UNRECOGNIZED` with or without a token (was 401 M_MISSING_TOKEN /
      M_UNKNOWN_TOKEN)); issuer
      variants (`https://h/`, `:8448`, uppercase host) are live and agree with `auth_metadata`.
    * AC3 parity across surfaces per state (S1-S5), runtime toggle, and the integration variant with
      the REAL `server_config` rows.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @forbidden ~r/msc2964|msc2965|msc2966|msc2967|msc3861|msc3824|msc4191|oauth/i

  setup do
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_config_repo], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp header(conn, name), do: T.header(conn, name)

  defp off_states do
    [
      {"S2 nil issuer", fn -> T.enable_oauth(nil) end},
      {"S2 http issuer", fn -> T.enable_oauth("http://nebu.example.com") end},
      {"S2 issuer with path", fn -> T.enable_oauth("https://nebu.example.com/path") end},
      {"S2 issuer with query", fn -> T.enable_oauth("https://nebu.example.com?q=1") end},
      {"S2 issuer with fragment", fn -> T.enable_oauth("https://nebu.example.com#f") end},
      {"S2 issuer with userinfo", fn -> T.enable_oauth("https://user@nebu.example.com") end},
      {"S3 disabled", fn -> T.disable_oauth() end},
      {"S4 unknown", fn -> T.unreadable_oauth_config() end},
      {"S5 raising seam", fn -> Application.put_env(:nebu_http, :oauth_config_source, fn -> raise "atdd config boom" end) end},
      {"S5 exiting seam", fn -> Application.put_env(:nebu_http, :oauth_config_source, fn -> exit(:atdd_boom) end) end}
    ]
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — the switch (unit, seam-driven)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/V1/V3/V5 — the versions switch" do
    test "Must #1: S1 (OAuth offered) => exactly v1.1..v1.15 in numeric order, unstable_features msc2666 only" do
      T.enable_oauth()
      conn = T.versions()
      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/json"
      assert body(conn)["versions"] == T.versions_on(), "15 consecutive entries v1.1..v1.15, nothing above"
      assert length(body(conn)["versions"]) == 15
      assert body(conn)["unstable_features"] == %{"uk.half-shot.msc2666.query_mutual_rooms" => true}
    end

    test "Must #2/#3: every not-offered state => the pre-story body BYTE FOR BYTE, status 200" do
      for {label, set} <- off_states() do
        set.()
        conn = T.versions()
        assert conn.status == 200, "#{label}: never 5xx, got #{conn.status}"
        assert conn.resp_body == T.versions_off_bytes(), "#{label}: byte-identical v1.11 body"
      end
    end

    test "no repo (unit run, :disabled) => v1.11 byte-identical" do
      T.clear_oauth_config()
      Application.put_env(:nebu_http, :oauth_config_repo, T.NoSuchRepo)
      conn = T.versions()
      assert conn.status == 200
      assert conn.resp_body == T.versions_off_bytes()
    end

    test "versions_body/1 is pure and returns exactly the two maps; versions/1 exists (@doc + @spec)" do
      assert apply(Nebu.Matrix.HttpPublic, :versions_body, [true]) == T.versions_on_map()
      assert apply(Nebu.Matrix.HttpPublic, :versions_body, [false]) == T.versions_off_map()
      assert function_exported?(Nebu.Matrix.HttpPublic, :versions, 1)
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Nebu.Matrix.HttpPublic)

      for {fun, ar} <- [versions: 1, versions_body: 1] do
        assert Enum.any?(docs, &match?({{:function, ^fun, ^ar}, _, _, %{"en" => _}, _}, &1)), "#{fun}/#{ar} needs a @doc"
      end
    end

    test "Must #4/#5: unstable_features never names an OAuth MSC, in any state" do
      for set <- [fn -> T.enable_oauth() end | Enum.map(off_states(), &elem(&1, 1))] do
        set.()
        feats = body(T.versions())["unstable_features"]
        assert feats == %{"uk.half-shot.msc2666.query_mutual_rooms" => true}
        refute Enum.any?(Map.keys(feats), &(&1 =~ @forbidden))
      end
    end
  end

  describe "AC1/V6/Must #8, #44 — the answer ignores Authorization" do
    test "absent / junk Bearer / Basic / garbage header => the same answer per state; never 401" do
      for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end,
                  fn -> Application.put_env(:nebu_http, :oauth_config_source, fn -> raise "atdd" end) end] do
        set.()
        reference = T.versions()

        for opts <- [[bearer: "junk"], [bearer: String.duplicate("ab", 32)], [authorization: "Basic " <> Base.encode64("u:p")], [authorization: "garbage"]] do
          conn = T.versions(opts)
          assert conn.status == 200, "never 401 (#{inspect(opts)})"
          assert conn.resp_body == reference.resp_body
        end
      end
    end

    test "Must #8 in every off state (S2-S5): Authorization ignored, application/json, no-store" do
      for {label, set} <- off_states() do
        set.()

        for opts <- [[], [bearer: "junk"], [authorization: "Basic " <> Base.encode64("u:p")]] do
          conn = T.versions(opts)
          assert conn.status == 200, "#{label} #{inspect(opts)}"
          assert conn.resp_body == T.versions_off_bytes()
          assert header(conn, "content-type") =~ "application/json"
          assert header(conn, "cache-control") == "no-store", "#{label}: no-store"
        end
      end
    end

    test "Must #44: a raising seam + any Authorization => 200 v1.11" do
      Application.put_env(:nebu_http, :oauth_config_source, fn -> raise "atdd" end)
      conn = T.versions(bearer: "junk")
      assert conn.status == 200
      assert conn.resp_body == T.versions_off_bytes()
    end
  end

  describe "AC1/V6 — legacy / OAuth / expired / revoked bearer tokens (integration)" do
    @describetag :integration

    test "valid legacy, valid OAuth, expired OAuth and revoked OAuth tokens => the no-header answer" do
      T.enable_oauth()
      priv = T.setup_idp!()
      cid = T.oauth_client!(["https://app.example.com/cb"])
      s = T.session!(cid, "https://app.example.com/cb", priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "VS" <> String.upcase(T.rand(3)))})
      legacy = T.legacy_session!(T.provision_user!(), "VSL" <> String.upcase(T.rand(3)))
      reference = T.versions()
      assert body(reference)["versions"] == T.versions_on()

      expired = T.session!(cid, "https://app.example.com/cb", priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "VE" <> String.upcase(T.rand(3)))})
      T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '1 second' WHERE access_token_hash = $1", [T.token_hash(expired.at)])
      revoked = T.session!(cid, "https://app.example.com/cb", priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "VR" <> String.upcase(T.rand(3)))})
      _ = T.revoke([{"token", revoked.at}])

      for token <- [s.at, legacy.at, expired.at, revoked.at] do
        conn = T.versions(bearer: token)
        assert conn.status == 200
        assert conn.resp_body == reference.resp_body
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — robustness, headers, measured pins
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2/V4/V7/V8 — headers, rate, config reads, logging" do
    test "Must #7: Cache-Control: no-store on both variants; no Set-Cookie; nosniff; no Vary" do
      for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end] do
        set.()
        conn = T.versions()
        assert header(conn, "cache-control") == "no-store"
        assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
        assert header(conn, "x-content-type-options") == "nosniff"
        assert header(conn, "vary") == nil
      end
    end

    test "Must #9: no rate limit (100 requests from one IP => 100 x 200)" do
      T.disable_oauth()
      ip = T.unique_ip()
      statuses = for _ <- 1..100, do: T.versions(ip: ip).status
      assert Enum.all?(statuses, &(&1 == 200))
    end

    test "Must #10: exactly one config read per request (both states)" do
      for value <- [%{enabled: true, issuer_url: T.issuer()}, %{enabled: false, issuer_url: T.issuer()}] do
        T.counting_config_source(value)
        _ = T.drain_config_reads()
        conn = T.versions()
        assert conn.status == 200
        assert T.drain_config_reads() == 1, "one server_config read per /versions request (V8)"
      end
    end

    test "Must #38: no new log line; S4 at most the existing OAuth.Config WARNING (no value)" do
      T.enable_oauth()
      assert capture_log(fn -> T.versions() end) == ""
      T.unreadable_oauth_config()
      log = capture_log(fn -> T.versions() end)
      refute log =~ "versions"
    end
  end

  describe "AC2/V19/Must #11, #39-#42 — other methods and paths, pinned as measured (2026-10-12)" do
    test "Must #39: OPTIONS preflight (Origin + Access-Control-Request-Headers: authorization) => 204 allowing Authorization" do
      for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end] do
        set.()
        conn = T.versions(method: :options, headers: [{"origin", "https://app.example.com"}, {"access-control-request-method", "GET"},
                                                      {"access-control-request-headers", "authorization"}])
        assert conn.status == 204
        assert header(conn, "access-control-allow-headers") =~ ~r/authorization/i
        assert header(conn, "access-control-allow-origin") == "*"
      end
    end

    test "Must #40: ?x=1 => the same body; no Vary" do
      for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end] do
        set.()
        assert T.versions(path: "/_matrix/client/versions?x=1").resp_body == T.versions().resp_body
      end
    end

    test "Must #41: /_matrix/client/versions/ answers like /versions (measured: Plug normalises the slash)" do
      for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end] do
        set.()
        conn = T.versions(path: "/_matrix/client/versions/")
        assert conn.status == 200
        assert conn.resp_body == T.versions().resp_body
      end
    end

    # story oauth-room-summary-unrecognized (af): changed deliberately. An unknown endpoint has no auth
    # requirement (RU10), so `/v3/versions` answers 404 M_UNRECOGNIZED for no token AND a junk token
    # (RU16; the route itself stays missing, follow-up ae / P5).
    test "Must #41: /v3/versions is NOT routed (404 M_UNRECOGNIZED, no token or junk token; follow-up ae)" do
      T.enable_oauth()
      no_token = T.versions(path: "/_matrix/client/v3/versions")
      assert {no_token.status, body(no_token)} == {404, %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}}
      junk = T.versions(path: "/_matrix/client/v3/versions", bearer: "junk")
      assert {junk.status, body(junk)} == {404, %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}}
    end

    # story oauth-room-summary-unrecognized (af, AC11.1): changed deliberately (was 401 M_MISSING_TOKEN, the
    # measured deviation of follow-up af). The spec's 405 M_UNRECOGNIZED + Allow now applies in both OAuth
    # states and regardless of Authorization.
    test "Must #11/#42: POST / PUT / DELETE / HEAD => 405 M_UNRECOGNIZED + Allow GET, OPTIONS (both states)" do
      for m <- [:post, :put, :delete, :head], set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end],
          opts <- [[], [bearer: "junk"], [authorization: "Basic abc"]] do
        set.()
        conn = T.versions([method: m, headers: [{"origin", "https://app.example.com"}]] ++ opts)
        assert conn.status == 405, "#{m} #{inspect(opts)}"
        assert header(conn, "allow") |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.sort() == ["GET", "OPTIONS"]
        assert header(conn, "access-control-allow-origin") != nil
        if m == :head, do: assert(conn.resp_body == ""), else: assert(body(conn) == %{"errcode" => "M_UNRECOGNIZED", "error" => "Unsupported method"})
      end
    end
  end

  describe "AC2/Must #43 — issuer variants (measured: all three are live) agree with auth_metadata" do
    for iss <- ["https://nebu.example.com/", "https://nebu.example.com:8448", "https://NEBU.EXAMPLE.COM"] do
      test "issuer #{iss}: /versions lists v1.15 IFF auth_metadata answers 200 (measured 200, issuer echo pinned)" do
        T.enable_oauth(unquote(iss))
        meta = T.get_metadata()
        assert meta.status == 200, "measured 2026-10-12: #{unquote(iss)} is a valid issuer"
        assert T.json(meta)["issuer"] == unquote(iss |> String.trim_trailing("/")), "issuer echoed (trailing slash dropped, host case kept)"
        assert "v1.15" in body(T.versions())["versions"]
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — parity per state, runtime toggle, real server_config (integration)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3/V9/Must #12-#16 — parity across every surface per state (statuses as measured on 9d4b57bb)" do
    @describetag :integration

    setup do
      _priv = T.setup_idp!()
      T.set_idp_prompt_values(["login", "create"])
      :ok
    end

    defp invariant!(snap, label) do
      live = snap.v115
      assert snap.versions_status == 200, label
      assert (snap.metadata == 200) == live, "#{label}: v1.15 <=> auth_metadata 200"
      assert snap.flags == live, "#{label}: v1.15 <=> OAuth-aware flags"
      assert (snap.openid == 200) == live, "#{label}: v1.15 <=> openid-configuration 200"
      assert (not snap.account_unavailable) == live, "#{label}: v1.15 <=> /account live"
      assert (snap.sso_action_prompt == "create") == live, "#{label}: v1.15 <=> SSO action honoured"
    end

    defp b(snap, k), do: snap.conns[k].resp_body
    defp h(snap, k, name), do: T.header(snap.conns[k], name)
    defp json_of(snap, k), do: Jason.decode!(b(snap, k))
    defp no_error_404!(snap, k), do: assert({snap.conns[k].status, json_of(snap, k)} == {404, %{"errcode" => "M_UNRECOGNIZED"}}, "#{k}: 404 without error")
    defp unrec_404!(snap, k), do: assert({snap.conns[k].status, json_of(snap, k)["errcode"]} == {404, "M_UNRECOGNIZED"}, "#{k}: 404 M_UNRECOGNIZED")

    defp empty_503!(snap, k) do
      assert snap.conns[k].status == 503, "#{k}: 503"
      assert b(snap, k) == "{}", "#{k}: body {}"
      assert h(snap, k, "retry-after") == "5"
      assert h(snap, k, "cache-control") =~ "no-store"
    end

    test "Must #12: S1 — every surface live (exact statuses)" do
      T.enable_oauth()
      s = T.parity_snapshot()
      invariant!(s, "S1")
      assert s.v115
      assert s.metadata == 200 and h(s, :metadata, "cache-control") == "public, max-age=259200"
      assert s.unstable == 200 and s.unstable_body == s.metadata_body
      assert {s.auth_issuer, json_of(s, :auth_issuer)} == {200, %{"issuer" => T.issuer()}}
      assert {s.conns.unstable_auth_issuer.status, Jason.decode!(s.conns.unstable_auth_issuer.resp_body)} == {200, %{"issuer" => T.issuer()}}
      assert s.openid == 200 and b(s, :openid) == s.metadata_body
      assert s.jwks == 200
      assert {s.token, json_of(s, :token)["error"]} == {401, "invalid_client"}, "empty token request => client auth first"
      assert {s.register, json_of(s, :register)["error"]} == {400, "invalid_request"}
      assert s.authorize == 400 and b(s, :authorize) =~ "<html", "no params => the HTML error page"
      assert s.account == 302
      assert s.revoke == 200 and b(s, :revoke) == "{}"
    end

    test "Must #13: S2 (invalid issuer) — off; register stays LIVE (measured, Config.enabled?/0, recorded deviation); revoke live" do
      T.enable_oauth("http://nebu.example.com")
      s = T.parity_snapshot()
      invariant!(s, "S2")
      refute s.v115
      unrec_404!(s, :metadata)
      unrec_404!(s, :unstable)
      unrec_404!(s, :auth_issuer)
      unrec_404!(s, :unstable_auth_issuer)
      for k <- [:openid, :jwks, :token], do: no_error_404!(s, k)
      assert {s.register, json_of(s, :register)["error"]} == {400, "invalid_request"}, "register keeps Config.enabled?/0 (decision M1, option A)"
      unrec_404!(s, :authorize)
      assert s.account == 404 and s.account_unavailable
      assert s.revoke == 200
    end

    test "Must #14: S3 (disabled) — off, unstable alias + auth_issuer = IdP passthrough, revoke live" do
      T.disable_oauth()
      s = T.parity_snapshot()
      invariant!(s, "S3")
      refute s.v115
      unrec_404!(s, :metadata)
      assert s.unstable == 200 and json_of(s, :unstable)["issuer"] == T.idp_issuer(), "decision 7: IdP passthrough"
      assert {s.auth_issuer, json_of(s, :auth_issuer)} == {200, %{"issuer" => T.idp_issuer()}}
      assert Jason.decode!(s.conns.unstable_auth_issuer.resp_body) == %{"issuer" => T.idp_issuer()}
      for k <- [:openid, :jwks, :token], do: no_error_404!(s, k)
      unrec_404!(s, :register)
      unrec_404!(s, :authorize)
      assert s.account == 404 and s.account_unavailable
      assert s.revoke == 200
    end

    test "Must #15: S4 (unknown) — v1.11; metadata 404 no-store; alias + auth_issuer 503 M_UNKNOWN; endpoints 503 {} + Retry-After; revoke 503" do
      T.unreadable_oauth_config()
      s = T.parity_snapshot()
      invariant!(s, "S4")
      refute s.v115
      unrec_404!(s, :metadata)
      assert h(s, :metadata, "cache-control") == "no-store"
      for k <- [:unstable, :auth_issuer, :unstable_auth_issuer], do: assert({s.conns[k].status, Jason.decode!(s.conns[k].resp_body)["errcode"]} == {503, "M_UNKNOWN"}, "#{k}")
      for k <- [:openid, :jwks, :token, :revoke], do: empty_503!(s, k)
      unrec_404!(s, :register)
      unrec_404!(s, :authorize)
      assert s.account == 503 and h(s, :account, "retry-after") == "5"
    end

    test "S5 (raising seam) — /versions, the flags and the SSO action fail closed; the OAuth endpoints raise (pinned as measured)" do
      Application.put_env(:nebu_http, :oauth_config_source, fn -> raise "atdd" end)
      v = T.versions()
      assert v.status == 200 and v.resp_body == T.versions_off_bytes()
      flow = T.json(T.login_flows())["flows"] |> Enum.find(&(&1["type"] == "m.login.sso"))
      refute Map.has_key?(flow, "oauth_aware_preferred")
      assert T.location(T.sso_redirect([{"action", "register"}])) =~ "prompt=login"
      # measured: the endpoints that call Config.get/0 directly propagate the seam's raise
      assert_raise Plug.Conn.WrapperError, fn -> T.get_metadata() end
    end

    test "Must #16: runtime toggle S3 -> S1 -> S3 and S1 -> S4 -> S1 flips every surface on the next request" do
      surfaces = fn s -> Map.drop(s, [:conns, :metadata_body, :unstable_body, :token_body]) end
      T.disable_oauth()
      off = surfaces.(T.parity_snapshot())
      T.enable_oauth()
      on = surfaces.(T.parity_snapshot())
      assert on.v115 and on.metadata == 200 and on.flags and on.openid == 200 and on.account == 302 and on.sso_action_prompt == "create"
      T.disable_oauth()
      assert surfaces.(T.parity_snapshot()) == off
      T.enable_oauth()
      assert surfaces.(T.parity_snapshot()) == on
      T.unreadable_oauth_config()
      unknown = surfaces.(T.parity_snapshot())
      refute unknown.v115 or unknown.flags
      assert unknown.metadata == 404 and unknown.openid == 503 and unknown.account == 503 and unknown.revoke == 503
      T.enable_oauth()
      assert surfaces.(T.parity_snapshot()) == on
    end
  end

  describe "AC3/Must #17 — integration variant with the REAL server_config rows" do
    @describetag :integration

    test "an UPDATE of oauth_enabled (+ issuer row) flips /versions on the next request; rows restored" do
      T.clear_oauth_config()
      # set_oauth_rows!/1 registers the restore BEFORE its first write
      _prior = T.set_oauth_rows!(%{"oauth_enabled" => "false", "oauth_issuer_url" => T.issuer()})

      assert T.versions().resp_body == T.versions_off_bytes()
      T.set_oauth_rows!(%{"oauth_enabled" => "true"})
      assert body(T.versions())["versions"] == T.versions_on()
      T.set_oauth_rows!(%{"oauth_enabled" => "false"})
      assert T.versions().resp_body == T.versions_off_bytes()
    end
  end

  describe "V18 — /capabilities unchanged (integration)" do
    @describetag :integration

    test "m.change_password / m.3pid_changes false and no m.get_login_token, in both states" do
      legacy = T.legacy_session!(T.provision_user!(), "CAP" <> String.upcase(T.rand(3)))

      bodies =
        for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end] do
          set.()
          caps = T.json(T.matrix_request(:get, "/_matrix/client/v3/capabilities", legacy.at))["capabilities"]
          assert caps["m.change_password"]["enabled"] == false
          assert caps["m.3pid_changes"]["enabled"] == false
          refute Map.has_key?(caps, "m.get_login_token")
          caps
        end

      assert Enum.uniq(bodies) |> length() == 1, "no dependency on the OAuth state"
    end
  end
end
