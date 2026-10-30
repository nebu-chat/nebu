defmodule Nebu.RuntimeStorageEndpointTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`, scenarios 6 and 7: how `config/runtime.exs` treats
  `NEBU_MINIO_ENDPOINT`.

    * S6 - set but empty (or whitespace only) in a production or development environment: boot aborts with a message
      that names `NEBU_MINIO_ENDPOINT` (an empty value would otherwise silently become host "" / port 80);
    * S7 - not set: the endpoint defaults to `minio:9000` (host "minio", port 9000), independent of `use_ssl`.

  Same technique as `Nebu.Web.RateLimitTiersTest`: the REAL runtime.exs is evaluated with `Config.Reader.read!/2` under a
  patched OS environment (every `NEBU_*` variable cleared first, restored on exit). Nothing is written to the app env.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  # what runtime.exs insists on outside :test; throwaway values that only live during the read
  @required_env %{
    "NEBU_DB_URL" => "postgresql://u:p@localhost:5432/atdd",
    "NEBU_PII_ENCRYPTION_KEY" => String.duplicate("ab", 32),
    "NEBU_ADMIN_SECRET_KEY_BASE" => String.duplicate("k", 64)
  }

  # the non-NEBU_ variables runtime.exs reads in the evaluated prod / dev branch (libcluster topology, lines ~390-415);
  # an ambient value (a CI job on Kubernetes, a dev shell) must not change or break the read
  @other_env ~w(CLUSTER_STRATEGY KUBERNETES_NAMESPACE KUBERNETES_SELECTOR KUBERNETES_SERVICE_NAME)

  defp scoped?(name), do: String.starts_with?(name, "NEBU_") or name in @other_env

  setup do
    snapshot = for {name, value} <- System.get_env(), scoped?(name), do: {name, value}

    on_exit(fn ->
      for {name, _} <- System.get_env(), scoped?(name), do: System.delete_env(name)
      for {name, value} <- snapshot, do: System.put_env(name, value)
    end)

    :ok
  end

  defp read_runtime(env, vars) do
    for {name, _} <- System.get_env(), scoped?(name), do: System.delete_env(name)
    for {name, value} <- Map.merge(@required_env, vars), do: System.put_env(name, value)
    Config.Reader.read!(@runtime, env: env, target: :host)
  end

  defp s3(config), do: config |> Keyword.fetch!(:ex_aws) |> Keyword.fetch!(:s3)

  describe "S6 - empty NEBU_MINIO_ENDPOINT aborts boot" do
    for env <- [:prod, :dev], {label, value} <- [{"empty", ""}, {"whitespace-only", "   "}, {"tab and spaces", " \t "}] do
      test "#{label} value in #{env} aborts boot with a message naming NEBU_MINIO_ENDPOINT" do
        error =
          try do
            read_runtime(unquote(env), %{"NEBU_MINIO_ENDPOINT" => unquote(value)})
            nil
          rescue
            e -> e
          end

        assert error != nil, "boot must abort, but runtime.exs was evaluated without an error"
        assert Exception.message(error) =~ "NEBU_MINIO_ENDPOINT"
      end
    end

    test "a blank value aborts regardless of use_ssl and of configured credentials" do
      for vars <- [%{"NEBU_MINIO_USE_SSL" => "true"}, %{"NEBU_MINIO_ACCESS_KEY" => "a", "NEBU_MINIO_SECRET_KEY" => "b"}] do
        assert_raise_naming_endpoint(fn -> read_runtime(:prod, Map.put(vars, "NEBU_MINIO_ENDPOINT", "")) end)
      end
    end

    test "the abort message does not echo any credential" do
      error =
        try do
          read_runtime(:prod, %{
            "NEBU_MINIO_ENDPOINT" => "",
            "NEBU_MINIO_ACCESS_KEY" => "RUNTIMECANARYACCESS0005",
            "NEBU_MINIO_SECRET_KEY" => "runtime-canary-secret-0005"
          })

          nil
        rescue
          e -> e
        end

      assert error != nil
      refute Exception.message(error) =~ "RUNTIMECANARYACCESS0005"
      refute Exception.message(error) =~ "runtime-canary-secret-0005"
    end

    test "the :test environment is not affected (the storage block only runs in prod / dev)" do
      config = read_runtime(:test, %{"NEBU_MINIO_ENDPOINT" => ""})
      assert Keyword.get(config, :ex_aws) == nil
    end

    test "valid endpoints keep working: host:port, host without port by scheme" do
      assert s3(read_runtime(:prod, %{"NEBU_MINIO_ENDPOINT" => "storage.internal:9100"})) |> Keyword.take([:host, :port, :scheme]) ==
               [scheme: "http://", host: "storage.internal", port: 9100]

      assert s3(read_runtime(:dev, %{"NEBU_MINIO_ENDPOINT" => "s3.example.test", "NEBU_MINIO_USE_SSL" => "true"})) |> Keyword.take([:host, :port, :scheme]) ==
               [scheme: "https://", host: "s3.example.test", port: 443]

      assert s3(read_runtime(:dev, %{"NEBU_MINIO_ENDPOINT" => "s3.example.test"})) |> Keyword.take([:host, :port]) == [host: "s3.example.test", port: 80]
    end
  end

  describe "S7 - unset NEBU_MINIO_ENDPOINT keeps the default endpoint" do
    for env <- [:prod, :dev] do
      test "in #{env} the storage endpoint defaults to minio:9000" do
        s3 = s3(read_runtime(unquote(env), %{}))
        assert {s3[:scheme], s3[:host], s3[:port]} == {"http://", "minio", 9000}
      end
    end

    test "the default endpoint does not depend on NEBU_MINIO_USE_SSL (explicit port 9000)" do
      s3 = s3(read_runtime(:prod, %{"NEBU_MINIO_USE_SSL" => "true"}))
      assert {s3[:scheme], s3[:host], s3[:port]} == {"https://", "minio", 9000}
    end

    test "the default bucket names are unchanged" do
      config = read_runtime(:prod, %{})
      assert config[:nebu_http][:media_bucket] == "nebu-media"
      assert config[:nebu_http][:media_archive_bucket] == "nebu-media-archive"
    end
  end

  defp assert_raise_naming_endpoint(fun) do
    error =
      try do
        fun.()
        nil
      rescue
        e -> e
      end

    assert error != nil, "boot must abort, but runtime.exs was evaluated without an error"
    assert Exception.message(error) =~ "NEBU_MINIO_ENDPOINT"
  end
end
