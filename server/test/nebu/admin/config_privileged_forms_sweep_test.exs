defmodule Nebu.Admin.ConfigPrivilegedFormsSweepTest do
  @moduledoc """
  Story `admin-config-privileged-forms-sweep` (follow-ups `cw`, Y-5), AC1 - AC5. The decision per form:

    * role mapping (`POST /admin/config/role-mapping`) and claim mapping (`POST /admin/config/claim-mapping`): `gate(conn, :marker, <their page>)`
      (strict fetch metadata incl. the Safari click proof, a fresh re-authentication marker bound to THAT page, single use), pages not framable;
    * OIDC scopes (`/admin/config/scopes`) and refresh mode (`/admin/config/refresh-mode`): `gate(conn, :click, "/admin/config")` (strict fetch
      metadata, NO marker: the marker's own sign-in would use the scopes that the form changes, a wrong value would lock the admin out), audited since the SEC review;
    * the SSO scheme list save writes an audit row `sso_redirect_schemes_changed` (Y-5); the two mappings write `oidc_claim_mapping_changed` /
      `admin_group_claim_changed` (claim NAMES only); scopes / refresh mode write `oidc_scopes_changed` / `oidc_refresh_mode_changed` (SEC review L-3).

  Test seams (test builds only): `:admin_config_claim_mapping_writer` and `:admin_config_role_mapping_writer` (1-arity `fn changes -> :ok | {:error, _}`),
  the existing `:admin_config_scopes_writer`, `:admin_config_refresh_mode_writer`, `:admin_config_sso_schemes_writer`, the audit writer seam.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-sweep-test-key-base", 3)
  @claim "/admin/config/claim-mapping"
  @role "/admin/config/role-mapping"
  @config "/admin/config"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :sweep_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      Application.get_env(:nebu_http, :sweep_audit_result, :ok)
    end
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    T.put_env_scoped(:sweep_audit_sink, self())
    T.put_env_scoped(:sweep_audit_result, :ok)
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

    writers = [
      {:admin_config_claim_mapping_writer, :claim},
      {:admin_config_role_mapping_writer, :role},
      {:admin_config_scopes_writer, :scopes},
      {:admin_config_refresh_mode_writer, :refresh},
      {:admin_config_sso_schemes_writer, :schemes}
    ]

    for {key, label} <- writers do
      Application.put_env(:nebu_http, key, fn changes ->
        send(test_pid, {:written, label, changes})
        Application.get_env(:nebu_http, :sweep_writer_result, :ok)
      end)
    end

    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    # story role-mapping-self-lockout-guard: no stored admin claim path whatever rows a previous run left in the database
    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn _key -> nil end)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_oidc_config_reader, :admin_server_config_reader, :sweep_writer_result | Enum.map(writers, &elem(&1, 0))], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp admin_conn(method, path, params \\ nil) do
    conn = %{conn(method, path) | secret_key_base: @secret_key_base}

    conn
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> then(fn c -> if params, do: c |> Map.put(:body_params, params) |> Map.put(:params, params), else: c end)
  end

  # story role-mapping-self-lockout-guard: the marker of the role mapping page carries the fingerprint of the fresh claims (what the callback
  # writes); here the claims of the admin hold every group value the tests below save
  @role_token_values ["admins", "groups", "ops-admins"]

  defp with_marker(conn, path, opts \\ []) do
    marker = T.fresh_marker(Keyword.get(opts, :sub, "admin-1"), Keyword.get(opts, :ago, 0), "auth_time", path)
    marker = if path == @role, do: Map.merge(marker, Nebu.Admin.Auth.role_claim_fingerprint(%{"groups" => @role_token_values})), else: marker
    put_session(conn, "admin_reauth", marker)
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp claim_params(overrides \\ %{}),
    do: Map.merge(%{"oidc_user_id_claim" => "sub", "oidc_displayname_claim" => "name", "oidc_email_claim" => "email"}, overrides)

  defp role_params(value \\ "admins"), do: %{"admin_group_claim" => value}

  defp refused?(conn), do: conn.status == 403 and conn.resp_body =~ ~s(data-error="fetch_metadata")

  defp refute_nothing_written do
    refute_received {:written, _, _}
    refute_received {:audit, _, _, _, _, _, _, _}
  end

  # ─── AC1 — claim mapping and role mapping: strict + marker bound to their page ────

  for {label, path, ok, invalid, writer, action} <- [
        {"claim mapping", @claim, %{"oidc_user_id_claim" => "preferred_username", "oidc_displayname_claim" => "name", "oidc_email_claim" => "email"}, %{"oidc_user_id_claim" => "", "oidc_displayname_claim" => "name", "oidc_email_claim" => "email"}, :claim, "oidc_claim_mapping_changed"},
        {"role mapping", @role, %{"admin_group_claim" => "groups"}, %{"admin_group_claim" => ""}, :role, "admin_group_claim_changed"}
      ] do
    describe "AC1 — #{label}: the gate (strict + marker for #{path})" do
      for header <- ["sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-user"] do
        test "without #{header}: the 403 page, nothing written or audited, the marker kept" do
          conn = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> with_marker(unquote(path)) |> T.put_strict_fetch_headers() |> delete_req_header(unquote(header)) |> call()
          assert refused?(conn)
          assert conn.private.plug_session["admin_reauth"] != nil
          refute_nothing_written()
        end
      end

      test "a fetch() is refused even with a fresh marker, before the validation" do
        conn =
          admin_conn(:post, unquote(path), unquote(Macro.escape(ok)))
          |> with_marker(unquote(path))
          |> put_req_header("sec-fetch-site", "same-origin")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> call()

        assert refused?(conn)
        assert refused?(admin_conn(:post, unquote(path), unquote(Macro.escape(invalid))) |> with_marker(unquote(path)) |> call())
        refute_nothing_written()
      end

      test "no / stale / foreign-page / foreign-subject / unbound marker: redirect to the sign-in of THIS page" do
        start = Nebu.Admin.Auth.reauth_start_path(unquote(path))

        for {what, marker} <- [
              none: nil,
              stale: T.fresh_marker("admin-1", 400, "auth_time", unquote(path)),
              config_page: T.fresh_marker("admin-1", 0, "auth_time", "/admin/config"),
              other_mapping: T.fresh_marker("admin-1", 0, "auth_time", if(unquote(path) == @claim, do: @role, else: @claim)),
              other_sub: T.fresh_marker("admin-2", 0, "auth_time", unquote(path)),
              unbound: T.fresh_marker("admin-1")
            ] do
          conn =
            admin_conn(:post, unquote(path), unquote(Macro.escape(ok)))
            |> then(fn c -> if marker, do: put_session(c, "admin_reauth", marker), else: c end)
            |> T.put_strict_fetch_headers()
            |> call()

          assert conn.status in [302, 303], "#{what}: #{conn.status}"
          assert get_resp_header(conn, "location") == [start], "#{what}"
        end

        refute_nothing_written()
      end

      test "the missing marker comes before the validation (sign-in redirect, not a 200)" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(invalid))) |> T.put_strict_fetch_headers() |> call()
        assert conn.status in [302, 303]
        assert get_resp_header(conn, "location") == [Nebu.Admin.Auth.reauth_start_path(unquote(path))]
        refute_nothing_written()
      end

      test "with both: saved, success flash, redirect to the page, marker consumed, one audit row" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> with_marker(unquote(path)) |> T.put_strict_fetch_headers() |> call()
        assert conn.status == 302
        assert get_resp_header(conn, "location") == [unquote(path)]
        assert conn.private.plug_session["admin_reauth"] == nil, "one fresh sign-in, one save"
        assert_received {:written, unquote(writer), _changes}
        assert_received {:audit, "@admin:test.local", unquote(action), "server_config", _target, meta, "success", nil}
        assert is_map(meta)
        refute_received {:audit, _, _, _, _, _, _, _}
      end

      test "a validation error keeps the marker (200 re-render)" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(invalid))) |> with_marker(unquote(path)) |> T.put_strict_fetch_headers() |> call()
        assert conn.status == 200
        assert conn.resp_body =~ ~r/must not be empty/
        assert conn.private.plug_session["admin_reauth"] != nil
        refute_nothing_written()
      end

      test "a failed write keeps the marker and writes no audit row" do
        Application.put_env(:nebu_http, :sweep_writer_result, {:error, :db_down})
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> with_marker(unquote(path)) |> T.put_strict_fetch_headers() |> call()
        assert conn.status == 200
        assert conn.resp_body =~ "Could not save"
        refute conn.resp_body =~ ~r/updated|saved\./i
        assert conn.private.plug_session["admin_reauth"] != nil
        refute_received {:audit, _, _, _, _, _, _, _}
      end

      test "a failing audit writer refuses the save: 200, the refusal flash, marker kept, value-free log (atomicity: config_audit_atomic_test)" do
        Application.put_env(:nebu_http, :sweep_audit_result, {:error, :audit_write_failed})

        {conn, log} =
          with_log(fn -> admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> with_marker(unquote(path)) |> T.put_strict_fetch_headers() |> call() end)

        assert conn.status == 200
        assert conn.resp_body =~ "not saved: the audit entry could not be written"
        assert conn.private.plug_session["admin_reauth"] != nil
        assert log =~ ~r/audit/i
        refute log =~ "preferred_username"
        refute log =~ "groups"
      end

      test "the refusal page names this page; Safari without proof gets the notice" do
        refused = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> with_marker(unquote(path)) |> call()
        {:ok, doc} = Floki.parse_document(refused.resp_body)
        assert [back] = Floki.find(doc, ~s(a[data-role="back-to-list"]))
        assert Floki.attribute(back, "href") == [unquote(path)]
        assert Floki.text(back) =~ if(unquote(path) == @claim, do: ~r/claim mapping page/i, else: ~r/role mapping page/i)
        assert [_] = Floki.find(doc, ~s([data-navkey="#{if unquote(path) == @claim, do: "claim-mapping", else: "role-mapping"}"][aria-current="page"]))

        {notice, log} = with_log(fn -> admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> with_marker(unquote(path)) |> T.put_safari_fetch_headers() |> call() end)
        assert notice.status == 200 and notice.resp_body =~ ~s(data-page="oauth-activation-unproven")
        assert log =~ ~r/click proof/i
        refute_nothing_written()
        assert notice.private.plug_session["admin_reauth"] != nil, "the notice keeps the marker (nothing happened)"
        {:ok, notice_doc} = Floki.parse_document(notice.resp_body)
        assert [notice_back] = Floki.find(notice_doc, ~s(a[data-role="back-to-list"]))
        assert Floki.attribute(notice_back, "href") == [unquote(path)]
        assert [_] = Floki.find(notice_doc, ~s([data-navkey="#{if unquote(path) == @claim, do: "claim-mapping", else: "role-mapping"}"][aria-current="page"]))
      end

      test "Safari: the click proof counts (saved), a fetch() with the proof is refused" do
        proven = admin_conn(:post, unquote(path), T.with_click_proof(unquote(Macro.escape(ok)))) |> with_marker(unquote(path)) |> T.put_safari_fetch_headers() |> call()
        assert proven.status in [302, 303]
        assert_received {:written, unquote(writer), changes}
        refute inspect(changes) =~ "click_proof"

        faked = admin_conn(:post, unquote(path), T.with_click_proof(unquote(Macro.escape(ok)))) |> with_marker(unquote(path)) |> T.put_safari_fetch_headers() |> put_req_header("sec-fetch-mode", "cors") |> call()
        assert refused?(faked)
      end

      test "require_admin first: a non-admin never sees the gate's refusal page" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> put_session("current_user", %{"admin" => false, "sub" => "u"}) |> call()
        refute conn.resp_body =~ ~s(data-error="fetch_metadata")
        refute conn.status == 200
        refute_nothing_written()
      end
    end
  end

  test "the role mapping refuses a value that occurs in every token (offline_access, default-roles-*, protocol scopes, the configured issuer / client id): 200, nothing written, marker kept" do
    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)

    for value <- ["offline_access", "Offline_Access", "default-roles-nebu", "uma_authorization", "openid", "email", "profile"] do
      conn = admin_conn(:post, @role, role_params(value)) |> with_marker(@role) |> T.put_strict_fetch_headers() |> call()
      assert conn.status == 200, value
      assert conn.resp_body =~ ~r/every sign-in token/, value
      assert conn.private.plug_session["admin_reauth"] != nil
    end

    refute_nothing_written()
    ok = admin_conn(:post, @role, role_params("ops-admins")) |> with_marker(@role) |> T.put_strict_fetch_headers() |> call()
    assert ok.status == 302
    assert_received {:written, :role, %{"admin_group_claim" => "ops-admins"}}
  end

  test "the audit metadata carries claim NAMES / the group claim only" do
    admin_conn(:post, @claim, claim_params()) |> with_marker(@claim) |> T.put_strict_fetch_headers() |> call()
    assert_received {:audit, _, "oidc_claim_mapping_changed", "server_config", "oidc_user_id_claim", meta, _, _}
    assert meta |> Map.keys() |> Enum.sort() == ["displayname_claim", "email_claim", "user_id_claim"]
    assert meta["user_id_claim"] == "sub"

    admin_conn(:post, @role, role_params("groups")) |> with_marker(@role) |> T.put_strict_fetch_headers() |> call()
    assert_received {:audit, _, "admin_group_claim_changed", "server_config", "admin_group_claim", %{"admin_group_claim" => "groups"} = meta2, _, _}
    assert map_size(meta2) == 1
  end

  test "a marker is spent on ONE save (single use): the replayed session needs a new sign-in" do
    first = admin_conn(:post, @claim, claim_params()) |> with_marker(@claim) |> T.put_strict_fetch_headers() |> call()
    assert first.status == 302
    assert_received {:written, :claim, _}

    replay = conn(:post, @claim) |> Map.put(:secret_key_base, @secret_key_base) |> recycle_cookies(first) |> Map.put(:body_params, claim_params()) |> T.put_strict_fetch_headers() |> call()
    assert get_resp_header(replay, "location") == [Nebu.Admin.Auth.reauth_start_path(@claim)]
    refute_received {:written, :claim, _}
  end

  test "a marker bound to a mapping page does not unlock the SSO trust forms or the OAuth switch (the binding is per page)" do
    for page <- [@claim, @role], {path, params} <- [{"/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://ok.example"}}, {"/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "x-scheme"}}, {"/admin/config/oauth-switch", %{"oauth_enabled" => "false", "oauth_issuer_url" => ""}}] do
      conn = admin_conn(:post, path, params) |> with_marker(page) |> T.put_strict_fetch_headers() |> call()
      assert conn.status in [302, 303], "#{page} -> #{path}"
      assert get_resp_header(conn, "location") == [Nebu.Admin.Auth.reauth_start_path("/admin/config")]
    end

    refute_received {:written, _, _}
  end

  test "scopes and refresh mode neither need nor spend a marker" do
    conn = admin_conn(:post, "/admin/config/scopes", %{"matrix_oidc_extra_scopes" => "profile", "admin_oidc_extra_scopes" => ""}) |> with_marker(@claim) |> T.put_strict_fetch_headers() |> call()
    assert conn.status == 302
    assert conn.private.plug_session["admin_reauth"]["path"] == @claim, "a marker of another page stays untouched"
  end

  test "a query string never carries a mapping form (body parameters only)" do
    body = %{"oidc_user_id_claim" => "sub"}
    conn =
      admin_conn(:post, @claim <> "?oidc_displayname_claim=name&oidc_email_claim=email", body)
      |> Map.put(:params, Map.merge(body, %{"oidc_displayname_claim" => "name", "oidc_email_claim" => "email"}))
      |> with_marker(@claim)
      |> T.put_strict_fetch_headers()
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ ~r/must not be empty/
    refute_nothing_written()
  end

  test "Safari: the click proof does not replace the marker (proof + no marker = redirect to the sign-in)" do
    for {path, params} <- [{@claim, claim_params()}, {@role, role_params()}] do
      conn = admin_conn(:post, path, T.with_click_proof(params)) |> T.put_safari_fetch_headers() |> call()
      assert conn.status in [302, 303]
      assert get_resp_header(conn, "location") == [Nebu.Admin.Auth.reauth_start_path(path)]
    end

    refute_nothing_written()
  end

  # ─── AC1 — the return target allowlist, the notice ────────────────────────

  describe "Auth.reauth_return_to/1 and the notice" do
    test "the two mapping pages are accepted exactly" do
      assert Nebu.Admin.Auth.reauth_return_to(@claim) == @claim
      assert Nebu.Admin.Auth.reauth_return_to(@role) == @role
      assert Nebu.Admin.Auth.reauth_return_to("/admin/config") == "/admin/config"
    end

    test "variants fall back to the default (trailing slash, query, fragment, case, encoded, other pages, absolute URLs)" do
      default = Nebu.Admin.Auth.reauth_return_to("/nope")

      for bad <- [@claim <> "/", @claim <> "?x=1", @claim <> "#x", String.upcase(@claim), "/admin/config/claim%2Dmapping", "/admin/config/other", "/admin/config//claim-mapping", "https://evil.example" <> @claim, "//evil.example" <> @role, @role <> "\n", "/admin/config/role-mapping/x"] do
        assert Nebu.Admin.Auth.reauth_return_to(bad) == default, inspect(bad)
      end
    end

    test "the reauth start for a mapping page binds that page (the callback and the notice are tested in admin_reauth_test.exs)" do
      assert Nebu.Admin.Auth.reauth_start_path(@role) == "/admin/login/start?mode=reauth&return_to=%2Fadmin%2Fconfig%2Frole-mapping"
      assert Nebu.Admin.Auth.reauth_start_path(@claim) == "/admin/login/start?mode=reauth&return_to=%2Fadmin%2Fconfig%2Fclaim-mapping"
    end

    test "the other config POST routes are not return targets" do
      default = Nebu.Admin.Auth.reauth_return_to("/nope")
      for bad <- ["/admin/config/scopes", "/admin/config/sso-origins", "/admin/config/oauth-switch", "/admin/config/refresh-mode"], do: assert(Nebu.Admin.Auth.reauth_return_to(bad) == default, bad)
    end
  end

  # ─── AC2 — scopes and refresh mode: strict, no marker ─────────────────────

  for {label, path, ok, invalid, writer} <- [
        {"scopes", "/admin/config/scopes", %{"matrix_oidc_extra_scopes" => "profile email", "admin_oidc_extra_scopes" => "profile"}, %{"matrix_oidc_extra_scopes" => "bad scope\n", "admin_oidc_extra_scopes" => ""}, :scopes},
        {"refresh mode", "/admin/config/refresh-mode", %{"matrix_oidc_refresh_mode" => "online", "admin_oidc_refresh_mode" => "offline"}, %{"matrix_oidc_refresh_mode" => "junk"}, :refresh}
      ] do
    describe "AC2 — #{label}: strict fetch metadata, no marker" do
      for header <- ["sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-user"] do
        test "without #{header}: the 403 page, nothing written" do
          conn = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> T.put_strict_fetch_headers() |> delete_req_header(unquote(header)) |> call()
          assert refused?(conn)
          refute_nothing_written()
        end
      end

      test "a request without any fetch metadata (the old plain POST) is refused" do
        assert refused?(admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> call())
        refute_nothing_written()
      end

      test "strict headers and NO marker are enough (no sign-in is asked): saved, redirect to /admin/config" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> T.put_strict_fetch_headers() |> call()
        assert conn.status == 302
        assert get_resp_header(conn, "location") == ["/admin/config"]
        assert_received {:written, unquote(writer), _}
      end

      test "a validation error is the usual answer (200 / nothing written), never a refusal, with the strict headers" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(invalid))) |> T.put_strict_fetch_headers() |> call()
        refute refused?(conn)
        assert conn.status == 200
        refute_nothing_written()
      end

      test "Safari: the click proof counts, without it the notice page (nothing written), the refusal page names /admin/config" do
        assert (admin_conn(:post, unquote(path), T.with_click_proof(unquote(Macro.escape(ok)))) |> T.put_safari_fetch_headers() |> call()).status in [302, 303]
        assert_received {:written, unquote(writer), changes}
        refute inspect(changes) =~ "click_proof"

        notice = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> T.put_safari_fetch_headers() |> call()
        assert notice.status == 200 and notice.resp_body =~ "oauth-activation-unproven"
        refute_received {:written, _, _}

        refused = admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> call()
        assert [back] = Floki.parse_document!(refused.resp_body) |> Floki.find(~s(a[data-role="back-to-list"]))
        assert Floki.attribute(back, "href") == ["/admin/config"]
      end

      test "one audit row after the save (SEC review L-3): it changes the claim set / the token lifetime; a failed write or a validation error writes none" do
        admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> T.put_strict_fetch_headers() |> call()
        action = if unquote(writer) == :scopes, do: "oidc_scopes_changed", else: "oidc_refresh_mode_changed"
        assert_received {:audit, "@admin:test.local", ^action, "server_config", _target, meta, "success", nil}
        assert is_map(meta) and meta != %{}
        refute_received {:audit, _, _, _, _, _, _, _}

        Application.put_env(:nebu_http, :sweep_writer_result, {:error, :db_down})
        admin_conn(:post, unquote(path), unquote(Macro.escape(ok))) |> T.put_strict_fetch_headers() |> call()
        refute_received {:audit, _, _, _, _, _, _, _}
      end
    end
  end

  # ─── AC5 — the SSO scheme list audit (Y-5) ────────────────────────────────

  describe "AC5 — the SSO scheme list writes an audit row" do
    defp schemes_post(value) do
      admin_conn(:post, "/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => value}) |> with_marker(@config) |> T.put_strict_fetch_headers() |> call()
    end

    test "one sso_redirect_schemes_changed row: the normalized list and its size, actor, target" do
      conn = schemes_post("element,   custom-app  ")
      assert conn.status == 302
      assert_received {:written, :schemes, %{"sso_extra_redirect_schemes" => "element, custom-app"}}

      assert_received {:audit, "@admin:test.local", "sso_redirect_schemes_changed", "server_config", "sso_extra_redirect_schemes", meta, "success", nil}
      assert meta == %{"schemes" => "element, custom-app", "count" => 2}
      refute_received {:audit, _, _, _, _, _, _, _}
    end

    test "clearing the list is audited too (count 0)" do
      assert schemes_post("").status == 302
      assert_received {:audit, _, "sso_redirect_schemes_changed", _, _, %{"schemes" => "", "count" => 0}, _, _}
    end

    test "a validation error and a failed write write no audit row; a failing audit writer refuses a widening and lets a clearing through (value-free log)" do
      assert schemes_post("javascript").status == 200
      refute_received {:audit, _, _, _, _, _, _, _}

      Application.put_env(:nebu_http, :sweep_writer_result, {:error, :db_down})
      schemes_post("one")
      refute_received {:audit, _, _, _, _, _, _, _}
      Application.put_env(:nebu_http, :sweep_writer_result, :ok)

      Application.put_env(:nebu_http, :sweep_audit_result, {:error, :audit_write_failed})
      {conn, log} = with_log(fn -> schemes_post("my-scheme") end)
      assert conn.status == 302
      assert log =~ ~r/audit/i
      refute log =~ "my-scheme"

      {cleared, _log} = with_log(fn -> schemes_post("") end)
      assert cleared.status == 302
      assert_received {:written, :schemes, %{"sso_extra_redirect_schemes" => ""}}
    end

    test "the action is in @known_actions (without it the real writer answers :audit_unknown_action)" do
      src = File.read!(Path.expand("../../../lib/nebu/compliance/audit_writer.ex", __DIR__))

      for action <- ~w(sso_redirect_schemes_changed oidc_claim_mapping_changed admin_group_claim_changed oidc_scopes_changed oidc_refresh_mode_changed) do
        assert src =~ Regex.compile!("@known_actions ~w\\([^)]*\\b#{action}\\b", "s"), action
      end
    end
  end

  # ─── AC3 — the pages are not framable ─────────────────────────────────────

  describe "AC3 — the mapping pages are not framable and not cacheable" do
    test "GET and POST (200 / 302 / 403) of both pages: frame-ancestors 'none', X-Frame-Options DENY, no-store" do
      responses =
        for path <- [@claim, @role] do
          [
            admin_conn(:get, path) |> call(),
            admin_conn(:post, path, if(path == @claim, do: claim_params(), else: role_params())) |> with_marker(path) |> T.put_strict_fetch_headers() |> call(),
            admin_conn(:post, path, if(path == @claim, do: claim_params(), else: role_params())) |> with_marker(path) |> call(),
            admin_conn(:post, path, if(path == @claim, do: claim_params(), else: role_params())) |> T.put_strict_fetch_headers() |> call()
          ]
        end
        |> List.flatten()

      assert length(responses) == 8

      for conn <- responses do
        csp = conn |> get_resp_header("content-security-policy") |> List.first()
        assert csp =~ "frame-ancestors 'none'", "#{conn.request_path} #{conn.status}"
        refute csp =~ "frame-ancestors 'self'"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], "#{conn.request_path} #{conn.status}"
        assert get_resp_header(conn, "cache-control") == ["no-store"], "#{conn.request_path} #{conn.status}"
      end
    end

    test "the slash variants (decided on path_info) are not framable either" do
      for {method, path} <- [{:get, "/admin/config/claim-mapping/"}, {:get, "/admin//config/role-mapping"}, {:get, "/admin/config//role-mapping"}, {:post, "/admin/config/claim-mapping/"}, {:post, "/admin//config/role-mapping"}] do
        conn = admin_conn(method, path, if(method == :post, do: %{}, else: nil)) |> call()
        refute conn.status == 404, path
        assert (conn |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'none'", path
        assert get_resp_header(conn, "x-frame-options") == ["DENY"], path
      end
    end

    test "another admin page still keeps frame-ancestors 'self'" do
      conn = admin_conn(:get, "/admin/dashboard") |> call()
      assert (conn |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'self'"
    end
  end

  # ─── AC4 — the forms ──────────────────────────────────────────────────────

  describe "AC4 — the forms carry the click proof field, the hint and (mappings) the lock-out warning" do
    for {label, path, form_selector} <- [{"claim mapping", @claim, "form[action='/admin/config/claim-mapping']"}, {"role mapping", @role, "form[action='/admin/config/role-mapping']"}] do
      test "#{label}: hidden _click_proof, the fresh sign-in hint on the button (aria-describedby), the lock-out warning" do
        conn = admin_conn(:get, unquote(path)) |> call()
        assert conn.status == 200
        {:ok, doc} = Floki.parse_document(conn.resp_body)
        assert [form] = Floki.find(doc, unquote(form_selector))
        assert [field] = Floki.find(form, ~s(input[type="hidden"][name="_click_proof"]))
        assert Floki.attribute(field, "data-click-proof") != []
        assert [button] = Floki.find(form, "button[type=submit]")
        assert [describedby] = Floki.attribute(button, "aria-describedby")
        ids = String.split(describedby)
        assert length(ids) == 2, "the lock-out hint and the sign-in hint"
        for id <- ids, do: assert(match?([_], Floki.find(doc, "##{id}")), "#{id} exists once")
        hint = ids |> Enum.map_join(" ", fn id -> doc |> Floki.find("##{id}") |> Floki.text() end) |> String.replace(~r/\s+/, " ")
        assert hint =~ "Saving this setting needs a fresh sign-in. If you are asked to sign in again, you return to this page and must enter your change again."

        page_text = doc |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ")
        if unquote(path) == @role do
          assert page_text =~ ~r/locks all administrators out/i
          assert page_text =~ ~r/makes every user an administrator/i
          assert page_text =~ ~r/open session cannot undo it/i
        else
          assert page_text =~ ~r/wrong or onto other users/i
          assert page_text =~ ~r/second browser|private window/i
        end

        assert page_text =~ "deployment guide"
        assert Floki.find(doc, ~s(script[src*="app.js"])) != []
      end
    end

    test "the scopes and refresh-mode forms carry the hidden _click_proof field, without the marker hint" do
      {:ok, doc} = admin_conn(:get, @config) |> call() |> Map.fetch!(:resp_body) |> Floki.parse_document()

      for id <- ["oidc-scopes-form", "oidc-refresh-mode-form"] do
        assert [form] = Floki.find(doc, "form##{id}")
        assert [field] = Floki.find(form, ~s(input[type="hidden"][name="_click_proof"]))
        assert Floki.attribute(field, "data-click-proof") != []
        refute Floki.text(form) =~ "needs a fresh sign-in", "#{id} asks for no sign-in"
      end
    end

    test "the static hygiene: every config form that posts is behind the gate" do
      src = File.read!(Path.expand("../../../lib/nebu/admin/config_controller.ex", __DIR__))
      for action <- ["save_scopes", "save_refresh_mode"], do: assert(src =~ ~r/def #{action}\(conn, _?params\) do\s+with \{:ok, conn, _kind\} <- Nebu\.Admin\.OAuthAdminHelpers\.gate\(conn, :click/s, action)

      for file <- ["claim_mapping_controller.ex", "role_mapping_controller.ex"] do
        mapping = File.read!(Path.expand("../../../lib/nebu/admin/#{file}", __DIR__))
        assert mapping =~ "OAuthAdminHelpers.gate(conn, :marker,", file
        assert mapping =~ "Nebu.Admin.Auth.consume_reauth", file
      end
    end
  end

  # ─── bootstrap wizard untouched ───────────────────────────────────────────

  describe "AC6 — the bootstrap wizard is not gated" do
    test "its POST routes answer neither the gate's refusal page nor a re-authentication redirect (no admin session, no fetch metadata, no marker)" do
      for path <- ["/admin/bootstrap/step/1", "/admin/bootstrap/step/2", "/admin/bootstrap/step/3"] do
        conn = conn(:post, path) |> Map.put(:secret_key_base, @secret_key_base) |> @endpoint.admin_session([]) |> fetch_session() |> Map.put(:body_params, %{"x" => "y"}) |> Map.put(:params, %{"x" => "y"}) |> call()
        refute conn.resp_body =~ ~s(data-error="fetch_metadata"), path
        refute conn.resp_body =~ "oauth-activation-unproven", path
        refute get_resp_header(conn, "location") |> Enum.any?(&String.contains?(&1, "mode=reauth")), path
      end
    end

    test "no bootstrap code path uses the gate (static): the controller, the login controller and the bootstrap helpers of Auth" do
      for file <- ["bootstrap_controller.ex", "login_controller.ex"] do
        refute File.read!(Path.expand("../../../lib/nebu/admin/#{file}", __DIR__)) =~ "OAuthAdminHelpers", file
      end
    end
  end
end
