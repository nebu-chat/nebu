defmodule Nebu.Media.MediaStorageBlankEndpointTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, scenario 3: when the effective storage endpoint
  resolves to an empty host, NO HTTP request is sent (not even to the boot-time endpoint, which a "no override"
  fallback would use), each operation returns `{:error, _}` and an upload through `Nebu.Media` keeps answering the
  existing 500 "Failed to store media file".

  A blank effective endpoint has three sources, all covered: a saved row with an empty / whitespace-only endpoint, an
  empty `NEBU_MINIO_ENDPOINT` seen through the env reader, and a host-less `:9000`.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    T.decoy_boot_buckets!()
    T.install_env(%{})
    {:ok, decoy: decoy}
  end

  defp saved_blank(endpoint) do
    T.saved_row(%{
      endpoint: endpoint,
      use_ssl: false,
      region: "saved-region-9",
      bucket: "saved-bucket",
      archive_bucket: "saved-archive-bucket",
      access_key: "BLANKAKIDCANARY0003",
      secret_key: "blank-secret-canary-0003"
    })
  end

  # name => installer
  @variants [
    {"saved endpoint is the empty string", :row, ""},
    {"saved endpoint is whitespace only", :row, "   "},
    {"saved endpoint has a port but no host", :row, ":9000"},
    {"no saved row and NEBU_MINIO_ENDPOINT is empty", :env, ""},
    {"no saved row and NEBU_MINIO_ENDPOINT is whitespace only", :env, "  \t "}
  ]

  defp install(:row, endpoint), do: T.install_row(saved_blank(endpoint))

  defp install(:env, endpoint) do
    T.install_row(nil)
    T.install_env(%{"NEBU_MINIO_ENDPOINT" => endpoint, "NEBU_MINIO_ACCESS_KEY" => "BLANKAKIDCANARY0003", "NEBU_MINIO_SECRET_KEY" => "blank-secret-canary-0003"})
  end

  defp assert_nothing_sent do
    refute_receive {:s3_accepted, :decoy}, 100
    refute_receive {:s3_request, :decoy, _}, 100
  end

  describe "S3 - blank endpoint is rejected without a request" do
    for {label, source, endpoint} <- @variants do
      test "#{label}: all five operations return {:error, _} and no request leaves the node" do
        install(unquote(source), unquote(endpoint))

        for {name, fun, _expect} <- T.operations() do
          assert {:error, _reason} = fun.(), "#{name} must fail for a blank effective endpoint"
        end

        assert_nothing_sent()
      end

      test "#{label}: no request reaches a recording HTTP client either (nothing is even handed to the transport)" do
        T.use_recording_client!()
        install(unquote(source), unquote(endpoint))

        for {_name, fun, _expect} <- T.operations(), do: fun.()

        refute_receive {:http_request, _, _, _, _}, 100
      end
    end

    test "an upload through Nebu.Media answers the existing 500 \"Failed to store media file\" and sends nothing" do
      install(:row, "")
      token = T.upload_setup!()

      conn = T.post_upload(token)

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["errcode"] == "M_UNKNOWN"
      assert body["error"] == "Failed to store media file"
      assert_nothing_sent()
    end

    test "an empty NEBU_MINIO_ENDPOINT does not hide a saved endpoint: the saved row wins and works" do
      saved = T.start_stub(tag: :saved)
      T.install_row(T.saved_row(%{endpoint: T.endpoint(saved), use_ssl: false, region: "r-1", bucket: "saved-bucket", access_key: "AKIDX1", secret_key: "sk-x1"}))
      T.install_env(%{"NEBU_MINIO_ENDPOINT" => ""})

      assert :ok = Nebu.Media.Storage.put("obj", "x")
      assert T.next_request!(:saved).target == "/saved-bucket/obj"
      assert_nothing_sent()
    end
  end
end
