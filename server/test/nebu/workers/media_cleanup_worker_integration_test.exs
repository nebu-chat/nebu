defmodule Nebu.Workers.MediaCleanupWorkerIntegrationTest do
  @moduledoc """
  Real-DB regression test for media-security-admin-control/8a-media-cleanup-worker's
  cycle-2 security-review fix (Kassandra F-1, MEDIUM): the `:deleted` candidate query
  was `state = 'deleted' AND deleted_at < NOW() - interval`, but nothing in the
  codebase ever writes `media_files.deleted_at` — `Nebu.Media.admin_delete/2`'s
  `StateMachine.transition/4` call never stamps it (only the `:hard_deleted` target
  has a column-stamping SQL variant), so the predicate matched zero rows forever in
  production. Every existing test in `media_cleanup_worker_test.exs` uses a `FakeRepo`
  that directly SEEDS `deleted_at` on the fake row and filters on it — presupposing
  exactly the population that doesn't actually exist, which is why that bug survived
  ATDD/test-review/CI/code-review.

  This file exercises the REAL, non-faked path end-to-end against a live PostgreSQL:
  the real `Nebu.Media.admin_delete/2` (the actual production producer of `:deleted`
  rows, Story 6a) drives a real `Nebu.Media.StateMachine.transition/4` call (the sole
  legal writer of `media_files.state`/`media_state_transitions`), and the real
  `Nebu.Workers.MediaCleanupWorker.perform/1` runs its candidate query against the
  real `Nebu.Repo` — none of the worker's own `:media_cleanup_repo_module` /
  `:media_state_machine_module` seams are swapped. Only `Nebu.Media.Storage` is
  swapped for a trivial in-process fake, so this test needs no real S3/MinIO
  connection — that dependency is orthogonal to the bug being regression-tested here
  (the candidate-selection query, not the object-storage delete). `AuditWriter` is
  also left at its real default (`Nebu.Repo`-backed), so the `media_hard_deleted`
  audit_log row is verified for real too.

  Since `now()` itself can't be moved into the past, this test proves the fix by
  backdating the one thing that legitimately can be: the real
  `media_state_transitions` ledger row admin_delete/2's real `transition/4` call just
  wrote for `to_state = 'deleted'` — the exact same age-anchor the (already-correct,
  unaffected-by-this-bug) `:infected` candidate query has relied on since this
  story's original implementation.

  Requires a live PostgreSQL — run via `make test-integration` / `mix test --include
  integration`. Follows the SAME no-Sandbox / real-connection / manual-cleanup
  convention already established by `state_machine_test.exs` (`@moduletag
  :integration`, unique per-run media ids, `async: false`), including its
  `nebu_migrate`-role DISABLE/ENABLE TRIGGER dance for touching the append-only
  `media_state_transitions` ledger (ADR-031's `media_state_transitions_no_mutate`
  trigger rejects a plain UPDATE/DELETE for every role, including the table owner).
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  @moduletag :integration

  alias Nebu.Media
  alias Nebu.Repo
  alias Nebu.Workers.MediaCleanupWorker

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "mcwi_#{@run_id}_#{suffix}"

  defp insert_media_file!(media_id, state, storage_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state, storage_key, file_hash)
      VALUES ($1, 'test.local', 'application/octet-stream', 1024, 'aeskeyhex', 'noncehex',
              '@tester:test.local', $2, false, $3, $4, 'deadbeef')
      """,
      [media_id, System.system_time(:millisecond), Atom.to_string(state), storage_key]
    )
  end

  defp fetch_row!(media_id) do
    %Postgrex.Result{rows: [[state, storage_key, uploader_user_id, hard_deleted_at]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT state, storage_key, uploader_user_id, hard_deleted_at
          FROM media_files
         WHERE media_id = $1
        """,
        [media_id]
      )

    %{
      state: state,
      storage_key: storage_key,
      uploader_user_id: uploader_user_id,
      hard_deleted_at: hard_deleted_at
    }
  end

  defp fetch_deleted_at!(media_id) do
    %Postgrex.Result{rows: [[deleted_at]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT deleted_at FROM media_files WHERE media_id = $1",
        [media_id]
      )

    deleted_at
  end

  defp count_hard_deleted_audit_rows!(media_id) do
    %Postgrex.Result{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM audit_log WHERE target_id = $1 AND action = 'media_hard_deleted'",
        [media_id]
      )

    count
  end

  # nebu_migrate is the actual table owner in this project's dual-role
  # docker-compose deployment (see state_machine_test.exs's own migrate_role_conn!/0)
  # — only the owner can DISABLE/ENABLE the append-only trigger without full
  # Postgres superuser, needed here purely to backdate a ledger timestamp for the
  # test (ADR-031's trigger otherwise rejects the UPDATE with SQLSTATE 23001 for
  # every role, including the owner).
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

  # Backdates the real ledger row admin_delete/2's real transition/4 call just
  # wrote for to_state = 'deleted', so the fixed candidate query's age check
  # (MAX(inserted_at) < NOW() - retention_interval) actually fires. `now()` cannot
  # be backdated; this ledger row's `inserted_at` is the one legitimate stand-in,
  # exactly mirroring how the sibling :infected query's age is anchored.
  defp backdate_deleted_transition!(media_id, days_ago), do: backdate_transition!(media_id, "deleted", days_ago)

  defp backdate_transition!(media_id, to_state, days_ago) do
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
         WHERE media_id = $1 AND to_state = $3
        """,
        [media_id, Integer.to_string(days_ago), to_state]
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

  # Trivial fake for Nebu.Media.Storage.delete/1 — the ONLY seam this test
  # swaps. Avoids a real S3/MinIO network dependency, which is orthogonal to
  # the F-1 bug this test regresses against (the :deleted candidate SELECT,
  # not the object-storage delete step). Test-private.
  defmodule FakeStorage do
    @moduledoc "Test-private fake for Nebu.Media.Storage.delete/1."
    def delete(_key), do: :ok
  end

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    Application.put_env(:nebu_http, :media_storage_module, FakeStorage)
    on_exit(fn -> Application.delete_env(:nebu_http, :media_storage_module) end)

    # the default-window tests must not see a value saved by a developer or leaked by another test
    Nebu.OAuth.TestSupport.privileged_sql!("DELETE FROM media_config WHERE key IN ('deleted_days', 'infected_days')", [])
    on_exit(fn -> Nebu.OAuth.TestSupport.privileged_sql!("DELETE FROM media_config WHERE key IN ('deleted_days', 'infected_days')", []) end)

    :ok
  end

  test "admin_delete/2 -> real :deleted row past deleted_days is hard-deleted by the " <>
         "worker's real ledger-derived candidate query (regression for Kassandra F-1)" do
    mid = media_id("real_deleted_expired")
    admin_id = "@kai:test.local"
    storage_key = "storage-key-#{mid}"

    insert_media_file!(mid, :quarantined, storage_key)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :deleted} = Media.admin_delete(mid, admin_id)
    assert fetch_row!(mid).state == "deleted"

    # Confirms F-1's premise directly, against the real DB: admin_delete/2 never
    # stamps deleted_at. If this assertion ever fails, F-1 (and the rationale for
    # this fix) is stale and the query should be revisited.
    assert fetch_deleted_at!(mid) == nil,
           "media_files.deleted_at is expected to stay NULL forever (Kassandra F-1's " <>
             "documented premise) — if this fails, this fix's rationale is stale"

    # Backdate the real ledger row admin_delete/2's transition/4 call just wrote,
    # past the default 30-day deleted_days retention window.
    backdate_deleted_transition!(mid, 31)

    assert :ok = perform_job(MediaCleanupWorker, %{})

    row = fetch_row!(mid)
    assert row.state == "hard_deleted"
    assert row.storage_key == nil
    assert row.uploader_user_id == nil
    assert row.hard_deleted_at != nil

    assert count_hard_deleted_audit_rows!(mid) == 1,
           "expected exactly one media_hard_deleted audit_log row for #{mid}"
  end

  test "a real :deleted row within the retention window is left untouched by the " <>
         "worker's real candidate query" do
    mid = media_id("real_deleted_fresh")
    admin_id = "@kai:test.local"
    storage_key = "storage-key-#{mid}"

    insert_media_file!(mid, :quarantined, storage_key)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :deleted} = Media.admin_delete(mid, admin_id)

    # No backdating — the transition just happened for real, well inside the
    # default 30-day deleted_days window.
    assert :ok = perform_job(MediaCleanupWorker, %{})

    row = fetch_row!(mid)
    assert row.state == "deleted", "must not be hard-deleted while inside the retention window"
    assert row.storage_key == storage_key
    assert count_hard_deleted_audit_rows!(mid) == 0
  end

  # ─── story media-cleanup-reads-media-config (follow-up du): the REAL media_config rows decide ──

  # media_config has no DELETE policy for the runtime role (FORCE ROW LEVEL SECURITY): a plain Repo DELETE silently deletes nothing
  defp set_config!(key, value) do
    Nebu.OAuth.TestSupport.privileged_sql!(
      "INSERT INTO media_config (key, value, set_at) VALUES ($1, $2, 1) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [key, value]
    )
  end

  defp infected_row!(suffix, days_ago) do
    mid = media_id(suffix)
    insert_media_file!(mid, :scanning, "storage-key-#{mid}")
    on_exit(fn -> cleanup!(mid) end)
    assert {:ok, :infected} = Nebu.Media.StateMachine.transition(mid, :infected, {:system, nil}, %{})
    backdate_transition!(mid, "infected", days_ago)
    mid
  end

  defp deleted_row!(suffix, days_ago) do
    mid = media_id(suffix)
    insert_media_file!(mid, :quarantined, "storage-key-#{mid}")
    on_exit(fn -> cleanup!(mid) end)
    assert {:ok, :deleted} = Media.admin_delete(mid, "@kai:test.local")
    backdate_deleted_transition!(mid, days_ago)
    mid
  end

  describe "retention windows from the real media_config table" do
    test "a stored deleted_days of 10 deletes a row 11 days old and keeps one 9 days old (days, real interval arithmetic, no restart)" do
      set_config!("deleted_days", "10")
      old = deleted_row!("cfg10_old", 11)
      young = deleted_row!("cfg10_young", 9)

      assert :ok = perform_job(MediaCleanupWorker, %{})

      assert fetch_row!(old).state == "hard_deleted"
      assert fetch_row!(young).state == "deleted"
    end

    test "a window longer than the default keeps a row the old default (30 days) would have deleted; a later shortening deletes it at the next run" do
      set_config!("deleted_days", "90")
      mid = deleted_row!("cfg90", 31)

      assert :ok = perform_job(MediaCleanupWorker, %{})
      assert fetch_row!(mid).state == "deleted", "window 90: 31 days old stays"

      set_config!("deleted_days", "30")
      assert :ok = perform_job(MediaCleanupWorker, %{})
      assert fetch_row!(mid).state == "hard_deleted", "the admin shortened the window: the next run deletes it, no restart"
    end

    test "fail-safe: a damaged stored value (not a number / negative / too large) deletes nothing, however old the row" do
      mid = deleted_row!("cfg_damaged", 3000)

      for bad <- ["abc", "", "-5", "3651"] do
        set_config!("deleted_days", bad)

        capture = ExUnit.CaptureLog.capture_log([level: :error], fn -> assert :ok = perform_job(MediaCleanupWorker, %{}) end)

        assert fetch_row!(mid).state == "deleted", "stored #{inspect(bad)}: nothing may be deleted"
        assert capture =~ "retention config unavailable"
      end
    end

    test "the default :infected window is 7 days against the real interval arithmetic (8 days old deleted, 6 days old kept)" do
      old = infected_row!("def_inf_old", 8)
      young = infected_row!("def_inf_young", 6)

      assert :ok = perform_job(MediaCleanupWorker, %{})

      assert fetch_row!(old).state == "hard_deleted"
      assert fetch_row!(young).state == "infected"
    end

    test "a stored infected_days of 3 deletes a 4 day old and keeps a 2 day old :infected row; 0 deletes a :deleted row of yesterday; 3650 keeps a 3649 day old one" do
      set_config!("infected_days", "3")
      i_old = infected_row!("cfg3_old", 4)
      i_young = infected_row!("cfg3_young", 2)
      assert :ok = perform_job(MediaCleanupWorker, %{})
      assert fetch_row!(i_old).state == "hard_deleted"
      assert fetch_row!(i_young).state == "infected"

      set_config!("deleted_days", "0")
      d_yesterday = deleted_row!("cfg0", 1)
      assert :ok = perform_job(MediaCleanupWorker, %{})
      assert fetch_row!(d_yesterday).state == "hard_deleted"

      set_config!("deleted_days", "3650")
      d_old = deleted_row!("cfg3650", 3649)
      assert :ok = perform_job(MediaCleanupWorker, %{})
      assert fetch_row!(d_old).state == "deleted"
    end

    test "a damaged infected_days also stops the :deleted phase (all-or-nothing read), the row stays" do
      set_config!("infected_days", "abc")
      mid = deleted_row!("cfg_infected_damaged", 3000)

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = perform_job(MediaCleanupWorker, %{}) end)

      assert fetch_row!(mid).state == "deleted"
    end
  end
end
