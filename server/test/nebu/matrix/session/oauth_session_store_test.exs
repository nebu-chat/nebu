defmodule Nebu.Matrix.Session.OAuthSessionStoreTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint` (story 3 of epic oauth-broker),
  MATRIX side (T1, T2-T5, T7, T10, T11, T19, T27; AC7, AC9 rotation semantics): the new
  `Nebu.Matrix` facade functions (ADR-020) backed by `Nebu.Matrix.OAuthSession` and
  `Nebu.Matrix.Session.OAuthSessionStore` (inline SQL on `matrix_sessions`, `auth_api = 'oauth'`).

  Pinned shapes (all called via `apply/3`, the modules do not exist yet => red with
  `UndefinedFunctionError`):

    * `Nebu.Matrix.oauth_issue_session(attrs)` => `{:ok, %{access_token:, refresh_token:, expires_in:,
      user_id:, device_id:, scope:, auth_time:}} | {:error, :inactive} | {:error, :unavailable}`
    * `Nebu.Matrix.oauth_resolve_refresh_token(rt)` => `{:ok, session, :current | :replay} |
      {:reused, session} | :error | {:error, :unavailable}`
    * `Nebu.Matrix.oauth_refresh_session(session, mode, rt, %{scope:, idp_revalidation:,
      access_ttl_seconds:})` => `{:ok, %{access_token:, refresh_token:, expires_in:, scope:, user_id:,
      device_id:, auth_time:}} | {:error, :invalid_grant} | {:error, {:unavailable, secs}}`
    * `Nebu.Matrix.oauth_revoke_device_session/2`, `Nebu.Matrix.oauth_revoke_sessions_for_code/1`
    * `Nebu.Matrix.OAuthSession.user_active/1` => `{:ok, boolean} | {:error, term}` (T19)

  Seams: `:nebu_http, :oauth_session_repo` (NoSuchRepo => `:unavailable`),
  `:nebu_http, :oauth_user_active_override` (1-arity).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  setup do
    _priv = T.setup_idp!()

    on_exit(fn ->
      for k <- [:oauth_session_repo, :oauth_user_active_override], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, cid: T.oauth_client!(["https://app.example.com/cb"])}
  end

  defp dev, do: "DEV" <> String.upcase(T.rand(4))
  defp m(fun, args), do: apply(Nebu.Matrix, fun, args)

  defp attrs(cid, uid, device_id, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: uid,
        device_id: device_id,
        client_id: cid,
        scope: T.matrix_scope(T.stable_prefix(), device_id),
        oauth_code_hash: T.sha256_hex("code-" <> T.rand(8)),
        idp_rt_enc: Nebu.Web.SecretBox.encrypt("idp-rt-" <> T.rand(6)),
        auth_time: System.system_time(:second) - 30,
        access_ttl_seconds: 900
      },
      overrides
    )
  end

  defp issue!(a) do
    assert {:ok, out} = m(:oauth_issue_session, [a])
    out
  end

  defp session_for(rt) do
    assert {:ok, session, :current} = m(:oauth_resolve_refresh_token, [rt])
    session
  end

  defp refresh_opts(o \\ %{}), do: Map.merge(%{scope: nil, idp_revalidation: :off, access_ttl_seconds: 900}, o)

  describe "AC7 — oauth_issue_session/1" do
    test "returns the token pair and the session facts; one oauth row with hashes only", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      a = attrs(cid, uid, d)
      out = issue!(a)

      assert out.access_token =~ ~r/\A[0-9a-f]{64}\z/
      assert out.refresh_token =~ ~r/\A[0-9a-f]{64}\z/
      assert out.user_id == uid and out.device_id == d
      assert out.scope == a.scope
      assert out.auth_time == a.auth_time
      assert is_integer(out.expires_in) and out.expires_in >= 1 and out.expires_in <= 900

      assert [row] = T.session_rows(uid, d)
      assert row["auth_api"] == "oauth"
      assert row["client_id"] == cid
      assert row["scope"] == a.scope
      assert row["oauth_code_hash"] == a.oauth_code_hash
      assert row["oidc_refresh_token"] == a.idp_rt_enc, "the IdP RT ciphertext is stored verbatim (T5), never decrypted"
      assert row["auth_time"] == a.auth_time
      assert row["access_token_hash"] == T.token_hash(out.access_token)
      assert row["refresh_token_hash"] == T.token_hash(out.refresh_token)
      for {col, v} <- row, is_binary(v), do: refute(v in [out.access_token, out.refresh_token], "plaintext token in #{col}")

      assert DateTime.compare(row["expires_at"], row["session_expires_at"]) != :gt
      ttl = Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      session_secs = DateTime.diff(row["session_expires_at"], row["created_at"])
      assert session_secs in (ttl - 1)..ttl, "session_expires_at = created_at + NEBU_MATRIX_SESSION_TTL_SECONDS (T3)"
      at_secs = DateTime.diff(row["expires_at"], row["created_at"])
      assert at_secs in 899..900, "expires_at = now() + 900 s (T4)"
      assert out.expires_in <= at_secs, "T33: expires_in never exceeds the stored lifetime"
    end

    test "access_ttl_seconds is honoured and capped by the session maximum (LEAST, T3)", %{cid: cid} do
      T.put_env_scoped(:matrix_session_ttl_seconds, 120)
      uid = T.provision_user!()
      d = dev()
      out = issue!(attrs(cid, uid, d, %{access_ttl_seconds: 900}))
      assert out.expires_in <= 120
      [row] = T.session_rows(uid, d)
      assert DateTime.compare(row["expires_at"], row["session_expires_at"]) != :gt
    end

    test "the devices row exists afterwards (listed by /devices), without a display name for a new device", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      _ = issue!(attrs(cid, uid, d))
      assert %{rows: [[nil]]} = T.sql!("SELECT display_name FROM devices WHERE user_id = $1 AND device_id = $2", [uid, d])
    end

    test "deactivated user => {:error, :inactive}, no row", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [uid])
      assert m(:oauth_issue_session, [attrs(cid, uid, d)]) == {:error, :inactive}
      assert T.session_rows(uid, d) == []
    end

    test "unknown user => {:error, :inactive}", %{cid: cid} do
      uid = T.user_id_for(%{"sub" => T.unique_sub()})
      assert m(:oauth_issue_session, [attrs(cid, uid, dev())]) == {:error, :inactive}
    end

    test "T19: an is_active read ERROR => {:error, :unavailable} (never :inactive)", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      Application.put_env(:nebu_http, :oauth_user_active_override, fn _ -> {:error, :db} end)
      assert m(:oauth_issue_session, [attrs(cid, uid, d)]) == {:error, :unavailable}
      assert T.session_rows(uid, d) == []
    end

    test "repo unavailable => {:error, :unavailable}; never raises", %{cid: cid} do
      uid = T.provision_user!()
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      assert m(:oauth_issue_session, [attrs(cid, uid, dev())]) == {:error, :unavailable}
    end

    test "T7: every earlier row of the device (legacy AND oauth) is deleted in the same step; devices row and keys kept", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      legacy = T.legacy_session!(uid, d)
      first = issue!(attrs(cid, uid, d))
      Nebu.Matrix.DeviceKeyStore.put_device_keys(uid, d, %{"user_id" => uid, "device_id" => d, "algorithms" => [], "keys" => %{}})

      second = issue!(attrs(cid, uid, d))

      hashes = uid |> T.session_rows(d) |> Enum.map(& &1["access_token_hash"])
      assert hashes == [T.token_hash(second.access_token)]
      refute T.token_hash(first.access_token) in hashes
      refute T.token_hash(legacy.at) in hashes
      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM devices WHERE user_id = $1 AND device_id = $2", [uid, d])
      assert %{rows: [[1]]} = T.sql!("SELECT count(*) FROM device_keys WHERE user_id = $1 AND device_id = $2", [uid, d])
    end

    test "another user's device with the same id is untouched", %{cid: cid} do
      d = dev()
      other = T.provision_user!()
      other_legacy = T.legacy_session!(other, d)
      _ = issue!(attrs(cid, T.provision_user!(), d))
      assert [_] = T.session_rows(other, d)
      assert T.row_by_at(other_legacy.at)
    end
  end

  describe "T19 — Nebu.Matrix.OAuthSession.user_active/1 is error-aware" do
    test "active => {:ok, true}; deactivated => {:ok, false}; unknown => {:ok, false}; DB error => {:error, _}" do
      uid = T.provision_user!()
      assert apply(Nebu.Matrix.OAuthSession, :user_active, [uid]) == {:ok, true}
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [uid])
      assert apply(Nebu.Matrix.OAuthSession, :user_active, [uid]) == {:ok, false}
      assert apply(Nebu.Matrix.OAuthSession, :user_active, ["@nobody-" <> T.rand() <> ":test.local"]) == {:ok, false}
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      assert {:error, _} = apply(Nebu.Matrix.OAuthSession, :user_active, [uid])
    end
  end

  describe "AC9/T10/T11 — oauth_resolve_refresh_token/1 and oauth_refresh_session/4" do
    test ":current with the session facts", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      a = attrs(cid, uid, d)
      out = issue!(a)
      session = session_for(out.refresh_token)
      assert session.user_id == uid and session.device_id == d and session.client_id == cid
      assert session.scope == a.scope
      assert session.auth_time == a.auth_time
      assert %DateTime{} = session.session_expires_at
    end

    test "rotation (off mode): new pair, old AT superseded, session_expires_at/auth_time/oauth_code_hash copied verbatim", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      a = attrs(cid, uid, d)
      out = issue!(a)
      [first_row] = T.session_rows(uid, d)

      assert {:ok, r} = m(:oauth_refresh_session, [session_for(out.refresh_token), :current, out.refresh_token, refresh_opts()])
      assert r.access_token != out.access_token and r.refresh_token != out.refresh_token
      assert r.scope == a.scope and r.user_id == uid and r.device_id == d and r.auth_time == a.auth_time

      [active] = T.active_rows(uid, d)
      assert active["access_token_hash"] == T.token_hash(r.access_token)
      assert active["session_expires_at"] == first_row["session_expires_at"], "never extended (T3)"
      assert active["oauth_code_hash"] == a.oauth_code_hash, "copied on rotation (T8)"
      assert active["auth_time"] == a.auth_time
      assert active["client_id"] == cid and active["auth_api"] == "oauth"
      old = T.row_by_at(out.access_token)
      assert old["revoked_at"] != nil and old["grace_until"] == nil, "old row PENDING (T10)"
    end

    test "the pending old RT resolves as :replay (serving the ACTIVE row); after consumption it is {:reused, _}", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      out = issue!(attrs(cid, uid, d))
      {:ok, r} = m(:oauth_refresh_session, [session_for(out.refresh_token), :current, out.refresh_token, refresh_opts()])

      assert {:ok, replay_session, :replay} = m(:oauth_resolve_refresh_token, [out.refresh_token])
      assert replay_session.device_id == d

      # the new RT is redeemed => the pending old RT is consumed (consume_pending_siblings)
      {:ok, _r2} = m(:oauth_refresh_session, [session_for(r.refresh_token), :current, r.refresh_token, refresh_opts()])
      assert {:reused, reused} = m(:oauth_resolve_refresh_token, [out.refresh_token])
      assert reused.user_id == uid and reused.device_id == d and reused.client_id == cid
    end

    test "unknown token and a LEGACY refresh token => :error (T27)" do
      uid = T.provision_user!()
      legacy = T.legacy_session!(uid, dev())
      assert m(:oauth_resolve_refresh_token, [Nebu.Matrix.Session.MatrixSessionStore.generate_opaque_token()]) == :error
      assert m(:oauth_resolve_refresh_token, [legacy.rt]) == :error
    end

    test "repo unavailable => {:error, :unavailable}", %{cid: cid} do
      out = issue!(attrs(cid, T.provision_user!(), dev()))
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      assert m(:oauth_resolve_refresh_token, [out.refresh_token]) == {:error, :unavailable}
    end

    test "off mode, deactivated user => {:error, :invalid_grant} and the session is revoked", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      out = issue!(attrs(cid, uid, d))
      session = session_for(out.refresh_token)
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [uid])
      assert m(:oauth_refresh_session, [session, :current, out.refresh_token, refresh_opts()]) == {:error, :invalid_grant}
      assert T.session_rows(uid, d) == []
    end

    test "off mode, is_active read error => {:error, {:unavailable, secs}}, session untouched", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      out = issue!(attrs(cid, uid, d))
      session = session_for(out.refresh_token)
      before = T.rows_snapshot(uid, d)
      Application.put_env(:nebu_http, :oauth_user_active_override, fn _ -> {:error, :db} end)
      assert {:error, {:unavailable, secs}} = m(:oauth_refresh_session, [session, :current, out.refresh_token, refresh_opts()])
      assert is_integer(secs) and secs > 0
      assert T.rows_snapshot(uid, d) == before
    end

    test "per_refresh: a provider-rotated IdP RT is stored encrypted on the NEW row", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      out = issue!(attrs(cid, uid, d))
      T.stub_idp_refresh(fn _rt -> {:ok, %{"sub" => "x", "exp" => System.system_time(:second) + 3600}, "rotated-idp-rt-new"} end)

      {:ok, r} =
        m(:oauth_refresh_session, [session_for(out.refresh_token), :current, out.refresh_token, refresh_opts(%{idp_revalidation: :per_refresh})])

      enc = T.row_by_at(r.access_token)["oidc_refresh_token"]
      refute enc == "rotated-idp-rt-new"
      assert Nebu.Web.SecretBox.decrypt(enc) == {:ok, "rotated-idp-rt-new"}
    end
  end

  describe "T10 — review cycle 1 (MINOR 2): a rotation serializes with device issuance (devices-row lock)" do
    test "the rotation waits for a concurrent issuance holding the devices row; when that issuance deleted the rows the rotation fails closed",
         %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      out = issue!(attrs(cid, uid, d))
      session = session_for(out.refresh_token)

      task =
        Nebu.Repo.transaction(fn ->
          # what `insert_replacing_device/1` does first: take the devices row, then delete the device's rows
          Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [uid, d])
          Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2", [uid, d])

          task = Task.async(fn -> m(:oauth_refresh_session, [session, :current, out.refresh_token, refresh_opts()]) end)
          assert Task.yield(task, 500) == nil, "the rotation must wait for the devices row lock of the concurrent issuance"
          task
        end)
        |> then(fn {:ok, task} -> task end)

      assert {:ok, {:error, :invalid_grant}} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
      assert T.session_rows(uid, d) == [], "no surviving active row of the rotation after the re-login deleted the device's rows"
    end
  end

  describe "AC6/T11 — revocation helpers" do
    test "oauth_revoke_device_session/2 deletes only the auth_api='oauth' rows of that device", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      other = dev()
      _ = issue!(attrs(cid, uid, d))
      keep = issue!(attrs(cid, uid, other))
      _ = m(:oauth_revoke_device_session, [uid, d])
      assert T.session_rows(uid, d) == []
      assert T.row_by_at(keep.access_token)
    end

    test "oauth_revoke_sessions_for_code/1 deletes exactly the device carrying that code hash (also after a rotation)", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      other = dev()
      a = attrs(cid, uid, d)
      out = issue!(a)
      {:ok, _} = m(:oauth_refresh_session, [session_for(out.refresh_token), :current, out.refresh_token, refresh_opts()])
      keep = issue!(attrs(cid, uid, other))

      _ = m(:oauth_revoke_sessions_for_code, [a.oauth_code_hash])
      assert T.session_rows(uid, d) == [], "every row of the derived device, incl. the rotated ones"
      assert T.row_by_at(keep.access_token), "a session derived from another code survives"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story 4 (oauth-token-revocation-logout): AC5 / R11 store + OAuthSession functions (RED)
  #
  # Pinned (ATDD Decisions story 4, via apply/3):
  #   OAuthSessionStore.end_session_for_token(plaintext) :: {:ok, :revoked, %{user_id:, device_id:, client_id:}}
  #                                                        | {:ok, :unknown} | {:error, term}
  #   OAuthSessionStore.end_device(user_id, device_id)    :: :ok | {:error, term}
  #   OAuthSessionStore.oauth_device_ids(user_id)         :: {:ok, [device_id]} | {:error, term}
  #   OAuthSession.end_device_session(user_id, device_id) :: :ok | {:error, :unavailable}
  #   OAuthSession.end_all_for_user(user_id)              :: {:ok, [device_id]} | {:error, :unavailable}
  #   DeviceKeyStore.delete_device!(user_id, device_id)   :: :ok (raises on a DB error)
  # ════════════════════════════════════════════════════════════════════════════

  defp store(fun, args), do: apply(Nebu.Matrix.Session.OAuthSessionStore, fun, args)
  defp osess(fun, args), do: apply(Nebu.Matrix.OAuthSession, fun, args)

  defp seed_keys!(uid, d), do: T.seed_device_keys!(uid, d)

  describe "story 4 AC5/R3/R11 — OAuthSessionStore.end_session_for_token/1 (one transaction, either token, any state)" do
    test "active AT and active RT: {:ok, :revoked, info}; all rows + device + keys gone", %{cid: cid} do
      for kind <- [:access_token, :refresh_token] do
        uid = T.provision_user!()
        d = dev()
        out = issue!(attrs(cid, uid, d))
        seed_keys!(uid, d)
        assert store(:end_session_for_token, [Map.fetch!(out, kind)]) == {:ok, :revoked, %{user_id: uid, device_id: d, client_id: cid}}
        assert T.session_rows(uid, d) == []
        assert T.device_gone?(uid, d), "device tables deleted INSIDE the transaction (Trap 3)"
      end
    end

    test "superseded AT, pending RT and consumed RT all end the session incl. the newest row", %{cid: cid} do
      for which <- [:superseded_at, :pending_rt, :consumed_rt] do
        uid = T.provision_user!()
        d = dev()
        out = issue!(attrs(cid, uid, d))
        {:ok, r} = m(:oauth_refresh_session, [session_for(out.refresh_token), :current, out.refresh_token, refresh_opts()])

        token =
          case which do
            :superseded_at -> out.access_token
            :pending_rt -> out.refresh_token
            :consumed_rt ->
              {:ok, _} = m(:oauth_refresh_session, [session_for(r.refresh_token), :current, r.refresh_token, refresh_opts()])
              out.refresh_token
          end

        assert {:ok, :revoked, %{device_id: ^d}} = store(:end_session_for_token, [token])
        assert T.session_rows(uid, d) == [], "#{which}: every row of the device"
      end
    end

    test "an expired AT and a token of an expired session are still found (no state filter)", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      out = issue!(attrs(cid, uid, d))
      T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '2 seconds', session_expires_at = now() - interval '1 second' WHERE user_id = $1 AND device_id = $2", [uid, d])
      assert {:ok, :revoked, _} = store(:end_session_for_token, [out.access_token])
      assert T.session_rows(uid, d) == []
    end

    test "unknown, legacy AT, legacy RT => {:ok, :unknown}, nothing touched", %{cid: _cid} do
      uid = T.provision_user!()
      d = dev()
      legacy = T.legacy_session!(uid, d)
      seed_keys!(uid, d)
      before = T.world_snapshot([uid])

      for t <- [T.rand(32), legacy.at, legacy.rt], do: assert(store(:end_session_for_token, [t]) == {:ok, :unknown})
      assert T.world_snapshot([uid]) == before
    end

    test "the second call for the same session is {:ok, :unknown} (idempotent)", %{cid: cid} do
      uid = T.provision_user!()
      out = issue!(attrs(cid, uid, dev()))
      assert {:ok, :revoked, _} = store(:end_session_for_token, [out.refresh_token])
      assert store(:end_session_for_token, [out.access_token]) == {:ok, :unknown}
    end

    test "NoSuchRepo => {:error, _}, never raises", %{cid: cid} do
      out = issue!(attrs(cid, T.provision_user!(), dev()))
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      assert {:error, _} = store(:end_session_for_token, [out.access_token])
    end

    test "Trap 2: re-check after the lock — a re-login that replaced the rows while we waited wins", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      old = issue!(attrs(cid, uid, d))

      {:ok, {task, fresh}} =
        Nebu.Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [uid, d])
          task = Task.async(fn -> T.safely(fn -> store(:end_session_for_token, [old.access_token]) end) end)
          T.await_lock_wait!()
          assert Task.yield(task, 0) == nil, "end_session_for_token must wait for the devices row lock"
          # what insert_replacing_device/1 does after its lock (same connection = same transaction)
          fresh = issue!(attrs(cid, uid, d))
          {task, fresh}
        end)

      assert {:ok, {:ok, :unknown}} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
      assert [row] = T.session_rows(uid, d)
      assert row["access_token_hash"] == T.token_hash(fresh.access_token)
    end
  end

  describe "story 4 AC5 — end_device/2, oauth_device_ids/1, OAuthSession.end_device_session/2 + end_all_for_user/1" do
    test "oauth_device_ids/1 lists the distinct OAuth devices of the user only", %{cid: cid} do
      uid = T.provision_user!()
      d1 = dev()
      d2 = dev()
      _ = issue!(attrs(cid, uid, d1))
      out = issue!(attrs(cid, uid, d2))
      {:ok, _} = m(:oauth_refresh_session, [session_for(out.refresh_token), :current, out.refresh_token, refresh_opts()])
      _legacy = T.legacy_session!(uid, dev())
      _other_user = issue!(attrs(cid, T.provision_user!(), dev()))

      assert {:ok, ids} = store(:oauth_device_ids, [uid])
      assert Enum.sort(ids) == Enum.sort([d1, d2])
    end

    test "end_device/2 deletes every row of the device (any auth_api) + device tables; other devices untouched", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      keep_d = dev()
      _ = issue!(attrs(cid, uid, d))
      keep = issue!(attrs(cid, uid, keep_d))
      seed_keys!(uid, d)
      seed_keys!(uid, keep_d)

      assert store(:end_device, [uid, d]) == :ok
      assert T.session_rows(uid, d) == []
      assert T.device_gone?(uid, d)
      assert T.row_by_at(keep.access_token)
      refute T.device_gone?(uid, keep_d)
    end

    test "OAuthSession.end_device_session/2 => :ok; end_all_for_user/1 => {:ok, ids}; NoSuchRepo => {:error, :unavailable}", %{cid: cid} do
      uid = T.provision_user!()
      d1 = dev()
      d2 = dev()
      _ = issue!(attrs(cid, uid, d1))
      _ = issue!(attrs(cid, uid, d2))

      assert osess(:end_device_session, [uid, d1]) == :ok
      assert {:ok, [^d2]} = osess(:end_all_for_user, [uid])
      assert osess(:end_all_for_user, [uid]) == {:ok, []}

      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      assert osess(:end_device_session, [uid, d1]) == {:error, :unavailable}
      assert osess(:end_all_for_user, [uid]) == {:error, :unavailable}
    end

    test "end_device_session/2 also runs the JWT kill-switch for the device", %{cid: cid} do
      priv = T.setup_idp!()
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      _ = issue!(attrs(cid, uid, d))
      jwt = T.insert_jwt_binding!(priv, sub, uid, d)
      assert osess(:end_device_session, [uid, d]) == :ok
      assert Nebu.Matrix.Session.DeviceBinding.list_for_user_device(uid, d) == []
      body = T.whoami(jwt) |> T.assert_unknown_token(false)
      assert body["error"] =~ "revoked"
    end
  end

  describe "story 4 AC5 — DeviceKeyStore.delete_device!/2 (raising variant for transactions)" do
    test "deletes the device and its key tables; delete_device/2 keeps its best-effort contract" do
      uid = T.provision_user!()
      d = dev()
      seed_keys!(uid, d)
      assert apply(Nebu.Matrix.DeviceKeyStore, :delete_device!, [uid, d]) == :ok
      assert T.device_gone?(uid, d)
      assert apply(Nebu.Matrix.DeviceKeyStore, :delete_device!, [uid, d]) == :ok, "idempotent"
      assert Nebu.Matrix.DeviceKeyStore.delete_device(uid, d) == :ok
    end
  end
end
