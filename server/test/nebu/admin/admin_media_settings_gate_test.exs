defmodule Nebu.Admin.AdminMediaSettingsGateTest do
  @moduledoc """
  Story `admin-forms-gate-sweep` (follow-up `de`), AC2 (decisions D1, D2): the media policy save (`POST /admin/media/settings`, M1) and the storage target save
  (`POST /admin/media/settings/storage`, M2) need the strict fetch metadata AND a fresh admin sign-in marker bound to `/admin/media/settings` (one marker for both: the
  page holds ONE object, the instance configuration); the marker is consumed after a SUCCESSFUL save only. The test-connection button (M3) needs the strict
  fetch metadata only and never touches the marker. The page is unframed (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`).

  The seams are the ones of `media_settings_controller_test.exs` (config / storage writers, the storage loader, the audit repo fake).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth
  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-gate-test-key-base", 3)
  @page "/admin/media/settings"

  defmodule FakeAuditRepo do
    @moduledoc false
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert(struct, _opts \\ []), do: {:ok, struct}
    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  @policy %{
    "max_upload_size_bytes" => "52428800",
    "max_file_size_bytes" => "104857600",
    "max_pending_per_user" => "20",
    "max_stall_ms" => "20000",
    # not the default: an unchanged submission writes nothing
    "deleted_days" => "31",
    "infected_days" => "7",
    "orphaned_hours" => "24",
    "webhook_url" => "",
    "released_delete_after_days" => ""
  }

  @storage %{"endpoint" => "93.184.216.34:9000", "bucket" => "media-bucket", "region" => "us-east-1", "use_ssl" => "false", "access_key" => "AKIAGATETEST", "secret_key" => "gate-test-secret", "s3_key_prefix_template" => "{media_id}"}

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:compliance, :repo, FakeAuditRepo)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "media-gate-test-at-rest-secret")
    Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
      send(test_pid, {:policy_written, key, value})
      :ok
    end)
    Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      send(test_pid, {:storage_written, Map.keys(columns)})
      :ok
    end)
    Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
    Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)
    Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
      send(test_pid, {:tested, candidate.endpoint})
      :ok
    end)
    Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
    # the boot cache of the media config would make the changed-keys diff nondeterministic (see media_settings_controller_test)
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_secret_at_rest, :media_config_writer, :media_storage_config_writer, :media_storage_config_loader, :media_storage_env_reader, :media_storage_test_connection_fun, :media_files_storage_key_count_fun, :media_config_source, :media_config_loader] do
        Application.delete_env(:nebu_http, k)
      end

      Application.delete_env(:compliance, :repo)
    end)

    :ok
  end

  defp admin_conn(method, path, params) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> T.put_strict_fetch_headers()
  end

  defp with_marker(conn, opts \\ []) do
    put_session(conn, "admin_reauth", T.fresh_marker(Keyword.get(opts, :sub, "admin-1"), Keyword.get(opts, :ago, 0), "auth_time", Keyword.get(opts, :path, @page)))
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))
  defp marker_kept?(conn), do: conn.private.plug_session["admin_reauth"] != nil

  defp refute_nothing_written do
    refute_received {:policy_written, _, _}
    refute_received {:storage_written, _}
  end

  for {label, path, params} <- [{"M1 media policy", "/admin/media/settings", @policy}, {"M2 storage target", "/admin/media/settings/storage", @storage}] do
    describe "#{label}: the gate (strict fetch metadata + marker bound to the media settings page)" do
      test "no marker: a redirect to the sign-in of THIS page, nothing written" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(params))) |> call()
        assert conn.status in [302, 303]
        assert get_resp_header(conn, "location") == [Auth.reauth_start_path(@page)]
        refute_nothing_written()
      end

      test "a stale, foreign-page or foreign-subject marker is refused the same way" do
        for {what, opts} <- [stale: [ago: 400], other_page: [path: "/admin/config"], claim_page: [path: "/admin/config/claim-mapping"], other_sub: [sub: "admin-2"]] do
          conn = admin_conn(:post, unquote(path), unquote(Macro.escape(params))) |> with_marker(opts) |> call()
          assert get_resp_header(conn, "location") == [Auth.reauth_start_path(@page)], inspect(what)
        end

        refute_nothing_written()
      end

      test "without the fetch metadata of a click: the 403 page BEFORE the marker is looked at; the marker is kept" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(params))) |> with_marker() |> delete_req_header("sec-fetch-user") |> call()
        assert conn.status == 403
        assert conn.resp_body =~ ~s(data-error="fetch_metadata")
        assert marker_kept?(conn)
        refute_nothing_written()
      end

      test "a fresh marker of this page: saved, and the marker is consumed (single use)" do
        conn = admin_conn(:post, unquote(path), unquote(Macro.escape(params))) |> with_marker() |> call()
        assert conn.status in [200, 302, 303]
        refute match?([_ | _], get_resp_header(conn, "location") |> Enum.filter(&String.contains?(&1, "mode=reauth")))
        assert_received msg when elem(msg, 0) in [:policy_written, :storage_written]
        refute marker_kept?(conn), "one marker, one decision"
      end

      test "a validation error keeps the marker (the admin corrects the value without a new sign-in)" do
        bad = Map.merge(unquote(Macro.escape(params)), if(unquote(path) == "/admin/media/settings", do: %{"max_upload_size_bytes" => "-5"}, else: %{"endpoint" => "http://scheme.example"}))
        conn = admin_conn(:post, unquote(path), bad) |> with_marker() |> call()
        assert conn.status == 200
        assert marker_kept?(conn)
        refute_nothing_written()
      end
    end
  end

  describe "M1 and M2 share one marker per page (D2): a marker earned for the page works for either form, once" do
    test "the marker spent on the policy does not unlock the storage form, and the other way round" do
      first = admin_conn(:post, "/admin/media/settings", @policy) |> with_marker() |> call()
      refute marker_kept?(first)

      replay = conn(:post, "/admin/media/settings/storage") |> Map.put(:secret_key_base, @secret_key_base) |> recycle_cookies(first) |> Map.put(:body_params, @storage) |> Map.put(:params, @storage) |> T.put_strict_fetch_headers() |> call()
      assert get_resp_header(replay, "location") == [Auth.reauth_start_path(@page)]
    end

    test "the marker of the media settings page does not unlock the other marker forms (the binding is per page)" do
      for {path, params} <- [{"/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://ok.example"}}, {"/admin/config/claim-mapping", %{"oidc_user_id_claim" => "sub", "oidc_displayname_claim" => "name", "oidc_email_claim" => "email"}}, {"/admin/config/role-mapping", %{"admin_group_claim" => "ops"}}] do
        conn = admin_conn(:post, path, params) |> with_marker() |> call()
        assert conn.status in [302, 303], path
        assert get_resp_header(conn, "location") != [], path
        assert hd(get_resp_header(conn, "location")) =~ "mode=reauth", path
      end
    end
  end

  describe "the gate runs BEFORE the validation, and the marker survives everything but a successful save" do
    test "no marker + INVALID params is the sign-in redirect, not the validation message (gate first)" do
      for {path, bad} <- [{"/admin/media/settings", %{"max_upload_size_bytes" => "-5"}}, {"/admin/media/settings/storage", %{"endpoint" => "http://scheme.example"}}] do
        conn = admin_conn(:post, path, Map.merge(@policy, bad) |> Map.merge(@storage)) |> call()
        assert get_resp_header(conn, "location") == [Auth.reauth_start_path(@page)], path
      end
    end

    test "an unbound marker, the role mapping marker and an OAuth confirm page marker do not unlock either form; a marker 299 s old still does" do
      for path_opts <- [[path: nil], [path: "/admin/config/role-mapping"], [path: "/admin/oauth/clients/abc/revoke"]] do
        conn = admin_conn(:post, "/admin/media/settings", @policy) |> with_marker(path_opts) |> call()
        assert get_resp_header(conn, "location") == [Auth.reauth_start_path(@page)], inspect(path_opts)
      end

      refute_nothing_written()
      conn = admin_conn(:post, "/admin/media/settings", @policy) |> with_marker(ago: 299) |> call()
      assert_received {:policy_written, _, _}
      refute marker_kept?(conn)
    end

    test "the storage form: the orphan-risk re-render (200, nothing written) and a failing write keep the marker" do
      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> %{"endpoint" => "old-endpoint:9000", "bucket" => "old", "region" => "us-east-1", "use_ssl" => false, "access_key_encrypted" => nil, "secret_key_encrypted" => nil, "s3_key_prefix_template" => "{media_id}", "archive_bucket" => nil, "iam_endpoint" => nil, "sts_endpoint" => nil} end)
      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 3 end)

      warned = admin_conn(:post, "/admin/media/settings/storage", @storage) |> with_marker() |> call()
      assert warned.status == 200
      assert marker_kept?(warned)
      refute_nothing_written()

      Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
      Application.put_env(:nebu_http, :media_storage_config_writer, fn _columns, _set_at -> {:error, :db_down} end)
      failed = admin_conn(:post, "/admin/media/settings/storage", @storage) |> with_marker() |> call()
      assert failed.status == 200
      assert marker_kept?(failed), "nothing was saved: the marker is not spent"
    end

    test "the marker spent on the storage target does not unlock the policy (the other direction)" do
      first = admin_conn(:post, "/admin/media/settings/storage", @storage) |> with_marker() |> call()
      refute marker_kept?(first)
      replay = conn(:post, "/admin/media/settings") |> Map.put(:secret_key_base, @secret_key_base) |> recycle_cookies(first) |> Map.put(:body_params, @policy) |> Map.put(:params, @policy) |> T.put_strict_fetch_headers() |> call()
      assert get_resp_header(replay, "location") == [Auth.reauth_start_path(@page)]
    end
  end

  describe "Safari: the click proof (M1 / M2)" do
    for {label, path, key} <- [{"M1", "/admin/media/settings", :policy}, {"M2", "/admin/media/settings/storage", :storage}] do
      test "#{label}: a fresh marker without the proof is the notice and keeps the marker, with the proof it saves and consumes it" do
        params = if unquote(key) == :policy, do: @policy, else: @storage

        unproven = admin_conn(:post, unquote(path), params) |> with_marker() |> T.put_safari_fetch_headers() |> call()
        assert unproven.resp_body =~ "oauth-activation-unproven"
        assert marker_kept?(unproven)
        refute_nothing_written()

        proven = admin_conn(:post, unquote(path), T.with_click_proof(params)) |> with_marker() |> T.put_safari_fetch_headers() |> call()
        assert proven.status in [200, 302, 303]
        assert_received msg when elem(msg, 0) in [:policy_written, :storage_written]
        refute marker_kept?(proven)
      end
    end
  end

  describe "M3 test connection: strict fetch metadata only, the marker is neither needed nor touched" do
    test "without a marker the test runs; a marker of this page stays untouched" do
      none = admin_conn(:post, "/admin/media/settings/storage/test-connection", @storage) |> call()
      assert none.status == 200
      assert_received {:tested, "93.184.216.34:9000"}

      with = admin_conn(:post, "/admin/media/settings/storage/test-connection", @storage) |> with_marker() |> call()
      assert with.status == 200
      assert marker_kept?(with), "a test persists nothing: it must not spend the marker"
    end

    test "D4: blank keys for a foreign endpoint: the page says to enter the keys, the test function is never called" do
      blank = Map.merge(@storage, %{"access_key" => "", "secret_key" => ""})
      conn = admin_conn(:post, "/admin/media/settings/storage/test-connection", blank) |> call()
      assert conn.status == 200
      assert conn.resp_body =~ "Enter the access key and secret key to test a different endpoint"
      refute_received {:tested, _}
    end

    test "without the fetch metadata of a click: the 403 page, the test function is never called" do
      conn = admin_conn(:post, "/admin/media/settings/storage/test-connection", @storage) |> delete_req_header("sec-fetch-user") |> call()
      assert conn.status == 403
      refute_received {:tested, _}
    end
  end

  describe "UX B1 — the page says in advance that Save needs a fresh sign-in" do
    test "both forms have the hint and the Save button points at it (aria-describedby), the storage hint names the keys; Test Connection needs none" do
      {:ok, doc} = admin_conn(:get, @page, %{}) |> call() |> Map.fetch!(:resp_body) |> Floki.parse_document()

      for {id, form_action} <- [{"media-policy-reauth-hint", "/admin/media/settings"}, {"media-storage-reauth-hint", "/admin/media/settings/storage"}] do
        assert [hint] = Floki.find(doc, "p##{id}")
        assert Floki.text(hint) =~ "needs a fresh sign-in"
        assert [form] = Floki.find(doc, ~s(form[action="#{form_action}"]))
        assert [save] = Floki.find(form, ~s(button[aria-describedby="#{id}"]))
        assert Floki.text(save) =~ "Save"
      end

      assert doc |> Floki.find("p#media-storage-reauth-hint") |> Floki.text() =~ "secret key"
    end
  end

  describe "D2 — the page is unframed and the re-authentication notice names the secret" do
    test "GET and POST responses of the media settings page carry frame-ancestors 'none', X-Frame-Options DENY and no-store" do
      for conn <- [admin_conn(:get, @page, %{}) |> call(), admin_conn(:post, @page, @policy) |> call(), admin_conn(:post, @page <> "/storage", @storage) |> call()] do
        assert (conn |> get_resp_header("content-security-policy") |> List.first()) =~ "frame-ancestors 'none'"
        assert get_resp_header(conn, "x-frame-options") == ["DENY"]
        assert get_resp_header(conn, "cache-control") |> Enum.join(",") =~ "no-store"
      end
    end

    test "Auth.reauth_return_to/1 accepts exactly the media settings page (no sub-path, no query, no look-alike)" do
      assert Auth.reauth_return_to(@page) == @page
      default = Auth.reauth_return_to("/nope")

      for bad <- [@page <> "/", @page <> "/storage", @page <> "?x=1", @page <> "#x", String.upcase(@page), "/admin/media", "/admin/media/settings%2F", "//evil.example/admin/media/settings"] do
        assert Auth.reauth_return_to(bad) == default, bad
      end
    end

    test "the start path of the sign-in carries the page" do
      assert Auth.reauth_start_path(@page) == "/admin/login/start?mode=reauth&return_to=%2Fadmin%2Fmedia%2Fsettings"
    end
  end
end
