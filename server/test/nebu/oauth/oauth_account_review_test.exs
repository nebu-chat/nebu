defmodule Nebu.OAuth.OAuthAccountReviewTest do
  @moduledoc """
  Tests for the review cycle 1 of story `oauth-account-management` (code review M1 / m1-m7 / INFO,
  Kassandra F-1 (b), F-2, F-3, I-6, UX review V1-V3 + advisories):

    * M1 the CSRF `Origin` rule with `Referrer-Policy: same-origin` (`Origin: null` only together with
      `Sec-Fetch-Site: same-origin`); F-1 (b) fetch-metadata navigation check on the destructive POSTs;
    * m2 / I-6 a future `auth_time` is clamped; m6 the binding cookie survives a callback while OAuth is not live;
    * m3 / F-3 one pending reset request per (user, device), a cap per user, serialized; the reset page refuses
      Approve while several requests are pending and names app / last activity / reference;
    * F-2 an approved PARTIAL replacement keeps the stored keys that were not supplied;
    * m7 one query for the client names; i3 `X-Forwarded-Proto: https,http`; i5 an honest device counter;
    * UX V1-V3 (label-in-name, stacked table hooks, reflow CSS) and the cheap advisories.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https], client_name: "Review App " <> T.rand(3))}
  end

  defp dev, do: "RV" <> String.upcase(T.rand(4))
  defp now, do: System.system_time(:second)
  defp q(pairs), do: "/account?" <> URI.encode_query(pairs)
  defp user!(sub \\ T.unique_sub()), do: %{sub: sub, uid: T.provision_user!(sub)}
  defp approve(uid, sid), do: apply(Nebu.Matrix, :approve_cross_signing_reset, [uid, sid])

  defp pending_count(uid),
    do: T.sql!("SELECT count(*) FROM uia_sessions WHERE user_id = $1 AND op = 'cross_signing_reset' AND consumed = FALSE AND stage_complete = FALSE", [uid]).rows |> hd() |> hd()

  defp challenge(s, body) do
    conn = T.device_signing_upload(s.at, body)
    assert conn.status == 401, "expected the m.oauth challenge, got #{conn.status}: #{conn.resp_body}"
    T.json(conn)["session"]
  end

  # ── M1 / F-1 (b) ──────────────────────────────────────────────────────────────

  describe "M1 — Origin null fallback" do
    setup %{priv: priv, cid: cid} do
      %{sub: sub, uid: uid} = user!()
      {:ok, uid: uid, s: T.oauth_device!(cid, @https, priv, sub, dev()), acct: T.account_session!(uid)}
    end

    test "Origin: null is refused alone and accepted ONLY with Sec-Fetch-Site: same-origin (valid token)", ctx do
      params = [{"device_id", ctx.s.device_id}, {"csrf_token", ctx.acct.csrf}]
      T.account_post("/account/devices/delete", params, cookie: ctx.acct.cookie, headers: [{"origin", "null"}]) |> T.assert_account_error(403, "forbidden")

      T.account_post("/account/devices/delete", params, cookie: ctx.acct.cookie, headers: [{"origin", "null"}, {"sec-fetch-site", "cross-site"}])
      |> T.assert_account_error(403, "forbidden")

      wrong = [{"device_id", ctx.s.device_id}, {"csrf_token", "wrong"}]
      T.account_post("/account/devices/delete", wrong, cookie: ctx.acct.cookie, headers: [{"origin", "null"}, {"sec-fetch-site", "same-origin"}])
      |> T.assert_account_error(403, "forbidden")

      conn = T.account_post("/account/devices/delete", params, cookie: ctx.acct.cookie, headers: [{"origin", "null"}, {"sec-fetch-site", "same-origin"}])
      assert conn.status == 303 and T.notice_of(conn) == "device_deleted"
    end

    test "the destructive POSTs refuse fetch metadata that is not a user-activated document navigation; logout is exempt; absent headers pass", ctx do
      post = fn headers -> T.account_post("/account/devices/delete", [{"device_id", ctx.s.device_id}, {"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie, headers: headers) end
      nav = [{"sec-fetch-mode", "navigate"}, {"sec-fetch-dest", "document"}, {"sec-fetch-user", "?1"}, {"sec-fetch-site", "same-origin"}]

      for bad <- [[{"sec-fetch-mode", "cors"}], [{"sec-fetch-dest", "empty"}], [{"sec-fetch-user", "?0"}], [{"sec-fetch-mode", "same-origin"}]] do
        post.(bad) |> T.assert_account_error(403, "forbidden")
      end

      assert T.whoami(ctx.s.at).status == 200
      assert post.(nav).status == 303

      out = T.account_post("/account/logout", [{"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie, headers: [{"sec-fetch-mode", "cors"}])
      assert out.status == 200
    end
  end

  # ── m2 / I-6, m6, i3 ──────────────────────────────────────────────────────────

  describe "freshness clamp, binding cookie order, X-Forwarded-Proto chain" do
    test "a FUTURE auth_time is clamped to now", %{priv: priv} do
      %{sub: sub} = user!()
      cb = T.account_finish(T.account_start!(), priv, sub, claims: %{"auth_time" => now() + 7200})
      assert cb.status == 303
      assert T.account_session_row(T.account_cookie_from(cb))["auth_time"] <= now()
    end

    test "a callback while OAuth is not live consumes nothing AND keeps the binding cookie", %{priv: priv} do
      %{sub: sub} = user!()
      flow = T.account_start!()
      T.disable_oauth()
      cb = T.account_finish(flow, priv, sub) |> T.assert_account_error(404, "unavailable")
      {bname, _} = flow.binding
      assert T.raw_set_cookie(cb, bname) == nil, "the binding cookie is not touched before the live check passed"
    end

    test "X-Forwarded-Proto: https,http counts as https (first value): Secure binding cookie, __Host- session", %{priv: priv} do
      %{sub: sub} = user!()
      chain = [{"x-forwarded-proto", "https,http"}]
      flow = T.account_start!("/account", headers: chain)
      {bname, _} = flow.binding
      assert T.raw_set_cookie(flow.conn, bname) =~ ~r/secure/i
      cb = T.account_finish(flow, priv, sub, headers: chain)
      assert T.raw_set_cookie(cb, "__Host-nebu_account")
    end
  end

  # ── F-3: pending reset requests ───────────────────────────────────────────────

  describe "F-3 — one pending reset request per (user, device), a cap per user, an unambiguous page" do
    setup %{priv: priv, cid: cid} do
      sub = T.unique_sub()
      s = T.oauth_device!(cid, @https, priv, sub, dev())
      assert T.device_signing_upload(s.at, T.cross_signing_keys(s.user_id, "OLD")).status == 200
      {:ok, s: s, uid: s.user_id, sub: sub, priv: priv, cid: cid}
    end

    test "a second request of the SAME device consumes the first pending one; an approved one is untouched", ctx do
      a = challenge(ctx.s, T.cross_signing_keys(ctx.uid, "N1"))
      b = challenge(ctx.s, T.cross_signing_keys(ctx.uid, "N2"))
      refute a == b
      assert T.uia_row(a)["consumed"] == true
      assert T.uia_row(b)["consumed"] == false
      assert pending_count(ctx.uid) == 1

      :ok = approve(ctx.uid, b)
      c = challenge(ctx.s, T.cross_signing_keys(ctx.uid, "N3"))
      refute c == b
      assert T.uia_row(b)["consumed"] == false and T.uia_row(b)["stage_complete"] == true, "an approved request is never consumed by a new challenge"
    end

    test "parallel auth-less uploads of one device get ONE session and ONE row", ctx do
      body = T.cross_signing_keys(ctx.uid, "PAR")
      ids = for _ <- 1..4, do: Task.async(fn -> T.json(T.device_signing_upload(ctx.s.at, body))["session"] end)
      ids = Enum.map(ids, &Task.await(&1, 15_000))
      assert length(Enum.uniq(ids)) == 1, inspect(ids)
      assert T.uia_count(ctx.uid, "cross_signing_reset") == 1
    end

    test "at most 5 pending requests per user (the new request always stays)", ctx do
      devices = [ctx.s | for(_ <- 1..6, do: T.oauth_device!(ctx.cid, @https, ctx.priv, ctx.sub, dev()))]
      sids = for {d, i} <- Enum.with_index(devices), do: challenge(d, T.cross_signing_keys(ctx.uid, "C#{i}"))
      assert pending_count(ctx.uid) == 5
      assert Enum.count(sids, &(T.uia_row(&1)["consumed"] == true)) == 2, "the surplus pending requests were trimmed"
      assert T.uia_row(List.last(sids))["consumed"] == false
    end

    test "the page refuses Approve while several requests are pending and warns; one request: Decline comes BEFORE Approve", ctx do
      other = T.oauth_device!(ctx.cid, @https, ctx.priv, ctx.sub, dev())
      a = challenge(ctx.s, T.cross_signing_keys(ctx.uid, "PA"))
      acct = T.account_session!(ctx.uid)
      single = T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie).resp_body
      {d, ap} = {:binary.match(single, ~s(data-role="decline-reset")), :binary.match(single, ~s(data-role="approve-reset"))}
      assert elem(d, 0) < elem(ap, 0), "Decline first in the DOM / focus order (safe default)"
      assert single =~ "name chosen by the app", "the app name is labelled as the app's own claim"
      assert single =~ "Review App"
      assert single =~ ~r/<time datetime="\d{4}-\d\d-\d\dT/
      assert single =~ ~r/Request reference/

      _b = challenge(other, T.cross_signing_keys(ctx.uid, "PB"))
      several = T.account_get(q([{"action", "org.matrix.cross_signing_reset"}]), cookie: acct.cookie).resp_body
      assert several =~ ~s(data-role="reset-several")
      refute several =~ ~s(data-role="approve-reset")
      assert length(Regex.scan(~r/data-role="decline-reset"/, several)) == 2
      assert T.uia_row(a)["stage_complete"] == false
    end
  end

  # ── F-2 ───────────────────────────────────────────────────────────────────────

  describe "F-2 — an approved PARTIAL replacement keeps the unsupplied keys" do
    test "SSK-only: master and USK stay, the SSK is replaced; a master-only token upload is not a first upload", %{priv: priv, cid: cid} do
      s = T.oauth_device!(cid, @https, priv, T.unique_sub(), dev())
      uid = s.user_id
      old = T.cross_signing_keys(uid, "OLD")
      assert T.device_signing_upload(s.at, old).status == 200

      body = Map.take(T.cross_signing_keys(uid, "NEW"), ["self_signing_key"])
      sid = challenge(s, body)
      :ok = approve(uid, sid)
      assert T.device_signing_upload(s.at, Map.put(body, "auth", %{"session" => sid})).status == 200

      stored = Nebu.Matrix.CrossSigningKeyStore.get_keys(uid)
      assert stored["master_key"] == old["master_key"], "the master key is kept"
      assert stored["user_signing_key"] == old["user_signing_key"], "the user-signing key is kept"
      assert stored["self_signing_key"] == body["self_signing_key"]

      evil = Map.take(T.cross_signing_keys(uid, "EVIL"), ["master_key"])
      conn = T.device_signing_upload(s.at, evil)
      assert conn.status == 401, "a stored master means a replacement needs the approval, never the UIA-free first-upload branch"
      assert Nebu.Matrix.CrossSigningKeyStore.get_keys(uid)["master_key"] == old["master_key"]
    end
  end

  # ── m7, i5, UX ────────────────────────────────────────────────────────────────

  describe "device list: batched client names, honest counter, UX hooks" do
    test "the app names of several clients are all shown (one batched lookup)", %{priv: priv} do
      %{sub: sub, uid: uid} = user!()
      c1 = T.oauth_client!([@https], client_name: "First-App-" <> T.rand(3))
      c2 = T.oauth_client!([@https], client_name: "Second-App-" <> T.rand(3))
      _ = T.oauth_device!(c1, @https, priv, sub, dev())
      _ = T.oauth_device!(c2, @https, priv, sub, dev())
      acct = T.account_session!(uid)
      body = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie).resp_body
      assert body =~ "First-App-" and body =~ "Second-App-"
      assert {:ok, %{} = names} = Nebu.OAuth.ClientStore.client_names([c1, c2, "unknown-client"])
      assert map_size(names) == 2
    end

    test "at the 5000-row read limit the count is a lower bound: 'At least N more devices not shown'" do
      %{uid: uid} = user!()
      acct = T.account_session!(uid)
      ms = System.system_time(:millisecond)
      T.sql!("INSERT INTO devices (user_id, device_id, created_at, updated_at) SELECT $1, 'LIM' || g, $2, $2 FROM generate_series(1, 5200) g", [uid, ms])
      body = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie).resp_body
      assert body =~ "At least 4500 more devices not shown"
    end

    test "UX hooks: label-in-name, stacked-row labels, focusable scroll region, row sign-out hook, reflow CSS, color-scheme", %{priv: priv, cid: cid} do
      s = T.oauth_device!(cid, @https, priv, T.unique_sub(), dev())
      Nebu.Matrix.DeviceKeyStore.rename_device(s.user_id, s.device_id, "Work Phone")
      acct = T.account_session!(s.user_id)

      list = T.account_get(q([{"action", "org.matrix.devices_list"}]), cookie: acct.cookie).resp_body
      assert list =~ ~r/data-label="Last active"/
      assert list =~ ~r/class="table-wrap"[^>]*role="region"[^>]*aria-label="[^"]+"[^>]*tabindex="0"/
      assert list =~ ~r/<a[^>]*data-role="device-row-sign-out"/
      assert list =~ ~r/<meta name="color-scheme" content="light">/
      assert list =~ "overflow-wrap:anywhere" and list =~ "white-space:normal" and list =~ "attr(data-label)" and list =~ "forced-colors"

      view = T.account_get(q([{"action", "org.matrix.device_view"}, {"device_id", s.device_id}]), cookie: acct.cookie).resp_body
      assert [_, label] = Regex.run(~r/data-role="device-sign-out"[^>]*aria-label="([^"]+)"/, view)
      assert label =~ "Sign out this device", "the accessible name contains the visible text (WCAG 2.5.3)"

      confirm = T.account_get(q([{"action", "org.matrix.device_delete"}, {"device_id", s.device_id}]), cookie: acct.cookie).resp_body
      assert confirm =~ "<title>Sign out Work Phone?</title>" and confirm =~ "<h1>Sign out Work Phone?</h1>"
      assert confirm =~ "Cancel - keep this device signed in"
      assert confirm =~ ~r/Sign out of the account page/

      default = T.account_get("/account", cookie: acct.cookie).resp_body
      refute default =~ ~s(aria-current="page"), "no nav entry is the default page itself"
      assert default =~ ~r/<h2 id="profile-heading">Profile<\/h2>/
    end
  end
end
