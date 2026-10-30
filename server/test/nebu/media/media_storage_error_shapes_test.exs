defmodule Nebu.Media.MediaStorageErrorShapesTest do
  @moduledoc """
  The error values of `Nebu.Media.Storage` are a closed set: an atom, or `{:http_error, status}` with an integer status.
  ExAws also produces `{type, message}` pairs for storage answers with a JSON error body (`{"__type": ..., "message":
  ...}`, also for throttling) and other shapes; text that the storage server controls never appears in a returned term
  or a log line (debug included), for all five operations (story `media-storage-uses-admin-config`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.StorageAdminTargetSupport, as: T

  @server_text "SERVERCONTROLLEDTEXTCANARY0901"

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
        region: "shape-region-9",
        bucket: "shape-bucket",
        archive_bucket: "shape-archive-bucket",
        access_key: "ROWAKIDSHAPE0901",
        secret_key: "row-secret-shape-0901"
      })
    )
  end

  defp closed_set?(reason), do: is_atom(reason) or match?({:http_error, status} when is_integer(status), reason)

  for {label, status, body} <- [
        {"400 with a JSON error (__type and message)", 400, ~s({"__type":"com.amazonaws#SomeError","message":"#{@server_text}"})},
        {"400 with a JSON error (capitalised Message)", 400, ~s({"__type":"SomeError","Message":"#{@server_text}"})},
        {"429 throttling JSON error", 429, ~s({"__type":"ThrottlingException","message":"#{@server_text}"})},
        {"403 with an XML body", 403, "<Error><Code>X</Code><Message>#{@server_text}</Message></Error>"},
        {"400 with an unknown JSON body", 400, ~s({"detail":"#{@server_text}"})},
        {"500 with a JSON error", 500, ~s({"__type":"SomeError","message":"#{@server_text}"})}
      ] do
    test "#{label}: every operation returns an error from the closed set, no server text in a term or a log line" do
      stub = T.start_stub(tag: :saved, status: unquote(status), error_body: unquote(body))
      install_saved(stub)

      log =
        capture_log([level: :debug], fn ->
          results = for {name, fun, _expect} <- T.operations(), do: {name, fun.()}
          send(self(), {:results, results})
        end)

      assert_receive {:results, results}

      for {name, result} <- results do
        assert match?({:error, reason} when is_atom(reason) or is_tuple(reason), result), "#{name}: #{inspect(result)}"
        {:error, reason} = result
        assert closed_set?(reason), "#{name}: #{inspect(result)} is not a closed-set error"
      end

      printed = inspect(results, limit: :infinity, printable_limit: :infinity)
      refute printed =~ @server_text, "storage-controlled text in a returned term"
      refute log =~ @server_text, "storage-controlled text in a log line"
    end
  end

  test "a refused connection is an atom reason as well" do
    T.install_row(
      T.saved_row(%{endpoint: "127.0.0.1:#{T.closed_port()}", use_ssl: false, region: "r", bucket: "b", access_key: "ROWAKIDSHAPE0901", secret_key: "row-secret-shape-0901"})
    )

    for {name, fun, _expect} <- T.operations() do
      assert {:error, reason} = fun.()
      assert closed_set?(reason), "#{name}: #{inspect(reason)}"
    end
  end

  test "the statuses that were already mapped keep their shape (403 / 500: {:http_error, status})" do
    for status <- [403, 500] do
      stub = T.start_stub(tag: :"saved#{status}", status: status, error_body: "x")
      install_saved(stub)
      assert {:error, {:http_error, ^status}} = Nebu.Media.Storage.put("obj", "x")
    end
  end
end
