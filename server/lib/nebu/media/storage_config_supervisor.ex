defmodule Nebu.Media.StorageConfig.Supervisor do
  @moduledoc """
  Dedicated child supervisor for `Nebu.Media.StorageConfig` (story
  `media-security-admin-control/11a-storage-config-schema-secrets`), started
  UNCONDITIONALLY by `Nebu.Application` — mirrors `Nebu.Media.Config.Supervisor`'s
  placement (always running, not gated behind a `:start_xxx` test flag), since
  AC7 requires storage-target changes to take effect cluster-wide without a
  restart, which in turn requires the cache holder to be genuinely supervised
  (not merely bare-started) so a crash repopulates its ETS cache automatically.
  This holder caches storage-target config, including decrypted-adjacent
  secret handling — at least as high a resilience bar as
  `Nebu.Media.Config.Supervisor`, not lower.

  ## Why a dedicated supervisor instead of adding `Nebu.Media.StorageConfig`
  directly to `Nebu.Application`'s root `Nebu.Supervisor` children list

  `storage_config_test.exs`'s own test teardown intentionally stops (or, in
  one test, kills) this GenServer after EVERY test, so each test starts from
  a clean ETS cache. With a `:permanent` child (the default, matching every
  sibling cache in this codebase) under the ROOT supervisor's default restart
  intensity (`max_restarts: 3, max_seconds: 5`), that legitimate, fast-running
  test pattern would exceed the root supervisor's tolerance within seconds and
  crash the entire `:nebu` application — taking every other supervised
  process down with it. A dedicated supervisor confines a much more generous
  restart budget to this one cache, without loosening failure-detection
  behaviour for any other supervised child. (Same rationale/shape as
  `Nebu.Media.Config.Supervisor` / `Nebu.Compliance.Supervisor` /
  `Nebu.Media.Supervisor` — a plain child `Supervisor`, NOT an OTP
  application, per ADR-019.)
  """
  use Supervisor

  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # :transient (not the sibling caches' implicit :permanent) + a custom
    # `start` MFA pointing at Nebu.Media.StorageConfig.raw_start_link/1
    # (bypassing Nebu.Media.StorageConfig.start_link/1's OWN smart
    # Supervisor.restart_child/2 delegation, which would otherwise deadlock
    # calling back into this very supervisor while it is still inside its
    # own init/1):
    #
    #   * :transient means a NORMAL exit (storage_config_test.exs's routine
    #     `on_exit(fn -> ... GenServer.stop(pid) end)` teardown after EVERY
    #     test, so each test starts from a clean ETS cache) is NOT
    #     auto-restarted by this supervisor — avoiding a restart race between
    #     that async, supervisor-driven restart and the NEXT test's `setup`
    #     block replacing the :media_storage_config_loader/
    #     :media_storage_config_writer/:media_storage_env_reader env seams.
    #   * An ABNORMAL exit (the crash/restart acceptance test's
    #     `Process.exit(pid, :kill)`, AT13) IS still auto-restarted by this
    #     supervisor under :transient — satisfying AC7 + that test.
    #   * Nebu.Media.StorageConfig.start_link/1 (called by tests via the
    #     file's own `ensure_started/0` helper) restores a stopped
    #     :transient child SYNCHRONOUSLY via Supervisor.restart_child/2
    #     instead of a bare, unsupervised GenServer.start_link — so whichever
    #     process is currently registered under the name is ALWAYS this
    #     supervisor's own managed child, never an untracked "shadow" process
    #     the crash/restart test's kill would go unnoticed by.
    children = [
      %{
        id: Nebu.Media.StorageConfig,
        start: {Nebu.Media.StorageConfig, :raw_start_link, [[]]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 1000, max_seconds: 5)
  end
end
