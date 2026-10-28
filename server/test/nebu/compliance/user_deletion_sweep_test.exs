defmodule Nebu.Compliance.UserDeletionSweepTest do
  @moduledoc """
  D8 of story `gdpr-erasure-global-data` (orchestrator decision on OQ-A): users that were erased BEFORE this release keep their `account_data`,
  `cross_signing_keys` and device-key rows (a second erasure answers `:conflict`). A one-off, idempotent OPERATOR step, SQL in the release note of
  `docs/architecture/07-deployment.md` and in the runbook `docs/compliance/gdpr-deletion-runbook.md`, built from the same table list as the erasure, deletes the
  leftover rows of users with `deletion_status = 'keys_deleted'`. It is a data fix the operator runs once after the deploy, not a migration.

  ## Contract pinned here (the story leaves the form open)

    * The SQL is a fenced ```sql block of `07-deployment.md` (the release note of this story) and a fenced ```sql block of the runbook; a block is the sweep when it
      contains `DELETE FROM` and `deletion_status = 'keys_deleted'`. Plain statements separated by `;`, `--` comment lines allowed, no placeholders, no psql
      meta commands, no DO block / function (so that a test can split and run it); `BEGIN` / `COMMIT` lines are allowed and ignored by the test, which runs all
      statements in ONE transaction.
    * D13 (orchestrator decision on gap G3): ALSO deletes the `devices` rows of the erased users (the legacy device rows with display name and last IP the old teardown left;
      `devices` is NOT in `erased_tables/0`, it is a separate statement of the sweep).
    * Review cycle 0 (D16, D17, D18 (a)): the sweep ALSO deletes the other teardown tables of the erased users (`matrix_sessions`, `sessions`, `jwt_device_bindings`,
      `sync_tokens`, `sync_room_cursors`, `oauth_idp_refresh_leases`: it is the retry path of a failed post-commit teardown), NULLs the `users` PII columns (display name,
      avatar and email ciphertexts) and sets `is_active = false` / `deactivated_at`, for `keys_deleted` users only.
    * Names every table of `UserDeletion.erased_tables/0` (`DELETE FROM <table>`) and anonymises the profile of the erased users
      (`displayname = 'Deleted User'`, `avatar_url = NULL`, `users.anonymized_at` set when NULL): gap G3 of the report (the story names only "the leftover rows").
    * Run by the OPERATOR role (the privileged migrate role of the test database): `oauth_codes` is protected by row level security for the runtime role.
    * Exactly the rows of the erased users go: an active user (`deletion_status` NULL) is byte-identical afterwards; the rows the erasure retains on purpose (events,
      room members, audit rows, public keys, the users row) are untouched; a second run changes nothing.
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @runbook Path.join(@root, "docs/compliance/gdpr-deletion-runbook.md")

  # the fenced sql blocks of a file whose text is a sweep
  defp sweep_blocks(path) do
    ~r/```sql\n(.*?)```/s
    |> Regex.scan(File.read!(path))
    |> Enum.map(&List.last/1)
    |> Enum.filter(&(&1 =~ ~r/DELETE\s+FROM/i and &1 =~ ~r/deletion_status\s*=\s*'keys_deleted'/))
  end

  defp sweep!(path) do
    case sweep_blocks(path) do
      [block | _] -> block
      [] -> flunk("#{Path.relative_to(path, @root)} has no fenced sql block with DELETE FROM ... deletion_status = 'keys_deleted' (the D8 sweep)")
    end
  end

  defp statements(block) do
    block
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) |> String.starts_with?("--")))
    |> Enum.join("\n")
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.upcase(&1) in ["BEGIN", "COMMIT", "START TRANSACTION"]))
  end

  describe "D8 - the operator sweep for users erased before this release (docs, static)" do
    test "07-deployment.md carries the sweep next to a note (story, one-off, idempotent, after the deploy)" do
      block = sweep!(@deploy)
      assert statements(block) != []
      refute block =~ ~r/\$\d|:[a-z_]+_id\b/, "no placeholders: the operator copies the statements as they are"
      refute block =~ ~r/^\s*\\/m, "no psql meta commands"

      text = File.read!(@deploy) |> String.replace(~r/\s+/, " ")
      assert text =~ "gdpr-erasure-global-data"
      assert text =~ ~r/gdpr-erasure-global-data.{0,3000}(one-off|once)/i
      assert text =~ ~r/gdpr-erasure-global-data.{0,4000}idempotent/i
      assert text =~ ~r/gdpr-erasure-global-data.{0,4000}after the (deploy|update|rollout)/i
    end

    test "the runbook carries the same sweep" do
      assert statements(sweep!(@runbook)) != []
    end

    test "both sweeps name every table of the erasure's own list and anonymise the profile" do
      for path <- [@deploy, @runbook] do
        block = sweep!(path)

        for table <- apply(Nebu.Compliance.UserDeletion, :erased_tables, []) do
          assert block =~ ~r/DELETE\s+FROM\s+#{table}\b/i, "#{Path.relative_to(path, @root)}: the sweep does not delete from #{table} (built from erased_tables/0)"
        end

        assert block =~ ~r/profiles/ and block =~ "Deleted User" and block =~ "anonymized_at"
        assert block =~ ~r/DELETE\s+FROM\s+devices\b/i, "#{Path.relative_to(path, @root)}: D13, the sweep deletes the devices rows of the erased users"
      end
    end

    test "both sweeps also delete the teardown tables, NULL the users PII columns and set is_active = false (D16, D17, D18 (a))" do
      for path <- [@deploy, @runbook] do
        block = sweep!(path)
        where = Path.relative_to(path, @root)

        for table <- E.teardown_tables(), do: assert(block =~ ~r/DELETE\s+FROM\s+#{table}\b/i, "#{where}: the sweep does not delete from the teardown table #{table}")
        for col <- E.users_pii_columns() ++ E.users_free_text_columns(), do: assert(block =~ ~r/#{col}\s*=\s*NULL/i, "#{where}: the sweep does not set users.#{col} to NULL")
        assert block =~ ~r/is_active\s*=\s*false/i and block =~ "deactivated_at", "#{where}: the sweep deactivates the erased users"
        assert block =~ "migration 000055", "#{where}: the sweep header says it runs after migration 000055"
      end
    end

    test "the two sweeps delete from the same set of tables" do
      tables = fn path -> ~r/DELETE\s+FROM\s+([a-z_]+)/i |> Regex.scan(sweep!(path)) |> Enum.map(&List.last/1) |> Enum.uniq() |> Enum.sort() end
      assert tables.(@deploy) == tables.(@runbook)
    end
  end

  describe "D8 - the sweep against a real database" do
    @describetag :integration

    setup do
      {:ok, E.setup_env!()}
    end

    # all statements in ONE transaction, as the operator (privileged migrate role)
    defp run_sweep!(block) do
      stmts = statements(block)

      T.with_privileged_conn(fn conn ->
        {:ok, _} = Postgrex.transaction(conn, fn c -> Enum.each(stmts, &Postgrex.query!(c, &1, [])) end)
      end)
    end

    defp as_erased_before_the_fix!(uid) do
      # the state the OLD erasure left: the status moved, private keys gone, every other row of the inventory still there
      T.sql!("UPDATE users SET deletion_status = 'keys_deleted', keys_deleted_at = $2 WHERE user_id = $1", [uid, System.system_time(:millisecond)])
      T.sql!("UPDATE user_keys SET private_key = NULL, deleted_at = $2 WHERE user_id = $1", [uid, System.system_time(:millisecond)])
    end

    # the legacy device row the OLD teardown left behind: a display name and the last IP address (personal data)
    defp with_legacy_device!(w) do
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(w.uid, w.dev, display_name: "Phone-" <> w.canary, last_seen_ip: "203.0.113.9", last_seen_ts: System.system_time(:millisecond))
      assert T.sql!("SELECT count(*) FROM devices WHERE user_id = $1 AND display_name = $2 AND last_seen_ip = '203.0.113.9'", [w.uid, "Phone-" <> w.canary]).rows == [[1]], "precondition: a legacy device row"
      w
    end

    test "deletes exactly the leftover rows and devices (D13) of erased users, nothing of active users; twice is a no-op", %{cid: cid} do
      block = sweep!(@deploy)
      erased_user = E.seed_user!(cid, "a") |> with_legacy_device!()
      active = E.seed_user!(cid, "c") |> with_legacy_device!()
      as_erased_before_the_fix!(erased_user.uid)
      assert E.count("account_data", erased_user.uid) == 6 and E.count("cross_signing_keys", erased_user.uid) == 1, "precondition: the leftovers"
      assert E.count("devices", erased_user.uid) >= 1 and E.count("devices", active.uid) >= 1
      active_devices = E.fp("devices", active.uid)

      active_before = E.snapshot(active.uid)
      active_profile = E.profile(active.uid)
      active_user = E.user_row(active.uid)
      retained = fn ->
        {E.events_of(erased_user.uid), E.fp("room_members", erased_user.uid), E.fp("user_keys", erased_user.uid), E.audit_rows(erased_user.uid, "user_deactivated"),
         # D16 / D17, old -> new: the sweep also NULLs the PII columns and sets is_active / deactivated_at (pinned by its own test below)
         Map.drop(E.user_row(erased_user.uid), ["anonymized_at", "is_active", "deactivated_at" | E.users_pii_columns() ++ E.users_free_text_columns()])}
      end
      retained_before = retained.()

      run_sweep!(block)

      for t <- E.expected_erased(), do: assert(E.count(t, erased_user.uid) == 0, "the sweep left rows of the erased user in #{t}")
      assert E.count("devices", erased_user.uid) == 0, "D13: the legacy devices rows (display name, last IP) of the erased user are swept"
      assert E.fp("devices", active.uid) == active_devices, "the active user's devices rows are byte-identical"
      assert E.profile(erased_user.uid) == %{displayname: "Deleted User", avatar_url: nil}
      assert is_integer(E.user_row(erased_user.uid)["anonymized_at"])
      assert retained.() == retained_before, "events, room members, public keys, audit rows and the users row are not the sweep's business"

      assert E.snapshot(active.uid) == active_before, "an active user is byte-identical"
      assert E.profile(active.uid) == active_profile and E.user_row(active.uid) == active_user
      for t <- E.expected_erased(), do: assert(E.count(t, active.uid) >= 1, "the active user still has rows in #{t}")

      # idempotent: the second run is a no-op
      after_first = {E.snapshot(erased_user.uid), E.user_row(erased_user.uid), E.profile(erased_user.uid), E.snapshot(active.uid)}
      run_sweep!(block)
      assert {E.snapshot(erased_user.uid), E.user_row(erased_user.uid), E.profile(erased_user.uid), E.snapshot(active.uid)} == after_first
    end

    test "only deletion_status = keys_deleted is swept: an active, a deactivated and a user in the middle of an erasure keep every row incl. devices", %{cid: cid} do
      block = sweep!(@deploy)
      active = E.seed_user!(cid, "c") |> with_legacy_device!()
      deactivated = E.seed_user!(cid, "d") |> with_legacy_device!()
      in_progress = E.seed_user!(cid, "p") |> with_legacy_device!()
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [deactivated.uid])
      T.sql!("UPDATE users SET deletion_status = 'deletion_in_progress' WHERE user_id = $1", [in_progress.uid])
      erased_user = E.seed_user!(cid, "a") |> with_legacy_device!()
      as_erased_before_the_fix!(erased_user.uid)

      users = [active, deactivated, in_progress]
      before = Map.new(users, &{&1.uid, {E.snapshot(&1.uid), E.fp("devices", &1.uid), E.profile(&1.uid), E.user_row(&1.uid)}})

      run_sweep!(block)

      for u <- users do
        assert {E.snapshot(u.uid), E.fp("devices", u.uid), E.profile(u.uid), E.user_row(u.uid)} == before[u.uid], "a user that is not keys_deleted keeps every row"
        assert E.count("devices", u.uid) >= 1
      end

      assert E.count("devices", erased_user.uid) == 0 and E.count("account_data", erased_user.uid) == 0, "control: the erased user IS swept"
    end

    test "D16 / D17: the sweep NULLs the PII columns and deactivates the erased user; an active user keeps them", %{cid: cid} do
      erased_user = E.seed_user!(cid, "a")
      active = E.seed_user!(cid, "c")
      as_erased_before_the_fix!(erased_user.uid)
      before = E.user_row(erased_user.uid)
      cols = E.users_pii_columns() ++ E.users_free_text_columns()
      assert before["is_active"] == true and Enum.all?(cols, &(before[&1] != nil)), "precondition: an erased-before user is still active and holds every PII column"
      active_pii = Map.take(E.user_row(active.uid), cols)

      for path <- [@deploy, @runbook] do
        run_sweep!(sweep!(path))
        row = E.user_row(erased_user.uid)
        for col <- cols, do: assert(row[col] == nil, "#{Path.relative_to(path, @root)}: users.#{col} is NULL after the sweep")
        assert row["personal_room_id"] == before["personal_room_id"]
        assert row["is_active"] == false and is_integer(row["deactivated_at"]) and is_integer(row["anonymized_at"])
        assert row["deletion_status"] == "keys_deleted" and row["keys_deleted_at"] == before["keys_deleted_at"], "the status columns are untouched"
        assert Map.take(E.user_row(active.uid), cols) == active_pii and E.user_row(active.uid)["is_active"] == true
      end

      assert {:error, :deactivated} = Nebu.Matrix.Session.TokenValidator.validate(erased_user.uid, "user", "x", "x@example.com"), "an admin reactivation cannot revive the swept user"
    end

    test "D18 (a): the sweep deletes the session teardown tables of an erased user (the retry path of a failed teardown), nothing of an active user", %{cid: cid} do
      active = E.seed_user!(cid, "c")
      _ = E.seed_sessions!(active)
      active_before = E.snapshot(active.uid)

      for path <- [@deploy, @runbook] do
        erased_user = E.seed_user!(cid, "a")
        _ = E.seed_sessions!(erased_user)
        as_erased_before_the_fix!(erased_user.uid)
        for t <- E.teardown_tables(), do: assert(E.count(t, erased_user.uid) >= 1, "precondition: the erased user still has rows in #{t} (a failed teardown)")

        run_sweep!(sweep!(path))

        for t <- E.teardown_tables(), do: assert(E.count(t, erased_user.uid) == 0, "#{Path.relative_to(path, @root)}: the sweep left rows in the teardown table #{t}")
        assert E.snapshot(active.uid) == active_before, "an active user's teardown rows are untouched"
      end
    end

    test "the sweep of a database without erased users is a no-op and the runbook copy deletes the same rows", %{cid: cid} do
      active = E.seed_user!(cid, "c")
      before = E.snapshot(active.uid)
      run_sweep!(sweep!(@runbook))
      assert E.snapshot(active.uid) == before

      erased_user = E.seed_user!(cid, "a") |> with_legacy_device!()
      as_erased_before_the_fix!(erased_user.uid)
      run_sweep!(sweep!(@runbook))
      for t <- E.expected_erased(), do: assert(E.count(t, erased_user.uid) == 0, "the runbook sweep left rows in #{t}")
      assert E.count("devices", erased_user.uid) == 0, "the runbook sweep deletes the devices rows too (D13)"
    end
  end
end
