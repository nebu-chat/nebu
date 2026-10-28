defmodule Nebu.OAuth.OAuthAccountHardeningTest do
  @moduledoc """
  Acceptance tests for story `oauth-account-management` (story 6 of epic oauth-broker):
  the test-review MAJORs M1-M8 and the cheap MINORs (2026-10-10,
  `step-results/oauth-account-management/test-review-findings.md`):

    * M1 https detection incl. `X-Forwarded-Proto` (`__Host-` cookie, Secure binding cookie, the
      unprefixed cookie ignored on https, logout clears the `__Host-` cookie);
    * M2 open-redirect safety of the callback target and of `/account/reauth`;
    * M3 CSRF on EVERY POST endpoint x token / Origin / Sec-Fetch-Site matrix, CSRF before freshness;
    * M4 isolated absolute timeout, sliding never refreshes `auth_time`, the 300 s freshness boundary;
    * M5 an approved-but-unconsumed UIA session is never re-issued to an auth-less request;
    * M6 concurrency (parallel approves, parallel uploads with one approval, parallel callbacks);
    * M7 the supplied-keys-only "unchanged" matrix and the ALL-keys binding of the approval;
    * M8 XSS: attacker-controlled names escaped on every page;
    * MINORs: a11y hooks, A12 fields, AC2 gaps (not-live callback consumes nothing, nonce mismatch,
      encrypted verifier, soft cap, csrf plaintext never stored), malformed `auth`, purge of an
      idle-expired session, logging of failure paths.

  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @proxy [{"x-forwarded-proto", "https"}]

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  defp dev, do: "HD" <> String.upcase(T.rand(4))
  defp now, do: System.system_time(:second)
  defp q(pairs), do: "/account?" <> URI.encode_query(pairs)
  defp user! do
    sub = T.unique_sub()
    %{sub: sub, uid: T.provision_user!(sub)}
  end

  # ════════════════════════════════════════════════════════════════════════════
  # M1 — https detection incl. X-Forwarded-Proto
  # ════════════════════════════════════════════════════════════════════════════

  describe "M1 — https behind a proxy (X-Forwarded-Proto: https)" do
    test "binding cookie Secure; session cookie __Host-nebu_account, Secure, Path=/", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!("/account", headers: @proxy)
      {bname, _} = flow.binding
      assert T.raw_set_cookie(flow.conn, bname) =~ ~r/secure/i, "the binding cookie is Secure on https"
      cb = T.account_finish(flow, priv, sub, headers: @proxy)
      assert cb.status == 303
      raw = T.raw_set_cookie(cb, "__Host-nebu_account") || flunk("no __Host- cookie behind an https proxy: #{inspect(T.set_cookies(cb))}")
      assert raw =~ ~r/secure/i and raw =~ ~r/path=\/(;|$)/i
    end

    test "on https the UNPREFIXED cookie is ignored (cookie tossing) => IdP login" do
      %{uid: uid} = user!()
      s = T.account_session!(uid)
      conn = T.account_get("/account", cookies: [{"nebu_account", s.cookie}], headers: @proxy)
      assert conn.status == 302
      conn2 = T.account_get("/account", cookies: [{"nebu_account", s.cookie}], https: true)
      assert conn2.status == 302
    end

    test "logout on https clears the __Host- cookie (Max-Age=0, Path=/, Secure)" do
      %{uid: uid} = user!()
      s = T.account_session!(uid)
      conn = T.account_post("/account/logout", [{"csrf_token", s.csrf}], cookies: [{"__Host-nebu_account", s.cookie}], headers: @proxy)
      assert conn.status == 200
      raw = T.raw_set_cookie(conn, "__Host-nebu_account")
      assert raw =~ ~r/max-age=0/i and raw =~ ~r/secure/i and raw =~ ~r/path=\/(;|$)/i
      assert T.account_session_row(s.cookie) == nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # M2 — open redirect
  # ════════════════════════════════════════════════════════════════════════════

  describe "M2 — the redirect target is server-built, relative and encoded" do
    defp assert_safe_location(loc) do
      assert is_binary(loc)
      refute loc =~ ~r/[\r\n]/
      assert String.starts_with?(loc, "/account")
      refute String.starts_with?(loc, "//")
      uri = URI.parse(loc)
      assert uri.host == nil and uri.scheme == nil
      assert uri.path == "/account"
      assert uri.fragment == nil
      uri
    end

    test "a hostile callback query (action / redirect / return / device_id) cannot steer the target", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!("/account?action=org.matrix.profile")
      T.stub_idp_exchange({:ok, T.sign_id_token(priv, %{"sub" => sub, "nonce" => flow.nonce, "auth_time" => now()}), nil})

      cb =
        T.callback(
          [{"code", "c-" <> T.rand()}, {"state", flow.state}, {"action", "org.matrix.device_delete"}, {"device_id", "EVIL"},
           {"redirect", "https://evil.example.com"}, {"return", "//evil.example.com"}],
          [flow.binding]
        )

      assert cb.status == 303
      assert T.location(cb) == "/account?action=org.matrix.profile"
    end

    for hostile <- ["X&action=org.matrix.profile", "X#frag", "//evil.example.com", "/../evil", "a\r\nSet-Cookie: x=y"] do
      test "return_device_id #{inspect(hostile)} => Location relative + encoded (or the default page)", %{priv: priv} do
        %{sub: sub} = user!()
        flow = T.account_start!(q([{"action", "org.matrix.device_view"}, {"device_id", unquote(hostile)}]))
        cb = T.account_finish(flow, priv, sub)
        assert cb.status == 303
        uri = assert_safe_location(T.location(cb))
        params = URI.decode_query(uri.query || "")
        assert params["action"] in [nil, "org.matrix.device_view"]
        if params["device_id"], do: assert(params["device_id"] == unquote(hostile)), else: :ok
        refute Enum.any?(cb.resp_headers, fn {k, v} -> k == "set-cookie" and v =~ "x=y" end)
      end
    end

    test "/account/reauth with a hostile action / device_id records a safe target", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      acct = T.account_session!(uid)
      flow = T.account_start!("/account/reauth?action=https%3A%2F%2Fevil.example.com&device_id=%2F%2Fevil.example.com", cookie: acct.cookie)
      cb = T.account_finish(flow, priv, sub)
      assert_safe_location(T.location(cb))
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # M3 — CSRF on every POST, matrix
  # ════════════════════════════════════════════════════════════════════════════

  describe "M3 — CSRF matrix: every POST endpoint x token / Origin / Sec-Fetch-Site" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      assert T.device_signing_upload(s.at, T.cross_signing_keys(uid, "OLD")).status == 200
      ch = T.device_signing_upload(s.at, T.cross_signing_keys(uid, "NEW"))
      {:ok, uid: uid, s: s, sid: T.json(ch)["session"], acct: T.account_session!(uid), other: T.account_session!(T.provision_user!())}
    end

    defp endpoints(ctx) do
      [
        {"/account/devices/delete", [{"device_id", ctx.s.device_id}]},
        {"/account/cross_signing_reset/approve", [{"session_id", ctx.sid}]},
        {"/account/cross_signing_reset/decline", [{"session_id", ctx.sid}]},
        {"/account/logout", []}
      ]
    end

    defp variants(ctx) do
      ok = [{"csrf_token", ctx.acct.csrf}]

      [
        {"missing token", [], []},
        {"wrong token", [{"csrf_token", "wrong-" <> T.rand()}], []},
        {"other session's token", [{"csrf_token", ctx.other.csrf}], []},
        {"foreign Origin", ok, [{"origin", "https://evil.example.com"}]},
        {"look-alike Origin", ok, [{"origin", "https://nebu.example.com.evil.com"}]},
        {"Origin null", ok, [{"origin", "null"}]},
        {"other scheme", ok, [{"origin", "http://nebu.example.com"}]},
        {"other port", ok, [{"origin", "https://nebu.example.com:8443"}]},
        {"cross-site fetch", ok, [{"sec-fetch-site", "cross-site"}]},
        # review cycle 1 (M3): the shared BrowserPost check is stricter than the story-6 one: only same-origin (or an
        # absent header) passes, so a sibling-site and a user-typed (`none`) request are refused too
        {"same-site fetch", ok, [{"sec-fetch-site", "same-site"}]},
        {"user-typed navigation (none)", ok, [{"sec-fetch-site", "none"}]}
      ]
    end

    test "every endpoint x variant => 403 forbidden, nothing changed, the session stays", ctx do
      before = {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)}

      for {path, params} <- endpoints(ctx), {label, tok, headers} <- variants(ctx) do
        conn = T.account_post(path, params ++ tok, cookie: ctx.acct.cookie, headers: headers)
        assert conn.status == 403, "#{path} / #{label}: expected 403, got #{conn.status}"
        T.assert_account_error(conn, 403, "forbidden")
      end

      assert {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)} == before
      assert T.account_session_row(ctx.acct.cookie), "the session stays valid"
      assert T.whoami(ctx.s.at).status == 200
    end

    test "the token check is independent of the Origin check (same Origin, wrong token => 403)", ctx do
      conn = T.account_post("/account/devices/delete", [{"device_id", ctx.s.device_id}, {"csrf_token", "wrong"}],
               cookie: ctx.acct.cookie, headers: [{"origin", "https://nebu.example.com"}, {"sec-fetch-site", "same-origin"}])

      T.assert_account_error(conn, 403, "forbidden")
    end

    test "CSRF is checked BEFORE freshness: stale session + wrong token => 403 forbidden (not 303 stale)", ctx do
      stale = T.account_session!(ctx.uid, auth_time: now() - 400)
      conn = T.account_post("/account/devices/delete", [{"device_id", ctx.s.device_id}, {"csrf_token", "wrong"}], cookie: stale.cookie)
      T.assert_account_error(conn, 403, "forbidden")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # story oauth-client-revocation (P4), AC7.4 / SO2 — STRICT fetch metadata on the reset approval
  # ════════════════════════════════════════════════════════════════════════════
  #
  # `POST /account/cross_signing_reset/approve` is the one `/account` action that hands out the right to
  # replace the user's cross-signing keys: it now needs all four fetch-metadata headers of a user-clicked
  # form submit (`Nebu.OAuth.BrowserPost.check(conn, issuer, strict: true)`, the ONE shared copy). Decline,
  # device delete and logout keep their lenient rules (absent headers pass, a present wrong one is refused).

  describe "AC7.4 — POST /account/cross_signing_reset/approve: strict fetch metadata (SO2)" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      assert T.device_signing_upload(s.at, T.cross_signing_keys(uid, "OLD")).status == 200
      ch = T.device_signing_upload(s.at, T.cross_signing_keys(uid, "NEW"))
      {:ok, uid: uid, s: s, sid: T.json(ch)["session"], acct: T.account_session!(uid)}
    end

    @strict_pairs [{"sec-fetch-site", "same-origin"}, {"sec-fetch-mode", "navigate"}, {"sec-fetch-dest", "document"}, {"sec-fetch-user", "?1"}]

    defp approve_post(ctx, headers) do
      T.account_post("/account/cross_signing_reset/approve", [{"session_id", ctx.sid}, {"csrf_token", ctx.acct.csrf}],
        cookie: ctx.acct.cookie,
        headers: [{"origin", T.issuer()} | headers]
      )
    end

    test "Origin + all four headers => 303 reset_approved", ctx do
      conn = approve_post(ctx, @strict_pairs)
      assert conn.status == 303, "got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
      assert T.notice_of(conn) == "reset_approved"
    end

    test "without ANY fetch metadata (older browser, scripted client) => 403 forbidden, nothing approved", ctx do
      before = {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)}
      T.assert_account_error(approve_post(ctx, []), 403, "forbidden")
      assert {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)} == before
      assert T.account_session_row(ctx.acct.cookie), "the session stays"
    end

    for {name, _} <- @strict_pairs do
      test "#{name} absent => 403 forbidden, nothing approved; the identical request WITH it is approved", ctx do
        before = {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)}
        partial = List.keydelete(@strict_pairs, unquote(name), 0)
        T.assert_account_error(approve_post(ctx, partial), 403, "forbidden")
        assert {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)} == before

        assert approve_post(ctx, @strict_pairs).status == 303
      end
    end

    test "wrong values (fetch / iframe / sibling site / not user-activated) => 403, nothing approved", ctx do
      before = {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)}

      for {label, replace} <- [
            {"mode cors", {"sec-fetch-mode", "cors"}},
            {"dest iframe", {"sec-fetch-dest", "iframe"}},
            {"dest empty", {"sec-fetch-dest", "empty"}},
            {"site same-site", {"sec-fetch-site", "same-site"}},
            {"site none", {"sec-fetch-site", "none"}},
            {"user ?0", {"sec-fetch-user", "?0"}}
          ] do
        {k, _} = replace
        headers = List.keyreplace(@strict_pairs, k, 0, replace)
        T.assert_account_error(approve_post(ctx, headers), 403, "forbidden")
        assert {T.world_snapshot([ctx.uid]), T.uia_rows(ctx.uid)} == before, label
      end
    end

    test "the strict level does not weaken the rest: wrong CSRF token / foreign Origin with all four headers => 403", ctx do
      bad_csrf = T.account_post("/account/cross_signing_reset/approve", [{"session_id", ctx.sid}, {"csrf_token", "wrong"}], cookie: ctx.acct.cookie, headers: [{"origin", T.issuer()} | @strict_pairs])
      T.assert_account_error(bad_csrf, 403, "forbidden")
      foreign = T.account_post("/account/cross_signing_reset/approve", [{"session_id", ctx.sid}, {"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie, headers: [{"origin", "https://evil.example.com"} | @strict_pairs])
      T.assert_account_error(foreign, 403, "forbidden")
    end

    test "decline, device delete and logout keep their LENIENT rules: absent headers still work, a present wrong one is refused", ctx do
      decline = T.account_post("/account/cross_signing_reset/decline", [{"session_id", ctx.sid}, {"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie)
      assert decline.status == 303 and T.notice_of(decline) == "reset_declined"

      refused = T.account_post("/account/cross_signing_reset/decline", [{"session_id", ctx.sid}, {"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie, headers: [{"sec-fetch-dest", "iframe"}])
      T.assert_account_error(refused, 403, "forbidden")

      delete = T.account_post("/account/devices/delete", [{"device_id", ctx.s.device_id}, {"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie)
      assert delete.status == 303, "got #{delete.status}"

      logout = T.account_post("/account/logout", [{"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie)
      assert logout.status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # M4 — timeouts and freshness boundary
  # ════════════════════════════════════════════════════════════════════════════

  describe "M4 — absolute timeout, auth_time never slides, 300 s boundary" do
    test "absolute expiry alone (idle in the future, expires_at past) => no session" do
      %{uid: uid} = user!()
      s = T.account_session!(uid, created_sql: "now() - interval '3599 seconds'", idle_sql: "now() - interval '2 seconds'", expires_sql: "now() - interval '1 second'")
      T.sql!("UPDATE oauth_account_sessions SET idle_expires_at = expires_at WHERE session_hash = $1", [s.hash])
      assert T.account_get("/account", cookie: s.cookie).status == 302
    end

    test "sliding the idle timeout never refreshes auth_time" do
      %{uid: uid} = user!()
      at = now() - 200
      s = T.account_session!(uid, auth_time: at)
      T.account_get("/account", cookie: s.cookie) |> T.assert_account_page("default")
      assert T.account_session_row(s.cookie)["auth_time"] == at
    end

    test "freshness boundary: auth_time 290 s ago => the delete form; 300 s ago => stale (reauth link)", %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      path = q([{"action", "org.matrix.device_delete"}, {"device_id", s.device_id}])
      fresh = T.account_session!(uid, auth_time: now() - 290)
      assert T.account_get(path, cookie: fresh.cookie).resp_body =~ ~s(data-role="delete-device-confirm")
      stale = T.account_session!(uid, auth_time: now() - 300)
      body = T.account_get(path, cookie: stale.cookie).resp_body
      assert body =~ ~s(data-role="reauth")
      refute body =~ ~s(data-role="delete-device-confirm")
    end

    # story oauth-authorize-freshness (FR14): a NULL auth_time is NEVER fresh, at no age, and it is told
    # apart from a stale one: no reauth link (the IdP would not report a time next time either: a loop)
    test "FR14: auth_time NULL => never fresh and NO reauth link (unlike a stale session)", %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      path = q([{"action", "org.matrix.device_delete"}, {"device_id", s.device_id}])
      acct = T.account_session!(uid, auth_time: nil)
      body = T.account_get(path, cookie: acct.cookie).resp_body
      refute body =~ ~s(data-role="delete-device-confirm")
      refute body =~ ~s(data-role="reauth")
      assert body =~ ~s(data-notice="freshness_unavailable")
    end

    test "FR14: sliding the idle timeout keeps a NULL auth_time NULL", %{} do
      %{uid: uid} = user!()
      s = T.account_session!(uid, auth_time: nil)
      T.account_get("/account", cookie: s.cookie) |> T.assert_account_page("default")
      assert T.account_session_row(s.cookie)["auth_time"] == nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # M5, M6, M7 — m.oauth session reuse, concurrency, key binding
  # ════════════════════════════════════════════════════════════════════════════

  describe "M5-M7 — m.oauth sessions" do
    setup %{priv: priv, cid: cid} do
      sub = T.unique_sub()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      assert T.device_signing_upload(s.at, T.cross_signing_keys(s.user_id, "OLD")).status == 200
      {:ok, s: s, uid: s.user_id, sub: sub}
    end

    defp challenge(s, body) do
      conn = T.device_signing_upload(s.at, body)
      assert conn.status == 401, "expected the m.oauth challenge, got #{conn.status}: #{conn.resp_body}"
      T.json(conn)["session"]
    end

    defp approve(uid, sid), do: apply(Nebu.Matrix, :approve_cross_signing_reset, [uid, sid])
    defp mix(uid, m, sk, uk), do: %{"master_key" => T.cross_signing_keys(uid, m)["master_key"], "self_signing_key" => T.cross_signing_keys(uid, sk)["self_signing_key"], "user_signing_key" => T.cross_signing_keys(uid, uk)["user_signing_key"]}
    defp old_keys(uid), do: assert(Nebu.Matrix.CrossSigningKeyStore.get_keys(uid) == T.cross_signing_keys(uid, "OLD"), "keys unchanged")

    test "M5: an APPROVED but unconsumed session is never re-issued to an auth-less request (a NEW session is minted)", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = challenge(ctx.s, body)
      :ok = approve(ctx.uid, sid)
      again = challenge(ctx.s, body)
      refute again == sid
      assert T.uia_row(sid)["consumed"] == false and T.uia_row(sid)["stage_complete"] == true
      old_keys(ctx.uid)
    end

    test "M6: two parallel approvals of one session => exactly one :ok", ctx do
      sid = challenge(ctx.s, T.cross_signing_keys(ctx.uid, "NEW"))
      results = for _ <- 1..2, do: Task.async(fn -> approve(ctx.uid, sid) end)
      results = Enum.map(results, &Task.await(&1, 10_000))
      assert Enum.count(results, &(&1 == :ok)) == 1, inspect(results)
      assert Enum.count(results, &(&1 == {:error, :not_found})) == 1
    end

    test "M6: two parallel uploads with the same approved session => one consume, keys = the new keys, never 500", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = challenge(ctx.s, body)
      :ok = approve(ctx.uid, sid)
      tasks = for _ <- 1..2, do: Task.async(fn -> T.device_signing_upload(ctx.s.at, Map.put(body, "auth", %{"session" => sid})).status end)
      statuses = Enum.map(tasks, &Task.await(&1, 10_000))
      assert Enum.all?(statuses, &(&1 in [200, 401])), inspect(statuses)
      assert 200 in statuses
      assert Nebu.Matrix.CrossSigningKeyStore.get_keys(ctx.uid)["master_key"] == body["master_key"]
      assert T.uia_row(sid)["consumed"] == true
    end

    test "M6: two parallel callbacks on one state => exactly one 303 and one session", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      flow = T.account_start!()
      tasks = for _ <- 1..2, do: Task.async(fn -> T.account_finish(flow, priv, sub).status end)
      statuses = tasks |> Enum.map(&Task.await(&1, 10_000)) |> Enum.sort()
      assert statuses == [303, 400], inspect(statuses)
      assert T.account_session_count(uid) == 1
    end

    test "M7: master matches + SSK or USK different => replacement (challenge); USK-only; SSK-only with the OLD SSK (no master)", ctx do
      for body <- [mix(ctx.uid, "OLD", "NEW", "OLD"), mix(ctx.uid, "OLD", "OLD", "NEW"),
                   Map.take(T.cross_signing_keys(ctx.uid, "NEW"), ["user_signing_key"]),
                   Map.take(T.cross_signing_keys(ctx.uid, "OLD"), ["self_signing_key"])] do
        _ = challenge(ctx.s, body)
        old_keys(ctx.uid)
      end
    end

    test "M7: legacy callers: master match + different SSK, USK-only => 403", %{priv: priv} do
      lsub = T.unique_sub()
      luid = T.provision_user!(lsub)
      legacy = T.legacy_session!(luid, dev())
      assert T.device_signing_upload(legacy.at, T.cross_signing_keys(luid, "OLD")).status == 200

      for body <- [mix(luid, "OLD", "NEW", "OLD"), Map.take(T.cross_signing_keys(luid, "NEW"), ["user_signing_key"])] do
        assert T.device_signing_upload(legacy.at, body).status == 403
      end

      _ = priv
    end

    test "M7 design decision: the approval is bound to ALL supplied keys: swapping SSK/USK after approval => new challenge", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = challenge(ctx.s, body)
      :ok = approve(ctx.uid, sid)
      swapped = Map.put(body, "self_signing_key", T.cross_signing_keys(ctx.uid, "SWAP")["self_signing_key"])
      new_sid = challenge(ctx.s, Map.put(swapped, "auth", %{"session" => sid}))
      refute new_sid == sid
      old_keys(ctx.uid)
      assert T.uia_row(sid)["consumed"] == false
      assert T.uia_row(new_sid)["params"] =~ T.keys_hash(swapped)
    end

    test "malformed auth (non-binary session, auth not a map, missing session) => a challenge, never a 500", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")

      for auth <- [%{"session" => 123}, "x", %{"type" => "m.oauth"}, %{"session" => nil}, []] do
        conn = T.device_signing_upload(ctx.s.at, Map.put(body, "auth", auth))
        assert conn.status == 401, "auth #{inspect(auth)}: got #{conn.status}: #{conn.resp_body}"
      end

      old_keys(ctx.uid)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # M8 — XSS
  # ════════════════════════════════════════════════════════════════════════════

  describe "M8 — attacker-controlled names are escaped on every page" do
    @xss "<script>alert('x')</script>"

    test "device display name, client name, device id, profile display name: confirmation, device_view, reset page, profile, list", %{priv: priv} do
      cid = T.oauth_client!([@https], client_name: "App " <> @xss)
      sub = T.unique_sub()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      uid = s.user_id
      Nebu.Matrix.DeviceKeyStore.rename_device(uid, s.device_id, "Phone " <> @xss)
      d = "XSS<b>" <> T.rand(2)
      Nebu.Matrix.DeviceKeyStore.upsert_device(uid, d, display_name: "Tablet " <> @xss)
      _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Name " <> @xss, nil)
      assert T.device_signing_upload(s.at, T.cross_signing_keys(uid, "OLD")).status == 200
      assert T.device_signing_upload(s.at, T.cross_signing_keys(uid, "NEW")).status == 401
      acct = T.account_session!(uid)

      pages = [
        q([{"action", "org.matrix.devices_list"}]),
        q([{"action", "org.matrix.device_view"}, {"device_id", d}]),
        q([{"action", "org.matrix.device_delete"}, {"device_id", d}]),
        q([{"action", "org.matrix.cross_signing_reset"}]),
        q([{"action", "org.matrix.profile"}]),
        "/account"
      ]

      for path <- pages do
        body = T.account_get(path, cookie: acct.cookie).resp_body
        refute body =~ "<script>alert", "#{path}: unescaped script (the reset page legitimately embeds the one pinned click-proof script, story safari-fetch-metadata-compat)"
        refute body =~ "XSS<b>", "#{path}: unescaped device id"
      end

      assert T.account_get(q([{"action", "org.matrix.device_view"}, {"device_id", d}]), cookie: acct.cookie).resp_body =~ "&lt;script&gt;"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # MINORs — a11y hooks, A12 fields, AC2 gaps, purge, logging of failure paths
  # ════════════════════════════════════════════════════════════════════════════

  describe "MINOR — accessibility hooks on action pages (A20)" do
    test "lang/viewport, nav aria-label, th scope=row, accessible names with the device name, role=status / role=alert notices", %{priv: priv, cid: cid} do
      sub = T.unique_sub()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      Nebu.Matrix.DeviceKeyStore.rename_device(s.user_id, s.device_id, "Work Phone")
      acct = T.account_session!(s.user_id)

      list = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie).resp_body
      assert list =~ ~r/<html[^>]*lang="en"/ and list =~ ~r/name="viewport"/
      assert list =~ ~r/<nav[^>]*aria-label="Account"/
      assert list =~ ~s(scope="row")
      assert list =~ ~r/Sign out Work Phone/

      confirm = T.account_get(q([{"action", "org.matrix.device_delete"}, {"device_id", s.device_id}]), cookie: acct.cookie).resp_body
      assert confirm =~ ~r/<button[^>]*type="submit"[^>]*>[^<]*Sign out Work Phone/

      ok = T.account_get("/account?notice=device_deleted", cookie: acct.cookie).resp_body
      assert ok =~ ~r/role="status"[^>]*data-notice="device_deleted"|data-notice="device_deleted"[^>]*role="status"/
      err = T.account_get(q([{"action", "org.matrix.device_view"}, {"device_id", "UNKNOWN"}]), cookie: acct.cookie).resp_body
      assert err =~ ~r/role="alert"[^>]*data-notice="device_not_found"|data-notice="device_not_found"[^>]*role="alert"/
    end
  end

  describe "MINOR — A12 device fields" do
    test "Last active (YYYY-MM-DD HH:MM UTC / Never), last IP, Added, the app label; NULLS LAST", %{priv: priv, cid: cid} do
      sub = T.unique_sub()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      seen = dev()
      Nebu.Matrix.DeviceKeyStore.upsert_device(s.user_id, seen, last_seen_ts: 1_700_000_000_000, last_seen_ip: "198.51.100.7")
      never = dev()
      T.sql!("INSERT INTO devices (user_id, device_id, created_at, updated_at) VALUES ($1, $2, 1700000000000, 1700000000000)", [s.user_id, never])
      T.sql!("UPDATE devices SET last_seen_ts = NULL WHERE user_id = $1 AND device_id = $2", [s.user_id, never])
      acct = T.account_session!(s.user_id)

      body = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie).resp_body
      assert body =~ "2023-11-14 22:13 UTC", "Last active formatted YYYY-MM-DD HH:MM UTC"
      assert body =~ "Never"
      assert body =~ "198.51.100.7"
      assert body =~ "Added"
      assert body =~ "App (name claimed by the app)"
      ids = Regex.scan(~r/data-role="account-device"[^>]*data-device-id="([^"]+)"/, body) |> Enum.map(&List.last/1)
      assert List.last(ids) == never, "NULLS LAST"
    end
  end

  describe "MINOR — AC2 gaps" do
    test "a callback while OAuth is not live consumes nothing (404 unavailable, row kept)", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      T.disable_oauth()
      T.account_finish(flow, priv, sub) |> T.assert_account_error(404, "unavailable")
      assert T.sql!("SELECT 1 FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)]).num_rows == 1
    end

    test "a story-2 o2. state still reaches the authorize branch (its oauth-error page, not an account page)" do
      state = "o2." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      cb = T.callback([{"code", "c"}, {"state", state}])
      assert cb.resp_body =~ ~s(data-page="oauth-error")
      refute cb.resp_body =~ "account-error"
    end

    test "nonce mismatch => no session (access_denied)", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      cb = T.account_finish(flow, priv, sub, claims: %{"nonce" => "wrong-nonce"})
      assert cb.status in [403, 503]
      assert T.account_cookie_from(cb) == nil
    end

    test "the IdP PKCE verifier is stored encrypted and matches the sent challenge; no plaintext csrf stored", %{priv: priv} do
      flow = T.account_start!()
      %{rows: [[enc]]} = T.sql!("SELECT idp_verifier_enc FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)])
      assert {:ok, verifier} = Nebu.Web.SecretBox.decrypt(enc)
      refute enc == verifier
      assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == flow.idp["code_challenge"]

      %{sub: sub} = user!()
      login = T.account_login!(priv, sub)
      row = T.account_session_row(login.cookie)
      refute Enum.any?(Map.values(row), &(&1 == login.csrf)), "the CSRF token is never stored in plaintext"
      assert row["csrf_hash"] == T.sha256_hex(login.csrf)
    end

    test "the login-request soft cap (10 000 live rows) => 503 unavailable, nothing inserted" do
      T.privileged_sql!(
        "INSERT INTO oauth_account_login_requests (state_hash, idp_verifier_enc, idp_nonce, binding_hash, return_action, created_at, expires_at) " <>
          "SELECT encode(sha256(('atdd-cap-' || g)::bytea), 'hex'), 'enc', 'n', encode(sha256(('b' || g)::bytea), 'hex'), NULL, now(), now() + interval '9 minutes' " <>
          "FROM generate_series(1, 10000) g"
      )

      on_exit(fn -> T.privileged_sql!("DELETE FROM oauth_account_login_requests WHERE idp_verifier_enc = 'enc' AND idp_nonce = 'n'") end)
      T.account_get("/account") |> T.assert_account_error(503, "unavailable")
    end
  end

  describe "MINOR — purge of an idle-expired session; logging of failure paths" do
    test "an idle-expired session whose absolute expiry is still in the future is purged too" do
      %{uid: uid} = user!()
      s = T.account_session!(uid, idle_sql: "now() - interval '1 second'")
      assert {:ok, _} = apply(Nebu.OAuth, :purge_expired_account_state, [])
      assert T.account_session_row(s.cookie) == nil
    end

    test "failure paths (invalid_state, forbidden, reauth_failed) log no secret", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      acct = T.account_session!(uid)
      flow = T.account_start!()

      log =
        capture_log(fn ->
          _ = T.account_finish(flow, priv, sub, cookies: [])
          _ = T.account_finish(flow, priv, sub)
          _ = T.account_post("/account/logout", [{"csrf_token", "wrong"}], cookie: acct.cookie)
          f2 = T.account_start!()
          _ = T.account_finish(f2, priv, sub, claims: %{"auth_time" => now() - 3600})
        end)

      T.refute_secrets_in_log(log, %{state: flow.state, binding: elem(flow.binding, 1), cookie: acct.cookie, csrf: acct.csrf,
                                     state_hash: T.sha256_hex(flow.state), cookie_hash: acct.hash})
    end
  end
end
