defmodule Nebu.Matrix.SyncTokenPerDeviceStoreTest do
  @moduledoc """
  Acceptance tests for story `sync-token-per-device` (epic oauth-broker, follow-up `fd`), store half, D9 / D11 / Oracle F3 / F5:
  what only the REAL database decides (lesson of the sibling suites: a fake hides an `ON CONFLICT` bug). Everything runs on the throwaway
  PostgreSQL (`.oauth-ci/quick.sh`), as the runtime role through `Nebu.Repo`; the position / lock / wake-up contract of the four stores:

    * `AccountDataStore.put/3`: one transaction, first `pg_advisory_xact_lock(hashtextextended('sync_global|' || user_id, 0))`, then the
      upsert that draws `stream_pos = nextval('sync_global_pos_seq')` in the INSERT values AND in the `ON CONFLICT DO UPDATE` branch (an overwrite
      must get a NEW position), then, AFTER the commit, a wake-up `{:account_data_changed, nil}` to every member of the `:pg` group
      `user:<id>` (`:pg.get_members/1`, cluster-wide). New readers `list_since(user_id, pos)` -> `{latest_pos, [{type, content_map}]}` and
      `pending_since?(user_id, pos)`: neither touches the consume-once `changed` flag. The two flag readers stay (device-less requests).
    * `CrossSigningKeyStore.put_keys/2`: the same transaction and the SAME per-user lock (one key for both tables), `changed_pos` stamped from the
      same sequence in both branches; `changed_since?(user_id, pos)` -> `{changed_pos, boolean}`. A signature merge (`merge_signatures/4`) and
      `consume_changed_flag/1` never touch `changed_pos`; a cross-signing upload sends NO wake-up (D11).
    * `Nebu.Matrix.Session.PgStore` (+ `.Postgres`): `get_positions(user, device)` -> `{account_data_pos, cross_signing_pos}` (`{0, 0}` without a
      row) and `advance_positions(user, device, token, ad_pos, cs_pos)` -> `:ok`: `GREATEST` per column, only `WHERE ... AND since_token = token`,
      never inserts a row, never touches another row; the token upsert (`persist_since_token`) leaves the columns alone.

  Contract choices taken literally from the story text (the dev may not rename them): the function names and tuple shapes above, the lock key
  `'sync_global|' || user_id`, the message `{:account_data_changed, nil}`, the sequence name `sync_global_pos_seq`.

  After adding migration 000052 reset the throwaway database (`docker rm -f nebu-oauth-pg`).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.AccountDataStore
  alias Nebu.Matrix.CrossSigningKeyStore
  alias Nebu.Matrix.Session.PgStore
  alias Nebu.OAuth.TestSupport, as: T

  @account_data_src Path.expand("../../../lib/nebu/matrix/account_data_store.ex", __DIR__)
  @cross_signing_src Path.expand("../../../lib/nebu/matrix/cross_signing_key_store.ex", __DIR__)

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp body(n), do: Jason.encode!(%{"n" => n, "r" => T.rand(4)})

  # short local names for the store functions of this story (the contract names, called directly)
  defp list_since(uid, pos), do: AccountDataStore.list_since(uid, pos)
  defp pending_since?(uid, pos), do: AccountDataStore.pending_since?(uid, pos)
  defp changed_since?(uid, pos), do: CrossSigningKeyStore.changed_since?(uid, pos)
  defp get_positions(uid, dev), do: PgStore.get_positions(uid, dev)
  defp advance_positions(uid, dev, tok, ad, cs), do: PgStore.advance_positions(uid, dev, tok, ad, cs)

  defp keys(uid, tag), do: T.cross_signing_keys(uid, tag)

  defp ad_pos(uid, type), do: T.sql!("SELECT stream_pos FROM account_data WHERE user_id = $1 AND type = $2", [uid, type]).rows |> hd() |> hd()
  defp ad_flag(uid, type), do: T.sql!("SELECT changed FROM account_data WHERE user_id = $1 AND type = $2", [uid, type]).rows |> hd() |> hd()
  defp ad_rows(uid), do: T.sql!("SELECT count(*) FROM account_data WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  defp cs_pos(uid), do: T.sql!("SELECT changed_pos FROM cross_signing_keys WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  defp cs_flag(uid), do: T.sql!("SELECT cross_signing_changed FROM cross_signing_keys WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  defp token_rows(uid), do: T.sql!("SELECT * FROM sync_tokens WHERE user_id = $1 ORDER BY device_id", [uid]).rows
  defp token_rows_except(uid, dev), do: T.sql!("SELECT * FROM sync_tokens WHERE user_id = $1 AND device_id <> $2 ORDER BY device_id", [uid, dev]).rows
  defp types(entries), do: entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  defp user! do
    uid = T.provision_user!()
    on_exit(fn -> for t <- ["account_data", "cross_signing_keys", "sync_tokens"], do: T.privileged_sql!("DELETE FROM #{t} WHERE user_id = $1", [uid]) end)
    uid
  end

  defp start_pg! do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  # Holds the per-user write lock in an UNCOMMITTED transaction: `writer` runs inside it (so the lock lives until `release`).
  # Returns `{task, backend_pid}`; `release.()` commits.
  defp hold(writer) do
    test = self()

    task =
      Task.async(fn ->
        Nebu.Repo.transaction(fn ->
          writer.()
          %{rows: [[pid]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT pg_backend_pid()", [])
          send(test, {:holding, self(), pid})

          receive do
            :release -> :ok
          after
            15_000 -> :timeout
          end
        end)
      end)

    receive do
      {:holding, holder, pid} -> {task, holder, pid}
    after
      5_000 -> flunk("the writer never reached its uncommitted state")
    end
  end

  defp release(task, holder) do
    send(holder, :release)
    assert {:ok, :ok} = Task.await(task, 10_000)
  end

  defp lock_count(backend_pid, key_text) do
    T.sql!(
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid = $1 AND ((classid::bigint << 32) | objid::bigint) = hashtextextended($2::text, 0)",
      [backend_pid, key_text]
    ).rows
    |> hd()
    |> hd()
  end

  # ═══ AccountDataStore: stream_pos in both upsert branches ════════════════════════════════════════════════════════════════════

  describe "AccountDataStore.put/3 draws stream_pos" do
    @describetag :integration

    test "every insert gets the next value of sync_global_pos_seq (strictly increasing, positive)" do
      uid = user!()
      for t <- ["t1", "t2", "t3"], do: assert(:ok = AccountDataStore.put(uid, t, body(t)))
      {p1, p2, p3} = {ad_pos(uid, "t1"), ad_pos(uid, "t2"), ad_pos(uid, "t3")}

      assert 0 < p1 and p1 < p2 and p2 < p3
      assert %{rows: [[next]]} = T.sql!("SELECT nextval('sync_global_pos_seq')")
      assert next > p3
    end

    test "an OVERWRITE (ON CONFLICT DO UPDATE) draws a NEW, higher position and keeps one row (nextval only on insert would never deliver it)" do
      uid = user!()
      assert :ok = AccountDataStore.put(uid, "t1", body(1))
      assert :ok = AccountDataStore.put(uid, "t2", body(2))
      {p1, p2} = {ad_pos(uid, "t1"), ad_pos(uid, "t2")}

      assert :ok = AccountDataStore.put(uid, "t1", body(3))
      p1b = ad_pos(uid, "t1")
      assert p1b > p2, "the overwritten row is now the newest change of the user (was #{p1}, is #{p1b}, other row #{p2})"
      assert ad_pos(uid, "t2") == p2, "an overwrite of t1 does not move t2"
      assert ad_rows(uid) == 2, "one row per (user, type)"
    end

    test "a PUT with IDENTICAL content is a change too: it draws a new position (re-delivered, as today's flag)" do
      uid = user!()
      same = body("same")
      assert :ok = AccountDataStore.put(uid, "t1", same)
      first = ad_pos(uid, "t1")
      assert :ok = AccountDataStore.put(uid, "t1", same)
      assert ad_pos(uid, "t1") > first
    end

    test "the consume-once changed flag is still SET by every put (the device-less clients read it)" do
      uid = user!()
      assert :ok = AccountDataStore.put(uid, "t1", body(1))
      assert ad_flag(uid, "t1") == true
      T.sql!("UPDATE account_data SET changed = FALSE WHERE user_id = $1", [uid])
      assert :ok = AccountDataStore.put(uid, "t1", body(2))
      assert ad_flag(uid, "t1") == true
    end

    test "the stored content stays byte for byte what the client sent (opaque, ADR-011)" do
      uid = user!()
      raw = ~s({"b":1,  "a":[true,null,"é ü"],"c":{"z":0.50}})
      assert :ok = AccountDataStore.put(uid, "t1", raw)
      assert AccountDataStore.get(uid, "t1") == {:ok, raw}
      assert :ok = AccountDataStore.put(uid, "t1", raw)
      assert AccountDataStore.get(uid, "t1") == {:ok, raw}
    end

    test "concurrent writers (12 tasks, 2 users) get pairwise distinct positions" do
      u1 = user!()
      u2 = user!()

      1..12
      |> Enum.map(fn i -> Task.async(fn -> AccountDataStore.put(if(rem(i, 2) == 0, do: u1, else: u2), "t#{i}", body(i)) end) end)
      |> Task.await_many(15_000)
      |> Enum.each(&assert(&1 == :ok))

      %{rows: rows} = T.sql!("SELECT stream_pos FROM account_data WHERE user_id = ANY($1)", [[u1, u2]])
      positions = List.flatten(rows)
      assert length(positions) == 12
      assert positions == Enum.uniq(positions)
    end
  end

  # ═══ AccountDataStore: the two new readers ═══════════════════════════════════════════════════════════════════════════════════

  describe "AccountDataStore.list_since/2 and pending_since?/2" do
    @describetag :integration

    test "list_since(user, 0) returns every row as {type, content_map}; latest is the highest position; entries come oldest first" do
      uid = user!()
      for {t, n} <- [{"a", 1}, {"b", 2}, {"c", 3}], do: AccountDataStore.put(uid, t, Jason.encode!(%{"n" => n}))

      assert {latest, entries} = list_since(uid, 0)
      assert entries == [{"a", %{"n" => 1}}, {"b", %{"n" => 2}}, {"c", %{"n" => 3}}]
      assert latest == ad_pos(uid, "c")
    end

    test "list_since(user, pos) returns only rows with a LARGER position; an overwritten row comes back once with its NEW content" do
      uid = user!()
      for {t, n} <- [{"a", 1}, {"b", 2}, {"c", 3}], do: AccountDataStore.put(uid, t, Jason.encode!(%{"n" => n}))
      pa = ad_pos(uid, "a")

      assert {_, entries} = list_since(uid, pa)
      assert types(entries) == ["b", "c"]

      {latest, _} = list_since(uid, 0)
      assert {_, []} = list_since(uid, latest)

      AccountDataStore.put(uid, "a", Jason.encode!(%{"n" => 99}))
      assert {new_latest, [{"a", %{"n" => 99}}]} = list_since(uid, latest)
      assert new_latest == ad_pos(uid, "a") and new_latest > latest
    end

    test "list_since for a user without rows is {0, []}" do
      assert {0, []} = list_since(user!(), 0)
    end

    test "another user's rows are NEVER returned (cross-user isolation) and never make pending_since? true" do
      mine = user!()
      theirs = user!()
      marker = "secret-#{T.rand(6)}"
      AccountDataStore.put(theirs, "m.secret_storage.default_key", Jason.encode!(%{"key" => marker}))
      AccountDataStore.put(mine, "t1", body(1))

      {_, entries} = list_since(mine, 0)
      assert types(entries) == ["t1"]
      refute inspect(entries) =~ marker

      assert {_, []} = list_since(user!(), 0)
      other = user!()
      refute pending_since?(other, 0)
    end

    test "pending_since?: true only while a row has a position above the argument" do
      uid = user!()
      refute pending_since?(uid, 0)

      AccountDataStore.put(uid, "t1", body(1))
      p = ad_pos(uid, "t1")
      assert pending_since?(uid, 0)
      assert pending_since?(uid, p - 1)
      refute pending_since?(uid, p)
      refute pending_since?(uid, p + 1_000_000)

      AccountDataStore.put(uid, "t1", body(2))
      assert pending_since?(uid, p), "an overwrite makes the row pending again"
    end

    test "neither reader touches the changed flag or a position (reading is not consuming)" do
      uid = user!()
      AccountDataStore.put(uid, "t1", body(1))
      AccountDataStore.put(uid, "t2", body(2))
      before = T.sql!("SELECT type, stream_pos, changed, updated_at FROM account_data WHERE user_id = $1 ORDER BY type", [uid]).rows

      assert {_, [_, _]} = list_since(uid, 0)
      assert pending_since?(uid, 0)
      assert {_, [_, _]} = list_since(uid, 0)

      assert T.sql!("SELECT type, stream_pos, changed, updated_at FROM account_data WHERE user_id = $1 ORDER BY type", [uid]).rows == before
      assert ad_flag(uid, "t1") and ad_flag(uid, "t2")
    end

    test "the flag readers for device-less requests are unchanged (read-and-clear) and independent of the positions" do
      uid = user!()
      AccountDataStore.put(uid, "t1", Jason.encode!(%{"n" => 1}))
      AccountDataStore.put(uid, "t2", Jason.encode!(%{"n" => 2}))
      {p1, p2} = {ad_pos(uid, "t1"), ad_pos(uid, "t2")}

      assert AccountDataStore.list_changed_and_clear(uid) |> types() == ["t1", "t2"]
      assert AccountDataStore.list_changed_and_clear(uid) == []
      assert {_, entries} = list_since(uid, 0)
      assert types(entries) == ["t1", "t2"], "clearing the flag does not hide the rows from a position reader"

      AccountDataStore.put(uid, "t1", Jason.encode!(%{"n" => 3}))
      assert AccountDataStore.list_changed_and_clear(uid) == [{"t1", %{"n" => 3}}]

      assert AccountDataStore.list_all_and_clear(uid) |> types() == ["t1", "t2"]
      assert ad_pos(uid, "t2") == p2 and ad_pos(uid, "t1") > p1, "the flag readers never write a position"
    end
  end

  # ═══ CrossSigningKeyStore ════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "CrossSigningKeyStore.put_keys/2 and changed_since?/2" do
    @describetag :integration

    test "put_keys stamps changed_pos from the SAME sequence in the insert branch and in the update branch (also for identical keys)" do
      uid = user!()
      assert :ok = CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
      p1 = cs_pos(uid)
      assert p1 > 0

      assert :ok = CrossSigningKeyStore.put_keys(uid, keys(uid, "B"))
      p2 = cs_pos(uid)
      assert p2 > p1

      assert :ok = CrossSigningKeyStore.put_keys(uid, keys(uid, "B"))
      assert cs_pos(uid) > p2, "the same keys again still draw a new position (as today's flag is set again)"
      assert cs_flag(uid) == true
    end

    test "one sequence for both tables: account data and cross-signing positions interleave strictly" do
      uid = user!()
      AccountDataStore.put(uid, "t1", body(1))
      CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
      AccountDataStore.put(uid, "t2", body(2))

      assert ad_pos(uid, "t1") < cs_pos(uid) and cs_pos(uid) < ad_pos(uid, "t2")
    end

    test "changed_since?(user, pos) is {changed_pos, changed_pos > pos}; a user without keys is {0, false}" do
      uid = user!()
      assert {0, false} = changed_since?(uid, 0)

      CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
      p = cs_pos(uid)
      assert {^p, true} = changed_since?(uid, 0)
      assert {^p, true} = changed_since?(uid, p - 1)
      assert {^p, false} = changed_since?(uid, p)
      assert {^p, false} = changed_since?(uid, p + 10)
    end

    test "changed_since? never clears the flag or moves the position (the device-less flag stays for the device-less client)" do
      uid = user!()
      CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
      p = cs_pos(uid)
      for _ <- 1..3, do: changed_since?(uid, 0)
      assert cs_flag(uid) == true and cs_pos(uid) == p

      assert CrossSigningKeyStore.consume_changed_flag(uid) == true
      assert CrossSigningKeyStore.consume_changed_flag(uid) == false
      assert cs_pos(uid) == p, "consuming the flag does not touch the position"
      assert {^p, true} = changed_since?(uid, 0), "the position reader is independent of the flag"
    end

    test "a signature merge is not a key change: it moves neither changed_pos nor the flag" do
      uid = user!()
      CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
      CrossSigningKeyStore.consume_changed_flag(uid)
      p = cs_pos(uid)

      # the submitted object is required (story cross-signing-upload-races): the stored master object itself
      master = CrossSigningKeyStore.get_keys(uid)["master_key"]
      assert :ok = CrossSigningKeyStore.merge_signatures(uid, "MSKA", %{uid => %{"ed25519:SIGNER" => "sig"}}, master)
      assert cs_pos(uid) == p
      assert cs_flag(uid) == false
    end

    test "changed_pos of one user never shows up for another (per-user row)" do
      u1 = user!()
      u2 = user!()
      CrossSigningKeyStore.put_keys(u1, keys(u1, "A"))
      assert {0, false} = changed_since?(u2, 0)
    end
  end

  # ═══ the advisory lock (commit order == position order) ══════════════════════════════════════════════════════════════════════

  describe "per-user advisory lock of the global writers" do
    @describetag :integration

    test "an account data PUT holds the sync_global| advisory lock of the user until its commit, and NOT the room account data key" do
      uid = user!()
      {task, holder, pid} = hold(fn -> AccountDataStore.put(uid, "t1", body(1)) end)

      assert lock_count(pid, "sync_global|" <> uid) == 1, "the namespaced per-user key is held while the writer is uncommitted"
      assert lock_count(pid, uid) == 0, "the room account data store's key (hashtextextended(user_id, 0)) is NOT taken: no serialisation against it"

      release(task, holder)
    end

    test "a cross-signing upload takes the SAME per-user key (one key for BOTH tables)" do
      uid = user!()
      {task, holder, pid} = hold(fn -> CrossSigningKeyStore.put_keys(uid, keys(uid, "A")) end)
      assert lock_count(pid, "sync_global|" <> uid) == 1
      release(task, holder)
    end

    test "a second writer of the SAME user waits for the first one's commit; positions follow the commit order" do
      uid = user!()
      {task, holder, _pid} = hold(fn -> AccountDataStore.put(uid, "first", body(1)) end)

      second = Task.async(fn -> AccountDataStore.put(uid, "second", body(2)) end)
      assert Task.yield(second, 400) == nil, "the second writer must wait for the lock of the uncommitted first one"
      assert {0, []} = list_since(uid, 0), "while the first is uncommitted a reader sees neither of them"

      release(task, holder)
      assert :ok = Task.await(second, 10_000)

      assert ad_pos(uid, "first") < ad_pos(uid, "second"), "position order == commit order"
      assert {_, entries} = list_since(uid, 0)
      assert types(entries) == ["first", "second"]
    end

    test "a cross-signing upload and an account data PUT of the same user serialise (the shared lock)" do
      uid = user!()
      {task, holder, _pid} = hold(fn -> CrossSigningKeyStore.put_keys(uid, keys(uid, "A")) end)

      second = Task.async(fn -> AccountDataStore.put(uid, "t1", body(1)) end)
      assert Task.yield(second, 400) == nil

      release(task, holder)
      assert :ok = Task.await(second, 10_000)
      assert cs_pos(uid) < ad_pos(uid, "t1")
    end

    test "a writer of ANOTHER user is not blocked by the held lock" do
      u1 = user!()
      u2 = user!()
      {task, holder, _pid} = hold(fn -> AccountDataStore.put(u1, "t1", body(1)) end)

      other = Task.async(fn -> AccountDataStore.put(u2, "t1", body(2)) end)
      assert {:ok, :ok} = Task.yield(other, 3_000) || Task.shutdown(other, :brutal_kill), "the lock is per user"

      release(task, holder)
    end
  end

  # ═══ the wake-up (D11) ═══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "AccountDataStore.put/3 wake-up" do
    @describetag :integration

    setup do
      start_pg!()
      :ok
    end

    test "every member of the user's :pg group user:<id> gets {:account_data_changed, nil}; other users' groups get nothing" do
      uid = user!()
      other = user!()
      test = self()
      :ok = :pg.join("user:#{uid}", self())
      :ok = :pg.join("user:#{other}", spawn_link(fn -> receive do m -> send(test, {:wrong_user, m}) end end))

      second = spawn_link(fn -> :pg.join("user:#{uid}", self()); send(test, :second_joined); receive do m -> send(test, {:second, m}) end end)
      assert_receive :second_joined, 2_000
      assert second in :pg.get_members("user:#{uid}")

      assert :ok = AccountDataStore.put(uid, "t1", body(1))

      assert_receive {:account_data_changed, nil}, 2_000
      assert_receive {:second, {:account_data_changed, nil}}, 2_000
      refute_receive {:wrong_user, _}, 200
      :pg.leave("user:#{uid}", self())
    end

    test "the wake-up is sent AFTER the commit: a woken reader already sees the row (a deferred commit-time trigger holds the commit back)" do
      uid = user!()
      test = self()
      name = "fd_slow_" <> T.rand(4)

      T.privileged_sql!("CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN PERFORM pg_sleep(0.5); RETURN NULL; END $$ LANGUAGE plpgsql")

      T.privileged_sql!(
        "CREATE CONSTRAINT TRIGGER #{name} AFTER INSERT OR UPDATE ON account_data DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.user_id = '#{uid}') EXECUTE FUNCTION #{name}()"
      )

      on_exit(fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON account_data")
        T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
      end)

      reader =
        spawn_link(fn ->
          :pg.join("user:#{uid}", self())
          send(test, :reader_ready)

          receive do
            {:account_data_changed, _} -> send(test, {:seen_rows, T.sql!("SELECT count(*) FROM account_data WHERE user_id = $1", [uid]).rows |> hd() |> hd()})
          end
        end)

      assert_receive :reader_ready, 2_000
      assert Process.alive?(reader)
      assert :ok = AccountDataStore.put(uid, "t1", body(1))
      assert_receive {:seen_rows, 1}, 5_000
    end

    test "a failed write sends NO wake-up and leaves no row" do
      uid = user!()
      name = "fd_fail_" <> T.rand(4)

      T.privileged_sql!("CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'atdd: account_data write blocked'; END $$ LANGUAGE plpgsql")

      T.privileged_sql!(
        "CREATE TRIGGER #{name} BEFORE INSERT OR UPDATE ON account_data FOR EACH ROW WHEN (NEW.user_id = '#{uid}') EXECUTE FUNCTION #{name}()"
      )

      on_exit(fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON account_data")
        T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
      end)

      :ok = :pg.join("user:#{uid}", self())

      outcome =
        try do
          AccountDataStore.put(uid, "t1", body(1))
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end

      # review m4: the contract is a RETURNED {:error, reason} (the route maps it to 500 M_UNKNOWN), never a raise (a raised Postgrex error can quote values)
      assert {:error, _} = outcome, "the blocked write is returned as an error, not stored and not raised: #{inspect(outcome)}"
      refute_receive {:account_data_changed, _}, 300
      assert ad_rows(uid) == 0
      :pg.leave("user:#{uid}", self())
    end

    test "a cross-signing upload sends no wake-up in this story (its device_lists entry is delivered with the next response)" do
      uid = user!()
      :ok = :pg.join("user:#{uid}", self())
      assert :ok = CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
      refute_receive {:account_data_changed, _}, 300
      :pg.leave("user:#{uid}", self())
    end

    test "put/3 does not raise when nobody listens (the wake-up never fails the PUT)" do
      assert :ok = AccountDataStore.put(user!(), "t1", body(1))
    end
  end

  describe "wake-up is cluster-wide (static)" do
    test "neither global store reaches processes node-locally: no :pg.get_local_members (cluster-safety); the layout of the code is free" do
      for src <- [File.read!(@account_data_src), File.read!(@cross_signing_src)] do
        assert byte_size(src) > 1_000, "positive control: the source was read"
        refute src =~ "get_local_members"
      end
    end
  end

  # Hides columns from the runtime role by renaming them (privileged, restored in `after` AND in on_exit). A failed restore is NOT swallowed.
  defp with_hidden_columns!(columns, fun) do
    restore = fn ->
      for {table, col} <- columns do
        hidden = "fd_hidden_" <> col

        %{rows: [[n]]} =
          T.privileged_sql!(
            "SELECT count(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
            [table, hidden]
          )

        if n == 1, do: T.privileged_sql!("ALTER TABLE #{table} RENAME COLUMN #{hidden} TO #{col}")
      end

      :ok
    end

    on_exit(restore)
    for {table, col} <- columns, do: T.privileged_sql!("ALTER TABLE #{table} RENAME COLUMN #{col} TO fd_hidden_#{col}")

    try do
      fun.()
    after
      restore.()
    end
  end

  describe "the readers never raise (failure direction: deliver again)" do
    @describetag :integration

    test "list_since is {pos, []} and pending_since? false while account_data.stream_pos is unreadable; both work again afterwards" do
      uid = user!()
      AccountDataStore.put(uid, "t1", body(1))
      p = ad_pos(uid, "t1")

      {listed, pending} = with_hidden_columns!([{"account_data", "stream_pos"}], fn -> {list_since(uid, 3), pending_since?(uid, 3)} end)

      assert listed == {3, []}, "a failed read does not advance the position and delivers nothing now"
      assert pending == false
      assert {^p, [{"t1", _}]} = list_since(uid, 0)
      assert pending_since?(uid, 0)
    end

    test "changed_since? does not raise and reports no change while cross_signing_keys.changed_pos is unreadable; it works again afterwards" do
      uid = user!()
      CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
      p = cs_pos(uid)

      {_pos, changed?} = with_hidden_columns!([{"cross_signing_keys", "changed_pos"}], fn -> changed_since?(uid, 0) end)

      assert changed? == false
      assert {^p, true} = changed_since?(uid, 0)
    end

    test "get_positions is {0, 0} and advance_positions does not raise while the sync_tokens position columns are unreadable" do
      uid = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")
      :ok = advance_positions(uid, "DEVA", t, 4, 6)

      {positions, advanced} =
        with_hidden_columns!([{"sync_tokens", "account_data_pos"}, {"sync_tokens", "cross_signing_pos"}], fn ->
          {get_positions(uid, "DEVA"), advance_positions(uid, "DEVA", t, 9, 9)}
        end)

      assert positions == {0, 0}
      assert advanced == :ok or match?({:error, _}, advanced), "a failure is returned, never raised"
      assert {4, 6} = get_positions(uid, "DEVA"), "the failed advance changed nothing"
    end
  end

  # ═══ PgStore: the two position columns of the device's row ═══════════════════════════════════════════════════════════════════

  describe "PgStore.get_positions/2 and advance_positions/5" do
    @describetag :integration

    defp token(label), do: "tok-#{label}-#{T.rand(5)}"

    test "the facade and the Postgres module export both functions" do
      assert function_exported?(PgStore, :get_positions, 2)
      assert function_exported?(PgStore, :advance_positions, 5)
      assert function_exported?(PgStore.Postgres, :get_positions, 2)
      assert function_exported?(PgStore.Postgres, :advance_positions, 5)
    end

    test "get_positions is {0, 0} without a row and for a freshly persisted device row" do
      uid = user!()
      assert {0, 0} = get_positions(uid, "DEVA")
      assert :ok = PgStore.persist_since_token(uid, "DEVA", token("a"), nil)
      assert {0, 0} = get_positions(uid, "DEVA")
    end

    test "advance_positions sets both columns for the matching token, per column GREATEST: a lower value never moves a column back" do
      uid = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")

      assert :ok = advance_positions(uid, "DEVA", t, 5, 0)
      assert {5, 0} = get_positions(uid, "DEVA")
      assert :ok = advance_positions(uid, "DEVA", t, 0, 7)
      assert {5, 7} = get_positions(uid, "DEVA"), "each column advances only to ITS OWN source (a shared column would give {7, 7})"
      assert :ok = advance_positions(uid, "DEVA", t, 3, 2)
      assert {5, 7} = get_positions(uid, "DEVA"), "GREATEST"
      assert :ok = advance_positions(uid, "DEVA", t, 9, 9)
      assert {9, 9} = get_positions(uid, "DEVA")
    end

    test "advance_positions with a token that is not the stored one changes nothing (a superseded response must not advance the positions)" do
      uid = user!()
      :ok = PgStore.persist_since_token(uid, "DEVA", token("new"), "$ev")
      before = token_rows(uid)

      assert :ok = advance_positions(uid, "DEVA", token("old"), 10, 10)
      assert {0, 0} = get_positions(uid, "DEVA")
      assert token_rows(uid) == before
    end

    test "advance_positions never creates a row (no orphan for a deleted device) and never touches another device, the '' row or another user" do
      uid = user!()
      other = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")
      :ok = PgStore.persist_since_token(uid, "DEVB", token("b"), "$ev")
      :ok = PgStore.persist_since_token(uid, token("empty"), nil)
      :ok = PgStore.persist_since_token(other, "DEVA", t, "$ev")
      before = {token_rows_except(uid, "DEVA"), token_rows(other)}

      assert :ok = advance_positions(uid, "DEVA", t, 4, 6)
      assert {4, 6} = get_positions(uid, "DEVA")
      assert {token_rows_except(uid, "DEVA"), token_rows(other)} == before, "no other row changes, byte for byte"

      assert :ok = advance_positions(uid, "GONE", t, 4, 6)
      assert T.sql!("SELECT count(*) FROM sync_tokens WHERE user_id = $1 AND device_id = 'GONE'", [uid]).rows == [[0]]
      assert {0, 0} = get_positions(uid, "GONE")
    end

    test "the token upsert (persist_since_token) leaves the position columns alone, for the device row and for the '' row" do
      uid = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")
      :ok = advance_positions(uid, "DEVA", t, 5, 7)

      t2 = token("a2")
      assert :ok = PgStore.persist_since_token(uid, "DEVA", t2, "$ev2")
      assert {5, 7} = get_positions(uid, "DEVA"), "the core's upsert is not allowed to reset the positions"

      assert :ok = PgStore.persist_since_token(uid, token("legacy"), "$ev")
      assert {0, 0} = get_positions(uid, "")
    end

    test "deleting the device row takes its positions with it, a re-created row starts at {0, 0}, the user-wide delete removes all rows" do
      uid = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")
      :ok = PgStore.persist_since_token(uid, "DEVB", token("b"), "$ev")
      :ok = advance_positions(uid, "DEVA", t, 5, 7)

      assert :ok = PgStore.invalidate_session(uid, "DEVA")
      assert T.sql!("SELECT device_id FROM sync_tokens WHERE user_id = $1", [uid]).rows == [["DEVB"]]
      assert {0, 0} = get_positions(uid, "DEVA")

      :ok = PgStore.persist_since_token(uid, "DEVA", token("again"), nil)
      assert {0, 0} = get_positions(uid, "DEVA")

      assert :ok = PgStore.invalidate_session(uid)
      assert token_rows(uid) == []
    end
  end

  # ═══ review cycle 0, m1: a failed read of an initial-shaped answer rewinds account_data_pos ════════════════════════════════════

  describe "list_since_checked/2 and PgStore.rewind_account_data_position/4" do
    @describetag :integration

    test "list_since_checked is {:ok, latest, entries} like list_since, and :error (never a raise) when the read fails" do
      uid = user!()
      AccountDataStore.put(uid, "t1", body(1))
      p = ad_pos(uid, "t1")
      assert {:ok, ^p, [{"t1", _}]} = AccountDataStore.list_since_checked(uid, 0)
      assert {:ok, ^p, []} = AccountDataStore.list_since_checked(uid, p)
      assert {:ok, 0, []} = AccountDataStore.list_since_checked(user!(), 0)

      assert :error = with_hidden_columns!([{"account_data", "stream_pos"}], fn -> AccountDataStore.list_since_checked(uid, 0) end)
      assert {:ok, ^p, [_]} = AccountDataStore.list_since_checked(uid, 0)
    end

    test "rewind sets account_data_pos to 0 (plain SET) and advances cross_signing_pos with GREATEST, only for the matching token" do
      uid = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")
      :ok = advance_positions(uid, "DEVA", t, 9, 7)

      assert :ok = PgStore.rewind_account_data_position(uid, "DEVA", token("other"), 99)
      assert {9, 7} = get_positions(uid, "DEVA"), "another token changes nothing"

      assert :ok = PgStore.rewind_account_data_position(uid, "DEVA", t, 3)
      assert {0, 7} = get_positions(uid, "DEVA"), "account data back to 0, cross-signing never lowered"
      assert :ok = PgStore.rewind_account_data_position(uid, "DEVA", t, 11)
      assert {0, 11} = get_positions(uid, "DEVA")
    end

    test "rewind never creates a row and never touches another device, the '' row or another user" do
      uid = user!()
      other = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVB", t, "$ev")
      :ok = PgStore.persist_since_token(uid, t, "$ev")
      :ok = PgStore.persist_since_token(other, "DEVA", t, "$ev")
      :ok = advance_positions(uid, "DEVB", t, 5, 5)
      :ok = advance_positions(other, "DEVA", t, 5, 5)
      before = {token_rows(uid), token_rows(other)}

      assert :ok = PgStore.rewind_account_data_position(uid, "DEVA", t, 1)
      assert {token_rows(uid), token_rows(other)} == before
    end

    test "rewind does not raise while the position columns are unreadable" do
      uid = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")

      result =
        with_hidden_columns!([{"sync_tokens", "account_data_pos"}, {"sync_tokens", "cross_signing_pos"}], fn ->
          PgStore.rewind_account_data_position(uid, "DEVA", t, 1)
        end)

      assert match?({:error, _}, result), "a failure is returned, never raised: #{inspect(result)}"
    end
  end

  # ═══ interleaving (Scenario 5) ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "interleaving of the two position reads" do
    @describetag :integration

    # one /sync request as the route performs it: read the positions of the row once, read the account data, (a write commits here),
    # read the cross-signing position, advance both columns, each ONLY to the maximum of ITS OWN source
    defp request(uid, dev, tok, between \\ fn -> :ok end) do
      {ad0, cs0} = get_positions(uid, dev)
      {ad_latest, entries} = list_since(uid, ad0)
      between.()
      {cs_latest, changed?} = changed_since?(uid, cs0)
      :ok = advance_positions(uid, dev, tok, max(ad_latest, ad0), max(cs_latest, cs0))
      %{entries: entries, cs_changed?: changed?}
    end

    test "an account data row committing BETWEEN the two position reads is delivered by the NEXT request (two columns)" do
      uid = user!()
      t = token("a")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")

      first =
        request(uid, "DEVA", t, fn ->
          :ok = AccountDataStore.put(uid, "m.secret_storage.default_key", Jason.encode!(%{"key" => "k1"}))
          :ok = CrossSigningKeyStore.put_keys(uid, keys(uid, "A"))
        end)

      assert first.entries == [], "the account data row committed after the first read"
      assert first.cs_changed?, "the cross-signing change committed before the second read"

      {col_ad, col_cs} = get_positions(uid, "DEVA")
      row_pos = ad_pos(uid, "m.secret_storage.default_key")
      assert col_ad < row_pos, "the account data column only advanced to what the account data read saw"
      assert col_cs == cs_pos(uid), "the cross-signing column advanced to the cross-signing position"
      assert col_cs > row_pos, "the premise: the shared-column mistake would have jumped over the row"

      second = request(uid, "DEVA", t)
      assert second.entries == [{"m.secret_storage.default_key", %{"key" => "k1"}}], "delivered by the following request"
      refute second.cs_changed?, "and the own cross-signing change exactly once"
      third = request(uid, "DEVA", t)
      assert third.entries == [] and not third.cs_changed?
    end

    test "after interleaved writes every entry is delivered exactly once per device, independent of the other device" do
      uid = user!()
      t = %{"DEVA" => token("A"), "DEVB" => token("B")}
      for {d, tok} <- t, do: :ok = PgStore.persist_since_token(uid, d, tok, "$ev")

      :ok = AccountDataStore.put(uid, "x1", body(1))
      a1 = request(uid, "DEVA", t["DEVA"], fn -> AccountDataStore.put(uid, "x2", body(2)) end)
      assert types(a1.entries) == ["x1"]
      b1 = request(uid, "DEVB", t["DEVB"])
      assert types(b1.entries) == ["x1", "x2"], "device B is independent of what A consumed"
      a2 = request(uid, "DEVA", t["DEVA"])
      assert types(a2.entries) == ["x2"]
      assert request(uid, "DEVA", t["DEVA"]).entries == [] and request(uid, "DEVB", t["DEVB"]).entries == []
    end

    test "concurrent writers and a polling device: every written type reaches the device, none is skipped (lock + per-source positions)" do
      uid = user!()
      t = token("stress")
      :ok = PgStore.persist_since_token(uid, "DEVA", t, "$ev")
      expected = for i <- 1..24, do: "stress#{i}"
      test = self()

      writers =
        for w <- 0..3 do
          Task.async(fn ->
            for i <- 1..24, rem(i, 4) == w do
              :ok = AccountDataStore.put(uid, "stress#{i}", body(i))
              if rem(i, 5) == 0, do: :ok = CrossSigningKeyStore.put_keys(uid, keys(uid, "S#{i}"))
            end

            send(test, {:writer_done, w})
          end)
        end

      poller =
        Task.async(fn ->
          Stream.repeatedly(fn -> request(uid, "DEVA", t) end)
          |> Enum.reduce_while(MapSet.new(), fn r, acc ->
            acc = Enum.reduce(r.entries, acc, fn {type, _}, a -> MapSet.put(a, type) end)

            receive do
              :stop -> {:halt, acc}
            after
              0 -> {:cont, acc}
            end
          end)
        end)

      Task.await_many(writers, 30_000)
      for _ <- 0..3, do: assert_received({:writer_done, _})
      send(poller.pid, :stop)
      seen = Task.await(poller, 30_000)

      rest = request(uid, "DEVA", t)
      all = Enum.reduce(rest.entries, seen, fn {type, _}, a -> MapSet.put(a, type) end)
      assert MapSet.equal?(all, MapSet.new(expected)), "never delivered: #{inspect(expected -- MapSet.to_list(all))}"
    end
  end
end
