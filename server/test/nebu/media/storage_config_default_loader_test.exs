defmodule Nebu.Media.StorageConfigDefaultLoaderTest do
  @moduledoc """
  The default loader of `Nebu.Media.StorageConfig` (no `:media_storage_config_loader` seam) reports an unavailable
  `Nebu.Repo` as a FAILED read (`{:error, :repo_unavailable}`), not as a confirmed absence of the row: the operational
  calls then fail closed instead of using the environment target (story `media-storage-uses-admin-config`).

  Needs a unit environment without a database (`Nebu.Repo` not running): tagged `:no_repo`, so it runs in the unit job
  (`make test-unit-elixir`, no `NEBU_DB_URL`) and is excluded wherever the Repo is up (the same convention as the other
  `:no_repo` tests); it is NOT exercised by a quick run against a database.
  """
  use ExUnit.Case, async: false

  Code.require_file("storage_admin_target_support.exs", __DIR__)

  alias Nebu.Media.Storage
  alias Nebu.Media.StorageAdminTargetSupport, as: T
  alias Nebu.Media.StorageConfig

  @moduletag :no_repo

  setup do
    T.isolate!()
    decoy = T.start_stub(tag: :decoy)
    T.decoy_boot_env!(decoy)
    # the env reader stays a seam so that the environment of the test host cannot matter; the LOADER is the real default
    T.install_env(%{"NEBU_MINIO_ENDPOINT" => "127.0.0.1:#{decoy.port}", "NEBU_MINIO_ACCESS_KEY" => "ENVAKID1101", "NEBU_MINIO_SECRET_KEY" => "env-secret-1101"})
    :ok
  end

  test "with the Repo not running, the default loader fails the read: request_target/0 and all five operations fail closed" do
    assert Process.whereis(Nebu.Repo) == nil, "this test needs a unit environment without a database"

    assert {:error, :storage_config_unavailable} = StorageConfig.request_target()

    for {name, fun, _expect} <- T.operations() do
      assert fun.() == {:error, :storage_config_unavailable}, "#{name}"
    end

    refute_receive {:s3_accepted, :decoy}, 50
    refute_receive {:s3_request, :decoy, _}, 50
  end

  test "the views that need no request still answer (no raise)" do
    assert Process.whereis(Nebu.Repo) == nil
    assert is_map(StorageConfig.get())
    assert is_binary(Storage.archive_bucket())
  end
end
