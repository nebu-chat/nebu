defmodule Nebu.OAuth.ConsentGrantAccountTest do
  @moduledoc """
  Story `persistent-consent-grants` (REQ-2026-003), scenario 9 and the UI around it: the list of allowed apps and the withdrawal on the OAuth
  account page (`Nebu.OAuth.Account` / `Nebu.OAuth.AccountPages`, story oauth-account-management). Real database, `--include integration`.

  ## Contract (names are the ATDD agent's)

    * `GET /account/apps` - a new account page: `<main data-page="account" data-action="apps">`, ONE `<h1>`, the account nav gains a link "Apps"
      (`/account/apps`, `aria-current="page"` on that page), a `<ul>` / table of the user's OWN valid grants (approved client, matching binding), one
      `data-role="consent-grant" data-client-id="<id>"` row each with the app name as CLAIMED by the app (HTML-escaped; labelled as such by the
      column / label text), the website host, and a form `POST /account/apps/withdraw` (hidden `csrf_token` and `client_id`, a button
      `data-role="withdraw-grant"` whose `aria-label` names the app). No grants: `data-role="no-grants"`. A `data-role="grants-note"` says that
      withdrawing does NOT sign out devices that are already signed in (use "Devices" for that). No script, the usual CSP and headers of every account page.
    * `POST /account/apps/withdraw` (`csrf_token`, `client_id`): the same CSRF + `BrowserPost` rules as the device sign-out (lenient fetch metadata); a
      session without a valid cookie => `303 /account` (like every account POST). Result `303` PRG to `/account/apps?notice=grant_withdrawn` or
      `grant_not_found`; the two notice codes are added to `AccountPages.notice_codes/0` (`grant_withdrawn`: success, `role="status"`;
      `grant_not_found`: problem, `role="alert"`).
    * DECISIONS: (1) a withdrawal is NOT gated on a fresh sign-in (it only takes a convenience away; the destructive actions of the page are); (2) it
      does NOT revoke existing sessions or refresh tokens of that app (the story: "her NEXT authorization request shows the consent screen"; signing a
      device out is the explicit, fresh-session-gated action of the Devices page); (3) a user can only withdraw their OWN grant: the row is selected by
      the session's user id AND the client id, a foreign or unknown client id is `grant_not_found` and nothing changes.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.TestSupport, as: T

  @https G.https()

  setup do
    env = G.setup_env!()
    sub = T.unique_sub()
    # provisioned: the account page answers `no_account` for a user the server does not know
    uid = T.provision_user!(sub)
    on_exit(fn -> G.cleanup_grants([uid]) end)
    {:ok, Map.merge(env, %{sub: sub, uid: uid})}
  end

  defp user! do
    sub = T.unique_sub()
    uid = T.provision_user!(sub)
    on_exit(fn -> G.cleanup_grants([uid]) end)
    %{sub: sub, uid: uid}
  end

  # ════════════════════════════════════════════════════════════════════════════
  # the page
  # ════════════════════════════════════════════════════════════════════════════

  describe "GET /account/apps" do
    test "lists the user's allowed apps with a withdraw form each; page contract, nav link, headers, one h1, no script", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      # cycle 1 (Kassandra INFO #4): the column shows the STORED, verified `client_host`; the registration of a real client has one
      G.set_client_host!(cid, "app.example.com")
      G.allow_new!(cid, priv, sub)
      # a session through the REAL sign-in: the page's CSRF token is the one derived from the cookie (`acct.csrf` is read from the landing page)
      acct = T.account_login!(priv, sub)
      assert uid == T.user_id_for(%{"sub" => sub})

      conn = G.apps_get(acct)
      T.assert_account_page(conn, "apps")
      body = conn.resp_body

      assert body =~ ~s(data-role="consent-grant")
      assert body =~ ~s(data-client-id="#{cid}")
      assert body =~ "Grant Test App"
      assert body =~ ~r/Website: app\.example\.com/, "the stored (verified) host of the client"
      assert body =~ ~s(action="/account/apps/withdraw")
      assert body =~ ~r/method="post"/i
      assert body =~ ~r/name="client_id"\s+value="#{cid}"|value="#{cid}"\s+name="client_id"/
      assert T.csrf_from(conn) == acct.csrf, "the form carries the CSRF token of the session"
      assert body =~ ~s(data-role="withdraw-grant")
      assert body =~ ~r/aria-label="[^"]*Grant Test App[^"]*"/, "the control's accessible name names the app"
      assert length(Regex.scan(~r/<h1[\s>]/, body)) == 1
      refute body =~ ~r/<script/i
      assert body =~ ~s(href="/account/apps"), "the nav links to the page"
      assert body =~ ~r/<a href="\/account\/apps"[^>]*aria-current="page"[^>]*>\s*Apps\s*<\/a>/, "and marks it as the current page"
      refute body =~ "oauth2/consent", "no consent endpoint on this page"
    end

    test "the nav of the OTHER account pages links to it as well", %{uid: uid} do
      acct = G.account!(uid)
      body = T.account_get("/account?action=org.matrix.devices_list", cookie: acct.cookie).resp_body
      assert body =~ ~r/<a href="\/account\/apps"[^>]*>\s*Apps\s*<\/a>/
      refute body =~ ~r/<a href="\/account\/apps"[^>]*aria-current/
    end

    test "no grants: an empty-state message, no withdraw form", %{uid: uid} do
      conn = G.apps_get(G.account!(uid))
      T.assert_account_page(conn, "apps")
      assert conn.resp_body =~ ~s(data-role="no-grants")
      refute conn.resp_body =~ ~s(data-role="withdraw-grant")
      refute conn.resp_body =~ ~s(action="/account/apps/withdraw")
    end

    # ── cycle 1 (UX review MINOR 1-4, Kassandra INFO #4): exact strings ────────────────────────────

    test "UX 2/3/4: title and h1 both read 'Apps you have allowed'; intro and empty state use the exact wording", %{uid: uid} do
      conn = G.apps_get(G.account!(uid))
      T.assert_account_page(conn, "apps")
      body = conn.resp_body
      assert body =~ "<title>Apps you have allowed</title>"
      assert body =~ ~r/<h1>Apps you have allowed<\/h1>/
      refute body =~ "<title>Allowed apps</title>"

      assert body =~ ~r/data-role="grants-note">These apps may use your account without asking you again\./
      assert body =~ ~r/data-role="grants-details"[^>]*>\s*<summary>[^<]*<\/summary>\s*<p>These are the apps you have allowed to use your Matrix account\./
      refute body =~ "allowed to sign you in"

      assert body =~ ~s(<p data-role="no-grants">There are no allowed apps on your account. An app appears here after you allow it when you sign in.</p>)
    end

    test "UX 1: the Withdraw button's accessible name is `Withdraw the permission of <name> (<host>)`; two apps of the same name stay distinguishable", %{priv: priv, sub: sub, uid: uid} do
      a = T.oauth_client!([@https], client_name: "Twin App", client_uri: "https://one.example.com")
      b = T.oauth_client!([@https], client_name: "Twin App", client_uri: "https://two.example.com")
      G.set_client_host!(a, "one.example.com")
      G.set_client_host!(b, "two.example.com")
      for c <- [a, b], do: G.allow_new!(c, priv, sub)

      body = G.apps_get(G.account!(uid)).resp_body
      assert body =~ ~s|aria-label="Withdraw the permission of Twin App (one.example.com)"|
      assert body =~ ~s|aria-label="Withdraw the permission of Twin App (two.example.com)"|
    end

    test "UX 1: an app whose registration has no stored host is named `(unknown website)`, the card says Unknown", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      body = G.apps_get(G.account!(uid)).resp_body
      assert body =~ ~s|aria-label="Withdraw the permission of Grant Test App (unknown website)"|
      assert body =~ ~r/Website: Unknown/
    end

    test "Kassandra INFO #4: a hostile CLAIMED client_uri host never appears; only the stored client_host does", %{priv: priv, sub: sub, uid: uid} do
      cid = T.oauth_client!([@https], client_name: "Claimed Host App", client_uri: "https://phish-claimed.evil.example")
      G.set_client_host!(cid, "verified.example.com")
      G.allow_new!(cid, priv, sub)

      body = G.apps_get(G.account!(uid)).resp_body
      assert body =~ ~r/Website: verified\.example\.com/
      refute body =~ "phish-claimed.evil.example"
      refute body =~ "evil.example"
    end

    test "Kassandra INFO #4: without a stored host the claimed client_uri host is NOT used as a fallback", %{priv: priv, sub: sub, uid: uid} do
      cid = T.oauth_client!([@https], client_name: "No Host App", client_uri: "https://only-claimed.evil.example")
      G.allow_new!(cid, priv, sub)
      body = G.apps_get(G.account!(uid)).resp_body
      refute body =~ "only-claimed.evil.example"
      assert body =~ ~s|aria-label="Withdraw the permission of No Host App (unknown website)"|
    end

    # ── cycle 1 (code review MINOR 5): GET /account/apps without a session returns to the page after the IdP login ──

    test "the sign-in started at /account/apps ends at /account/apps (return target), and the page renders there", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub)

      flow = T.account_start!("/account/apps")
      cb = T.account_finish(flow, priv, sub)
      assert cb.status == 303, G.describe(cb)
      assert T.location(cb) == "/account/apps"

      cookie = T.account_cookie_from(cb) || flunk("no account session cookie")
      page = T.account_get(T.location(cb), cookie: cookie)
      T.assert_account_page(page, "apps")
      assert page.resp_body =~ ~s(data-client-id="#{cid}")
    end

    test "the other return targets are unchanged: no target => /account, an action => /account?action=...", %{priv: priv, sub: sub} do
      cb = T.account_finish(T.account_start!("/account"), priv, sub)
      assert T.location(cb) == "/account"

      cb = T.account_finish(T.account_start!("/account?action=org.matrix.devices_list"), priv, sub)
      assert T.location(cb) == "/account?action=org.matrix.devices_list"
    end

    test "shows ONLY the user's own grants", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      %{sub: bob_sub, uid: bob} = user!()
      bobs_client = T.oauth_client!([@https], client_name: "Bobs Private App")
      G.allow_new!(cid, priv, sub)
      G.allow_new!(bobs_client, priv, bob_sub)
      assert G.grant_count(bob) == 1

      body = G.apps_get(G.account!(uid)).resp_body
      assert body =~ ~s(data-client-id="#{cid}")
      refute body =~ bobs_client
      refute body =~ "Bobs Private App"

      bobs_body = G.apps_get(G.account!(bob)).resp_body
      assert bobs_body =~ "Bobs Private App"
      refute bobs_body =~ cid
    end

    test "the app name is shown escaped (claimed by the app: never trusted markup)", %{priv: priv, sub: sub, uid: uid} do
      evil = ~s|<script>alert("x")</script> & <img src=x onerror=alert(1)>|
      cid = T.oauth_client!([@https], client_name: evil, client_uri: G.website())
      G.allow_new!(cid, priv, sub)

      conn = G.apps_get(G.account!(uid))
      T.assert_account_page(conn, "apps")
      refute conn.resp_body =~ "<script"
      refute conn.resp_body =~ "<img"
      assert conn.resp_body =~ "&lt;script&gt;"
      assert conn.resp_body =~ "&amp;"
    end

    test "lists neither a revoked client's grant nor a grant whose binding no longer matches", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      revoked = T.oauth_client!([@https], client_name: "Revoked App")
      stale = T.oauth_client!([@https], client_name: "Stale App")
      for c <- [cid, revoked, stale], do: G.allow_new!(c, priv, sub)
      :ok = T.mark_revoked!(revoked)
      T.privileged_sql!("UPDATE oauth_consent_grants SET client_approved_at = client_approved_at - interval '1 hour' WHERE client_id = $1", [stale])

      body = G.apps_get(G.account!(uid)).resp_body
      assert body =~ ~s(data-client-id="#{cid}")
      refute body =~ "Revoked App"
      refute body =~ "Stale App"
    end

    test "a GET changes nothing", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      before = G.grant_rows(uid)
      acct = G.account!(uid)
      for _ <- 1..2, do: G.apps_get(acct)
      assert G.grant_rows(uid) == before
    end

    test "without a session: the account sign-in starts (302 to the IdP), the page is never served", %{} do
      conn = T.account_get("/account/apps")
      assert conn.status == 302
      assert T.location(conn) |> String.starts_with?(T.idp_authorize_endpoint())
    end

    test "the notices render: grant_withdrawn (status, success) and grant_not_found (alert, problem); both are known notice codes", %{uid: uid} do
      assert "grant_withdrawn" in Nebu.OAuth.AccountPages.notice_codes()
      assert "grant_not_found" in Nebu.OAuth.AccountPages.notice_codes()
      acct = G.account!(uid)

      ok = T.account_get("/account/apps?notice=grant_withdrawn", cookie: acct.cookie).resp_body
      assert ok =~ ~s(data-notice="grant_withdrawn")
      assert ok =~ ~r/class="notice success[^"]*"[^>]*role="status"/

      bad = T.account_get("/account/apps?notice=grant_not_found", cookie: acct.cookie).resp_body
      assert bad =~ ~s(data-notice="grant_not_found")
      assert bad =~ ~r/role="alert"/
    end

    test "the note says that withdrawing does not sign out devices that are already signed in", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      body = G.apps_get(G.account!(uid)).resp_body
      assert body =~ ~s(data-role="grants-note")
      assert body =~ ~r/does not sign out/i
      assert body =~ ~r/Devices/
    end

    test "the page is unavailable (503, unavailable page) when the grants cannot be read: never an empty list that looks like 'no apps'", %{uid: uid} do
      conn = G.with_table_unreadable(fn -> G.apps_get(G.account!(uid)) end)
      T.assert_account_error(conn, 503, "unavailable")
    end

    test "methods: POST /account/apps => 405 (Allow GET); GET /account/apps/withdraw => 405 (Allow POST); the page itself is not cacheable", %{uid: uid} do
      acct = G.account!(uid)
      conn = T.account_get("/account/apps", method: :post, cookie: acct.cookie)
      T.assert_account_error(conn, 405, "method_not_allowed")
      assert T.header(conn, "allow") =~ "GET"

      conn = T.account_get("/account/apps/withdraw", cookie: acct.cookie)
      T.assert_account_error(conn, 405, "method_not_allowed")
      assert T.header(conn, "allow") =~ "POST"
      assert T.header(G.apps_get(acct), "cache-control") =~ "no-store"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # scenario 9: the withdrawal
  # ════════════════════════════════════════════════════════════════════════════

  describe "scenario 9 - the user withdraws the grant on the OAuth account page" do
    test "her next authorization request shows the consent screen again (real account sign-in, token from the page)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      G.login(cid, priv, sub) |> G.assert_skipped!()
      acct = T.account_login!(priv, sub)

      conn = G.withdraw_post(acct, cid)
      assert conn.status == 303
      assert T.location(conn) == "/account/apps?notice=grant_withdrawn"
      T.assert_account_headers(conn)
      assert G.grant_count(uid) == 0

      G.login(cid, priv, sub) |> G.assert_consent!()
    end

    test "the page after the redirect shows the success notice and no longer lists the app", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      acct = G.account!(uid)
      conn = G.withdraw_post(acct, cid)
      page = T.account_get(T.location(conn), cookie: acct.cookie)
      T.assert_account_page(page, "apps")
      assert page.resp_body =~ ~s(data-notice="grant_withdrawn")
      refute page.resp_body =~ ~s(data-client-id="#{cid}")
      assert page.resp_body =~ ~s(data-role="no-grants")
    end

    test "withdrawing app A leaves the grant of app B (and the other user's grant of A) alone", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      %{sub: bob_sub, uid: bob} = user!()
      second = T.oauth_client!([@https], client_name: "Second App")
      G.allow_new!(cid, priv, sub)
      G.allow_new!(second, priv, sub)
      G.allow_new!(cid, priv, bob_sub)

      assert G.withdraw_post(G.account!(uid), cid).status == 303
      assert G.grant_count(uid, cid) == 0
      assert G.grant_count(uid, second) == 1
      assert G.grant_count(bob, cid) == 1
      G.login(second, priv, sub) |> G.assert_skipped!()
      G.login(cid, priv, bob_sub) |> G.assert_skipped!()
    end

    test "a user can only withdraw their OWN grant: another user's client id is grant_not_found and their row stays", %{cid: cid, priv: priv, uid: uid} do
      %{sub: bob_sub, uid: bob} = user!()
      bobs_client = T.oauth_client!([@https], client_name: "Bobs Private App")
      G.allow_new!(bobs_client, priv, bob_sub)
      G.allow_new!(cid, priv, bob_sub)
      before = G.grant_rows(bob)

      conn = G.withdraw_post(G.account!(uid), bobs_client)
      assert conn.status == 303
      assert T.location(conn) == "/account/apps?notice=grant_not_found"
      assert G.grant_rows(bob) == before, "bob's grants are untouched"

      # alice has a grant of `cid`? No (only bob): same answer for an app she never allowed
      assert T.location(G.withdraw_post(G.account!(uid), cid)) == "/account/apps?notice=grant_not_found"
      assert G.grant_rows(bob) == before
    end

    test "unknown, empty, oversized and hostile client ids are grant_not_found, never an error page", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      acct = G.account!(uid)

      for bad <- ["no-such-client", "", String.duplicate("a", 600), "x' OR '1'='1", "%00", "<script>"] do
        conn = G.withdraw_post(acct, bad)
        assert conn.status == 303, "client_id #{inspect(String.slice(bad, 0, 20))}: #{G.describe(conn)}"
        assert T.location(conn) == "/account/apps?notice=grant_not_found"
      end

      conn = G.withdraw_post(acct, nil)
      assert conn.status == 303
      assert T.location(conn) == "/account/apps?notice=grant_not_found"
      assert G.grant_count(uid, cid) == 1
    end

    test "a second withdrawal of the same grant is grant_not_found (idempotent, nothing else changes)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      acct = G.account!(uid)
      assert T.location(G.withdraw_post(acct, cid)) == "/account/apps?notice=grant_withdrawn"
      assert T.location(G.withdraw_post(acct, cid)) == "/account/apps?notice=grant_not_found"
    end

    test "DECISION: it does NOT end existing sessions: the access token and the refresh token of the app keep working", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      s = T.session!(cid, @https, priv, sub: sub, authorize: %{"scope" => G.scope("LIVEDEV001")})
      T.idp_refresh_ok(sub)
      assert G.grant_count(uid, cid) == 1

      assert G.withdraw_post(G.account!(uid), cid).status == 303

      assert T.whoami(s.at).status == 200, "the signed-in device stays signed in"
      assert T.refresh(cid, s.rt).status == 200, "and can still refresh"
      G.login(cid, priv, sub) |> G.assert_consent!()
    end

    test "DECISION: a withdrawal does not need a fresh sign-in (stale or missing auth_time still works)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      stale = G.account!(uid, auth_time: System.system_time(:second) - 7200)
      assert T.location(G.withdraw_post(stale, cid)) == "/account/apps?notice=grant_withdrawn"

      G.allow_new!(cid, priv, sub)
      no_time = G.account!(uid, auth_time: nil)
      assert T.location(G.withdraw_post(no_time, cid)) == "/account/apps?notice=grant_withdrawn"
    end

    test "after a withdrawal, an Allow remembers again and the following login skips", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      G.withdraw_post(G.account!(uid), cid)
      G.allow_new!(cid, priv, sub)
      G.login(cid, priv, sub) |> G.assert_skipped!()
    end

    test "storage failure: a 503 unavailable page (never 'withdrawn' when nothing was deleted)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      acct = G.account!(uid)
      conn = G.with_table_unreadable(fn -> G.withdraw_post(acct, cid) end)
      T.assert_account_error(conn, 503, "unavailable")
      refute (T.location(conn) || "") =~ "grant_withdrawn"
      assert G.grant_count(uid, cid) == 1
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # request hardening of the POST (the device sign-out rules)
  # ════════════════════════════════════════════════════════════════════════════

  describe "POST /account/apps/withdraw hardening" do
    setup %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      %{sub: other_sub, uid: other_uid} = user!()
      {:ok, acct: G.account!(uid), other: G.account!(other_uid), other_sub: other_sub}
    end

    test "missing / wrong / other-session CSRF token, foreign Origin, cross-site fetch metadata => 403 forbidden, nothing deleted, session still valid",
         %{cid: cid, uid: uid, acct: acct, other: other} do
      variants = [
        [csrf: ""],
        [csrf: "wrong"],
        [csrf: other.csrf],
        [headers: [{"origin", "https://evil.example.com"}]],
        [headers: [{"origin", T.issuer()}, {"sec-fetch-site", "cross-site"}]],
        [headers: [{"origin", T.issuer()}, {"sec-fetch-site", "same-site"}]]
      ]

      log =
        capture_log(fn ->
          for opts <- variants do
            G.withdraw_post(acct, cid, opts) |> T.assert_account_error(403, "forbidden")
          end
        end)

      assert G.grant_count(uid, cid) == 1
      assert T.account_session_row(acct.cookie)
      T.refute_secrets_in_log(log, %{csrf: acct.csrf, other: other.csrf, cookie: acct.cookie})
    end

    test "a request without the csrf_token field at all is refused too", %{cid: cid, uid: uid, acct: acct} do
      conn = T.account_post("/account/apps/withdraw", [{"client_id", cid}], cookie: acct.cookie, headers: [{"origin", T.issuer()}])
      T.assert_account_error(conn, 403, "forbidden")
      assert G.grant_count(uid, cid) == 1
    end

    test "no session cookie: 303 to /account (sign in first), nothing deleted", %{cid: cid, uid: uid, acct: acct} do
      conn = T.account_post("/account/apps/withdraw", [{"csrf_token", acct.csrf}, {"client_id", cid}], headers: [{"origin", T.issuer()}])
      assert conn.status == 303
      assert T.location(conn) == "/account"
      assert G.grant_count(uid, cid) == 1
    end

    test "an expired / unknown session cookie behaves the same", %{cid: cid, uid: uid, acct: acct} do
      conn = T.account_post("/account/apps/withdraw", [{"csrf_token", acct.csrf}, {"client_id", cid}], cookie: "unknown-" <> T.rand(20), headers: [{"origin", T.issuer()}])
      assert conn.status == 303
      assert G.grant_count(uid, cid) == 1
    end

    test "body rules of every account POST: JSON content type, a query string, a duplicated client_id => 400 invalid_request", %{cid: cid, uid: uid, acct: acct} do
      hdr = [{"origin", T.issuer()}]
      T.account_post("/account/apps/withdraw", ~s({"client_id":"#{cid}"}), cookie: acct.cookie, content_type: "application/json", headers: hdr) |> T.assert_account_error(400, "invalid_request")
      T.account_post("/account/apps/withdraw?x=1", [{"client_id", cid}, {"csrf_token", acct.csrf}], cookie: acct.cookie, headers: hdr) |> T.assert_account_error(400, "invalid_request")
      T.account_post("/account/apps/withdraw", "client_id=#{cid}&csrf_token=#{acct.csrf}&client_id=other", cookie: acct.cookie, headers: hdr) |> T.assert_account_error(400, "invalid_request")
      assert G.grant_count(uid, cid) == 1
    end

    test "the INFO line names ids only; no CSRF token, cookie, scope or redirect URI is logged", %{cid: cid, uid: uid, acct: acct} do
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      log = capture_log(fn -> assert G.withdraw_post(acct, cid).status == 303 end)

      assert log =~ "user_id=#{uid}"
      assert log =~ "client_id=#{cid}"
      T.refute_secrets_in_log(log, %{csrf: acct.csrf, cookie: acct.cookie, redirect: @https, scope: G.remembered_scope()})
    end

    test "OAuth switched off: the account page answers 404 unavailable before anything else (also the new routes)", %{cid: cid, uid: uid, acct: acct} do
      T.disable_oauth()
      T.account_get("/account/apps", cookie: acct.cookie) |> T.assert_account_error(404, "unavailable")
      G.withdraw_post(acct, cid) |> T.assert_account_error(404, "unavailable")
      assert G.grant_count(uid, cid) == 1
    end
  end
end
