defmodule Nebu.OAuth.ConsentGrantFlowTest do
  @moduledoc """
  Story `persistent-consent-grants` (REQ-2026-003), scenarios 1-5, 7 and the hardening around them: the REAL flow (authorize -> IdP stub -> callback ->
  consent -> code -> token) with remembered consent grants. Real database, `--include integration`.

  ## Where the decision is taken

  The user is only known after the verified IdP login, so the decision sits in the IdP CALLBACK (`Nebu.OAuth.Authorize.handle_idp_callback/1`), at the
  place where the consent row is created today. After the gates that exist today (gate l, provisioning, freshness verdict, device-holder check, encryption
  of the IdP refresh token) the callback asks `Nebu.OAuth.ConsentGrantStore.skip_consent?/4` (scope AFTER the existing narrowing, exact redirect URI):

    * not remembered (or `prompt=consent`, or the store is unreadable) => unchanged: consent row, cookie, `303 /oauth2/consent`;
    * remembered => NO consent row, NO consent cookie: the callback mints the code the same way `Consent` does after Allow (same row, same device holder
      check, same logging style) and redirects to the client (`302` or `303`, `code`, `state`, `iss` in the request's response mode).

  Allow remembers (`upsert/1`, AFTER the code was minted, so no grant exists without an issued code; a failing grant write never fails the Allow: one
  value-free warning, the user is simply asked again next time). Deny remembers nothing and leaves an existing grant alone (withdrawal is explicit).

  ## Decisions pinned here

    1. The remembered scope has NO device token (clients such as FluffyChat / matrix-js-sdk use a new device id for every login).
    2. `profile` / `email` and other unknown scope tokens are dropped by the existing scope parser and never granted, so "openid profile email" after a
       grant for "openid" is the SAME narrowed scope: it skips. What scenario 3 can observably widen is `openid` (and the Matrix prefix).
    3. The skip never widens what the client asked for: the code carries the REQUESTED (narrowed) scope, not the remembered one.
    4. One redirect URI per grant (the one the user last allowed): another registered URI asks again and, once allowed, MOVES the grant.
    5. The skip applies whatever the freshness verdict of the IdP login is (today the verdict only drives a notice on the consent screen, it never
       refuses a login); the code carries the same raw `auth_time` as on the consent path.
    6. Nothing on the skip path weakens the code binding: PKCE challenge of THIS request, `state`, `nonce`, device id, the device-holder rule, the IdP
       errors, gate l: all behave as on the consent path.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.TestSupport, as: T

  @https G.https()
  @other "https://other.example.com/cb"

  setup do
    env = G.setup_env!()
    sub = T.unique_sub()
    uid = T.user_id_for(%{"sub" => sub})
    on_exit(fn -> G.cleanup_grants([uid]) end)
    {:ok, Map.merge(env, %{sub: sub, uid: uid})}
  end

  defp code_row(code) do
    case T.sql!("SELECT *, extract(epoch FROM auth_time)::bigint AS auth_time_s FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(code)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  defp code_of(params), do: params["code"] || flunk("no code in #{inspect(params)}")

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 1: first login asks
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 1 - first login with a client asks for consent" do
    test "no grant: the consent screen is shown (303 /oauth2/consent, cookie, consent row), nothing is remembered yet", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      login = G.login(cid, priv, sub) |> G.assert_consent!()
      assert T.count_for("oauth_consent_requests", cid) == 1
      assert T.count_for("oauth_codes", cid) == 0, "no code before the user's click"
      assert G.grant_count(uid) == 0, "showing the screen remembers nothing"
      assert login.cb.status == 303
    end

    test "Allow remembers exactly what was allowed: one row, normalised scope without the device, the redirect URI, the client's approval time", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      login = G.allow_new!(cid, priv, sub, device: "FIRSTDEV01", nonce: "n-" <> T.rand(), state: "st-" <> T.rand())

      assert [row] = G.grant_rows(uid)
      assert row["client_id"] == cid
      assert row["scope"] == G.remembered_scope()
      assert row["redirect_uri"] == @https
      assert row["client_approved_at"] == T.client_row(cid)["approved_at"]

      secrets = [login.code, T.param(login.flow.pairs, "state"), T.param(login.flow.pairs, "nonce"), T.param(login.flow.pairs, "code_challenge"), login.device, login.verifier]

      for {col, value} <- row, is_binary(value), s <- secrets do
        refute String.contains?(value, s), "a per-login value (#{s}) was stored in oauth_consent_grants.#{col}"
      end

      assert G.grant_count_for_client(cid) == 1
    end

    test "Deny remembers nothing, and the next login asks again", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      login = G.login(cid, priv, sub) |> G.assert_consent!()
      conn = T.consent!(login.cb, :deny)
      assert conn.status == 303
      assert G.grant_count(uid) == 0
      G.login(cid, priv, sub) |> G.assert_consent!()
    end

    test "Deny leaves an EXISTING grant alone (withdrawal is explicit): after prompt=consent + Deny the next plain login still skips", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      before = G.grant_row(uid, cid)
      login = G.login(cid, priv, sub, prompt: "consent") |> G.assert_consent!()
      assert T.consent!(login.cb, :deny).status == 303
      assert G.grant_row(uid, cid) == before
      G.login(cid, priv, sub) |> G.assert_skipped!()
    end

    test "two tabs: both consent screens are allowed, there is ONE grant row", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      a = G.login(cid, priv, sub) |> G.assert_consent!()
      b = G.login(cid, priv, sub) |> G.assert_consent!()
      {_, _} = G.allow!(a)
      {_, _} = G.allow!(b)
      assert G.grant_count(uid) == 1
    end

    test "the client is revoked between the callback and the click: the Allow is refused (403 client_rejected), no code, NO grant", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      login = G.login(cid, priv, sub) |> G.assert_consent!()
      :ok = T.mark_revoked!(cid)
      # the page itself already refuses a revoked client (GET 403): the POST of a form that was rendered earlier is what is pinned here
      conn = T.consent!(login.cb, :allow, get: false)
      assert conn.status == 403
      assert conn.resp_body =~ "client_rejected"
      assert T.count_for("oauth_codes", cid) == 0
      assert G.grant_count(uid) == 0
    end

    test "a failing grant write never fails the Allow: the code is issued, one value-free warning, the next login asks again", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      canary = "canary-" <> T.rand(6)
      login = G.login(cid, priv, sub, state: canary) |> G.assert_consent!()
      original = Logger.level()
      Logger.configure(level: :debug)

      {conn, log} =
        with_log(fn ->
          try do
            G.with_table_unreadable(fn -> T.consent!(login.cb, :allow) end)
          after
            Logger.configure(level: original)
          end
        end)

      assert conn.status == 303
      {_base, _mode, params, _} = T.client_redirect(conn)
      assert is_binary(params["code"]), "the user's Allow still issues the code"
      assert log =~ "[warning] OAuth consent: the decision was not remembered client_id=#{cid}"
      refute log =~ canary
      refute log =~ params["code"]
      assert G.grant_count(uid) == 0
      G.login(cid, priv, sub) |> G.assert_consent!()
    end

    test "no grant without an issued code: when the code cannot be stored the Allow ends in server_error and NOTHING is remembered", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      login = G.login(cid, priv, sub) |> G.assert_consent!()
      G.block_code_inserts!(uid)

      conn = T.consent!(login.cb, :allow)
      assert conn.status == 303
      {_base, _mode, params, _} = T.client_redirect(conn)
      assert params["error"] == "server_error"
      refute Map.has_key?(params, "code")
      assert G.grant_count(uid) == 0, "the user's click produced no code, so no grant"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 2: second login skips
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 2 - the second login with the same client skips the consent screen" do
    setup %{cid: cid, priv: priv, sub: sub} do
      first = G.allow_new!(cid, priv, sub, device: "FIRSTDEV01")
      {:ok, first: first}
    end

    test "a NEW device id, the same scope: the code comes straight from the callback; no consent row, no cookie", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      login = G.login(cid, priv, sub, device: "SECONDDEV2")
      params = G.assert_skipped!(login)
      assert is_binary(params["code"]) and params["code"] != ""
      assert G.grant_count(uid) == 1
    end

    test "the code is bound to THIS request: PKCE challenge, nonce, device, redirect URI, user, IdP refresh token, raw auth_time", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      nonce = "nonce-" <> T.rand()
      t = System.system_time(:second) - 30
      login = G.login(cid, priv, sub, device: "SECONDDEV2", nonce: nonce, claims: %{"auth_time" => t}, idp_rt: "idp-rt-skip-" <> T.rand())
      params = G.assert_skipped!(login)
      row = code_row(code_of(params))

      assert row["client_id"] == cid
      assert row["user_id"] == uid
      assert row["redirect_uri"] == @https
      assert row["code_challenge"] == T.param(login.flow.pairs, "code_challenge")
      assert row["device_id"] == "SECONDDEV2"
      assert row["scope"] == G.scope("SECONDDEV2"), "the REQUESTED narrowed scope, device included"
      assert row["scope_prefix"] == T.unstable_prefix()
      assert row["openid_requested"] == true
      assert row["client_nonce"] == nonce
      assert row["response_mode"] == "fragment"
      assert row["auth_time_s"] == t, "the raw auth_time claim, as on the consent path"
      assert {:ok, _} = Nebu.Web.SecretBox.decrypt(row["idp_rt_enc"]), "the IdP refresh token is stored encrypted, like after an Allow"
      assert row["device_holder_checked"] == true
      assert row["device_holder_client_id"] == nil
      assert row["used_at"] == nil
    end

    test "the skip-path code row has the same shape as the code row after an Allow (same columns set, same holder fields)", %{first: first, cid: cid, priv: priv, sub: sub} do
      allowed = code_row(first.code)
      skipped = code_row(code_of(G.assert_skipped!(G.login(cid, priv, sub, device: "SECONDDEV2"))))

      for col <- ~w(client_id redirect_uri user_id scope_prefix openid_requested response_mode device_holder_checked device_holder_client_id) do
        assert skipped[col] == allowed[col], "#{col}: skip #{inspect(skipped[col])} vs allow #{inspect(allowed[col])}"
      end

      assert Map.keys(skipped) |> Enum.sort() == Map.keys(allowed) |> Enum.sort()
      refute skipped["code_hash"] == allowed["code_hash"]
    end

    test "the client's state and the issuer are echoed in the request's response mode (query)", %{cid: cid, priv: priv, sub: sub} do
      login = G.login(cid, priv, sub, authorize: %{"response_mode" => "query"}, state: "s-" <> T.rand())
      params = G.assert_skipped!(login)
      {_base, mode, _p, order} = T.client_redirect(login.cb)
      assert mode == "query"
      assert order == ["code", "state", "iss"], "parameter order #{inspect(order)}"
      assert params["iss"] == T.get_metadata() |> T.json() |> Map.fetch!("issuer")
    end

    test "the code is redeemed ONLY with this request's verifier and redirect URI; the session is for the NEW device", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      # a failed redemption burns the code (reuse detection): every probe gets its own login
      wrong_verifier = G.login(cid, priv, sub, device: "WRONGVER01")
      code1 = code_of(G.assert_skipped!(wrong_verifier))
      assert (conn = G.redeem(%{wrong_verifier | verifier: T.pkce_pair() |> elem(0)}, code1)).status == 400
      assert T.json(conn)["error"] == "invalid_grant", "another verifier cannot redeem the code"

      wrong_redirect = G.login(cid, priv, sub, device: "WRONGURI01")
      code2 = code_of(G.assert_skipped!(wrong_redirect))
      assert (conn = G.redeem(%{wrong_redirect | redirect: @other}, code2)).status == 400
      assert T.json(conn)["error"] == "invalid_grant", "another redirect URI cannot redeem the code"

      login = G.login(cid, priv, sub, device: "SECONDDEV2")
      code = code_of(G.assert_skipped!(login))
      conn = G.redeem(login, code)
      assert conn.status == 200, G.describe(conn)
      body = T.json(conn)
      assert is_binary(body["access_token"]) and is_binary(body["refresh_token"])
      assert body["token_type"] |> String.downcase() == "bearer"
      assert T.json(T.whoami(body["access_token"]))["device_id"] == "SECONDDEV2"
      assert T.json(T.whoami(body["access_token"]))["user_id"] == uid
    end

    test "a code of the skip path is single use", %{cid: cid, priv: priv, sub: sub} do
      login = G.login(cid, priv, sub)
      code = code_of(G.assert_skipped!(login))
      assert G.redeem(login, code).status == 200
      assert G.redeem(login, code).status == 400
    end

    test "the skip does not touch the grant row (no write on the hot path)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      before = G.grant_row(uid, cid)
      for _ <- 1..3, do: G.login(cid, priv, sub) |> G.assert_skipped!()
      assert G.grant_row(uid, cid) == before
    end

    test "repeated skips each mint a distinct code, no consent request ever exists", %{cid: cid, priv: priv, sub: sub} do
      codes = for _ <- 1..3, do: G.login(cid, priv, sub) |> G.assert_skipped!() |> code_of()
      assert length(Enum.uniq(codes)) == 3
      assert T.count_for("oauth_consent_requests", cid) == 0
    end

    test "the freshness verdict does not matter: stale or absent auth_time skips too, with the same raw value in the code", %{cid: cid, priv: priv, sub: sub} do
      old = System.system_time(:second) - 7200
      stale = G.login(cid, priv, sub, claims: %{"auth_time" => old})
      assert code_row(code_of(G.assert_skipped!(stale)))["auth_time_s"] == old

      absent = G.login(cid, priv, sub, claims: %{"auth_time" => nil})
      assert code_row(code_of(G.assert_skipped!(absent)))["auth_time_s"] == nil
    end

    test "login is NOT skipped: an IdP error still ends the flow as an error redirect, never a code", %{cid: cid, sub: _sub} do
      flow = T.start_flow(cid, @https, %{"scope" => G.scope("ERRDEV0001")})
      cb = T.callback([{"error", "access_denied"}, {"state", flow.state}], [flow.cookie])
      assert cb.status == 302
      params = T.assert_error_redirect(cb, @https, "access_denied", "fragment", T.param(flow.pairs, "state"), T.get_metadata() |> T.json() |> Map.fetch!("issuer"))
      refute Map.has_key?(params, "code")
    end

    test "login is NOT skipped: an id token that does not verify (wrong nonce) is refused, never a code", %{cid: cid, priv: priv, sub: sub} do
      flow = T.start_flow(cid, @https, %{"scope" => G.scope("BADNONCE01")})
      cb = T.finish_flow(%{flow | nonce: "not-the-nonce"}, priv, claims: %{"sub" => sub})
      assert cb.status == 302
      {_base, _mode, params, _} = T.client_redirect(cb)
      assert params["error"] in ["access_denied", "server_error"]
      refute Map.has_key?(params, "code")
    end

    test "gate l still applies: no IdP refresh token under per_refresh => server_error redirect, no code, no consent row", %{cid: cid, priv: priv, sub: sub} do
      login = G.login(cid, priv, sub, idp_rt: nil)
      assert {:other, cb} = login.outcome
      assert cb.status == 302
      {_base, _mode, params, _} = T.client_redirect(cb)
      assert params["error"] == "server_error"
      refute Map.has_key?(params, "code")
      assert T.count_for("oauth_consent_requests", cid) == 0
    end

    test "a DEACTIVATED user with a live grant gets no code and no consent screen: access_denied, grant untouched", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      before = G.grant_row(uid, cid)
      codes_before = T.count_for("oauth_codes", cid)
      T.privileged_sql!("UPDATE users SET is_active = false WHERE user_id = $1", [uid])

      login = G.login(cid, priv, sub)
      assert {:other, cb} = login.outcome, "a deactivated user must not be skipped through: #{G.describe(login.cb)}"
      assert cb.status in [302, 303]
      {_base, _mode, params, _} = T.client_redirect(cb)
      assert params["error"] == "access_denied"
      refute Map.has_key?(params, "code")
      assert T.consent_set_cookies(cb) == []
      assert T.count_for("oauth_consent_requests", cid) == 0
      assert T.count_for("oauth_codes", cid) == codes_before, "no new code"
      assert G.grant_row(uid, cid) == before, "the grant is untouched"
    end

    test "the device holder rule still applies: a device held by ANOTHER app is refused (403 device_in_use), grant or not", %{cid: cid, priv: priv, sub: sub} do
      other = T.oauth_client!([@https])
      _held = T.oauth_device!(other, @https, priv, sub, "HELDDEV001")

      login = G.login(cid, priv, sub, device: "HELDDEV001")
      assert login.cb.status == 403
      assert login.cb.resp_body =~ "device_in_use"
      assert T.count_for("oauth_codes", cid) == 1, "only the code of the first Allow exists"
      assert T.count_for("oauth_consent_requests", cid) == 0
    end

    test "the same app on the same device continues its session: skip, and the code records the holder the user already accepted", %{cid: cid, priv: priv, sub: sub} do
      login1 = G.login(cid, priv, sub, device: "SAMEDEV001")
      code1 = code_of(G.assert_skipped!(login1))
      assert G.redeem(login1, code1).status == 200, "a live session of this app on SAMEDEV001"

      login2 = G.login(cid, priv, sub, device: "SAMEDEV001")
      row = code_row(code_of(G.assert_skipped!(login2)))
      assert row["device_holder_checked"] == true
      assert row["device_holder_client_id"] == cid
    end

    # cycle 1 (Kassandra MEDIUM #1): a skip never replaces another session. For `{:replace, _}` (a legacy session on the requested device id, or a
    # device row without a live session) the consent screen is shown: it says "another session will be signed out" and the user decides.
    test "a LEGACY session on the requested device id: the consent screen (data-device=replace), nothing is replaced before the click", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      legacy = T.legacy_session!(uid, "LEGSKIP001")
      assert T.whoami(legacy.at).status == 200

      login = G.login(cid, priv, sub, device: "LEGSKIP001") |> G.assert_consent!()
      assert T.consent_get(T.consent_cookie(login.cb) |> then(fn {n, v, _} -> {n, v} end)).resp_body =~ ~s(data-device="replace")
      assert T.whoami(legacy.at).status == 200, "no code, nothing replaced without a click"
      assert T.count_for("oauth_codes", cid) == 1, "only the code of the first Allow exists"

      {_conn, code} = G.allow!(login)
      assert G.redeem(login, code).status == 200
      assert T.whoami(legacy.at).status == 401, "after the user's Allow the legacy session is replaced"
    end

    test "a device row WITHOUT a live session is a replace as well: the consent screen", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, "BARESKIP01", display_name: "Old phone", last_seen_ts: System.system_time(:millisecond))
      login = G.login(cid, priv, sub, device: "BARESKIP01") |> G.assert_consent!()
      assert T.consent_get(T.consent_cookie(login.cb) |> then(fn {n, v, _} -> {n, v} end)).resp_body =~ ~s(data-device="replace")
    end

    test "after that Allow the same device id is held by this app: the next login skips again (same_client)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      _legacy = T.legacy_session!(uid, "LEGSKIP002")
      login = G.login(cid, priv, sub, device: "LEGSKIP002") |> G.assert_consent!()
      {_conn, code} = G.allow!(login)
      assert G.redeem(login, code).status == 200

      G.login(cid, priv, sub, device: "LEGSKIP002") |> G.assert_skipped!()
    end

    test "the hot path adds no consent-table traffic: a skip inserts and consumes no oauth_consent_requests row", %{cid: cid, priv: priv, sub: sub} do
      id = "grant-flow-" <> T.rand()
      me = self()
      :telemetry.attach(id, [:nebu, :repo, :query], fn _e, _m, meta, _c -> if self() == me, do: send(me, {:q, meta[:query]}) end, nil)

      login =
        try do
          G.login(cid, priv, sub)
        after
          :telemetry.detach(id)
        end

      queries = drain([])
      G.assert_skipped!(login)
      refute Enum.any?(queries, &(&1 =~ "oauth_consent_requests")), "no consent request statement on the skip path, got #{inspect(Enum.filter(queries, &(&1 =~ "oauth_consent_requests")))}"
      assert Enum.any?(queries, &(&1 =~ "oauth_consent_grants")), "the grant is read"
    end

    test "a code that cannot be stored on the skip path is a server_error redirect (never a consent screen, never a half code)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.block_code_inserts!(uid)
      login = G.login(cid, priv, sub)
      assert {:other, cb} = login.outcome, G.describe(login.cb)
      assert cb.status in [302, 303]
      {_base, _mode, params, _} = T.client_redirect(cb)
      assert params["error"] == "server_error"
      refute Map.has_key?(params, "code")
      assert T.consent_set_cookies(cb) == []
      assert G.grant_count(uid, cid) == 1, "the grant itself is untouched"
    end

    test "a redirect target that can never be a valid CSP source is not redirected to on the skip path either (500 server_error page, no code)", %{priv: priv, sub: sub, uid: uid} do
      bad = "data:text/html,atdd-" <> T.rand(4)
      cid = T.oauth_client!([bad], client_name: "Unusable Target App", client_uri: G.website())
      :ok = G.insert_grant!(uid, cid, %{redirect_uri: bad})

      login = G.login(cid, priv, sub, redirect: bad)
      assert login.cb.status == 500, G.describe(login.cb)
      assert login.cb.resp_body =~ "server_error"
      assert T.location(login.cb) == nil
      assert T.count_for("oauth_codes", cid) == 0
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 3: broader scope asks again
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 3 - a broader scope asks for consent again" do
    test "grant without openid, request WITH openid: the consent screen; Allow widens the grant; the next openid login skips", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub, openid: false)
      assert G.grant_row(uid, cid)["scope"] == G.remembered_scope(openid: false)

      wider = G.login(cid, priv, sub, openid: true) |> G.assert_consent!()
      {_, _} = G.allow!(wider)
      assert G.grant_row(uid, cid)["scope"] == G.remembered_scope(openid: true), "the grant now covers openid"
      G.login(cid, priv, sub, openid: true) |> G.assert_skipped!()
    end

    test "story wording: grant \"openid\", request \"openid profile email\" is the same narrowed scope: skip, no profile or email in the code", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub)
      login = G.login(cid, priv, sub, device: "WIDEDEV001", scope: G.scope("WIDEDEV001", extra: "profile email"))
      row = code_row(code_of(G.assert_skipped!(login)))
      refute row["scope"] =~ "profile"
      refute row["scope"] =~ "email"
    end

    test "a first Allow of \"openid profile email\" remembers only what the parser granted (no profile, no email token)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub, scope: G.scope("WIDEDEV002", extra: "profile email"))
      assert G.grant_row(uid, cid)["scope"] == G.remembered_scope()
    end

    test "grant with openid, request WITHOUT openid: a narrower request skips and the code carries only what was requested (no openid)", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub, openid: true)
      login = G.login(cid, priv, sub, openid: false)
      row = code_row(code_of(G.assert_skipped!(login)))
      assert row["openid_requested"] == false, "the skip never adds openid the client did not ask for"
      refute row["scope"] =~ "openid"
    end

    test "another Matrix prefix is another scope: the consent screen", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub, prefix: :unstable)
      G.login(cid, priv, sub, prefix: :stable) |> G.assert_consent!()
    end

    test "an Allow that is NARROWER than the grant narrows it: the broader request asks again afterwards", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub, openid: true)
      forced = G.login(cid, priv, sub, openid: false, prompt: "consent") |> G.assert_consent!()
      {_, _} = G.allow!(forced)
      assert G.grant_row(uid, cid)["scope"] == G.remembered_scope(openid: false)
      G.login(cid, priv, sub, openid: true) |> G.assert_consent!()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 4: changed redirect URI asks again
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 4 - a changed redirect URI asks for consent again" do
    test "allowed for A, requested for B: the consent screen; Allow MOVES the grant to B; A asks again", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub, redirect: @https)
      b = G.login(cid, priv, sub, redirect: @other) |> G.assert_consent!()
      {_, _} = G.allow!(b)
      assert G.grant_row(uid, cid)["redirect_uri"] == @other
      G.login(cid, priv, sub, redirect: @other) |> G.assert_skipped!()
      G.login(cid, priv, sub, redirect: @https) |> G.assert_consent!()
    end

    test "the redirect URI of the skipped redirect is the requested one (never the stored one of another request)", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub, redirect: @https)
      login = G.login(cid, priv, sub, redirect: @https)
      assert T.location(login.cb) |> String.starts_with?(@https <> "#")
    end

    test "loopback clients: the port is part of the requested URI, a different port asks again", %{priv: priv, sub: sub, uid: uid} do
      native = T.oauth_client!(["http://localhost/cb"], client_name: "Desktop App")
      allowed = "http://localhost:5001/cb"
      G.allow_new!(native, priv, sub, redirect: allowed)
      assert G.grant_row(uid, native)["redirect_uri"] == allowed
      G.login(native, priv, sub, redirect: allowed) |> G.assert_skipped!()
      G.login(native, priv, sub, redirect: "http://localhost:5002/cb") |> G.assert_consent!()
    end

    test "a registered URI that only differs in a query string is another URI", %{priv: priv, sub: sub} do
      with_query = T.oauth_client!([@https, @https <> "?tenant=1"])
      G.allow_new!(with_query, priv, sub, redirect: @https)
      G.login(with_query, priv, sub, redirect: @https <> "?tenant=1") |> G.assert_consent!()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 5: another user is asked; another client is asked
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 5 - another user is asked for consent" do
    test "alice allowed; bob gets the consent screen; his Allow adds HIS row and leaves alice's untouched", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      alice_before = G.grant_row(uid, cid)

      bob_sub = T.unique_sub()
      bob = T.user_id_for(%{"sub" => bob_sub})
      on_exit(fn -> G.cleanup_grants([bob]) end)

      b = G.login(cid, priv, bob_sub) |> G.assert_consent!()
      assert G.grant_count(bob) == 0
      {_, _} = G.allow!(b)
      assert G.grant_count(bob) == 1
      assert G.grant_row(uid, cid) == alice_before
      G.login(cid, priv, bob_sub) |> G.assert_skipped!()
      G.login(cid, priv, sub) |> G.assert_skipped!()
    end

    test "the same user with ANOTHER approved client is asked", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub)
      other = T.oauth_client!([@https], client_name: "Another App")
      G.login(other, priv, sub) |> G.assert_consent!()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 7: prompt=consent
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 7 - prompt=consent always shows the consent screen" do
    setup %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub)
      :ok
    end

    # cycle 1 (Kassandra LOW #2): `login` (a request for re-authentication) forces the screen too: "login", "select_account login", "create login"
    for prompt <- ["consent", "login consent", "consent login", "create consent", "select_account login consent", "login", "select_account login", "create login"] do
      test "prompt=#{inspect(prompt)} => the consent screen even though a grant exists", %{cid: cid, priv: priv, sub: sub} do
        G.login(cid, priv, sub, prompt: unquote(prompt)) |> G.assert_consent!()
      end
    end

    test "the request row carries the flag (authorize -> callback), and only when consent was asked for", %{cid: cid} do
      flag = fn prompt ->
        {_v, challenge} = T.pkce_pair()
        overrides = %{"code_challenge" => challenge, "scope" => G.scope("PROMPTDEV1")} |> then(&if(prompt, do: Map.put(&1, "prompt", prompt), else: &1))
        flow = T.start_flow(cid, @https, overrides)
        %{rows: [[f]]} = T.sql!("SELECT force_consent FROM oauth_authz_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)])
        f
      end

      assert flag.("consent") == true
      assert flag.("login consent") == true
      # SUPERSEDES the cycle 0 assertion `flag.("login") == false`
      assert flag.("login") == true
      assert flag.("select_account") == false
      assert flag.(nil) == false
    end

    test "the Allow on a forced screen REPLACES the grant (granted_at advances, scope is what was just allowed) and is NOT an error", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      T.privileged_sql!("UPDATE oauth_consent_grants SET granted_at = now() - interval '3 days' WHERE user_id = $1", [uid])
      before = G.grant_row(uid, cid)
      forced = G.login(cid, priv, sub, prompt: "consent") |> G.assert_consent!()
      {_, _} = G.allow!(forced)
      assert [after_row] = G.grant_rows(uid)
      assert DateTime.compare(after_row["granted_at"], before["granted_at"]) == :gt
      assert after_row["created_at"] == before["created_at"]
    end

    test "prompt=consent does not stick: the next login WITHOUT it skips again", %{cid: cid, priv: priv, sub: sub} do
      forced = G.login(cid, priv, sub, prompt: "consent") |> G.assert_consent!()
      {_, _} = G.allow!(forced)
      G.login(cid, priv, sub) |> G.assert_skipped!()
    end

    # SUPERSEDES the cycle 0 list ["login", "select_account", "consentx", "CONSENT"]: `login` moved to the forcing values above
    test "other prompt values do not force the screen: select_account, lookalikes (consentx, loginx), upper case", %{cid: cid, priv: priv, sub: sub} do
      for prompt <- ["select_account", "consentx", "CONSENT", "loginx", "LOGIN"] do
        G.login(cid, priv, sub, prompt: prompt) |> G.assert_skipped!()
      end
    end

    test "prompt=none stays login_required: no code, no consent, with or without a grant", %{cid: cid, sub: _sub} do
      pairs = T.authorize_params(cid, @https, %{"prompt" => "none", "scope" => G.scope()})
      conn = T.authorize(pairs)
      assert conn.status == 302
      {_base, _mode, params, _} = T.client_redirect(conn)
      assert params["error"] == "login_required"
      refute Map.has_key?(params, "code")
    end

    test "prompt=none combined with login or consent is invalid_request (unchanged), never a code", %{cid: cid} do
      for prompt <- ["none login", "none consent"] do
        conn = T.authorize(T.authorize_params(cid, @https, %{"prompt" => prompt, "scope" => G.scope()}))
        assert conn.status == 302
        {_base, _mode, params, _} = T.client_redirect(conn)
        assert params["error"] == "invalid_request"
        refute Map.has_key?(params, "code")
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # the store is unreadable / hygiene
  # ════════════════════════════════════════════════════════════════════════════

  describe "fail towards asking" do
    test "the grant table cannot be read at the callback: the consent screen is shown (never a skip, never an error page), and the Allow works", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub)

      login = G.with_table_unreadable(fn -> G.login(cid, priv, sub) end) |> G.assert_consent!()
      {_conn, code} = G.allow!(login)
      assert is_binary(code)
    end
  end

  describe "log hygiene" do
    test "skip and Allow log ids only: no code, state, nonce, challenge, verifier, IdP refresh token, scope or redirect URI; the skip leaves an INFO line with the ids", %{priv: priv, sub: sub} do
      canary = T.rand(8)
      redirect = "https://app.example.com/cb-" <> canary
      cid = T.oauth_client!([redirect], client_name: "LogApp-" <> canary, client_uri: G.website())
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      nonce = "nonce-" <> canary
      state = "state-" <> canary
      idp_rt = "idp-rt-" <> canary

      {{first, second}, log} =
        with_log(fn ->
          first = G.allow_new!(cid, priv, sub, redirect: redirect, nonce: nonce, state: state, idp_rt: idp_rt)
          second = G.login(cid, priv, sub, redirect: redirect, nonce: nonce, state: state, idp_rt: idp_rt)
          {first, second}
        end)

      params = G.assert_skipped!(second)
      secrets = [canary, first.code, params["code"], first.verifier, second.verifier, T.param(second.flow.pairs, "code_challenge"), "urn:matrix:org.matrix.msc2967.client:api:*"]
      for s <- secrets, do: refute(String.contains?(log, s), "#{String.slice(s, 0, 12)}... leaked into the log")
      assert log =~ "client_id=#{cid}", "the INFO lines name the client id"
      assert log =~ ~r/user_id=@/, "and the user id"
    end
  end

  defp drain(acc) do
    receive do
      {:q, q} -> drain([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
