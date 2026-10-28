defmodule Nebu.Media.ConfigRetentionAtomicTest do
  @moduledoc """
  Acceptance tests for story `media-retention-audit-atomic` (follow-up `dn`, owner scope: `released_delete_after_days`, `deleted_days`, `infected_days`),
  AC1 - AC7 (decisions D1 - D4, D6): `Nebu.Media.Config.upsert/3` writes the value of the three retention keys and its `media_config_updated` row in ONE
  transaction, with a policy per direction when the audit row cannot be written.

  Part 1 (no database, runs in the unit job): the orchestration around the transaction, which the test seam `:nebu_http, :media_config_tx` replaces.
  Part 2 (integration, real PostgreSQL, the runtime role `nebu_app`, the REAL `Nebu.Compliance.AuditWriter`): the real transaction, the rollback, the nested
  audit writer, the cache refresh after the commit, the lock proof (a deterministic interleaving of two saves).

  ## Seam contract of the implementation (D6, pattern `:admin_config_tx` of `Nebu.Admin.DB`)

  `Application.get_env(:nebu_http, :media_config_tx)`: a 4-arity function `fn key, value, audit, guard -> :ok | {:error, term} end`, read ONLY inside
  `if Mix.env() == :test do ... else ... end` (compile-guarded, same layout as `run_config_tx/3` of `Nebu.Admin.DB`: the static test below strips that block),
  consulted ONLY for the three retention keys. It REPLACES the database transaction:

    * `key` is the binary key, `value` the validated typed value (integer, or `nil` for `released_delete_after_days`).
    * `audit` is `nil` or a 1-arity function over the OLD value: `audit.(old) :: :ok | {:error, reason}`. It NEVER raises (the implementation wraps the
      audit writer: a raise, an error tuple, a non-`:ok` answer all count as a failed audit). `old` is the EFFECTIVE old value read inside the transaction
      under the lock (the stored decoded value, or the default of the key when no row exists: `30` / `90` / `nil`). The function writes the
      `media_config_updated` row (`AuditWriter.log/6`, metadata `%{key:, old_value:, new_value:}`, the actor of `upsert/3`).
    * `guard` is `nil` or a 1-arity function over the OLD value: `guard.(old) :: boolean`, `true` = the change is no data-deleting step (lengthening,
      disabling or unchanged). It is passed ONLY together with `audit == nil` (the retry): the real transaction evaluates it AFTER taking the lock and BEFORE
      the write, and rolls back with `{:error, {:audit, _}}` when it is not `true`.
    * Return: `:ok` (committed), `{:error, {:audit, reason}}` (rolled back because the audit failed or the guard refused), any other `{:error, reason}`
      (rolled back, no retry).

  Orchestration (what the tests pin): first call `(key, value, audit_fun, nil)`. A failed audit (`{:error, {:audit, _}}`) triggers EXACTLY ONE retry
  `(key, value, nil, guard_fun)`; a call with `audit == nil` AND `guard == nil` never happens (an unaudited write is always direction-guarded under the lock).
  A refused guard answers `{:error, {:audit, _}}` (shortening: nothing persisted); a passed guard answers `:ok` after one value-free ERROR log (key only).
  The cache refresh (loader re-read) and the `:pg` broadcast happen once after a commit and never after a rollback.

  Precedence of the seams for the three keys: `:media_config_tx` > `:media_config_writer` (the existing sequential fake path, which cannot roll back, stays
  for every key: the existing unit tests keep working) > the real transaction. Every OTHER key never calls `:media_config_tx`.

  Direction (pure policy, tested through the guard): `deleted_days` / `infected_days`: lengthening iff `new >= old` (0 is the shortest retention).
  `released_delete_after_days`: `nil` AND `0` both mean "off" (the worker `MediaReleasedAutoDeleteWorker` treats 0 as invalid = off): a new `nil` or `0` is a
  deactivation (lengthening); an old `nil` or `0` followed by a positive number is a SHORTENING (0 -> 5 too); positive -> positive: lengthening iff `new >= old`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Media.Config
  alias Nebu.OAuth.TestSupport, as: T

  @actor "@retention-admin:test.local"

  @defaults %{"deleted_days" => 30, "infected_days" => 90, "released_delete_after_days" => nil}

  # {key, old, new}: the effective old value (a nil old of released_delete_after_days = unset), the new one
  @shortening [
    {"deleted_days", 30, 7},
    {"deleted_days", 30, 0},
    {"infected_days", 90, 30},
    {"infected_days", 90, 0},
    {"released_delete_after_days", nil, 14},
    {"released_delete_after_days", 30, 14},
    # 0 = off like nil (the worker treats 0 as invalid = off): from "off" to a positive number is a shortening (story D2b)
    {"released_delete_after_days", 0, 5}
  ]

  # lengthening, disabling and unchanged (equal = no data is deleted sooner)
  @lengthening [
    {"deleted_days", 30, 60},
    {"deleted_days", 0, 30},
    {"deleted_days", 30, 30},
    {"infected_days", 90, 180},
    {"infected_days", 90, 90},
    {"released_delete_after_days", 14, 30},
    {"released_delete_after_days", 14, nil},
    {"released_delete_after_days", 14, 14},
    {"released_delete_after_days", nil, nil},
    # 0 = off like nil (story D2b): a positive number -> 0 is a deactivation, off -> off is no change in effect
    {"released_delete_after_days", 5, 0},
    {"released_delete_after_days", nil, 0},
    {"released_delete_after_days", 0, nil},
    {"released_delete_after_days", 0, 0}
  ]

  # the raising audit writer is a second way to fail the audit: one shortening and one lengthening per key are enough, the truth table runs in the
  # "error answer" mode
  @raising_shortening [{"deleted_days", 30, 7}, {"infected_days", 90, 30}, {"released_delete_after_days", 30, 14}]
  @raising_lengthening [{"deleted_days", 30, 60}, {"infected_days", 90, 180}, {"released_delete_after_days", 14, 30}]

  # ─── fakes ────────────────────────────────────────────────────────────────

  defmodule FakeAuditRepo do
    @moduledoc "In-process fake for Nebu.Repo used by AuditWriter (a working audit table). Test-private."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      bucket = Application.get_env(:compliance, :__test_media_config_audit_bucket__)
      if bucket, do: Agent.update(bucket, fn rows -> rows ++ [struct] end)
      {:ok, struct}
    end

    def insert!(struct, opts \\ []) do
      {:ok, s} = insert(struct, opts)
      s
    end
  end

  defmodule FailingAuditRepo do
    @moduledoc "AuditWriter.log/6 degrades to {:error, :audit_write_failed} (its documented Repo-down path). Test-private."

    def transaction(fun) when is_function(fun, 0) do
      fun.()
      {:ok, nil}
    rescue
      _ -> {:error, :simulated_audit_failure}
    end

    def insert(_struct, _opts \\ []), do: {:error, :simulated_audit_failure}
    def insert!(_struct, _opts \\ []), do: raise("FailingAuditRepo: simulated audit write failure")
  end

  defmodule RaisingAuditRepo do
    @moduledoc "AuditWriter.log/6 RAISES (a non-RuntimeError, as a database error does: the writer only rescues RuntimeError). Test-private."

    def transaction(_fun), do: raise(ArgumentError, "RaisingAuditRepo: simulated database error")
    def insert(_struct, _opts \\ []), do: raise(ArgumentError, "RaisingAuditRepo")
    def insert!(_struct, _opts \\ []), do: raise(ArgumentError, "RaisingAuditRepo")
  end

  # ─── setup ────────────────────────────────────────────────────────────────

  setup do
    {:ok, store} = Agent.start_link(fn -> @defaults end)
    {:ok, bucket} = Agent.start_link(fn -> [] end)

    Application.put_env(:compliance, :__test_media_config_audit_bucket__, bucket)
    Application.put_env(:compliance, :repo, FakeAuditRepo)

    for k <- [:media_config_tx, :media_config_writer, :media_config_loader, :media_config_source], do: Application.delete_env(:nebu_http, k)

    on_exit(fn ->
      Application.delete_env(:compliance, :__test_media_config_audit_bucket__)
      Application.delete_env(:compliance, :repo)
      for k <- [:media_config_tx, :media_config_writer, :media_config_loader, :media_config_source], do: Application.delete_env(:nebu_http, k)

      if pid = Process.whereis(Nebu.Media.Config) do
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    {:ok, store: store, bucket: bucket}
  end

  # a fake of the transaction (cannot truly roll back: it only commits when everything passes). `old` = the fake's effective stored value
  defp install_tx(store, opts \\ []) do
    test_pid = self()
    after_failed_audit = Keyword.get(opts, :after_failed_audit, fn _store, _key -> :ok end)

    Application.put_env(:nebu_http, :media_config_tx, fn key, value, audit, guard ->
      send(test_pid, {:tx, key, value, audit != nil, guard != nil})
      old = Agent.get(store, &Map.fetch!(&1, key))

      cond do
        is_function(guard, 1) and guard.(old) != true ->
          {:error, {:audit, :not_lengthening}}

        is_function(audit, 1) ->
          case audit.(old) do
            :ok ->
              Agent.update(store, &Map.put(&1, key, value))
              :ok

            {:error, reason} ->
              after_failed_audit.(store, key)
              {:error, {:audit, reason}}
          end

        true ->
          Agent.update(store, &Map.put(&1, key, value))
          :ok
      end
    end)
  end

  defp seed(store, key, old), do: Agent.update(store, &Map.put(&1, key, old))
  defp stored(store, key), do: Agent.get(store, &Map.fetch!(&1, key))
  defp audit_rows(bucket), do: Agent.get(bucket, & &1)

  defp drain_tx(acc \\ []) do
    receive do
      {:tx, key, value, audit?, guard?} -> drain_tx([{key, value, audit?, guard?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_pg do
    receive do
      {:invalidate_media_config} -> flush_pg()
    after
      0 -> :ok
    end
  end

  defp ensure_started do
    case Config.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Part 1 (no database): the policy per direction, orchestration around the transaction
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC2 shortening, failing audit (DB-less)" do
    for {key, old, new} <- @shortening,
        {mode, repo} <- [{"error answer", FailingAuditRepo}, {"raising audit writer", RaisingAuditRepo}],
        mode == "error answer" or {key, old, new} in @raising_shortening do
      test "#{key} #{inspect(old)} -> #{inspect(new)} (#{mode}): refused, value unchanged, unaudited attempts are guarded", %{store: store} do
        Application.put_env(:compliance, :repo, unquote(repo))
        seed(store, unquote(key), unquote(old))
        install_tx(store)

        capture_log(fn -> send(self(), {:result, Config.upsert(unquote(key), unquote(new), @actor)}) end)
        assert_received {:result, result}

        assert {:error, {:audit, _reason}} = result
        assert stored(store, unquote(key)) == unquote(old), "a refused shortening persists NOTHING"

        calls = drain_tx()
        assert [{unquote(key), unquote(new), true, false} | retries] = calls, "the first attempt carries the audit function and no guard"
        assert length(retries) <= 1, "at most ONE retry"
        assert Enum.all?(retries, &(&1 == {unquote(key), unquote(new), false, true})), "an unaudited attempt always carries the direction guard, got #{inspect(retries)}"
      end
    end
  end

  describe "AC3 lengthening / disabling / unchanged, failing audit (DB-less)" do
    for {key, old, new} <- @lengthening,
        {mode, repo} <- [{"error answer", FailingAuditRepo}, {"raising audit writer", RaisingAuditRepo}],
        mode == "error answer" or {key, old, new} in @raising_lengthening do
      test "#{key} #{inspect(old)} -> #{inspect(new)} (#{mode}): :ok, the value is persisted without the row", %{store: store} do
        Application.put_env(:compliance, :repo, unquote(repo))
        seed(store, unquote(key), unquote(old))
        install_tx(store)

        capture_log(fn -> send(self(), {:result, Config.upsert(unquote(key), unquote(new), @actor)}) end)
        assert_received {:result, result}

        assert drain_tx() == [{unquote(key), unquote(new), true, false}, {unquote(key), unquote(new), false, true}],
               "attempt 1 with the audit function, then exactly ONE retry without it (direction-guarded)"

        assert :ok = result
        assert stored(store, unquote(key)) == unquote(new)
      end
    end
  end

  describe "AC1 working audit (DB-less)" do
    for {key, old, new} <- @shortening ++ @lengthening do
      test "#{key} #{inspect(old)} -> #{inspect(new)}: :ok, persisted, ONE row (target, metadata old / new, actor)", %{store: store, bucket: bucket} do
        seed(store, unquote(key), unquote(old))
        install_tx(store)

        assert :ok = Config.upsert(unquote(key), unquote(new), @actor)

        assert drain_tx() == [{unquote(key), unquote(new), true, false}], "ONE transaction call, no retry"
        assert stored(store, unquote(key)) == unquote(new)

        assert [row] = audit_rows(bucket)
        assert row.action == "media_config_updated"
        assert row.target_type == "media_config"
        assert row.target_id == unquote(key)
        assert row.actor_user_id == @actor
        assert row.outcome == "success"
        assert row.metadata == %{key: unquote(key), old_value: unquote(old), new_value: unquote(new)}
      end
    end

    test "the arity-2 call keeps the system actor", %{store: store, bucket: bucket} do
      install_tx(store)
      assert :ok = Config.upsert("deleted_days", 7)
      assert [{"deleted_days", 7, true, false}] = drain_tx()
      assert [row] = audit_rows(bucket)
      assert row.actor_user_id == "system:media_config"
    end
  end

  describe "AC3 value-free ERROR log (DB-less)" do
    # the ERROR lines that name the key (the audit writer's own error line does not)
    defp key_lines(log, key), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ key))

    test "one ERROR names the key and contains neither the old nor the new value", %{store: store} do
      seed(store, "deleted_days", 2321)
      install_tx(store)
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      log = capture_log([level: :error], fn -> send(self(), {:result, Config.upsert("deleted_days", 3487, @actor)}) end)

      assert_received {:result, :ok}
      assert [{"deleted_days", 3487, true, false}, {"deleted_days", 3487, false, true}] = drain_tx(), "the unaudited retry went through the transaction seam"
      assert log =~ "[error]", "an ERROR is logged"
      assert [line] = key_lines(log, "deleted_days"), "exactly ONE line names the key (not one per attempt)"
      assert line =~ "applied without audit"
      refute log =~ "2321", "no old value in the log"
      refute log =~ "3487", "no new value in the log"
      refute log =~ @actor, "no actor in the log (key only)"
      refute log =~ "audit_write_failed", "key only: not the writer's reason either"
    end

    test "D2b a refused shortening logs ONE value-free ERROR naming the key and the direction", %{store: store} do
      seed(store, "deleted_days", 3487)
      install_tx(store)
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      log = capture_log([level: :error], fn -> send(self(), {:result, Config.upsert("deleted_days", 2321, @actor)}) end)

      assert_received {:result, {:error, {:audit, _}}}
      assert [line] = key_lines(log, "deleted_days"), "exactly ONE line names the key"
      assert line =~ "shortening refused"
      refute log =~ "3487"
      refute log =~ "2321"
      refute log =~ @actor
      refute log =~ "audit_write_failed"
    end

    test "D2b released_delete_after_days 0 -> 5 (from \"off\", a shortening): refused with the ERROR \"shortening refused\", no value", %{store: store} do
      seed(store, "released_delete_after_days", 0)
      install_tx(store)
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      log = capture_log([level: :error], fn -> send(self(), {:result, Config.upsert("released_delete_after_days", 5, @actor)}) end)

      assert_received {:result, {:error, {:audit, _}}}
      assert stored(store, "released_delete_after_days") == 0
      assert [line] = key_lines(log, "released_delete_after_days")
      assert line =~ "shortening refused"
    end

    test "released_delete_after_days 1234 -> unset (disabling): the ERROR names the key, no value", %{store: store} do
      seed(store, "released_delete_after_days", 1234)
      install_tx(store)
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      log = capture_log([level: :error], fn -> send(self(), {:result, Config.upsert("released_delete_after_days", nil, @actor)}) end)

      assert_received {:result, :ok}
      assert [{"released_delete_after_days", nil, true, false}, {"released_delete_after_days", nil, false, true}] = drain_tx()
      assert [_line] = key_lines(log, "released_delete_after_days")
      refute log =~ "1234"
      refute log =~ @actor
    end
  end

  describe "AC5 direction read under the lock at retry (DB-less)" do
    test "a lengthening committed by another admin between the attempts turns this save into a shortening: refused, the newer value stays", %{store: store} do
      # stored 30; this save writes 45 (a lengthening against 30). While its audit fails, another admin commits 90: 45 is now a SHORTENING
      seed(store, "deleted_days", 30)
      install_tx(store, after_failed_audit: fn s, key -> seed(s, key, 90) end)
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      capture_log(fn -> send(self(), {:result, Config.upsert("deleted_days", 45, @actor)}) end)
      assert_received {:result, result}

      assert {:error, {:audit, _}} = result, "the classification of attempt 1 must not be reused: the guard re-reads the old value on the retry"
      assert stored(store, "deleted_days") == 90, "the 45 was NOT persisted unaudited"
    end

    test "the opposite: a concurrent shortening between the attempts leaves this save a lengthening: persisted", %{store: store} do
      seed(store, "infected_days", 90)
      install_tx(store, after_failed_audit: fn s, key -> seed(s, key, 20) end)
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      capture_log(fn -> send(self(), {:result, Config.upsert("infected_days", 30, @actor)}) end)
      assert_received {:result, :ok}
      assert stored(store, "infected_days") == 30
    end
  end

  describe "AC4 refresh only after a commit (DB-less)" do
    setup %{store: store} do
      test_pid = self()
      {:ok, ref} = Agent.start_link(fn -> :counters.new(1, []) end)
      refreshes = Agent.get(ref, & &1)

      # counts only the re-reads of the cache holder (the GenServer process): a loader call of the caller (e.g. an old value lookup) is no refresh
      Application.put_env(:nebu_http, :media_config_loader, fn ->
        if self() == Process.whereis(Config), do: :counters.add(refreshes, 1, 1)
        Agent.get(store, fn rows -> Map.take(rows, ["deleted_days", "infected_days", "released_delete_after_days"]) end)
      end)

      ensure_started()
      :ok = Config.refresh()

      _ = :pg.start_link()
      :pg.join(Config.pg_group(), test_pid)
      on_exit(fn -> :pg.leave(Config.pg_group(), test_pid) end)
      flush_pg()

      {:ok, refreshes: refreshes}
    end

    test "a refused shortening refreshes nothing: no loader re-read, no broadcast, the cache keeps its value", %{store: store, refreshes: refreshes} do
      install_tx(store)
      Application.put_env(:compliance, :repo, FailingAuditRepo)
      before = :counters.get(refreshes, 1)

      capture_log(fn -> send(self(), {:result, Config.upsert("deleted_days", 7, @actor)}) end)
      assert_received {:result, {:error, {:audit, _}}}

      assert :counters.get(refreshes, 1) == before, "no refresh after a rollback"
      refute_receive {:invalidate_media_config}, 150
      assert Config.get().deleted_days == 30
    end

    test "another error (:db_down) is passed through: no retry, no refresh, no broadcast", %{refreshes: refreshes} do
      test_pid = self()

      Application.put_env(:nebu_http, :media_config_tx, fn key, value, audit, guard ->
        send(test_pid, {:tx, key, value, audit != nil, guard != nil})
        {:error, :db_down}
      end)

      before = :counters.get(refreshes, 1)

      assert {:error, :db_down} = Config.upsert("deleted_days", 60, @actor)

      assert [{"deleted_days", 60, true, false}] = drain_tx(), "exactly ONE call: only an {:error, {:audit, _}} is retried"
      assert :counters.get(refreshes, 1) == before
      refute_receive {:invalidate_media_config}, 150
    end

    test "a committed (audited) change refreshes the cache ONCE and broadcasts ONCE", %{store: store, refreshes: refreshes} do
      install_tx(store)
      before = :counters.get(refreshes, 1)

      assert :ok = Config.upsert("deleted_days", 7, @actor)

      assert :counters.get(refreshes, 1) == before + 1, "exactly one refresh"
      assert_receive {:invalidate_media_config}, 500
      refute_receive {:invalidate_media_config}, 100
      assert Config.get().deleted_days == 7
    end

    test "a committed unaudited lengthening (the retry) refreshes ONCE, not once per attempt", %{store: store, refreshes: refreshes} do
      install_tx(store)
      Application.put_env(:compliance, :repo, FailingAuditRepo)
      before = :counters.get(refreshes, 1)

      capture_log(fn -> send(self(), {:result, Config.upsert("deleted_days", 60, @actor)}) end)
      assert_received {:result, :ok}

      assert :counters.get(refreshes, 1) == before + 1
      assert_receive {:invalidate_media_config}, 500
      refute_receive {:invalidate_media_config}, 100
      assert Config.get().deleted_days == 60
    end
  end

  describe "AC6 other keys unchanged (DB-less)" do
    @other_keys [
      {"max_upload_size_bytes", 1_234_567},
      {"max_file_size_bytes", 7_654_321},
      {"max_pending_per_user", 3},
      {"max_stall_ms", 4_000},
      {"orphaned_hours", 12},
      {"webhook_url", "https://93.184.216.34/hook"},
      {"mime_denylist", "application/x-msdownload"},
      {"clamav_down_alert_minutes", 7},
      {"scan_kill_switch", "fail_open"}
    ]

    setup %{store: store} do
      test_pid = self()
      Application.put_env(:nebu_http, :media_config_tx, fn key, _value, _audit, _guard ->
        send(test_pid, {:tx_must_not_run, key})
        {:error, :must_not_run}
      end)

      Application.put_env(:nebu_http, :media_config_loader, fn -> Agent.get(store, &Map.take(&1, ["deleted_days"])) end)

      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:written, key, value})
        :ok
      end)

      :ok
    end

    for {key, value} <- @other_keys do
      test "#{key}: written through the writer seam, ONE audit row, no transaction call", %{bucket: bucket} do
        assert :ok = Config.upsert(unquote(key), unquote(value), @actor)
        assert_received {:written, unquote(key), unquote(value)}
        refute_received {:tx_must_not_run, _}
        assert [%{action: "media_config_updated", target_id: unquote(key)}] = audit_rows(bucket)
      end

      test "#{key}: a failing audit is only logged, the answer stays :ok and the value stays written (best-effort, unchanged)" do
        Application.put_env(:compliance, :repo, FailingAuditRepo)
        log = capture_log(fn -> send(self(), {:result, Config.upsert(unquote(key), unquote(value), @actor)}) end)

        assert_received {:result, :ok}
        assert_received {:written, unquote(key), unquote(value)}
        refute_received {:tx_must_not_run, _}
        assert log =~ "media_config_updated audit write failed"
      end
    end
  end

  describe "D6 seam precedence" do
    test "the transaction seam wins over the writer seam for the three keys: the writer fake is not called", %{store: store} do
      test_pid = self()
      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:written, key, value})
        :ok
      end)
      Application.put_env(:nebu_http, :media_config_loader, fn -> %{} end)
      install_tx(store)

      assert :ok = Config.upsert("deleted_days", 60, @actor)

      assert_received {:tx, "deleted_days", 60, true, false}
      refute_received {:written, _, _}
    end

    test "WITHOUT the transaction seam the writer / loader fakes keep working for the three keys (sequential fake path): written, audited best-effort, :ok", %{bucket: bucket} do
      test_pid = self()
      Application.put_env(:nebu_http, :media_config_loader, fn -> %{"deleted_days" => 30} end)
      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:written, key, value})
        :ok
      end)

      assert :ok = Config.upsert("deleted_days", 7, @actor)
      assert_received {:written, "deleted_days", 7}
      assert [%{metadata: %{key: "deleted_days", old_value: 30, new_value: 7}}] = audit_rows(bucket)

      Application.put_env(:compliance, :repo, FailingAuditRepo)
      log = capture_log(fn -> send(self(), {:r, Config.upsert("infected_days", 3, @actor)}) end)
      assert_received {:r, :ok}
      assert log =~ "media_config_updated audit write failed"
    end
  end

  describe "AC7 validation first (DB-less)" do
    test "invalid values of the three keys and an unknown key never reach the transaction, the writer, the loader or the audit", %{store: store, bucket: bucket} do
      test_pid = self()
      install_tx(store)
      Application.put_env(:nebu_http, :media_config_loader, fn ->
        send(test_pid, :loader_called)
        %{}
      end)
      Application.put_env(:nebu_http, :media_config_writer, fn key, value, _set_at ->
        send(test_pid, {:written, key, value})
        :ok
      end)

      invalid = [
        {"deleted_days", -1},
        {"deleted_days", nil},
        {"deleted_days", "7"},
        {"deleted_days", 1.5},
        {"infected_days", -5},
        {"infected_days", :forever},
        {"released_delete_after_days", -1},
        {"released_delete_after_days", "14"},
        {"released_delete_after_days", 1.5},
        {"retention_days", 7}
      ]

      for {key, value} <- invalid do
        assert {:error, _} = Config.upsert(key, value, @actor), "#{key} #{inspect(value)} must be rejected"
      end

      assert drain_tx() == []
      refute_received {:written, _, _}
      refute_received :loader_called
      assert audit_rows(bucket) == []
    end
  end

  describe "static hygiene (D1, D6)" do
    @config Path.expand("../../../lib/nebu/media/config.ex", __DIR__)

    # anti-regression only: the behaviour (one transaction, the lock) is proven against the database below
    test "the audit row is still written by AuditWriter.log/6 as media_config_updated (nothing new in @known_actions)" do
      code = @config |> File.read!() |> String.replace(~r/@(module)?doc """.*?"""/s, "") |> String.replace(~r/^\s*#.*$/m, "")

      assert code =~ "AuditWriter.log("
      assert code =~ "media_config_updated"
    end

    # the layout is pinned on purpose (same as `run_config_tx/3` of Nebu.Admin.DB): the test strips the compile-guarded block and looks for the seam outside it
    test "the transaction seam is read only inside `if Mix.env() == :test` (compile-guarded)" do
      src = File.read!(@config)
      assert src =~ ":media_config_tx", "the seam exists"
      assert src =~ ~r/  if Mix\.env\(\) == :test do.*:media_config_tx.*?\n  else\n/s, "inside an `if Mix.env() == :test do ... else` block"

      guarded = Regex.replace(~r/  if Mix\.env\(\) == :test do.*?\n  else\n/s, src, "")
      code = guarded |> String.replace(~r/@(module)?doc """.*?"""/s, "") |> String.replace(~r/^\s*#.*$/m, "")
      refute code =~ ":media_config_tx", "the seam is read only inside `if Mix.env() == :test`"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Part 2 (integration): the real transaction against PostgreSQL, the real AuditWriter
  # ═══════════════════════════════════════════════════════════════════════════

  describe "the real transaction (integration)" do
    @describetag :integration

    @keys ["deleted_days", "infected_days", "released_delete_after_days", "max_upload_size_bytes"]
    @lock_id 7_410_021

    setup do
      prior = T.privileged_sql!("SELECT key, value, set_at FROM media_config WHERE key = ANY($1)", [@keys]).rows
      T.privileged_sql!("DELETE FROM media_config WHERE key = ANY($1)", [@keys])
      T.privileged_sql!("DELETE FROM audit_log WHERE action = 'media_config_updated' AND target_id = ANY($1)", [@keys])

      # the real database path: no fake seam, the real audit writer
      Application.delete_env(:compliance, :repo)
      Application.delete_env(:compliance, :__test_media_config_audit_bucket__)
      ensure_started()
      :ok = Config.refresh()

      on_exit(fn ->
        Application.delete_env(:compliance, :repo)
        drop_hooks!()
        T.privileged_sql!("DELETE FROM media_config WHERE key = ANY($1)", [@keys])
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
        T.privileged_sql!("DELETE FROM audit_log WHERE action = 'media_config_updated' AND target_id = ANY($1)", [@keys])
        if Process.whereis(Nebu.Media.Config), do: Config.refresh()
      end)

      :ok
    end

    defp db_seed(_key, :none), do: :ok
    defp db_seed(key, nil), do: T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ($1, '', 1)", [key])
    defp db_seed(key, value), do: T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ($1, $2, 1)", [key, to_string(value)])

    defp db_value(key), do: T.sql!("SELECT value FROM media_config WHERE key = $1", [key]).rows |> List.first() |> List.wrap() |> List.first()
    defp db_rows(key), do: T.privileged_sql!("SELECT actor_user_id, target_type, metadata FROM audit_log WHERE action = 'media_config_updated' AND target_id = $1 ORDER BY id", [key]).rows

    # the VALUE write of `deleted_days` fails with a database error (a trigger on media_config)
    defp fail_deleted_days_value_writes! do
      drop_hooks!()
      T.privileged_sql!("CREATE FUNCTION public.media_retention_atdd_value_hook() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'media retention atdd: value write refused'; END $$ LANGUAGE plpgsql")
      T.privileged_sql!("CREATE TRIGGER media_retention_atdd_value_hook BEFORE INSERT OR UPDATE ON media_config FOR EACH ROW WHEN (NEW.key = 'deleted_days') EXECUTE FUNCTION public.media_retention_atdd_value_hook()")
    end

    defp xid_of_value(key), do: T.privileged_sql!("SELECT xmin::text FROM media_config WHERE key = $1", [key]).rows |> List.first() |> List.first()
    defp xid_of_audit(key), do: T.privileged_sql!("SELECT xmin::text FROM audit_log WHERE action = 'media_config_updated' AND target_id = $1 ORDER BY id DESC LIMIT 1", [key]).rows |> List.first() |> List.first()

    defp drop_hooks! do
      T.privileged_sql!("DROP TRIGGER IF EXISTS media_retention_atdd_hook ON audit_log")
      T.privileged_sql!("DROP TRIGGER IF EXISTS media_retention_atdd_value_hook ON media_config")
      T.privileged_sql!("DROP FUNCTION IF EXISTS public.media_retention_atdd_hook()")
      T.privileged_sql!("DROP FUNCTION IF EXISTS public.media_retention_atdd_value_hook()")
    end

    # the audit INSERT of `media_config_updated` fails with a database error (inside the transaction), the stand-in of a revoked INSERT privilege
    defp fail_audit_inserts! do
      drop_hooks!()
      T.privileged_sql!("CREATE OR REPLACE FUNCTION public.media_retention_atdd_hook() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'media retention atdd: audit insert refused'; END $$ LANGUAGE plpgsql")
      T.privileged_sql!("CREATE TRIGGER media_retention_atdd_hook BEFORE INSERT ON audit_log FOR EACH ROW WHEN (NEW.action = 'media_config_updated') EXECUTE FUNCTION public.media_retention_atdd_hook()")
    end

    # the audit INSERT waits for the advisory lock the test holds (pauses a save INSIDE its transaction, after its value write), and a new value of 45 is refused
    defp hold_and_refuse_45_audit_inserts! do
      drop_hooks!()

      T.privileged_sql!(
        "CREATE OR REPLACE FUNCTION public.media_retention_atdd_hook() RETURNS trigger AS $$ BEGIN " <>
          "PERFORM pg_advisory_lock(#{@lock_id}); PERFORM pg_advisory_unlock(#{@lock_id}); " <>
          "IF (NEW.metadata->>'new_value') = '45' THEN RAISE EXCEPTION 'media retention atdd: audit insert refused'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
      )

      T.privileged_sql!("CREATE TRIGGER media_retention_atdd_hook BEFORE INSERT ON audit_log FOR EACH ROW WHEN (NEW.action = 'media_config_updated') EXECUTE FUNCTION public.media_retention_atdd_hook()")
    end

    # AC1 -------------------------------------------------------------------------------------------------------------------------------------------------

    for {key, seeded, new, old_in_row} <- [
          {"deleted_days", 30, 7, 30},
          {"deleted_days", :none, 7, 30},
          {"infected_days", 90, 30, 90},
          {"released_delete_after_days", :none, 14, nil},
          {"released_delete_after_days", nil, 14, nil},
          {"released_delete_after_days", 30, 14, 30},
          {"released_delete_after_days", 0, 5, 0}
        ] do
      test "AC1 shortening #{key} #{inspect(seeded)} -> #{inspect(new)}: value and exactly ONE media_config_updated row (old / new value, the admin)" do
        db_seed(unquote(key), unquote(seeded))

        assert :ok = Config.upsert(unquote(key), unquote(new), @actor)

        assert db_value(unquote(key)) == to_string(unquote(new))
        assert [[@actor, "media_config", metadata]] = db_rows(unquote(key))
        assert metadata == %{"key" => unquote(key), "old_value" => unquote(old_in_row), "new_value" => unquote(new)}
        # secondary evidence only (the primary proof of ONE transaction is the rollback of the AC2 tests): assumes the nested audit transaction opens no
        # savepoint, i.e. the row is not stamped with a sub-transaction id
        assert xid_of_value(unquote(key)) == xid_of_audit(unquote(key)), "the value and its audit row carry the same transaction id"
        assert Config.get()[String.to_existing_atom(unquote(key))] == unquote(new), "the cache is refreshed after the commit"
      end
    end

    # AC2 -------------------------------------------------------------------------------------------------------------------------------------------------

    for {key, seeded, new} <- [
          {"deleted_days", 30, 7},
          {"deleted_days", :none, 7},
          {"infected_days", 90, 30},
          {"released_delete_after_days", :none, 14},
          {"released_delete_after_days", nil, 14},
          {"released_delete_after_days", 30, 14},
          {"released_delete_after_days", 0, 5}
        ] do
      test "AC2 shortening #{key} #{inspect(seeded)} -> #{inspect(new)} with a failing audit INSERT (database error inside the transaction): {:error, {:audit, _}}, the value and the row are rolled back" do
        db_seed(unquote(key), unquote(seeded))
        before = db_value(unquote(key))
        fail_audit_inserts!()

        capture_log(fn -> send(self(), {:result, Config.upsert(unquote(key), unquote(new), @actor)}) end)
        assert_received {:result, result}

        assert {:error, {:audit, _}} = result
        assert db_value(unquote(key)) == before, "NOTHING persisted (no row stays a missing row)"
        assert db_rows(unquote(key)) == []
      end

      test "AC2 shortening #{key} #{inspect(seeded)} -> #{inspect(new)} with an audit writer that ANSWERS an error (no database error): {:error, {:audit, _}}, rolled back" do
        db_seed(unquote(key), unquote(seeded))
        before = db_value(unquote(key))
        Application.put_env(:compliance, :repo, FailingAuditRepo)

        capture_log(fn -> send(self(), {:result, Config.upsert(unquote(key), unquote(new), @actor)}) end)
        assert_received {:result, result}

        assert {:error, {:audit, _}} = result
        assert db_value(unquote(key)) == before
      end
    end

    # AC3 -------------------------------------------------------------------------------------------------------------------------------------------------

    for {key, seeded, new, new_text} <- [
          {"deleted_days", 30, 60, "60"},
          {"infected_days", 90, 180, "180"},
          {"released_delete_after_days", 14, 30, "30"},
          {"released_delete_after_days", 14, nil, ""},
          {"released_delete_after_days", 14, 0, "0"}
        ] do
      test "AC3 lengthening / disabling #{key} #{inspect(seeded)} -> #{inspect(new)} with a failing audit INSERT: :ok, the value IS persisted (retry without the audit), no row" do
        db_seed(unquote(key), unquote(seeded))
        fail_audit_inserts!()

        capture_log(fn -> send(self(), {:result, Config.upsert(unquote(key), unquote(new), @actor)}) end)
        assert_received {:result, result}

        assert :ok = result
        assert db_value(unquote(key)) == unquote(new_text)
        assert db_rows(unquote(key)) == []
        assert Config.get()[String.to_existing_atom(unquote(key))] == unquote(new), "the cache shows the committed value"
      end
    end

    test "AC3 with an audit writer that answers an error: lengthening persisted without a row, one value-free ERROR (the key, no values)" do
      db_seed("deleted_days", 3001)
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      log = capture_log([level: :error], fn -> send(self(), {:result, Config.upsert("deleted_days", 3011, @actor)}) end)

      assert_received {:result, :ok}
      assert db_value("deleted_days") == "3011"
      assert log =~ "[error]"
      assert [_one_line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "deleted_days")), "exactly ONE ERROR line names the key"
      refute log =~ "3001"
      refute log =~ "3011"
      refute log =~ @actor, "key only: no actor in the log"
      refute log =~ "audit_write_failed", "key only: not the writer's reason either"
    end

    test "a damaged stored old value (not a number) is unknown: with a failing audit even a larger number is refused (fail-safe), no crash" do
      T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ('deleted_days', 'abc', 1)")
      fail_audit_inserts!()

      capture_log(fn -> send(self(), {:result, Config.upsert("deleted_days", 60, @actor)}) end)
      assert_received {:result, result}

      assert {:error, {:audit, _}} = result
      assert db_value("deleted_days") == "abc", "nothing persisted"
    end

    test "a damaged stored old value with a working audit table: saved, the row records the old value as unknown" do
      T.privileged_sql!("INSERT INTO media_config (key, value, set_at) VALUES ('infected_days', '', 1)")

      assert :ok = Config.upsert("infected_days", 30, @actor)

      assert db_value("infected_days") == "30"
      assert [[@actor, "media_config", %{"old_value" => "unknown", "new_value" => 30}]] = db_rows("infected_days")
    end

    test "AC3 an unchanged value is treated as lengthening: written, audited when the table works" do
      db_seed("infected_days", 90)
      assert :ok = Config.upsert("infected_days", 90, @actor)
      assert db_value("infected_days") == "90"
      assert [[@actor, "media_config", %{"old_value" => 90, "new_value" => 90}]] = db_rows("infected_days")
    end

    # AC4 -------------------------------------------------------------------------------------------------------------------------------------------------

    test "AC4 a rolled-back shortening leaves the ETS cache untouched (no refresh, no :pg broadcast to peers); a committed change refreshes it" do
      db_seed("deleted_days", 30)
      :ok = Config.refresh()
      assert Config.get().deleted_days == 30

      # the database moves on behind the cache's back: only a refresh could show it
      T.privileged_sql!("UPDATE media_config SET value = '31' WHERE key = 'deleted_days'")

      _ = :pg.start_link()
      me = self()
      :pg.join(Config.pg_group(), me)
      on_exit(fn -> :pg.leave(Config.pg_group(), me) end)
      flush_pg()

      fail_audit_inserts!()
      capture_log(fn -> send(self(), {:result, Config.upsert("deleted_days", 7, @actor)}) end)
      assert_received {:result, {:error, {:audit, _}}}

      assert db_value("deleted_days") == "31"
      assert Config.get().deleted_days == 30, "a rolled-back transaction must not refresh the cache (it would show 31)"
      refute_receive {:invalidate_media_config}, 200

      drop_hooks!()
      assert :ok = Config.upsert("deleted_days", 40, @actor)
      assert Config.get().deleted_days == 40
      assert_receive {:invalidate_media_config}, 1_000
      refute_receive {:invalidate_media_config}, 100
    end

    # AC5 -------------------------------------------------------------------------------------------------------------------------------------------------

    test "AC5 race: B (45) waits behind the paused A (30 -> 60), reads its old value UNDER the lock (60), and is refused when its audit fails: no unaudited shortening" do
      db_seed("deleted_days", 30)
      hold_and_refuse_45_audit_inserts!()

      {a, b, log} = run_interleaved("deleted_days", 60, 45)

      assert :ok = a
      assert {:error, {:audit, _}} = b, "45 against the committed 60 is a SHORTENING and must not be persisted unaudited by racing the lengthening check, got #{inspect(b)} (log: #{String.slice(log, 0, 300)})"
      assert db_value("deleted_days") == "60"
      assert [[_actor, "media_config", %{"old_value" => 30, "new_value" => 60}]] = db_rows("deleted_days")
    end

    test "AC5 race with NO row yet (the default 30 is the old value): B (45) is refused behind A (60), the rows show the default as A's old value" do
      hold_and_refuse_45_audit_inserts!()

      {a, b, log} = run_interleaved("deleted_days", 60, 45)

      assert :ok = a
      assert {:error, {:audit, _}} = b, "45 against the committed 60 is a SHORTENING, got #{inspect(b)} (log: #{String.slice(log, 0, 300)})"
      assert db_value("deleted_days") == "60"
      assert [[_actor, "media_config", %{"old_value" => 30, "new_value" => 60}]] = db_rows("deleted_days"), "no row to lock: the advisory lock serializes the two saves"
    end

    test "AC5 race of released_delete_after_days (14): A lengthens to 60, B (45) is a shortening behind it and is refused" do
      db_seed("released_delete_after_days", 14)
      hold_and_refuse_45_audit_inserts!()

      {a, b, log} = run_interleaved("released_delete_after_days", 60, 45)

      assert :ok = a
      assert {:error, {:audit, _}} = b, "45 against the committed 60 is a SHORTENING, got #{inspect(b)} (log: #{String.slice(log, 0, 300)})"
      assert db_value("released_delete_after_days") == "60"
      assert [[_actor, "media_config", %{"old_value" => 14, "new_value" => 60}]] = db_rows("released_delete_after_days")
    end

    test "AC5 race: with a working audit the row of B carries the old value read UNDER the lock (60), the rows form a consistent history" do
      db_seed("deleted_days", 30)
      hold_and_refuse_45_audit_inserts!()

      {a, b, _log} = run_interleaved("deleted_days", 60, 10)

      assert :ok = a
      assert :ok = b
      assert db_value("deleted_days") == "10"

      assert [
               [_, "media_config", %{"old_value" => 30, "new_value" => 60}],
               [_, "media_config", %{"old_value" => 60, "new_value" => 10}]
             ] = db_rows("deleted_days"),
             "B read its old value after A committed"
    end

    test "AC2 a failing VALUE write (trigger on media_config): the database error is passed through, no retry, no audit row, the value is unchanged" do
      db_seed("deleted_days", 30)
      fail_deleted_days_value_writes!()

      capture_log(fn -> send(self(), {:result, Config.upsert("deleted_days", 60, @actor)}) end)
      assert_received {:result, result}

      assert {:error, reason} = result
      refute match?({:audit, _}, reason), "a failed value write is no audit failure: no unaudited retry, got #{inspect(reason)}"
      assert db_value("deleted_days") == "30"
      assert db_rows("deleted_days") == [], "no audit row describes a change that did not happen"
    end

    # AC6 / AC7 (database) --------------------------------------------------------------------------------------------------------------------------------

    test "AC6 another key keeps the sequential behaviour: the value is written, an audit writer that answers an error is only logged, the answer stays :ok" do
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      capture_log(fn -> send(self(), {:result, Config.upsert("max_upload_size_bytes", 1_234_567, @actor)}) end)
      assert_received {:result, :ok}

      assert db_value("max_upload_size_bytes") == "1234567"
    end

    test "AC6 another key with a working audit table: value, then ONE row (separate transactions, as before)" do
      assert :ok = Config.upsert("max_upload_size_bytes", 2_345_678, @actor)

      assert db_value("max_upload_size_bytes") == "2345678"
      assert [[@actor, "media_config", %{"key" => "max_upload_size_bytes", "new_value" => 2_345_678}]] = db_rows("max_upload_size_bytes")
    end

    test "AC7 an invalid value of a retention key has no database and no audit side effect" do
      db_seed("deleted_days", 30)

      assert {:error, _} = Config.upsert("deleted_days", -1, @actor)
      assert {:error, _} = Config.upsert("released_delete_after_days", "14", @actor)
      assert {:error, :unknown_config_key} = Config.upsert("retention_days", 7, @actor)

      assert db_value("deleted_days") == "30"
      assert db_value("released_delete_after_days") == nil
      assert db_rows("deleted_days") == []
      assert db_rows("released_delete_after_days") == []
    end

    # the interleaving: a privileged session holds the advisory lock the audit trigger waits for; A is parked inside its transaction (value written,
    # audit pending); B starts and (in a correct implementation) waits behind A; then the lock is released. Returns {result of A, result of B, captured log}.
    defp run_interleaved(key, a_value, b_value) do
      me = self()

      holder =
        Task.async(fn ->
          T.with_privileged_conn(fn c ->
            Postgrex.query!(c, "SELECT pg_advisory_lock($1)", [@lock_id])
            send(me, :held)

            receive do
              :release -> :ok
            after
              60_000 -> :timeout
            end

            Postgrex.query!(c, "SELECT pg_advisory_unlock($1)", [@lock_id])
          end)
        end)

      assert_receive :held, 10_000

      log =
        capture_log(fn ->
          a = Task.async(fn -> safe_upsert(key, a_value, "@admin-a:test.local") end)
          assert :ok == await_blocked(1), "A never parked on the lock the audit trigger waits for"
          b = Task.async(fn -> safe_upsert(key, b_value, "@admin-b:test.local") end)
          assert :ok == await_blocked(2), "B did not wait behind A (no per-key advisory lock taken inside the transaction)"

          send(holder.pid, :release)
          send(me, {:results, Task.await(a, 30_000), Task.await(b, 30_000)})
        end)

      Task.await(holder, 10_000)
      assert_received {:results, ra, rb}
      {ra, rb, log}
    end

    # a raise inside a save becomes a value the assertions can describe (not an EXIT of the linked task that takes the test down)
    defp safe_upsert(key, value, actor) do
      Config.upsert(key, value, actor)
    rescue
      e -> {:raised, e}
    end

    # polls (<= 3 s) until `n` advisory lock requests of this database wait (the holder's lock the audit trigger of A waits for, the per-key lock of B);
    # answers :not_blocked on timeout, the caller asserts with a message naming what did not block
    defp await_blocked(n, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
      %{rows: [[waiting]]} =
        T.sql!("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database())")

      cond do
        waiting >= n -> :ok
        System.monotonic_time(:millisecond) > deadline -> :not_blocked
        true ->
          Process.sleep(20)
          await_blocked(n, deadline)
      end
    end
  end
end
