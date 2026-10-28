defmodule Nebu.Admin.ConfigSsoTrustHardeningTest do
  @moduledoc """
  Story `sso-origins-admin-hardening` (SEC gate 3 delta X-1), ACs 1, 3, 4: the two admin forms that widen legacy-SSO
  trust (`POST /admin/config/sso-origins`, `POST /admin/config/sso-schemes`) run `OAuthAdminHelpers.gate(conn, :marker,
  "/admin/config")` (strict fetch metadata, then a fresh admin re-authentication marker bound to `/admin/config`) after
  the admin check and the CSRF check and before anything is validated or written; the marker is consumed after a
  SUCCESSFUL write only. `/admin/config` is never framed. The other forms of the page are unchanged.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-sso-trust-hardening-b", 2)
  @path "/admin/config"
  @origins_path "/admin/config/sso-origins"
  @schemes_path "/admin/config/sso-schemes"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :trust_hardening_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:nebu_http, :admin_config_sso_origins_writer, fn changes ->
      send(test_pid, {:written, :origins, changes})
      :ok
    end)
    Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
      send(test_pid, {:written, :schemes, changes})
      :ok
    end)
    Application.put_env(:nebu_http, :admin_config_refresh_mode_writer, fn changes ->
      send(test_pid, {:written, :refresh_mode, changes})
      :ok
    end)
    Application.put_env(:nebu_http, :admin_config_scopes_writer, fn changes ->
      send(test_pid, {:written, :scopes, changes})
      :ok
    end)
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    T.put_env_scoped(:trust_hardening_audit_sink, self())
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_config_refresh_mode_writer, :admin_config_scopes_writer, :admin_server_config_reader] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp admin_conn(method, path, params \\ nil) do
    conn = %{conn(method, path) | secret_key_base: @secret_key_base}

    conn
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> then(fn c -> if params, do: Map.put(c, :body_params, params), else: c end)
  end

  defp with_marker(conn, opts \\ []) do
    sub = Keyword.get(opts, :sub, "admin-1")
    marker = T.fresh_marker(sub, Keyword.get(opts, :ago, 0), Keyword.get(opts, :kind, "auth_time"), Keyword.get(opts, :path, @path))
    put_session(conn, "admin_reauth", marker)
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  # a user-clicked, fresh-signed-in form submit
  defp good_post(path, params), do: admin_conn(:post, path, params) |> with_marker() |> T.put_strict_fetch_headers() |> call()

  defp origins_params(value \\ "https://ok.example"), do: %{"sso_redirect_allowed_origins" => value}
  defp schemes_params(value \\ "myorg-matrix"), do: %{"sso_extra_redirect_schemes" => value}

  defp forms, do: [{"origins", @origins_path, origins_params(), :origins}, {"schemes", @schemes_path, schemes_params(), :schemes}]

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
    refute_received {:written, _, _}
    refute_received {:audit, _, _, _, _, _, _, _}
  end

  describe "AC1 — strict fetch metadata" do
    for {label, path, params, _kind} <- [{"origins", @origins_path, %{"sso_redirect_allowed_origins" => "https://ok.example"}, :origins}, {"schemes", @schemes_path, %{"sso_extra_redirect_schemes" => "myorg-matrix"}, :schemes}] do
      for header <- ["sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-user"] do
        test "#{label}: without #{header} the response is the 403 'Request refused' page, nothing is written or audited" do
          conn =
            admin_conn(:post, unquote(path), unquote(Macro.escape(params)))
            |> with_marker()
            |> T.put_strict_fetch_headers()
            |> delete_req_header(unquote(header))
            |> call()

          assert conn.status == 403
          assert conn.resp_body =~ ~s(data-error="fetch_metadata")
          refute_nothing_written()
        end
      end

      test "#{label}: a cross-site / non-navigating request (a fetch() of a script) is refused even with a fresh marker" do
        conn =
          admin_conn(:post, unquote(path), unquote(Macro.escape(params)))
          |> with_marker()
          |> put_req_header("sec-fetch-site", "same-origin")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> call()

        assert conn.status == 403
        assert conn.resp_body =~ ~s(data-error="fetch_metadata")
        refute_nothing_written()
      end

      test "#{label}: the refusal comes before the validation (an invalid value gets the 403, not the 200 re-render)" do
        invalid = if unquote(label) == "origins", do: origins_params("https://*.example"), else: schemes_params("javascript")
        conn = admin_conn(:post, unquote(path), invalid) |> with_marker() |> call()
        assert conn.status == 403
        refute_nothing_written()
      end
    end
  end

  describe "the 403 page on /admin/config is neutral" do
    test "no 'confirmation page' or 'revoke a client' wording, a back link to the configuration page, the config nav highlighted" do
      conn = admin_conn(:post, @origins_path, origins_params()) |> with_marker() |> call()
      assert conn.status == 403
      html = conn.resp_body
      t = html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ")

      assert t =~ "This action must be submitted with its button in the same browser window. Your browser did not send the information that proves it, so nothing was changed."
      assert t =~ "If you used a script or an embedded page, open the page and press the button yourself."
      refute t =~ ~r/confirmation page/i
      refute t =~ ~r/command line/i
      {:ok, doc} = Floki.parse_document(html)
      assert [back] = Floki.find(doc, ~s(a[data-role="back-to-list"]))
      assert Floki.attribute(back, "href") == ["/admin/config"]
      assert t =~ "Back to the configuration page"
      assert [_] = Floki.find(doc, ~s([data-navkey="config-general"][aria-current="page"])), "the Configuration > General nav entry is the current page"
      assert [] == Floki.find(doc, ~s([data-navkey^="oauth"][aria-current="page"]))
    end

    test "the OAuth action pages keep their wording incl. the command line hint for the revoke / approve return paths" do
      src = File.read!(Path.expand("../../../lib/nebu/admin/templates/oauth_clients/fetch_metadata.html.heex", __DIR__))
      assert src =~ "command line"
    end

    test "the refusal WARNING no longer carries an OAuth-only prefix" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:conn, admin_conn(:post, @origins_path, origins_params()) |> with_marker() |> call()})
        end)

      assert log =~ "[warning] admin: request refused"
      refute log =~ "OAuth admin: request refused"
    end
  end

  describe "AC1 — fresh re-authentication marker bound to /admin/config" do
    for {label, path, params, _kind} <- [{"origins", @origins_path, %{"sso_redirect_allowed_origins" => "https://ok.example"}, :origins}, {"schemes", @schemes_path, %{"sso_extra_redirect_schemes" => "myorg-matrix"}, :schemes}] do
      test "#{label}: without a marker the response is a redirect to the re-authentication start, nothing is written or audited" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(params))) |> T.put_strict_fetch_headers() |> call()

        assert conn.status in [302, 303]
        assert get_resp_header(conn, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
        refute_nothing_written()
      end

      test "#{label}: a stale, foreign-path, foreign-subject or unbound marker is no marker" do
        for {what, marker_opts} <- [stale: [ago: 400], other_path: [path: "/admin/oauth/clients"], other_sub: [sub: "admin-2"]] do
          conn =
            admin_conn(:post, unquote(path), unquote(Macro.escape(params)))
            |> with_marker(marker_opts)
            |> T.put_strict_fetch_headers()
            |> call()

          assert conn.status in [302, 303], "#{what}: got #{conn.status}"
          assert get_resp_header(conn, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")], "#{what}"
        end

        unbound =
          admin_conn(:post, unquote(path), unquote(Macro.escape(params)))
          |> put_session("admin_reauth", T.fresh_marker("admin-1"))
          |> T.put_strict_fetch_headers()
          |> call()

        assert get_resp_header(unbound, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
        refute_nothing_written()
      end

      test "#{label}: the missing marker comes before the validation (an invalid value redirects to the sign-in, not a 200 re-render)" do
        invalid = if unquote(label) == "origins", do: origins_params("https://*.example"), else: schemes_params("javascript")
        conn = admin_conn(:post, unquote(path), invalid) |> T.put_strict_fetch_headers() |> call()
        assert conn.status in [302, 303]
        assert get_resp_header(conn, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
        refute_nothing_written()
      end
    end
  end

  describe "AC1 — with both, the save behaves as before and consumes the marker after a successful write only" do
    test "origins: persisted (normalized), audit row, success flash, redirect, marker consumed" do
      conn = good_post(@origins_path, origins_params("https://Chat.Example.com:443/, https://web.example.com:8443"))

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/config"]
      assert flash(conn, "info") == "SSO origins saved"
      assert_received {:written, :origins, %{"sso_redirect_allowed_origins" => "https://chat.example.com, https://web.example.com:8443"}}
      assert_received {:audit, "@admin:test.local", "sso_redirect_origins_changed", "server_config", "sso_redirect_allowed_origins", _, "success", _}
      assert conn.private.plug_session["admin_reauth"] == nil, "one fresh sign-in, one save"
    end

    test "schemes: persisted (normalized), success flash, redirect, marker consumed" do
      conn = good_post(@schemes_path, schemes_params("element,   custom-app  "))

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/admin/config"]
      assert flash(conn, "info") == "SSO schemes saved"
      assert_received {:written, :schemes, %{"sso_extra_redirect_schemes" => "element, custom-app"}}
      assert conn.private.plug_session["admin_reauth"] == nil
    end

    test "a validation error keeps the marker (the admin corrects the text with the same fresh sign-in)" do
      origins = good_post(@origins_path, origins_params("https://*.example"))
      assert origins.status == 200
      assert origins.resp_body =~ ~r/not valid/i
      assert origins.private.plug_session["admin_reauth"] != nil

      schemes = good_post(@schemes_path, schemes_params("javascript"))
      assert schemes.status == 200
      assert schemes.private.plug_session["admin_reauth"] != nil
      refute_nothing_written()
    end

    test "a failed write keeps the marker" do
      Application.put_env(:nebu_http, :admin_config_sso_origins_writer, fn _ -> {:error, :db_down} end)
      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn _ -> {:error, :db_down} end)

      for {_label, path, params, _kind} <- forms() do
        conn = good_post(path, params)
        assert conn.status == 302
        assert is_binary(flash(conn, "error"))
        assert conn.private.plug_session["admin_reauth"] != nil, path
      end

      refute_received {:audit, _, _, _, _, _, _, _}
    end

    test "the same marker cannot be replayed after a successful save: the session cookie of the first response goes into the second request" do
      first = good_post(@schemes_path, schemes_params("one-scheme"))
      assert first.status == 302
      assert first.private.plug_session["admin_reauth"] == nil
      assert_received {:written, :schemes, _}

      replay =
        conn(:post, @schemes_path)
        |> Map.put(:secret_key_base, @secret_key_base)
        |> recycle_cookies(first)
        |> Map.put(:body_params, schemes_params("two-scheme"))
        |> T.put_strict_fetch_headers()
        |> call()

      assert replay.status in [302, 303], "got #{replay.status}"
      # the carried session is the first response's: the admin stays signed in but the marker is gone
      assert get_resp_header(replay, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
      refute_received {:written, :schemes, _}
    end

    test "the CSRF check still runs first: without the bypass a request without a token is refused before the gate" do
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      conn = admin_conn(:post, @origins_path, origins_params()) |> with_marker() |> T.put_strict_fetch_headers()
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn -> call(conn) end
      refute_nothing_written()
    end
  end

  describe "AC2 — scopes and refresh mode need the strict fetch metadata but no marker (story admin-config-privileged-forms-sweep)" do
    test "refresh mode and scopes save with strict fetch metadata and WITHOUT a marker" do
      refresh = admin_conn(:post, "/admin/config/refresh-mode", %{"matrix_oidc_refresh_mode" => "online"}) |> T.put_strict_fetch_headers() |> call()
      assert refresh.status == 302
      assert get_resp_header(refresh, "location") == ["/admin/config"]

      scopes = admin_conn(:post, "/admin/config/scopes", %{"matrix_oidc_extra_scopes" => "profile", "admin_oidc_extra_scopes" => ""}) |> T.put_strict_fetch_headers() |> call()
      assert scopes.status in [200, 302]
      refute scopes.status in [403]
    end

    test "without fetch metadata they are refused (the 403 page)" do
      for {path, params} <- [{"/admin/config/refresh-mode", %{"matrix_oidc_refresh_mode" => "online"}}, {"/admin/config/scopes", %{"matrix_oidc_extra_scopes" => "profile", "admin_oidc_extra_scopes" => ""}}] do
        assert admin_conn(:post, path, params) |> call() |> Map.get(:status) == 403
      end
    end
  end

  describe "AC3 — /admin/config is never framed" do
    test "GET /admin/config: frame-ancestors 'none' (no 'self'), X-Frame-Options DENY, Cache-Control no-store" do
      conn = admin_conn(:get, @path) |> call()
      assert conn.status == 200
      csp = conn |> get_resp_header("content-security-policy") |> List.first()
      assert csp =~ "frame-ancestors 'none'"
      refute csp =~ "frame-ancestors 'self'"
      assert csp =~ "default-src 'self'", "the rest of the admin policy is unchanged"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "the two POSTs (200 re-render, 302, 403 page) carry the same headers" do
      responses = [
        good_post(@origins_path, origins_params()),
        good_post(@origins_path, origins_params("https://*.example")),
        admin_conn(:post, @schemes_path, schemes_params()) |> with_marker() |> call()
      ]

      for conn <- responses do
        csp = conn |> get_resp_header("content-security-policy") |> List.first()
        assert csp =~ "frame-ancestors 'none'", "#{conn.request_path} #{conn.status}"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], "#{conn.request_path} #{conn.status}"
        assert get_resp_header(conn, "cache-control") == ["no-store"], "#{conn.request_path} #{conn.status}"
      end
    end

    test "the OAuth admin pages keep their headers and another admin page keeps frame-ancestors 'self' without DENY" do
      oauth = admin_conn(:get, "/admin/oauth/registrations") |> call()
      assert (oauth |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'none'"
      assert get_resp_header(oauth, "x-frame-options") == ["DENY"]

      other = admin_conn(:get, "/admin/dashboard") |> call()
      assert (other |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'self'"
      refute get_resp_header(other, "x-frame-options") == ["DENY"]
    end

    test "trailing slash and double slash variants are not framable either (decided on path_info, like the routing; GET and POST)" do
      variants =
        for path <- ["/admin/config/", "/admin//config", "/admin/config//", "/admin//config/"], do: {:get, path}

      posts =
        for path <- ["/admin/config/sso-origins/", "/admin//config/sso-origins", "/admin/config//sso-origins", "/admin/config/sso-schemes/", "/admin/config/scopes/", "/admin/config/refresh-mode/"],
            do: {:post, path}

      for {method, path} <- variants ++ posts do
        conn = admin_conn(method, path, if(method == :post, do: %{}, else: nil)) |> call()
        refute conn.status == 404, "#{path} is routed (got #{conn.status})"
        csp = conn |> get_resp_header("content-security-policy") |> List.first()
        assert csp =~ "frame-ancestors 'none'", "#{method} #{path}: #{csp}"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], "#{method} #{path}"
        assert get_resp_header(conn, "cache-control") == ["no-store"], "#{method} #{path}"
      end
    end

    test "the same variants of the OAuth admin pages are not framable (decided on path_info)" do
      for path <- ["/admin/oauth/registrations/", "/admin//oauth/registrations", "/admin/oauth//registrations", "/admin/oauth/clients/", "/admin//oauth/clients/revoked"] do
        conn = admin_conn(:get, path) |> call()
        refute conn.status == 404, "#{path} is routed (got #{conn.status})"
        csp = conn |> get_resp_header("content-security-policy") |> List.first()
        assert csp =~ "frame-ancestors 'none'", "#{path}: #{csp}"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], path
      end
    end

    test "the claim mapping and role mapping pages are unframed too (story admin-config-privileged-forms-sweep)" do
      for path <- ["/admin/config/claim-mapping", "/admin/config/role-mapping", "/admin/config/claim-mapping/"] do
        conn = admin_conn(:get, path) |> call()
        csp = conn |> get_resp_header("content-security-policy") |> List.first()
        assert csp =~ "frame-ancestors 'none'", "#{path}: #{csp}"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], path
      end
    end

    test "there is ONE copy of the header list: the router has no second x-frame-options header" do
      src = File.read!(Path.expand("../../../lib/nebu/admin/router.ex", __DIR__))
      assert length(Regex.scan(~r/"x-frame-options"/, src)) == 1
    end
  end

  describe "AC4 — the page tells the admin that saving needs a fresh sign-in" do
    test "one sentence next to the two forms, referenced by aria-describedby of both submit buttons" do
      html = (admin_conn(:get, @path) |> call()).resp_body

      for {form, label} <- [{"sso-schemes-form", "Save SSO schemes"}, {"sso-origins-form", "Save SSO origins"}] do
        [_, block] = Regex.run(~r/<form[^>]*id="#{form}".*?<\/form>/s, html) |> then(&[nil, hd(&1)])
        [button] = Regex.scan(~r/<button\b[^>]*>\s*#{label}\s*<\/button>/s, block) |> Enum.map(&hd/1)
        assert [_, id] = Regex.run(~r/aria-describedby="([^"]+)"/, button), "#{form}: the submit button needs aria-describedby"
        assert block =~ ~r/id="#{Regex.escape(id)}"[^>]*>[^<]*Saving this setting needs a fresh sign-in\. If you are asked to sign in again, you return to this page and must enter your change again\./,
               "#{form}: the referenced element carries the hint"
      end
    end
  end
end
