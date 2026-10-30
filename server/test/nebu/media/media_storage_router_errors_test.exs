defmodule Nebu.Media.MediaStorageRouterErrorsTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`: the HTTP-level behaviour of the media routes when the
  storage target is the admin-saved one (REAL `Nebu.Media.Storage`, real router, real local stub), in particular when
  storage fails. Covers scenarios 1, 3 and 5 at the route level:

    * sync `POST /v3/upload` and async `PUT /v3/upload/{server}/{id}` store at the saved target; a failing storage
      (403) or a blank endpoint keeps the existing 500 M_UNKNOWN "Failed to store media file";
    * `GET /v3/download/...` reads from the saved target; a storage 404 answers the existing 404 M_NOT_FOUND "Media not
      found", any other storage error (403, blank endpoint) the existing 502 M_UNKNOWN "Media storage unavailable" and
      sends nothing for a blank endpoint. Never a crash.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T

  setup do
    T.isolate!()
    T.install_env(%{})
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    T.decoy_boot_buckets!()
    :ok
  end

  defp row(endpoint) do
    T.saved_row(%{
      endpoint: endpoint,
      use_ssl: false,
      region: "route-region-7",
      bucket: "route-bucket",
      archive_bucket: "route-archive-bucket",
      access_key: "ROUTEAKIDCANARY0007",
      secret_key: "route-secret-canary-0007"
    })
  end

  defp assert_decoy_untouched do
    refute_receive {:s3_accepted, :decoy}, 50
    refute_receive {:s3_request, :decoy, _}, 50
  end

  defp assert_error(conn, status, errcode, message) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    body = Jason.decode!(conn.resp_body)
    assert body["errcode"] == errcode
    assert body["error"] == message
  end

  describe "sync upload (POST /v3/upload)" do
    test "a failing (403) saved storage answers the existing 500 \"Failed to store media file\"" do
      stub = T.start_stub(tag: :saved, status: 403)
      T.install_row(row(T.endpoint(stub)))
      token = T.upload_setup!()

      conn = T.post_upload(token)

      assert_error(conn, 500, "M_UNKNOWN", "Failed to store media file")
      assert T.next_request!(:saved).method == "PUT"
      assert_decoy_untouched()
    end
  end

  describe "async upload (PUT /v3/upload/{server}/{mediaId})" do
    test "the object is stored at the saved endpoint and bucket (the async path resolves the saved target too)" do
      stub = T.start_stub(tag: :saved)
      T.install_row(row(T.endpoint(stub)))
      ctx = T.async_upload_setup!()

      conn = T.put_async_upload(ctx)

      assert conn.status == 200, "async upload must succeed against the saved endpoint, got #{conn.status}: #{conn.resp_body}"
      req = T.next_request!(:saved)
      assert req.method == "PUT"
      assert req.target == "/route-bucket/#{ctx.media_id}"
      assert T.credential_scope(req) == {"ROUTEAKIDCANARY0007", "route-region-7"}
      assert_decoy_untouched()
    end

    test "a failing (403) saved storage answers the existing 500 \"Failed to store media file\"" do
      stub = T.start_stub(tag: :saved, status: 403)
      T.install_row(row(T.endpoint(stub)))
      ctx = T.async_upload_setup!()

      assert_error(T.put_async_upload(ctx), 500, "M_UNKNOWN", "Failed to store media file")
      assert T.next_request!(:saved).method == "PUT"
      assert_decoy_untouched()
    end

    test "a blank effective endpoint answers the existing 500 \"Failed to store media file\" and sends nothing" do
      T.install_row(row("  "))
      ctx = T.async_upload_setup!()

      assert_error(T.put_async_upload(ctx), 500, "M_UNKNOWN", "Failed to store media file")
      assert_decoy_untouched()
    end
  end

  describe "download (GET /v3/download/{server}/{mediaId})" do
    test "the object is read from the saved endpoint and bucket and served decrypted" do
      ctx = T.download_setup!()
      stub = T.start_stub(tag: :saved, get_body: ctx.ciphertext)
      T.install_row(row(T.endpoint(stub)))

      conn = T.get_download(ctx)

      assert conn.status == 200, "download must succeed against the saved endpoint, got #{conn.status}: #{conn.resp_body}"
      assert conn.resp_body == ctx.plaintext
      req = T.next_request!(:saved)
      assert req.method == "GET"
      assert req.target == "/route-bucket/#{ctx.media_id}"
      assert_decoy_untouched()
    end

    test "a 404 from the saved storage answers the existing 404 \"Media not found\"" do
      ctx = T.download_setup!()
      stub = T.start_stub(tag: :saved, status: 404)
      T.install_row(row(T.endpoint(stub)))

      assert_error(T.get_download(ctx), 404, "M_NOT_FOUND", "Media not found")
      assert T.next_request!(:saved).method == "GET"
    end

    test "a failing (403) saved storage answers the existing 502 \"Media storage unavailable\"" do
      ctx = T.download_setup!()
      stub = T.start_stub(tag: :saved, status: 403)
      T.install_row(row(T.endpoint(stub)))

      assert_error(T.get_download(ctx), 502, "M_UNKNOWN", "Media storage unavailable")
      assert_decoy_untouched()
    end

    test "a blank effective endpoint answers the existing 502 \"Media storage unavailable\", sends nothing and does not crash" do
      ctx = T.download_setup!()
      T.install_row(row("   "))

      assert_error(T.get_download(ctx), 502, "M_UNKNOWN", "Media storage unavailable")
      assert_decoy_untouched()
    end
  end
end
