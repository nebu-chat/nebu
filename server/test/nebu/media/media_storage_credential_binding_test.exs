defmodule Nebu.Media.MediaStorageCredentialBindingTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, fix A (Kassandra #1, code review MINOR-3):
  the credentials are bound to the SOURCE of the endpoint, and an undecryptable saved secret fails closed.

    * the effective endpoint comes from the saved row  =>  the credentials come from the saved row too. Row
      credentials NULL (either one) or undecryptable (corrupt ciphertext, wrong at-rest key)  =>  every
      `Nebu.Media.Storage` operation returns `{:error, :storage_credentials_missing}` and NO request is sent: the
      `NEBU_MINIO_*` credentials never sign a request to the saved host;
    * the saved row has NO endpoint (endpoint from env / default)  =>  row credentials win when present, else the env
      credentials (key rotation), but a row credential that cannot be decrypted is not replaced by the env ones either;
    * a decrypt failure is logged at most once per operation, without any secret or ciphertext.

  Three stubs: `:decoy` (boot-time endpoint), `:env_stub` (the endpoint of the environment), `:saved` (the saved
  endpoint). Where the test says "nothing sent", none of them may see a connection.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T

  @row_akid "ROWAKIDCANARY0101"
  @row_secret "row-secret-canary-0101"
  @env_akid "ENVAKIDCANARY0102"
  @env_secret "env-secret-canary-0102"

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    env_stub = T.start_stub(tag: :env_stub)
    saved = T.start_stub(tag: :saved)

    T.install_env(%{
      "NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub),
      "NEBU_S3_REGION" => "env-region-1",
      "NEBU_MINIO_BUCKET" => "env-bucket",
      "NEBU_MINIO_ACCESS_KEY" => @env_akid,
      "NEBU_MINIO_SECRET_KEY" => @env_secret
    })

    T.put_env_scoped(:nebu_http, :media_bucket, "env-bucket")
    {:ok, saved: saved, env_stub: env_stub}
  end

  defp saved_attrs(saved, extra \\ %{}) do
    Map.merge(
      %{endpoint: T.endpoint(saved), use_ssl: false, region: "saved-region-1", bucket: "saved-bucket", archive_bucket: "saved-archive-bucket"},
      extra
    )
  end

  defp assert_nothing_sent do
    for tag <- [:decoy, :env_stub, :saved] do
      refute_receive {:s3_accepted, ^tag}, 30
      refute_receive {:s3_request, ^tag, _}, 30
    end
  end

  defp assert_all_fail_closed do
    for {name, fun, _expect} <- T.operations() do
      assert fun.() == {:error, :storage_credentials_missing}, "#{name} must fail closed"
    end

    assert_nothing_sent()
  end

  describe "saved endpoint: the credentials must come from the saved row" do
    test "row credentials NULL, environment credentials set: all five operations fail closed, nothing is sent", %{saved: saved} do
      T.install_row(T.saved_row(saved_attrs(saved)))
      assert_all_fail_closed()
    end

    test "only the access key saved (secret key NULL): fail closed", %{saved: saved} do
      T.install_row(T.saved_row(saved_attrs(saved, %{access_key: @row_akid})))
      assert_all_fail_closed()
    end

    test "only the secret key saved (access key NULL): fail closed", %{saved: saved} do
      T.install_row(T.saved_row(saved_attrs(saved, %{secret_key: @row_secret})))
      assert_all_fail_closed()
    end

    test "the credential files of the environment (NEBU_MINIO_*_FILE) do not sign a request to the saved host either", %{saved: saved} do
      T.install_row(T.saved_row(saved_attrs(saved)))

      T.install_env(%{
        "NEBU_MINIO_ACCESS_KEY_FILE" => T.write_secret_file!(@env_akid),
        "NEBU_MINIO_SECRET_KEY_FILE" => T.write_secret_file!(@env_secret)
      })

      assert_all_fail_closed()
    end

    test "a corrupt stored access key (does not decrypt): fail closed, the environment credentials are not substituted", %{saved: saved} do
      row = T.saved_row(saved_attrs(saved, %{secret_key: @row_secret})) |> Map.put("access_key_encrypted", T.corrupt_ciphertext())
      T.install_row(row)
      assert_all_fail_closed()
    end

    test "a corrupt stored secret key: fail closed", %{saved: saved} do
      row = T.saved_row(saved_attrs(saved, %{access_key: @row_akid})) |> Map.put("secret_key_encrypted", T.corrupt_ciphertext())
      T.install_row(row)
      assert_all_fail_closed()
    end

    test "credentials stored under another at-rest key (key rotated): fail closed", %{saved: saved} do
      T.install_row(T.saved_row(saved_attrs(saved, %{access_key: @row_akid, secret_key: @row_secret})))
      T.put_env_scoped(:nebu_http, :admin_secret_at_rest, "a-different-at-rest-secret-after-rotation")
      assert_all_fail_closed()
    end

    test "intact row credentials still work (the rule only removes the substitution)", %{saved: saved} do
      T.install_row(T.saved_row(saved_attrs(saved, %{access_key: @row_akid, secret_key: @row_secret})))

      assert :ok = Nebu.Media.Storage.put("obj", "x")

      req = T.next_request!(:saved)
      assert T.credential_scope(req) == {@row_akid, "saved-region-1"}
      refute_receive {:s3_request, :env_stub, _}, 30
      refute_receive {:s3_request, :decoy, _}, 30
    end
  end

  describe "a decrypt failure is logged at most once per operation, without secrets" do
    test "both stored secrets corrupt: at most one warning/error line per call, no secret, ciphertext or environment credential in it", %{saved: saved} do
      logger_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: logger_level) end)

      T.install_row(
        T.saved_row(saved_attrs(saved))
        |> Map.put("access_key_encrypted", T.corrupt_ciphertext())
        |> Map.put("secret_key_encrypted", T.corrupt_ciphertext())
      )

      for {name, fun, _expect} <- T.operations() do
        log = capture_log([level: :debug], fn -> assert fun.() == {:error, :storage_credentials_missing} end)

        lines = Regex.scan(~r/\[(warning|error)\]/, log)
        assert length(lines) <= 1, "#{name}: expected at most one warning/error line per operation, got #{length(lines)}:\n#{log}"

        for secret <- [T.corrupt_ciphertext(), @env_akid, @env_secret, @row_akid, @row_secret] do
          refute log =~ secret, "#{name}: a secret / ciphertext appears in the log"
        end
      end

      assert_nothing_sent()
    end
  end

  describe "no endpoint in the saved row (endpoint from the environment): row credentials win, else the environment's" do
    test "row credentials present: they sign the request to the environment's endpoint" do
      T.install_row(T.saved_row(%{access_key: @row_akid, secret_key: @row_secret}))

      assert :ok = Nebu.Media.Storage.put("obj", "x")

      req = T.next_request!(:env_stub)
      assert T.credential_scope(req) == {@row_akid, "env-region-1"}
      refute_receive {:s3_request, :decoy, _}, 30
    end

    test "row without credentials (key rotation): the environment credentials sign the request" do
      T.install_row(T.saved_row(%{bucket: "env-bucket"}))

      assert :ok = Nebu.Media.Storage.put("obj", "x")

      assert T.credential_scope(T.next_request!(:env_stub)) == {@env_akid, "env-region-1"}
      refute_receive {:s3_request, :decoy, _}, 30
    end

    test "row with an undecryptable credential: fail closed, the environment credentials are not substituted" do
      T.install_row(T.saved_row(%{secret_key: @row_secret}) |> Map.put("access_key_encrypted", T.corrupt_ciphertext()))
      assert_all_fail_closed()
    end

    test "no row at all: the environment credentials (unchanged behaviour)" do
      T.install_row(nil)

      assert :ok = Nebu.Media.Storage.put("obj", "x")

      assert T.credential_scope(T.next_request!(:env_stub)) == {@env_akid, "env-region-1"}
    end
  end
end
