defmodule Nebu.Media.StorageConfigKeyRulesTest do
  @moduledoc """
  The key rules of `Nebu.Media.StorageConfig` on the save path and in Test Connection (story
  `media-storage-uses-admin-config`; the controller side is `Nebu.Admin.MediaSettingsFreshSaveTest`).

  * Half a key pair: `upsert/2` returns `{:error, :key_pair_required}` (nothing written or audited) when a save would write
    exactly ONE non-blank key (the other one nil, blank or absent). A changed endpoint / Use SSL with one key keeps the
    earlier `{:error, :secret_required}`.
  * Test Connection resolves the stored credentials for blank form keys by the SAME rule as the operational path: the row's
    own pair; both NULL and the row's endpoint / Use SSL equal to the environment's own target: the environment credentials;
    anything else (another endpoint, half pair, undecryptable): `{:error, :secret_required}` and the test function is never
    called. Typed keys are always used.
  * The save-time key check compares with a strict, fresh read of the row that is being written, never with the cached
    snapshot: a stale cache can neither let a changed endpoint keep the old keys nor reject an unchanged one; when the row
    cannot be read the save fails closed with `{:error, :storage_config_unavailable}` and the writer is not called.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter: reports every insert to the test process."
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_key_rules_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  @env_endpoint "93.184.216.34:9000"
  @other_endpoint "93.184.216.35:9000"

  setup do
    T.isolate!()
    test_pid = self()
    T.put_env_scoped(:compliance, :repo, FakeAuditRepo)
    T.put_env_scoped(:compliance, :__test_key_rules_pid__, test_pid)

    T.put_env_scoped(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      send(test_pid, {:written, columns})
      :ok
    end)

    T.put_env_scoped(:nebu_http, :media_storage_test_connection_fun, fn candidate ->
      send(test_pid, {:tested, candidate})
      :ok
    end)

    T.install_env(%{"NEBU_MINIO_ENDPOINT" => @env_endpoint, "NEBU_MINIO_USE_SSL" => "false", "NEBU_MINIO_ACCESS_KEY" => "ENVAKIDKEYRULES0801", "NEBU_MINIO_SECRET_KEY" => "env-secret-keyrules-0801"})
    :ok
  end

  defp row(extra), do: T.saved_row(Map.merge(%{use_ssl: false, bucket: "stored-bucket", region: "r"}, extra))

  defp candidate(endpoint, extra \\ %{}) do
    Map.merge(%{endpoint: endpoint, bucket: "b", region: "r", use_ssl: false, access_key: "", secret_key: ""}, extra)
  end

  defp assert_nothing_persisted do
    refute_received {:written, _}
    refute_received {:audit_insert, _}
  end

  describe "upsert: exactly one key is never saved" do
    setup do
      T.install_row(row(%{endpoint: @env_endpoint, access_key: "STOREDAKID0801", secret_key: "stored-secret-0801"}))
      :ok
    end

    test "one non-blank key (the other nil, blank or absent): {:error, :key_pair_required}, nothing written or audited" do
      for keys <- [%{access_key: "NEWAKID0801"}, %{secret_key: "new-secret-0801"}, %{access_key: "NEWAKID0801", secret_key: ""}, %{access_key: "NEWAKID0801", secret_key: nil}, %{access_key: "", secret_key: "new-secret-0801"}] do
        assert {:error, :key_pair_required} = StorageConfig.upsert(Map.put(keys, :bucket, "renamed-bucket")), inspect(keys)
      end

      assert_nothing_persisted()
    end

    test "the same with an unchanged endpoint in the same save" do
      assert {:error, :key_pair_required} = StorageConfig.upsert(%{endpoint: @env_endpoint, access_key: "NEWAKID0801"})
      assert_nothing_persisted()
    end

    test "a changed endpoint with one key keeps the earlier answer {:error, :secret_required}" do
      assert {:error, :secret_required} = StorageConfig.upsert(%{endpoint: @other_endpoint, access_key: "NEWAKID0801"})
      assert_nothing_persisted()
    end

    test "both keys, or no key: saved" do
      assert :ok = StorageConfig.upsert(%{bucket: "renamed-bucket", access_key: "NEWAKID0801", secret_key: "new-secret-0801"})
      assert_received {:written, %{"access_key_encrypted" => _, "secret_key_encrypted" => _}}

      assert :ok = StorageConfig.upsert(%{bucket: "renamed-again"})
      assert_received {:written, columns}
      refute Map.has_key?(columns, "access_key_encrypted")
    end
  end

  describe "Test Connection: blank form keys use the stored credentials by the operational rule" do
    test "another endpoint than the environment's, NULL keys, environment keys set: :secret_required, the test function is never called" do
      T.install_row(row(%{endpoint: @other_endpoint}))
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(@other_endpoint))
      refute_received {:tested, _}
    end

    test "undecryptable stored keys: :secret_required" do
      T.install_row(row(%{endpoint: @other_endpoint}) |> Map.put("access_key_encrypted", T.corrupt_ciphertext()) |> Map.put("secret_key_encrypted", T.corrupt_ciphertext()))
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(@other_endpoint))
      refute_received {:tested, _}
    end

    test "a half stored pair: :secret_required" do
      T.install_row(row(%{endpoint: @other_endpoint, access_key: "STOREDAKID0801"}))
      assert {:error, :secret_required} = StorageConfig.test_connection(candidate(@other_endpoint))
      refute_received {:tested, _}
    end

    test "the row's endpoint equals the environment's own target and the keys are NULL: the environment credentials are used" do
      T.install_row(row(%{endpoint: @env_endpoint}))
      assert :ok = StorageConfig.test_connection(candidate(@env_endpoint))
      assert_received {:tested, %{access_key: "ENVAKIDKEYRULES0801", secret_key: "env-secret-keyrules-0801"}}
    end

    test "no row at all, the environment's endpoint: the environment credentials (unchanged)" do
      T.install_row(nil)
      assert :ok = StorageConfig.test_connection(candidate(@env_endpoint))
      assert_received {:tested, %{access_key: "ENVAKIDKEYRULES0801"}}
    end

    test "stored keys of the stored endpoint are used for blank form keys" do
      T.install_row(row(%{endpoint: @other_endpoint, access_key: "STOREDAKID0801", secret_key: "stored-secret-0801"}))
      assert :ok = StorageConfig.test_connection(candidate(@other_endpoint))
      assert_received {:tested, %{access_key: "STOREDAKID0801", secret_key: "stored-secret-0801"}}
    end

    test "typed keys are always used" do
      T.install_row(row(%{endpoint: @other_endpoint}))
      assert :ok = StorageConfig.test_connection(candidate(@other_endpoint, %{access_key: "TYPEDAKID0801", secret_key: "typed-secret-0801"}))
      assert_received {:tested, %{access_key: "TYPEDAKID0801", secret_key: "typed-secret-0801"}}
    end
  end

  describe "the save-time key check reads the row being written, strictly and fresh" do
    defp start_loader(initial) do
      {:ok, agent} = Agent.start_link(fn -> initial end)

      T.put_env_scoped(:nebu_http, :media_storage_config_loader, fn ->
        case Agent.get(agent, & &1) do
          {:ok, row} -> row
          :error_tuple -> {:error, :db_down}
          :raise -> raise "db down"
        end
      end)

      agent
    end

    defp start_cache do
      case StorageConfig.start_link() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    defp keyed_row(endpoint), do: row(%{endpoint: endpoint, access_key: "KEY-#{endpoint}-0801", secret_key: "secret-#{endpoint}-0801"})

    test "the cache says A, the database row says B: a save of A without keys changes B -> A and is rejected" do
      agent = start_loader({:ok, keyed_row(@env_endpoint)})
      start_cache()
      assert StorageConfig.get().endpoint == @env_endpoint

      Agent.update(agent, fn _ -> {:ok, keyed_row(@other_endpoint)} end)
      assert StorageConfig.get().endpoint == @env_endpoint, "the cache is stale on purpose"

      assert {:error, :secret_required} = StorageConfig.upsert(%{endpoint: @env_endpoint})
      assert_nothing_persisted()
    end

    test "the cache says B, the database row says A: a save of A (unchanged) without keys is fine" do
      agent = start_loader({:ok, keyed_row(@other_endpoint)})
      start_cache()
      Agent.update(agent, fn _ -> {:ok, keyed_row(@env_endpoint)} end)

      assert :ok = StorageConfig.upsert(%{endpoint: @env_endpoint, bucket: "renamed-bucket"})
      assert_received {:written, _}
    end

    test "with both keys the stale cache does not matter" do
      agent = start_loader({:ok, keyed_row(@env_endpoint)})
      start_cache()
      Agent.update(agent, fn _ -> {:ok, keyed_row(@other_endpoint)} end)

      assert :ok = StorageConfig.upsert(%{endpoint: @env_endpoint, access_key: "NEWAKID0801", secret_key: "new-secret-0801"})
    end

    for mode <- [:error_tuple, :raise] do
      test "the row cannot be read (loader #{mode}) although the cache is healthy: an endpoint / use_ssl save fails closed" do
        agent = start_loader({:ok, keyed_row(@env_endpoint)})
        start_cache()
        Agent.update(agent, fn _ -> unquote(mode) end)

        assert {:error, :storage_config_unavailable} = StorageConfig.upsert(%{endpoint: @env_endpoint})
        assert {:error, :storage_config_unavailable} = StorageConfig.upsert(%{use_ssl: true})
        assert_nothing_persisted()
      end
    end

    test "no cache at all and an unreadable row: the same" do
      start_loader(:error_tuple)
      assert {:error, :storage_config_unavailable} = StorageConfig.upsert(%{endpoint: @env_endpoint})
      assert_nothing_persisted()
    end
  end
end
