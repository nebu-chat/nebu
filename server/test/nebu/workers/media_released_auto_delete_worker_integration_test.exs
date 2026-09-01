defmodule Nebu.Workers.MediaReleasedAutoDeleteWorkerIntegrationTest do
  @moduledoc """
  Real-DB regression test for media-security-admin-control/8d-released-auto-delete's
  cycle-1 code-review MINOR fix (finding 2): `released_for_days/1` has three clauses
  (`%DateTime{}`, `%NaiveDateTime{}`, and an `is_integer/1` ms-epoch clause). Only the
  `is_integer/1` clause is exercised by `media_released_auto_delete_worker_test.exs`'s
  unit suite — that file's `FakeRepo` models `media_state_transitions.inserted_at` as a
  plain integer millisecond epoch (mirroring Story 8a's own fake convention), never as a
  `%DateTime{}` struct. In production, `inserted_at` is a real `TIMESTAMPTZ`
  (`server/priv/migrations/000022_media_state_machine_foundation.up.sql`), which Postgrex
  decodes as `%DateTime{}` — the ONLY clause of `released_for_days/1` that actually runs
  against a live row. A regression in that clause's day-arithmetic would pass the entire
  unit suite undetected.

  This file exercises the REAL, non-faked path end-to-end against a live PostgreSQL: a
  real `Nebu.Media.StateMachine.create_quarantined/1` genesis insert, followed by two real
  `StateMachine.transition/4` calls (`:quarantined -> :scanning -> :released`, the exact
  edges `Nebu.Workers.MediaScanWorker`'s own `release/2` uses in production), then the
  real `Nebu.Workers.MediaReleasedAutoDeleteWorker.perform/1` running its candidate query
  and `released_for_days/1` conversion against the real `Nebu.Repo` — none of the worker's
  own `:media_released_auto_delete_repo_module` / `:media_state_machine_module` /
  `:media_audit_writer_module` seams are swapped. Only `Nebu.Media.Config`'s own
  `:media_config_source` test seam is set, to deterministically select a
  `released_delete_after_days` window without depending on whatever the `media_config`
  table happens to hold — mirroring this same file's unit tests' own `put_config/1`
  convention, just with every OTHER module left at its real default.

  Since `now()` itself can't be moved into the past, this test proves the fix by
  backdating the one thing that legitimately can be: the real `media_state_transitions`
  ledger row the real `transition/4` call just wrote for `to_state = 'released'` — the
  exact same age-anchor `Nebu.Workers.MediaCleanupWorker`'s own
  `media_cleanup_worker_integration_test.exs` backdates for `to_state = 'deleted'`.

  Requires a live PostgreSQL — run via `make test-integration` / `mix test --include
  integration`. Follows the SAME no-Sandbox / real-connection / manual-cleanup convention
  already established by `state_machine_test.exs` and
  `media_cleanup_worker_integration_test.exs` (`@moduletag :integration`, unique per-run
  media ids, `async: false`), including the `nebu_migrate`-role DISABLE/ENABLE TRIGGER
  dance for backdating/cleaning up the append-only `media_state_transitions` ledger
  (ADR-031's `media_state_transitions_no_mutate` trigger rejects a plain UPDATE/DELETE for
  every role, including the table owner).
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  @moduletag :integration

  alias Nebu.Media.StateMachine
  alias Nebu.Repo
  alias Nebu.Workers.MediaReleasedAutoDeleteWorker

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "mradwi_#{@run_id}_#{suffix}"

  defp create_real_released!(media_id) do
    {:ok, ^media_id} =
      StateMachine.create_quarantined(%{
        media_id: media_id,
        server_name: "test.local",
        uploader_user_id: "@tester:test.local"
      })

    assert {:ok, :scanning} = StateMachine.transition(media_id, :scanning, {:system, nil})
    assert {:ok, :released} = StateMachine.transition(media_id, :released, {:system, nil})

    :ok
  end

  defp fetch_state!(media_id) do
    %Postgrex.Result{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT state FROM media_files WHERE media_id = $1",
        [media_id]
      )

    state
  end

  defp count_auto_deleted_audit_rows!(media_id) do
    %Postgrex.Result{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM audit_log WHERE target_id = $1 AND action = 'media_released_auto_deleted'",
        [media_id]
      )

    count
  end

  # nebu_migrate is the actual table owner in this project's dual-role docker-compose
  # deployment (see state_machine_test.exs's / media_cleanup_worker_integration_test.exs's
  # own migrate_role_conn!/0) — only the owner can DISABLE/ENABLE the append-only trigger
  # without full Postgres superuser, needed here purely to backdate a ledger timestamp for
  # the test (ADR-031's trigger otherwise rejects the UPDATE with SQLSTATE 23001 for every
  # role, including the owner).
  defp migrate_role_conn! do
    url =
      System.get_env("NEBU_DB_URL") ||
        raise "NEBU_DB_URL is not set — this test requires a live PostgreSQL connection"

    uri = URI.parse(url)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: uri.host || "localhost",
        port: uri.port || 5432,
        database: String.trim_leading(uri.path || "", "/"),
        username: "nebu_migrate",
        password: "nebu_migrate_dev_pw"
      )

    conn
  end

  # Backdates the real ledger row the real transition/4 call just wrote for
  # to_state = 'released', so the worker's candidate query AND its
  # released_for_days/1's real %DateTime{} clause both see a genuinely aged
  # TIMESTAMPTZ. `now()` cannot be backdated; this ledger row's `inserted_at`
  # is the one legitimate stand-in — exactly mirroring
  # media_cleanup_worker_integration_test.exs's backdate_deleted_transition!/2.
  defp backdate_released_transition!(media_id, days_ago) do
    conn = migrate_role_conn!()

    try do
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions DISABLE TRIGGER media_state_transitions_no_mutate",
        []
      )

      Postgrex.query!(
        conn,
        """
        UPDATE media_state_transitions
           SET inserted_at = NOW() - ($2 || ' days')::interval
         WHERE media_id = $1 AND to_state = 'released'
        """,
        [media_id, Integer.to_string(days_ago)]
      )
    after
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions ENABLE TRIGGER media_state_transitions_no_mutate",
        []
      )
    end
  end

  defp cleanup!(media_id) do
    # audit_log is not append-only-protected — a plain DELETE via the app's own
    # Nebu.Repo connection (owner role in this project's single-role dev/CI
    # deployment) is sufficient, no migrate-role trigger dance needed.
    Ecto.Adapters.SQL.query(Repo, "DELETE FROM audit_log WHERE target_id = $1", [media_id])

    conn = migrate_role_conn!()

    try do
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions DISABLE TRIGGER media_state_transitions_no_mutate",
        []
      )

      Postgrex.query(conn, "DELETE FROM media_state_transitions WHERE media_id = $1", [media_id])
      Postgrex.query(conn, "DELETE FROM media_files WHERE media_id = $1", [media_id])
    after
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions ENABLE TRIGGER media_state_transitions_no_mutate",
        []
      )
    end
  end

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    # ONLY Config's own read seam is overridden — the worker's own repo/
    # state-machine/audit-writer seams stay at their real defaults for this
    # file (Nebu.Repo, Nebu.Media.StateMachine, Nebu.Compliance.AuditWriter).
    Application.put_env(:nebu_http, :media_config_source, fn ->
      %{"released_delete_after_days" => 30}
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :media_config_source) end)

    :ok
  end

  test "a real :released row whose ledger transition is older than the configured " <>
         "window is soft-deleted for real, exercising released_for_days/1's real " <>
         "%DateTime{} clause (regression coverage for cycle-1 code-review finding 2)" do
    mid = media_id("real_released_expired")

    :ok = create_real_released!(mid)
    on_exit(fn -> cleanup!(mid) end)

    assert fetch_state!(mid) == "released"

    # Backdate the real ledger row the real transition/4 call just wrote, past
    # the configured 30-day released_delete_after_days window (31 days old,
    # same margin media_released_auto_delete_worker_test.exs's own unit test 2
    # uses for a 30-day window).
    backdate_released_transition!(mid, 31)

    assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

    assert fetch_state!(mid) == "deleted",
           "a real :released row whose media_state_transitions.inserted_at " <>
             "(a genuine TIMESTAMPTZ, decoded by Postgrex as %DateTime{}) is more than " <>
             "released_delete_after_days whole days old must be soft-deleted to :deleted"

    assert count_auto_deleted_audit_rows!(mid) == 1,
           "expected exactly one media_released_auto_deleted audit_log row for #{mid}"
  end
end
