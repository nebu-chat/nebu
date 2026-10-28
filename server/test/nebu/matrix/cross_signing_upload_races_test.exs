defmodule Nebu.Matrix.CrossSigningUploadRacesTest do
  @moduledoc """
  Real-database acceptance tests for story `cross-signing-upload-races` (epic oauth-broker, follow-up `cq` (g), REQ-2026-007): the cross-signing writers
  decide on the stored keys ONLY under the per-user lock.

  The contract (decisions D1-D5 and the orchestrator decisions of the story):

    * `CrossSigningKeyStore.lock_keys/1` (inside a transaction) takes, in this order, the `cross_signing_keys` row lock (`FOR UPDATE`), the per-user
      `sync_global|<user>` advisory lock, and only THEN reads the three key columns: `{:ok, keys}` (all-nil without a row) or `{:error, reason}` (never
      raises, never an all-nil map for a failed read).
    * `do_persist_cross_signing/3` and `replace_with_approval/7` decide on that read; the signature merge reads its merge base under the same lock and
      repeats the "same object" check there; a failed locked read is a 500 for the upload and for the merge.

  Technique (D7): the barrier pattern of `user_deletion_lock_order_test.exs`. A holder session takes a lock, the racers are started, the test polls
  `pg_stat_activity` / `pg_blocking_pids` (`E.await_blocked!/3`) until every racer is blocked, then releases the holder. No fixed sleep decides anything.
  Two kinds of test:

    * BEHAVIOUR tests through the HTTP handlers (`POST /keys/device_signing/upload`, `POST /keys/signatures/upload`) and the real erasure: they use
      no new function and FAIL on the code of the story's premise check for the right reason (a wrong stored key set, a lost update, a stale write-back).
    * STORE tests of `lock_keys/1` (called through `apply/3`, so the module compiles before the function exists): they pin the lock order and the read
      after the lock directly.

  The green pins (marked "pin" in the test names) already pass on the premise code and guard what must not change: the erasure guard (D10 of
  gdpr-erasure-global-data), the lock order against the erasure, a failed upload read being a 500.

  async: false (real `AuditWriter` seam via `E.setup_env!/0`, committed rows, own connections, a column privilege is revoked for the failing-read tests).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.CrossSigningKeyStore, as: Store
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @https "https://app.example.com/cb"

  # a hard-killed earlier run may have left the column privilege revoked (MINOR-3): put it back before anything else, and refuse to run on a
  # database that does not look like a throwaway test database (the fault is a role-wide privilege change)
  setup_all do
    %{rows: [[db]]} = T.privileged_sql!("SELECT current_database()")
    assert db =~ ~r/\Anebu(_test|_ci)?\z/, "refusing to run: #{inspect(db)} does not look like a test database (the failing-read fault revokes a privilege)"
    restore_master_read!()
    :ok
  end

  setup do
    {:ok, E.setup_env!()}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp dev, do: "RC" <> String.upcase(T.rand(4))

  # a legacy session whose bearer the provisioning cache of the OIDC plug has confirmed (an in-flight request of the story)
  defp legacy!(uid) do
    s = T.legacy_session!(uid, dev())
    assert T.whoami(s.at).status == 200, "precondition: the session is accepted"
    s
  end

  defp oauth_world!(%{priv: priv, cid: cid}) do
    s = T.oauth_device!(cid, @https, priv, T.unique_sub(), dev())
    uid = s.user_id
    old = T.cross_signing_keys(uid, "OLD")
    assert T.device_signing_upload(s.at, old).status == 200, "precondition: the first upload needs no UIA"
    %{s: s, uid: uid, old: old}
  end

  defp challenge!(s, body) do
    conn = T.device_signing_upload(s.at, body)
    assert conn.status == 401, "expected the m.oauth challenge, got #{conn.status}: #{conn.resp_body}"
    T.json(conn)["session"]
  end

  defp approve!(uid, sid), do: :ok = apply(Nebu.Matrix, :approve_cross_signing_reset, [uid, sid])

  defp with_auth(body, sid), do: Map.put(body, "auth", %{"session" => sid})

  defp signatures_upload(token, body), do: T.matrix_request(:post, "/_matrix/client/v3/keys/signatures/upload", token, body: body)

  defp key_id(obj), do: obj["keys"] |> Map.keys() |> hd() |> String.split(":", parts: 2) |> List.last()
  defp sig_for(uid, tag), do: %{uid => %{"ed25519:SG#{tag}" => "sig-#{tag}"}}
  defp sig_body(uid, obj, tag), do: %{uid => %{key_id(obj) => Map.put(obj, "signatures", sig_for(uid, tag))}}

  defp stored(uid), do: Store.get_keys(uid)

  defp cs_row(uid) do
    case T.privileged_sql!(
           "SELECT master_key_json, self_signing_key_json, user_signing_key_json, changed_pos, cross_signing_changed FROM cross_signing_keys WHERE user_id = $1",
           [uid]
         ).rows do
      [row] -> row
      [] -> nil
    end
  end

  # 0 for a sequence that was never drawn from (`last_value` stays 1 until the first `nextval`)
  defp seq, do: T.privileged_sql!("SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM sync_global_pos_seq").rows |> hd() |> hd()

  defp advisory_holder!(uid), do: E.hold(fn -> T.sql!(E.lock_user_sql(), [uid]) end)

  defp request_task(fun), do: Task.async(fn -> T.safely(fun) end)

  # every task must be blocked, directly or through a chain of waiters (a row lock queue is a chain: the second updater of a row waits for the
  # FIRST WAITER, which waits for the holder), by a lock of the transaction of `backend`. Polled up to 15 s (`pg_blocking_pids`), never slept
  # on; a task that completes first did not wait for the lock and fails the test.
  defp await_blocked!(tasks, backend, what), do: await_blocked!(List.wrap(tasks), backend, what, System.monotonic_time(:millisecond) + 15_000)

  defp await_blocked!(tasks, backend, what, deadline) do
    for task <- tasks do
      case Task.yield(task, 0) do
        {:ok, result} -> flunk("#{what} completed (#{inspect(result, limit: 5)}) while the other transaction held the lock: it did not wait for it")
        {:exit, reason} -> flunk("#{what} crashed: #{inspect(reason, limit: 5)}")
        nil -> :ok
      end
    end

    %{rows: [[waiting]]} =
      T.sql!(
        """
        WITH RECURSIVE chain(pid) AS (
          SELECT w.pid FROM pg_stat_activity w WHERE w.wait_event_type = 'Lock' AND $1 = ANY(pg_blocking_pids(w.pid))
          UNION
          SELECT w.pid FROM pg_stat_activity w, chain c WHERE w.wait_event_type = 'Lock' AND c.pid = ANY(pg_blocking_pids(w.pid))
        )
        SELECT count(*) FROM chain
        """,
        [backend]
      )

    cond do
      waiting >= length(tasks) -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("#{what}: only #{waiting} of #{length(tasks)} backends wait for a lock of the other transaction within 15 s")
      true -> Process.sleep(20) && await_blocked!(tasks, backend, what, deadline)
    end
  end

  # holder (advisory lock) -> the requests are started and blocked -> the holder rolls back -> the answers
  defp race!(uid, funs) do
    holder = advisory_holder!(uid)
    tasks = Enum.map(funs, &request_task/1)
    await_blocked!(tasks, holder.backend, "the requests")
    E.finish(holder, :rollback)
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp status!(%Plug.Conn{status: status}), do: status
  defp status!(other), do: flunk("the request crashed instead of answering: #{inspect(other, limit: 5)}")

  # a "reset" as replace_with_approval/7 writes it: the cross_signing_keys row first, then put_keys/2 (advisory lock, write)
  defp start_reset!(uid, keys) do
    Task.async(fn ->
      T.safely(fn ->
        Nebu.Repo.transaction(fn ->
          T.sql!("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [uid])

          case Store.put_keys(uid, keys) do
            :ok -> :reset
            {:error, reason} -> Nebu.Repo.rollback(reason)
          end
        end)
      end)
    end)
  end

  # The per-request access / debug line of `Nebu.Web.Plugs.RequestLogger` (`[status: ...]` and the redacted JSON body at :debug) is existing
  # infrastructure that prints the request body of EVERY route (the public key objects of an upload); the rule of the story (D5) is about the lines
  # of the writers and the store, so those two entries are left out of the check. Everything else (handler lines, crash reports) is checked.
  defp refute_material!(log, material) do
    entries = String.split(log, ~r/\n+(?=\d\d:\d\d:\d\d\.\d+ \[)/)
    own = Enum.reject(entries, &(&1 =~ ~r/\A\d\d:\d\d:\d\d\.\d+ \[\w+\] (\[status: |\{"status":)/))
    checked = Enum.join(own, "\n")
    for m <- material, do: refute(checked =~ m, "key material in a log line: #{String.slice(m, 0, 8)}")
  end

  defp key_strings(keys), do: for({_k, %{"keys" => ks}} <- keys, {id, v} <- ks, s <- [id, v, key_id(%{"keys" => ks})], do: s)

  # ── the failing read (scenario 5): the table SELECT is revoked and given back WITHOUT the master column ─────────────────────────────────
  #
  # `SELECT 1 ... FOR UPDATE` (the row lock) needs UPDATE and the key column `user_id`; the advisory lock needs nothing; only the READ of the three
  # key columns fails (permission denied for master_key_json). A fault of the row lock itself would not prove that the READ is error-aware.
  defp break_master_read! do
    # the restore is registered FIRST (a failing statement below must not leave the privilege revoked); both statements run atomically in one DO block
    ExUnit.Callbacks.on_exit(&restore_master_read!/0)

    T.privileged_sql!("""
    DO $$ BEGIN
      REVOKE SELECT ON cross_signing_keys FROM nebu_app;
      GRANT SELECT (user_id, self_signing_key_json, user_signing_key_json) ON cross_signing_keys TO nebu_app;
    END $$
    """)

    &restore_master_read!/0
  end

  # idempotent: also the right state when nothing was broken
  defp restore_master_read! do
    T.privileged_sql!("""
    DO $$ BEGIN
      REVOKE SELECT (user_id, self_signing_key_json, user_signing_key_json) ON cross_signing_keys FROM nebu_app;
      GRANT SELECT ON cross_signing_keys TO nebu_app;
    END $$
    """)
  end

  # the log checks run at :debug (the test config logs :warning only, an info / debug line with key material would escape)
  defp capture_debug(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      ExUnit.CaptureLog.capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp assert_lock_keys_defined! do
    assert {:module, _} = Code.ensure_loaded(Store)
    assert function_exported?(Store, :lock_keys, 1), "CrossSigningKeyStore.lock_keys/1 does not exist yet"
  end

  # runs `fun` inside a transaction of its own (a statement error aborts it) that is always rolled back; returns what `fun` returned
  defp probe(fun) do
    parent = self()
    ref = make_ref()

    Nebu.Repo.transaction(fn ->
      send(parent, {ref, fun.()})
      Nebu.Repo.rollback(:probe)
    end)

    receive do
      {^ref, value} -> value
    after
      0 -> flunk("the probe did not run")
    end
  end

  defp row_locked?(uid) do
    probe(fn ->
      try do
        T.sql!("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE NOWAIT", [uid])
        false
      rescue
        e in Postgrex.Error -> e.postgres.code == :lock_not_available
      end
    end)
  end

  defp advisory_free?(uid) do
    probe(fn ->
      %{rows: [[free?]]} = T.sql!("SELECT pg_try_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))", [uid])
      free?
    end)
  end

  defp lock_keys_task(uid) do
    assert_lock_keys_defined!()

    Task.async(fn ->
      T.safely(fn -> Nebu.Repo.transaction(fn -> apply(Store, :lock_keys, [uid]) end) end)
    end)
  end

  # ═══ Scenario 1: two concurrent first uploads store exactly one key set ═════════════════════════════════════════════════════════════

  describe "scenario 1 - two concurrent first uploads" do
    test "identical keys on two devices: both answer 200, the keys are written ONCE (one changed_pos draw)" do
      uid = T.provision_user!()
      {s1, s2} = {legacy!(uid), legacy!(uid)}
      keys = T.cross_signing_keys(uid, "ONE")
      before = seq()

      answers = race!(uid, [fn -> T.device_signing_upload(s1.at, keys) end, fn -> T.device_signing_upload(s2.at, keys) end])

      assert Enum.map(answers, &status!/1) == [200, 200]
      assert stored(uid) |> Map.take(Map.keys(keys)) == keys
      assert seq() - before == 1, "the second upload is an idempotent re-upload against stored keys: no second changed_pos draw (got #{seq() - before} draws)"
      assert [_, _, _, changed_pos, true] = cs_row(uid)
      assert changed_pos == before + 1
    end

    test "different keys, LEGACY callers: one takes the UIA-free first upload, the other answers 403, the stored keys are the winner's" do
      uid = T.provision_user!()
      {s1, s2} = {legacy!(uid), legacy!(uid)}
      {k1, k2} = {T.cross_signing_keys(uid, "ONE"), T.cross_signing_keys(uid, "TWO")}
      before = seq()

      answers = race!(uid, [fn -> T.device_signing_upload(s1.at, k1) end, fn -> T.device_signing_upload(s2.at, k2) end])

      statuses = answers |> Enum.map(&status!/1) |> Enum.sort()
      assert statuses == [200, 403], "exactly one UIA-free first upload, got #{inspect(statuses)}"
      loser = Enum.find(answers, &(status!(&1) == 403))
      assert T.json(loser)["errcode"] == "M_FORBIDDEN"

      winner_keys = if status!(hd(answers)) == 200, do: k1, else: k2
      assert Map.take(stored(uid), Map.keys(k1)) == winner_keys, "the second upload must not replace the first"
      assert seq() - before == 1, "changed_pos was drawn once"
    end

    test "different keys, OAuth callers: one takes the UIA-free first upload, the other gets the m.oauth challenge", ctx do
      sub = T.unique_sub()
      s1 = T.oauth_device!(ctx.cid, @https, ctx.priv, sub, dev())
      s2 = T.oauth_device!(ctx.cid, @https, ctx.priv, sub, dev())
      uid = s1.user_id
      {k1, k2} = {T.cross_signing_keys(uid, "ONE"), T.cross_signing_keys(uid, "TWO")}

      answers = race!(uid, [fn -> T.device_signing_upload(s1.at, k1) end, fn -> T.device_signing_upload(s2.at, k2) end])

      statuses = answers |> Enum.map(&status!/1) |> Enum.sort()
      assert statuses == [200, 401], "exactly one UIA-free first upload, got #{inspect(statuses)}"
      challenge = Enum.find(answers, &(status!(&1) == 401)) |> T.json()
      assert challenge["flows"] == [%{"stages" => ["m.oauth"]}]

      winner_keys = if status!(hd(answers)) == 200, do: k1, else: k2
      assert Map.take(stored(uid), Map.keys(k1)) == winner_keys
      assert T.uia_count(uid, "cross_signing_reset") == 1, "the loser answered like any replacement of stored keys"
    end

    test "a row with a NULL master is still a first upload, a stored master never is (non-goal, INFO-1 rule)" do
      uid = T.provision_user!()
      s = legacy!(uid)
      assert :ok = Store.put_keys(uid, %{})
      assert [nil, nil, nil, _, _] = cs_row(uid)

      keys = T.cross_signing_keys(uid, "NULLM")
      assert T.device_signing_upload(s.at, keys).status == 200
      assert Map.take(stored(uid), Map.keys(keys)) == keys

      other = T.cross_signing_keys(uid, "OTHER")
      assert T.device_signing_upload(s.at, other).status == 403, "stored master: a replacement, not a first upload"
      assert Map.take(stored(uid), Map.keys(keys)) == keys
    end
  end

  # ═══ lock_keys/1 (D1) ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "lock_keys/1 - row lock, advisory lock, then the read" do
    test "the function exists with arity 1" do
      assert {:module, _} = Code.ensure_loaded(Store)
      assert function_exported?(Store, :lock_keys, 1)
    end

    test "without a row: waits for the per-user advisory lock, then answers {:ok, all-nil}" do
      uid = T.provision_user!()
      holder = advisory_holder!(uid)
      task = lock_keys_task(uid)

      await_blocked!(task, holder.backend, "lock_keys/1")
      E.finish(holder, :rollback)

      assert {:ok, {:ok, %{"master_key" => nil, "self_signing_key" => nil, "user_signing_key" => nil}}} = Task.await(task, 20_000)
    end

    test "the read happens AFTER the advisory lock: it returns the keys the previous holder committed (no row existed when it started)" do
      uid = T.provision_user!()
      keys = T.cross_signing_keys(uid, "PREV")
      holder = E.hold(fn -> :ok = Store.put_keys(uid, keys) end)
      task = lock_keys_task(uid)

      await_blocked!(task, holder.backend, "lock_keys/1")
      E.finish(holder, :commit)

      assert {:ok, {:ok, read}} = Task.await(task, 20_000)
      assert read["master_key"] == keys["master_key"], "the decision read must see the commit of the previous holder"
      assert read["self_signing_key"] == keys["self_signing_key"] and read["user_signing_key"] == keys["user_signing_key"]
    end

    test "the row lock comes BEFORE the advisory lock (1/2): waiting for the row it does not hold the advisory lock" do
      uid = T.provision_user!()
      assert :ok = Store.put_keys(uid, T.cross_signing_keys(uid, "ROW"))
      holder = E.hold(fn -> T.sql!("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [uid]) end)
      task = lock_keys_task(uid)

      await_blocked!(task, holder.backend, "lock_keys/1")
      assert advisory_free?(uid), "an advisory lock taken BEFORE the row lock would deadlock with the erasure (row locks, then advisory lock)"
      E.finish(holder, :rollback)

      assert {:ok, {:ok, %{"master_key" => %{}}}} = Task.await(task, 20_000)
    end

    test "the row lock comes BEFORE the advisory lock (2/2): waiting for the advisory lock it already holds the row" do
      uid = T.provision_user!()
      assert :ok = Store.put_keys(uid, T.cross_signing_keys(uid, "ADV"))
      holder = advisory_holder!(uid)
      task = lock_keys_task(uid)

      await_blocked!(task, holder.backend, "lock_keys/1")
      assert row_locked?(uid), "lock_keys/1 holds the cross_signing_keys row while it waits for the advisory lock (row -> advisory -> read)"
      E.finish(holder, :rollback)

      assert {:ok, {:ok, %{"master_key" => %{}}}} = Task.await(task, 20_000)
    end

    test "a failing READ is {:error, reason} (the row lock and the advisory lock succeed), never an all-nil map and never a raise" do
      uid = T.provision_user!()
      assert_lock_keys_defined!()
      assert :ok = Store.put_keys(uid, T.cross_signing_keys(uid, "ERR"))
      break_master_read!()

      result = probe(fn -> T.safely(fn -> apply(Store, :lock_keys, [uid]) end) end)
      restore_master_read!()

      assert {:error, _reason} = result
    end

    # D-A2: `get_keys_for_update/1` is removed OR delegates. An explicit conditional, never a silently vacuous test: the removed branch requires lock_keys/1
    # to exist (the row-only decision API must have been replaced, not just deleted).
    test "get_keys_for_update/1 is removed, or it delegates to lock_keys/1 and waits for the advisory lock too" do
      assert_lock_keys_defined!()
      uid = T.provision_user!()

      if function_exported?(Store, :get_keys_for_update, 1) do
        holder = advisory_holder!(uid)

        task =
          Task.async(fn -> T.safely(fn -> Nebu.Repo.transaction(fn -> apply(Store, :get_keys_for_update, [uid]) end) end) end)

        await_blocked!(task, holder.backend, "get_keys_for_update/1")
        E.finish(holder, :rollback)
        assert {:ok, {:ok, _keys}} = Task.await(task, 20_000)
      else
        refute function_exported?(Store, :get_keys_for_update, 1), "removed: the decision read is lock_keys/1 only"
      end
    end
  end

  # ═══ Scenario 2: a signature merge concurrent with a reset never writes back stale columns ══════════════════════════════════════════

  describe "scenario 2 - the merge base is read under the lock" do
    # the reset is a transaction that holds the row and waits for the advisory lock (a holder `x`); the merge is started behind it
    defp race_merge_behind_reset!(uid, reset_fun, merge_fun) do
      x = advisory_holder!(uid)
      reset = reset_fun.()
      await_blocked!(reset, x.backend, "the reset")
      merge = request_task(merge_fun)
      await_blocked!([reset, merge], x.backend, "the reset and the merge")
      E.finish(x, :rollback)
      {Task.await(reset, 30_000), Task.await(merge, 30_000)}
    end

    # the reset as a function of its kind: an emulated writer transaction (the lock order of replace_with_approval/7) or the real approved OAuth request
    defp reset_fun(:emulated, w, body), do: fn -> start_reset!(w.uid, Map.merge(w.old, body)) end

    defp reset_fun(:oauth_approval, w, body) do
      sid = challenge!(w.s, body)
      approve!(w.uid, sid)
      fn -> request_task(fn -> T.device_signing_upload(w.s.at, with_auth(body, sid)) end) end
    end

    defp assert_reset_done!(:emulated, answer), do: assert({:ok, :reset} = answer)
    defp assert_reset_done!(:oauth_approval, answer), do: assert(status!(answer) == 200)

    defp reset_ssk_vs_merge!(kind, ctx) do
      w = oauth_world!(ctx)
      new_ssk = T.cross_signing_keys(w.uid, "NEWSSK")["self_signing_key"]
      reset_fun = reset_fun(kind, w, %{"self_signing_key" => new_ssk})

      {reset_answer, merge_answer} =
        race_merge_behind_reset!(w.uid, reset_fun, fn -> signatures_upload(w.s.at, sig_body(w.uid, w.old["master_key"], "M")) end)

      assert_reset_done!(kind, reset_answer)
      assert status!(merge_answer) == 200
      assert T.json(merge_answer) == %{"failures" => %{}}, "the signed master key still exists unchanged: no failure entry"

      keys = stored(w.uid)
      assert keys["self_signing_key"] == new_ssk, "the merge wrote back the stale self-signing key and undid the reset"
      assert keys["user_signing_key"] == w.old["user_signing_key"]
      assert keys["master_key"] == Map.put(w.old["master_key"], "signatures", sig_for(w.uid, "M"))
    end

    defp reset_master_vs_merge!(kind, ctx) do
      w = oauth_world!(ctx)
      new_keys = T.cross_signing_keys(w.uid, "NEWALL")
      reset_fun = reset_fun(kind, w, new_keys)
      old_id = key_id(w.old["master_key"])

      {reset_answer, merge_answer} =
        race_merge_behind_reset!(w.uid, reset_fun, fn -> signatures_upload(w.s.at, sig_body(w.uid, w.old["master_key"], "M")) end)

      assert_reset_done!(kind, reset_answer)
      assert status!(merge_answer) == 200
      assert %{"failures" => %{} = failures} = T.json(merge_answer)

      # the reset's keys stand, UNSIGNED, whatever the order (nothing of a stale merge base is stored)
      assert Map.take(stored(w.uid), Map.keys(new_keys)) == new_keys, "the merge wrote its stale base back over the reset"

      case kind do
        # one writer transaction: the reset commits first, the merge then finds no key of that id
        :emulated ->
          assert failures[w.uid][old_id]["errcode"] == "M_INVALID_SIGNATURE", "the signed key was replaced meanwhile: a failure entry, got #{inspect(failures)}"

        # the real request decides in a transaction of its own and writes in a second one (`replace_with_approval/7`): the merge may run
        # in between (then it signs the old key and the reset replaces everything afterwards) or after the reset (a failure entry)
        :oauth_approval ->
          assert failures == %{} or failures[w.uid][old_id]["errcode"] == "M_INVALID_SIGNATURE"
      end
    end

    test "emulated reset of the self-signing key vs a master signature: the reset's keys stay, the master is signed", ctx,
      do: reset_ssk_vs_merge!(:emulated, ctx)

    test "oauth_approval reset of the self-signing key vs a master signature: the reset's keys stay, the master is signed", ctx,
      do: reset_ssk_vs_merge!(:oauth_approval, ctx)

    test "emulated reset that REPLACES the signed master key: the merge stores nothing and reports a failure entry", ctx,
      do: reset_master_vs_merge!(:emulated, ctx)

    test "oauth_approval reset that REPLACES the signed master key: the merge stores nothing and reports a failure entry", ctx,
      do: reset_master_vs_merge!(:oauth_approval, ctx)

    test "a reset that keeps the key id but changes the key OBJECT: the merge stores nothing (the object check is repeated under the lock)", ctx do
      w = oauth_world!(ctx)
      changed_master = put_in(w.old["master_key"], ["usage"], ["master", "atdd-changed"])
      assert key_id(changed_master) == key_id(w.old["master_key"])
      new_keys = Map.put(w.old, "master_key", changed_master)

      {{:ok, :reset}, merge_answer} =
        race_merge_behind_reset!(w.uid, fn -> start_reset!(w.uid, new_keys) end, fn -> signatures_upload(w.s.at, sig_body(w.uid, w.old["master_key"], "M")) end)

      assert status!(merge_answer) == 200
      assert %{"failures" => failures} = T.json(merge_answer)
      assert failures[w.uid][key_id(changed_master)]["errcode"] == "M_INVALID_SIGNATURE"
      assert stored(w.uid)["master_key"] == changed_master, "the signature of the OLD object must not be attached to the reset's new object, nor the old object written back"
    end

    test "two concurrent merges (different signatures) both survive: the second reads the first one's commit as its base", ctx do
      w = oauth_world!(ctx)
      master = w.old["master_key"]

      answers =
        race!(w.uid, [
          fn -> signatures_upload(w.s.at, sig_body(w.uid, master, "A")) end,
          fn -> signatures_upload(w.s.at, sig_body(w.uid, master, "B")) end
        ])

      assert Enum.map(answers, &status!/1) == [200, 200]
      assert Enum.all?(answers, &(T.json(&1) == %{"failures" => %{}}))
      signatures = stored(w.uid)["master_key"]["signatures"]
      assert signatures[w.uid]["ed25519:SGA"] == "sig-A" and signatures[w.uid]["ed25519:SGB"] == "sig-B", "a lost update: got #{inspect(signatures)}"
    end

    test "pin: a plain merge adds the signature, keeps the other keys, and moves neither cross_signing_changed nor changed_pos", ctx do
      w = oauth_world!(ctx)
      T.sql!("UPDATE cross_signing_keys SET cross_signing_changed = FALSE WHERE user_id = $1", [w.uid])
      [_, _, _, pos, false] = cs_row(w.uid)
      before = seq()

      conn = signatures_upload(w.s.at, sig_body(w.uid, w.old["master_key"], "P"))

      assert conn.status == 200 and T.json(conn) == %{"failures" => %{}}
      keys = stored(w.uid)
      assert keys["master_key"]["signatures"] == sig_for(w.uid, "P")
      assert keys["self_signing_key"] == w.old["self_signing_key"] and keys["user_signing_key"] == w.old["user_signing_key"]
      assert [_, _, _, ^pos, false] = cs_row(w.uid), "a merge does not touch cross_signing_changed / changed_pos"
      assert seq() == before, "a merge draws no position"
    end

    test "pin: a submitted object that differs from the stored one writes nothing and reports the failure entry", ctx do
      w = oauth_world!(ctx)
      forged = put_in(w.old["master_key"], ["usage"], ["master", "forged"])
      before = E.fp("cross_signing_keys", w.uid)

      conn = signatures_upload(w.s.at, sig_body(w.uid, forged, "F"))

      assert conn.status == 200
      assert %{"failures" => %{} = failures} = T.json(conn)
      assert failures[w.uid][key_id(w.old["master_key"])]["errcode"] == "M_INVALID_SIGNATURE"
      assert E.fp("cross_signing_keys", w.uid) == before
    end
  end

  # ═══ Scenario 3: an erased user's uploads and merges are still refused ═══════════════════════════════════════════════════════════════

  describe "scenario 3 - the erasure guard" do
    test "pin: an erasure that holds its locks while a first upload and a merge wait: 403 M_USER_DEACTIVATED, a failure entry, no row", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      s = legacy!(a.uid)
      master = stored(a.uid)["master_key"]
      assert master != nil, "precondition: the seeded user has cross-signing keys"

      # the erasure takes its locks (uia rows, cross_signing_keys row, advisory lock) and then waits for this account_data row
      x = E.hold(fn -> T.sql!("SELECT 1 FROM account_data WHERE user_id = $1 ORDER BY type FOR UPDATE", [a.uid]) end)
      erasure = Task.async(fn -> UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd erasure vs upload") end)
      await_blocked!(erasure, x.backend, "the erasure")

      upload = request_task(fn -> T.device_signing_upload(s.at, T.cross_signing_keys(a.uid, "AFTER")) end)
      merge = request_task(fn -> signatures_upload(s.at, sig_body(a.uid, master, "E")) end)
      await_blocked!([erasure, upload, merge], x.backend, "the erasure, the upload and the merge")
      E.finish(x, :rollback)

      assert {:ok, %{keys_deleted_at: _}} = Task.await(erasure, 60_000)
      upload = Task.await(upload, 30_000)
      merge = Task.await(merge, 30_000)

      assert status!(upload) == 403 and T.json(upload)["errcode"] == "M_USER_DEACTIVATED", "got #{inspect(upload)}"
      assert status!(merge) == 200
      assert %{"failures" => failures} = T.json(merge)
      assert failures[a.uid][key_id(master)]["errcode"] == "M_INVALID_SIGNATURE"
      assert E.count("cross_signing_keys", a.uid) == 0, "no cross_signing_keys row exists for the erased user"
    end

    test "pin: the first upload of a user whose status is set (an in-flight request, a row without keys) is refused 403 M_USER_DEACTIVATED, nothing changes" do
      uid = T.provision_user!()
      s = legacy!(uid)
      assert :ok = Store.put_keys(uid, %{})
      T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [uid])
      before = E.fp("cross_signing_keys", uid)

      conn = T.device_signing_upload(s.at, T.cross_signing_keys(uid, "LATE"))

      assert conn.status == 403 and T.json(conn)["errcode"] == "M_USER_DEACTIVATED"
      assert E.fp("cross_signing_keys", uid) == before
    end

    test "pin: a signature merge into the stored keys of a user whose status is set reports a failure entry and leaves the row untouched" do
      uid = T.provision_user!()
      s = legacy!(uid)
      keys = T.cross_signing_keys(uid, "KEPT")
      assert :ok = Store.put_keys(uid, keys)
      T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [uid])
      before = E.fp("cross_signing_keys", uid)

      conn = signatures_upload(s.at, sig_body(uid, keys["master_key"], "LATE"))

      assert conn.status == 200
      assert %{"failures" => failures} = T.json(conn)
      assert failures[uid][key_id(keys["master_key"])]["errcode"] == "M_INVALID_SIGNATURE"
      assert E.fp("cross_signing_keys", uid) == before
    end
  end

  # ═══ Scenario 4: uploads, the signatures upload and the erasure never deadlock ═══════════════════════════════════════════════════════

  describe "scenario 4 - no deadlock with the erasure" do
    # a first upload needs a user WITHOUT a cross_signing_keys row (the absent-row case of the race); every other writer works on stored keys
    defp world!(:first_upload, %{priv: priv, cid: cid}) do
      s = T.oauth_device!(cid, @https, priv, T.unique_sub(), dev())
      %{s: s, uid: s.user_id, old: nil}
    end

    defp world!(_kind, ctx), do: oauth_world!(ctx)

    defp writer!(:first_upload, w), do: fn -> T.device_signing_upload(w.s.at, T.cross_signing_keys(w.uid, "FIRSTD")) end
    defp writer!(:upload, w), do: fn -> T.device_signing_upload(w.s.at, %{"master_key" => w.old["master_key"]}) end
    defp writer!(:merge, w), do: fn -> signatures_upload(w.s.at, sig_body(w.uid, w.old["master_key"], "D")) end

    defp writer!(:replace, w) do
      new = T.cross_signing_keys(w.uid, "NEWD")
      sid = challenge!(w.s, new)
      approve!(w.uid, sid)
      fn -> T.device_signing_upload(w.s.at, with_auth(new, sid)) end
    end

    # a uia_sessions row must exist: `FOR UPDATE` of no row locks nothing (the user has no pending request yet)
    defp mint_uia_row!(uid) do
      assert T.uia_count(uid, "cross_signing_reset") == 0
      Nebu.Matrix.Uia.mint_session(uid, "cross_signing_reset", "{}")
      assert T.uia_count(uid, "cross_signing_reset") == 1, "precondition: the uia_sessions row exists"
    end

    defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd deadlock")

    defp assert_finished!(writer_task, erasure_task, kind, order) do
      writer = Task.await(writer_task, 40_000)
      assert {:ok, %{keys_deleted_at: _}} = Task.await(erasure_task, 60_000), "#{kind} (#{order}): the erasure must not be the victim of a deadlock"
      assert is_struct(writer, Plug.Conn), "#{kind} (#{order}): the request crashed: #{inspect(writer, limit: 5)}"
      assert writer.status < 500, "#{kind} (#{order}): the request must not fail (a deadlock victim answers 500), got #{writer.status}: #{writer.resp_body}"
    end

    for kind <- [:first_upload, :upload, :merge, :replace] do
      test "#{kind}: writer queued on the advisory lock before the erasure starts: both finish", ctx do
        kind = unquote(kind)
        w = world!(kind, ctx)
        fun = writer!(kind, w)

        x = advisory_holder!(w.uid)
        writer = request_task(fun)
        await_blocked!(writer, x.backend, "the writer")
        erasure = Task.async(fn -> erase!(w.uid) end)
        await_blocked!([writer, erasure], x.backend, "the writer and the erasure")
        E.finish(x, :rollback)

        assert_finished!(writer, erasure, kind, "writer first")
      end

      test "#{kind}: erasure queued on the advisory lock before the writer starts: both finish", ctx do
        kind = unquote(kind)
        w = world!(kind, ctx)
        fun = writer!(kind, w)

        x = advisory_holder!(w.uid)
        erasure = Task.async(fn -> erase!(w.uid) end)
        await_blocked!(erasure, x.backend, "the erasure")
        writer = request_task(fun)
        await_blocked!([erasure, writer], x.backend, "the erasure and the writer")
        E.finish(x, :rollback)

        assert_finished!(writer, erasure, kind, "erasure first")
      end
    end

    test "pin: a simulated writer in the documented lock order (uia row, cs row, advisory, read) commits with the erasure", ctx do
      w = oauth_world!(ctx)
      parent = self()
      mint_uia_row!(w.uid)

      writer =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            %{rows: [[backend]]} = T.sql!("SELECT pg_backend_pid()")
            T.sql!("SELECT 1 FROM uia_sessions WHERE user_id = $1 FOR UPDATE", [w.uid])
            T.sql!("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [w.uid])
            send(parent, {:holding, backend})

            receive do
              :go -> :ok
            after
              30_000 -> Nebu.Repo.rollback(:atdd_timeout)
            end

            T.sql!(E.lock_user_sql(), [w.uid])
            T.sql!("SELECT master_key_json FROM cross_signing_keys WHERE user_id = $1", [w.uid])
            :written
          end)
        end)

      assert_receive {:holding, backend}, 15_000
      erasure = Task.async(fn -> erase!(w.uid) end)
      await_blocked!(erasure, backend, "the erasure")
      send(writer.pid, :go)

      assert {:ok, :written} = Task.await(writer, 20_000)
      assert {:ok, %{keys_deleted_at: _}} = Task.await(erasure, 30_000)
    end

    test "pin: a simulated writer holding only the uia row and taking the cross_signing row AFTER the erasure queued does not deadlock with it", ctx do
      w = oauth_world!(ctx)
      parent = self()
      mint_uia_row!(w.uid)

      writer =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            %{rows: [[backend]]} = T.sql!("SELECT pg_backend_pid()")
            T.sql!("SELECT 1 FROM uia_sessions WHERE user_id = $1 FOR UPDATE", [w.uid])
            send(parent, {:holding, backend})

            receive do
              :go -> :ok
            after
              30_000 -> Nebu.Repo.rollback(:atdd_timeout)
            end

            # the second row of the documented order: an erasure that already holds this row while it waits for the uia row would deadlock here
            T.sql!("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [w.uid])
            T.sql!(E.lock_user_sql(), [w.uid])
            :written
          end)
        end)

      assert_receive {:holding, backend}, 15_000
      erasure = Task.async(fn -> erase!(w.uid) end)
      await_blocked!(erasure, backend, "the erasure")
      send(writer.pid, :go)

      assert {:ok, :written} = Task.await(writer, 30_000), "the writer must not be the victim of a deadlock"
      assert {:ok, %{keys_deleted_at: _}} = Task.await(erasure, 60_000), "the erasure must not be the victim of a deadlock"
    end

    test "four operations released together from a barrier, four rounds: all finish, none fails, no deadlock", ctx do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for round <- 1..4 do
            w = oauth_world!(ctx)
            funs = [writer!(:upload, w), writer!(:merge, w), writer!(:replace, w), fn -> {:erased, erase!(w.uid)} end]
            barrier = self()

            tasks =
              for fun <- funs do
                Task.async(fn ->
                  send(barrier, {:ready, self()})

                  receive do
                    :go -> T.safely(fun)
                  after
                    30_000 -> :no_go
                  end
                end)
              end

            for _ <- tasks, do: assert_receive({:ready, _}, 15_000)
            for t <- tasks, do: send(t.pid, :go)
            results = Enum.map(tasks, &Task.await(&1, 60_000))

            for r <- results do
              case r do
                %Plug.Conn{status: status} -> assert status < 500, "round #{round}: a request failed with #{status} (a deadlock victim answers 500)"
                {:erased, {:ok, %{keys_deleted_at: _}}} -> :ok
                other -> flunk("round #{round}: an operation failed: #{inspect(other, limit: 5)}")
              end
            end
          end
        end)

      refute log =~ "deadlock", "a deadlock was detected: #{String.slice(log, 0, 300)}"
    end
  end

  # ═══ Scenario 5: a failed decision read is an error, never a first upload ═══════════════════════════════════════════════════════════

  describe "scenario 5 - a failed locked read" do
    test "pin: the upload of a user WITH stored keys answers 500 M_UNKNOWN, stores nothing, and no log line carries key material", ctx do
      w = oauth_world!(ctx)
      before = E.fp("cross_signing_keys", w.uid)
      new_keys = T.cross_signing_keys(w.uid, "NEWER")
      break_master_read!()

      log =
        capture_debug(fn ->
          send(self(), {:resp, T.safely(fn -> T.device_signing_upload(w.s.at, %{"master_key" => w.old["master_key"]}) end)})
          send(self(), {:resp2, T.safely(fn -> T.device_signing_upload(w.s.at, new_keys) end)})
        end)

      assert_received {:resp, same}
      assert_received {:resp2, other}
      restore_master_read!()

      assert status!(same) == 500 and T.json(same)["errcode"] == "M_UNKNOWN", "an idempotent upload cannot be answered 200 from a failed read"
      assert status!(other) == 500 and T.json(other)["errcode"] == "M_UNKNOWN", "a failed read is never the UIA-free branch or a challenge"
      assert E.fp("cross_signing_keys", w.uid) == before
      refute_material!(log, key_strings(w.old) ++ key_strings(new_keys))
    end

    test "pin: the first upload of a user WITHOUT a row answers 500 M_UNKNOWN and creates no row (never the first-upload branch)" do
      uid = T.provision_user!()
      s = legacy!(uid)
      keys = T.cross_signing_keys(uid, "NOROW")
      break_master_read!()

      log = capture_debug(fn -> send(self(), {:resp, T.device_signing_upload(s.at, keys)}) end)
      assert_received {:resp, conn}
      restore_master_read!()

      assert conn.status == 500 and T.json(conn)["errcode"] == "M_UNKNOWN"
      assert E.count("cross_signing_keys", uid) == 0, "nothing was written during the outage"
      refute_material!(log, key_strings(keys))
    end

    test "the signature merge of a user WITH stored keys answers 500 (or raises: the server answers 500), stores nothing, and logs no key material", ctx do
      w = oauth_world!(ctx)
      before = E.fp("cross_signing_keys", w.uid)
      body = sig_body(w.uid, w.old["master_key"], "R")
      break_master_read!()

      log =
        capture_debug(fn ->
          answer =
            try do
              signatures_upload(w.s.at, body)
            rescue
              e in Plug.Conn.WrapperError -> {:raised, e.reason}
            end

          send(self(), {:resp, answer})
        end)

      assert_received {:resp, answer}
      restore_master_read!()

      case answer do
        %Plug.Conn{status: status} ->
          assert status == 500, "a failed read is not a failure entry of a 200: got #{status} #{inspect(T.json(answer))}"

        {:raised, reason} ->
          assert Exception.message(reason) =~ "merge failed"
      end

      assert E.fp("cross_signing_keys", w.uid) == before, "nothing is stored"
      refute_material!(log, key_strings(w.old) ++ ["sig-R", "ed25519:SGR"])
    end

    # The column fault above makes the SQL statement fail (and aborts the transaction, so a swallowed error would still end in a 500). A row whose
    # JSON cannot be decoded fails AFTER a successful read: the transaction stays usable, so only an error-aware decision answers 500.
    test "pin: an undecodable stored row (the SQL succeeds, the decode fails): the upload answers 500 and writes nothing, never a first upload", ctx do
      w = oauth_world!(ctx)
      T.privileged_sql!("UPDATE cross_signing_keys SET master_key_json = 'not json' WHERE user_id = $1", [w.uid])
      before = E.fp("cross_signing_keys", w.uid)

      conn = T.device_signing_upload(w.s.at, T.cross_signing_keys(w.uid, "OVER"))

      assert conn.status == 500 and T.json(conn)["errcode"] == "M_UNKNOWN", "got #{conn.status}: #{conn.resp_body}"
      assert E.fp("cross_signing_keys", w.uid) == before, "the undecodable row was not overwritten by a first upload"
    end

    test "pin: an undecodable stored row: the signature merge answers 500 (or raises: the server answers 500) and writes nothing", ctx do
      w = oauth_world!(ctx)
      T.privileged_sql!("UPDATE cross_signing_keys SET master_key_json = 'not json' WHERE user_id = $1", [w.uid])
      before = E.fp("cross_signing_keys", w.uid)
      body = sig_body(w.uid, w.old["master_key"], "U")

      answer =
        try do
          signatures_upload(w.s.at, body)
        rescue
          e in Plug.Conn.WrapperError -> {:raised, e.reason}
        end

      case answer do
        %Plug.Conn{status: status} -> assert status == 500, "an unreadable row is not a failure entry of a 200: got #{status} #{inspect(T.json(answer))}"
        {:raised, reason} -> assert Exception.message(reason) =~ "merge failed"
      end

      assert E.fp("cross_signing_keys", w.uid) == before, "nothing is stored"
    end

    test "lock_keys/1 on an undecodable row: {:error, reason} and the transaction stays usable (no all-nil map, no raise)", ctx do
      assert_lock_keys_defined!()
      w = oauth_world!(ctx)
      T.privileged_sql!("UPDATE cross_signing_keys SET master_key_json = 'not json' WHERE user_id = $1", [w.uid])

      result = probe(fn -> {T.safely(fn -> apply(Store, :lock_keys, [w.uid]) end), T.sql!("SELECT 1").rows} end)

      assert {{:error, _reason}, [[1]]} = result
    end
  end
end
