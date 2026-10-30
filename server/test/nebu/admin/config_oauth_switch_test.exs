defmodule Nebu.Admin.ConfigOAuthSwitchTest do
  @moduledoc """
  Story `admin-oauth-switch`, AC1 - AC5, AC7, AC8 (decisions D1 - D9, D12): the section "OAuth 2.0 authorization server" of
  `/admin/config` and `POST /admin/config/oauth-switch` (`Nebu.Admin.ConfigController.save_oauth_switch/2`). No database: the
  config reader, the transaction function of `Nebu.OAuth.SwitchStore` and the audit writer are test seams.

  Seams pinned here (test builds only, compile-guarded like the other `:admin_config_*_writer` seams):

    * `:nebu_http, :admin_server_config_reader` — the `[{key, value}]` the page shows (existing).
    * `:nebu_http, :oauth_switch_tx` — 2-arity `fn changes, audit -> :ok | {:error, term()} end`, the database transaction of
      `Nebu.OAuth.SwitchStore` (the two upserts plus the audit function inside one transaction). `changes` is
      `%{"oauth_enabled" => "true" | "false", "oauth_issuer_url" => binary}`; `audit` is a 0-arity function (`:ok | {:error, r}`)
      or `nil` (the retry without audit of D7). The real transaction runs the audit function after the upserts and rolls back
      with `{:error, {:audit, reason}}` when it fails; the fake below does the same.
    * `:compliance, :audit_writer` — the existing audit writer seam.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-oauth-switch-bas", 3)
  @path "/admin/config"
  @post "/admin/config/oauth-switch"
  @issuer "https://chat.example.com"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      sink = Application.get_env(:nebu_http, :oauth_switch_audit_sink)
      send(sink, {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})

      case Application.get_env(:nebu_http, :oauth_switch_audit_result, :ok) do
        :ok -> :ok
        :raise -> raise "audit writer boom"
        other -> other
      end
    end
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    T.put_env_scoped(:oauth_switch_audit_sink, self())
    T.put_env_scoped(:oauth_switch_audit_result, :ok)
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)
    T.clear_oauth_config()

    # the fake transaction: records the changes, runs the audit function like the real one does (inside), and rolls back on its failure
    Application.put_env(:nebu_http, :oauth_switch_tx, fn changes, audit ->
      send(test_pid, {:tx, changes, audit != nil})

      case audit && audit.() do
        nil -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, {:audit, reason}}
      end
    end)

    # a stray write through any OTHER seam would be a bug: the form only writes the two oauth keys through the transaction
    for key <- [:admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_config_refresh_mode_writer, :admin_config_scopes_writer] do
      Application.put_env(:nebu_http, key, fn changes ->
        send(test_pid, {:stray_write, key, changes})
        :ok
      end)
    end

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_server_config_reader, :oauth_switch_tx, :admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_config_refresh_mode_writer, :admin_config_scopes_writer] do
        Application.delete_env(:nebu_http, k)
      end

      T.clear_oauth_config()
    end)

    :ok
  end

  defp stored(pairs), do: Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, pairs} end)
  defp stored_on, do: stored([{"oauth_enabled", "true"}, {"oauth_issuer_url", @issuer}])

  defp admin_conn(method, path, params \\ nil) do
    conn = %{conn(method, path) | secret_key_base: @secret_key_base}

    conn
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> then(fn c -> if params, do: c |> Map.put(:body_params, params) |> Map.put(:params, params), else: c end)
  end

  defp with_marker(conn, opts \\ []) do
    marker = T.fresh_marker(Keyword.get(opts, :sub, "admin-1"), Keyword.get(opts, :ago, 0), Keyword.get(opts, :kind, "auth_time"), Keyword.get(opts, :path, @path))
    put_session(conn, "admin_reauth", marker)
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))
  defp good_post(params), do: admin_conn(:post, @post, params) |> with_marker() |> T.put_strict_fetch_headers() |> call()

  defp on_params(issuer \\ @issuer, ack \\ "true"), do: %{"oauth_enabled" => "true", "oauth_issuer_url" => issuer, "oauth_activation_ack" => ack}
  defp off_params(issuer \\ @issuer), do: %{"oauth_enabled" => "false", "oauth_issuer_url" => issuer}

  defp flash(conn, key) do
    k = to_string(key)

    from_assigns =
      case conn.assigns[:flash] do
        m when is_map(m) -> m[k]
        _ -> nil
      end

    from_session =
      case conn.private[:plug_session] do
        %{"phoenix_flash" => m} when is_map(m) -> m[k]
        _ -> nil
      end

    from_assigns || get_in(conn.private, [:phoenix_flash, k]) || from_session
  end

  defp refute_nothing_written do
    refute_received {:tx, _, _}
    refute_received {:audit, _, _, _, _, _, _, _}
    refute_received {:stray_write, _, _}
  end

  defp page(pairs) do
    stored(pairs)
    conn = admin_conn(:get, @path) |> call()
    assert conn.status == 200
    {:ok, doc} = Floki.parse_document(conn.resp_body)
    {conn, doc}
  end

  defp text(node), do: node |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  # story admin-reauth-button-flow: the submit "Save OAuth settings" exists in the FRESH state only (stale: the link "Sign in again to save",
  # admin_reauth_button_flow_config_test.exs): this page carries a marker bound to /admin/config
  defp fresh_page(pairs) do
    stored(pairs)
    conn = admin_conn(:get, @path) |> with_marker() |> call()
    assert conn.status == 200
    {:ok, doc} = Floki.parse_document(conn.resp_body)
    {conn, doc}
  end

  # ─── AC1 — the page ────────────────────────────────────────────────────────

  describe "AC1 — the section and the form" do
    test "section #oauth-switch with the heading, the form and the contract of the fields" do
      {_conn, doc} = fresh_page([])

      assert [section] = Floki.find(doc, "section#oauth-switch")
      assert [heading] = Floki.find(section, "h2#oauth-switch-heading")
      assert text(heading) == "OAuth 2.0 authorization server"
      assert Floki.attribute(section, "aria-labelledby") == ["oauth-switch-heading"]

      assert [form] = Floki.find(doc, "form#oauth-switch-form")
      assert Floki.attribute(form, "method") == ["post"]
      assert Floki.attribute(form, "action") == ["/admin/config/oauth-switch"]
      assert [_] = Floki.find(form, ~s(input[type="hidden"][name="_csrf_token"]))
      assert [_] = Floki.find(form, ~s(input[type="hidden"][name="_click_proof"][value=""][data-click-proof]))
      assert [_] = Floki.find(form, ~s(input[type="hidden"][name="oauth_enabled"][value="false"]))
      assert [checkbox] = Floki.find(form, ~s(input[type="checkbox"][name="oauth_enabled"]))
      assert Floki.attribute(checkbox, "value") == ["true"]
      assert [issuer] = Floki.find(form, ~s(input[type="text"][name="oauth_issuer_url"]))
      assert Floki.attribute(issuer, "id") == ["oauth-issuer-input"]
      assert [ack] = Floki.find(form, ~s(input[type="checkbox"][name="oauth_activation_ack"]))
      assert Floki.attribute(ack, "value") == ["true"]
      assert [_] = Floki.find(form, ~s(button[type="submit"]))
    end

    test "the hidden false comes BEFORE the checkbox (the last value of a duplicated key wins in the form decoder)" do
      {_conn, doc} = page([])
      [form] = Floki.find(doc, "form#oauth-switch-form")
      assert [first, second] = Floki.find(form, ~s(input[name="oauth_enabled"]))
      assert Floki.attribute(first, "type") == ["hidden"]
      assert Floki.attribute(second, "type") == ["checkbox"]

      assert %{"oauth_enabled" => "true"} = Plug.Conn.Query.decode("oauth_enabled=false&oauth_enabled=true")
      assert %{"oauth_enabled" => "false"} = Plug.Conn.Query.decode("oauth_enabled=false")
    end

    test "every control has a label (for / id), the button is described by the fresh sign-in hint" do
      {_conn, doc} = fresh_page([])
      [form] = Floki.find(doc, "form#oauth-switch-form")

      for {id, label_text} <- [{"oauth-enabled-input", "Offer the OAuth 2.0 API"}, {"oauth-issuer-input", "Issuer URL"}, {"oauth-ack-input", "I have read the activation checklist"}] do
        assert [_] = Floki.find(form, ~s(##{id})), "control ##{id}"
        assert [label] = Floki.find(form, ~s(label[for="#{id}"])), "label for ##{id}"
        assert text(label) =~ label_text
      end

      [button] = Floki.find(form, "button[type=submit]")
      assert text(button) == "Save OAuth settings"
      assert [hint_id] = Floki.attribute(button, "aria-describedby")
      assert [hint] = Floki.find(form, "##{hint_id}")
      assert text(hint) =~ ~r/\bvalid\b/
    end

    test "the checkbox is checked iff the stored switch is exactly true; the issuer field shows the stored value" do
      {_c, doc_off} = page([{"oauth_enabled", "false"}, {"oauth_issuer_url", @issuer}])
      assert [] = Floki.find(doc_off, ~s(input[type="checkbox"][name="oauth_enabled"][checked]))
      assert Floki.attribute(Floki.find(doc_off, "input#oauth-issuer-input"), "value") == [@issuer]

      {_c, doc_on} = page([{"oauth_enabled", "true"}, {"oauth_issuer_url", @issuer}])
      assert [_] = Floki.find(doc_on, ~s(input[type="checkbox"][name="oauth_enabled"][checked]))

      {_c, doc_junk} = page([{"oauth_enabled", "TRUE"}])
      assert [] = Floki.find(doc_junk, ~s(input[type="checkbox"][name="oauth_enabled"][checked]))
    end

    test "the acknowledgement checkbox is never pre-ticked" do
      {_c, doc} = page([{"oauth_enabled", "true"}, {"oauth_issuer_url", @issuer}])
      assert [] = Floki.find(doc, ~s(input[name="oauth_activation_ack"][checked]))
    end

    test "nothing is stored: the issuer field suggests https://<server name> (and says so) when the session is secure and the name is not localhost" do
      T.put_env_scoped(:server_name, "chat.example.com")
      T.put_env_scoped(:admin_session_secure, true)
      {_c, doc} = page([])
      assert Floki.attribute(Floki.find(doc, "input#oauth-issuer-input"), "value") == ["https://chat.example.com"]
      assert text(hd(Floki.find(doc, "section#oauth-switch"))) =~ ~r/suggested, not saved yet/i
    end

    test "no suggestion for localhost, with an insecure admin session, or when a value is stored" do
      T.put_env_scoped(:server_name, "localhost")
      {_c, doc} = page([])
      assert Floki.attribute(Floki.find(doc, "input#oauth-issuer-input"), "value") in [[], [""]]

      T.put_env_scoped(:server_name, "chat.example.com")
      T.put_env_scoped(:admin_session_secure, false)
      {_c, doc2} = page([])
      assert Floki.attribute(Floki.find(doc2, "input#oauth-issuer-input"), "value") in [[], [""]]

      T.put_env_scoped(:admin_session_secure, true)
      {_c, doc3} = page([{"oauth_issuer_url", "https://stored.example.com"}])
      assert Floki.attribute(Floki.find(doc3, "input#oauth-issuer-input"), "value") == ["https://stored.example.com"]
    end

    test "the help text names the checklist, the rollback, the cache TTL and that running OAuth sessions stay valid after switching off" do
      {_c, doc} = page([])
      t = text(hd(Floki.find(doc, "section#oauth-switch")))

      assert t =~ "07-deployment"
      assert t =~ ~r/Activating OAuth/
      assert t =~ ~r/remove the check|clear the check|uncheck|untick/i
      assert t =~ "NEBU_OAUTH_CONFIG_CACHE_MS"
      assert t =~ ~r/all nodes/i
      assert t =~ ~r/sessions.*stay valid|stay valid.*sessions/i
      assert t =~ "revoke_all_oauth_sessions"
    end

    test "the standing honest text: what the server cannot see stays the operator's job" do
      {_c, doc} = page([])
      assert [note] = Floki.find(doc, "#oauth-not-checked")
      t = text(note)
      assert t =~ ~r/cannot (see|check|verify)/i
      assert t =~ ~r/client IP/i
      assert t =~ ~r/load balancer/i
      assert t =~ ~r/groups? A/i
      assert t =~ ~r/auth_time/
    end

    test "the status list: each item carries a visible status word (never colour only) and its id / level" do
      T.put_env_scoped(:server_name, "chat.example.com")
      {_c, doc} = page([{"oauth_enabled", "false"}, {"oauth_issuer_url", "https://other.example.com"}])
      assert [list] = Floki.find(doc, "ul#oauth-status")
      items = Floki.find(list, "li[data-status-id]")
      assert length(items) >= 3

      for li <- items do
        [level] = Floki.attribute(li, "data-level")
        assert level in ["ok", "attention", "note"]
        word = %{"ok" => "OK", "attention" => "Attention", "note" => "Note"}[level]
        assert text(li) |> String.starts_with?(word), "#{inspect(text(li))} must start with #{word}"
      end

      assert [_] = Floki.find(list, ~s(li[data-status-id="issuer_host"][data-level="attention"]))
    end

    test "the empty trusted-proxy list shows as an attention item on the page" do
      prior = Nebu.Web.ClientIP.trusted()
      on_exit(fn -> :persistent_term.put({Nebu.Web.ClientIP, :trusted}, prior) end)
      Nebu.Web.ClientIP.configure(nil)
      {_c, doc} = page([])
      assert [li] = Floki.find(doc, ~s(li[data-status-id="proxy"]))
      assert Floki.attribute(li, "data-level") == ["attention"]
      assert text(li) =~ "NEBU_TRUSTED_PROXY_CIDRS"
    end

    test "the node line follows the live predicate of the server (200 vs 404 on this node)" do
      T.enable_oauth(@issuer)
      {_c, on_doc} = page([{"oauth_enabled", "true"}, {"oauth_issuer_url", @issuer}])
      assert text(hd(Floki.find(on_doc, ~s(li[data-status-id="node"])))) =~ "200"

      T.disable_oauth()
      {_c, off_doc} = page([])
      assert text(hd(Floki.find(off_doc, ~s(li[data-status-id="node"])))) =~ "404"
    end

    test "/admin/config/oauth-switch is not frameable and not cacheable (all response kinds)" do
      responses = [
        admin_conn(:get, @path) |> call(),
        good_post(on_params()),
        good_post(on_params("http://bad.example", "true")),
        admin_conn(:post, @post, on_params()) |> with_marker() |> call(),
        admin_conn(:post, @post, on_params()) |> T.put_strict_fetch_headers() |> call()
      ]

      for conn <- responses do
        csp = conn |> get_resp_header("content-security-policy") |> List.first()
        assert csp =~ "frame-ancestors 'none'", "#{conn.request_path} #{conn.status}"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], "#{conn.request_path} #{conn.status}"
        assert get_resp_header(conn, "cache-control") == ["no-store"], "#{conn.request_path} #{conn.status}"
      end

      for path <- ["/admin/config/oauth-switch/", "/admin//config/oauth-switch", "/admin/config//oauth-switch"] do
        conn = admin_conn(:post, path, %{}) |> call()
        refute conn.status == 404, "#{path} is routed"
        assert (conn |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'none'", path
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], path
      end
    end
  end

  # ─── AC2 — the gate ────────────────────────────────────────────────────────

  describe "AC2 — strict fetch metadata and the fresh marker run before anything else" do
    for header <- ["sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-user"] do
      test "without #{header}: the 403 'Request refused' page, nothing written or audited, the marker kept" do
        conn = admin_conn(:post, @post, on_params()) |> with_marker() |> T.put_strict_fetch_headers() |> delete_req_header(unquote(header)) |> call()

        assert conn.status == 403
        assert conn.resp_body =~ ~s(data-error="fetch_metadata")
        assert conn.private.plug_session["admin_reauth"] != nil
        refute_nothing_written()
      end
    end

    test "a fetch() of a script (cors / empty) with a fresh marker is refused" do
      conn =
        admin_conn(:post, @post, on_params())
        |> with_marker()
        |> put_req_header("sec-fetch-site", "same-origin")
        |> put_req_header("sec-fetch-mode", "cors")
        |> put_req_header("sec-fetch-dest", "empty")
        |> call()

      assert conn.status == 403
      refute_nothing_written()
    end

    test "both directions are protected: switching OFF is refused without fetch metadata and redirects without a marker" do
      stored_on()
      refused = admin_conn(:post, @post, off_params()) |> with_marker() |> call()
      assert refused.status == 403

      no_marker = admin_conn(:post, @post, off_params()) |> T.put_strict_fetch_headers() |> call()
      assert no_marker.status in [302, 303]
      assert get_resp_header(no_marker, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
      refute_nothing_written()
    end

    test "no marker, a stale one, one bound to another page, one of another subject, an unbound one: redirect to the re-authentication start" do
      for {what, opts} <- [none: nil, stale: [ago: 400], other_path: [path: "/admin/oauth/clients"], other_sub: [sub: "admin-2"]] do
        conn =
          admin_conn(:post, @post, on_params())
          |> then(fn c -> if opts, do: with_marker(c, opts), else: c end)
          |> T.put_strict_fetch_headers()
          |> call()

        assert conn.status in [302, 303], "#{what}: #{conn.status}"
        assert get_resp_header(conn, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")], "#{what}"
        refute_nothing_written()
      end

      unbound = admin_conn(:post, @post, on_params()) |> put_session("admin_reauth", T.fresh_marker("admin-1")) |> T.put_strict_fetch_headers() |> call()
      assert get_resp_header(unbound, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
      refute_nothing_written()
    end

    test "the gate comes BEFORE the validation (an invalid issuer gets the 403 / redirect, not the 200 re-render)" do
      invalid = on_params("http://bad.example", "")
      assert (admin_conn(:post, @post, invalid) |> with_marker() |> call()).status == 403
      assert (admin_conn(:post, @post, invalid) |> T.put_strict_fetch_headers() |> call()).status in [302, 303]
      refute_nothing_written()
    end

    test "the 403 page is the neutral config page (back link to /admin/config, config nav highlighted)" do
      conn = admin_conn(:post, @post, on_params()) |> with_marker() |> call()
      {:ok, doc} = Floki.parse_document(conn.resp_body)
      assert [back] = Floki.find(doc, ~s(a[data-role="back-to-list"]))
      assert Floki.attribute(back, "href") == ["/admin/config"]
      assert [_] = Floki.find(doc, ~s([data-navkey="config-general"][aria-current="page"]))
    end

    test "require_admin first: no session at all, a non-admin session and an admin flag of false never reach the form" do
      anon = conn(:post, @post) |> Map.put(:secret_key_base, @secret_key_base) |> @endpoint.admin_session([]) |> fetch_session() |> Map.put(:body_params, on_params()) |> T.put_strict_fetch_headers() |> call()
      assert anon.status in [302, 303, 401, 403]
      refute anon.status == 200

      user =
        admin_conn(:post, @post, on_params())
        |> put_session("current_user", %{"admin" => false, "sub" => "admin-1", "matrix_user_id" => "@u:test.local"})
        |> with_marker()
        |> T.put_strict_fetch_headers()
        |> call()

      assert user.status in [302, 303, 401, 403]
      refute user.resp_body =~ ~s(data-error="fetch_metadata")
      refute_nothing_written()

      # no marker, no fetch metadata at all: still the admin check first, never the gate's 403 page
      bare = admin_conn(:post, @post, on_params()) |> put_session("current_user", %{"admin" => false, "sub" => "u", "matrix_user_id" => "@u:test.local"}) |> call()
      refute bare.resp_body =~ ~s(data-error="fetch_metadata")
      refute bare.status == 200
      refute_nothing_written()
    end

    test "a query string never carries the form: the acknowledgement (or the switch) in the URL does not count" do
      body = %{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}
      merged = Map.put(body, "oauth_activation_ack", "true")

      conn =
        admin_conn(:post, @post <> "?oauth_activation_ack=true", body)
        |> Map.put(:params, merged)
        |> with_marker()
        |> T.put_strict_fetch_headers()
        |> call()

      assert conn.status == 200
      assert conn.resp_body =~ ~s(id="oauth-ack-error")
      refute_nothing_written()
    end

    test "other methods on the path are not routed and write nothing" do
      for method <- [:get, :put, :patch, :delete] do
        result =
          try do
            admin_conn(method, @post, nil) |> with_marker() |> T.put_strict_fetch_headers() |> call()
          rescue
            e in Phoenix.Router.NoRouteError -> e
          end

        refute match?(%Plug.Conn{status: status} when status in [200, 302, 303], result), "#{method}"
      end

      refute_nothing_written()
    end

    test "the CSRF check still runs first: without the bypass a request without a token is refused before the gate" do
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      conn = admin_conn(:post, @post, on_params()) |> with_marker() |> T.put_strict_fetch_headers()
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> call(conn) end
      refute_nothing_written()
    end
  end

  # ─── AC3 — validation ──────────────────────────────────────────────────────

  describe "AC3 — validation errors: 200 re-render with the submitted values, nothing written, the marker kept" do
    test "enabling without a valid issuer: the clear message under the issuer field (role=alert, aria-invalid, aria-describedby)" do
      for issuer <- ["", "http://chat.example.com", "https://chat.example.com/path"] do
        conn = good_post(on_params(issuer))
        assert conn.status == 200, inspect(issuer)
        {:ok, doc} = Floki.parse_document(conn.resp_body)

        assert [field] = Floki.find(doc, "input#oauth-issuer-input")
        assert Floki.attribute(field, "value") == [issuer]
        assert Floki.attribute(field, "aria-invalid") == ["true"]
        assert [describedby] = Floki.attribute(field, "aria-describedby")
        assert describedby =~ "oauth-issuer-error"
        assert [error] = Floki.find(doc, "p#oauth-issuer-error[role=alert]")
        assert text(error) =~ ~r/switched on without a valid https issuer/i

        assert conn.private.plug_session["admin_reauth"] != nil, "the admin corrects the text with the same fresh sign-in"
      end

      refute_nothing_written()
    end

    test "a missing acknowledgement: the error under the acknowledgement checkbox, the submitted issuer and checkbox state kept" do
      conn = good_post(on_params(@issuer, ""))
      assert conn.status == 200
      {:ok, doc} = Floki.parse_document(conn.resp_body)

      assert [error] = Floki.find(doc, "p#oauth-ack-error[role=alert]")
      assert text(error) =~ ~r/checklist/i
      assert [box] = Floki.find(doc, "input#oauth-ack-input")
      assert Floki.attribute(box, "aria-invalid") == ["true"]
      assert Floki.attribute(box, "aria-describedby") |> hd() =~ "oauth-ack-error"
      assert [_] = Floki.find(doc, ~s(input[type="checkbox"][name="oauth_enabled"][checked])), "the submitted on state is kept"
      assert Floki.attribute(Floki.find(doc, "input#oauth-issuer-input"), "value") == [@issuer]
      assert conn.private.plug_session["admin_reauth"] != nil
      refute_nothing_written()
    end

    test "a typed issuer is HTML-escaped when the page is rendered again" do
      conn = good_post(on_params("\"><script>alert(1)</script>", "true"))
      assert conn.status == 200
      refute conn.resp_body =~ "<script>alert(1)</script>"
      assert conn.resp_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "an invalid issuer while the switch is OFF is refused too (a junk value is never persisted)" do
      conn = good_post(off_params("ftp://x.example"))
      assert conn.status == 200
      assert conn.resp_body =~ ~s(id="oauth-issuer-error")
      refute_nothing_written()
    end

    test "oauth_enabled with another value than true / false is an error on the checkbox, never a silent off" do
      stored_on()

      for bad <- ["on", "1", "", "yes"] do
        conn = good_post(%{"oauth_enabled" => bad, "oauth_issuer_url" => @issuer})
        assert conn.status == 200, inspect(bad)
        assert conn.resp_body =~ ~s(id="oauth-enabled-error")
      end

      conn = good_post(%{"oauth_issuer_url" => @issuer})
      assert conn.status == 200
      refute_nothing_written()
    end

    test "the error page still shows the stored state and the status list" do
      conn = good_post(on_params("http://x.example", "true"))
      {:ok, doc} = Floki.parse_document(conn.resp_body)
      assert [_] = Floki.find(doc, "ul#oauth-status")
      assert [_] = Floki.find(doc, "#oauth-not-checked")
    end

    test "a multi-key pollution attempt writes nothing else: only the two oauth keys ever reach the transaction" do
      params = Map.merge(on_params(), %{"matrix_oidc_refresh_mode" => "online", "sso_redirect_allowed_origins" => "https://evil.example", "oidc_user_id_claim" => "email"})
      conn = good_post(params)
      assert conn.status == 302
      assert_received {:tx, changes, true}
      assert Map.keys(changes) |> Enum.sort() == ["oauth_enabled", "oauth_issuer_url"]
      refute_received {:stray_write, _, _}
    end
  end

  # ─── AC4 — persistence, audit, the marker ──────────────────────────────────

  describe "AC4 — a valid change" do
    test "on: one transaction with the normalized values and the audit function, flash, redirect, marker consumed, audit row" do
      conn = good_post(on_params("  #{@issuer}/  "))

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/config#oauth-switch"], "back to the section, not to the top of the page"
      assert_received {:tx, %{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, true}
      info = flash(conn, "info")
      assert info =~ "OAuth settings saved"
      assert info =~ ~r/within \d+ seconds|immediately/i
      assert conn.private.plug_session["admin_reauth"] == nil, "one fresh sign-in, one save"

      assert_received {:audit, "@admin:test.local", "oauth_switch_changed", "server_config", "oauth_enabled", meta, "success", nil}
      assert meta["enabled_before"] == false
      assert meta["enabled_after"] == true
      assert meta["issuer_before"] == ""
      assert meta["issuer_after"] == @issuer
      assert meta["reauth"] == "auth_time"
      refute_received {:audit, _, _, _, _, _, _, _}, "exactly one audit row per change"
    end

    test "off: the stored issuer stays, the audit row says on -> off, no acknowledgement needed" do
      stored_on()
      conn = good_post(off_params())

      assert conn.status == 302
      assert_received {:tx, %{"oauth_enabled" => "false", "oauth_issuer_url" => @issuer}, true}
      assert flash(conn, "info") =~ "OAuth settings saved"
      assert_received {:audit, _actor, "oauth_switch_changed", "server_config", "oauth_enabled", %{"enabled_before" => true, "enabled_after" => false, "issuer_before" => @issuer, "issuer_after" => @issuer}, "success", nil}
      assert conn.private.plug_session["admin_reauth"] == nil
    end

    test "off with an empty issuer stores the empty string and audits the issuer change" do
      stored_on()
      conn = good_post(off_params(""))
      assert conn.status == 302
      assert_received {:tx, %{"oauth_enabled" => "false", "oauth_issuer_url" => ""}, true}
      assert_received {:audit, _, "oauth_switch_changed", _, _, %{"issuer_after" => ""}, _, _}
    end

    test "the audit actor is the Matrix id, else the sub; the reauth kind of the marker is recorded (flow)" do
      conn =
        admin_conn(:post, @post, on_params())
        |> put_session("current_user", %{"admin" => true, "sub" => "admin-1"})
        |> with_marker(kind: "flow")
        |> T.put_strict_fetch_headers()
        |> call()

      assert conn.status == 302
      assert_received {:audit, "admin-1", "oauth_switch_changed", _, _, %{"reauth" => "flow"}, "success", nil}
    end

    test "the audit metadata carries the switch and the issuer only (no token, no session, no config dump)" do
      good_post(on_params())
      assert_received {:audit, _, _, _, _, meta, _, _}
      assert Map.keys(meta) |> Enum.sort() == ["enabled_after", "enabled_before", "issuer_after", "issuer_before", "reauth"]
    end

    test "a failed write (the transaction seam answers an error) keeps the marker, shows an error and logs the error TYPE only" do
      Application.put_env(:nebu_http, :oauth_switch_tx, fn _changes, _audit -> {:error, :db_down} end)
      {conn, log} = with_log(fn -> good_post(on_params()) end)
      assert conn.status == 302
      assert flash(conn, "error") =~ ~r/failed to save/i
      assert conn.private.plug_session["admin_reauth"] != nil
      assert log =~ "OAuth switch save failed: :db_down"
      refute log =~ @issuer
    end

    test "the same marker cannot be replayed: the session of the first response goes into the second request" do
      first = good_post(on_params())
      assert first.status == 302
      assert_received {:tx, _, _}

      replay =
        conn(:post, @post)
        |> Map.put(:secret_key_base, @secret_key_base)
        |> recycle_cookies(first)
        |> Map.put(:body_params, off_params())
        |> T.put_strict_fetch_headers()
        |> call()

      assert replay.status in [302, 303]
      assert get_resp_header(replay, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
      refute_received {:tx, _, _}
    end
  end

  describe "D6 — no change" do
    test "a submission equal to the stored state writes and audits nothing, keeps the marker, says so" do
      stored_on()
      conn = good_post(on_params("#{@issuer}/"))

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/config#oauth-switch"]
      assert flash(conn, "info") =~ ~r/no change/i
      assert conn.private.plug_session["admin_reauth"] != nil
      refute_nothing_written()
    end

    test "off while nothing is stored is no change either (the default stays untouched: no key is created)" do
      stored([])
      conn = good_post(off_params(""))
      assert conn.status == 302
      assert flash(conn, "info") =~ ~r/no change/i
      refute_nothing_written()
    end
  end

  # ─── D7 — the audit asymmetry ──────────────────────────────────────────────

  describe "D7 — an audit row that cannot be written" do
    setup do
      Application.put_env(:nebu_http, :oauth_switch_audit_result, {:error, :audit_write_failed})
      :ok
    end

    test "turning the switch ON is refused: nothing is persisted, the error says why, the marker is kept" do
      conn = good_post(on_params())
      assert conn.status == 302
      assert flash(conn, "error") =~ ~r/audit/i
      assert flash(conn, "info") == nil
      assert conn.private.plug_session["admin_reauth"] != nil
      # the transaction was attempted ONCE (with the audit function); there is no retry without it
      assert_received {:tx, _, true}
      refute_received {:tx, _, _}
    end

    test "changing the issuer while on is refused as well" do
      stored_on()
      conn = good_post(on_params("https://other.example.com"))
      assert flash(conn, "error") =~ ~r/audit/i
      assert_received {:tx, _, true}
      refute_received {:tx, _, false}
    end

    test "turning the switch OFF is applied without the audit row, with a value-free ERROR log and a flash that says so (the kill switch is never blocked)" do
      stored_on()

      log =
        capture_log([level: :error], fn ->
          send(self(), {:conn, good_post(off_params())})
        end)

      assert_received {:conn, conn}
      assert conn.status == 302
      assert flash(conn, "error") =~ ~r/saved/i
      assert flash(conn, "error") =~ ~r/audit/i
      assert conn.private.plug_session["admin_reauth"] == nil, "the change happened: the marker is consumed"
      assert_received {:tx, _, true}
      assert_received {:tx, %{"oauth_enabled" => "false"}, false}
      assert log =~ ~r/audit/i
      refute log =~ @issuer
      refute log =~ "admin-1"
    end

    test "setting or changing an issuer while OFF needs its audit row (the issuer origin is trusted by the legacy SSO login with OAuth off too): refused, nothing saved" do
      stored([{"oauth_enabled", "false"}, {"oauth_issuer_url", "https://old.example.com"}])
      conn = good_post(Map.put(off_params("https://new.example.com"), "oauth_activation_ack", "true"))

      assert conn.status == 302
      assert flash(conn, "error") =~ ~r/not saved/i
      assert flash(conn, "error") =~ ~r/audit/i
      assert_received {:tx, _, true}
      refute_received {:tx, _, _}
      assert conn.private.plug_session["admin_reauth"] != nil
    end

    test "switching off together with a NEW issuer needs its audit row as well" do
      stored_on()
      conn = good_post(Map.put(off_params("https://other.example.com"), "oauth_activation_ack", "true"))
      assert flash(conn, "error") =~ ~r/not saved/i
      refute_received {:tx, _, false}
    end

    test "switching off with the issuer unchanged is applied without the audit row (stored issuer written with a trailing slash)" do
      stored([{"oauth_enabled", "true"}, {"oauth_issuer_url", @issuer <> "/"}])
      conn = good_post(off_params(@issuer))
      assert conn.status == 302
      assert flash(conn, "error") =~ ~r/saved/i
      assert_received {:tx, %{"oauth_enabled" => "false"}, false}
    end

    test "clearing the issuer while OFF is applied without the audit row as well" do
      stored([{"oauth_enabled", "false"}, {"oauth_issuer_url", "https://old.example.com"}])
      conn = good_post(off_params(""))
      assert conn.status == 302
      assert_received {:tx, %{"oauth_issuer_url" => ""}, false}
    end

    test "a raising audit writer while switching OFF is applied without the audit row" do
      stored_on()
      Application.put_env(:nebu_http, :oauth_switch_audit_result, :raise)
      conn = good_post(off_params())
      assert conn.status == 302
      assert flash(conn, "error") =~ ~r/audit/i
      assert_received {:tx, %{"oauth_enabled" => "false"}, false}
    end

    test "actor_id/1 is nil without a Matrix id and without a sub (the defensive no_actor branch of the controller then refuses ON)" do
      conn = admin_conn(:get, @path) |> assign(:current_user, %{"admin" => true})
      assert Nebu.Admin.OAuthAdminHelpers.actor_id(conn) == nil
    end

    test "a raising audit writer behaves like a failing one" do
      Application.put_env(:nebu_http, :oauth_switch_audit_result, :raise)
      conn = good_post(on_params())
      assert flash(conn, "error") =~ ~r/audit/i
      assert conn.status == 302
    end
  end

  # ─── AC7 — the form never writes another key ───────────────────────────────

  describe "AC7 — the other forms and keys are untouched" do
    test "the refresh-mode form still saves through its own seam and never through the OAuth transaction" do
      assert (admin_conn(:post, "/admin/config/refresh-mode", %{"matrix_oidc_refresh_mode" => "online"}) |> T.put_strict_fetch_headers() |> call()).status == 302
      assert_received {:stray_write, :admin_config_refresh_mode_writer, _}
      refute_received {:tx, _, _}
    end

    test "the router has the route and the unframed segment (static)" do
      src = File.read!(Path.expand("../../../lib/nebu/admin/router.ex", __DIR__))
      assert src =~ ~s(post "/config/oauth-switch", ConfigController, :save_oauth_switch)
      assert src =~ ~s("oauth-switch")
    end
  end

  # ─── AC8 — the audit vocabulary ────────────────────────────────────────────

  describe "AC8 — Nebu.Compliance.AuditWriter knows oauth_switch_changed" do
    test "the action is in @known_actions (without it the real writer answers :audit_unknown_action and nothing is ever audited)" do
      src = File.read!(Path.expand("../../../lib/nebu/compliance/audit_writer.ex", __DIR__))
      assert src =~ ~r/@known_actions ~w\([^)]*\boauth_switch_changed\b/s
    end
  end
end
