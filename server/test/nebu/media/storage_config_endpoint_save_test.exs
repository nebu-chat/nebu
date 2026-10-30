defmodule Nebu.Media.StorageConfigEndpointSaveTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, fixes B and D at the `Nebu.Media.StorageConfig`
  level (the controller level is `Nebu.Admin.MediaSettingsStorageSaveTest`).

  ## B (Kassandra #2): a save that changes the target needs the keys

  Since the operational calls sign real traffic with the saved credentials, `upsert/2` rejects a save that changes
  `endpoint` or `use_ssl` versus the stored / effective values unless `access_key` AND `secret_key` are both given (non
  blank) in the SAME save: `{:error, :secret_required}` (the atom `test_connection/1` already uses for the same rule,
  same `same_target?` comparison: trimmed, ASCII-downcased endpoint, `use_ssl == true`). Nothing is written and no audit
  entry is made. An unchanged endpoint / `use_ssl` with no keys, or a save without either field, is untouched.

  ## D (code review MINOR-1/5): one endpoint parser for save, Test Connection and the operational path

  `upsert/2` and `test_connection/1` reject what the operational parser rejects: a path (`host:9000/`, `host:9000/x`), a
  bracketed IPv6 literal, port 0, port above 65535, a non-numeric port: `{:error, :invalid_endpoint}` (Test Connection
  never reaches its request function and never raises). Valid `host`, `host:9000` and an uppercase host are accepted.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter: reports every insert to the test process."
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_storage_save_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  @stored_endpoint "93.184.216.34:9000"
  @other_endpoint "93.184.216.35:9000"
  @invalid_endpoints [
    "93.184.216.34:9000/",
    "93.184.216.34:9000/path",
    "[2001:db8::1]:9000",
    "93.184.216.34:0",
    "93.184.216.34:65536",
    "93.184.216.34:abc"
  ]

  setup do
    T.isolate!()
    test_pid = self()
    T.put_env_scoped(:compliance, :repo, FakeAuditRepo)
    T.put_env_scoped(:compliance, :__test_storage_save_pid__, test_pid)
    T.put_env_scoped(:nebu_http, :media_ssrf_resolver, fn _host -> {:ok, [{93, 184, 216, 34}]} end)
    T.put_env_scoped(:nebu_http, :media_storage_config_writer, fn columns, _set_at -> send(test_pid, {:written, columns}); :ok end)
    T.install_env(%{})
    :ok
  end

  defp install_stored(extra \\ %{}) do
    T.install_row(T.saved_row(Map.merge(%{endpoint: @stored_endpoint, use_ssl: false, region: "r", bucket: "stored-bucket", access_key: "STOREDAKID0501", secret_key: "stored-secret-0501"}, extra)))
  end

  defp assert_nothing_persisted do
    refute_received {:written, _}
    refute_received {:audit_insert, _}
  end

  describe "B - a changed endpoint or use_ssl needs both keys in the same save" do
    test "changed endpoint, no keys: {:error, :secret_required}, no write, no audit entry" do
      install_stored()
      assert {:error, :secret_required} = StorageConfig.upsert(%{endpoint: @other_endpoint})
      assert_nothing_persisted()
    end

    test "changed use_ssl, no keys: {:error, :secret_required}" do
      install_stored()
      assert {:error, :secret_required} = StorageConfig.upsert(%{use_ssl: true})
      assert_nothing_persisted()
    end

    test "changed endpoint with only one key (or blank / nil keys): {:error, :secret_required}" do
      install_stored()

      for keys <- [%{access_key: "NEWAKID0501"}, %{secret_key: "new-secret-0501"}, %{access_key: "NEWAKID0501", secret_key: ""}, %{access_key: "", secret_key: ""}, %{access_key: nil, secret_key: nil}] do
        assert {:error, :secret_required} = StorageConfig.upsert(Map.put(keys, :endpoint, @other_endpoint)), inspect(keys)
      end

      assert_nothing_persisted()
    end

    test "changed endpoint together with a changed bucket and no keys is rejected as well" do
      install_stored()
      assert {:error, :secret_required} = StorageConfig.upsert(%{endpoint: @other_endpoint, bucket: "other-bucket"})
      assert_nothing_persisted()
    end

    test "changed endpoint WITH both keys: saved, the keys are stored encrypted" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{endpoint: @other_endpoint, access_key: "NEWAKID0501", secret_key: "new-secret-0501"})

      assert_received {:written, columns}
      assert columns["endpoint"] == @other_endpoint
      assert is_binary(columns["access_key_encrypted"]) and columns["access_key_encrypted"] != "NEWAKID0501"
      assert is_binary(columns["secret_key_encrypted"]) and columns["secret_key_encrypted"] != "new-secret-0501"
      assert_received {:audit_insert, _}
    end

    test "changed use_ssl WITH both keys: saved" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{use_ssl: true, access_key: "NEWAKID0501", secret_key: "new-secret-0501"})
      assert_received {:written, %{"use_ssl" => true}}
    end

    test "unchanged endpoint and use_ssl, no keys, changed bucket: saved, the stored credentials are untouched" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{endpoint: @stored_endpoint, use_ssl: false, bucket: "renamed-bucket"})

      assert_received {:written, columns}
      assert columns["bucket"] == "renamed-bucket"
      refute Map.has_key?(columns, "access_key_encrypted")
      refute Map.has_key?(columns, "secret_key_encrypted")
    end

    test "the endpoint comparison ignores case (the Test Connection rule): not a change" do
      install_stored(%{endpoint: "Storage.Example.Test:9000"})
      assert :ok = StorageConfig.upsert(%{endpoint: "storage.example.test:9000", bucket: "renamed-bucket"})
      assert_received {:written, _}
    end

    test "a save without endpoint and use_ssl (bucket only) needs no keys" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{bucket: "renamed-bucket"})
      assert_received {:written, _}
    end

    test "fresh config (no row): the effective endpoint is the environment's, so another endpoint needs the keys too" do
      T.install_row(nil)
      T.install_env(%{"NEBU_MINIO_ENDPOINT" => @stored_endpoint})

      assert {:error, :secret_required} = StorageConfig.upsert(%{endpoint: @other_endpoint})
      assert_nothing_persisted()
      assert :ok = StorageConfig.upsert(%{endpoint: @other_endpoint, access_key: "NEWAKID0501", secret_key: "new-secret-0501"})
    end

    test "fresh config: the environment's own endpoint and use_ssl, no keys: saved (not a change)" do
      T.install_row(nil)
      T.install_env(%{"NEBU_MINIO_ENDPOINT" => @stored_endpoint, "NEBU_MINIO_USE_SSL" => "false"})

      assert :ok = StorageConfig.upsert(%{endpoint: @stored_endpoint, use_ssl: false, bucket: "first-bucket"})
      assert_received {:written, _}
    end
  end

  describe "D - save and Test Connection use the operational endpoint parser" do
    for endpoint <- @invalid_endpoints do
      test "upsert rejects #{endpoint}: {:error, :invalid_endpoint}, nothing written" do
        T.install_row(nil)

        assert {:error, :invalid_endpoint} =
                 StorageConfig.upsert(%{endpoint: unquote(endpoint), access_key: "NEWAKID0502", secret_key: "new-secret-0502"})

        assert_nothing_persisted()
      end

      test "test_connection rejects #{endpoint}: {:error, :invalid_endpoint}, the request function is never called and nothing raises" do
        T.install_row(nil)
        test_pid = self()
        T.put_env_scoped(:nebu_http, :media_storage_test_connection_fun, fn candidate -> send(test_pid, {:tested, candidate}); :ok end)

        candidate = %{endpoint: unquote(endpoint), bucket: "b", region: "r", use_ssl: false, access_key: "NEWAKID0502", secret_key: "new-secret-0502"}
        assert {:error, :invalid_endpoint} = StorageConfig.test_connection(candidate)
        refute_received {:tested, _}
      end
    end

    for endpoint <- ["93.184.216.34", "93.184.216.34:9000", "STORAGE.Example.TEST", "Storage.Example.Test:9000"] do
      test "upsert accepts the valid endpoint #{endpoint}" do
        T.install_row(nil)

        assert :ok = StorageConfig.upsert(%{endpoint: unquote(endpoint), access_key: "NEWAKID0502", secret_key: "new-secret-0502"})
        assert_received {:written, %{"endpoint" => unquote(endpoint)}}
      end

      test "test_connection accepts the valid endpoint #{endpoint}" do
        T.install_row(nil)
        test_pid = self()
        T.put_env_scoped(:nebu_http, :media_storage_test_connection_fun, fn candidate -> send(test_pid, {:tested, candidate.endpoint}); :ok end)

        candidate = %{endpoint: unquote(endpoint), bucket: "b", region: "r", use_ssl: false, access_key: "NEWAKID0502", secret_key: "new-secret-0502"}
        assert :ok = StorageConfig.test_connection(candidate)
        assert_received {:tested, unquote(endpoint)}
      end
    end
  end
end
