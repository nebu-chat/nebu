defmodule Nebu.Media.MediaStorageUploadCredentialsTest do
  @moduledoc """
  An upload through the real router (`POST /_matrix/media/v3/upload`, real `Nebu.Media.Storage`) when the storage
  credentials cannot be used (story `media-storage-uses-admin-config`):

  * an unreadable `NEBU_MINIO_*_FILE` credential file, an unreadable at-rest key file or undecryptable saved keys answer
    the existing 500 M_UNKNOWN "Failed to store media file": no crash, nothing sent, no file path in the response or in a
    log line;
  * looking up the object key prefix template for an upload reads no secret: nothing is decrypted and no
    `Nebu.Media.StorageConfig` log line is written for it, and a saved template is honoured on a successful upload.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T

  @missing_path "/nonexistent-nebu-dir-1001/upload-credential-path-canary"

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    env_stub = T.start_stub(tag: :env_stub)

    logger_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: logger_level) end)

    {:ok, env_stub: env_stub}
  end

  defp assert_nothing_sent do
    for tag <- [:decoy, :env_stub, :saved] do
      refute_receive {:s3_accepted, ^tag}, 30
      refute_receive {:s3_request, ^tag, _}, 30
    end
  end

  defp assert_upload_failed(conn, log) do
    assert conn.status == 500
    body = Jason.decode!(conn.resp_body)
    assert body["errcode"] == "M_UNKNOWN"
    assert body["error"] == "Failed to store media file"
    refute conn.resp_body =~ @missing_path
    refute log =~ @missing_path, "the file path must not be logged"
  end

  test "an unreadable NEBU_MINIO_*_FILE credential file and no saved keys: the existing 500, no crash", %{env_stub: env_stub} do
    T.install_row(nil)

    T.install_env(%{
      "NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub),
      "NEBU_MINIO_ACCESS_KEY_FILE" => @missing_path,
      "NEBU_MINIO_SECRET_KEY_FILE" => T.write_secret_file!("file-secret-1001")
    })

    token = T.upload_setup!()
    log = capture_log([level: :debug], fn -> send(self(), {:conn, T.post_upload(token)}) end)

    assert_receive {:conn, conn}
    assert_upload_failed(conn, log)
    assert_nothing_sent()
  end

  test "a saved template with an unreadable credential file elsewhere: the same 500", %{env_stub: env_stub} do
    T.install_row(T.saved_row(%{s3_key_prefix_template: "{year}/{media_id}"}))
    T.install_env(%{"NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub), "NEBU_MINIO_SECRET_KEY_FILE" => @missing_path})

    token = T.upload_setup!()
    log = capture_log([level: :debug], fn -> send(self(), {:conn, T.post_upload(token)}) end)

    assert_receive {:conn, conn}
    assert_upload_failed(conn, log)
    assert_nothing_sent()
  end

  test "saved keys and an unreadable at-rest key file: the existing 500, no crash, no path in the log", %{env_stub: env_stub} do
    T.install_row(T.saved_row(%{access_key: "ROWAKID1001", secret_key: "row-secret-1001", s3_key_prefix_template: "{year}/{media_id}"}))
    T.install_env(%{"NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub)})

    T.delete_env_scoped(:nebu_http, :admin_secret_at_rest)
    T.put_os_env_scoped("NEBU_INTERNAL_SECRET", nil)
    T.put_os_env_scoped("NEBU_INTERNAL_SECRET_FILE", @missing_path)

    token = T.upload_setup!()
    log = capture_log([level: :debug], fn -> send(self(), {:conn, T.post_upload(token)}) end)

    assert_receive {:conn, conn}
    assert_upload_failed(conn, log)
    assert_nothing_sent()
  end

  test "undecryptable saved keys: the existing 500; the template lookup decrypts nothing (no StorageConfig log line, no claimed fallback)", %{env_stub: env_stub} do
    T.install_row(
      T.saved_row(%{s3_key_prefix_template: "{year}/{media_id}"})
      |> Map.put("access_key_encrypted", T.corrupt_ciphertext())
      |> Map.put("secret_key_encrypted", T.corrupt_ciphertext())
    )

    T.install_env(%{"NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub), "NEBU_MINIO_ACCESS_KEY" => "ENVAKID1001", "NEBU_MINIO_SECRET_KEY" => "env-secret-1001"})

    token = T.upload_setup!()
    log = capture_log([level: :debug], fn -> send(self(), {:conn, T.post_upload(token)}) end)

    assert_receive {:conn, conn}
    assert_upload_failed(conn, log)
    refute log =~ "Nebu.Media.StorageConfig:", "the template lookup must not touch the secrets: #{log}"
    refute log =~ ~r/fall(ing)?\s?back/i
    refute log =~ T.corrupt_ciphertext()
    assert_nothing_sent()
  end

  test "a saved template is honoured on a successful upload (the key is built from it)" do
    saved = T.start_stub(tag: :saved)

    T.install_row(
      T.saved_row(%{endpoint: T.endpoint(saved), use_ssl: false, region: "r-1", bucket: "tpl-bucket", access_key: "ROWAKID1001", secret_key: "row-secret-1001", s3_key_prefix_template: "{year}/{media_id}"})
    )

    T.install_env(%{})
    token = T.upload_setup!()

    conn = T.post_upload(token)

    assert conn.status == 200
    "mxc://" <> rest = Jason.decode!(conn.resp_body)["content_uri"]
    media_id = rest |> String.split("/") |> List.last()
    req = T.next_request!(:saved)
    assert req.target == "/tpl-bucket/#{Date.utc_today().year}/#{media_id}"
  end
end
