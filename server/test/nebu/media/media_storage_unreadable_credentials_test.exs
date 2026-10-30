defmodule Nebu.Media.MediaStorageUnreadableCredentialsTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, fix E (code review MINOR-2): the credentials are
  read on every call now (`NEBU_MINIO_*_FILE` secret files, the at-rest key file of `Nebu.Web.SecretBox`). A missing or
  unreadable file must not raise out of `Nebu.Media.Storage` (the download route has no rescue): every operation returns
  `{:error, :storage_credentials_unreadable}` (or `:storage_credentials_missing` when the cause is a saved secret that
  cannot be decrypted), sends nothing, and logs only the setting name, never the file path or any credential.
  `Nebu.Media.Storage.archive_bucket/0` needs a bucket name only: it never touches credentials or files.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.Storage
  alias Nebu.Media.StorageAdminTargetSupport, as: T

  @missing_path "/nonexistent-nebu-dir-0201/credential-file-path-canary"
  @unreadable_reasons [:storage_credentials_unreadable, :storage_credentials_missing]

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    env_stub = T.start_stub(tag: :env_stub)
    saved = T.start_stub(tag: :saved)

    logger_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: logger_level) end)

    {:ok, env_stub: env_stub, saved: saved}
  end

  defp assert_nothing_sent do
    for tag <- [:decoy, :env_stub, :saved] do
      refute_receive {:s3_accepted, ^tag}, 30
      refute_receive {:s3_request, ^tag, _}, 30
    end
  end

  # Runs the five operations; an exception is reported as a failure of the test (the result is data, never a raise).
  defp run_ops do
    for {name, fun, _expect} <- T.operations() do
      result =
        try do
          fun.()
        rescue
          e -> flunk("#{name} raised #{inspect(e.__struct__)} instead of returning an error tuple")
        end

      {name, result}
    end
  end

  defp assert_all_unreadable(results) do
    for {name, result} <- results do
      assert match?({:error, reason} when reason in @unreadable_reasons, result), "#{name}: #{inspect(result)}"
    end
  end

  describe "an unreadable NEBU_MINIO_*_FILE credential file" do
    for {label, key} <- [{"access key", "NEBU_MINIO_ACCESS_KEY_FILE"}, {"secret key", "NEBU_MINIO_SECRET_KEY_FILE"}] do
      test "a missing #{label} file: all five operations return an error tuple, nothing is sent, the path is not logged", %{env_stub: env_stub} do
        T.install_row(nil)

        env =
          %{"NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub), "NEBU_MINIO_ACCESS_KEY_FILE" => T.write_secret_file!("FILEAKID0201"), "NEBU_MINIO_SECRET_KEY_FILE" => T.write_secret_file!("file-secret-0201")}
          |> Map.put(unquote(key), @missing_path)

        T.install_env(env)

        log = capture_log([level: :debug], fn -> send(self(), {:results, run_ops()}) end)
        assert_receive {:results, results}
        assert_all_unreadable(results)
        assert_nothing_sent()
        refute log =~ @missing_path, "the credential file path must not be logged (log the setting name only)"
      end
    end

    test "a credential 'file' that is a directory is an error tuple too", %{env_stub: env_stub} do
      T.install_row(nil)

      T.install_env(%{
        "NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub),
        "NEBU_MINIO_ACCESS_KEY_FILE" => System.tmp_dir!(),
        "NEBU_MINIO_SECRET_KEY_FILE" => T.write_secret_file!("file-secret-0201")
      })

      assert_all_unreadable(run_ops())
      assert_nothing_sent()
    end

    test "an unreadable file does not matter when the saved row has its own endpoint and credentials", %{saved: saved} do
      T.install_row(T.saved_row(%{endpoint: T.endpoint(saved), use_ssl: false, region: "r-2", bucket: "b-2", access_key: "ROWAKID0201", secret_key: "row-secret-0201"}))
      T.install_env(%{"NEBU_MINIO_ACCESS_KEY_FILE" => @missing_path, "NEBU_MINIO_SECRET_KEY_FILE" => @missing_path})

      assert :ok = Storage.put("obj", "x")
      assert T.credential_scope(T.next_request!(:saved)) == {"ROWAKID0201", "r-2"}
    end
  end

  describe "an unreadable at-rest key file (NEBU_INTERNAL_SECRET_FILE) for saved credentials" do
    test "all five operations return an error tuple, nothing is sent, no path in the log", %{saved: saved} do
      T.install_row(T.saved_row(%{endpoint: T.endpoint(saved), use_ssl: false, region: "r-2", bucket: "b-2", access_key: "ROWAKID0201", secret_key: "row-secret-0201"}))
      T.install_env(%{})

      # the at-rest key now has to come from a file that cannot be read
      T.delete_env_scoped(:nebu_http, :admin_secret_at_rest)
      T.put_os_env_scoped("NEBU_INTERNAL_SECRET", nil)
      T.put_os_env_scoped("NEBU_INTERNAL_SECRET_FILE", @missing_path)

      log = capture_log([level: :debug], fn -> send(self(), {:results, run_ops()}) end)
      assert_receive {:results, results}
      assert_all_unreadable(results)
      assert_nothing_sent()
      refute log =~ @missing_path
    end
  end

  describe "Storage.archive_bucket/0 does not touch credentials or files" do
    test "an unreadable credential file does not matter", %{env_stub: env_stub} do
      T.install_row(nil)

      T.install_env(%{
        "NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub),
        "NEBU_MINIO_ACCESS_KEY_FILE" => @missing_path,
        "NEBU_MINIO_SECRET_KEY_FILE" => @missing_path
      })

      log = capture_log([level: :debug], fn -> send(self(), {:bucket, Storage.archive_bucket()}) end)

      assert_receive {:bucket, "nebu-media-archive"}
      refute log =~ ~r/\[(warning|error)\]/, "archive_bucket/0 must not even try to read a credential: #{log}"
    end

    test "undecryptable saved secrets and an unreadable at-rest key do not matter, the saved archive bucket is returned", %{saved: saved} do
      row =
        T.saved_row(%{endpoint: T.endpoint(saved), bucket: "b-2", archive_bucket: "saved-archive-bucket-0201"})
        |> Map.put("access_key_encrypted", T.corrupt_ciphertext())
        |> Map.put("secret_key_encrypted", T.corrupt_ciphertext())

      T.install_row(row)
      T.install_env(%{})

      log = capture_log([level: :debug], fn -> send(self(), {:bucket, Storage.archive_bucket()}) end)
      assert_receive {:bucket, "saved-archive-bucket-0201"}
      refute log =~ ~r/\[(warning|error)\]/, "archive_bucket/0 must not try to decrypt anything: #{log}"

      T.delete_env_scoped(:nebu_http, :admin_secret_at_rest)
      T.put_os_env_scoped("NEBU_INTERNAL_SECRET", nil)
      T.put_os_env_scoped("NEBU_INTERNAL_SECRET_FILE", @missing_path)
      assert Storage.archive_bucket() == "saved-archive-bucket-0201"
    end
  end

  describe "the routes stay up" do
    test "a download with an unreadable credential file answers the existing 502 \"Media storage unavailable\"", %{env_stub: env_stub} do
      ctx = T.download_setup!()
      T.install_row(nil)
      T.install_env(%{"NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub), "NEBU_MINIO_ACCESS_KEY_FILE" => @missing_path})

      conn = T.get_download(ctx)

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "Media storage unavailable"
      assert_nothing_sent()
    end
  end
end
