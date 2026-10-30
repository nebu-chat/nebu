defmodule Nebu.OAuth.OAuthAdminClientsTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-client-revocation` (P4): the admin side.
  AC6 (approved / revoked client lists, revoke confirm step, revoke POST, HTML contract), AC7.2 / 7.3 / 7.5
  (strict / lenient fetch metadata, framing) and AC8.1 / 8.5 (the fresh re-authentication marker on approve and
  revoke). The re-auth flow itself (`/admin/login/start?mode=reauth`, the callback) is `test/nebu/admin/admin_reauth_test.exs`.

  Driven through `Nebu.Admin.Endpoint` with a signed admin session like `oauth_admin_test.exs` (CSRF bypass flag
  only where a test is not about CSRF; the CSRF tests use a REAL token from the confirm page and the recycled
  session cookie). P2's pending list, badges and bulk removal coexist: nothing here changes them.

  ## Pinned routes (all behind `Nebu.Admin.Auth :require_admin`; Post-Redirect-Get)

    * `GET  /admin/oauth/clients`                    approved clients, newest approval first, 50 per page (`?page=N`)
    * `GET  /admin/oauth/clients/revoked`            revoked clients, newest revocation first
    * `GET  /admin/oauth/clients/:client_id/revoke`  confirm page (read only)
    * `POST /admin/oauth/clients/:client_id/revoke`  `confirm_host`, optional `reason`, `_csrf_token`
    * `GET  /admin/oauth/registrations/:client_id/approve`  approve confirm page (read only; the list's Approve is a link)
    * `POST /admin/oauth/registrations/:client_id/approve`  unchanged route; now needs a fresh marker + strict fetch metadata

  ## Pinned decisions of the contract

    * Order of checks on approve / revoke (SO2): `require_admin` -> Phoenix CSRF -> STRICT fetch metadata (403 page
      `data-error="fetch_metadata"`, a value-free WARNING naming the failed header NAMES) -> fresh marker (303 to
      `/admin/login/start?mode=reauth&return_to=<the confirm page path>`) -> typed host (303 back to the confirm page,
      error flash) -> the decision. Reject and bulk removal need the STRICT fetch metadata too (review cycle 1, L-2)
      but NO marker (same 403 page).
    * Marker (SO4, review cycle 1 M-1): session key `"admin_reauth"` = `%{"sub", "at", "kind", "path"}`; accepted when
      `sub` equals the session user's `sub`, `path` equals the confirm page of THIS action (the request path),
      `now - at <= 300` and `at <= now + 5`; a successful approve / revoke consumes it (single use); `kind` is `"auth_time"` | `"flow"` and becomes the audit
      metadata `"reauth"` of the approve (`%{"reauth" => kind}`) and revoke audit rows.
    * Revoke audit (CR9): `oauth_client_revoked`, target_type `oauth_client`, target_id = client id, metadata
      `%{"devices" => n, "reauth" => kind}` plus `"reason"` when given; never client metadata, never user / device ids.
    * Flash: info on success, error otherwise; redirect targets: success => `/admin/oauth/clients`; wrong / missing
      host or an already revoked / unknown client => the confirm page (`/admin/oauth/clients/:id/revoke`) resp. the list.
    * Live session count (CR7): devices with a row whose `session_expires_at > now()`, read through the Matrix facade
      (`:oauth_session_repo` seam); an unreadable count renders `?`, never `0`.

  ## HTML contract (shared with the Gherkin steps)

    * `data-page="oauth-clients"` / `"oauth-revoked-clients"` / `"oauth-revoke-confirm"` / `"oauth-approve-confirm"`
    * approved row `[data-role="oauth-approved-row"][data-client-id]` with cells `data-field="client-name"` (the page
      labels names as unverified, `[data-role="unverified-claims-note"]`), `[data-role="client-host"]`,
      `data-field="application-type"`, `"approved-by"`, `"approved-at"`, `"last-used"`, `"sessions"`; link
      `[data-role="revoke-client"]` to the confirm page
    * revoked row `[data-role="oauth-revoked-row"][data-client-id]` with `"revoked-by"`, `"revoked-at"`, `"revoked-reason"`
    * summary `[data-role="clients-summary"][data-total][data-page][data-total-pages]`, pager `[data-role="pagination"]`
    * confirm page: `[data-role="client-host"]`, `[data-role="revoke-device-count"]`, form `[data-role="revoke-confirm-form"]`
      (method post, action = the revoke URL, `_csrf_token`, input `confirm_host`, input `reason`), NO `data-confirm` anywhere
    * approve confirm page: form `[data-role="approve-confirm-form"]` (action = the approve URL), verified host before the claims,
      redirect URIs with host-bound badges, NO `data-confirm`
    * sidebar `a[data-navkey="oauth-approved-clients"]` / `a[data-navkey="oauth-revoked-clients"]`
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)
  @admin "@admin:test.local"
  @clients_path "/admin/oauth/clients"
  @revoked_path "/admin/oauth/clients/revoked"
  @reg_path "/admin/oauth/registrations"

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    T.enable_oauth()
    {:ok, ids} = Agent.start(fn -> [] end)
    {:ok, users} = Agent.start(fn -> [] end)

    prior_writer = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      case prior_writer do
        {:ok, writer} -> Application.put_env(:compliance, :audit_writer, writer)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end

      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      Application.delete_env(:nebu_http, :oauth_session_repo)
      T.clear_oauth_config()
      T.cleanup_clients(Agent.get(ids, & &1))
      for u <- Agent.get(users, & &1), do: T.privileged_sql!("DELETE FROM devices WHERE user_id = $1", [u])
      Agent.stop(ids)
      Agent.stop(users)
    end)

    {:ok, ids: ids, users: users}
  end

  # ── fixtures / helpers ─────────────────────────────────────────────────────

  # status "approved" | "pending" | "rejected" | "revoked"; attrs: :name, :host (the stored client_host, default the
  # host of the client URI; `nil` = no host), :reason (revoked_reason), :revoked_by, :application_type
  defp insert_client(ids, status, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    id = "atdd-clients-#{n}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    Agent.update(ids, &[id | &1])
    host = Map.get(attrs, :host, "app#{n}.example.com")
    name = Map.get(attrs, :name, "ClientApp-#{n}-end")
    type = Map.get(attrs, :application_type, "web")

    metadata =
      %{
        "client_name" => name,
        "client_uri" => "https://#{host || "app#{n}.example.com"}",
        "redirect_uris" => Map.get(attrs, :redirect_uris, ["https://#{host || "app#{n}.example.com"}/callback"]),
        "application_type" => type
      }
      |> then(fn m -> if Map.get(attrs, :logo, false), do: Map.put(m, "logo_uri", "https://#{host}/logo.png"), else: m end)

    T.insert_row!(id, Jason.encode!(metadata), "hash-#{id}", status, "NOW()", type,
      client_host: host,
      client_domain: Map.get(attrs, :client_domain),
      revoked_reason: Map.get(attrs, :reason),
      revoked_by: Map.get(attrs, :revoked_by, "@root:test.local")
    )

    %{id: id, name: name, host: host, metadata: metadata}
  end

  # One live (or expired) OAuth device of the client, through the real store.
  defp add_session!(users, cid, opts \\ []) do
    uid = T.provision_user!()
    Agent.update(users, &[uid | &1])
    did = "AC" <> String.upcase(T.rand(4))

    {:ok, _} =
      Nebu.Matrix.Session.OAuthSessionStore.insert_replacing_device(%{
        access_token: T.rand(32),
        refresh_token: T.rand(32),
        user_id: uid,
        device_id: did,
        client_id: cid,
        scope: T.matrix_scope(T.stable_prefix(), did),
        oauth_code_hash: nil,
        idp_rt_enc: nil,
        auth_time: nil,
        access_ttl_seconds: 300,
        session_ttl_seconds: 3600
      })

    if Keyword.get(opts, :expired, false),
      do: T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '2 hours', session_expires_at = now() - interval '1 hour' WHERE user_id = $1 AND device_id = $2", [uid, did])

    {uid, did}
  end

  defp admin_conn(method, path, params \\ nil) do
    %{conn(method, path, params) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => @admin})
  end

  # reject and bulk removal POSTs: the STRICT fetch metadata, no marker (Kassandra L-2)
  defp click_admin_conn(method, path, params \\ nil), do: admin_conn(method, path, params) |> T.put_strict_fetch_headers()

  # approve / revoke POSTs: fresh marker (same sub, bound to the confirm page = the request path) + the four strict
  # fetch-metadata headers (opts: :ago, :kind, :path)
  defp fresh_admin_conn(method, path, params \\ nil, opts \\ []) do
    admin_conn(method, path, params)
    |> put_session("admin_reauth", T.fresh_marker("admin-1", Keyword.get(opts, :ago, 0), Keyword.get(opts, :kind, "auth_time"), Keyword.get(opts, :path, URI.parse(path).path)))
    |> T.put_strict_fetch_headers()
  end

  defp non_admin_conn(method, path, params \\ nil) do
    %{conn(method, path, params) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => false, "sub" => "user-1", "matrix_user_id" => "@alex:test.local"})
  end

  defp anon_conn(method, path, params \\ nil) do
    %{conn(method, path, params) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
  end

  # The test env logs at :warning: a test that asserts an INFO line (or that nothing leaks at :debug) must admit it.
  defp debug_logging! do
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))
  defp flash_of(conn), do: conn.private.plug_session["phoenix_flash"] || %{}
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()
  defp doc(conn), do: Floki.parse_document!(conn.resp_body)
  defp text(nodes), do: nodes |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  defp revoke_path(id), do: "#{@clients_path}/#{id}/revoke"
  defp approve_path(id), do: "#{@reg_path}/#{id}/approve"

  defp audit_rows(action, client_id) do
    %{rows: rows} = T.sql!("SELECT actor_user_id, metadata, outcome, target_type FROM audit_log WHERE action = $1 AND target_id = $2", [action, client_id])
    rows
  end

  defp row_of(doc, role, id), do: doc |> Floki.find(~s([data-role="#{role}"][data-client-id="#{id}"])) |> List.first()
  defp cell(row, field), do: row |> Floki.find(~s([data-field="#{field}"])) |> text()

  defp client_sessions(cid), do: T.sql!("SELECT count(*) FROM matrix_sessions WHERE client_id = $1", [cid]).rows |> hd() |> hd()

  # ════════════════════════════════════════════════════════════════════════════
  # AC6.1 — the approved list
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6.1 — GET /admin/oauth/clients" do
    test "lists ONLY approved clients with the CR7 fields; names are labelled unverified; counts are live devices", %{ids: ids, users: users} do
      a = insert_client(ids, "approved", %{name: "Approved <b>App</b>"})
      add_session!(users, a.id)
      add_session!(users, a.id)
      add_session!(users, a.id, expired: true)
      quiet = insert_client(ids, "approved")
      pending = insert_client(ids, "pending")
      rejected = insert_client(ids, "rejected")
      revoked = insert_client(ids, "revoked")

      conn = admin_conn(:get, @clients_path) |> call()
      assert conn.status == 200
      assert (get_resp_header(conn, "content-type") |> List.first()) =~ "text/html"
      d = doc(conn)
      assert Floki.find(d, ~s([data-page="oauth-clients"])) != []
      assert Floki.find(d, ~s([data-role="unverified-claims-note"])) != []

      row = row_of(d, "oauth-approved-row", a.id) || flunk("approved client not listed")
      assert row |> Floki.find(~s([data-role="client-host"])) |> text() == a.host, "the VERIFIED host (client_host)"
      assert cell(row, "client-name") =~ "Approved <b>App</b>", "the claimed name is shown as text (HEEx-escaped)"
      refute conn.resp_body =~ "Approved <b>App</b>", "never rendered as markup"
      assert cell(row, "application-type") =~ "web"
      assert cell(row, "approved-by") =~ @admin
      assert cell(row, "approved-at") != ""
      assert cell(row, "last-used") != ""
      assert cell(row, "sessions") == "2", "two LIVE devices; the expired session does not count"
      assert [link] = Floki.find(row, ~s(a[data-role="revoke-client"]))
      assert Floki.attribute(link, "href") == [revoke_path(a.id)]

      assert cell(row_of(d, "oauth-approved-row", quiet.id), "sessions") == "0"

      for c <- [pending, rejected, revoked], do: assert(row_of(d, "oauth-approved-row", c.id) == nil, "#{c.id} is not approved")
    end

    test "newest approval first", %{ids: ids} do
      first = insert_client(ids, "approved")
      second = insert_client(ids, "approved")
      third = insert_client(ids, "approved")

      page = admin_conn(:get, @clients_path) |> call()
      assert page.status == 200
      body = page.resp_body
      pos = fn c -> body |> :binary.match(~s(data-client-id="#{c.id}")) |> elem(0) end
      assert pos.(third) < pos.(second) and pos.(second) < pos.(first)
    end

    test "a count read error shows ? (never 0) and the rest of the page still renders", %{ids: ids, users: users} do
      a = insert_client(ids, "approved")
      add_session!(users, a.id)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)

      {conn, _log} = with_log(fn -> admin_conn(:get, @clients_path) |> call() end)
      assert conn.status == 200
      row = row_of(doc(conn), "oauth-approved-row", a.id) || flunk("the client must still be listed")
      assert String.starts_with?(cell(row, "sessions"), "?") and cell(row, "sessions") =~ "could not be read", "visible, not just a bare ?"
      assert Floki.find(row, ~s(a[data-role="revoke-client"])) != []
    end

    test "paging: 50 per page, the real total, nothing silently cut off", %{ids: ids} do
      mine = for _ <- 1..52, do: insert_client(ids, "approved")

      p1 = admin_conn(:get, @clients_path) |> call() |> doc()
      rows1 = Floki.find(p1, ~s([data-role="oauth-approved-row"]))
      assert length(rows1) == 50
      assert [summary] = Floki.find(p1, ~s([data-role="clients-summary"]))
      assert String.to_integer(hd(Floki.attribute(summary, "data-total"))) >= 52
      assert hd(Floki.attribute(summary, "data-page")) == "1"
      assert Floki.find(p1, ~s([data-role="pagination"])) != []

      total_pages = String.to_integer(hd(Floki.attribute(summary, "data-total-pages")))

      ids_seen =
        for p <- 1..total_pages, row <- admin_conn(:get, "#{@clients_path}?page=#{p}") |> call() |> doc() |> Floki.find(~s([data-role="oauth-approved-row"])) do
          hd(Floki.attribute(row, "data-client-id"))
        end

      assert length(ids_seen) == length(Enum.uniq(ids_seen)), "rows never repeat across pages"
      for c <- mine, do: assert(c.id in ids_seen, "#{c.id} is reachable")
      assert admin_conn(:get, "#{@clients_path}?page=garbage") |> call() |> Map.fetch!(:status) == 200
    end

    test "the sidebar has the two new OAuth entries", %{ids: _ids} do
      d = admin_conn(:get, @clients_path) |> call() |> doc()
      assert [a] = Floki.find(d, ~s(a[data-navkey="oauth-approved-clients"]))
      assert Floki.attribute(a, "href") == [@clients_path]
      assert [r] = Floki.find(d, ~s(a[data-navkey="oauth-revoked-clients"]))
      assert Floki.attribute(r, "href") == [@revoked_path]
      assert Floki.find(d, ~s(a[data-navkey="oauth-pending-clients"])) != [], "P2's entry stays"
    end

    test "a non-admin is redirected to /admin/login (or refused), an anonymous visitor redirected; every new GET route", %{ids: ids} do
      c = insert_client(ids, "approved")
      p = insert_client(ids, "pending")

      for path <- [@clients_path, @revoked_path, revoke_path(c.id), approve_path(p.id)] do
        anon = anon_conn(:get, path) |> call()
        assert anon.status == 302 and location(anon) == "/admin/login", "anonymous #{path}"
        non = non_admin_conn(:get, path) |> call()
        assert non.status in [302, 403], "non-admin #{path}"
        if non.status == 302, do: assert(location(non) == "/admin/login")
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6.2 — the revoked list
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6.2 — GET /admin/oauth/clients/revoked" do
    test "lists revoked clients with revoked by / at and the reason; nothing else", %{ids: ids} do
      r = insert_client(ids, "revoked", %{reason: "lost the key <i>x</i>", revoked_by: "@carol:test.local"})
      bare = insert_client(ids, "revoked")
      approved = insert_client(ids, "approved")
      pending = insert_client(ids, "pending")

      conn = admin_conn(:get, @revoked_path) |> call()
      assert conn.status == 200
      d = doc(conn)
      assert Floki.find(d, ~s([data-page="oauth-revoked-clients"])) != []

      row = row_of(d, "oauth-revoked-row", r.id) || flunk("revoked client not listed")
      assert cell(row, "revoked-by") =~ "@carol:test.local"
      assert cell(row, "revoked-at") != ""
      assert cell(row, "revoked-reason") =~ "lost the key <i>x</i>"
      refute conn.resp_body =~ "lost the key <i>x</i>", "reason text is escaped"
      assert row |> Floki.find(~s([data-role="client-host"])) |> text() == r.host
      assert Floki.find(row, ~s(a[data-role="revoke-client"])) == [], "a revoked client has no revoke link"

      assert row_of(d, "oauth-revoked-row", bare.id) != nil
      for c <- [approved, pending], do: assert(row_of(d, "oauth-revoked-row", c.id) == nil)
      refute row_of(doc(admin_conn(:get, @clients_path) |> call()), "oauth-approved-row", r.id), "a revoked client left the approved list"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6.3 — confirm pages
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6.3 — the revoke confirm page" do
    test "shows client, verified host, device count, consequences; confirm_host + reason inputs; no data-confirm; changes nothing", %{ids: ids, users: users} do
      c = insert_client(ids, "approved", %{name: "Confirm Me"})
      add_session!(users, c.id)
      add_session!(users, c.id)

      # story admin-reauth-button-flow: the submit exists in the fresh state only (stale: the link "Sign in again to revoke", admin_reauth_button_flow_confirm_test.exs)
      conn = fresh_admin_conn(:get, revoke_path(c.id)) |> call()
      assert conn.status == 200
      d = doc(conn)
      assert Floki.find(d, ~s([data-page="oauth-revoke-confirm"])) != []
      assert d |> Floki.find(~s([data-role="client-host"])) |> text() =~ c.host
      assert d |> Floki.find(~s([data-role="revoke-device-count"])) |> text() == "2"
      assert conn.resp_body =~ "Confirm Me"
      body = String.downcase(conn.resp_body)
      for phrase <- ["sessions", "devices", "keys", "never"], do: assert(body =~ phrase, "the consequences mention #{phrase}")
      refute conn.resp_body =~ "data-confirm", "a plain user-clicked submit (SO3)"

      assert [form] = Floki.find(d, ~s(form[data-role="revoke-confirm-form"]))
      assert form |> Floki.attribute("method") |> hd() |> String.downcase() == "post"
      assert Floki.attribute(form, "action") == [revoke_path(c.id)]
      assert Floki.find(form, ~s(input[name="_csrf_token"])) != []
      assert [host_input] = Floki.find(form, ~s(input[name="confirm_host"]))
      assert Floki.attribute(host_input, "value") in [[], [""]], "never pre-filled"
      assert Floki.find(form, ~s(input[name="reason"], textarea[name="reason"])) != []
      assert Floki.find(form, ~s(button[type="submit"])) != []

      assert T.client_row(c.id)["status"] == "approved"
      assert audit_rows("oauth_client_revoked", c.id) == []
    end

    test "device count unreadable => ?", %{ids: ids, users: users} do
      c = insert_client(ids, "approved")
      add_session!(users, c.id)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      {conn, _} = with_log(fn -> admin_conn(:get, revoke_path(c.id)) |> call() end)
      d = doc(conn)
      assert d |> Floki.find(~s([data-role="revoke-device-count"])) |> text() == "?"
      assert conn.resp_body =~ "removed all the same", "the page says the devices go either way"
    end

    test "a client without a stored host asks for the client id instead", %{ids: ids} do
      c = insert_client(ids, "approved", %{host: nil})
      body = admin_conn(:get, revoke_path(c.id)) |> call() |> Map.fetch!(:resp_body)
      assert body =~ c.id
    end

    for status <- ["pending", "rejected", "revoked"] do
      test "a #{status} client has no revoke page: 303 to the approved list with an error flash", %{ids: ids} do
        c = insert_client(ids, unquote(status))
        conn = admin_conn(:get, revoke_path(c.id)) |> call()
        assert conn.status in [302, 303] and location(conn) == @clients_path
        assert flash_of(conn)["error"]
      end
    end

    test "an unknown client id => 303 to the approved list with an error flash" do
      conn = admin_conn(:get, revoke_path("no-such-client-" <> T.rand())) |> call()
      assert conn.status in [302, 303] and location(conn) == @clients_path
      assert flash_of(conn)["error"]
    end

    test "client-controlled text is escaped", %{ids: ids} do
      c = insert_client(ids, "approved", %{name: "<script>alert(1)</script>"})
      body = admin_conn(:get, revoke_path(c.id)) |> call() |> Map.fetch!(:resp_body)
      refute body =~ "<script>alert(1)</script>"
    end
  end

  describe "AC6.3 — the approve confirm page coexists with P2's list (bulk removal, badges, form below the list)" do
    test "a pending client's approve link on the list leads to the confirm page; shared-hosting badge is repeated there", %{ids: ids} do
      name = "n#{T.rand(5)}"
      c = insert_client(ids, "pending", %{host: "app.#{name}.github.io", client_domain: "#{name}.github.io"})
      list = admin_conn(:get, @reg_path) |> call() |> doc()
      row = list |> Floki.find(~s([data-role="oauth-client-row"][data-client-id="#{c.id}"]))
      assert [link] = Floki.find(row, ~s(a[data-role="review-approve"]))
      assert Floki.attribute(link, "href") == [approve_path(c.id)]
      assert Floki.find(row, ~s(form[data-form="approve-client"])) == [], "no approve form in the list"
      # P2 stays: bulk-remove link and the bulk form below the list
      assert Floki.find(list, ~s(form[data-form="bulk-remove"])) != []

      page = admin_conn(:get, approve_path(c.id)) |> call()
      assert page.status == 200
      assert Floki.find(doc(page), ~s([data-role="redirect-host-bound"])) != []
      assert Floki.find(doc(page), ~s([data-role="shared-hosting-warning"])) != [], "the confirm step shows the same warnings the list did"
      assert T.client_row(c.id)["status"] == "pending"
    end

    test "approve confirm page for a decided / unknown client redirects to the list with an error flash", %{ids: ids} do
      c = insert_client(ids, "approved")
      conn = admin_conn(:get, approve_path(c.id)) |> call()
      assert conn.status in [302, 303] and location(conn) == @reg_path
      assert flash_of(conn)["error"]
      assert (admin_conn(:get, approve_path("no-such-" <> T.rand())) |> call()).status in [302, 303]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6.4 - 6.7 — the revoke POST
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6.4 — a valid revoke" do
    test "303 to the approved list, success flash, ends the sessions, ONE audit row with the CR9 metadata", %{ids: ids, users: users} do
      debug_logging!()
      c = insert_client(ids, "approved")
      add_session!(users, c.id)
      add_session!(users, c.id)

      {conn, log} =
        with_log(fn ->
          fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "no longer trusted"}) |> call()
        end)

      assert conn.status in [302, 303] and location(conn) == @clients_path
      assert flash_of(conn)["info"] =~ "revoked"
      row = T.client_row(c.id)
      assert row["status"] == "revoked" and row["revoked_by"] == @admin and row["revoked_reason"] == "no longer trusted"
      assert client_sessions(c.id) == 0

      assert [[actor, metadata, "success", "oauth_client"]] = audit_rows("oauth_client_revoked", c.id)
      assert actor == @admin
      assert metadata == %{"devices" => 2, "reauth" => "auth_time", "reason" => "no longer trusted"}
      refute inspect(metadata) =~ c.name

      assert log =~ "OAuth admin: client revoked client_id=#{c.id} devices=2"
      refute log =~ "no longer trusted", "the reason text is never logged (CR12)"
      refute log =~ c.name

      # the lists moved it
      assert row_of(doc(admin_conn(:get, @revoked_path) |> call()), "oauth-revoked-row", c.id) != nil
    end

    test "the host is compared trimmed and case-insensitively; no reason => no reason key", %{ids: ids} do
      c = insert_client(ids, "approved")
      conn = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => "  " <> String.upcase(c.host) <> "\t"}) |> call()
      assert conn.status in [302, 303] and location(conn) == @clients_path
      assert [[_, metadata, _, _]] = audit_rows("oauth_client_revoked", c.id)
      refute Map.has_key?(metadata, "reason")
      assert T.client_row(c.id)["revoked_reason"] == nil
    end

    test "a client without a stored host is confirmed by typing its client id", %{ids: ids} do
      c = insert_client(ids, "approved", %{host: nil})
      wrong = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => "app.example.com"}) |> call()
      assert location(wrong) == revoke_path(c.id) and T.client_row(c.id)["status"] == "approved"

      ok = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.id}) |> call()
      assert location(ok) == @clients_path and T.client_row(c.id)["status"] == "revoked"
    end

    test "the reason is normalised like the reject reason: control / bidi characters stripped, 500 characters max", %{ids: ids} do
      c = insert_client(ids, "approved")
      reason = "bad\u0000 \u202Eactor" <> String.duplicate("x", 600)
      fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "reason" => reason}) |> call()
      stored = T.client_row(c.id)["revoked_reason"]
      assert is_binary(stored), "the revocation went through with a cleaned reason"
      refute stored =~ "\u0000" or stored =~ "\u202E"
      assert String.length(stored) == 500
      assert [[_, %{"reason" => ^stored}, _, _]] = audit_rows("oauth_client_revoked", c.id)

      d = insert_client(ids, "approved")
      fresh_admin_conn(:post, revoke_path(d.id), %{"confirm_host" => d.host, "reason" => "\u0000\u202E \n"}) |> call()
      assert T.client_row(d.id)["revoked_reason"] == nil, "only control characters count as no reason"
    end

    test "a failing audit writer rolls the revocation back and says so (nothing changed)", %{ids: ids, users: users} do
      c = insert_client(ids, "approved")
      add_session!(users, c.id)
      Application.put_env(:compliance, :audit_writer, Nebu.OAuth.OAuthAdminClientsTest.FailingAudit)

      {conn, log} = with_log(fn -> fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "secret-reason-77"}) |> call() end)
      assert conn.status in [302, 303]
      assert is_binary(flash_of(conn)["error"]), "an error flash tells the admin nothing was changed"
      assert T.client_row(c.id)["status"] == "approved"
      assert client_sessions(c.id) == 1
      refute log =~ "secret-reason-77"
      refute log =~ c.name
    end
  end

  describe "AC6.5 — a wrong or missing confirmation changes nothing" do
    test "303 back to the confirm page with an error flash, no audit row", %{ids: ids, users: users} do
      c = insert_client(ids, "approved", %{host: "payroll.example.com"})
      add_session!(users, c.id)

      for params <- [%{}, %{"confirm_host" => ""}, %{"confirm_host" => "other.example.com"}, %{"confirm_host" => "payroll"}, %{"confirm_host" => "payroll.example.com.evil.com"}, %{"confirm_host" => c.id}, %{"confirm_host" => ["payroll.example.com"]}] do
        conn = fresh_admin_conn(:post, revoke_path(c.id), params) |> call()
        assert conn.status in [302, 303] and location(conn) == revoke_path(c.id), "#{inspect(params)}"
        assert flash_of(conn)["error"]
      end

      assert T.client_row(c.id)["status"] == "approved"
      assert client_sessions(c.id) == 1
      assert audit_rows("oauth_client_revoked", c.id) == []
    end
  end

  describe "AC6.6 — CSRF (no admin_csrf_bypass: the real token of the confirm page and the recycled session)" do
    defp real_post(get_conn, path, params, token \\ :from_page) do
      token = if token == :from_page, do: doc(get_conn) |> Floki.find(~s(input[name="_csrf_token"])) |> Floki.attribute("value") |> hd(), else: token
      body = if token, do: Map.put(params, "_csrf_token", token), else: params

      %{conn(:post, path, body) | secret_key_base: @secret_key_base}
      |> recycle_cookies(get_conn)
      |> T.put_strict_fetch_headers()
      |> call()
    end

    setup do
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      :ok
    end

    test "the token of the confirm page + the same session => the revocation goes through", %{ids: ids} do
      c = insert_client(ids, "approved")
      get = fresh_admin_conn(:get, revoke_path(c.id)) |> call()
      assert get.status == 200
      post = real_post(get, revoke_path(c.id), %{"confirm_host" => c.host})
      assert post.status in [302, 303] and location(post) == @clients_path
      assert T.client_row(c.id)["status"] == "revoked"
    end

    test "a missing / wrong / foreign token => 403, nothing changed", %{ids: ids} do
      c = insert_client(ids, "approved")
      get = fresh_admin_conn(:get, revoke_path(c.id)) |> call()

      for token <- [nil, "wrong-token", String.duplicate("A", 64)] do
        status =
          try do
            real_post(get, revoke_path(c.id), %{"confirm_host" => c.host}, token).status
          rescue
            e in Plug.CSRFProtection.InvalidCSRFTokenError -> Plug.Exception.status(e)
          end

        assert status == 403
        assert T.client_row(c.id)["status"] == "approved"
      end

      assert audit_rows("oauth_client_revoked", c.id) == []
    end

    test "approve: the same holds (real token ok, none => 403)", %{ids: ids} do
      c = insert_client(ids, "pending")
      get = fresh_admin_conn(:get, approve_path(c.id)) |> call()
      assert get.status == 200

      status =
        try do
          real_post(get, approve_path(c.id), %{}, nil).status
        rescue
          e in Plug.CSRFProtection.InvalidCSRFTokenError -> Plug.Exception.status(e)
        end

      assert status == 403 and T.client_row(c.id)["status"] == "pending"
      ok = real_post(get, approve_path(c.id), %{})
      assert ok.status in [302, 303] and T.client_row(c.id)["status"] == "approved"
    end
  end

  describe "AC6.7 — a second revoke" do
    test "error flash, no second audit row, the first attribution stays", %{ids: ids} do
      c = insert_client(ids, "approved")
      first = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "first"}) |> call()
      assert first.status in [302, 303] and flash_of(first)["info"]

      second = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "second"}) |> call()
      assert second.status in [302, 303]
      assert flash_of(second)["error"]
      assert length(audit_rows("oauth_client_revoked", c.id)) == 1
      assert T.client_row(c.id)["revoked_reason"] == "first"
    end

    test "unknown, pending and rejected clients: error flash, nothing audited", %{ids: ids} do
      for status <- ["pending", "rejected"] do
        c = insert_client(ids, status)
        conn = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host}) |> call()
        assert conn.status in [302, 303] and flash_of(conn)["error"]
        assert T.client_row(c.id)["status"] == status
        assert audit_rows("oauth_client_revoked", c.id) == []
      end

      unknown = "no-such-client-" <> T.rand()
      conn = fresh_admin_conn(:post, revoke_path(unknown), %{"confirm_host" => "x.example.com"}) |> call()
      assert conn.status in [302, 303] and audit_rows("oauth_client_revoked", unknown) == []
    end

    test "anonymous and non-admin POSTs change nothing", %{ids: ids} do
      c = insert_client(ids, "approved")
      p = insert_client(ids, "pending")

      for build <- [&anon_conn/3, &non_admin_conn/3], {path, params} <- [{revoke_path(c.id), %{"confirm_host" => c.host}}, {approve_path(p.id), %{}}] do
        conn = build.(:post, path, params) |> put_session("admin_reauth", T.fresh_marker("user-1")) |> T.put_strict_fetch_headers() |> call()
        assert conn.status in [302, 403]
      end

      assert T.client_row(c.id)["status"] == "approved" and T.client_row(p.id)["status"] == "pending"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7.2 / 7.3 — fetch metadata on the admin POSTs
  # ════════════════════════════════════════════════════════════════════════════

  defp fm_variants do
    # {label, header, replacement value | :absent | :duplicated}
    absent = for h <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest sec-fetch-user), do: {"#{h} absent", h, :absent}
    dup = for h <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest sec-fetch-user), do: {"#{h} duplicated", h, :duplicated}

    wrong =
      for {h, vs} <- [{"sec-fetch-site", ~w(same-site cross-site none)}, {"sec-fetch-mode", ~w(cors no-cors)}, {"sec-fetch-dest", ~w(iframe empty)}, {"sec-fetch-user", ["?0"]}],
          v <- vs,
          do: {"#{h}: #{v}", h, v}

    absent ++ dup ++ wrong
  end

  defp with_variant(conn, header, :absent), do: %{conn | req_headers: List.keydelete(conn.req_headers, header, 0)}

  defp with_variant(conn, header, :duplicated) do
    value = T.strict_fetch_headers() |> List.keyfind(header, 0) |> elem(1)
    %{conn | req_headers: List.keydelete(conn.req_headers, header, 0) ++ [{header, value}, {header, value}]}
  end

  defp with_variant(conn, header, value), do: put_req_header(conn, header, value)

  describe "AC7.2 — strict fetch metadata on admin approve and revoke: 403 page fetch_metadata, nothing changed, no audit" do
    test "revoke: every absent / wrong / duplicated header is refused", %{ids: ids} do
      c = insert_client(ids, "approved")

      for {label, header, variant} <- fm_variants() do
        {conn, log} =
          with_log(fn ->
            fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host}) |> with_variant(header, variant) |> call()
          end)

        assert conn.status == 403, "#{label}: expected 403, got #{conn.status}"
        assert conn.resp_body =~ ~s(data-error="fetch_metadata"), "#{label}: the fetch_metadata page"
        assert T.client_row(c.id)["status"] == "approved", "#{label}: nothing changed"
        assert log =~ header, "#{label}: the WARNING names the failed header"

        # never the VALUE: match the `header=value` / `header: value` forms, not a bare substring ("none" occurs in words)
        if is_binary(variant),
          do: refute(log =~ ~r/#{Regex.escape(header)}["']?\s*[=:]\s*["']?#{Regex.escape(variant)}/i, "#{label}: and never its value"),
          else: :ok
      end

      assert audit_rows("oauth_client_revoked", c.id) == []
    end

    test "approve: the same table", %{ids: ids} do
      c = insert_client(ids, "pending")

      for {label, header, variant} <- fm_variants() do
        conn = fresh_admin_conn(:post, approve_path(c.id)) |> with_variant(header, variant) |> call()
        assert conn.status == 403, "#{label}: expected 403, got #{conn.status}"
        assert conn.resp_body =~ ~s(data-error="fetch_metadata")
        assert T.client_row(c.id)["status"] == "pending", "#{label}: nothing changed"
      end

      assert audit_rows("oauth_client_approved", c.id) == []
    end

    test "order of checks: bad headers + no marker => 403; good headers + no marker => 303 re-auth", %{ids: ids} do
      c = insert_client(ids, "approved")
      no_marker = fn -> admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host}) end

      bad = no_marker.() |> T.put_strict_fetch_headers() |> put_req_header("sec-fetch-mode", "cors") |> call()
      assert bad.status == 403

      good = no_marker.() |> T.put_strict_fetch_headers() |> call()
      assert good.status in [302, 303] and location(good) =~ "/admin/login/start"
      assert T.client_row(c.id)["status"] == "approved"
    end

    test "order: CSRF before fetch metadata (bad token => CSRF error, good token => fetch_metadata page)", %{ids: ids} do
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      c = insert_client(ids, "approved")
      get = fresh_admin_conn(:get, revoke_path(c.id)) |> call()
      token = doc(get) |> Floki.find(~s(input[name="_csrf_token"])) |> Floki.attribute("value") |> hd()

      post = fn token ->
        %{conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "_csrf_token" => token}) | secret_key_base: @secret_key_base}
        |> recycle_cookies(get)
        |> T.put_strict_fetch_headers()
        |> put_req_header("sec-fetch-dest", "iframe")
      end

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> post.("wrong-token") |> call() end

      refused = post.(token) |> call()
      assert refused.status == 403 and refused.resp_body =~ ~s(data-error="fetch_metadata"), "the token is fine: the fetch metadata refusal"
      assert T.client_row(c.id)["status"] == "approved"
    end

    test "order: fetch metadata, then marker, then typed host (no marker + wrong host => re-auth redirect)", %{ids: ids} do
      c = insert_client(ids, "approved")
      wrong = %{"confirm_host" => "wrong.example.com"}

      bad_headers = fresh_admin_conn(:post, revoke_path(c.id), wrong) |> put_req_header("sec-fetch-dest", "iframe") |> call()
      assert bad_headers.status == 403, "headers are judged before the host"

      no_marker = admin_conn(:post, revoke_path(c.id), wrong) |> T.put_strict_fetch_headers() |> call()
      assert no_marker.status in [302, 303]
      assert URI.parse(location(no_marker)).path == "/admin/login/start", "the marker is judged BEFORE the typed host: no hint about the host reaches an unauthenticated flow"
      assert flash_of(no_marker)["error"] == nil

      all_good_wrong_host = fresh_admin_conn(:post, revoke_path(c.id), wrong) |> call()
      assert location(all_good_wrong_host) == revoke_path(c.id), "only with headers and marker in order is the typed host judged"
      assert T.client_row(c.id)["status"] == "approved"
    end
  end

  describe "AC6 — revoked clients stay revoked at the app level (CR6: nothing resurrects them)" do
    test "approve confirm, approve POST and reject POST of a revoked client change nothing", %{ids: ids} do
      c = insert_client(ids, "revoked")
      before = T.client_row(c.id)

      confirm = admin_conn(:get, approve_path(c.id)) |> call()
      assert confirm.status in [302, 303] and location(confirm) == @reg_path and flash_of(confirm)["error"]

      approve = fresh_admin_conn(:post, approve_path(c.id)) |> call()
      assert approve.status in [302, 303] and flash_of(approve)["error"], "not pending any more"
      assert audit_rows("oauth_client_approved", c.id) == []

      reject = click_admin_conn(:post, "#{@reg_path}/#{c.id}/reject") |> call()
      assert reject.status in [302, 303] and flash_of(reject)["error"]
      assert audit_rows("oauth_client_rejected", c.id) == []

      assert T.client_row(c.id) == before, "still revoked, attribution and reason untouched"
    end

    test "bulk removal of a domain with approved and revoked clients removes only the pending ones", %{ids: ids} do
      domain = "bulk#{T.rand(5)}.com"
      pending = insert_client(ids, "pending", %{host: "p.#{domain}", client_domain: domain})
      approved = insert_client(ids, "approved", %{host: "a.#{domain}", client_domain: domain})
      revoked = insert_client(ids, "revoked", %{host: "r.#{domain}", client_domain: domain})
      params = %{"host" => domain, "match" => "domain", "as_of" => DateTime.utc_now() |> DateTime.to_iso8601()}

      conn = click_admin_conn(:post, "#{@reg_path}/bulk-remove", params) |> call()
      assert conn.status in [302, 303]
      assert T.client_row(pending.id) == nil, "the pending row is gone"
      assert T.client_row(approved.id)["status"] == "approved", "approved and revoked rows are never swept"
      assert T.client_row(revoked.id)["status"] == "revoked"
    end
  end

  describe "AC7.3 — STRICT fetch metadata (no marker) on admin reject and bulk removal (review cycle 1, Kassandra L-2)" do
    test "reject: the four correct headers are accepted, WITHOUT a marker", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = click_admin_conn(:post, "#{@reg_path}/#{c.id}/reject") |> call()
      assert conn.status in [302, 303] and T.client_row(c.id)["status"] == "rejected"
    end

    test "reject: absent headers (a scripted POST, an old browser) => 403 fetch_metadata, still pending, no audit", %{ids: ids} do
      c = insert_client(ids, "pending")

      for header <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest sec-fetch-user) do
        conn = click_admin_conn(:post, "#{@reg_path}/#{c.id}/reject") |> with_variant(header, :absent) |> call()
        assert conn.status == 403, "#{header} absent"
        assert conn.resp_body =~ ~s(data-error="fetch_metadata")
      end

      conn = admin_conn(:post, "#{@reg_path}/#{c.id}/reject") |> call()
      assert conn.status == 403
      assert T.client_row(c.id)["status"] == "pending"
      assert audit_rows("oauth_client_rejected", c.id) == []
    end

    for {label, header, value} <- [
          {"cross-site", "sec-fetch-site", "cross-site"},
          {"same-site", "sec-fetch-site", "same-site"},
          {"Dest: iframe", "sec-fetch-dest", "iframe"},
          {"Mode: cors", "sec-fetch-mode", "cors"}
        ] do
      test "reject with #{label} => 403 fetch_metadata, still pending, no audit", %{ids: ids} do
        c = insert_client(ids, "pending")
        conn = click_admin_conn(:post, "#{@reg_path}/#{c.id}/reject") |> put_req_header(unquote(header), unquote(value)) |> call()
        assert conn.status == 403
        assert conn.resp_body =~ ~s(data-error="fetch_metadata")
        assert T.client_row(c.id)["status"] == "pending"
        assert audit_rows("oauth_client_rejected", c.id) == []
      end
    end

    test "bulk removal POST: cross-site / Dest: iframe / no headers => 403, nothing removed; the strict headers work", %{ids: ids} do
      domain = "t#{T.rand(5)}.com"
      c = insert_client(ids, "pending", %{host: "a.#{domain}", client_domain: domain})
      params = %{"host" => domain, "match" => "domain", "as_of" => DateTime.utc_now() |> DateTime.to_iso8601()}

      for {h, v} <- [{"sec-fetch-site", "cross-site"}, {"sec-fetch-dest", "iframe"}] do
        conn = click_admin_conn(:post, "#{@reg_path}/bulk-remove", params) |> put_req_header(h, v) |> call()
        assert conn.status == 403, "#{h}: #{v}"
        assert T.client_row(c.id) != nil, "nothing was removed"
      end

      assert (admin_conn(:post, "#{@reg_path}/bulk-remove", params) |> call()).status == 403, "no fetch metadata at all"
      assert T.client_row(c.id) != nil

      conn = click_admin_conn(:post, "#{@reg_path}/bulk-remove", params) |> call()
      assert conn.status in [302, 303]
      assert T.client_row(c.id) == nil
    end

    test "the 403 page links back to the page the admin came from", %{ids: ids} do
      c = insert_client(ids, "approved")
      p = insert_client(ids, "pending")

      revoke = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host}) |> put_req_header("sec-fetch-dest", "iframe") |> call()
      assert [back] = revoke |> doc() |> Floki.find(~s(a[data-role="back-to-list"]))
      assert Floki.attribute(back, "href") == [revoke_path(c.id)]
      assert text(back) =~ "revoke confirmation"

      reject = click_admin_conn(:post, "#{@reg_path}/#{p.id}/reject") |> put_req_header("sec-fetch-dest", "iframe") |> call()
      assert [back2] = reject |> doc() |> Floki.find(~s(a[data-role="back-to-list"]))
      assert Floki.attribute(back2, "href") == [@reg_path]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7.5 — no framing
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7.5 — /admin/oauth/* cannot be framed" do
    test "every OAuth admin page and the 403 page send frame-ancestors 'none' + X-Frame-Options: DENY", %{ids: ids} do
      a = insert_client(ids, "approved")
      p = insert_client(ids, "pending")

      responses = [
        admin_conn(:get, @reg_path) |> call(),
        admin_conn(:get, "#{@reg_path}/bulk-remove?host=x.com&match=domain") |> call(),
        admin_conn(:get, approve_path(p.id)) |> call(),
        admin_conn(:get, @clients_path) |> call(),
        admin_conn(:get, @revoked_path) |> call(),
        admin_conn(:get, revoke_path(a.id)) |> call(),
        fresh_admin_conn(:post, revoke_path(a.id), %{"confirm_host" => a.host}) |> put_req_header("sec-fetch-dest", "iframe") |> call()
      ]

      for conn <- responses do
        csp = conn |> get_resp_header("content-security-policy") |> List.first()
        assert csp =~ "frame-ancestors 'none'", "#{conn.request_path}: #{csp}"
        refute csp =~ "frame-ancestors 'self'"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], conn.request_path
        assert get_resp_header(conn, "cache-control") == ["no-store"], "#{conn.request_path}: confirm pages carry a CSRF token (Kassandra L-1)"
        assert csp =~ "script-src 'self'", "the rest of the admin policy is unchanged"
      end
    end

    test "?logos=1 still widens img-src to the logo origins, now on top of the new frame-ancestors", %{ids: ids} do
      c = insert_client(ids, "pending", %{logo: true})
      conn = admin_conn(:get, @reg_path <> "?logos=1") |> call()
      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "img-src 'self' data: https://#{c.host}", "the per-response widening to the logo origin keeps working"
    end

    test "another admin page keeps frame-ancestors 'self' and sends no DENY" do
      conn = admin_conn(:get, "/admin/dashboard") |> call()
      assert (conn |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'self'"
      refute get_resp_header(conn, "x-frame-options") == ["DENY"]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.1 / AC8.5 — the fresh re-authentication marker
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.1 — approve and revoke need a fresh marker of the same admin" do
    test "revoke: no marker, an old one, a future one, another admin's one => 303 to the re-auth start with the confirm page as return_to; nothing changed", %{ids: ids} do
      c = insert_client(ids, "approved")
      confirm = revoke_path(c.id)
      mk = fn marker ->
        base = admin_conn(:post, confirm, %{"confirm_host" => c.host})
        base = if marker, do: put_session(base, "admin_reauth", marker), else: base
        base |> T.put_strict_fetch_headers() |> call()
      end

      for {label, marker} <- [
            {"no marker", nil},
            {"older than 300 s", T.fresh_marker("admin-1", 310, "auth_time", confirm)},
            {"far in the future", T.fresh_marker("admin-1", -60, "auth_time", confirm)},
            {"another admin", T.fresh_marker("admin-2", 0, "auth_time", confirm)},
            {"empty sub", T.fresh_marker("", 0, "auth_time", confirm)},
            {"garbage", "yes"},
            {"missing at", %{"sub" => "admin-1", "kind" => "auth_time", "path" => confirm}},
            {"string at", %{"sub" => "admin-1", "at" => "now", "kind" => "auth_time", "path" => confirm}},
            {"the old unbound shape (no path)", T.fresh_marker("admin-1")},
            {"bound to ANOTHER confirm page (another client)", T.fresh_marker("admin-1", 0, "auth_time", revoke_path("someone-else"))},
            {"bound to the approve page of the same client", T.fresh_marker("admin-1", 0, "auth_time", approve_path(c.id))},
            {"bound to a list, not a confirm page", T.fresh_marker("admin-1", 0, "auth_time", @clients_path)}
          ] do
        conn = mk.(marker)
        assert conn.status in [302, 303], "#{label}: expected the re-auth redirect, got #{conn.status}"
        uri = URI.parse(location(conn))
        assert uri.path == "/admin/login/start", label
        assert URI.decode_query(uri.query) == %{"mode" => "reauth", "return_to" => confirm}, label
        assert T.client_row(c.id)["status"] == "approved", "#{label}: nothing changed"
      end

      assert audit_rows("oauth_client_revoked", c.id) == []
    end

    test "approve: the same, with the approve confirm page as return_to", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = admin_conn(:post, approve_path(c.id)) |> T.put_strict_fetch_headers() |> call()
      assert conn.status in [302, 303]
      uri = URI.parse(location(conn))
      assert uri.path == "/admin/login/start"
      assert URI.decode_query(uri.query) == %{"mode" => "reauth", "return_to" => approve_path(c.id)}
      assert T.client_row(c.id)["status"] == "pending"
    end

    test "the boundary: a marker 290 s old and one 3 s in the future are accepted, one 310 s old is not", %{ids: ids} do
      for {ago, ok?} <- [{290, true}, {-3, true}, {310, false}] do
        c = insert_client(ids, "approved")
        conn = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host}, ago: ago) |> call()
        assert (T.client_row(c.id)["status"] == "revoked") == ok?, "ago=#{ago}: status #{T.client_row(c.id)["status"]}, response #{conn.status} #{location(conn)}"
      end
    end

    test "a marker authorizes ONE confirm page: approving client B with the marker of client A is refused (Kassandra M-1)", %{ids: ids} do
      a = insert_client(ids, "pending")
      b = insert_client(ids, "pending")
      marker = T.fresh_marker("admin-1", 100, "auth_time", approve_path(a.id))

      for c <- [b] do
        conn = admin_conn(:post, approve_path(c.id)) |> put_session("admin_reauth", marker) |> T.put_strict_fetch_headers() |> call()
        assert URI.parse(location(conn)).path == "/admin/login/start"
        assert URI.decode_query(URI.parse(location(conn)).query)["return_to"] == approve_path(c.id)
      end

      assert T.client_row(b.id)["status"] == "pending"
      ok = admin_conn(:post, approve_path(a.id)) |> put_session("admin_reauth", marker) |> T.put_strict_fetch_headers() |> call()
      assert T.client_row(a.id)["status"] == "approved", "the marker of A approves A (#{ok.status})"
    end

    test "single use: a successful approve and a successful revoke drop the marker; a refused typed host keeps it", %{ids: ids} do
      p = insert_client(ids, "pending")
      approve = fresh_admin_conn(:post, approve_path(p.id)) |> call()
      assert T.client_row(p.id)["status"] == "approved"
      assert approve.private.plug_session["admin_reauth"] == nil, "consumed by the approval"

      c = insert_client(ids, "approved")
      wrong = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => "wrong.example.com"}) |> call()
      assert location(wrong) == revoke_path(c.id)
      assert wrong.private.plug_session["admin_reauth"] != nil, "a typo does not cost the fresh sign-in"

      ok = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host}) |> call()
      assert T.client_row(c.id)["status"] == "revoked"
      assert ok.private.plug_session["admin_reauth"] == nil, "consumed by the revocation"
    end

    test "reject and bulk removal do NOT need a marker (strict headers only)", %{ids: ids} do
      c = insert_client(ids, "pending")
      assert (click_admin_conn(:post, "#{@reg_path}/#{c.id}/reject") |> call()).status in [302, 303]
      assert T.client_row(c.id)["status"] == "rejected"
    end
  end

  describe "AC8.5 — the audit rows record how the fresh login was proven" do
    test "approve and revoke audit metadata `reauth` equals the marker kind", %{ids: ids} do
      for kind <- ["auth_time", "flow"] do
        p = insert_client(ids, "pending")
        a = insert_client(ids, "approved")
        fresh_admin_conn(:post, approve_path(p.id), nil, kind: kind) |> call()
        fresh_admin_conn(:post, revoke_path(a.id), %{"confirm_host" => a.host}, kind: kind) |> call()

        assert [[_, %{"reauth" => ^kind}, _, _]] = audit_rows("oauth_client_approved", p.id)
        assert [[_, %{"reauth" => ^kind, "devices" => 0}, _, _]] = audit_rows("oauth_client_revoked", a.id)
      end
    end
  end

  describe "review cycle 1 — UX and security details of the confirm pages" do
    test "approve confirm page: the button name contains its visible text (WCAG 2.5.3), no static status role, the back link, the cancel link", %{ids: ids} do
      c = insert_client(ids, "pending", %{name: "Label Me"})
      # story admin-reauth-button-flow: the submit button is the fresh state (stale: the link "Sign in again to approve")
      d = fresh_admin_conn(:get, approve_path(c.id)) |> call() |> doc()
      assert [button] = Floki.find(d, ~s(button[data-role="approve-confirm"]))
      assert text(button) == "Approve client"
      assert Floki.attribute(button, "aria-label") |> hd() =~ "Approve client", "the accessible name starts with the visible label"
      assert Floki.find(d, ~s([role="status"])) == [], "no static role=status noise"
    end

    test "approve confirm page: a registration under a host that was revoked before carries the warning (L-3)", %{ids: ids} do
      revoked = insert_client(ids, "revoked", %{host: "again.example.org"})
      other = insert_client(ids, "revoked", %{host: "again.example.org"})
      fresh = insert_client(ids, "pending", %{host: "again.example.org", name: "Totally New Name"})
      clean = insert_client(ids, "pending", %{host: "never-seen-#{T.rand(5)}.example.org"})
      assert revoked.id != other.id

      warned = admin_conn(:get, approve_path(fresh.id)) |> call()
      assert [note] = warned |> doc() |> Floki.find(~s([data-role="revoked-same-host"]))
      assert text(note) =~ "2 revoked clients share this host"

      assert admin_conn(:get, approve_path(clean.id)) |> call() |> doc() |> Floki.find(~s([data-role="revoked-same-host"])) == []
    end

    test "revoke confirm page: re-auth notice above the buttons, autofocus on the host, Cancel first, no status role", %{ids: ids} do
      c = insert_client(ids, "approved")
      d = admin_conn(:get, revoke_path(c.id)) |> call() |> doc()
      assert Floki.find(d, ~s([role="status"])) == []
      assert [state] = Floki.find(d, ~s(form [data-role="reauth-state"]))
      assert Floki.attribute(state, "data-reauth") == ["needed"]
      # story admin-reauth-button-flow (Decision): nothing was typed before the sign-in, so the hint says to sign in FIRST and no longer "type ... again"
      assert text(state) =~ ~r/\bfirst\b/
      refute text(state) =~ ~r/\btype\b[^.]*\bagain\b/i
      # story admin-reauth-button-flow (UX gate M4): while the sign-in link is the primary control the host field takes no autofocus (it would be lost at the sign-in)
      assert Floki.find(d, ~s(input[name="confirm_host"][autofocus])) == []
      assert [h2] = Floki.find(d, ~s([data-role="revoke-consequences"] h2))
      assert text(h2) =~ "What happens"

      fresh = fresh_admin_conn(:get, revoke_path(c.id)) |> call() |> doc()
      assert [_] = Floki.find(fresh, ~s(input[name="confirm_host"][autofocus]))

      # story admin-reauth-button-flow: the submit with data-role=revoke-confirm exists in the fresh state only
      html = Floki.raw_html(fresh)
      {cancel_at, _} = :binary.match(html, ~s(data-role="revoke-cancel"))
      {revoke_at, _} = :binary.match(html, ~s(data-role="revoke-confirm"))
      assert cancel_at < revoke_at, "Cancel comes first in the tab order"

      assert fresh |> Floki.find(~s([data-role="reauth-state"])) |> Floki.attribute("data-reauth") == ["fresh"]
    end

    test "a typed-host mismatch is shown WITH the field: aria-invalid, aria-describedby, one alert", %{ids: ids} do
      c = insert_client(ids, "approved")
      post = fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => "nope.example.org"}) |> call()
      assert flash_of(post)["error"] && flash_of(post)["confirm_host_error"]

      # the redirect target rendered with the flash of the POST (the flash lives in the session cookie)
      get = %{conn(:get, revoke_path(c.id)) | secret_key_base: @secret_key_base} |> recycle_cookies(post) |> call()
      d = doc(get)
      assert [input] = Floki.find(d, ~s(input[name="confirm_host"]))
      assert Floki.attribute(input, "aria-invalid") == ["true"]
      assert Floki.attribute(input, "aria-describedby") |> hd() =~ "confirm-host-error"
      assert [err] = Floki.find(d, ~s(#confirm-host-error[role="alert"]))
      assert text(err) =~ "does not match"
      assert length(Floki.find(d, ~s([role="alert"]))) == 1, "announced once, not twice"
    end
  end

  describe "AC11 — logging of the admin refusals" do
    test "the re-auth redirect, the host mismatch and the fetch-metadata refusal log no cookie, token, CSRF value, reason or client metadata", %{ids: ids} do
      debug_logging!()
      c = insert_client(ids, "approved", %{name: "Name-To-Keep-Out-Of-Logs"})

      log =
        capture_log([level: :debug], fn ->
          admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "reason-keep-out-123"}) |> T.put_strict_fetch_headers() |> call()
          fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => "nope.example.com", "reason" => "reason-keep-out-123"}) |> call()
          fresh_admin_conn(:post, revoke_path(c.id), %{"confirm_host" => c.host, "reason" => "reason-keep-out-123"}) |> put_req_header("sec-fetch-site", "cross-site") |> call()
        end)

      for needle <- ["reason-keep-out-123", "Name-To-Keep-Out-Of-Logs", "cross-site", "_csrf_token", "admin_reauth"],
          do: refute(log =~ needle, "#{needle} must not be logged")
    end
  end
end

defmodule Nebu.OAuth.OAuthAdminClientsTest.FailingAudit do
  @moduledoc false
  def log(_actor, _action, _type, _id, _metadata, _outcome, _error_detail \\ nil), do: {:error, :audit_down}
end
