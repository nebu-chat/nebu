defmodule Nebu.OAuth.OAuthAdminTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-metadata-dcr-admin-approval`,
  AC4 (admin-controlled approval) + the AC7 admin-audit clause.

  Routes (story Dev Notes, "Admin-UI Backend Routes"), all behind `Nebu.Admin.Auth :require_admin`:

    * `GET  /admin/oauth/registrations`                       — list PENDING registrations
    * `GET  /admin/oauth/registrations/:client_id/approve`    — the approve CONFIRM page (story
      oauth-client-revocation SO3; the list's Approve is a link to it, no native confirm())
    * `POST /admin/oauth/registrations/:client_id/approve`    — approve (fresh re-auth marker + strict
      fetch metadata required since story oauth-client-revocation: `fresh_admin_conn/3`)
    * `POST /admin/oauth/registrations/:client_id/reject`     — reject (optional `reason`)

  Driven through `Nebu.Admin.Endpoint` with a real signed admin session (same pattern as
  `Nebu.Admin.HttpControllersTest`; CSRF bypass flag only where a test is not about CSRF).
  Fixture rows are inserted with the documented AC5 schema, so these tests are independent of
  the DCR handler. The browser-level flow (real OIDC login, no cookie forging) is covered by
  the Gherkin feature `e2e/features/admin/oauth-client-approvals.feature`.

  HTML markup contract (shared with the Gherkin step definitions):
    * page root `data-page="oauth-registrations"`
    * one row per pending client `[data-role="oauth-client-row"][data-client-id=ID]`
    * empty state `[data-role="no-pending-clients"]` (asserted in the Gherkin feature only —
      an ExUnit empty-state test would have to mutate foreign rows in the shared DB)
    * forms post to `/admin/oauth/registrations/ID/approve|reject` (reject: input `reason`)

  Audit contract (ambiguity flagged in the ATDD report): actions `oauth_client_approved` /
  `oauth_client_rejected`, target_type `oauth_client`, target_id = client_id, outcome `success`;
  the full client metadata is NOT part of the audit row.
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
  @list_path "/admin/oauth/registrations"

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    T.enable_oauth()
    {:ok, ids} = Agent.start(fn -> [] end)

    # config/test.exs installs the no-op audit writer suite-wide (`:compliance, :audit_writer`).
    # These tests assert REAL `audit_log` rows, so use the real writer here and put the prior
    # value back afterwards.
    prior_writer = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      case prior_writer do
        {:ok, writer} -> Application.put_env(:compliance, :audit_writer, writer)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end

      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      T.clear_oauth_config()
      T.cleanup_clients(Agent.get(ids, & &1))
      Agent.stop(ids)
    end)

    {:ok, ids: ids}
  end

  # ── fixtures / helpers ─────────────────────────────────────────────────────

  defp insert_client(ids, status, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    # `unique_integer` restarts on every VM boot while `audit_log` is append-only and the runtime
    # role cannot DELETE registrations, so a per-run random suffix keeps ids unique across runs
    # against the same (non-fresh) database.
    id = "atdd-admin-#{n}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    Agent.update(ids, &[id | &1])

    name = Map.get(attrs, :name, "AdminListApp-#{n}-end")
    application_type = Map.get(attrs, :application_type, "web")
    # story oauth-dcr-abuse-hardening: optional client_uri override and the stored host / registrable
    # domain columns (only written when given, so the older tests need no migration 000044)
    client_uri = Map.get(attrs, :client_uri, "https://app#{n}.example.com")

    metadata =
      %{
        "client_name" => name,
        "client_uri" => client_uri,
        "redirect_uris" =>
          Map.get(attrs, :redirect_uris, ["https://app#{n}.example.com/callback", "https://app#{n}.example.com/cb2"]),
        "logo_uri" => "https://app#{n}.example.com/logo.png",
        "application_type" => application_type
      }
      |> then(fn m -> if Map.get(attrs, :logo, true), do: m, else: Map.delete(m, "logo_uri") end)

    extra = [client_host: Map.get(attrs, :client_host), client_domain: Map.get(attrs, :client_domain)]
    T.insert_row!(id, Jason.encode!(metadata), "hash-#{id}", status, "NOW()", application_type, extra)

    %{id: id, name: name, metadata: metadata}
  end

  # Every state-changing admin POST (approve, revoke, reject, bulk removal) needs the strict fetch metadata of a
  # user-clicked form submit (story oauth-client-revocation SO2 + review cycle 1, Kassandra L-2): a real browser sends it.
  defp admin_conn(method, path, params \\ nil) do
    %{conn(method, path, params) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => @admin})
    |> then(fn conn -> if method in [:post, "POST"], do: T.put_strict_fetch_headers(conn), else: conn end)
  end

  # Story oauth-client-revocation (SO2, SO4; AC8.6): approving (and revoking) needs a FRESH admin
  # re-authentication marker in the session (`admin_reauth` = %{"sub", "at", "kind", "path"}, at most 300 s old, same
  # `sub`, bound to the confirm page = the request path) and the STRICT fetch metadata of a user-clicked form submit (all four Sec-Fetch headers). Every
  # story-1 approve below goes through this helper; all other assertions are unchanged.
  defp fresh_admin_conn(method, path, params \\ nil) do
    admin_conn(method, path, params)
    |> put_session("admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", URI.parse(path).path))
    |> T.put_strict_fetch_headers()
  end

  defp non_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => false, "sub" => "user-1", "matrix_user_id" => "@alex:test.local"})
  end

  defp anon_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp audit_rows(action, client_id) do
    %{rows: rows} =
      T.sql!(
        "SELECT actor_user_id, action, target_type, target_id, metadata, outcome FROM audit_log WHERE action = $1 AND target_id = $2",
        [action, client_id]
      )

    rows
  end

  # ── AC4: list ──────────────────────────────────────────────────────────────

  describe "AC4 — GET /admin/oauth/registrations lists pending registrations only" do
    test "shows pending clients with name, client URI, redirect URIs, logo, created time, Approve/Reject",
         %{ids: ids} do
      pending = for _ <- 1..3, do: insert_client(ids, "pending")
      approved = for _ <- 1..2, do: insert_client(ids, "approved")
      rejected = insert_client(ids, "rejected")

      conn = admin_conn(:get, @list_path) |> call()
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
      assert conn.resp_body =~ ~s(data-page="oauth-registrations")

      for c <- pending do
        assert conn.resp_body =~ ~s(data-client-id="#{c.id}"), "pending client #{c.id} not listed"
        assert conn.resp_body =~ c.name
        assert conn.resp_body =~ c.metadata["client_uri"]
        for uri <- c.metadata["redirect_uris"], do: assert(conn.resp_body =~ uri)
        assert conn.resp_body =~ c.metadata["logo_uri"], "the logo URL must be visible as text"
        assert conn.resp_body =~ "#{@list_path}/#{c.id}/approve"
        assert conn.resp_body =~ "#{@list_path}/#{c.id}/reject"
      end

      for c <- approved ++ [rejected] do
        refute conn.resp_body =~ ~s(data-client-id="#{c.id}"), "non-pending client #{c.id} must not be listed"
        refute conn.resp_body =~ c.name
      end

      refute conn.resp_body =~ "<img", "no client-hosted image may be rendered by default (logos only on click)"
    end

    test "each pending row exposes its registration timestamp (data-field=\"created\")",
         %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = admin_conn(:get, @list_path) |> call()
      assert conn.status == 200
      assert conn.resp_body =~ ~r/data-client-id="#{c.id}".*?data-field="created"/s
    end

    test "Accept: application/json returns the pending registrations as a JSON list (story: JSON API)",
         %{ids: ids} do
      pending = insert_client(ids, "pending")
      approved = insert_client(ids, "approved")

      conn = admin_conn(:get, @list_path) |> put_req_header("accept", "application/json") |> call()
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"

      body = Jason.decode!(conn.resp_body)
      list = if is_list(body), do: body, else: body["registrations"] || body["clients"] || []
      listed = Enum.map(list, & &1["client_id"])
      assert pending.id in listed
      refute approved.id in listed

      # paging metadata: the real total is always reported
      assert is_map(body) and body["total"] >= 1
      assert body["page"] == 1 and body["page_size"] == 50 and body["total_pages"] >= 1
    end

    test "the list renders client-supplied text HTML-escaped (stored-XSS guard)", %{ids: ids} do
      evil = insert_client(ids, "pending", %{name: "<script>alert(\"xss\")</script>"})
      conn = admin_conn(:get, @list_path) |> call()
      assert conn.status == 200
      refute conn.resp_body =~ "<script>alert(\"xss\")</script>"
      assert conn.resp_body =~ ~s(data-client-id="#{evil.id}")
    end
  end

  # ── code-review cycle 1: UX gate (V1, A2-A8) markup contract ───────────────

  describe "UX gate — row markup" do
    test "name is the row header; redirect URIs are a list; long client-supplied text cannot push the actions away",
         %{ids: ids} do
      c = insert_client(ids, "pending", %{name: String.duplicate("W", 255)})
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)
      row = row_html(body, c.id)

      # V1: width-capped, break-anywhere cells for the three unbounded client strings
      assert row =~ ~r/<th scope="row" data-field="client-name" class="[^"]*max-w-xs[^"]*break-all/
      assert row =~ ~r/<td data-field="client-uri" class="[^"]*max-w-xs[^"]*break-all/
      assert row =~ ~r/<a [^>]*class="[^"]*break-all/
      # A4 + A2
      for uri <- c.metadata["redirect_uris"] do
        assert row =~ ~r/<li [^>]*data-role="redirect-uri"[^>]*>\s*<span [^>]*class="[^"]*break-all[^"]*"[^>]*>#{Regex.escape(uri)}<\/span>/
      end

      refute row =~ ", https://", "redirect URIs must not be comma-joined"
    end

    test "the client URI host is shown prominently and the new-tab link announces itself (A5)", %{ids: ids} do
      c = insert_client(ids, "pending")
      row = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body) |> row_html(c.id)
      host = URI.parse(c.metadata["client_uri"]).host

      assert row =~ ~s(data-role="client-host">#{host}</div>)
      assert row =~ ~s|<span class="sr-only"> (opens in new tab)</span>|
      assert row =~ ~s(rel="noopener noreferrer")
    end

    test "a client without a logo gets an sr-only 'No logo'; one with a logo shows its URL as text, host prominent (A3)",
         %{ids: ids} do
      without = insert_client(ids, "pending", %{logo: false})
      with_logo = insert_client(ids, "pending")
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)

      assert row_html(body, without.id) =~ ~s(<span class="sr-only">No logo</span>)
      refute row_html(body, without.id) =~ "<img"
      refute row_html(body, without.id) =~ ~s(data-role="logo-url")

      row = row_html(body, with_logo.id)
      host = URI.parse(with_logo.metadata["logo_uri"]).host
      refute row =~ "<img", "the default page makes no contact to client-hosted URLs"
      refute row =~ "No logo"
      assert row =~ ~s(data-role="logo-host">#{host}</div>)
      assert row =~ with_logo.metadata["logo_uri"]
    end

    test "the reject reason has a VISIBLE label with the limit (A6) and the table is zebra striped (A9)", %{ids: ids} do
      c = insert_client(ids, "pending")
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)

      assert row_html(body, c.id) =~ ~r/<label class="text-xs[^"]*" for="reason-#{c.id}">\s*Reason \(optional, max 500\)\s*<\/label>/
      assert body =~ ~r/<table class="table table-zebra/
    end

    # F-5: the VERIFIED host comes first, the attacker-chosen name second and quoted.
    # Story oauth-client-revocation (SO3): the approve button is a LINK to a confirm page (no native
    # confirm(), no form in the list: Sec-Fetch-User needs a plain user-clicked submit); reject keeps data-confirm.
    test "the native reject confirm leads with the client URI host and quotes the name (A8, F-5); approve is a link (SO3)", %{ids: ids} do
      c = insert_client(ids, "pending")
      row = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body) |> row_html(c.id)
      host = URI.parse(c.metadata["client_uri"]).host

      assert row =~
               ~s|data-confirm="Reject client at #{host} (name &quot;#{c.name}&quot;)? The registration is kept but can never be used."|

      refute row =~ ~s(data-form="approve-client"), "the list has no approve form any more (SO3)"
      refute row =~ ~r/Approve client at/, "no native approve confirm in the list (SO3)"
      assert [link] = row |> Floki.parse_fragment!() |> Floki.find(~s(a[data-role="review-approve"]))
      assert Floki.attribute(link, "href") |> hd() =~ "#{@list_path}/#{c.id}/approve"
    end

    # story oauth-hardening-hygiene HY6 (I-10, test review M11): the RENDERED data-confirm of a hostile name
    test "a hostile client name is JSON-escaped and cut to 80 graphemes inside the rendered data-confirm (HY6)", %{ids: ids} do
      hostile = ~S|x" at evil.example (name "y| <> "\nline2\u0001"
      long = String.duplicate("n", 90)
      a = insert_client(ids, "pending", %{name: hostile})
      b = insert_client(ids, "pending", %{name: long})

      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)

      confirm = fn c ->
        [form] = c.id |> then(&row_html(body, &1)) |> Floki.parse_fragment!() |> Floki.find("[data-confirm]")
        form |> Floki.attribute("data-confirm") |> hd()
      end

      host_a = URI.parse(a.metadata["client_uri"]).host
      assert confirm.(a) == "Reject client at #{host_a} (name " <> Jason.encode!(hostile) <> ")? The registration is kept but can never be used."
      refute confirm.(a) =~ "\n", "no raw line break reaches the native dialog"

      host_b = URI.parse(b.metadata["client_uri"]).host
      assert confirm.(b) == "Reject client at #{host_b} (name " <> Jason.encode!(String.duplicate("n", 80) <> "…") <> ")? The registration is kept but can never be used."
    end

    test "the approve confirm page names the verified host BEFORE the claimed name, no data-confirm, form posts to /approve (SO3)", %{ids: ids} do
      c = insert_client(ids, "pending", %{name: "Element (app.element.io)"})
      conn = admin_conn(:get, "#{@list_path}/#{c.id}/approve") |> call()
      assert conn.status == 200
      body = conn.resp_body
      host = URI.parse(c.metadata["client_uri"]).host

      assert body =~ ~s(data-page="oauth-approve-confirm")
      refute body =~ "data-confirm", "no native confirm() on the approve step: a plain user-clicked submit (SO3)"
      {host_at, _} = :binary.match(body, host)
      {name_at, _} = :binary.match(body, "Element (app.element.io)")
      assert host_at < name_at, "the verified host comes before the attacker-chosen name"
      for uri <- c.metadata["redirect_uris"], do: assert(body =~ uri)
      assert body =~ ~s(data-role="redirect-uri")

      # story oauth-hardening-hygiene HY7: no "host-bound" wording on the confirm page either
      visible = String.replace(body, ~r/data-role="redirect-(not-)?host-bound"/, "")
      refute visible =~ "host-bound"
      assert body =~ "host matches client_uri"
      assert body =~ "matches the client URI host"

      d = Floki.parse_document!(body)
      assert [form] = Floki.find(d, ~s(form[data-role="approve-confirm-form"]))
      assert Floki.attribute(form, "method") |> hd() |> String.downcase() == "post"
      assert Floki.attribute(form, "action") == ["#{@list_path}/#{c.id}/approve"]
      assert Floki.find(form, ~s(input[name="_csrf_token"])) != []
      assert T.client_row(c.id)["status"] == "pending", "the GET confirm page changes nothing"
    end
  end

  # ── security review F-5: the page lets the admin spot impersonation ────────

  describe "F-5 — approval page: application type, host-binding, unverified claims" do
    test "the page states that name, client URI and logo are unverified claims", %{ids: ids} do
      insert_client(ids, "pending")
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)

      assert body =~ ~s(data-role="unverified-claims-note")
      assert body =~ "NOT verified"
    end

    test "every row shows its application_type", %{ids: ids} do
      web = insert_client(ids, "pending")
      native = insert_client(ids, "pending", %{application_type: "native", redirect_uris: ["http://localhost/cb"]})
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)

      assert row_html(body, web.id) =~ ~s(data-role="application-type" data-application-type="web">web</span>)
      assert row_html(body, native.id) =~ ~s(data-role="application-type" data-application-type="native">native</span>)
    end

    test "https redirect URIs are badged host-bound; loopback and private-scheme ones NOT host-bound", %{ids: ids} do
      web = insert_client(ids, "pending")

      native =
        insert_client(ids, "pending", %{
          application_type: "native",
          redirect_uris: ["http://localhost/cb", "http://127.0.0.1/cb", "com.example.app:/cb"]
        })

      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)

      web_row = row_html(body, web.id)
      assert web_row =~ ~s(data-role="redirect-host-bound")
      refute web_row =~ ~s(data-role="redirect-not-host-bound")
      refute web_row =~ ~s(data-role="identity-unverified")

      native_row = row_html(body, native.id)
      assert length(Regex.scan(~r/data-role="redirect-not-host-bound"/, native_row)) == 3
      # story oauth-hardening-hygiene HY7 (I-11): wording changed by design, data-role attributes did not
      assert native_row =~ "NOT tied to the client_uri host: client identity unverified"
      refute native_row =~ "NOT host-bound"
      assert web_row =~ "host matches client_uri"
      refute native_row =~ ~s(data-role="redirect-host-bound")
      assert native_row =~ ~s(data-role="identity-unverified")

      # HY7: the string "host-bound" no longer appears in the rendered page (the data-role attributes stay)
      visible = String.replace(body, ~r/data-role="redirect-(not-)?host-bound"/, "")
      refute visible =~ "host-bound", "the list page must say `host matches client_uri`, not `host-bound`"
      assert body =~ "matches the client URI host", "the explanatory sentence uses the new wording"
    end

    test "a redirect host that differs from the client host is highlighted", %{ids: ids} do
      c =
        insert_client(ids, "pending", %{
          redirect_uris: ["https://auth.evil-sub.example.com/cb"]
        })

      row = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body) |> row_html(c.id)
      assert row =~ ~s(data-role="redirect-other-host")
      assert row =~ "auth.evil-sub.example.com"
    end
  end

  # ── decision cycle 0 #2: logos only on click, strict CSP by default ────────

  @strict_img "img-src 'self' data:;"

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  defp img_src(conn) do
    [directive] = Regex.run(~r/img-src [^;]*/, csp(conn))
    directive
  end

  describe "logos only on click (decision cycle 0 #2)" do
    test "default page: NO <img>, strict CSP (no https: wildcard), 'Load logos' control + explanation", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = admin_conn(:get, @list_path) |> call()

      assert conn.status == 200
      refute conn.resp_body =~ "<img"
      assert csp(conn) =~ @strict_img
      refute csp(conn) =~ "https:"
      refute csp(conn) =~ "https://"

      assert conn.resp_body =~ ~s(data-role="load-logos")
      assert conn.resp_body =~ ~s(href="#{@list_path}?logos=1")
      assert conn.resp_body =~ ~s(data-role="load-logos-note")
      refute conn.resp_body =~ ~s(data-role="hide-logos")
      assert row_html(conn.resp_body, c.id) =~ c.metadata["logo_uri"], "logo URL stays visible as text"
    end

    test "?logos=1: <img> only for https logos (no-referrer, lazy, alt), CSP widened to the EXACT logo origins", %{ids: ids} do
      a = insert_client(ids, "pending")
      b = insert_client(ids, "pending")
      no_logo = insert_client(ids, "pending", %{logo: false})
      conn = admin_conn(:get, @list_path <> "?logos=1") |> call()

      assert conn.status == 200
      for c <- [a, b] do
        row = row_html(conn.resp_body, c.id)
        assert row =~ ~r/<img [^>]*src="#{Regex.escape(c.metadata["logo_uri"])}"/
        assert row =~ ~s(referrerpolicy="no-referrer")
        assert row =~ ~s(loading="lazy")
        assert row =~ ~r/<img [^>]*class="[^"]*overflow-hidden/
        assert row =~ ~r/<img [^>]*alt="Logo of #{Regex.escape(c.name)}"/
        # the exact origin is allowed ...
        assert img_src(conn) =~ " https://" <> URI.parse(c.metadata["logo_uri"]).host
      end

      refute row_html(conn.resp_body, no_logo.id) =~ "<img"

      # ... and nothing broader than that
      directive = img_src(conn)
      refute directive =~ ~r/ https:(?:[ ;]|$)/, "no bare https: wildcard: #{directive}"
      refute directive =~ "*"
      assert directive =~ "'self' data:"

      # the rest of the policy is unchanged
      assert csp(conn) =~ "script-src 'self'"
      assert csp(conn) =~ "default-src 'self'"

      assert conn.resp_body =~ ~s(data-role="hide-logos")
      assert conn.resp_body =~ ~s(href="#{@list_path}")
      refute conn.resp_body =~ ~s(data-role="load-logos")
    end

    test "the widening is per request: a following default request is strict again", %{ids: ids} do
      insert_client(ids, "pending")
      widened = admin_conn(:get, @list_path <> "?logos=1") |> call()
      assert img_src(widened) =~ "https://"

      default = admin_conn(:get, @list_path) |> call()
      assert img_src(default) == "img-src 'self' data:"
      refute default.resp_body =~ "<img"
    end

    test "other values of ?logos do not load logos", %{ids: ids} do
      insert_client(ids, "pending")

      for v <- ["0", "true", "", "yes", "1&x=2"] do
        conn = admin_conn(:get, @list_path <> "?logos=" <> URI.encode_www_form(v)) |> call()
        refute conn.resp_body =~ "<img", "?logos=#{v}"
        assert img_src(conn) == "img-src 'self' data:"
      end
    end

    test "a logo with an unsafe origin is never rendered nor allowed (CSP header injection guard)", %{ids: ids} do
      n = System.unique_integer([:positive])
      id = "atdd-admin-evil-#{n}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      Agent.update(ids, &[id | &1])

      for {uri, i} <- Enum.with_index(["http://plain.example.com/l.png", "https://a.example.com;script-src *;/l.png", "https://user@u.example.com/l.png"]) do
        meta = %{"client_name" => "EvilLogo#{n}-#{i}", "client_uri" => "https://x.example.com", "logo_uri" => uri, "redirect_uris" => ["https://x.example.com/cb"]}
        cid = id <> "-#{i}"
        Agent.update(ids, &[cid | &1])

        T.sql!("INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status) VALUES ($1, $2::jsonb, $3, 'pending')", [cid, meta, "hash-" <> cid])
      end

      conn = admin_conn(:get, @list_path <> "?logos=1") |> call()
      assert conn.status == 200
      for i <- 0..2, do: refute(row_html(conn.resp_body, id <> "-#{i}") =~ "<img")
      refute csp(conn) =~ "plain.example.com"
      refute csp(conn) =~ "script-src *"
      assert csp(conn) =~ "script-src 'self'"
    end

    test "?logos=1 with no loadable logo keeps the CSP byte-identical to the default", %{ids: ids} do
      insert_client(ids, "pending", %{logo: false})
      # other (foreign) pending rows with logos may exist in a shared DB: compare only the
      # directive when the page has no logo at all
      conn = admin_conn(:get, @list_path <> "?logos=1") |> call()
      if not (conn.resp_body =~ "<img"), do: assert(img_src(conn) == "img-src 'self' data:")
    end

    test "the JSON list is unaffected by ?logos and keeps the URL as data", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = admin_conn(:get, @list_path <> "?logos=1") |> put_req_header("accept", "application/json") |> call()
      assert conn.status == 200
      entry = Enum.find(Jason.decode!(conn.resp_body)["registrations"], &(&1["client_id"] == c.id))
      assert entry["logo_uri"] == c.metadata["logo_uri"]
      assert img_src(conn) == "img-src 'self' data:"
    end

    test "no other admin page is affected: strict CSP everywhere" do
      conn = admin_conn(:get, "/admin/dashboard") |> call()
      assert csp(conn) =~ @strict_img
    end
  end

  # ── decision cycle 0 #1: pagination, total, never silently truncated ──────

  describe "pagination (decision cycle 0 #1)" do
    # 55 pending rows, NEWER than any other row (created_at in the future), so they are exactly
    # the first 55 of the newest-first list whatever else the shared database holds.
    setup %{ids: ids} do
      tag = "pg#{System.unique_integer([:positive])}#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"

      T.sql!(
        "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, status, created_at) " <>
          "SELECT $1::text || '-' || g, jsonb_build_object('client_name', 'Paged ' || $1::text || ' ' || g, 'client_uri', 'https://example.com', " <>
          "'redirect_uris', jsonb_build_array('https://example.com/cb')), 'hash-' || $1::text || '-' || g, 'pending', " <>
          "NOW() + INTERVAL '10 years' + g * INTERVAL '1 second' FROM generate_series(1, 55) g",
        [tag]
      )

      Agent.update(ids, &(Enum.map(1..55, fn g -> "#{tag}-#{g}" end) ++ &1))
      {:ok, tag: tag}
    end

    defp row_ids(body), do: Regex.scan(~r/data-role="oauth-client-row" data-client-id="([^"]+)"/, body) |> Enum.map(&List.last/1)

    test "page 1 shows exactly 50 rows, the real total, 'N more pending' and a next link", %{tag: tag} do
      conn = admin_conn(:get, @list_path) |> call()
      body = conn.resp_body
      ids = row_ids(body)

      assert length(ids) == 50
      # newest first: rows 55..6 are on page 1
      assert Enum.take(ids, 3) == ["#{tag}-55", "#{tag}-54", "#{tag}-53"]
      refute "#{tag}-5" in ids

      assert [_, total] = Regex.run(~r/data-role="pending-summary" data-total="(\d+)"/, body)
      assert String.to_integer(total) >= 55
      %{rows: [[db_total]]} = T.sql!("SELECT count(*) FROM oauth_clients WHERE status = 'pending'")
      assert String.to_integer(total) == db_total, "the total is the real pending count, never a truncated one"

      assert [_, more] = Regex.run(~r/data-role="more-pending" data-more="(\d+)"/, body)
      assert String.to_integer(more) == db_total - 50
      assert body =~ "#{db_total - 50} more pending on later pages"

      assert body =~ ~s(data-role="page-next")
      assert body =~ ~s(href="#{@list_path}?page=2")
      refute body =~ ~s(data-role="page-prev")
      assert body =~ ~s(data-role="pagination")
    end

    test "page 2 continues where page 1 ended, has a previous link, and rows never repeat", %{tag: tag} do
      p1 = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body) |> row_ids()
      conn = admin_conn(:get, @list_path <> "?page=2") |> call()
      p2 = row_ids(conn.resp_body)

      assert Enum.take(p2, 5) == for(g <- 5..1//-1, do: "#{tag}-#{g}")
      assert MapSet.disjoint?(MapSet.new(p1), MapSet.new(p2))
      assert conn.resp_body =~ ~s(data-role="page-prev")
      assert conn.resp_body =~ ~s(href="#{@list_path}")
      assert conn.resp_body =~ ~r/data-page="2"/
    end

    test "every pending row is reachable by walking the pages (nothing is silently cut off)", %{tag: tag} do
      %{rows: [[db_total]]} = T.sql!("SELECT count(*) FROM oauth_clients WHERE status = 'pending'")
      pages = div(db_total + 49, 50)

      seen =
        for p <- 1..pages, reduce: [] do
          acc -> acc ++ row_ids(admin_conn(:get, "#{@list_path}?page=#{p}") |> call() |> Map.fetch!(:resp_body))
        end

      assert length(seen) == db_total
      assert length(Enum.uniq(seen)) == db_total
      for g <- 1..55, do: assert("#{tag}-#{g}" in seen)
    end

    test "invalid pages fall back to page 1; a page past the end is clamped to the last page" do
      for bad <- ["abc", "0", "-3", "1.5", "", "2x"] do
        conn = admin_conn(:get, @list_path <> "?page=" <> URI.encode_www_form(bad)) |> call()
        assert conn.status == 200
        assert conn.resp_body =~ ~r/data-page="1"/, "?page=#{bad}"
      end

      conn = admin_conn(:get, @list_path <> "?page=999999") |> call()
      assert conn.status == 200
      assert [_, page, last] = Regex.run(~r/data-page="(\d+)" data-total-pages="(\d+)"/, conn.resp_body)
      assert page == last
      assert row_ids(conn.resp_body) != []
    end

    test "JSON carries total/page/page_size/total_pages and honours ?page=", %{tag: tag} do
      conn = admin_conn(:get, @list_path <> "?page=2") |> put_req_header("accept", "application/json") |> call()
      body = Jason.decode!(conn.resp_body)
      assert body["page"] == 2 and body["page_size"] == 50
      assert body["total"] >= 55 and body["total_pages"] >= 2
      assert length(body["registrations"]) in 5..50
      assert "#{tag}-1" in Enum.map(body["registrations"], & &1["client_id"])
    end

    test "decision forms carry the page and logo mode; the redirect returns to that page", %{tag: tag} do
      conn = admin_conn(:get, @list_path <> "?page=2&logos=1") |> call()
      row = row_html(conn.resp_body, "#{tag}-5")
      assert row =~ ~s(name="page" value="2")
      assert row =~ ~s(name="logos" value="1")

      # page 1 / no logos: no extra fields
      p1 = admin_conn(:get, @list_path) |> call()
      refute row_html(p1.resp_body, "#{tag}-55") =~ ~s(name="page")
      refute row_html(p1.resp_body, "#{tag}-55") =~ ~s(name="logos")

      c = fresh_admin_conn(:post, "#{@list_path}/#{tag}-5/approve", %{"page" => "2", "logos" => "1"}) |> call()
      assert get_resp_header(c, "location") == ["#{@list_path}?page=2&logos=1"]
      assert T.client_row("#{tag}-5")["status"] == "approved"

      c = admin_conn(:post, "#{@list_path}/#{tag}-4/reject", %{"page" => "3"}) |> call()
      assert get_resp_header(c, "location") == ["#{@list_path}?page=3"]
    end

    test "hostile page/logos return values never reach the Location header", %{tag: tag} do
      c =
        fresh_admin_conn(:post, "#{@list_path}/#{tag}-3/approve", %{"page" => "2\r\nSet-Cookie: x=1", "logos" => "1&x=//evil.example"})
        |> call()

      assert get_resp_header(c, "location") == [@list_path]
    end

    test "with exactly one page there is no pager and no 'more pending'" do
      # (the shared DB makes an exact count unpredictable; assert the markup rule instead)
      conn = admin_conn(:get, @list_path <> "?page=999999") |> call()
      [_, last] = Regex.run(~r/data-total-pages="(\d+)"/, conn.resp_body)
      refute conn.resp_body =~ ~s(data-role="more-pending"), "the last page has nothing more (total_pages=#{last})"
      refute conn.resp_body =~ ~s(data-role="page-next")
    end
  end

  # Flash set by the controller (persisted into the session cookie data before send).
  defp flash_of(conn), do: conn.private.plug_session["phoenix_flash"] || %{}

  # The HTML of one client row (from its <tr> to the next one).
  defp row_html(body, client_id) do
    [_, rest] = String.split(body, ~s|<tr data-role="oauth-client-row" data-client-id="#{client_id}">|, parts: 2)
    rest |> String.split("</tr>", parts: 2) |> hd()
  end

  # ── code-review 5: an unreadable database is not "nothing pending" ─────────

  describe "list — database failure is surfaced (code-review 5)" do
    setup do
      Application.put_env(:nebu_http, :oauth_repo, Nebu.OAuth.TestSupport.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:nebu_http, :oauth_repo) end)
    end

    test "HTML: error flash, NOT the empty state" do
      {conn, log} = with_log(fn -> admin_conn(:get, @list_path) |> call() end)

      assert conn.status == 200
      assert conn.resp_body =~ ~s(data-role="toast" data-toast-kind="error")
      assert conn.resp_body =~ "could not be loaded"
      refute conn.resp_body =~ ~s(data-role="no-pending-clients")
      assert log =~ "could not list pending registrations"
    end

    test "JSON: 503 with an error body instead of an empty list" do
      {conn, _log} =
        with_log(fn -> admin_conn(:get, @list_path) |> put_req_header("accept", "application/json") |> call() end)

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["error"])
      refute Map.has_key?(body, "registrations")
    end

    test "a decision that cannot be saved says so and writes no audit entry", %{ids: ids} do
      Application.delete_env(:nebu_http, :oauth_repo)
      c = insert_client(ids, "pending")
      Application.put_env(:nebu_http, :oauth_repo, Nebu.OAuth.TestSupport.NoSuchRepo)

      conn = fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call()
      assert conn.status in [302, 303]
      assert flash_of(conn)["error"] =~ "could not be saved"

      Application.delete_env(:nebu_http, :oauth_repo)
      assert T.client_row(c.id)["status"] == "pending"
      assert audit_rows("oauth_client_approved", c.id) == []
    end
  end

  # ── code-review 6: audit failure is surfaced ───────────────────────────────

  defmodule FailingAuditWriter do
    def log(_actor, _action, _target_type, _target_id, _metadata, _outcome, _detail \\ nil),
      do: {:error, :audit_write_failed}
  end

  defmodule RaisingAuditWriter do
    def log(_actor, _action, _target_type, _target_id, _metadata, _outcome, _detail \\ nil),
      do: raise(RuntimeError, "audit repo down")
  end

  describe "decision flash (code-review 6, UX A7)" do
    test "success flash names the client", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call()
      assert flash_of(conn)["info"] == ~s(Client "#{c.name}" approved.)
      refute flash_of(conn)["error"]

      r = insert_client(ids, "pending")
      conn = admin_conn(:post, "#{@list_path}/#{r.id}/reject") |> call()
      assert flash_of(conn)["info"] == ~s(Client "#{r.name}" rejected.)
    end

    # security review F-6: decision and audit row are ONE transaction — a failed audit write rolls
    # the decision back, so a decision is never unaudited.
    for {label, writer} <- [failing: FailingAuditWriter, raising: RaisingAuditWriter] do
      test "a #{label} audit write ROLLS THE DECISION BACK and tells the admin (error flash, error log)", %{ids: ids} do
        Application.put_env(:compliance, :audit_writer, unquote(writer))
        c = insert_client(ids, "pending")

        {conn, log} =
          with_log(fn -> fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call() end)

        assert conn.status in [302, 303]
        assert get_resp_header(conn, "location") == [@list_path]

        row = T.client_row(c.id)
        assert row["status"] == "pending", "an unaudited decision must not stand"
        assert row["approved_by"] == nil and row["approved_at"] == nil

        flash = flash_of(conn)
        refute flash["info"], "never a plain success message when the audit entry is missing"
        assert flash["error"] =~ "not saved"
        assert flash["error"] =~ "audit"
        assert flash["error"] =~ "still pending"
        assert log =~ "audit entry for client approved"
        assert log =~ "decision rolled back"
        assert log =~ c.id
        refute log =~ c.name, "client metadata is never logged"
      end
    end

    test "a failing audit write on reject rolls the rejection back the same way", %{ids: ids} do
      Application.put_env(:compliance, :audit_writer, FailingAuditWriter)
      c = insert_client(ids, "pending")

      {conn, _log} =
        with_log(fn -> admin_conn(:post, "#{@list_path}/#{c.id}/reject", %{"reason" => "nope"}) |> call() end)

      assert T.client_row(c.id)["status"] == "pending"
      assert T.client_row(c.id)["rejected_by"] == nil
      assert flash_of(conn)["error"] =~ "not saved"
    end

    test "after a rolled-back decision the admin can decide again once the audit writer works", %{ids: ids} do
      Application.put_env(:compliance, :audit_writer, FailingAuditWriter)
      c = insert_client(ids, "pending")
      {_conn, _log} = with_log(fn -> fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call() end)
      assert T.client_row(c.id)["status"] == "pending"

      Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)
      conn = fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call()
      assert flash_of(conn)["info"] =~ "approved"
      assert T.client_row(c.id)["status"] == "approved"
      assert [_one] = audit_rows("oauth_client_approved", c.id)
    end

    test "an audit step that ABORTS the database transaction (failed INSERT) also rolls the decision back", %{ids: ids} do
      # A failed audit INSERT leaves PostgreSQL's transaction in the aborted state; the decision
      # must be undone and the connection must stay usable. Exercised at the facade level.
      c = insert_client(ids, "pending")

      failing = fn ->
        # a statement that aborts the transaction, like a failed audit INSERT would
        case Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT 1/0", []) do
          {:error, e} -> {:error, e}
          _ -> :ok
        end
      end

      assert {:error, {:audit, _}} = Nebu.OAuth.approve_registration(c.id, @admin, audit: failing)
      assert T.client_row(c.id)["status"] == "pending"
      # the connection is usable again afterwards
      assert :ok = Nebu.OAuth.approve_registration(c.id, @admin)
      assert T.client_row(c.id)["status"] == "approved"
    end
  end

  # ── security review F-6: reject reason sanitising ──────────────────────────

  describe "F-6 — reject reason" do
    test "control and format characters (NUL, bidi override, zero-width, newline) are stripped; the rejection is audited",
         %{ids: ids} do
      c = insert_client(ids, "pending")
      reason = "bad\u0000 ven\u202Edor\u200B\nlist\u0007ed"

      conn = admin_conn(:post, "#{@list_path}/#{c.id}/reject", %{"reason" => reason}) |> call()

      assert flash_of(conn)["info"] =~ "rejected"
      assert T.client_row(c.id)["status"] == "rejected"

      assert [[_, "oauth_client_rejected", _, _, %{"reason" => "bad vendorlisted"}, "success"]] =
               audit_rows("oauth_client_rejected", c.id)
    end

    test "a reason made only of control characters counts as no reason", %{ids: ids} do
      c = insert_client(ids, "pending")
      admin_conn(:post, "#{@list_path}/#{c.id}/reject", %{"reason" => "\u0000\u202E \n"}) |> call()

      assert [[_, _, _, _, metadata, "success"]] = audit_rows("oauth_client_rejected", c.id)
      refute Map.has_key?(metadata, "reason")
    end

    test "a percent-encoded NUL posted as form data never leaves a rejection without an audit row", %{ids: ids} do
      c = insert_client(ids, "pending")

      conn =
        %{conn(:post, "#{@list_path}/#{c.id}/reject", "reason=abc%00def") | secret_key_base: @secret_key_base}
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Nebu.Admin.Endpoint.admin_session([])
        |> fetch_session()
        |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => @admin})
        |> T.put_strict_fetch_headers()
        |> call()

      assert conn.status in [302, 303]
      assert T.client_row(c.id)["status"] == "rejected"
      assert [[_, _, _, _, %{"reason" => "abcdef"}, "success"]] = audit_rows("oauth_client_rejected", c.id)
    end
  end

  # ── security review F-7: retention of the first registrant's IP / user agent ─

  describe "F-7 — created_from_ip / user_agent are erased on a decision" do
    test "both are present while pending and NULL after approve", %{ids: ids} do
      c = insert_client(ids, "pending")
      pending = T.client_row(c.id)
      assert pending["created_from_ip"] == "203.0.113.7"
      assert pending["user_agent"] == "TestAgent/1.0"

      fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call()
      row = T.client_row(c.id)
      assert row["status"] == "approved"
      assert row["created_from_ip"] == nil
      assert row["user_agent"] == nil
    end

    test "both are NULL after reject", %{ids: ids} do
      c = insert_client(ids, "pending")
      admin_conn(:post, "#{@list_path}/#{c.id}/reject") |> call()
      row = T.client_row(c.id)
      assert row["status"] == "rejected"
      assert row["created_from_ip"] == nil
      assert row["user_agent"] == nil
    end

    test "a rolled-back decision keeps them (nothing changed)", %{ids: ids} do
      Application.put_env(:compliance, :audit_writer, FailingAuditWriter)
      c = insert_client(ids, "pending")
      {_conn, _log} = with_log(fn -> fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call() end)
      assert T.client_row(c.id)["created_from_ip"] == "203.0.113.7"
    end
  end

  # ── AC4: approve ───────────────────────────────────────────────────────────

  describe "AC4 — approve" do
    test "POST approve => status approved, approved_by = admin user id, approved_at set, redirect to list",
         %{ids: ids} do
      c = insert_client(ids, "pending")

      conn = fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call()
      assert conn.status in [302, 303]
      assert get_resp_header(conn, "location") == [@list_path]

      row = T.client_row(c.id)
      assert row["status"] == "approved"
      assert row["approved_by"] == @admin
      assert row["approved_at"] != nil
      assert row["rejected_by"] == nil and row["rejected_at"] == nil
    end

    test "approved client no longer appears in the pending list", %{ids: ids} do
      c = insert_client(ids, "pending")
      fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call()

      conn = admin_conn(:get, @list_path) |> call()
      refute conn.resp_body =~ ~s(data-client-id="#{c.id}")
    end

    test "approval writes an audit entry (admin id, action, target) WITHOUT the client metadata",
         %{ids: ids} do
      c = insert_client(ids, "pending")
      fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call()

      assert [[actor, action, target_type, target_id, metadata, outcome]] =
               audit_rows("oauth_client_approved", c.id)

      assert actor == @admin
      assert action == "oauth_client_approved"
      assert target_type == "oauth_client"
      assert target_id == c.id
      assert outcome == "success"
      # story oauth-client-revocation CR9: the approve audit metadata gains how the fresh login was proven
      assert metadata == %{"reauth" => "auth_time"}

      serialized = Jason.encode!(metadata)
      refute serialized =~ c.name, "audit row must not contain the full client metadata"
      refute serialized =~ "redirect_uris"
      refute serialized =~ c.metadata["client_uri"]
    end

    test "approving an already-decided client does not change it (WHERE status = 'pending' race guard)",
         %{ids: ids} do
      rejected = insert_client(ids, "rejected")
      conn = fresh_admin_conn(:post, "#{@list_path}/#{rejected.id}/approve") |> call()
      assert conn.status < 500
      row = T.client_row(rejected.id)
      assert row["status"] == "rejected"
      assert row["approved_by"] == nil

      approved = insert_client(ids, "pending")
      fresh_admin_conn(:post, "#{@list_path}/#{approved.id}/approve") |> call()
      first = T.client_row(approved.id)

      other_admin =
        %{conn(:post, "#{@list_path}/#{approved.id}/approve") | secret_key_base: @secret_key_base}
        |> Nebu.Admin.Endpoint.admin_session([])
        |> fetch_session()
        |> put_session("current_user", %{"admin" => true, "sub" => "admin-2", "matrix_user_id" => "@admin2:test.local"})
        |> put_session("admin_reauth", T.fresh_marker("admin-2", 0, "auth_time", "#{@list_path}/#{approved.id}/approve"))
        |> T.put_strict_fetch_headers()
        |> call()

      assert other_admin.status < 500
      second = T.client_row(approved.id)
      assert second["approved_by"] == first["approved_by"], "a second approve must not overwrite the first decision"
      assert second["approved_at"] == first["approved_at"]
    end

    test "unknown client_id is refused cleanly (no 5xx, no audit entry) and leaves other registrations untouched",
         %{ids: ids} do
      bystander = insert_client(ids, "pending")
      unknown = "no-such-client-#{System.unique_integer([:positive])}"

      conn = fresh_admin_conn(:post, "#{@list_path}/#{unknown}/approve") |> call()
      assert conn.status < 500
      assert conn.status in [302, 303, 404], "got #{conn.status}"
      assert audit_rows("oauth_client_approved", unknown) == []
      assert T.client_row(unknown) == nil
      assert T.client_row(bystander.id)["status"] == "pending"
    end
  end

  # ── AC4: reject ────────────────────────────────────────────────────────────

  describe "AC4 — reject" do
    test "POST reject => status rejected, rejected_by/rejected_at set, row is NOT deleted", %{ids: ids} do
      c = insert_client(ids, "pending")

      conn = admin_conn(:post, "#{@list_path}/#{c.id}/reject") |> call()
      assert conn.status in [302, 303]
      assert get_resp_header(conn, "location") == [@list_path]

      row = T.client_row(c.id)
      assert row != nil, "rejecting must NOT delete the registration (spec: MUST NOT delete registrations)"
      assert row["status"] == "rejected"
      assert row["rejected_by"] == @admin
      assert row["rejected_at"] != nil
      assert row["approved_by"] == nil and row["approved_at"] == nil
      assert T.count_by_hash(row["metadata_hash"]) == 1
    end

    test "optional rejection reason is recorded in the audit entry (not the client metadata)", %{ids: ids} do
      c = insert_client(ids, "pending")

      admin_conn(:post, "#{@list_path}/#{c.id}/reject", %{"reason" => "Unknown vendor, not on allowlist"})
      |> call()

      assert [[actor, "oauth_client_rejected", "oauth_client", target_id, metadata, "success"]] =
               audit_rows("oauth_client_rejected", c.id)

      assert actor == @admin
      assert target_id == c.id
      serialized = Jason.encode!(metadata)
      assert serialized =~ "Unknown vendor, not on allowlist"
      refute serialized =~ c.name
      refute serialized =~ "redirect_uris"
    end

    test "reject without a reason works and still audits", %{ids: ids} do
      c = insert_client(ids, "pending")
      conn = admin_conn(:post, "#{@list_path}/#{c.id}/reject") |> call()
      assert conn.status in [302, 303]
      assert [[_, "oauth_client_rejected", _, _, _, "success"]] = audit_rows("oauth_client_rejected", c.id)
    end

    test "rejected client no longer appears in the pending list", %{ids: ids} do
      c = insert_client(ids, "pending")
      admin_conn(:post, "#{@list_path}/#{c.id}/reject") |> call()

      conn = admin_conn(:get, @list_path) |> call()
      refute conn.resp_body =~ ~s(data-client-id="#{c.id}")
    end

    test "rejecting an already-approved client does not change it (race guard)", %{ids: ids} do
      c = insert_client(ids, "approved")
      conn = admin_conn(:post, "#{@list_path}/#{c.id}/reject") |> call()
      assert conn.status < 500
      row = T.client_row(c.id)
      assert row["status"] == "approved"
      assert row["rejected_by"] == nil
    end
  end

  # ── AC4: authorization ─────────────────────────────────────────────────────

  describe "AC4 — only admins may list/approve/reject" do
    test "anonymous GET is redirected to /admin/login" do
      conn = anon_conn(:get, @list_path) |> call()
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/login"]
    end

    test "non-admin session GET is denied (403 or redirect to login)" do
      conn = non_admin_conn(:get, @list_path) |> call()
      assert conn.status in [302, 403]
      if conn.status == 302, do: assert(get_resp_header(conn, "location") == ["/admin/login"])
    end

    test "anonymous and non-admin POST approve/reject change nothing", %{ids: ids} do
      c = insert_client(ids, "pending")

      for action <- ~w(approve reject) do
        for build <- [&anon_conn/2, &non_admin_conn/2] do
          conn = build.(:post, "#{@list_path}/#{c.id}/#{action}") |> call()
          assert conn.status in [302, 403]
        end
      end

      row = T.client_row(c.id)
      assert row["status"] == "pending"
      assert row["approved_by"] == nil and row["rejected_by"] == nil
    end

    test "state-changing POST without a CSRF token is refused (CSRF protection on, no bypass)", %{ids: ids} do
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      c = insert_client(ids, "pending")

      status =
        try do
          fresh_admin_conn(:post, "#{@list_path}/#{c.id}/approve") |> call() |> Map.fetch!(:status)
        rescue
          e in Plug.CSRFProtection.InvalidCSRFTokenError -> Plug.Exception.status(e)
        end

      assert status == 403
      assert T.client_row(c.id)["status"] == "pending"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story oauth-dcr-abuse-hardening (phase 2, P2): AC7 badges + AC9 bulk removal UI
  # ════════════════════════════════════════════════════════════════════════════
  #
  # ATDD decisions (markup the story leaves open, pinned here so dev and the e2e steps agree):
  #   * the preview page lists its rows in a table without a dedicated data-role (rows are counted as
  #     `tbody tr`); the criteria are echoed in words (host / "older than N days");
  #   * the POST carries the criteria as the same `host` / `match` / `older_than_days` params as the GET
  #     plus `as_of` (ISO 8601 UTC) and `_csrf_token`;
  #   * invalid criteria answer 200 or 422 (the preview page re-rendered);
  #   * flash texts are exactly the story's (AC9.4).

  @bulk_path "/admin/oauth/registrations/bulk-remove"

  defp doc(conn), do: Floki.parse_document!(conn.resp_body)
  defp text(nodes), do: nodes |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  defp rand_domain, do: "t#{T.rand(5)}.com"

  # n pending rows of one registrable domain (host app<i>.<domain>) with the stored host/domain columns
  defp domain_clients(ids, domain, n, status \\ "pending") do
    for i <- 1..n do
      host = "app#{i}.#{domain}"

      insert_client(ids, status, %{
        client_uri: "https://" <> host,
        redirect_uris: ["https://" <> host <> "/cb"],
        client_host: host,
        client_domain: domain
      })
    end
  end

  # n pending rows via one statement (client ids registered for cleanup); g = 1 is the newest row
  defp seed_many!(ids, domain, n) do
    tag = T.rand(5)

    T.sql!(
      "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type, client_host, client_domain, created_at) " <>
        "SELECT 'atdd-adminbulk-' || $1::text || '-' || g, '{}'::jsonb, 'atdd-adminbulk-h-' || $1::text || '-' || g, 'web', $2, $3, now() - (g * interval '1 second') " <>
        "FROM generate_series(1, $4::int) g",
      [tag, "app." <> domain, domain, n]
    )

    all = for g <- 1..n, do: "atdd-adminbulk-#{tag}-#{g}"
    Agent.update(ids, &(all ++ &1))
    all
  end

  defp exists?(id), do: T.client_row(id) != nil
  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp bulk_audit_rows(client_id) do
    %{rows: rows} =
      T.sql!(
        "SELECT actor_user_id, target_type, target_id, metadata, outcome FROM audit_log " <>
          "WHERE action = 'oauth_clients_bulk_removed' AND metadata->'client_ids' @> jsonb_build_array($1::text)",
        [client_id]
      )

    rows
  end

  defp bulk_audit_total do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM audit_log WHERE action = 'oauth_clients_bulk_removed'")
    n
  end

  defp anon_conn(method, path, params) do
    %{conn(method, path, params) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
  end

  defp non_admin_conn(method, path, params) do
    method
    |> anon_conn(path, params)
    |> put_session("current_user", %{"admin" => false, "sub" => "user-1", "matrix_user_id" => "@alex:test.local"})
  end

  defp post_bulk(params, build \\ &admin_conn/3) do
    build.(:post, @bulk_path, params) |> call()
  end

  defp criteria(domain, extra \\ %{}), do: Map.merge(%{"host" => domain, "match" => "domain", "as_of" => now_iso()}, extra)

  # ── AC7: warning badges on the approval page ───────────────────────────────

  describe "AC7 — approval page badges (shared hosting, public suffix, registrable domain)" do
    test "a host below a private suffix gets the shared-hosting warning with the exact text; client-domain shows the registrable domain",
         %{ids: ids} do
      name = "n#{T.rand(5)}"
      host = "app.#{name}.github.io"

      c =
        insert_client(ids, "pending", %{
          client_uri: "https://" <> host,
          redirect_uris: ["https://" <> host <> "/cb"],
          client_host: host,
          client_domain: "#{name}.github.io"
        })

      conn = admin_conn(:get, @list_path) |> call()
      row = row_html(conn.resp_body, c.id)

      assert [badge] = Floki.find(Floki.parse_fragment!(row), ~s([data-role="shared-hosting-warning"]))
      assert text([badge]) == "shared hosting domain (github.io): anyone can create sites here"
      assert (Floki.attribute(badge, "class") |> List.first()) =~ "badge-warning"
      refute row =~ ~s(data-role="public-suffix-error")

      assert [domain_node] = Floki.find(Floki.parse_fragment!(row), ~s([data-role="client-domain"]))
      assert text([domain_node]) =~ "#{name}.github.io", "the registrable domain is shown when it differs from the host"
    end

    test "a legacy pending row whose host IS a public suffix gets the error badge", %{ids: ids} do
      c =
        insert_client(ids, "pending", %{
          client_uri: "https://github.io",
          redirect_uris: ["https://github.io/cb"],
          client_host: "github.io"
        })

      row = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body) |> row_html(c.id)

      assert [badge] = Floki.find(Floki.parse_fragment!(row), ~s([data-role="public-suffix-error"]))
      assert text([badge]) == "client URI host is a public suffix"
      assert (Floki.attribute(badge, "class") |> List.first()) =~ "badge-error"
    end

    test "an ordinary domain has no badge; client-domain is only rendered when it differs from the host", %{ids: ids} do
      d = rand_domain()
      sub = insert_client(ids, "pending", %{client_uri: "https://app.#{d}", client_host: "app.#{d}", client_domain: d})
      apex = insert_client(ids, "pending", %{client_uri: "https://#{d}", redirect_uris: ["https://#{d}/cb"], client_host: d, client_domain: d})
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)

      for c <- [sub, apex] do
        row = row_html(body, c.id)
        refute row =~ ~s(data-role="shared-hosting-warning")
        refute row =~ ~s(data-role="public-suffix-error")
      end

      assert row_html(body, sub.id) =~ ~r/data-role="client-domain"[^>]*>\s*#{Regex.escape(d)}/s
      refute row_html(body, apex.id) =~ ~s(data-role="client-domain"), "host == registrable domain: nothing to add"
    end

    test "badges are derived from the client URI host at render time (rows without stored columns still get them)", %{ids: ids} do
      c = insert_client(ids, "pending", %{client_uri: "https://x#{T.rand(4)}.herokuapp.com", redirect_uris: ["https://x.herokuapp.com/cb"]})
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)
      assert row_html(body, c.id) =~ ~s(data-role="shared-hosting-warning")
      assert row_html(body, c.id) =~ "herokuapp.com"
    end

    test "the badge text is HEEx-escaped (client-controlled host text)", %{ids: ids} do
      c = insert_client(ids, "pending", %{client_uri: "https://evil<b>.github.io", redirect_uris: ["https://x.example.com/cb"]})
      body = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body)
      row = row_html(body, c.id)
      refute row =~ "<b>.github.io"
      assert row =~ "evil&lt;b&gt;", "the client-controlled host text is rendered escaped, not dropped"
    end

    test "each row with a host has the bulk-remove-domain link to the preview (encoded query, aria-label names the domain)", %{ids: ids} do
      d = rand_domain()
      [c | _] = domain_clients(ids, d, 1)
      row = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body) |> row_html(c.id)

      [link] = Floki.find(Floki.parse_fragment!(row), ~s(a[data-role="bulk-remove-domain"]))
      href = link |> Floki.attribute("href") |> List.first() |> String.replace("&amp;", "&")
      assert href == "#{@bulk_path}?" <> URI.encode_query([{"host", d}, {"match", "domain"}])
      assert Floki.attribute(link, "aria-label") == ["Remove all pending registrations of #{d}"]
    end

    test "a row without any host gets no bulk-remove link", %{ids: ids} do
      c = insert_client(ids, "pending", %{client_uri: "not a uri at all"})
      row = admin_conn(:get, @list_path) |> call() |> Map.fetch!(:resp_body) |> row_html(c.id)
      refute row =~ ~s(data-role="bulk-remove-domain")
    end

    test "static: the HTML module reaches the suffix logic only through the Nebu.OAuth facade (ADR-020)" do
      for f <- ["oauth_registrations_html.ex", "oauth_registrations_controller.ex"] do
        src = File.read!(Path.expand("../../../lib/nebu/admin/#{f}", __DIR__))
        refute src =~ "Nebu.OAuth.PublicSuffix", "#{f} must not call Nebu.OAuth.PublicSuffix directly"
      end

      html = File.read!(Path.expand("../../../lib/nebu/admin/oauth_registrations_html.ex", __DIR__))
      assert html =~ "Nebu.OAuth.host_info", "the HTML module uses Nebu.OAuth.host_info/1"
      assert Code.ensure_loaded?(Nebu.OAuth) and function_exported?(Nebu.OAuth, :host_info, 1)
    end
  end

  # ── AC9.1: the form on the list page ───────────────────────────────────────

  describe "AC9.1 — bulk-remove form on the list page" do
    test "labelled host input, match radios in a fieldset with legend (default domain), number input with help text", %{ids: ids} do
      insert_client(ids, "pending")
      d = admin_conn(:get, @list_path) |> call() |> doc()

      assert [form] = Floki.find(d, ~s(form[data-form="bulk-remove"]))
      assert Floki.attribute(form, "method") |> List.first() |> String.downcase() == "get"
      assert Floki.attribute(form, "action") == [@bulk_path]

      # host: <label for> + described by help text
      assert [host] = Floki.find(form, ~s(input[name="host"]))
      host_id = host |> Floki.attribute("id") |> List.first()
      assert host_id
      assert [_] = Floki.find(form, ~s(label[for="#{host_id}"]))
      assert [desc_id] = host |> Floki.attribute("aria-describedby") |> List.first() |> String.split()
      assert [_] = Floki.find(form, "##{desc_id}")

      # match: radio group in fieldset + legend, default domain
      assert [fieldset] = Floki.find(form, "fieldset")
      assert [_] = Floki.find(fieldset, "legend")
      radios = Floki.find(fieldset, ~s(input[type="radio"][name="match"]))
      assert radios |> Enum.map(&(Floki.attribute(&1, "value") |> List.first())) |> Enum.sort() == ["domain", "exact"]
      checked = Enum.filter(radios, &(Floki.attribute(&1, "checked") != []))
      assert [domain_radio] = checked
      assert Floki.attribute(domain_radio, "value") == ["domain"]
      for r <- radios do
        rid = r |> Floki.attribute("id") |> List.first()
        assert rid, "every radio has an id"
        assert [_] = Floki.find(form, ~s(label[for="#{rid}"])), "every radio has a label"
      end

      # older_than_days
      assert [days] = Floki.find(form, ~s(input[name="older_than_days"]))
      assert Floki.attribute(days, "type") == ["number"]
      assert Floki.attribute(days, "min") == ["1"]
      assert Floki.attribute(days, "max") == ["3650"]
      days_id = days |> Floki.attribute("id") |> List.first()
      assert [_] = Floki.find(form, ~s(label[for="#{days_id}"]))
      assert Floki.attribute(days, "aria-describedby") != []
    end

    test "the form is a GET (preview first): it carries no as_of", %{ids: ids} do
      insert_client(ids, "pending")
      [form] = admin_conn(:get, @list_path) |> call() |> doc() |> Floki.find(~s(form[data-form="bulk-remove"]))
      assert Floki.find(form, ~s(input[name="as_of"])) == []
    end
  end

  # ── AC9.2: the preview ─────────────────────────────────────────────────────

  describe "AC9.2 — preview page" do
    test "heading, status summary with count, table of rows, criteria in words, the 500 note, confirm form", %{ids: ids} do
      d = rand_domain()
      domain_clients(ids, d, 3)
      domain_clients(ids, d, 1, "approved")
      other = domain_clients(ids, "o" <> d, 1)

      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain")) |> call()
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
      d_ = doc(conn)

      assert [h1] = Floki.find(d_, "h1")
      assert text([h1]) == "Remove pending registrations"

      assert [summary] = Floki.find(d_, ~s([data-role="bulk-match-count"]))
      assert Floki.attribute(summary, "role") == ["status"]
      assert Floki.attribute(summary, "data-count") == ["3"], "only the 3 PENDING rows of the domain are counted"
      assert text([summary]) =~ "3 pending registrations match"

      assert [table] = Floki.find(d_, "table")
      assert [_] = Floki.find(table, "caption")
      assert Floki.find(table, "th[scope]") != []
      assert length(Floki.find(table, "tbody tr")) == 3
      refute conn.resp_body =~ hd(other).id

      body_text = text(d_)
      assert body_text =~ d, "criteria are echoed in words"
      assert body_text =~
               "At most 500 are removed per run. Removed registrations are deleted; a legitimate client that registers again appears as a new pending registration."

      assert [form] = Floki.find(d_, ~s(form[data-form="bulk-remove-confirm"]))
      assert Floki.attribute(form, "method") |> List.first() |> String.downcase() == "post"
      assert Floki.attribute(form, "action") == [@bulk_path]
      hidden = form |> Floki.find(~s(input[type="hidden"])) |> Map.new(fn i -> {hd(Floki.attribute(i, "name")), List.first(Floki.attribute(i, "value"))} end)
      assert hidden["host"] == d and hidden["match"] == "domain"
      assert Map.has_key?(hidden, "_csrf_token") and hidden["_csrf_token"] != ""
      assert {:ok, as_of, _} = DateTime.from_iso8601(hidden["as_of"])
      assert abs(DateTime.diff(DateTime.utc_now(), as_of)) < 30, "as_of is the server UTC time of the preview"

      confirm = form |> Floki.attribute("data-confirm") |> List.first()
      assert confirm =~ ~r/\ARemove 3 pending registrations matching .+\? This cannot be undone\.\z/
      assert confirm =~ d
      assert [btn] = Floki.find(form, ~s(button[data-role="bulk-remove-confirm"]))
      assert List.first(Floki.attribute(btn, "type")) in [nil, "submit"]
    end

    test "older_than_days is part of the criteria, the words and the hidden fields", %{ids: ids} do
      d = rand_domain()
      [old1, old2, fresh] = domain_clients(ids, d, 3)
      T.sql!("UPDATE oauth_clients SET created_at = now() - interval '40 days' WHERE client_id = ANY($1)", [[old1.id, old2.id]])

      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain", older_than_days: "30")) |> call()
      d_ = doc(conn)

      assert Floki.attribute(Floki.find(d_, ~s([data-role="bulk-match-count"])), "data-count") == ["2"], "the fresh row is not older than 30 days"
      assert text(d_) =~ "30 days", "criteria in words"
      assert [form] = Floki.find(d_, ~s(form[data-form="bulk-remove-confirm"]))
      assert Floki.attribute(Floki.find(form, ~s(input[name="older_than_days"])), "value") == ["30"]
      _ = fresh
    end

    test "a preview that matches nothing (fresh rows vs older_than_days): no confirm form", %{ids: ids} do
      d = rand_domain()
      domain_clients(ids, d, 1)
      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain", older_than_days: "30")) |> call()
      d_ = doc(conn)
      assert [_] = Floki.find(d_, ~s([data-role="bulk-no-match"]))
      assert Floki.find(d_, ~s(form[data-form="bulk-remove-confirm"])) == []
    end

    test "zero matches: bulk-no-match is shown and there is NO confirm form", %{} do
      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: rand_domain(), match: "domain")) |> call()
      assert conn.status == 200
      d_ = doc(conn)
      assert [_] = Floki.find(d_, ~s([data-role="bulk-no-match"]))
      assert Floki.find(d_, ~s(form[data-form="bulk-remove-confirm"])) == []
      assert Floki.attribute(Floki.find(d_, ~s([data-role="bulk-match-count"])), "data-count") in [[], ["0"]]
    end

    test "at most 20 rows are listed, the count is the real total", %{ids: ids} do
      d = rand_domain()
      seed_many!(ids, d, 25)
      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain")) |> call()
      d_ = doc(conn)
      assert Floki.attribute(Floki.find(d_, ~s([data-role="bulk-match-count"])), "data-count") == ["25"]
      assert length(Floki.find(d_, "table tbody tr")) == 20
    end

    test "the preview is read only (nothing deleted, no audit row)", %{ids: ids} do
      d = rand_domain()
      rows = domain_clients(ids, d, 2)
      before = bulk_audit_total()
      admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain")) |> call()
      for r <- rows, do: assert(exists?(r.id))
      assert bulk_audit_total() == before
    end

    test "client-controlled text on the preview is HEEx-escaped", %{ids: ids} do
      d = rand_domain()
      c = insert_client(ids, "pending", %{name: "<script>alert(1)</script>", client_uri: "https://app.#{d}", client_host: "app.#{d}", client_domain: d})
      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain")) |> call()
      refute conn.resp_body =~ "<script>alert(1)</script>"
      assert conn.resp_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;", "the name is rendered escaped, not dropped"
      _ = c
    end
  end

  # ── AC9.3: invalid criteria ────────────────────────────────────────────────

  describe "AC9.3 — invalid criteria re-render the preview with an accessible error; no write" do
    for {label, query} <- [
          {"no criterion at all", [host: "", match: "domain"]},
          {"a bad host", [host: "a b", match: "exact", older_than_days: "0"]},
          {"days out of range", [host: "example.com", match: "exact", older_than_days: "3651"]},
          {"days not a number", [host: "example.com", match: "exact", older_than_days: "x"]},
          {"domain match on a public suffix", [host: "github.io", match: "domain"]}
        ] do
      test "#{label}" do
        conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(unquote(query))) |> call()
        assert conn.status in [200, 422]
        d_ = doc(conn)

        assert [alert] = Floki.find(d_, ~s([role="alert"]))
        assert text([alert]) != ""
        assert Floki.find(d_, ~s(form[data-form="bulk-remove-confirm"])) == []

        invalid = Floki.find(d_, ~s([aria-invalid="true"]))
        assert invalid != [], "the offending input is marked aria-invalid"
        alert_id = alert |> Floki.attribute("id") |> List.first()

        assert Enum.any?(invalid, fn i -> alert_id && alert_id in String.split(List.first(Floki.attribute(i, "aria-describedby")) || "") end),
               "the invalid input is described by the error"
      end
    end

    test "the inputs are preserved" do
      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: "a b", match: "exact", older_than_days: "0")) |> call()
      d_ = doc(conn)
      assert Floki.attribute(Floki.find(d_, ~s(input[name="host"])), "value") == ["a b"]
      assert Floki.attribute(Floki.find(d_, ~s(input[name="older_than_days"])), "value") == ["0"]
      assert [exact] = Floki.find(d_, ~s(input[type="radio"][name="match"][value="exact"]))
      assert Floki.attribute(exact, "checked") != []
    end

    test "an invalid POST writes nothing and audits nothing", %{ids: ids} do
      d = rand_domain()
      rows = domain_clients(ids, d, 2)
      before = bulk_audit_total()
      conn = post_bulk(%{"host" => "", "match" => "domain", "as_of" => now_iso()})
      assert conn.status in [200, 302, 303, 422]
      for r <- rows, do: assert(exists?(r.id))
      assert bulk_audit_total() == before
      _ = d
    end
  end

  # ── AC9.4: the POST ────────────────────────────────────────────────────────

  describe "AC9.4 — POST removes the snapshot rows, Post-Redirect-Get with a flash" do
    test "success: redirect to the list, flash 'N pending registrations removed.', rows gone, decided rows kept", %{ids: ids} do
      d = rand_domain()
      pending = domain_clients(ids, d, 3)
      [approved] = domain_clients(ids, "a" <> d, 1, "approved")
      other = domain_clients(ids, "o" <> d, 1)

      conn = post_bulk(criteria(d))
      assert conn.status in [302, 303]
      assert get_resp_header(conn, "location") == [@list_path]
      assert flash_of(conn)["info"] == "3 pending registrations removed."
      refute flash_of(conn)["error"]

      for c <- pending, do: refute(exists?(c.id))
      assert exists?(approved.id)
      assert exists?(hd(other).id)
    end

    test "more than 500 matches: 500 removed and the flash says how many still match", %{ids: ids} do
      d = rand_domain()
      seed_many!(ids, d, 501)
      conn = post_bulk(criteria(d))
      assert flash_of(conn)["info"] == "500 removed, 1 still match. Run the removal again."
      assert T.sql!("SELECT count(*) FROM oauth_clients WHERE client_domain = $1", [d]).rows == [[1]]
    end

    test "zero matches: info flash, nothing deleted, NO audit row", %{} do
      before = bulk_audit_total()
      conn = post_bulk(criteria(rand_domain()))
      assert conn.status in [302, 303]
      assert flash_of(conn)["info"] == "No pending registration matched; nothing was removed."
      assert bulk_audit_total() == before
    end

    test "a registration made AFTER the preview snapshot is never swept", %{ids: ids} do
      d = rand_domain()
      pending = domain_clients(ids, d, 2)
      snapshot = DateTime.utc_now() |> DateTime.add(-2, :second) |> DateTime.to_iso8601()
      late = domain_clients(ids, d, 1)

      T.sql!("UPDATE oauth_clients SET created_at = now() + interval '1 second' WHERE client_id = $1", [hd(late).id])
      T.sql!("UPDATE oauth_clients SET created_at = now() - interval '10 seconds' WHERE client_id = ANY($1)", [Enum.map(pending, & &1.id)])

      conn = post_bulk(%{"host" => d, "match" => "domain", "as_of" => snapshot})
      assert flash_of(conn)["info"] =~ "2 pending registrations removed"
      assert exists?(hd(late).id)
    end

    defp as_of_params(:old), do: %{"as_of" => DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.to_iso8601()}
    defp as_of_params(:future), do: %{"as_of" => DateTime.utc_now() |> DateTime.add(2 * 3600, :second) |> DateTime.to_iso8601()}
    defp as_of_params(:garbage), do: %{"as_of" => "yesterday"}
    defp as_of_params(:missing), do: %{}

    for {label, kind} <- [{"older than one hour", :old}, {"in the future", :future}, {"not a timestamp", :garbage}, {"missing", :missing}] do
      test "an as_of that is #{label} => error flash (preview expired), nothing removed", %{ids: ids} do
        d = rand_domain()
        rows = domain_clients(ids, d, 2)
        params = Map.merge(%{"host" => d, "match" => "domain"}, as_of_params(unquote(kind)))

        before = bulk_audit_total()
        conn = post_bulk(params)
        assert conn.status in [302, 303]
        assert flash_of(conn)["error"], "an error flash is expected, got #{inspect(flash_of(conn))}"
        refute flash_of(conn)["info"]
        for r <- rows, do: assert(exists?(r.id))
        assert bulk_audit_total() == before
      end
    end

    test "the snapshot window is judged on the DATABASE clock (cycle 1, M2): 59 min old is accepted, 61 min and +5 s are expired", %{ids: ids} do
      d = rand_domain()
      rows = domain_clients(ids, d, 1)
      db_iso = fn offset_sql -> T.sql!("SELECT (now() + #{offset_sql})::timestamptz").rows |> hd() |> hd() |> DateTime.to_iso8601() end

      for sql <- ["interval '5 seconds'", "- interval '61 minutes'"] do
        conn = post_bulk(%{"host" => d, "match" => "domain", "as_of" => db_iso.(sql)})
        assert flash_of(conn)["error"] =~ ~r/preview expired/i, "#{sql} must be expired"
        for r <- rows, do: assert(exists?(r.id))
      end

      # the row must be older than the snapshot to be swept
      T.sql!("UPDATE oauth_clients SET created_at = now() - interval '2 hours' WHERE client_id = ANY($1)", [Enum.map(rows, & &1.id)])
      conn = post_bulk(%{"host" => d, "match" => "domain", "as_of" => db_iso.("- interval '59 minutes'")})
      assert flash_of(conn)["info"] == "1 pending registration removed.", "59 minutes old is still inside the window: #{inspect(flash_of(conn))}"
    end

    test "the preview snapshot is the database now(): a row created a moment earlier is always inside it, and the controller never reads the app clock for it", %{ids: ids} do
      d = rand_domain()
      [c] = domain_clients(ids, d, 1)
      conn = admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain")) |> call()
      [as_of_attr] = conn |> doc() |> Floki.find(~s(form[data-form="bulk-remove-confirm"] input[name="as_of"])) |> Floki.attribute("value")
      {:ok, as_of, _} = DateTime.from_iso8601(as_of_attr)
      assert DateTime.compare(as_of, T.client_row(c.id)["created_at"]) in [:gt, :eq]

      src = File.read!(Path.expand("../../../lib/nebu/admin/oauth_registrations_controller.ex", __DIR__))
      code = src |> String.replace(~r/@moduledoc """.*?"""/s, "") |> String.replace(~r/^\s*#.*$/m, "")
      refute code =~ "DateTime.utc_now", "the snapshot and its window come from the database clock"
    end

    test "the audit row records the EFFECTIVE registrable domain next to the host as typed (cycle 1, M3)", %{ids: ids} do
      d = rand_domain()
      [c | _] = domain_clients(ids, d, 2)
      conn = post_bulk(%{"host" => "Whatever.#{d}", "match" => "domain", "older_than_days" => "", "as_of" => now_iso()})
      assert flash_of(conn)["info"] == "2 pending registrations removed."
      assert [[_, _, _, metadata, _]] = bulk_audit_rows(c.id)
      assert metadata["criteria"]["host"] == "whatever.#{d}"
      assert metadata["criteria"]["domain"] == d, "the swept domain is recorded, not only the typed host"
      assert metadata["criteria"]["match"] == "domain"
    end

    test "the expired flash says so", %{ids: ids} do
      d = rand_domain()
      domain_clients(ids, d, 1)
      conn = post_bulk(criteria(d, %{"as_of" => DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.to_iso8601()}))
      assert flash_of(conn)["error"] =~ ~r/preview expired/i
    end

    test "exact match through the POST removes only the identical host", %{ids: ids} do
      d = rand_domain()
      [a, b] = domain_clients(ids, d, 2)
      conn = post_bulk(%{"host" => a.metadata["client_uri"] |> URI.parse() |> Map.fetch!(:host), "match" => "exact", "as_of" => now_iso()})
      assert flash_of(conn)["info"] == "1 pending registration removed."
      refute exists?(a.id)
      assert exists?(b.id)
    end
  end

  # ── AC9.5: CSRF and authorisation ──────────────────────────────────────────

  describe "AC9.5 — CSRF, admin only" do
    setup %{ids: ids} do
      d = rand_domain()
      {:ok, d: d, rows: domain_clients(ids, d, 2)}
    end

    for {label, token} <- [{"without a token", nil}, {"with a wrong token", "not-the-token"}] do
      test "a POST #{label} is refused (CSRF on, no bypass) and deletes nothing", %{d: d, rows: rows} do
        Application.delete_env(:nebu_http, :admin_csrf_bypass)
        before = bulk_audit_total()
        params = criteria(d) |> then(fn p -> if unquote(token), do: Map.put(p, "_csrf_token", unquote(token)), else: p end)

        status =
          try do
            post_bulk(params) |> Map.fetch!(:status)
          rescue
            e in Plug.CSRFProtection.InvalidCSRFTokenError -> Plug.Exception.status(e)
          end

        assert status == 403
        for r <- rows, do: assert(exists?(r.id))
        assert bulk_audit_total() == before
      end
    end

    test "positive control: with a VALID CSRF token the same POST succeeds while the bypass stays off", %{d: d, rows: rows} do
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      token = Plug.CSRFProtection.get_csrf_token()
      secret = Plug.CSRFProtection.dump_state()

      conn =
        admin_conn(:post, @bulk_path, criteria(d, %{"_csrf_token" => token}))
        |> put_session("_csrf_token", secret)
        |> call()

      assert conn.status in [302, 303], "a valid token must be accepted, got #{conn.status}"
      assert flash_of(conn)["info"] == "2 pending registrations removed."
      for r <- rows, do: refute(exists?(r.id))
    end

    test "anonymous and non-admin POST/GET change nothing and are redirected / denied", %{d: d, rows: rows} do
      before = bulk_audit_total()

      for build <- [&anon_conn/3, &non_admin_conn/3] do
        conn = post_bulk(criteria(d), build)
        assert conn.status in [302, 403]
        if conn.status == 302, do: assert(get_resp_header(conn, "location") == ["/admin/login"])
      end

      for build <- [&anon_conn/2, &non_admin_conn/2] do
        conn = build.(:get, @bulk_path <> "?" <> URI.encode_query(host: d, match: "domain")) |> call()
        assert conn.status in [302, 403]
        refute conn.resp_body =~ "Remove pending registrations"
      end

      for r <- rows, do: assert(exists?(r.id))
      assert bulk_audit_total() == before
    end
  end

  # ── AC9.6: audit ───────────────────────────────────────────────────────────

  defmodule RecordingAuditWriter do
    def log(actor, action, target_type, target_id, metadata, outcome, detail \\ nil) do
      send(self(), {:audit, actor, action, target_type, target_id, metadata, outcome, detail})
      :ok
    end
  end

  describe "AC9.6 — exactly ONE audit row per successful POST, in the same transaction" do
    test "the real audit_log row: action, target, criteria, as_of, removed, client_ids; no client metadata", %{ids: ids} do
      d = rand_domain()
      pending = domain_clients(ids, d, 3)
      as_of = now_iso()

      conn = post_bulk(%{"host" => d, "match" => "domain", "as_of" => as_of})
      assert flash_of(conn)["info"] == "3 pending registrations removed."

      for c <- pending do
        assert [[actor, target_type, target_id, metadata, outcome]] = bulk_audit_rows(c.id), "ONE shared audit row for the whole batch"
        assert actor == @admin
        assert target_type == "oauth_client"
        assert target_id == "bulk"
        assert outcome == "success"
        assert metadata["removed"] == 3
        assert Enum.sort(metadata["client_ids"]) == pending |> Enum.map(& &1.id) |> Enum.sort()
        assert metadata["criteria"]["host"] == d
        assert metadata["criteria"]["match"] == "domain"
        assert is_binary(metadata["as_of"]) and match?({:ok, _, _}, DateTime.from_iso8601(metadata["as_of"]))

        serialized = Jason.encode!(metadata)
        for p <- pending do
          refute serialized =~ p.name, "the audit row never carries client metadata"
          refute serialized =~ p.metadata["client_uri"]
        end
      end
    end

    test "the audit entry is written through the writer seam exactly once, with the documented action", %{ids: ids} do
      Application.put_env(:compliance, :audit_writer, RecordingAuditWriter)
      d = rand_domain()
      domain_clients(ids, d, 2)
      post_bulk(criteria(d))

      assert_received {:audit, @admin, "oauth_clients_bulk_removed", "oauth_client", "bulk", metadata, "success", _}
      assert metadata["removed"] == 2 or metadata[:removed] == 2
      refute_received {:audit, _, _, _, _, _, _, _}, "exactly one audit entry"
    end

    test "the action is registered in AuditWriter @known_actions (else every bulk action rolls back)" do
      src = File.read!(Path.expand("../../../lib/nebu/compliance/audit_writer.ex", __DIR__))
      assert src =~ "oauth_clients_bulk_removed"
    end

    for {label, writer} <- [failing: FailingAuditWriter, raising: RaisingAuditWriter] do
      test "a #{label} audit write rolls the removal back: error flash 'nothing was removed', rows present", %{ids: ids} do
        Application.put_env(:compliance, :audit_writer, unquote(writer))
        d = rand_domain()
        rows = domain_clients(ids, d, 2)

        {conn, log} = with_log(fn -> post_bulk(criteria(d)) end)

        assert conn.status in [302, 303]
        flash = flash_of(conn)
        refute flash["info"], "never a success message when the audit entry is missing"
        assert flash["error"] =~ "nothing was removed"
        for r <- rows, do: assert(exists?(r.id), "the removal must be rolled back")
        refute log =~ d, "the host/domain is never logged"
      end
    end
  end

  # ── AC9.7 + AC12: HTML only, logging ───────────────────────────────────────

  describe "AC9.7 — HTML only on the bulk routes; the list JSON is unchanged" do
    test "Accept: application/json on the preview is not served as JSON" do
      result =
        try do
          admin_conn(:get, @bulk_path <> "?" <> URI.encode_query(host: "example.com", match: "exact"))
          |> put_req_header("accept", "application/json")
          |> call()
        rescue
          e in Phoenix.NotAcceptableError -> e
        end

      case result do
        %Phoenix.NotAcceptableError{} -> :ok
        %Plug.Conn{} = conn -> assert conn.status == 406 or (get_resp_header(conn, "content-type") |> List.first() || "") =~ "text/html"
      end
    end

    test "the list JSON keeps its shape and carries no bulk fields", %{ids: ids} do
      insert_client(ids, "pending")
      conn = admin_conn(:get, @list_path) |> put_req_header("accept", "application/json") |> call()
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.keys(body) |> Enum.sort() == ~w(page page_size registrations total total_pages)
      refute conn.resp_body =~ "bulk"
    end
  end

  describe "AC12 — the bulk log line carries only the count and the admin id" do
    test "INFO line 'OAuth admin: bulk removal removed=<n> actor=<admin id>'; no host, domain, ids", %{ids: ids} do
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)

      d = rand_domain()
      rows = domain_clients(ids, d, 3)
      {_conn, log} = with_log([level: :info], fn -> post_bulk(criteria(d)) end)

      assert log =~ "OAuth admin: bulk removal removed=3 actor=#{@admin}"
      refute log =~ d
      for r <- rows, do: refute(log =~ r.id)
    end
  end
end
