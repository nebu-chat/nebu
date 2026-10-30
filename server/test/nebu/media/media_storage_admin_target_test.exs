defmodule Nebu.Media.MediaStorageAdminTargetTest do
  @moduledoc """
  Story `media-storage-uses-admin-config` (epic `media-storage-admin-target`),
  scenarios 1, 2 and 4:

    * S1 - the admin-saved storage target is used at call time (no restart);
    * S2 - nothing saved: the environment and default values are used;
    * S4 - every one of the five operations (`put`, `get`, `delete`, `put_object_copy`, `get_from_archive`) addresses
      the saved endpoint, region, credentials, bucket / archive bucket.

  The bug: `Nebu.Media.Storage` called `ExAws.request/1` without per-request overrides, so it only ever used the
  BOOT-TIME app env (`config/runtime.exs`). Here the boot-time app env points at a DECOY stub that must never see a
  request, while the saved `media_storage_config` row (through the `:media_storage_config_loader` /
  `:media_storage_env_reader` seams of `Nebu.Media.StorageConfig`) points at a REAL local HTTP stub that records what
  it receives. No database is involved.

  Contract (see the ATDD report): the operational requests are executed by ExAws's configured `:http_client` (the
  default hackney client; these tests swap it for a recording double only in the "defaults" tests), the five public
  functions keep their signatures, and `Nebu.Media.Storage.archive_bucket/0` returns the effective archive bucket.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.Storage
  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  @access_key "SAVEDAKIDCANARY0001"
  @secret_key "saved-secret-canary-0001"
  @region "saved-region-9"

  setup do
    T.isolate!()
    T.install_env(%{})
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    {:ok, decoy: decoy}
  end

  # The full saved row pointing at a stub.
  defp row(stub, extra \\ %{}), do: row_for(T.endpoint(stub), extra)

  # The full saved row for an arbitrary endpoint string.
  defp row_for(endpoint, extra) do
    T.saved_row(
      Map.merge(
        %{
          endpoint: endpoint,
          use_ssl: false,
          region: @region,
          bucket: "saved-bucket",
          archive_bucket: "saved-archive-bucket",
          access_key: @access_key,
          secret_key: @secret_key
        },
        extra
      )
    )
  end

  defp assert_decoy_untouched do
    refute_receive {:s3_accepted, :decoy}, 50
    refute_receive {:s3_request, :decoy, _}, 50
  end

  # ── Scenario 1 ─────────────────────────────────────────────────────────────

  describe "S1 - saved admin storage target is used at call time" do
    test "an upload through the router is stored at the saved endpoint and bucket, not at the boot-time endpoint" do
      T.decoy_boot_buckets!()
      saved = T.start_stub(tag: :saved)
      T.install_row(row(saved))
      token = T.upload_setup!()

      conn = T.post_upload(token)

      assert conn.status == 200, "upload must succeed against the saved endpoint, got #{conn.status}: #{conn.resp_body}"
      "mxc://" <> rest = Jason.decode!(conn.resp_body)["content_uri"]
      media_id = rest |> String.split("/") |> List.last()

      req = T.next_request!(:saved)
      assert req.method == "PUT"
      assert req.target == "/saved-bucket/#{media_id}"
      assert req.headers["host"] == T.endpoint(saved)
      assert req.body_size > 0
      assert T.credential_scope(req) == {@access_key, @region}
      assert_decoy_untouched()
    end

    test "Storage.put/2 goes to the saved endpoint and bucket even though the boot-time config points elsewhere" do
      T.decoy_boot_buckets!()
      saved = T.start_stub(tag: :saved)
      T.install_row(row(saved))

      assert :ok = Storage.put("obj-put", "payload-bytes")

      req = T.next_request!(:saved)
      assert req.target == "/saved-bucket/obj-put"
      assert req.headers["host"] == T.endpoint(saved)
      assert_decoy_untouched()
    end

    test "a changed saved row (endpoint, then bucket) takes effect on the very next call, no restart" do
      saved_a = T.start_stub(tag: :saved_a)
      saved_b = T.start_stub(tag: :saved_b)

      T.install_row(row(saved_a))
      assert :ok = Storage.put("obj-1", "x")
      assert T.next_request!(:saved_a).target == "/saved-bucket/obj-1"

      T.install_row(row(saved_b))
      assert :ok = Storage.put("obj-2", "x")
      assert T.next_request!(:saved_b).target == "/saved-bucket/obj-2"
      refute_receive {:s3_request, :saved_a, _}, 50

      T.install_row(row(saved_b, %{bucket: "renamed-bucket"}))
      assert :ok = Storage.put("obj-3", "x")
      assert T.next_request!(:saved_b).target == "/renamed-bucket/obj-3"
      assert_decoy_untouched()
    end

    test "with the StorageConfig cache running, a refresh (what upsert/1 triggers) makes the new row effective on the next call" do
      saved_a = T.start_stub(tag: :saved_a)
      saved_b = T.start_stub(tag: :saved_b)
      {:ok, store} = Agent.start_link(fn -> row(saved_a) end)
      T.put_env_scoped(:nebu_http, :media_storage_config_loader, fn -> Agent.get(store, & &1) end)

      case StorageConfig.start_link() do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      assert :ok = Storage.put("obj-1", "x")
      assert T.next_request!(:saved_a).target == "/saved-bucket/obj-1"

      Agent.update(store, fn _ -> row(saved_b) end)
      assert :ok = GenServer.call(StorageConfig, :refresh)

      assert :ok = Storage.put("obj-2", "x")
      assert T.next_request!(:saved_b).target == "/saved-bucket/obj-2"
      refute_receive {:s3_request, :saved_a, _}, 50
      assert_decoy_untouched()
    end
  end

  # ── Scenario 2 ─────────────────────────────────────────────────────────────

  describe "S2 - nothing saved keeps the environment configuration" do
    test "with no saved row and no env values, all five operations use minio:9000, nebu-media and nebu-media-archive" do
      T.use_recording_client!()
      T.install_row(nil)
      T.install_env(%{"NEBU_MINIO_ACCESS_KEY" => "ENVAKIDCANARY0002", "NEBU_MINIO_SECRET_KEY" => "env-secret-canary-0002"})

      for {name, fun, expect} <- T.operations() do
        result = fun.()
        refute match?({:error, _}, result), "#{name} failed: #{inspect(result)}"

        assert_receive {:http_request, method, url, headers, _size}, 1_000, "#{name}: no request was made"
        uri = URI.parse(url)
        bucket = if expect.bucket == :primary, do: "nebu-media", else: "nebu-media-archive"

        assert method |> Atom.to_string() |> String.upcase() == expect.method
        assert {uri.scheme, uri.host, uri.port} == {"http", "minio", 9000}, "#{name}: wrong endpoint #{url}"
        assert uri.path == "/#{bucket}/#{expect.key}", "#{name}: wrong bucket/path #{uri.path}"
        assert authorization(headers) =~ "Credential=ENVAKIDCANARY0002/"
        assert authorization(headers) =~ "/us-east-1/s3/"

        if name == :put_object_copy do
          assert header(headers, "x-amz-copy-source") == "/nebu-media/obj-copy"
        end
      end
    end

    test "the environment values (endpoint, bucket, archive bucket, region, credentials) are used when nothing is saved" do
      env_stub = T.start_stub(tag: :env_stub)
      T.install_row(nil)

      T.install_env(%{
        "NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub),
        "NEBU_MINIO_USE_SSL" => "false",
        "NEBU_MINIO_BUCKET" => "env-bucket",
        "NEBU_MINIO_ARCHIVE_BUCKET" => "env-archive-bucket",
        "NEBU_S3_REGION" => "env-region-2",
        "NEBU_MINIO_ACCESS_KEY" => "ENVAKIDCANARY0002",
        "NEBU_MINIO_SECRET_KEY" => "env-secret-canary-0002"
      })

      # config/runtime.exs derives the two bucket names from the same variables at boot
      T.put_env_scoped(:nebu_http, :media_bucket, "env-bucket")
      T.put_env_scoped(:nebu_http, :media_archive_bucket, "env-archive-bucket")

      for {name, fun, expect} <- T.operations() do
        assert fun.() == expect.result, "#{name}"
        req = T.next_request!(:env_stub)
        bucket = if expect.bucket == :primary, do: "env-bucket", else: "env-archive-bucket"
        assert req.target == "/#{bucket}/#{expect.key}", "#{name}"
        assert T.credential_scope(req) == {"ENVAKIDCANARY0002", "env-region-2"}, "#{name}"
      end

      assert_decoy_untouched()
    end

    test "a saved row without archive bucket keeps the environment archive bucket for the archive operations" do
      saved = T.start_stub(tag: :saved)
      T.install_row(row(saved, %{archive_bucket: nil}) |> Map.delete("archive_bucket"))
      T.install_env(%{"NEBU_MINIO_ARCHIVE_BUCKET" => "env-archive-bucket"})
      T.put_env_scoped(:nebu_http, :media_archive_bucket, "env-archive-bucket")

      assert :ok = Storage.put_object_copy("obj-copy", Storage.archive_bucket())
      req = T.next_request!(:saved)
      assert req.target == "/env-archive-bucket/obj-copy"
      assert req.headers["x-amz-copy-source"] == "/saved-bucket/obj-copy"

      assert {:ok, _} = Storage.get_from_archive("obj-arch")
      assert T.next_request!(:saved).target == "/env-archive-bucket/obj-arch"
      assert_decoy_untouched()
    end

    test "a saved row without archive bucket and no environment value falls back to nebu-media-archive" do
      saved = T.start_stub(tag: :saved)
      T.install_row(row(saved) |> Map.delete("archive_bucket"))

      assert Storage.archive_bucket() == "nebu-media-archive"
      assert {:ok, _} = Storage.get_from_archive("obj-arch")
      assert T.next_request!(:saved).target == "/nebu-media-archive/obj-arch"
    end

    for {label, endpoint, use_ssl, expected} <- [
          {"https without port defaults to 443", "storage.example.test", true, {"https", "storage.example.test", 443}},
          {"https with an explicit port keeps it", "storage.example.test:9443", true, {"https", "storage.example.test", 9443}},
          {"http with an explicit port keeps it", "storage.example.test:9100", false, {"http", "storage.example.test", 9100}},
          {"http without port defaults to 80", "storage.example.test", false, {"http", "storage.example.test", 80}}
        ] do
      test "the scheme follows use_ssl and the port follows the endpoint: #{label}" do
        T.use_recording_client!()
        T.install_row(row_for(unquote(endpoint), %{use_ssl: unquote(use_ssl)}))

        assert :ok = Storage.put("obj", "x")

        assert_receive {:http_request, _, url, _, _}, 1_000
        uri = URI.parse(url)
        assert {uri.scheme, uri.host, uri.port} == unquote(Macro.escape(expected))
        assert_decoy_untouched()
      end
    end

    test "a partial saved row (endpoint and credentials only) takes bucket, archive bucket and region from the environment" do
      saved = T.start_stub(tag: :saved)
      T.install_row(T.saved_row(%{endpoint: T.endpoint(saved), access_key: @access_key, secret_key: @secret_key}))

      T.install_env(%{
        "NEBU_MINIO_BUCKET" => "env-bucket",
        "NEBU_MINIO_ARCHIVE_BUCKET" => "env-archive-bucket",
        "NEBU_S3_REGION" => "env-region-2"
      })

      T.put_env_scoped(:nebu_http, :media_bucket, "env-bucket")
      T.put_env_scoped(:nebu_http, :media_archive_bucket, "env-archive-bucket")

      for {name, fun, expect} <- T.operations() do
        assert fun.() == expect.result, "#{name}"
        req = T.next_request!(:saved)
        bucket = if expect.bucket == :primary, do: "env-bucket", else: "env-archive-bucket"
        assert req.target == "/#{bucket}/#{expect.key}", "#{name}"
        assert req.headers["host"] == T.endpoint(saved), "#{name}"
        assert T.credential_scope(req) == {@access_key, "env-region-2"}, "#{name}"
      end

      assert_decoy_untouched()
    end

    test "credentials come from the NEBU_MINIO_*_FILE secret files (they win over the plain variables) when nothing is saved" do
      stub = T.start_stub(tag: :saved)
      key_file = T.write_secret_file!("FILEAKIDCANARY0006")
      secret_file = T.write_secret_file!("file-secret-canary-0006")
      T.install_row(nil)

      T.install_env(%{
        "NEBU_MINIO_ENDPOINT" => T.endpoint(stub),
        "NEBU_S3_REGION" => "file-region-6",
        "NEBU_MINIO_ACCESS_KEY_FILE" => key_file,
        "NEBU_MINIO_SECRET_KEY_FILE" => secret_file,
        "NEBU_MINIO_ACCESS_KEY" => "PLAINVALUELOSES0006",
        "NEBU_MINIO_SECRET_KEY" => "plain-value-loses-0006"
      })

      assert :ok = Storage.put("obj-put", "x")

      assert T.credential_scope(T.next_request!(:saved)) == {"FILEAKIDCANARY0006", "file-region-6"}
      assert_decoy_untouched()
    end
  end

  describe "the saved row wins over every environment value" do
    test "endpoint, bucket, archive bucket, region and credentials of the row are used although the environment sets all of them" do
      saved = T.start_stub(tag: :saved)
      env_stub = T.start_stub(tag: :env_stub)
      T.install_row(row(saved))

      T.install_env(%{
        "NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub),
        "NEBU_MINIO_BUCKET" => "env-bucket",
        "NEBU_MINIO_ARCHIVE_BUCKET" => "env-archive-bucket",
        "NEBU_S3_REGION" => "env-region-2",
        "NEBU_MINIO_ACCESS_KEY" => "ENVAKIDCANARY0002",
        "NEBU_MINIO_SECRET_KEY" => "env-secret-canary-0002"
      })

      T.put_env_scoped(:nebu_http, :media_bucket, "env-bucket")
      T.put_env_scoped(:nebu_http, :media_archive_bucket, "env-archive-bucket")

      for {name, fun, expect} <- T.operations() do
        assert fun.() == expect.result, "#{name}"
        req = T.next_request!(:saved)
        bucket = if expect.bucket == :primary, do: "saved-bucket", else: "saved-archive-bucket"
        assert req.target == "/#{bucket}/#{expect.key}", "#{name}"
        assert T.credential_scope(req) == {@access_key, @region}, "#{name}"
      end

      refute_receive {:s3_request, :env_stub, _}, 50
      assert_decoy_untouched()
    end
  end

  # ── storage answers 404: the existing error mapping of each operation ──────

  describe "a 404 from the saved storage keeps the existing error mapping" do
    setup do
      saved = T.start_stub(tag: :saved, status: 404)
      T.install_row(row(saved))
      {:ok, saved: saved}
    end

    test "get -> {:error, :not_found}" do
      assert {:error, :not_found} = Storage.get("obj-get")
      assert T.next_request!(:saved).target == "/saved-bucket/obj-get"
    end

    test "get_from_archive -> {:error, :not_found}" do
      assert {:error, :not_found} = Storage.get_from_archive("obj-arch")
      assert T.next_request!(:saved).target == "/saved-archive-bucket/obj-arch"
    end

    test "delete -> :ok (an already-gone object is a no-op, ADR-032)" do
      assert :ok = Storage.delete("obj-del")
      assert T.next_request!(:saved).target == "/saved-bucket/obj-del"
    end

    test "put -> {:error, _}" do
      assert {:error, _} = Storage.put("obj-put", "x")
      assert T.next_request!(:saved).target == "/saved-bucket/obj-put"
    end

    test "put_object_copy -> {:error, _}" do
      assert {:error, _} = Storage.put_object_copy("obj-copy", Storage.archive_bucket())
      assert T.next_request!(:saved).target == "/saved-archive-bucket/obj-copy"
    end
  end

  # ── Scenario 4 ─────────────────────────────────────────────────────────────

  describe "S4 - every storage operation resolves the saved target, including the archive bucket" do
    for name <- [:put, :get, :delete, :put_object_copy, :get_from_archive] do
      test "#{name} addresses the saved endpoint with the saved credentials, region and its saved bucket" do
        T.decoy_boot_buckets!()
        saved = T.start_stub(tag: :saved)
        T.install_row(row(saved))
        {_, fun, expect} = List.keyfind(T.operations(), unquote(name), 0)

        assert fun.() == expect.result

        req = T.next_request!(:saved)
        bucket = if expect.bucket == :primary, do: "saved-bucket", else: "saved-archive-bucket"
        assert req.method == expect.method
        assert req.target == "/#{bucket}/#{expect.key}"
        assert req.headers["host"] == T.endpoint(saved)
        assert T.credential_scope(req) == {@access_key, @region}

        if unquote(name) == :put_object_copy do
          assert req.headers["x-amz-copy-source"] == "/saved-bucket/obj-copy"
        end

        if unquote(name) == :put, do: assert(req.body_size == byte_size("payload-bytes"))
        assert_decoy_untouched()
      end
    end

    test "Storage.archive_bucket/0 returns the saved archive bucket" do
      saved = T.start_stub(tag: :saved)
      T.install_row(row(saved))
      T.decoy_boot_buckets!()
      assert Storage.archive_bucket() == "saved-archive-bucket"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  defp authorization(headers), do: header(headers, "authorization") || ""
end
