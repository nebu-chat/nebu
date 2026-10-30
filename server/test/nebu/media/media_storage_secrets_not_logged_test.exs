defmodule Nebu.Media.MediaStorageSecretsNotLoggedTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, scenario 5: storage credentials never appear in logs
  or error values. Now that `Nebu.Media.Storage` resolves the credentials from `Nebu.Media.StorageConfig` and hands
  them to ExAws per request, a failing operation must not leak them through a log line (also at debug level), a
  returned error term or an exception message.

  Canary strings stand in for the credentials. Three failure modes are driven for all five operations: the storage
  answers 403, the connection is refused, and the effective endpoint is blank.

  Not covered (open point of the report): ExAws's own `debug_requests: true` logs the signed headers, i.e. the access
  key ID inside the SigV4 `Authorization` header; that flag is never set by this code base and is left untouched.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T

  @access_key "LEAKCANARYACCESSKEY0004"
  @secret_key "leak-canary-secret-key-0004"
  @region "leak-region-4"

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    T.install_env(%{})

    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  defp row(endpoint) do
    T.saved_row(%{
      endpoint: endpoint,
      use_ssl: false,
      region: @region,
      bucket: "leak-bucket",
      archive_bucket: "leak-archive-bucket",
      access_key: @access_key,
      secret_key: @secret_key
    })
  end

  # Runs every operation; never lets an exception escape (its message is part of what is inspected).
  defp run_all do
    for {name, fun, _expect} <- T.operations() do
      result =
        try do
          fun.()
        rescue
          e -> {:raised, e.__struct__, Exception.message(e)}
        catch
          kind, reason -> {:caught, kind, reason}
        end

      {name, result}
    end
  end

  defp run_logged do
    log = capture_log([level: :debug], fn -> send(self(), {:results, run_all()}) end)

    results =
      receive do
        {:results, r} -> r
      after
        0 -> flunk("operations did not run")
      end

    {log, results}
  end

  defp assert_no_secrets(log, results) do
    printed = inspect(results, limit: :infinity, printable_limit: :infinity, structs: false)

    for {label, haystack} <- [{"log output", log}, {"returned values / exception messages", printed}],
        {what, canary} <- [{"access key", @access_key}, {"secret key", @secret_key}] do
      refute haystack =~ canary, "the #{what} appears in the #{label}"
    end

    # also not in a base64 / url-encoded disguise of the plain canary
    for canary <- [@access_key, @secret_key], form <- [Base.encode64(canary), URI.encode_www_form(canary)], form != canary do
      refute log =~ form
      refute printed =~ form
    end
  end

  describe "S5 - storage credentials never appear in logs or error values" do
    test "the storage answers 403: five failing operations leak neither key (debug logging on)" do
      saved = T.start_stub(tag: :saved, status: 403)
      T.install_row(row(T.endpoint(saved)))

      {log, results} = run_logged()

      for {name, result} <- results, do: assert({:error, _} = result, "#{name} must fail against a 403 storage")
      # the credentials really were in use (otherwise the canary check below proves nothing)
      assert T.credential_scope(T.next_request!(:saved)) == {@access_key, @region}
      assert_no_secrets(log, results)
    end

    test "the connection is refused: five failing operations leak neither key (debug logging on)" do
      T.install_row(row("127.0.0.1:#{T.closed_port()}"))

      {log, results} = run_logged()

      for {name, result} <- results, do: assert({:error, _} = result, "#{name} must fail when nothing listens")
      assert_no_secrets(log, results)
    end

    test "the effective endpoint is blank: five failing operations leak neither key (debug logging on)" do
      T.install_row(row("  "))

      {log, results} = run_logged()

      for {name, result} <- results, do: assert({:error, _} = result, "#{name} must fail for a blank endpoint")
      assert_no_secrets(log, results)
      refute_receive {:s3_request, :decoy, _}, 100
    end

    test "env-sourced credentials (nothing saved) are not leaked either, with a refused connection" do
      T.install_row(nil)

      T.install_env(%{
        "NEBU_MINIO_ENDPOINT" => "127.0.0.1:#{T.closed_port()}",
        "NEBU_MINIO_ACCESS_KEY" => @access_key,
        "NEBU_MINIO_SECRET_KEY" => @secret_key
      })

      {log, results} = run_logged()

      for {name, result} <- results, do: assert({:error, _} = result, "#{name}")
      assert_no_secrets(log, results)
    end
  end
end
