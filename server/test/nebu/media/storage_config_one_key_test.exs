defmodule Nebu.Media.StorageConfigOneKeyTest do
  @moduledoc """
  `Nebu.Media.StorageConfig.upsert/2` and a lone key (story `media-storage-uses-admin-config`): a fields map that mentions
  exactly ONE of `:access_key` / `:secret_key` is `{:error, :key_pair_required}`, whether that key is non-blank, `nil` or
  blank, also for direct callers: `%{secret_key: nil}` alone neither clears a key nor writes an empty ciphertext. A map with
  BOTH keys `nil` is legal (it clears the pair); a map with neither key is unaffected. Nothing is written or audited on
  the error.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter: reports every insert to the test process."
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_one_key_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  setup do
    T.isolate!()
    test_pid = self()
    T.put_env_scoped(:compliance, :repo, FakeAuditRepo)
    T.put_env_scoped(:compliance, :__test_one_key_pid__, test_pid)
    T.put_env_scoped(:nebu_http, :media_storage_config_writer, fn columns, _set_at -> send(test_pid, {:written, columns}); :ok end)
    T.install_env(%{"NEBU_MINIO_ENDPOINT" => "93.184.216.34:9000"})
    T.install_row(T.saved_row(%{endpoint: "93.184.216.34:9000", use_ssl: false, bucket: "b", region: "r", access_key: "STOREDAKID1401", secret_key: "stored-secret-1401"}))
    :ok
  end

  defp assert_nothing_persisted do
    refute_received {:written, _}
    refute_received {:audit_insert, _}
  end

  test "exactly one key mentioned, non-blank, nil or blank: {:error, :key_pair_required}, nothing written or audited" do
    for fields <- [%{secret_key: nil}, %{access_key: nil}, %{access_key: ""}, %{secret_key: ""}, %{access_key: "NEWAKID1401"}, %{secret_key: "new-secret-1401"}, %{bucket: "b2", secret_key: nil}] do
      assert {:error, :key_pair_required} = StorageConfig.upsert(fields), inspect(fields)
    end

    assert_nothing_persisted()
  end

  test "one key non-blank and the other nil or blank: {:error, :key_pair_required}" do
    for fields <- [%{access_key: "NEWAKID1401", secret_key: nil}, %{access_key: nil, secret_key: "new-secret-1401"}, %{access_key: "NEWAKID1401", secret_key: ""}, %{access_key: "", secret_key: "new-secret-1401"}] do
      assert {:error, :key_pair_required} = StorageConfig.upsert(fields), inspect(fields)
    end

    assert_nothing_persisted()
  end

  test "both keys nil is legal: the pair is cleared" do
    assert :ok = StorageConfig.upsert(%{access_key: nil, secret_key: nil})
    assert_received {:written, %{"access_key_encrypted" => nil, "secret_key_encrypted" => nil}}
  end

  test "both keys non-blank is legal, a map with neither key is unaffected" do
    assert :ok = StorageConfig.upsert(%{access_key: "NEWAKID1401", secret_key: "new-secret-1401"})
    assert_received {:written, %{"access_key_encrypted" => _, "secret_key_encrypted" => _}}

    assert :ok = StorageConfig.upsert(%{bucket: "renamed-bucket"})
    assert_received {:written, columns}
    refute Map.has_key?(columns, "access_key_encrypted")
  end
end
