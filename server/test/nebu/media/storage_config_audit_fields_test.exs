defmodule Nebu.Media.StorageConfigAuditFieldsTest do
  @moduledoc """
  The `media_storage_config_updated` audit entry of `Nebu.Media.StorageConfig.upsert/2` and blank keys (story
  `media-storage-uses-admin-config`).

  * `metadata.changed_fields` names (atoms, never values) only the fields that REALLY changed: a submitted field that equals the
    value of the freshly read row is not named (a key rotation that carries the stored endpoint and Use SSL names the two keys
    only); the keys count as changed whenever they are submitted; with no stored row every submitted field is a change.
  * Both keys blank strings (also whitespace only), or a blank string with a `nil`, mean "no keys submitted": `:ok`, no key
    column is written (no `SecretBox.encrypt("")`), the keys are not named. Both `nil` stays the explicit clear (both columns
    nil, both named); exactly one non-blank key stays `{:error, :key_pair_required}`.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter: reports every insert to the test process."
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      if pid = Application.get_env(:compliance, :__test_audit_fields_pid__), do: send(pid, {:audit_insert, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []), do: elem(insert(struct, opts), 1)
  end

  @stored_endpoint "93.184.216.34:9000"
  @other_endpoint "93.184.216.35:9000"

  setup do
    T.isolate!()
    test_pid = self()
    T.put_env_scoped(:compliance, :repo, FakeAuditRepo)
    T.put_env_scoped(:compliance, :__test_audit_fields_pid__, test_pid)

    T.put_env_scoped(:nebu_http, :media_storage_config_writer, fn columns, _set_at ->
      send(test_pid, {:written, columns})
      :ok
    end)

    T.install_env(%{})
    :ok
  end

  defp install_stored do
    T.install_row(T.saved_row(%{endpoint: @stored_endpoint, use_ssl: false, bucket: "stored-bucket", region: "stored-region", access_key: "STOREDAKID1501", secret_key: "stored-secret-1501"}))
  end

  defp changed_fields do
    assert_received {:audit_insert, entry}
    refute Map.has_key?(entry.metadata, :old_value)
    refute Map.has_key?(entry.metadata, :new_value)

    printed = inspect(entry.metadata)

    for value <- [@stored_endpoint, @other_endpoint, "NEWAKID1501", "new-secret-1501", "stored-bucket", "renamed-bucket"] do
      refute printed =~ value, "a value (#{value}) is in the audit metadata: #{printed}"
    end

    Enum.sort(entry.metadata.changed_fields)
  end

  describe "X - only the fields that really changed are named" do
    test "a key rotation that carries the stored endpoint and Use SSL names the two keys only" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{endpoint: @stored_endpoint, use_ssl: false, access_key: "NEWAKID1501", secret_key: "new-secret-1501"})
      assert changed_fields() == [:access_key, :secret_key]
    end

    test "a changed endpoint (with the keys) names the endpoint and the keys" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{endpoint: @other_endpoint, use_ssl: false, access_key: "NEWAKID1501", secret_key: "new-secret-1501"})
      assert changed_fields() == [:access_key, :endpoint, :secret_key]
    end

    test "a Use SSL toggle (with the keys) names use_ssl and the keys" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{endpoint: @stored_endpoint, use_ssl: true, access_key: "NEWAKID1501", secret_key: "new-secret-1501"})
      assert changed_fields() == [:access_key, :secret_key, :use_ssl]
    end

    test "a bucket-only change names the bucket only, also when unchanged fields are submitted along" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{endpoint: @stored_endpoint, use_ssl: false, region: "stored-region", bucket: "renamed-bucket"})
      assert changed_fields() == [:bucket]
    end

    test "with no stored row every submitted field is a change (the first save)" do
      T.install_row(nil)
      assert :ok = StorageConfig.upsert(%{endpoint: @stored_endpoint, use_ssl: false, bucket: "renamed-bucket", access_key: "NEWAKID1501", secret_key: "new-secret-1501"})
      assert changed_fields() == [:access_key, :bucket, :endpoint, :secret_key, :use_ssl]
    end

    test "the columns written are unchanged by the audit rule (a rotation still writes endpoint and use_ssl next to the keys)" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{endpoint: @stored_endpoint, use_ssl: false, access_key: "NEWAKID1501", secret_key: "new-secret-1501"})
      assert_received {:written, columns}
      assert columns["endpoint"] == @stored_endpoint and columns["use_ssl"] == false
      assert is_binary(columns["access_key_encrypted"]) and is_binary(columns["secret_key_encrypted"])
    end
  end

  describe "Z - blank keys are no keys" do
    for {label, keys} <- [
          {"both blank strings", %{access_key: "", secret_key: ""}},
          {"both whitespace only", %{access_key: "  ", secret_key: " \t "}},
          {"a blank string and nil", %{access_key: "", secret_key: nil}},
          {"nil and a blank string", %{access_key: nil, secret_key: ""}}
        ] do
      test "#{label}: :ok, no key column is written, the keys are not named" do
        install_stored()

        assert :ok = StorageConfig.upsert(Map.put(unquote(Macro.escape(keys)), :bucket, "renamed-bucket"))

        assert_received {:written, columns}
        assert columns["bucket"] == "renamed-bucket"
        refute Map.has_key?(columns, "access_key_encrypted")
        refute Map.has_key?(columns, "secret_key_encrypted")
        assert changed_fields() == [:bucket]
      end

      test "#{label} alone: :ok and no key column is written" do
        install_stored()

        assert :ok = StorageConfig.upsert(unquote(Macro.escape(keys)))

        refute_received {:written, %{"access_key_encrypted" => _}}
        refute_received {:written, %{"secret_key_encrypted" => _}}
      end
    end

    test "both nil stays the explicit clear: both columns nil, both named" do
      install_stored()
      assert :ok = StorageConfig.upsert(%{access_key: nil, secret_key: nil})
      assert_received {:written, %{"access_key_encrypted" => nil, "secret_key_encrypted" => nil}}
      assert changed_fields() == [:access_key, :secret_key]
    end

    test "exactly one non-blank key is still {:error, :key_pair_required}" do
      install_stored()

      for keys <- [%{access_key: "NEWAKID1501", secret_key: ""}, %{access_key: "NEWAKID1501", secret_key: "  "}, %{access_key: "NEWAKID1501", secret_key: nil}, %{access_key: "NEWAKID1501"}] do
        assert {:error, :key_pair_required} = StorageConfig.upsert(keys), inspect(keys)
      end

      refute_received {:written, _}
      refute_received {:audit_insert, _}
    end
  end
end
