defmodule Nebu.Admin.SsoConfigSecondSaveTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC15.3: saving the SSO schemes
  form TWICE and the SSO origins form TWICE through HTTP against the REAL database (no writer seam) ends with the
  second values and the success flash.

  Today the second save of the SSO schemes form raises an RLS error (`config_update_mutable` never listed
  `sso_extra_redirect_schemes`, `INSERT ... ON CONFLICT DO UPDATE` on the existing row fails the UPDATE `USING`
  check): migration 000048 fixes that and adds `sso_redirect_allowed_origins`. `:integration` (runtime role).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-sso-second-save-key-b", 3)
  @keys ~w(sso_extra_redirect_schemes sso_redirect_allowed_origins)

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    # no writer seam: the real Nebu.Admin.DB.upsert_server_config/1 path
    for k <- [:admin_config_sso_schemes_writer, :admin_config_sso_origins_writer, :admin_server_config_reader], do: Application.delete_env(:nebu_http, k)

    %{rows: prior} = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = ANY($1)", [@keys])
    T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
      for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
      if Process.whereis(Nebu.Web.OidcConfig), do: Nebu.Web.OidcConfig.refresh()
    end)

    :ok
  end

  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
  end

  defp post_form(path, params) do
    # every save is its own fresh sign-in (the marker is single use): strict fetch metadata + marker bound to /admin/config
    build_admin_conn(:post, path)
    |> put_session("admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", "/admin/config"))
    |> T.put_strict_fetch_headers()
    |> Map.put(:body_params, params)
    |> then(&@endpoint.call(&1, @endpoint.init([])))
  end

  # the flash of a response: assigns (rendered), private (put_flash) or the session a redirect wrote it to
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

  defp stored(key) do
    case T.sql!("SELECT value FROM server_config WHERE key = $1", [key]) do
      %{rows: [[v]]} -> v
      %{rows: []} -> nil
    end
  end

  defp assert_saved(conn, expected) do
    assert conn.status == 302, "expected the success redirect, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"
    assert get_resp_header(conn, "location") == ["/admin/config"]
    assert flash(conn, "info") == expected
    refute flash(conn, "error")
  end

  describe "AC15.3 — the second save takes effect (real DB, no writer seam)" do
    test "the SSO schemes form saved twice ends with the second value and the success flash" do
      conn1 = post_form("/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "scheme-one"})
      assert_saved(conn1, "SSO schemes saved")
      assert stored("sso_extra_redirect_schemes") == "scheme-one"

      conn2 = post_form("/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "scheme-two, scheme-three"})
      assert_saved(conn2, "SSO schemes saved")
      assert stored("sso_extra_redirect_schemes") == "scheme-two, scheme-three"
    end

    test "the SSO origins form saved twice ends with the second (normalized) value and the success flash" do
      conn1 = post_form("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://Chat.E2E.example:443/, https://web.e2e.example:8443"})
      assert_saved(conn1, "SSO origins saved")
      assert stored("sso_redirect_allowed_origins") == "https://chat.e2e.example, https://web.e2e.example:8443"

      conn2 = post_form("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://chat.e2e.example"})
      assert_saved(conn2, "SSO origins saved")
      assert stored("sso_redirect_allowed_origins") == "https://chat.e2e.example"
    end

    test "clearing the list (an empty value) is a save too" do
      assert_saved(post_form("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://a.e2e.example"}), "SSO origins saved")
      assert_saved(post_form("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => ""}), "SSO origins saved")
      assert stored("sso_redirect_allowed_origins") == ""
    end

    test "an invalid origins value persists nothing, not even over an existing value" do
      assert_saved(post_form("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://keep.e2e.example"}), "SSO origins saved")
      bad = post_form("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://*.e2e.example"})
      assert bad.status == 200
      assert bad.resp_body =~ ~r/not valid/i
      assert stored("sso_redirect_allowed_origins") == "https://keep.e2e.example"
    end

    test "after a save the DB-backed form shows the saved value on GET /admin/config" do
      assert_saved(post_form("/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://shown.e2e.example"}), "SSO origins saved")
      page = build_admin_conn(:get, "/admin/config") |> then(&@endpoint.call(&1, @endpoint.init([])))
      assert page.status == 200
      assert page.resp_body =~ "https://shown.e2e.example"
      assert page.resp_body =~ ~s(id="sso-origins-form")
    end
  end
end
