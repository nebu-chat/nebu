defmodule Nebu.Admin.MediaSettingsStorageAuditTest do
  @moduledoc """
  Two details of the storage settings form (story `media-storage-uses-admin-config`; setup as
  `Nebu.Admin.MediaSettingsStorageErrorsTest`):

  * The audit entry of a save through the controller names only the fields that really changed. A pure key rotation (endpoint and
    Use SSL equal the stored row, although the controller writes them next to the keys) names `access_key` and `secret_key` only; a
    changed endpoint names the endpoint (and the keys); a Use SSL toggle names `use_ssl` (and the keys); a bucket-only change names
    the bucket only. Names only, never values.
  * The reason shown for a rejected endpoint is computed from the TRIMMED submitted value: a private IP literal with a leading or
    trailing space gets the private-address reason, not a DNS one (Save and Test Connection).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Media.StorageAdminTargetSupport, as: S
  alias Nebu.Media.StorageConfig
  alias Nebu.OAuth.TestSupport, as: T

  Code.require_file("../media/storage_admin_target_support.exs", __DIR__)

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-storage-audit-test-key-base", 2)
  @page "/admin/media/settings"
  @save "/admin/media/settings/storage"
  @test_connection "/admin/media/settings/storage/test-connection"

  @stored_endpoint "93.184.216.34:9000"
  @other_endpoint "93.184.216.35:9000"

  defmodule FakeAuditRepo do
    @moduledoc false
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_storage_audit_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  setup do
    S.isolate!()
    test_pid = self()
    S.put_env_scoped(:nebu_http, :admin_csrf_bypass, true)
    S.put_env_scoped(:compliance, :repo, FakeAuditRepo)
    S.put_env_scoped(:compliance, :__test_storage_audit_pid__, test_pid)
    S.put_env_scoped(:nebu_http, :media_config_source, fn -> %{} end)
    S.put_env_scoped(:nebu_http, :media_files_storage_key_count_fun, fn -> 0 end)
    S.put_env_scoped(:nebu_http, :media_storage_allow_private_endpoints, false)

    {:ok, store} = Agent.start_link(fn -> S.saved_row(%{endpoint: @stored_endpoint, use_ssl: false, bucket: "stored-bucket", region: "stored-region", access_key: "STOREDAKID1601", secret_key: "stored-secret-1601"}) end)
    S.put_env_scoped(:nebu_http, :media_storage_config_loader, fn -> Agent.get(store, & &1) end)

    S.put_env_scoped(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      Agent.update(store, &Map.merge(&1, columns))
      send(test_pid, {:storage_written, columns})
      :ok
    end)

    S.put_env_scoped(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
      send(test_pid, {:tested, candidate})
      :ok
    end)

    S.install_env(%{})
    {:ok, store: store}
  end

  defp form(overrides) do
    Map.merge(
      %{
        "endpoint" => @stored_endpoint,
        "bucket" => "stored-bucket",
        "region" => "stored-region",
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
  defp save(params), do: admin_conn(@save, params) |> with_marker() |> call()

  defp changed_fields do
    assert_received {:audit_insert, entry}
    printed = inspect(entry.metadata)

    for value <- [@stored_endpoint, @other_endpoint, "NEWAKID1601", "new-secret-1601", "renamed-bucket"] do
      refute printed =~ value, "a value (#{value}) is in the audit metadata: #{printed}"
    end

    Enum.sort(entry.metadata.changed_fields)
  end

  @keys %{"access_key" => "NEWAKID1601", "secret_key" => "new-secret-1601"}

  describe "X - the audit entry of a save names only what really changed" do
    test "a pure key rotation: the two keys only" do
      conn = save(form(@keys))
      assert conn.status in [302, 303]
      assert_received {:storage_written, columns}
      assert columns["endpoint"] == @stored_endpoint, "the keys are still written next to the endpoint"
      assert changed_fields() == [:access_key, :secret_key]
    end

    test "a changed endpoint with the keys: endpoint and keys" do
      assert save(form(Map.put(@keys, "endpoint", @other_endpoint))).status in [302, 303]
      assert changed_fields() == [:access_key, :endpoint, :secret_key]
    end

    test "a Use SSL toggle with the keys: use_ssl and keys" do
      assert save(form(Map.put(@keys, "use_ssl", "true"))).status in [302, 303]
      assert changed_fields() == [:access_key, :secret_key, :use_ssl]
    end

    test "a bucket-only change without keys: the bucket only" do
      assert save(form(%{"bucket" => "renamed-bucket"})).status in [302, 303]
      assert changed_fields() == [:bucket]
    end
  end

  describe "Y - the rejected-endpoint reason comes from the trimmed value" do
    for {label, endpoint} <- [{"leading space", " 10.0.0.5:9000"}, {"trailing space", "10.0.0.5:9000 "}, {"both", "  10.0.0.5:9000  "}] do
      test "Save, #{label}: the private-address reason" do
        conn = save(form(Map.merge(@keys, %{"endpoint" => unquote(endpoint)})))

        assert conn.status == 200
        {:ok, doc} = Floki.parse_document(conn.resp_body)
        text = doc |> Floki.find("p#media-storage-error") |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()

        assert text == StorageConfig.describe_invalid_endpoint("10.0.0.5:9000")
        assert text =~ "private"
        refute text =~ ~r/DNS|resolved|nxdomain/i
        refute_received {:storage_written, _}
      end

      test "Test Connection, #{label}: the private-address reason" do
        conn = admin_conn(@test_connection, form(Map.merge(@keys, %{"endpoint" => unquote(endpoint)}))) |> call()

        assert conn.status == 200
        {:ok, doc} = Floki.parse_document(conn.resp_body)
        texts = doc |> Floki.find("p[role=alert]") |> Enum.map(&(&1 |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

        assert StorageConfig.describe_invalid_endpoint("10.0.0.5:9000") in texts
        refute_received {:tested, _}
      end
    end
  end
end
