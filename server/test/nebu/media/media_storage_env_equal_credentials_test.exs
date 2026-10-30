defmodule Nebu.Media.MediaStorageEnvEqualCredentialsTest do
  @moduledoc """
  The credential rule for a saved row whose endpoint equals the environment's own target, and what the settings page
  shows for the keys (story `media-storage-uses-admin-config`).

  * A saved endpoint is only ever used with the credentials saved with it. The one exception: when the row's endpoint
    and Use SSL setting are the SAME target as the environment's own (`NEBU_MINIO_ENDPOINT` / `NEBU_MINIO_USE_SSL`,
    compared like Test Connection does: trimmed, ASCII-downcased endpoint, `use_ssl == true`) and both saved keys are
    NULL, the `NEBU_MINIO_*` credentials are used, because they belong to exactly that target (a first save that only
    changed the bucket, region or key prefix template; legacy rows saved before the keys mattered).
  * A row whose endpoint differs from the environment's own, a half-saved key pair and undecryptable keys fail closed with
    `{:error, :storage_credentials_missing}`; the environment credentials are never used and nothing is sent.
  * If the environment endpoint later changes so that it no longer matches, the row fails closed again.
  * `Nebu.Media.StorageConfig.get/0` (what the settings page shows) reports the credentials the operational path would
    use: no key when it would fail closed, no log line that claims a fallback to the environment credentials.

  The requests are recorded by the recording ExAws client (the endpoint is a name that only the SSRF seam resolves);
  a real decoy stub at the boot-time endpoint must stay untouched.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  @env_endpoint "storage.example.test:9000"
  @env_akid "ENVAKIDCANARY0701"
  @env_secret "env-secret-canary-0701"
  @row_akid "ROWAKIDCANARY0702"
  @row_secret "row-secret-canary-0703"

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    T.use_recording_client!()
    install_env(@env_endpoint)
    :ok
  end

  defp install_env(endpoint, extra \\ %{}) do
    T.install_env(
      Map.merge(
        %{
          "NEBU_MINIO_ENDPOINT" => endpoint,
          "NEBU_MINIO_USE_SSL" => "false",
          "NEBU_S3_REGION" => "env-region-1",
          "NEBU_MINIO_ACCESS_KEY" => @env_akid,
          "NEBU_MINIO_SECRET_KEY" => @env_secret
        },
        extra
      )
    )
  end

  defp row(extra) do
    T.saved_row(Map.merge(%{use_ssl: false, bucket: "row-bucket", region: "row-region-1"}, extra))
  end

  defp akid(headers) do
    auth = Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "authorization", do: v end) || ""
    case Regex.run(~r/Credential=([^\/]+)\//, auth) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp assert_all_signed_with(expected_akid) do
    for {name, fun, _expect} <- T.operations() do
      result = fun.()
      refute match?({:error, _}, result), "#{name} failed: #{inspect(result)}"
      assert_receive {:http_request, _method, url, headers, _size}, 1_000, "#{name}: no request"
      assert akid(headers) == expected_akid, "#{name}: signed with #{inspect(akid(headers))}"
      assert String.downcase(URI.parse(url).host) == "storage.example.test"
    end
  end

  defp assert_all_fail_closed do
    for {name, fun, _expect} <- T.operations() do
      assert fun.() == {:error, :storage_credentials_missing}, "#{name} must fail closed"
    end

    refute_receive {:http_request, _, _, _, _}, 50
    refute_receive {:s3_accepted, :decoy}, 50
    refute_receive {:s3_request, :decoy, _}, 50
  end

  describe "a row whose endpoint and Use SSL equal the environment's own target" do
    test "NULL keys: the environment credentials sign all five operations" do
      T.install_row(row(%{endpoint: @env_endpoint}))
      assert_all_signed_with(@env_akid)
    end

    test "the comparison ignores the case of the endpoint (a legacy row saved as typed)" do
      T.install_row(row(%{endpoint: "Storage.Example.TEST:9000"}))
      assert_all_signed_with(@env_akid)
    end

    test "a NULL use_ssl column follows the environment's value: still the same target" do
      T.install_row(T.saved_row(%{endpoint: @env_endpoint, bucket: "row-bucket"}))
      assert_all_signed_with(@env_akid)
    end

    test "both keys saved: the saved keys win" do
      T.install_row(row(%{endpoint: @env_endpoint, access_key: @row_akid, secret_key: @row_secret}))
      assert_all_signed_with(@row_akid)
    end

    test "only one key saved: fail closed" do
      T.install_row(row(%{endpoint: @env_endpoint, access_key: @row_akid}))
      assert_all_fail_closed()
      T.install_row(row(%{endpoint: @env_endpoint, secret_key: @row_secret}))
      assert_all_fail_closed()
    end

    test "undecryptable keys: fail closed" do
      T.install_row(row(%{endpoint: @env_endpoint}) |> Map.put("access_key_encrypted", T.corrupt_ciphertext()) |> Map.put("secret_key_encrypted", T.corrupt_ciphertext()))
      assert_all_fail_closed()
    end
  end

  describe "a row whose endpoint is another target than the environment's" do
    test "NULL keys and environment keys set: fail closed, nothing is sent anywhere" do
      T.install_row(row(%{endpoint: "other.example.test:9000"}))
      assert_all_fail_closed()
    end

    test "same endpoint but another Use SSL setting is another target: fail closed" do
      T.install_row(row(%{endpoint: @env_endpoint, use_ssl: true}))
      assert_all_fail_closed()
    end

    test "same host on another port is another target: fail closed" do
      T.install_row(row(%{endpoint: "storage.example.test:9001"}))
      assert_all_fail_closed()
    end
  end

  describe "the environment target changes after the row was saved" do
    test "a row that matched no longer does after NEBU_MINIO_ENDPOINT changed: fail closed again" do
      T.install_row(row(%{endpoint: @env_endpoint}))
      assert_all_signed_with(@env_akid)

      install_env("moved.example.test:9000")
      assert_all_fail_closed()
    end

    test "the same after NEBU_MINIO_USE_SSL changed" do
      T.install_row(row(%{endpoint: @env_endpoint}))
      assert_all_signed_with(@env_akid)

      install_env(@env_endpoint, %{"NEBU_MINIO_USE_SSL" => "true"})
      assert_all_fail_closed()
    end

    test "a row with its own keys keeps working when the environment endpoint changes" do
      T.install_row(row(%{endpoint: @env_endpoint, access_key: @row_akid, secret_key: @row_secret}))
      install_env("moved.example.test:9000")
      assert_all_signed_with(@row_akid)
    end
  end

  describe "StorageConfig.get/0 (the settings page) reports the credentials the operational path would use" do
    test "other endpoint, NULL keys, environment keys set: no key is shown" do
      T.install_row(row(%{endpoint: "other.example.test:9000"}))
      cfg = StorageConfig.get()
      assert cfg.access_key == nil
      assert cfg.secret_key == nil
    end

    test "undecryptable keys: no key is shown and no log line claims a fallback to the environment credentials" do
      logger_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: logger_level) end)

      T.install_row(row(%{endpoint: "other.example.test:9000"}) |> Map.put("access_key_encrypted", T.corrupt_ciphertext()) |> Map.put("secret_key_encrypted", T.corrupt_ciphertext()))

      log = capture_log([level: :debug], fn -> send(self(), {:cfg, StorageConfig.get()}) end)

      assert_receive {:cfg, cfg}
      assert cfg.access_key == nil and cfg.secret_key == nil
      refute log =~ ~r/fall(ing)?\s?back/i, "the decrypt warning must not claim a fallback: #{log}"
      refute log =~ T.corrupt_ciphertext()
    end

    test "the environment's own endpoint with NULL keys: the (masked) environment keys are shown, they are what is used" do
      T.install_row(row(%{endpoint: @env_endpoint}))
      cfg = StorageConfig.get()
      assert cfg.access_key == "••••0701"
      assert cfg.secret_key == "••••0701"
    end

    test "no endpoint saved, NULL keys: the (masked) environment keys (key rotation, as before)" do
      T.install_row(row(%{}))
      assert StorageConfig.get().access_key == "••••0701"
    end

    test "saved keys are shown masked" do
      T.install_row(row(%{endpoint: "other.example.test:9000", access_key: @row_akid, secret_key: @row_secret}))
      assert StorageConfig.get().access_key == "••••0702"
      assert StorageConfig.get().secret_key == "••••0703"
    end
  end
end
