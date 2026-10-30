defmodule Nebu.Media.MediaStorageErrorBodiesTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, fix F (Kassandra #4, code review MINOR-4):
  `Nebu.Media.Storage.*` never returns an S3 error body. A real S3 error answer carries the access key id
  (`<AWSAccessKeyId>`), the canonical request and the string that was signed (`<StringToSign>`), and the callers
  (`MediaScanWorker`, `MediaCleanupWorker`) `inspect/1` the reason into logs and audit metadata. `{:http_error, status,
  body}` therefore becomes `{:http_error, status}`; the 404 mapping (get / get_from_archive -> `:not_found`, delete ->
  `:ok`) is unchanged.

  Callers checked (server/lib, read only): nothing outside `Nebu.Media.Storage` and `Nebu.Media.PinnedHttpClient`
  (the Test Connection path, untouched) matches on `{:http_error, ...}`; `Nebu.Media.fetch_and_decrypt/3` matches
  `{:error, :not_found}` and `_`, the workers `inspect/1` an opaque reason.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T

  @canary_akid "S3BODYCANARYAKID0301"
  @string_to_sign "STRINGTOSIGNCANARY0301"
  @error_body ~s(<?xml version="1.0"?><Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match.</Message>) <>
                ~s(<AWSAccessKeyId>#{@canary_akid}</AWSAccessKeyId><StringToSign>#{@string_to_sign}</StringToSign>) <>
                ~s(<CanonicalRequest>CANONICALCANARY0301</CanonicalRequest></Error>)

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    T.install_env(%{})

    logger_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: logger_level) end)
    :ok
  end

  defp install_saved(stub) do
    T.install_row(
      T.saved_row(%{
        endpoint: T.endpoint(stub),
        use_ssl: false,
        region: "body-region-3",
        bucket: "body-bucket",
        archive_bucket: "body-archive-bucket",
        access_key: "ROWAKIDBODY0301",
        secret_key: "row-secret-body-0301"
      })
    )
  end

  defp assert_no_body(printed, log) do
    for needle <- [@canary_akid, @string_to_sign, "CANONICALCANARY0301", "SignatureDoesNotMatch", "StringToSign", "AWSAccessKeyId"] do
      refute printed =~ needle, "an S3 error body fragment (#{needle}) appears in a returned term"
      refute log =~ needle, "an S3 error body fragment (#{needle}) appears in the log"
    end
  end

  describe "an error status with an S3 error body" do
    for status <- [403, 500] do
      test "#{status}: every operation returns {:error, {:http_error, #{status}}} and no body fragment reaches a term or a log line" do
        stub = T.start_stub(tag: :saved, status: unquote(status), error_body: @error_body)
        install_saved(stub)

        log =
          capture_log([level: :debug], fn ->
            results = for {name, fun, _expect} <- T.operations(), do: {name, fun.()}
            send(self(), {:results, results})
          end)

        assert_receive {:results, results}

        for {name, result} <- results do
          assert result == {:error, {:http_error, unquote(status)}}, "#{name}: #{inspect(result)}"
        end

        assert_no_body(inspect(results, limit: :infinity, printable_limit: :infinity), log)
      end
    end
  end

  describe "the 404 mapping is unchanged (body of a 404 is not returned either)" do
    test "get and get_from_archive -> {:error, :not_found}, delete -> :ok, put and put_object_copy -> {:error, {:http_error, 404}}" do
      stub = T.start_stub(tag: :saved, status: 404, error_body: @error_body)
      install_saved(stub)

      log =
        capture_log([level: :debug], fn ->
          results = for {name, fun, _expect} <- T.operations(), into: %{}, do: {name, fun.()}
          send(self(), {:results, results})
        end)

      assert_receive {:results, results}
      assert results.get == {:error, :not_found}
      assert results.get_from_archive == {:error, :not_found}
      assert results.delete == :ok
      assert results.put == {:error, {:http_error, 404}}
      assert results.put_object_copy == {:error, {:http_error, 404}}
      assert_no_body(inspect(results, limit: :infinity, printable_limit: :infinity), log)
    end
  end

  describe "the routes" do
    test "a download whose storage answers an error body: the existing 502 \"Media storage unavailable\", no body fragment in the response" do
      ctx = T.download_setup!()
      stub = T.start_stub(tag: :saved, status: 403, error_body: @error_body)
      install_saved(stub)

      conn = T.get_download(ctx)

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body)["error"] == "Media storage unavailable"
      assert_no_body(conn.resp_body, "")
    end
  end
end
