defmodule Nebu.Admin.MediaSettingsStorageSaveTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, fixes B and D at the controller level
  (`POST /admin/media/settings/storage` and `.../storage/test-connection`; the model level is
  `Nebu.Media.StorageConfigEndpointSaveTest`).

    * B: a save that changes the endpoint or the Use SSL setting versus the stored / effective values without BOTH keys
      typed in the same form re-renders the page (200) with "Enter the access key and secret key to use a different
      endpoint", writes nothing, makes no audit entry and keeps the fresh sign-in marker (a validation error). A save of
      an unchanged target with blank keys works and leaves the stored credentials alone; a changed endpoint with both keys
      works.
    * D: an endpoint the operational parser rejects (path, IPv6 literal, port 0 / 65536 / not a number) is rejected by the
      save and by the Test Connection button (the request function is never called).

  Setup mirrors `Nebu.Admin.AdminMediaSettingsGateTest` (seams: storage writer / loader / env reader / test-connection
  function, audit repo fake, strict fetch metadata + fresh marker for the save).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-save-test-key-base", 3)
  @page "/admin/media/settings"
  @save "/admin/media/settings/storage"
  @test_connection "/admin/media/settings/storage/test-connection"
  @message "Enter the access key and secret key to use a different endpoint"

  @stored_endpoint "93.184.216.34:9000"

  defmodule FakeAuditRepo do
    @moduledoc false
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_storage_save_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:compliance, :repo, FakeAuditRepo)
    Application.put_env(:compliance, :__test_storage_save_pid__, test_pid)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "media-save-test-at-rest-secret")
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

    Application.put_env(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      send(test_pid, {:storage_written, columns})
      :ok
    end)

    Application.put_env(:nebu_http, :media_storage_config_loader, fn -> stored_row() end)
    Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{} end)

    Application.put_env(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
      send(test_pid, {:tested, candidate.endpoint})
      :ok
    end)

    Application.put_env(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
    Application.put_env(:nebu_http, :media_ssrf_resolver, fn _host -> {:ok, [{93, 184, 216, 34}]} end)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_secret_at_rest, :media_config_source, :media_config_loader, :media_storage_config_writer, :media_storage_config_loader, :media_storage_env_reader, :media_storage_test_connection_fun, :media_files_storage_key_count_fun, :media_ssrf_resolver] do
        Application.delete_env(:nebu_http, k)
      end

      Application.delete_env(:compliance, :repo)
      Application.delete_env(:compliance, :__test_storage_save_pid__)
    end)

    :ok
  end

  # The persisted row: endpoint 93.184.216.34:9000 (http), credentials stored.
  defp stored_row(extra \\ %{}) do
    Map.merge(
      %{
        "endpoint" => @stored_endpoint,
        "bucket" => "media-bucket",
        "region" => "us-east-1",
        "use_ssl" => false,
        "access_key_encrypted" => Nebu.Web.SecretBox.encrypt("STOREDAKID0502"),
        "secret_key_encrypted" => Nebu.Web.SecretBox.encrypt("stored-secret-0502"),
        "s3_key_prefix_template" => "{media_id}",
        "archive_bucket" => nil,
        "iam_endpoint" => nil,
        "sts_endpoint" => nil
      },
      extra
    )
  end

  # What the form posts for the stored target (blank keys = leave the stored ones).
  defp form(overrides \\ %{}) do
    Map.merge(
      %{
        "endpoint" => @stored_endpoint,
        "bucket" => "media-bucket",
        "region" => "us-east-1",
        "use_ssl" => "false",
        "access_key" => "",
        "secret_key" => "",
        "s3_key_prefix_template" => "{media_id}",
        "archive_bucket" => "",
        "iam_endpoint" => "",
        "sts_endpoint" => ""
      },
      overrides
    )
  end

  defp admin_conn(path, params) do
    %{conn(:post, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> T.put_strict_fetch_headers()
  end

  defp with_marker(conn), do: put_session(conn, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @page))
  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))
  defp marker_kept?(conn), do: conn.private.plug_session["admin_reauth"] != nil
  defp save(params), do: admin_conn(@save, params) |> with_marker() |> call()

  defp assert_nothing_persisted do
    refute_received {:storage_written, _}
    refute_received {:audit_insert, _}
  end

  defp saved?(conn), do: conn.status in [302, 303] or (conn.status == 200 and not (conn.resp_body =~ @message))

  describe "B - a changed endpoint or Use SSL needs both keys typed in the same save" do
    test "another endpoint, blank keys: the page says to enter the keys, nothing is written or audited, the marker is kept" do
      conn = save(form(%{"endpoint" => "93.184.216.35:9000"}))

      assert conn.status == 200
      assert conn.resp_body =~ @message
      assert_nothing_persisted()
      assert marker_kept?(conn)
    end

    test "another Use SSL setting, blank keys: the same" do
      conn = save(form(%{"use_ssl" => "true"}))

      assert conn.status == 200
      assert conn.resp_body =~ @message
      assert_nothing_persisted()
      assert marker_kept?(conn)
    end

    test "another endpoint with only one key typed: the same" do
      for keys <- [%{"access_key" => "NEWAKID0502"}, %{"secret_key" => "new-secret-0502"}] do
        conn = save(form(Map.put(keys, "endpoint", "93.184.216.35:9000")))
        assert conn.status == 200
        assert conn.resp_body =~ @message
      end

      assert_nothing_persisted()
    end

    test "another endpoint WITH both keys: saved, the keys are written (encrypted), the marker is consumed" do
      conn = save(form(%{"endpoint" => "93.184.216.35:9000", "access_key" => "NEWAKID0502", "secret_key" => "new-secret-0502"}))

      assert saved?(conn)
      refute conn.resp_body =~ @message
      assert_received {:storage_written, columns}
      assert columns["endpoint"] == "93.184.216.35:9000"
      assert is_binary(columns["access_key_encrypted"]) and columns["access_key_encrypted"] != "NEWAKID0502"
      assert is_binary(columns["secret_key_encrypted"]) and columns["secret_key_encrypted"] != "new-secret-0502"
      refute marker_kept?(conn)
    end

    test "unchanged endpoint and Use SSL, blank keys, changed bucket: saved, the stored credentials are left alone" do
      conn = save(form(%{"bucket" => "renamed-bucket"}))

      assert saved?(conn)
      assert_received {:storage_written, columns}
      assert columns["bucket"] == "renamed-bucket"
      refute Map.has_key?(columns, "access_key_encrypted")
      refute Map.has_key?(columns, "secret_key_encrypted")
      refute marker_kept?(conn)
    end

    test "fresh config (no row): an endpoint other than the environment's needs the keys as well" do
      Application.put_env(:nebu_http, :media_storage_config_loader, fn -> nil end)
      Application.put_env(:nebu_http, :media_storage_env_reader, fn -> %{"NEBU_MINIO_ENDPOINT" => "93.184.216.36:9000"} end)

      conn = save(form())

      assert conn.status == 200
      assert conn.resp_body =~ @message
      assert_nothing_persisted()

      assert saved?(save(form(%{"access_key" => "NEWAKID0502", "secret_key" => "new-secret-0502"})))
      assert_received {:storage_written, _}
    end
  end

  describe "D - endpoints the operational parser rejects" do
    for endpoint <- ["93.184.216.34:9000/", "93.184.216.34:9000/path", "[2001:db8::1]:9000", "93.184.216.34:0", "93.184.216.34:65536", "93.184.216.34:abc"] do
      test "the save rejects #{endpoint}: the page re-renders, nothing is written or audited" do
        conn = save(form(%{"endpoint" => unquote(endpoint), "access_key" => "NEWAKID0502", "secret_key" => "new-secret-0502"}))

        assert conn.status == 200
        assert conn.resp_body =~ ~s(role="alert")
        refute conn.resp_body =~ "Storage settings saved"
        assert_nothing_persisted()
        assert marker_kept?(conn)
      end

      test "Test Connection rejects #{endpoint}: an alert, the request function is never called" do
        conn = admin_conn(@test_connection, form(%{"endpoint" => unquote(endpoint), "access_key" => "NEWAKID0502", "secret_key" => "new-secret-0502"})) |> call()

        assert conn.status == 200
        assert conn.resp_body =~ ~s(role="alert")
        refute_received {:tested, _}
      end
    end

    test "valid endpoints keep working: host, host:port, uppercase host" do
      for endpoint <- ["93.184.216.40", "93.184.216.40:9000", "STORAGE.Example.TEST:9000"] do
        conn = save(form(%{"endpoint" => endpoint, "access_key" => "NEWAKID0502", "secret_key" => "new-secret-0502"}))
        assert saved?(conn), endpoint
        assert_received {:storage_written, %{"endpoint" => ^endpoint}}
      end
    end
  end
end
