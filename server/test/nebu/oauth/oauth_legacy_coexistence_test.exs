defmodule Nebu.OAuth.OAuthLegacyCoexistenceTest do
  @moduledoc """
  Acceptance tests for story `oauth-legacy-coexistence` (story 5 of epic oauth-broker),
  AC1-AC5 and AC9 (C1-C10, C14-C18; Must #1-#16, #23, #26-#29, #32-#34, #37, oracle edge cases):

    * AC1 `GET /login` advertises `oauth_aware_preferred` + `org.matrix.msc3824.delegated_oidc_compatibility`
      on the `m.login.sso` flow IFF OAuth is offered (== `auth_metadata` 200, same predicate,
      evaluated per request); byte-identical response otherwise; never 503.
    * AC2 `action` / `org.matrix.msc3824.action` at the legacy SSO redirect: `register` =>
      `prompt=create` only while OAuth is offered AND the IdP lists `create`; everything else
      byte-for-byte today's redirect; error order unchanged; never logged raw.
    * AC3 OAuth callers get `403 M_FORBIDDEN` at `DELETE /devices/{id}` and `POST /delete_devices`
      FIRST (before IDOR guard, body validation, UIA); legacy callers unchanged.
    * AC4 legacy UIA completion refreshes only legacy `auth_time`; AC5 absent account endpoints
      (404 STATUS only, oracle correction a) and capabilities; AC9 coexistence regressions.

  Regression describes (legacy callers, absent account endpoints, UIA fallback, error order) pin
  today's behaviour and were green before the implementation by design.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @forbidden %{"errcode" => "M_FORBIDDEN", "error" => "Device deletion is not available for OAuth sessions; use the account management page."}
  @stable "oauth_aware_preferred"
  @unstable "org.matrix.msc3824.delegated_oidc_compatibility"

  setup do
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :uia_fresh_auth_seconds], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp dev, do: "CX" <> String.upcase(T.rand(4))

  defp states do
    [
      {"enabled, valid issuer", fn -> T.enable_oauth() end, true},
      {"enabled, nil issuer", fn -> T.enable_oauth(nil) end, false},
      {"enabled, http issuer", fn -> T.enable_oauth("http://nebu.example.com") end, false},
      {"enabled, issuer with a path", fn -> T.enable_oauth("https://nebu.example.com/nebu") end, false},
      {"disabled", fn -> T.disable_oauth() end, false},
      {"unknown (unreadable)", fn -> T.unreadable_oauth_config() end, false},
      {"config read raises", fn -> Application.put_env(:nebu_http, :oauth_config_source, fn -> raise "atdd config boom" end) end, false}
    ]
  end

  defp expected_login_body(extra_sso \\ %{}) do
    display_name = Application.get_env(:nebu_http, :oidc_display_name, "SSO")

    Jason.encode!(%{
      "flows" => [
        Map.merge(%{"type" => "m.login.sso", "identity_providers" => [%{"id" => "oidc", "name" => display_name, "icon" => nil}]}, extra_sso),
        %{"type" => "m.login.token"}
      ]
    })
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — GET /login OAuth-aware flags (C1-C3, O5; Must #1-#3, #32) — no DB
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/C1-C3/Must #1-#3, #32 — GET /login" do
    test "Nebu.OAuth.oauth_aware?/0 follows the C1 predicate in every state and never raises" do
      for {label, set, expected} <- states() do
        set.()
        assert apply(Nebu.OAuth, :oauth_aware?, []) == expected, "#{label}: oauth_aware?/0 must be #{expected}"
      end
    end

    test "OAuth offered: the m.login.sso flow carries BOTH keys as JSON true; m.login.sso first; m.login.token without keys" do
      T.enable_oauth()
      conn = T.login_flows()
      assert conn.status == 200
      assert (T.header(conn, "content-type") || "") =~ "application/json"
      [first, second] = T.json(conn)["flows"]
      assert first["type"] == "m.login.sso", "m.login.sso stays the FIRST flow"
      assert first[@stable] === true, "#{@stable} must be the JSON boolean true"
      assert first[@unstable] === true, "#{@unstable} must be the JSON boolean true"
      assert second == %{"type" => "m.login.token"}, "the m.login.token flow never carries the keys"
      assert conn.resp_body == expected_login_body(%{@stable => true, @unstable => true})
    end

    test "every non-offered state: neither key, still 200, body byte-identical to today's (never 503)" do
      for {label, set, false} <- states() do
        set.()
        conn = T.login_flows()
        assert conn.status == 200, "#{label}: GET /login must answer 200, got #{conn.status}"
        sso = T.sso_flow(conn)
        refute Map.has_key?(sso, @stable), "#{label}: #{@stable} must be absent"
        refute Map.has_key?(sso, @unstable), "#{label}: #{@unstable} must be absent"
        assert conn.resp_body == expected_login_body(), "#{label}: byte-identical to the pre-story response"
      end
    end

    test "O5: the flags are present IFF GET auth_metadata answers 200, per state" do
      # the raising config source is excluded: auth_metadata itself does not rescue a raising seam
      for {label, set, _} <- states(), label != "config read raises" do
        set.()
        meta_ok = T.get_metadata().status == 200
        flagged = Map.has_key?(T.sso_flow(T.login_flows()), @stable)
        assert flagged == meta_ok, "#{label}: flags present (#{flagged}) must equal auth_metadata 200 (#{meta_ok})"
      end
    end

    test "O5: a runtime toggle of oauth_enabled flips the flags on the very next request (no cache)" do
      T.disable_oauth()
      refute Map.has_key?(T.sso_flow(T.login_flows()), @stable)
      T.enable_oauth()
      assert T.sso_flow(T.login_flows())[@stable] === true
      T.disable_oauth()
      refute Map.has_key?(T.sso_flow(T.login_flows()), @stable)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — `action` at the legacy SSO redirect (C4-C6; Must #4-#10, #33)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2/C4-C6 — action / org.matrix.msc3824.action at /login/sso/redirect" do
    @describetag :integration

    setup do
      priv = T.setup_idp!()
      T.set_idp_prompt_values(["login", "create", "consent"])
      {:ok, priv: priv}
    end

    defp names(pairs), do: Enum.map(pairs, &elem(&1, 0))
    defp fixed(pairs), do: pairs |> Enum.reject(fn {k, _} -> k in ~w(state nonce code_challenge) end)

    defp prompts(conn), do: conn |> T.location_pairs() |> Enum.filter(fn {k, _} -> k == "prompt" end) |> Enum.map(&elem(&1, 1))

    defp assert_like_login(conn, reference, label) do
      assert conn.status == 302, "#{label}: expected the 302 to the IdP, got #{conn.status}: #{conn.resp_body}"
      got = T.location_pairs(conn)
      ref = T.location_pairs(reference)
      assert names(got) == names(ref), "#{label}: parameter names/order must equal today's login redirect"
      assert fixed(got) == fixed(ref), "#{label}: non-random values must equal today's login redirect"
      assert prompts(conn) == ["login"]
    end

    test "Must #4: OAuth offered + action=register + IdP lists create => prompt=create, same parameter set, no max_age" do
      T.enable_oauth()
      login = T.sso_redirect([{"action", "login"}])
      reg = T.sso_redirect([{"action", "register"}])
      assert reg.status == 302
      assert prompts(reg) == ["create"], "exactly ONE prompt parameter, value create (never `login create`)"
      refute Enum.any?(T.location_pairs(reg), fn {k, _} -> k == "max_age" end)

      norm = fn c -> c |> T.location_pairs() |> fixed() |> Enum.reject(fn {k, _} -> k == "prompt" end) end
      assert norm.(reg) == norm.(login), "otherwise the same parameters as a login redirect"
      assert names(T.location_pairs(reg)) == names(T.location_pairs(login))
    end

    test "Must #4: the scope is unchanged (OIDC Scopes Law) for action=register" do
      T.enable_oauth()
      scope = fn c -> c |> T.location_pairs() |> List.keyfind("scope", 0) |> elem(1) end
      assert scope.(T.sso_redirect([{"action", "register"}])) == scope.(T.sso_redirect([]))
    end

    for {label, value} <- [{"missing key", :absent}, {"not a list", "create"}, {"list without create", ["login", "consent"]}] do
      test "Must #5: IdP discovery #{label} => action=register is identical to login (prompt=login)" do
        T.enable_oauth()
        T.set_idp_prompt_values(unquote(Macro.escape(value)))
        assert_like_login(T.sso_redirect([{"action", "register"}]), T.sso_redirect([{"action", "login"}]), unquote(label))
      end
    end

    test "Must #6: org.matrix.msc3824.action=register alone is honoured; stable login + unstable register => login wins" do
      T.enable_oauth()
      assert prompts(T.sso_redirect([{"org.matrix.msc3824.action", "register"}])) == ["create"]
      assert prompts(T.sso_redirect([{"action", "login"}, {"org.matrix.msc3824.action", "register"}])) == ["login"]
      assert prompts(T.sso_redirect([{"action", "register"}, {"org.matrix.msc3824.action", "register"}])) == ["create"],
             "matrix-js-sdk sends both with the same value"
    end

    test "Must #33: stable invalid + unstable register => register; both invalid => absent" do
      T.enable_oauth()
      assert prompts(T.sso_redirect([{"action", "REGISTER"}, {"org.matrix.msc3824.action", "register"}])) == ["create"]
      assert prompts(T.sso_redirect([{"action", "signup"}, {"org.matrix.msc3824.action", "junk"}])) == ["login"]
    end

    test "Must #33: a repeated action key resolves to a pinned outcome (Plug: last value wins), never a 4xx" do
      T.enable_oauth()
      a = T.sso_redirect([{"action", "login"}, {"action", "register"}])
      b = T.sso_redirect([{"action", "register"}, {"action", "login"}])
      assert a.status == 302 and b.status == 302
      assert prompts(a) == ["create"], "conn.query_params keeps the LAST value (register)"
      assert prompts(b) == ["login"]
    end

    test "Must #7: junk / case variants / array / oversized / control characters are ignored, never 4xx/5xx" do
      T.enable_oauth()
      reference = T.sso_redirect([])

      variants = [
        [{"action", ""}],
        [{"action", "REGISTER"}],
        [{"action", "Register"}],
        [{"action", "signup"}],
        [{"action", String.duplicate("r", 33)}],
        [{"action", "register" <> String.duplicate(" ", 25)}],
        [{"action", "regis\nter"}],
        [{"org.matrix.msc3824.action", "REGISTER"}]
      ]

      for pairs <- variants, do: assert_like_login(T.sso_redirect(pairs), reference, inspect(pairs))
      assert_like_login(T.sso_redirect([], raw_query: "action[]=register"), reference, "action[]=register")
      assert_like_login(T.sso_redirect([], raw_query: "action[x]=register"), reference, "action[x]=register")
    end

    for {label, set} <- [{"disabled", :disable}, {"invalid issuer", :invalid}, {"unknown", :unknown}] do
      test "Must #8: OAuth NOT offered (#{label}) => every action value is ignored (URL identical to today's)" do
        case unquote(set) do
          :disable -> T.disable_oauth()
          :invalid -> T.enable_oauth("http://nebu.example.com")
          :unknown -> T.unreadable_oauth_config()
        end

        reference = T.sso_redirect([])

        for pairs <- [[{"action", "register"}], [{"org.matrix.msc3824.action", "register"}], [{"action", "login"}]] do
          assert_like_login(T.sso_redirect(pairs), reference, inspect(pairs))
        end
      end
    end

    test "Must #9: /sso/redirect/{idpId} (oidc) behaves like /sso/redirect" do
      T.enable_oauth()
      assert prompts(T.sso_redirect([{"action", "register"}], idp: "oidc")) == ["create"]
      assert prompts(T.sso_redirect([{"action", "login"}], idp: "oidc")) == ["login"]
    end

    test "Must #33: an arbitrary {idpId} keeps today's behaviour with action=register (same status as without action)" do
      T.enable_oauth()
      plain = T.sso_redirect([], idp: "not-a-known-idp")
      reg = T.sso_redirect([{"action", "register"}], idp: "not-a-known-idp")
      assert reg.status == plain.status

      if plain.status == 302 do
        fixed_noprompt = fn c -> c |> T.location_pairs() |> fixed() end
        assert fixed_noprompt.(reg) == fixed_noprompt.(plain), "an arbitrary {idpId} redirect stays today's Location (incl. prompt)"
        assert names(T.location_pairs(reg)) == names(T.location_pairs(plain))
      else
        assert reg.resp_body == plain.resp_body
      end
    end

    test "review MINOR 2: an idpId literally named \"redirect\" is an arbitrary idpId: action is NOT honoured" do
      T.enable_oauth()
      plain = T.sso_redirect([], idp: "redirect")
      reg = T.sso_redirect([{"action", "register"}], idp: "redirect")
      assert reg.status == 302 and plain.status == 302
      assert prompts(reg) == prompts(plain) and prompts(reg) == ["login"]
    end

    test "Kassandra L-2: the values of every action* key variant are masked in the redirect's log; redirectUrl stays visible" do
      T.enable_oauth()
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)
      marker = "ACTIONVARIANT" <> T.rand(4)

      log =
        capture_log([level: :debug], fn ->
          for {name, suffix} <- [{"action[]", ""}, {"Action", "x"}, {"ACTION", ""}, {"org.matrix.msc3824.action[]", ""}, {"action[x]", ""}, {"actionfoo", ""}] do
            T.sso_redirect([{name, marker <> suffix}])
          end

          T.sso_redirect([{"org.matrix.msc3824.ACTION", marker}], idp: "oidc")
        end)

      refute log =~ marker
      assert log =~ "redirectUrl", "the redirect's query capture itself stays (only the action values are masked)"
    end

    test "Must #33: error order unchanged: missing / rejected redirectUrl => today's 400 before action is looked at" do
      T.enable_oauth()
      missing_plain = T.sso_redirect([], redirect_url: nil)
      missing_reg = T.sso_redirect([{"action", "register"}], redirect_url: nil)
      assert missing_reg.status == 400 and missing_reg.resp_body == missing_plain.resp_body

      bad_plain = T.sso_redirect([], redirect_url: "evilscheme://x")
      bad_reg = T.sso_redirect([{"action", "register"}], redirect_url: "evilscheme://x")
      assert bad_reg.status == 400 and bad_reg.resp_body == bad_plain.resp_body

      html = [headers: [{"accept", "text/html"}]]
      assert T.sso_redirect([{"action", "register"}], [redirect_url: "evilscheme://x"] ++ html).resp_body ==
               T.sso_redirect([], [redirect_url: "evilscheme://x"] ++ html).resp_body
    end

    test "Must #33: an IdP discovery failure with action=register => the same 503 M_UNAVAILABLE as login" do
      T.enable_oauth()
      Application.put_env(:nebu_http, :oidc_metadata_override, %{"issuer" => T.idp_issuer()})
      login = T.sso_redirect([{"action", "login"}])
      reg = T.sso_redirect([{"action", "register"}])
      assert login.status == 503
      assert reg.status == login.status and reg.resp_body == login.resp_body
    end

    test "Must #9: the UIA fallback is unaffected by action=register (prompt=login + max_age=0)" do
      T.enable_oauth()
      uid = T.user_id_for(%{"sub" => T.unique_sub()})
      sid = Nebu.Matrix.Uia.mint_session(uid, "delete_devices", "{}")
      conn = T.get("/_matrix/client/v3/auth/m.login.sso/fallback/web?session=" <> URI.encode_www_form(sid) <> "&action=register&org.matrix.msc3824.action=register")
      assert conn.status == 302
      idp = T.idp_params(conn)
      assert idp["prompt"] == "login"
      assert idp["max_age"] == "0"
    end

    test "Must #10 / C6: the raw action value never appears in a log line" do
      T.enable_oauth()
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)
      marker = "ACTIONMARKER" <> T.rand(4)

      log =
        capture_log([level: :debug], fn ->
          T.sso_redirect([{"action", marker}, {"org.matrix.msc3824.action", marker}])
          T.sso_redirect([{"action", "register"}])
        end)

      refute log =~ marker
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — OAuth callers refused at device deletion (C7, C8; Must #11-#13, #34)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3/C7/C8 — OAuth callers => 403 M_FORBIDDEN before anything else" do
    @describetag :integration

    setup do
      T.enable_oauth()
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      priv = T.setup_idp!()
      cid = T.oauth_client!([@https])
      s = T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      other_oauth = T.session!(cid, @https, priv, sub: s.sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      legacy_dev = dev()
      legacy = T.legacy_session!(s.user_id, legacy_dev)
      stranger_uid = T.provision_user!()
      stranger_dev = dev()
      _stranger = T.legacy_session!(stranger_uid, stranger_dev)
      for {u, d} <- [{s.user_id, s.device_id}, {s.user_id, legacy_dev}, {stranger_uid, stranger_dev}], do: T.seed_device_keys!(u, d)

      {:ok, s: s, cid: cid, priv: priv, other_oauth: other_oauth, legacy: legacy, legacy_dev: legacy_dev,
       stranger_uid: stranger_uid, stranger_dev: stranger_dev}
    end

    defp snapshot(ctx), do: {T.world_snapshot([ctx.s.user_id, ctx.stranger_uid]), T.uia_rows(ctx.s.user_id)}

    defp assert_refused(conn, ctx, before) do
      assert conn.status == 403, "OAuth caller must be refused with 403, got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == @forbidden
      assert snapshot(ctx) == before, "nothing changed: no session/device/key/binding row, no uia_sessions row minted or consumed"
      assert T.whoami(ctx.s.at).status == 200, "the caller's session keeps working"
    end

    test "Must #11: DELETE /devices/{id} for own / other OAuth / legacy / foreign / unknown id, with and without auth", ctx do
      ids = [ctx.s.device_id, ctx.other_oauth.device_id, ctx.legacy_dev, ctx.stranger_dev, "UNKNOWN" <> T.rand(3)]

      for id <- ids, body <- [%{}, %{"auth" => %{"type" => "m.login.sso", "session" => "nope"}}] do
        before = snapshot(ctx)
        conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> id, ctx.s.at, body: body)
        assert_refused(conn, ctx, before)
      end
    end

    test "Must #11: a valid COMPLETED UIA session of the user stays unconsumed", ctx do
      sid = T.uia_session!(ctx.s.user_id, Nebu.Matrix.Uia.canonical_params([ctx.legacy_dev]), complete: true)
      before = snapshot(ctx)
      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> ctx.legacy_dev, ctx.s.at, body: %{"auth" => %{"type" => "m.login.sso", "session" => sid}})
      assert_refused(conn, ctx, before)
      assert [[^sid, true, false]] = Enum.filter(T.uia_rows(ctx.s.user_id), fn [id | _] -> id == sid end)
    end

    test "Must #12: POST /delete_devices => 403 before body validation (ids, missing, non-list, 101 ids, auth)", ctx do
      bodies = [
        %{"devices" => [ctx.s.device_id]},
        %{"devices" => [ctx.legacy_dev, ctx.other_oauth.device_id, ctx.stranger_dev]},
        %{},
        %{"devices" => "x"},
        %{"devices" => Enum.map(1..101, &"D#{&1}")},
        %{"devices" => [ctx.legacy_dev], "auth" => %{"type" => "m.login.sso", "session" => "nope"}}
      ]

      for body <- bodies do
        before = snapshot(ctx)
        assert_refused(T.matrix_request(:post, "/_matrix/client/v3/delete_devices", ctx.s.at, body: body), ctx, before)
      end
    end

    test "Must #34: also with an empty body and a non-JSON body (refusal before body parsing)", ctx do
      for {method, path} <- [{:delete, "/_matrix/client/v3/devices/" <> ctx.legacy_dev}, {:post, "/_matrix/client/v3/delete_devices"}],
          {body, ct} <- [{nil, nil}, {"", "application/json"}, {"{not json", "application/json"}, {"devices=x", "application/x-www-form-urlencoded"}] do
        before = snapshot(ctx)
        assert_refused(T.raw_request(method, path, ctx.s.at, body, ct), ctx, before)
      end
    end

    test "Must #34: an EXPIRED OAuth access token => 401 M_UNKNOWN_TOKEN soft_logout: true (authentication first), nothing touched", ctx do
      T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '1 second' WHERE access_token_hash = $1", [T.token_hash(ctx.s.at)])
      before = snapshot(ctx)
      T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> ctx.legacy_dev, ctx.s.at, body: %{}) |> T.assert_unknown_token(true)
      T.matrix_request(:post, "/_matrix/client/v3/delete_devices", ctx.s.at, body: %{"devices" => [ctx.legacy_dev]}) |> T.assert_unknown_token(true)
      assert snapshot(ctx) == before
    end

    test "Must #13: legacy callers unchanged: fresh-window delete of an OAuth device of the same user works", ctx do
      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> ctx.other_oauth.device_id, ctx.legacy.at, body: %{})
      assert conn.status == 200, "legacy caller deletes an OAuth device (story 4 R18), got #{conn.status}: #{conn.resp_body}"
      T.refresh(ctx.cid, ctx.other_oauth.rt) |> T.assert_token_error(400, "invalid_grant")
    end

    test "Must #13: legacy callers unchanged: stale session => UIA 401 with m.login.sso; IDOR 404; body 400s", ctx do
      T.put_env_scoped(:uia_fresh_auth_seconds, 1)
      T.sql!("UPDATE matrix_sessions SET auth_time = 1000 WHERE access_token_hash = $1", [T.token_hash(ctx.legacy.at)])

      challenge = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> ctx.legacy_dev, ctx.legacy.at, body: %{})
      assert challenge.status == 401
      assert Enum.any?(T.json(challenge)["flows"] || [], &(&1["stages"] == ["m.login.sso"]))

      idor = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> ctx.stranger_dev, ctx.legacy.at, body: %{})
      assert idor.status == 404

      assert T.matrix_request(:post, "/_matrix/client/v3/delete_devices", ctx.legacy.at, body: %{}).status == 400
      assert T.matrix_request(:post, "/_matrix/client/v3/delete_devices", ctx.legacy.at, body: %{"devices" => "x"}).status == 400
    end

    test "Must #13: a raw-JWT legacy caller is unchanged (fresh window deletes its other device)", ctx do
      jwt_dev = dev()
      jwt = T.bound_jwt!(ctx.priv, ctx.s.sub, jwt_dev)
      target = dev()
      T.seed_device_keys!(ctx.s.user_id, target)
      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> target, jwt, body: %{})
      assert conn.status == 200, "a raw-JWT legacy caller inside the fresh window deletes its other device, got #{conn.status}: #{conn.resp_body}"
      assert T.device_gone?(ctx.s.user_id, target)
      assert T.whoami(jwt).status == 200, "the caller's own JWT is untouched"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — UIA freshness legacy-only (C9; Must #14)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/C9/Must #14 — Uia.complete/2 refreshes only legacy auth_time" do
    @describetag :integration

    test "legacy row refreshed, OAuth row unchanged" do
      T.enable_oauth()
      priv = T.setup_idp!()
      cid = T.oauth_client!([@https])
      s = T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      legacy = T.legacy_session!(s.user_id, dev())
      T.sql!("UPDATE matrix_sessions SET auth_time = 1000 WHERE user_id = $1", [s.user_id])

      sid = T.uia_session!(s.user_id)
      assert {:ok, _} = Nebu.Matrix.Uia.complete(sid, s.user_id)

      assert T.row_by_at(legacy.at)["auth_time"] > 1000, "the legacy row's auth_time is refreshed"
      assert T.row_by_at(s.at)["auth_time"] == 1000, "the OAuth row's auth_time (IdP login time) is untouched (C9)"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — account endpoints stay absent, capabilities (C10; Must #15, #16, #37)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5/C10/Must #15, #16, #37 — absent endpoints (404 status only), capabilities, device_signing/upload" do
    @describetag :integration

    setup do
      T.enable_oauth()
      priv = T.setup_idp!()
      cid = T.oauth_client!([@https])
      s = T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      legacy = T.legacy_session!(T.provision_user!(), dev())
      {:ok, tokens: [s.at, legacy.at], s: s}
    end

    # story oauth-room-summary-unrecognized (af): changed deliberately. The account endpoints are still
    # absent, now answered by the spec's 404 M_UNRECOGNIZED (was a bare status pin, the errcode was
    # M_NOT_FOUND). `POST /register` is NOT a fall-through any more: RU10a routes it explicitly to
    # 403 M_FORBIDDEN (registration not enabled), see the next test.
    test "deactivate / password / 3pid => 404 M_UNRECOGNIZED for OAuth and legacy tokens", %{tokens: tokens} do
      for token <- tokens,
          {m, p} <- [{:post, "/_matrix/client/v3/account/deactivate"}, {:post, "/_matrix/client/v3/account/password"},
                     {:get, "/_matrix/client/v3/account/3pid"}, {:post, "/_matrix/client/v3/account/3pid/add"},
                     {:post, "/_matrix/client/v3/account/3pid/delete"}] do
        conn = T.matrix_request(m, p, token, body: %{})
        assert conn.status == 404, "#{m} #{p} must stay absent"
        assert T.json(conn) == %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}, "#{m} #{p}"
      end
    end

    # story oauth-room-summary-unrecognized (af, RU10a / AC8a): was part of the 404 list above.
    test "POST /register => 403 M_FORBIDDEN (registration not enabled) for OAuth and legacy tokens", %{tokens: tokens} do
      for token <- tokens do
        conn = T.matrix_request(:post, "/_matrix/client/v3/register", token, body: %{})
        assert conn.status == 403
        assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "Registration is not enabled on this homeserver."}
      end
    end

    test "capabilities: m.change_password and m.3pid_changes disabled for both", %{tokens: tokens} do
      for token <- tokens do
        caps = T.json(T.matrix_request(:get, "/_matrix/client/v3/capabilities", token))["capabilities"]
        assert caps["m.change_password"]["enabled"] == false
        assert caps["m.3pid_changes"]["enabled"] == false
      end
    end

    # story 6 (oauth-account-management, A14 / Trap 7): changed deliberately. Story 5 pinned "different
    # keys => 403" for an OAuth caller ("m.oauth is story 6"); from story 6 on the OAuth replacement gets
    # the m.oauth UIA challenge (full behaviour: oauth_account_cross_signing_test.exs).
    test "Must #16: /keys/device_signing/upload with an OAuth token: 200, identical 200, different keys => m.oauth challenge (story 6)", %{s: s} do
      master = fn pub -> %{"master_key" => %{"user_id" => s.user_id, "usage" => ["master"], "keys" => %{"ed25519:#{pub}" => pub}}} end
      path = "/_matrix/client/v3/keys/device_signing/upload"
      first = master.("MASTERone" <> T.rand(8))
      T.sql!("DELETE FROM cross_signing_keys WHERE user_id = $1", [s.user_id])
      assert T.matrix_request(:post, path, s.at, body: first).status == 200
      assert T.matrix_request(:post, path, s.at, body: first).status == 200
      conn = T.matrix_request(:post, path, s.at, body: master.("MASTERtwo" <> T.rand(8)))
      assert conn.status == 401
      assert T.json(conn)["flows"] == [%{"stages" => ["m.oauth"]}]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — coexistence regressions (C14-C18; Must #23, #26-#29) — green by design
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9/C14-C18 — coexistence regressions" do
    @describetag :integration

    setup do
      T.enable_oauth()
      priv = T.setup_idp!()
      cid = T.oauth_client!([@https])
      s = T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      {:ok, s: s, priv: priv, cid: cid}
    end

    test "Must #26: an unbound raw JWT of an OAuth-only user authenticates device-less (C14)", %{s: s, priv: priv} do
      jwt = T.unbound_jwt!(priv, s.sub)
      who = T.whoami(jwt)
      assert who.status == 200
      refute Map.has_key?(T.json(who), "device_id")
      assert T.sync(jwt).status == 200
    end

    test "Must #27: /whoami per credential kind", %{s: s, priv: priv} do
      assert T.json(T.whoami(s.at))["device_id"] == s.device_id
      ld = dev()
      legacy = T.legacy_session!(s.user_id, ld)
      assert T.json(T.whoami(legacy.at))["device_id"] == ld
      bd = dev()
      bound = T.bound_jwt!(priv, s.sub, bd)
      assert T.json(T.whoami(bound))["device_id"] == bd
      refute Map.has_key?(T.json(T.whoami(T.unbound_jwt!(priv, s.sub))), "device_id")
    end

    test "Must #28: legacy /refresh vs OAuth RT and /oauth2/token vs legacy RT stay isolated", %{s: s, cid: cid} do
      assert T.legacy_refresh(s.rt).status == 401
      legacy = T.legacy_session!(T.provision_user!(), dev())
      T.refresh(cid, legacy.rt) |> T.assert_token_error(400, "invalid_grant")
    end

    test "C18: admin device list shows legacy and OAuth devices; admin delete of the OAuth device ends its session", %{s: s, cid: cid} do
      ld = dev()
      _legacy = T.legacy_session!(s.user_id, ld)
      T.seed_device_keys!(s.user_id, ld)
      ids = s.user_id |> Nebu.Matrix.list_user_devices() |> Enum.map(& &1["device_id"])
      assert s.device_id in ids and ld in ids
      assert Nebu.Matrix.delete_user_device(s.user_id, s.device_id) == :ok
      T.assert_unknown_token(T.whoami(s.at), false)
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
    end

    test "Must #29: OAuth switched off with a live session: AT works, refresh 404 (T22), /logout ends it (C16)", %{s: s, cid: cid} do
      T.disable_oauth()
      assert T.whoami(s.at).status == 200
      T.refresh(cid, s.rt) |> T.assert_unrecognized_404_no_error()
      T.logout(s.at) |> T.assert_logout_ok()
      T.assert_unknown_token(T.whoami(s.at), false)
    end
  end
end
