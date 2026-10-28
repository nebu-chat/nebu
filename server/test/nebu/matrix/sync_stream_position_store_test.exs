defmodule Nebu.Matrix.SyncStreamPositionStoreTest do
  @moduledoc """
  Store-level acceptance tests for story `sync-stream-position` (epic oauth-broker, follow-up `fc`, story 2 of 2): the session store half of D3 (the cascade), D8 (the base of the
  global positions: `get_positions(user, device, core_token)`, "the HTTP layer passes the client's core token to `get_positions`") and the interplay with the earlier story's
  `get_positions/2`. The real `Nebu.Matrix.Session.PgStore` and `Nebu.Repo`, rows through SQL strings; `async: false`.

  ## Contract choices of the ATDD step

    * `PgStore.get_positions(user_id, device_id, core_token)` (named by the story) -> the bare tuple `{account_data_pos, cross_signing_pos}` of the generation the token names: the row's
      CURRENT positions for its current `since_token`, `prev_account_data_pos` / `prev_cross_signing_pos` for its `prev_since_token`. It is called through `apply/3` (the function is
      new: a missing one is a runtime failure of the test, never a compile warning under `--warnings-as-errors`). The positions of an UNKNOWN token are not pinned (that request is an
      initial-shaped fallback, which delivers everything whatever the positions are).
    * `PgStore.get_positions/2` keeps answering the current positions (sync-token-per-device's tests rely on it).
    * The persist step itself is covered where it is observable: the cursor / token rows in the HTTP, dispatcher and concurrency suites. Its function names are not pinned.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.Session.PgStore
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  defp positions(user, device, token), do: apply(PgStore, :get_positions, [user, device, token])

  defp token_row!(uid, dev, fields) do
    f = Map.merge(%{since: "s2_cur", prev: nil, ad: 0, cs: 0, prev_ad: nil, prev_cs: nil, gen: 3}, Map.new(fields))

    T.sql!(
      "INSERT INTO sync_tokens (user_id, device_id, since_token, updated_at, account_data_pos, cross_signing_pos, stream_version, generation, prev_since_token, prev_account_data_pos, prev_cross_signing_pos) VALUES ($1, $2, $3, $4, $5, $6, 1, $7, $8, $9, $10)",
      [uid, dev, f.since, System.system_time(:millisecond), f.ad, f.cs, f.gen, f.prev, f.prev_ad, f.prev_cs]
    )

    on_exit(fn -> T.sql!("DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, dev]) end)
  end

  describe "get_positions/3 (D8)" do
    test "the current token reads the current positions, the previous token the previous generation's" do
      uid = T.provision_user!()
      token_row!(uid, "D1", since: "s2_cur", prev: "s2_prev", ad: 10, cs: 20, prev_ad: 7, prev_cs: 8)

      assert positions(uid, "D1", "s2_cur") == {10, 20}
      assert positions(uid, "D1", "s2_prev") == {7, 8}
    end

    test "the two columns are independent per generation (account data advanced, cross-signing not, and the reverse)" do
      uid = T.provision_user!()
      token_row!(uid, "D1", since: "s2_c", prev: "s2_p", ad: 50, cs: 3, prev_ad: 5, prev_cs: 3)
      token_row!(uid, "D2", since: "s2_c2", prev: "s2_p2", ad: 5, cs: 30, prev_ad: 5, prev_cs: 2)

      assert positions(uid, "D1", "s2_c") == {50, 3} and positions(uid, "D1", "s2_p") == {5, 3}
      assert positions(uid, "D2", "s2_c2") == {5, 30} and positions(uid, "D2", "s2_p2") == {5, 2}
    end

    test "the lookup key is the caller's: another device's or another user's previous token reads nothing of this row" do
      {u1, u2} = {T.provision_user!(), T.provision_user!()}
      token_row!(u1, "D1", since: "s2_cur1", prev: "s2_prev1", ad: 11, cs: 12, prev_ad: 1, prev_cs: 2)
      token_row!(u1, "D2", since: "s2_cur2", prev: "s2_prev2", ad: 21, cs: 22, prev_ad: 3, prev_cs: 4)
      token_row!(u2, "D1", since: "s2_curX", prev: "s2_prevX", ad: 31, cs: 32, prev_ad: 5, prev_cs: 6)

      assert positions(u1, "D1", "s2_prev1") == {1, 2}
      refute positions(u1, "D1", "s2_prev2") == {3, 4}, "the previous token of device D2 is not the previous token of D1"
      refute positions(u1, "D1", "s2_prevX") == {5, 6}, "another user's previous token neither"
      refute positions(u2, "D1", "s2_prev1") == {1, 2}
    end

    test "a user without a row reads {0, 0}: everything is delivered again, never missed; it never raises" do
      uid = T.provision_user!()
      assert positions(uid, "NOPE", "s2_anything") == {0, 0}
      assert positions(uid, "", nil) == {0, 0}
    end

    test "get_positions/2 still answers the current positions (the earlier story's contract)" do
      uid = T.provision_user!()
      token_row!(uid, "D1", since: "s2_cur", prev: "s2_prev", ad: 10, cs: 20, prev_ad: 7, prev_cs: 8)
      assert PgStore.get_positions(uid, "D1") == {10, 20}
    end

    test "reading is not writing: the row is byte-identical after both reads" do
      uid = T.provision_user!()
      token_row!(uid, "D1", since: "s2_cur", prev: "s2_prev", ad: 10, cs: 20, prev_ad: 7, prev_cs: 8)
      before = T.sql!("SELECT to_jsonb(t)::text FROM sync_tokens t WHERE user_id = $1", [uid]).rows
      positions(uid, "D1", "s2_cur")
      positions(uid, "D1", "s2_prev")
      assert T.sql!("SELECT to_jsonb(t)::text FROM sync_tokens t WHERE user_id = $1", [uid]).rows == before
    end
  end

  # ═══ the cascade (D3): every teardown path that deletes the token row removes the cursors ══════════════════════════════════════

  defp device!(uid, prefix) do
    dev = prefix <> String.upcase(T.rand(3))
    %{uid: uid, dev: dev, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}
  end

  defp cursor_count(uid), do: T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  defp cursor_rows(uid), do: T.sql!("SELECT to_jsonb(c)::text FROM sync_room_cursors c WHERE user_id = $1 ORDER BY device_id, room_id", [uid]).rows

  # a user with devices A and B (cursors for both) and a stranger with one device and cursors
  defp world! do
    uid = T.provision_user!()
    a = device!(uid, "SSA")
    b = device!(uid, "SSB")
    o = S.user!("SSO")
    room = S.invite_room(o, [a])
    anchor = S.anchor_room!(a)
    ta = S.snapshot!(a, anchor)
    tb = S.snapshot!(b, anchor)

    stranger = S.user!("SSS")
    S.make_room(stranger, %{})
    S.sync(stranger)

    assert cursor_count(uid) >= 4, "precondition: both devices have cursor rows"
    assert cursor_count(stranger.uid) >= 1
    %{uid: uid, a: a, b: b, o: o, room: room, ta: ta, tb: tb, stranger: stranger, stranger_rows: cursor_rows(stranger.uid)}
  end

  describe "cascade (D3)" do
    test "DELETE /devices/{A} removes A's cursors only; POST /delete_devices removes the rest" do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      w = world!()
      b_before = T.sql!("SELECT to_jsonb(c)::text FROM sync_room_cursors c WHERE user_id = $1 AND device_id = $2 ORDER BY room_id", [w.uid, w.b.dev]).rows

      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> w.a.dev, w.b.at, body: %{}).status == 200
      assert T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2", [w.uid, w.a.dev]).rows == [[0]]
      assert T.sql!("SELECT to_jsonb(c)::text FROM sync_room_cursors c WHERE user_id = $1 AND device_id = $2 ORDER BY room_id", [w.uid, w.b.dev]).rows == b_before, "B's cursors are untouched"
      assert cursor_rows(w.stranger.uid) == w.stranger_rows
    end

    test "POST /logout/all removes every cursor of the user and leaves the stranger's" do
      w = world!()
      assert T.matrix_request(:post, "/_matrix/client/v3/logout/all", w.b.at, body: %{}).status == 200
      assert cursor_count(w.uid) == 0
      assert cursor_rows(w.stranger.uid) == w.stranger_rows
    end

    test "the GDPR erasure (DeleteUserKeys) removes every cursor of the user and leaves the stranger's" do
      w = world!()
      admin = %{http_request_headers: %{"x-user-id" => "@admin:test.local", "x-system-role" => "admin"}}
      req = %Core.DeleteUserKeysRequest{admin_user_id: "@admin:test.local", target_user_id: w.uid, reason: "atdd erasure"}
      assert %Core.DeleteUserKeysResponse{status: "keys_deleted"} = Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, admin)

      assert cursor_count(w.uid) == 0
      assert cursor_rows(w.stranger.uid) == w.stranger_rows
    end

    test "an admin deactivation removes every cursor of the user and leaves the stranger's" do
      w = world!()
      admin = %{http_request_headers: %{"x-user-id" => "@admin:test.local", "x-system-role" => "admin"}}
      assert %Core.DeactivateUserResponse{ok: true} = Nebu.Matrix.EventDispatcher.Server.deactivate_user(%Core.DeactivateUserRequest{user_id: w.uid}, admin)

      assert cursor_count(w.uid) == 0
      assert cursor_rows(w.stranger.uid) == w.stranger_rows
    end

    test "the legacy per-device logout (POST /logout of one device) removes that device's cursors and keeps the other device's" do
      w = world!()
      assert T.matrix_request(:post, "/_matrix/client/v3/logout", w.a.at).status == 200
      assert T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2", [w.uid, w.a.dev]).rows == [[0]]
      assert T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2", [w.uid, w.b.dev]).rows != [[0]]
      assert cursor_rows(w.stranger.uid) == w.stranger_rows
    end
  end
end
