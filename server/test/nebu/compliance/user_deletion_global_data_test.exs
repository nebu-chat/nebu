defmodule Nebu.Compliance.UserDeletionGlobalDataTest do
  @moduledoc """
  Acceptance tests (REAL database, real `Nebu.Repo`, real writers) for story `gdpr-erasure-global-data` (epic oauth-broker, follow-up `ck`,
  REQ-2026-005): Gherkin scenarios 1-6 (the erasure deletes every per-user table of the inventory in one transaction, anonymises the
  profile, serves nothing afterwards, is a no-op the second time, rolls back as a whole, and deactivation keeps the data).

  `async: false`; every test provisions its own users (random ids). Seeding: `Nebu.Compliance.UserDeletionTestSupport.seed_user!/2` (a row in
  every table of the inventory through the real writers where one exists). The REAL `AuditWriter` is switched on (the test config uses the
  no-op writer).

  ## Contract pinned here (see the ATDD report)

    * Entry point: `Nebu.Compliance.UserDeletion.delete_user_keys/3` (unchanged signature and results) and the dispatcher function
      `EventDispatcher.Server.delete_user_keys/2` (response unchanged, sessions ended after the commit).
    * The erasure TRANSACTION deletes every row of the user in the tables of `expected_erased/0` (also the device key rows of a device id that
      has no `devices` row), anonymises `profiles` (`displayname = 'Deleted User'`, `avatar_url = NULL`, an existing row stays) and sets
      `users.anonymized_at`; `users`, `user_keys` (private key NULL), events, room members and audit rows stay.
    * A failing step rolls back EVERYTHING (no `deletion_in_progress`, no row missing, no anonymisation) and writes the
      `user_keys_deletion_attempted` audit row; a retry succeeds.
    * Two erasures racing each other: exactly one `{:ok, _}`, the other `{:error, :conflict}`, one `user_keys_deleted` audit row.
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    {:ok, E.setup_env!()}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  defp dispatcher_erase(uid) do
    req = %Core.DeleteUserKeysRequest{admin_user_id: E.admin(), target_user_id: uid, reason: "atdd erasure"}
    Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, E.admin_stream())
  end

  @scenario_1 ~w(account_data cross_signing_keys device_keys device_one_time_keys device_fallback_keys user_room_account_data)
  @scenario_2 ~w(forgotten_rooms auto_join_opt_outs read_receipts uia_sessions oauth_account_sessions oauth_consent_requests)

  # ═══ Scenario 1 ════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 1 - global data, cross-signing, device keys" do
    test "no row of A remains in account_data, cross_signing_keys, the device key tables and user_room_account_data; B is identical", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")

      for t <- @scenario_1, do: assert(E.count(t, a.uid) >= 1, "precondition: user A has a row in #{t}")
      assert E.count("account_data", a.uid) == 6, "precondition: m.secret_storage.default_key / .key.<id>, m.cross_signing.master, m.push_rules, m.direct, m.ignored_user_list"
      assert E.count("device_keys", a.uid) == 2, "precondition: a device with a devices row and a ghost device without one"
      b_before = E.snapshot(b.uid)

      assert {:ok, %{keys_deleted_at: at}} = erase!(a.uid)
      assert is_integer(at) and at > 0

      for t <- @scenario_1, do: assert(E.count(t, a.uid) == 0, "the erasure left rows of user A in #{t}")
      assert E.snapshot(b.uid) == b_before, "user B's rows are byte-identical to before"
      for t <- @scenario_1, do: assert(E.count(t, b.uid) >= 1, "user B still has rows in #{t}")
    end

    test "device key rows of a device id WITHOUT a devices row are deleted by the transaction itself", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert T.device_state(a.uid, a.ghost) == %{"devices" => 0, "device_keys" => 1, "device_one_time_keys" => 1, "device_fallback_keys" => 1}

      assert {:ok, _} = erase!(a.uid)

      assert T.device_state(a.uid, a.ghost) == %{"devices" => 0, "device_keys" => 0, "device_one_time_keys" => 0, "device_fallback_keys" => 0}
      assert T.device_state(a.uid, a.dev)["device_keys"] == 0, "the device that has a devices row loses its key rows too (the transaction does not wait for the teardown)"
    end

    test "the secret storage canaries of A are in no remaining row of account_data / cross_signing_keys", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert {:ok, _} = erase!(a.uid)
      assert T.sql!("SELECT count(*) FROM account_data WHERE content_json LIKE '%' || $1 || '%'", [a.canary]).rows == [[0]]

      assert T.sql!("SELECT count(*) FROM cross_signing_keys WHERE master_key_json LIKE '%' || $1 || '%' OR user_id = $2", [a.canary, a.uid]).rows == [[0]]
    end
  end

  # ═══ Scenario 2 ════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 2 - other per-user tables, profile" do
    test "forgotten_rooms, auto_join_opt_outs, read_receipts, uia_sessions, account sessions, consent requests: emptied for A, untouched for B", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      for t <- @scenario_2, do: assert(E.count(t, a.uid) >= 1, "precondition: user A has a row in #{t}")
      b_before = E.snapshot(b.uid)

      assert {:ok, _} = erase!(a.uid)

      for t <- @scenario_2, do: assert(E.count(t, a.uid) == 0, "the erasure left rows of user A in #{t}")
      assert E.snapshot(b.uid) == b_before
      for t <- @scenario_2, do: assert(E.count(t, b.uid) >= 1, "user B still has rows in #{t}")
    end

    test "the profile reads 'Deleted User' without an avatar, anonymized_at is set; B's rows are untouched", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      assert E.profile(a.uid) == %{displayname: a.secrets.display, avatar_url: a.secrets.avatar}, "precondition"
      assert E.user_row(a.uid)["anonymized_at"] == nil
      b_profile = E.profile(b.uid)
      b_user = E.user_row(b.uid)
      b_session = T.legacy_session!(b.uid, b.dev)
      profile_path = "/_matrix/client/v3/profile/" <> URI.encode_www_form(a.uid)

      seen = T.matrix_request(:get, profile_path, b_session.at)
      assert seen.status == 200 and T.json(seen)["displayname"] == a.secrets.display, "precondition: B reads A's display name over /profile"

      assert {:ok, %{keys_deleted_at: at}} = erase!(a.uid)

      served = T.matrix_request(:get, profile_path, b_session.at)
      assert served.status == 200, "the /profile of an erased user answers (the row stays)"
      assert T.json(served)["displayname"] == "Deleted User", "/profile of an erased user shows Deleted User"
      refute is_binary(T.json(served)["avatar_url"]), "and no avatar"
      refute served.resp_body =~ a.secrets.display

      assert E.profile(a.uid) == %{displayname: "Deleted User", avatar_url: nil}
      row = E.user_row(a.uid)
      assert is_integer(row["anonymized_at"]) and row["anonymized_at"] > 0, "users.anonymized_at is set"
      assert row["deletion_status"] == "keys_deleted" and row["keys_deleted_at"] == at

      assert E.profile(b.uid) == b_profile
      assert E.user_row(b.uid) == b_user
      assert E.user_row(b.uid)["anonymized_at"] == nil
    end

    test "events, room members, audit rows and the public user_keys rows of A are still present; the users row stays", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert E.events_of(a.uid) == 1 and E.count("room_members", a.uid) == 1
      assert E.audit_count(a.uid, "user_deactivated") == 1
      keys_before = T.sql!("SELECT key_id, key_type, algorithm, public_key FROM user_keys WHERE user_id = $1 ORDER BY key_type", [a.uid]).rows
      assert length(keys_before) == 2

      assert {:ok, _} = erase!(a.uid)

      assert E.events_of(a.uid) == 1, "retained: the events authored by the user (room history preservation)"
      assert T.sql!("SELECT content::text FROM events WHERE event_id = $1", ["$ev-" <> a.canary]).rows != [], "the event is not redacted either"
      assert E.count("room_members", a.uid) == 1
      assert E.audit_count(a.uid, "user_deactivated") == 1, "retained: audit rows"
      assert E.audit_count(a.uid, "user_keys_deleted") == 1
      assert T.sql!("SELECT key_id, key_type, algorithm, public_key FROM user_keys WHERE user_id = $1 ORDER BY key_type", [a.uid]).rows == keys_before, "the public keys stay"
      assert T.sql!("SELECT count(*) FROM user_keys WHERE user_id = $1 AND private_key IS NULL AND deleted_at IS NOT NULL", [a.uid]).rows == [[2]]
      assert E.count("users", a.uid) == 1
    end

    test "a user without a profile row is erased without error and is anonymised", %{cid: _cid} do
      uid = T.provision_user!()
      assert E.profile(uid) == nil, "precondition: no profile row"
      assert {:ok, _} = erase!(uid)
      assert is_integer(E.user_row(uid)["anonymized_at"])
    end
  end

  describe "Scenario 2 - oauth_codes (D11: migration 000055)" do
    test "the authorization codes of A are physically deleted, B's code survives", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      assert E.count("oauth_codes", a.uid) == 1 and E.count("oauth_codes", b.uid) == 1, "precondition"
      b_before = E.fp("oauth_codes", b.uid)

      assert {:ok, _} = erase!(a.uid)

      assert E.count("oauth_codes", a.uid) == 0, "a code carries idp_rt_enc, an IdP refresh token ciphertext: it must be gone"
      assert E.fp("oauth_codes", b.uid) == b_before
    end

    test "with an erased user around, an ACTIVE user's unexpired and used-but-fresh codes stay undeletable (policy correlated)", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      c = E.seed_user!(cid, "c")
      assert {:ok, _} = erase!(a.uid)
      assert E.user_row(a.uid)["deletion_status"] == "keys_deleted", "an erased user exists whatever the test order or the database history"

      # B: an unexpired code and a code that was used a moment ago (reuse detection needs it for 24 h after its expiry)
      used = T.insert_code!(cid, user_id: b.uid, device_id: b.dev, idp_rt: nil)
      assert {:ok, _} = Nebu.OAuth.CodeStore.consume(used.code)
      assert E.count("oauth_codes", b.uid) == 2 and T.sql!("SELECT count(*) FROM oauth_codes WHERE user_id = $1 AND used_at IS NOT NULL", [b.uid]).rows == [[1]]
      before = E.fp("oauth_codes", b.uid)

      assert T.sql!("DELETE FROM oauth_codes WHERE user_id = $1", [b.uid]).num_rows == 0, "an uncorrelated `EXISTS (... deletion_status IS NOT NULL)` would delete these as soon as ANY user is erased"
      assert E.fp("oauth_codes", b.uid) == before

      # the positive mirror: the status the erasure sets BEFORE it deletes opens the branch for that user only
      T.sql!("UPDATE users SET deletion_status = 'deletion_in_progress' WHERE user_id = $1", [c.uid])
      assert T.sql!("DELETE FROM oauth_codes WHERE user_id = $1", [c.uid]).num_rows == 1
      assert E.count("oauth_codes", c.uid) == 0
      assert E.fp("oauth_codes", b.uid) == before, "and still nothing of B"
    end

    test "a pending code of the erased user cannot be redeemed; another user's code can", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      assert {:ok, _} = erase!(a.uid)

      assert {:error, _} = Nebu.OAuth.CodeStore.consume(a.grant.code)
      assert {:ok, %{user_id: uid}} = Nebu.OAuth.CodeStore.consume(b.grant.code)
      assert uid == b.uid
    end
  end

  # ═══ Scenario 3 ════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 3 - nothing is served for an erased user, its sessions are dead" do
    defp keys_query(token, uids),
      do: T.matrix_request(:post, "/_matrix/client/v3/keys/query", token, body: %{"device_keys" => Map.new(uids, &{&1, []})})

    defp key_shape(body, uid),
      do: {get_in(body, ["master_keys", uid]), get_in(body, ["self_signing_keys", uid]), get_in(body, ["user_signing_keys", uid]), get_in(body, ["device_keys", uid]) || %{}}

    defp account_data_path(uid, type), do: "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}"

    test "B's /keys/query shows no keys and no device of A (as for a never-uploaded user); A's token is dead", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      never = T.provision_user!()
      a_session = E.seed_sessions!(a)
      b_session = T.legacy_session!(b.uid, b.dev)

      before = keys_query(b_session.at, [a.uid, never])
      assert before.status == 200
      before_body = T.json(before)
      assert get_in(before_body, ["master_keys", a.uid]) != nil, "precondition: B sees A's master key"
      assert map_size(get_in(before_body, ["device_keys", a.uid]) || %{}) >= 1, "precondition: B sees A's device"
      assert T.whoami(a_session.at).status == 200, "precondition: A's session works"

      assert %Core.DeleteUserKeysResponse{status: "keys_deleted"} = dispatcher_erase(a.uid)

      after_conn = keys_query(b_session.at, [a.uid, never])
      assert after_conn.status == 200
      body = T.json(after_conn)
      assert key_shape(body, a.uid) == key_shape(body, never), "the erased user looks like a user who never uploaded keys"
      refute after_conn.resp_body =~ a.canary, "no cross-signing key object of A is served"

      dead = T.whoami(a_session.at)
      assert dead.status == 401 and T.json(dead)["errcode"] == "M_UNKNOWN_TOKEN", "A's tokens are rejected: 401 M_UNKNOWN_TOKEN"
      get = T.matrix_request(:get, account_data_path(a.uid, "m.direct"), a_session.at)
      assert get.status == 401 and T.json(get)["errcode"] == "M_UNKNOWN_TOKEN"
      other = T.matrix_request(:get, account_data_path(a.uid, "m.direct"), b_session.at)
      assert other.status == 403 and T.json(other)["errcode"] == "M_FORBIDDEN", "another user may not read A's account data (the spec answer)"
      refute other.resp_body =~ a.partner
    end

    # story gdpr-erasure-global-data (D17), old -> new: a session created AFTER the erasure was served by the node's provisioning cache (an earlier request of A had
    # confirmed the user: 404 for `m.direct`). The erasure is terminal for authentication now: the same session is refused (401 M_UNKNOWN_TOKEN, soft logout), and
    # still nothing of A is served. The cache is switched off (TTL 0) so that the test does not depend on a cache entry of the precondition requests.
    test "a session created AFTER the erasure is refused (the erasure is terminal) and serves no account data of A", %{cid: cid} do
      Application.put_env(:nebu_http, :provision_cache_ttl_ms, 0)
      on_exit(fn -> Application.delete_env(:nebu_http, :provision_cache_ttl_ms) end)
      a = E.seed_user!(cid, "a")
      old = T.legacy_session!(a.uid, a.dev)

      before = T.matrix_request(:get, account_data_path(a.uid, "m.direct"), old.at)
      assert before.status == 200 and before.resp_body =~ a.partner, "precondition: A's session reads its m.direct"
      before_sync = T.sync(old.at)
      assert before_sync.status == 200 and before_sync.resp_body =~ a.secrets.default_key, "precondition: A's /sync delivers its account data"

      assert {:ok, _} = erase!(a.uid)
      fresh = T.legacy_session!(a.uid, "CKNEW" <> T.rand(2))

      get = T.matrix_request(:get, account_data_path(a.uid, "m.direct"), fresh.at)
      assert get.status == 401 and T.json(get)["errcode"] == "M_UNKNOWN_TOKEN", "the erased user is not authenticated, got #{get.status}"
      refute get.resp_body =~ a.partner

      sync = T.sync(fresh.at)
      assert sync.status == 401
      for {name, secret} <- Map.take(a.secrets, [:default_key, :ciphertext, :iv, :mac, :rule, :partner, :ignored]), do: refute(sync.resp_body =~ secret, "A's /sync carries #{name} after the erasure")
    end

    test "the dispatcher erasure empties the teardown tables (sessions, tokens) and leaves B's session working", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      _a_session = E.seed_sessions!(a)
      b_session = E.seed_sessions!(b)
      for t <- E.teardown_tables(), do: assert(E.count(t, a.uid) >= 1, "precondition: A has rows in the teardown table #{t}")
      b_before = E.snapshot(b.uid)

      assert %Core.DeleteUserKeysResponse{status: "keys_deleted", keys_deleted_at: at} = dispatcher_erase(a.uid)
      assert is_integer(at) and at > 0

      for t <- E.expected_erased() ++ E.teardown_tables(), do: assert(E.count(t, a.uid) == 0, "after the dispatcher erasure A still has rows in #{t}")
      assert E.snapshot(b.uid) == b_before
      assert T.whoami(b_session.at).status == 200
    end

    test "D12: the dispatcher erasure also removes the devices rows of LEGACY devices (display name, last IP)", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      _ = E.seed_sessions!(a)
      assert T.sql!("SELECT count(*) FROM devices WHERE user_id = $1 AND display_name = $2 AND last_seen_ip = $3", [a.uid, a.secrets.device_name, a.secrets.device_ip]).rows == [[1]], "precondition"
      b_devices = E.fp("devices", b.uid)

      assert %Core.DeleteUserKeysResponse{status: "keys_deleted"} = dispatcher_erase(a.uid)

      assert E.count("devices", a.uid) == 0, "a legacy device row holds a display name and the last IP address: personal data of the erased user"
      assert E.fp("devices", b.uid) == b_devices
    end
  end

  # ═══ Scenario 4 ════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 4 - a second erasure is a no-op" do
    test "UserDeletion answers :conflict, the dispatcher raises already_exists, no row changes, no second success audit row", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      assert {:ok, _} = erase!(a.uid)
      before = {E.snapshot(a.uid), E.user_row(a.uid), E.profile(a.uid), E.snapshot(b.uid), E.audit_rows(a.uid, "user_keys_deleted"), E.events_of(a.uid)}
      assert E.audit_count(a.uid, "user_keys_deleted") == 1

      assert {:error, :conflict} = erase!(a.uid)

      error = assert_raise Nebu.Matrix.Error, fn -> dispatcher_erase(a.uid) end
      assert error.status == Nebu.Matrix.Status.already_exists()

      assert {E.snapshot(a.uid), E.user_row(a.uid), E.profile(a.uid), E.snapshot(b.uid), E.audit_rows(a.uid, "user_keys_deleted"), E.events_of(a.uid)} == before
      assert E.audit_count(a.uid, "user_keys_deleted") == 1, "no second success audit row"
      assert E.audit_count(a.uid, "user_keys_deletion_attempted") == 0, "a conflict is a guard, not a failed attempt"
    end

    test "two erasures racing each other: exactly one {:ok, _}, one {:error, :conflict}, ONE success audit row", %{cid: cid} do
      a = E.seed_user!(cid, "a")

      # a transaction that holds the users row: both erasures read the guard (a plain SELECT), then queue on the conditional UPDATE of step 2
      holder = E.hold(fn -> T.sql!("SELECT 1 FROM users WHERE user_id = $1 FOR UPDATE", [a.uid]) end)
      t1 = Task.async(fn -> erase!(a.uid) end)
      t2 = Task.async(fn -> erase!(a.uid) end)
      E.await_blocked!([t1, t2], holder.backend, "the two erasures")
      E.finish(holder, :rollback)

      results = Enum.sort_by([Task.await(t1, 30_000), Task.await(t2, 30_000)], &elem(&1, 0))

      assert [{:error, :conflict}, {:ok, %{keys_deleted_at: at}}] = results, "the loser of the race must be answered :conflict, got #{inspect(results)}"
      assert is_integer(at)
      assert E.audit_count(a.uid, "user_keys_deleted") == 1, "exactly one success audit row"
      for t <- E.expected_erased(), do: assert(E.count(t, a.uid) == 0, "the race winner left rows in #{t}")
    end
  end

  # ═══ Scenario 5 ════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 5 - a failing step rolls everything back" do
    # every table the transaction deletes from (oauth_codes through the policy of migration 000055, D11), plus the profile anonymisation (an UPDATE)
    faults =
      for t <- ~w(user_room_account_data account_data cross_signing_keys device_keys device_one_time_keys device_fallback_keys
                  forgotten_rooms auto_join_opt_outs read_receipts uia_sessions oauth_account_sessions oauth_consent_requests oauth_codes),
          do: {t, "DELETE"}

    for {table, event} <- faults ++ [{"profiles", "UPDATE"}] do
      test "a failing #{String.downcase(event)} of #{table}: nothing changed, attempted audit written, a retry succeeds", %{cid: cid} do
        table = unquote(table)
        a = E.seed_user!(cid, "a")
        user_before = E.user_row(a.uid)
        before = E.snapshot(a.uid, E.expected_erased() ++ ~w(users profiles user_keys room_members))
        remove = E.block!(table, unquote(event), a.uid)

        assert {:error, _} = erase!(a.uid)

        row = E.user_row(a.uid)
        assert row["deletion_status"] == nil, "the deletion_in_progress marker is rolled back too"
        assert row == user_before, "the users row is unchanged (no anonymized_at, no keys_deleted_at)"
        assert E.snapshot(a.uid, E.expected_erased() ++ ~w(users profiles user_keys room_members)) == before, "every row of user A is still present, the room account data included, the profile not anonymised, the private keys not NULLed"
        assert T.sql!("SELECT count(*) FROM user_keys WHERE user_id = $1 AND private_key IS NOT NULL AND deleted_at IS NULL", [a.uid]).rows == [[2]]

        assert E.audit_count(a.uid, "user_keys_deletion_attempted") == 1, "the failure invariant: an attempted-audit row"
        assert E.audit_count(a.uid, "user_keys_deleted") == 0
        [[actor, outcome, metadata, _detail]] = E.audit_rows(a.uid, "user_keys_deletion_attempted")
        assert actor == E.admin() and outcome == "attempted"
        assert metadata =~ "reason" and metadata =~ "error"

        remove.()
        assert {:ok, %{keys_deleted_at: _}} = erase!(a.uid)
        for t <- E.expected_erased(), do: assert(E.count(t, a.uid) == 0, "after the retry A has rows in #{t}")
        assert E.profile(a.uid) == %{displayname: "Deleted User", avatar_url: nil}
        assert E.audit_count(a.uid, "user_keys_deleted") == 1
      end
    end

    test "a failing step of the DISPATCHER erasure raises internal and ends no session; it succeeds after the fault is removed", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      session = E.seed_sessions!(a)
      remove = E.block!("account_data", "DELETE", a.uid)

      error = assert_raise Nebu.Matrix.Error, fn -> dispatcher_erase(a.uid) end
      assert error.status == Nebu.Matrix.Status.internal()
      assert T.whoami(session.at).status == 200, "the sessions are ended only after a COMMITTED erasure"
      assert E.count("sync_tokens", a.uid) >= 1

      remove.()
      assert %Core.DeleteUserKeysResponse{status: "keys_deleted"} = dispatcher_erase(a.uid)
      assert T.whoami(session.at).status == 401
    end
  end

  describe "D12 - the legacy device teardown is best effort, after the commit" do
    test "a failing legacy-device teardown leaves the erasure committed, the answer keys_deleted, other sessions ended", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      session = E.seed_sessions!(a)
      remove = E.block!("devices", "DELETE", a.uid)

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:response, dispatcher_erase(a.uid)}) end)

      assert_received {:response, %Core.DeleteUserKeysResponse{status: "keys_deleted", keys_deleted_at: at}}
      assert is_integer(at)
      assert E.user_row(a.uid)["deletion_status"] == "keys_deleted", "the transaction stays committed"
      for t <- E.expected_erased(), do: assert(E.count(t, a.uid) == 0, "the failing teardown did not undo the erasure: rows left in #{t}")
      for t <- ~w(matrix_sessions sessions sync_tokens), do: assert(E.count(t, a.uid) == 0, "the other teardown steps still ran: rows left in #{t}")
      assert T.whoami(session.at).status == 401, "the legacy session is ended"
      assert E.count("devices", a.uid) >= 1, "precondition of the fault: the device row is the one thing left"
      for {name, secret} <- Map.take(a.secrets, [:device_name, :device_ip, :display]) |> Map.put(:at, session.at), do: refute(log =~ secret, "the teardown warning carries #{name}")

      remove.()
      assert E.audit_count(a.uid, "user_keys_deleted") == 1
    end
  end

  # ═══ Scenario 6 ════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 6 - deactivation without erasure keeps the data" do
    test "account data, cross-signing keys, device keys and room account data survive deactivation and reactivation", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      tables = @scenario_1 ++ ["profiles"]
      before = E.snapshot(a.uid, tables)
      assert E.count("account_data", a.uid) == 6

      assert %Core.DeactivateUserResponse{ok: true} =
               Nebu.Matrix.EventDispatcher.Server.deactivate_user(%Core.DeactivateUserRequest{user_id: a.uid}, E.admin_stream())

      assert E.snapshot(a.uid, tables) == before, "deactivation deletes none of these rows"
      assert E.user_row(a.uid)["deletion_status"] == nil and E.user_row(a.uid)["anonymized_at"] == nil

      assert %Core.ReactivateUserResponse{ok: true} =
               Nebu.Matrix.EventDispatcher.Server.reactivate_user(%Core.ReactivateUserRequest{user_id: a.uid}, E.admin_stream())

      assert E.snapshot(a.uid, tables) == before, "still there after reactivation"
      assert E.profile(a.uid) == %{displayname: a.secrets.display, avatar_url: a.secrets.avatar}
    end
  end
end
