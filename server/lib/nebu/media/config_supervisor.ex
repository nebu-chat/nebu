defmodule Nebu.Media.Config.Supervisor do
  @moduledoc """
  Dedicated child supervisor for `Nebu.Media.Config` (ADR-027), started
  UNCONDITIONALLY by `Nebu.Application` — mirrors `Nebu.Matrix.OidcClaimCache`'s
  placement (always running, not gated behind a `:start_xxx` test flag), since
  AC5 requires media-policy changes to take effect cluster-wide without a
  restart, which in turn requires the cache holder to be genuinely supervised
  (not merely bare-started) so a crash repopulates its ETS cache automatically.

  ## Why a dedicated supervisor instead of adding `Nebu.Media.Config` directly
  to `Nebu.Application`'s root `Nebu.Supervisor` children list

  `config_test.exs`'s own test teardown intentionally stops (or, in one test,
  kills) this GenServer after EVERY test, so each test starts from a clean ETS
  cache. With a `:permanent` child (the default, matching every sibling cache
  in this codebase) under the ROOT supervisor's default restart intensity
  (`max_restarts: 3, max_seconds: 5`), that legitimate, fast-running test
  pattern would exceed the root supervisor's tolerance within seconds and
  crash the entire `:nebu` application — taking every other supervised
  process down with it. A dedicated supervisor confines a much more generous
  restart budget to this one cache, without loosening failure-detection
  behaviour for any other supervised child. (Same rationale/shape as
  `Nebu.Compliance.Supervisor` / `Nebu.Media.Supervisor` — a plain child
  `Supervisor`, NOT an OTP application, per ADR-019.)

  Code review (Cycle 0, m1 — accepted, not fixed): this bespoke supervisor +
  `:transient` restart + `max_restarts: 1000/5s` is more machinery than the
  codebase's usual bare-`:permanent`-child convention (e.g. `OidcClaimCache`)
  warrants, and the generous restart budget largely neutralizes crash-loop
  detection for this one child. Verified correct (the test-teardown
  incompatibility above is real), and the coordinator decided it is not
  worth further churn for this story — left as-is deliberately.
  """
  use Supervisor

  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # :transient (not the sibling caches' implicit :permanent) + a custom
    # `start` MFA pointing at Nebu.Media.Config.raw_start_link/1 (bypassing
    # Nebu.Media.Config.start_link/1's OWN smart Supervisor.restart_child/2
    # delegation, which would otherwise deadlock calling back into this very
    # supervisor while it is still inside its own init/1):
    #
    #   * :transient means a NORMAL exit (config_test.exs's routine
    #     `on_exit(fn -> ... GenServer.stop(pid) end)` teardown after EVERY
    #     test, so each test starts from a clean ETS cache) is NOT
    #     auto-restarted by this supervisor — avoiding a restart race between
    #     that async, supervisor-driven restart and the NEXT test's `setup`
    #     block replacing the :media_config_loader/:media_config_writer env
    #     seams (observed empirically: an in-flight restart's init/1 can call
    #     the wrong test's freshly-installed loader, incrementing ITS call
    #     counter before that test's own assertions run).
    #   * An ABNORMAL exit (the crash/restart acceptance test's
    #     `Process.exit(pid, :kill)`) IS still auto-restarted by this
    #     supervisor under :transient — satisfying AC5 + that test.
    #   * Nebu.Media.Config.start_link/1 (called by tests via the file's own
    #     `ensure_started/0` helper) restores a stopped :transient child
    #     SYNCHRONOUSLY via Supervisor.restart_child/2 instead of a bare,
    #     unsupervised GenServer.start_link — so whichever process is
    #     currently registered under the name is ALWAYS this supervisor's
    #     own managed child, never an untracked "shadow" process the
    #     crash/restart test's kill would go unnoticed by.
    children = [
      %{
        id: Nebu.Media.Config,
        start: {Nebu.Media.Config, :raw_start_link, [[]]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 1000, max_seconds: 5)
  end
end
