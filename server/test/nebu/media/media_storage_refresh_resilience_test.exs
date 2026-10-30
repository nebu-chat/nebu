defmodule Nebu.Media.MediaStorageRefreshResilienceTest do
  @moduledoc """
  Story `media-storage-uses-admin-config`: a FAILED refresh of the `Nebu.Media.StorageConfig` cache (the loader
  cannot read the row: DB error, pool timeout, Repo not up) must not replace the last good snapshot with "no row".
  Caching `{nil, env}` on a failed read would send every operational call, for up to 60 s, silently to the environment
  endpoint / bucket / credentials: uploads would land in another store.

  ## Contract pinned for the loader seam (`:media_storage_config_loader`)

  Besides `row | nil` (nil = a CONFIRMED "no row") the loader may signal a failed read with `{:error, term}`, or by
  raising. A failed read

    * keeps the last good snapshot (GenServer `:refresh`, `{:invalidate_media_storage_config}` and the `:ttl_tick` path);
    * is retried on the next refresh (the cache heals);
    * with no snapshot at all (cache not running or never loaded: the direct read) makes `Nebu.Media.Storage.*` return
      `{:error, _}` without sending anything (never the environment target while the saved row cannot be read).

  `nil` from the loader still replaces the snapshot (the row was deleted).
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.Storage
  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    env_stub = T.start_stub(tag: :env_stub)
    saved_a = T.start_stub(tag: :saved_a)
    saved_b = T.start_stub(tag: :saved_b)

    T.install_env(%{
      "NEBU_MINIO_ENDPOINT" => T.endpoint(env_stub),
      "NEBU_MINIO_ACCESS_KEY" => "ENVAKIDRESIL0401",
      "NEBU_MINIO_SECRET_KEY" => "env-secret-resil-0401"
    })

    {:ok, saved_a: saved_a, saved_b: saved_b}
  end

  defp row(stub, bucket) do
    T.saved_row(%{endpoint: T.endpoint(stub), use_ssl: false, region: "resil-region-4", bucket: bucket, access_key: "ROWAKIDRESIL0401", secret_key: "row-secret-resil-0401"})
  end

  # The loader reads its answer from an Agent: ONE closure for the whole test (the cache is tagged with the seam value).
  defp start_loader(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)

    T.put_env_scoped(:nebu_http, :media_storage_config_loader, fn ->
      case Agent.get(agent, & &1) do
        {:ok, row} -> row
        :error_tuple -> {:error, :db_down}
        :raise -> raise "db down"
      end
    end)

    agent
  end

  defp start_cache do
    case StorageConfig.start_link() do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp assert_goes_to(tag, bucket) do
    assert :ok = Storage.put("obj", "x")
    assert T.next_request!(tag).target == "/#{bucket}/obj"
    for other <- [:decoy, :env_stub, :saved_a, :saved_b] -- [tag], do: refute_receive({:s3_request, ^other, _}, 30)
  end

  describe "a failed refresh keeps the last good snapshot" do
    for failure <- [:error_tuple, :raise], path <- [:refresh, :invalidate, :ttl_tick] do
      test "loader #{failure}, via #{path}: the saved target is still used and the saved config is still the effective one", %{saved_a: saved_a} do
        agent = start_loader({:ok, row(saved_a, "bucket-a")})
        pid = start_cache()
        assert_goes_to(:saved_a, "bucket-a")

        Agent.update(agent, fn _ -> unquote(failure) end)

        case unquote(path) do
          :refresh -> GenServer.call(pid, :refresh)
          :invalidate -> send(pid, {:invalidate_media_storage_config})
          :ttl_tick -> send(pid, :ttl_tick)
        end

        :sys.get_state(pid)

        assert StorageConfig.get().bucket == "bucket-a"
        assert_goes_to(:saved_a, "bucket-a")
      end
    end

    test "after the failure the next successful refresh picks up the (changed) row", %{saved_a: saved_a, saved_b: saved_b} do
      agent = start_loader({:ok, row(saved_a, "bucket-a")})
      pid = start_cache()
      assert_goes_to(:saved_a, "bucket-a")

      Agent.update(agent, fn _ -> :error_tuple end)
      GenServer.call(pid, :refresh)
      assert_goes_to(:saved_a, "bucket-a")

      Agent.update(agent, fn _ -> {:ok, row(saved_b, "bucket-b")} end)
      GenServer.call(pid, :refresh)
      assert_goes_to(:saved_b, "bucket-b")
    end

    test "a CONFIRMED absence of the row (loader answers nil) does replace the snapshot: the environment target is used again", %{saved_a: saved_a} do
      agent = start_loader({:ok, row(saved_a, "bucket-a")})
      pid = start_cache()
      assert_goes_to(:saved_a, "bucket-a")

      Agent.update(agent, fn _ -> {:ok, nil} end)
      GenServer.call(pid, :refresh)

      assert :ok = Storage.put("obj", "x")
      assert T.next_request!(:env_stub).target == "/nebu-media/obj"
    end
  end

  describe "no snapshot at all (the direct read): fail closed" do
    for failure <- [:error_tuple, :raise] do
      test "loader #{failure}, cache not running: every operation returns an error, nothing is sent" do
        start_loader(unquote(failure))

        for {name, fun, _expect} <- T.operations() do
          assert {:error, _} = fun.(), "#{name} must not fall back to the environment target while the saved row cannot be read"
        end

        for tag <- [:decoy, :env_stub, :saved_a, :saved_b] do
          refute_receive {:s3_accepted, ^tag}, 30
          refute_receive {:s3_request, ^tag, _}, 30
        end
      end

      test "loader #{failure} while the cache starts, then healthy: the saved target is used from the first good read", %{saved_a: saved_a} do
        agent = start_loader(unquote(failure))
        pid = start_cache()

        assert {:error, _} = Storage.put("obj", "x")
        refute_receive {:s3_request, :env_stub, _}, 30

        Agent.update(agent, fn _ -> {:ok, row(saved_a, "bucket-a")} end)
        GenServer.call(pid, :refresh)
        assert_goes_to(:saved_a, "bucket-a")
      end
    end

    test "StorageConfig.get/0 and get_for_connection/0 still answer (no raise) while the loader fails" do
      start_loader(:raise)
      assert is_map(StorageConfig.get())
      assert is_map(StorageConfig.get_for_connection())
    end
  end
end
