defmodule Nebu.OAuth.OAuthAccountCrossSigningTest do
  @moduledoc """
  Acceptance tests for story `oauth-account-management` (story 6 of epic oauth-broker),
  AC8 and the UIA separation of AC9 (A14, A15; Must #21-#31, #41-#46, #54, #57): the `m.oauth` UIA
  stage on `POST /_matrix/client/v3/keys/device_signing/upload` for OAuth callers REPLACING keys,
  approvals bound to user + requesting device + master-key hash, single use in ONE transaction with
  the key write, the corrected "unchanged" rule (supplied keys only, master required), legacy callers
  byte-identical, `m.oauth` never elsewhere, legacy SSO fallback / `Uia.complete/2` never completing a
  reset session.

  Approvals are made through the facade `Nebu.Matrix.approve_cross_signing_reset/2` (via `apply/3`;
  the page itself is covered in `oauth_account_test.exs`). Key-write / mint failures are privileged
  triggers (`T.block_cross_signing_writes!/1`, `T.block_uia_inserts!/1`).

  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @reset_url "https://nebu.example.com/account?action=org.matrix.cross_signing_reset"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    cid = T.oauth_client!([@https])
    sub = T.unique_sub()
    s = T.oauth_device!(cid, @https, priv, sub, dev())
    s2 = T.oauth_device!(cid, @https, priv, sub, dev())
    uid = s.user_id
    assert T.device_signing_upload(s.at, T.cross_signing_keys(uid, "OLD")).status == 200, "first upload needs no UIA"
    {:ok, priv: priv, cid: cid, sub: sub, s: s, s2: s2, uid: uid}
  end

  defp dev, do: "XS" <> String.upcase(T.rand(4))
  defp now, do: System.system_time(:second)
  defp approve(uid, sid), do: apply(Nebu.Matrix, :approve_cross_signing_reset, [uid, sid])
  defp with_auth(body, auth), do: Map.put(body, "auth", auth)

  defp assert_challenge(conn) do
    assert conn.status == 401, "expected the m.oauth challenge, got #{conn.status}: #{conn.resp_body}"
    body = T.json(conn)
    assert Enum.sort(Map.keys(body)) == ["flows", "params", "session"], "EXACTLY flows, params, session (no errcode/error/completed): #{inspect(body)}"
    assert body["flows"] == [%{"stages" => ["m.oauth"]}]
    assert body["params"] == %{"m.oauth" => %{"url" => @reset_url}}
    assert is_binary(body["session"]) and body["session"] != ""
    body["session"]
  end

  # Blocks until a backend waits for a lock nobody released yet (pg_locks is visible to every role).
  defp wait_for_ungranted_lock!(attempts \\ 400) do
    %{rows: [[waiting]]} = T.privileged_sql!("SELECT count(*) FROM pg_locks WHERE NOT granted")

    cond do
      waiting > 0 -> :ok
      attempts == 0 -> flunk("no backend ever waited for the cross_signing_keys row lock")
      true ->
        Process.sleep(25)
        wait_for_ungranted_lock!(attempts - 1)
    end
  end

  defp keys_still_old(uid), do: assert(T.stored_master(uid) == T.cross_signing_keys(uid, "OLD")["master_key"], "keys unchanged")

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — the challenge (Must #21, #22, #41, #57)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/A14 step 7 — the m.oauth challenge" do
    test "Must #21/#57: 401 with exactly flows/params/session; url == account_management_uri?action=...; one pending row bound to the device + master hash", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      meta = T.json(T.get_metadata())
      assert @reset_url == meta["account_management_uri"] <> "?action=org.matrix.cross_signing_reset"
      assert String.starts_with?(@reset_url, "https://")

      row = T.uia_row(sid)
      assert row["op"] == "cross_signing_reset"
      assert row["stage_complete"] == false and row["consumed"] == false
      assert row["user_id"] == ctx.uid
      assert row["params"] =~ ctx.s.device_id, "params bound to the requesting device"
      assert row["params"] =~ T.keys_hash(body), "params bound to the SHA-256 of ALL supplied keys (test review M7)"
      assert row["expires_at"] <= System.system_time(:second) + 900, "the reset session lives at most 900 s"
      keys_still_old(ctx.uid)
    end

    test "Must #22/#41: two consecutive auth-less attempts get the SAME session (no new row); auth with a pending session => same session", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      a = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      b = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      assert a == b
      assert T.uia_count(ctx.uid, "cross_signing_reset") == 1
      c = assert_challenge(T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => a})))
      assert c == a
      keys_still_old(ctx.uid)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — the retry after approval (Must #23, #42, #44, #45)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/A14 step 6 — retry after approval" do
    for {label, auth} <- [{"no type", %{}}, {"type m.oauth", %{"type" => "m.oauth"}}, {"type org.matrix.cross_signing_reset", %{"type" => "org.matrix.cross_signing_reset"}}] do
      test "Must #42: retry with #{label} => 200 {}, keys replaced, cross_signing_changed set", ctx do
        body = T.cross_signing_keys(ctx.uid, "NEW")
        sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
        assert approve(ctx.uid, sid) == :ok
        T.sql!("UPDATE cross_signing_keys SET cross_signing_changed = FALSE WHERE user_id = $1", [ctx.uid])

        conn = T.device_signing_upload(ctx.s.at, with_auth(body, Map.put(unquote(Macro.escape(auth)), "session", sid)))
        assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
        assert T.json(conn) == %{}
        assert T.stored_master(ctx.uid) == body["master_key"]
        assert %{rows: [[true]]} = T.sql!("SELECT cross_signing_changed FROM cross_signing_keys WHERE user_id = $1", [ctx.uid])
        assert T.uia_row(sid)["consumed"] == true

        q = T.matrix_request(:post, "/_matrix/client/v3/keys/query", ctx.s2.at, body: %{"device_keys" => %{ctx.uid => []}})
        assert T.json(q)["master_keys"][ctx.uid]["keys"] == body["master_key"]["keys"]
      end
    end

    test "Must #42: type m.login.sso => re-challenge, keys unchanged", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      _ = assert_challenge(T.device_signing_upload(ctx.s.at, with_auth(body, %{"type" => "m.login.sso", "session" => sid})))
      keys_still_old(ctx.uid)
      assert T.uia_row(sid)["consumed"] == false
    end

    test "Must #45: lost-response retry with the SAME body after success => 200 identical re-upload, nothing consumed; different body => NEW session", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      assert T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid})).status == 200
      count = T.uia_count(ctx.uid, "cross_signing_reset")

      same = T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid}))
      assert same.status == 200 and T.json(same) == %{}, "step 3 before step 6: identical re-upload"
      assert T.uia_count(ctx.uid, "cross_signing_reset") == count

      different = T.cross_signing_keys(ctx.uid, "NEWER")
      new_sid = assert_challenge(T.device_signing_upload(ctx.s.at, with_auth(different, %{"session" => sid})))
      refute new_sid == sid
      assert T.stored_master(ctx.uid) == body["master_key"]
    end

    test "Must #44: the approved session with a DIFFERENT master key => new challenge, keys unchanged, the approved row unconsumed", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      other = T.cross_signing_keys(ctx.uid, "OTHER")
      new_sid = assert_challenge(T.device_signing_upload(ctx.s.at, with_auth(other, %{"session" => sid})))
      refute new_sid == sid
      keys_still_old(ctx.uid)
      assert T.uia_row(sid)["consumed"] == false
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — approval binding, TTL, transaction, mint (Must #24-#27)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/A14/A15 — binding, TTL, transaction, checked mint" do
    test "Must #24: the session presented by ANOTHER device, another user or for delete_devices is not accepted", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)

      _ = assert_challenge(T.device_signing_upload(ctx.s2.at, with_auth(body, %{"session" => sid})))
      keys_still_old(ctx.uid)

      stranger = T.oauth_device!(ctx.cid, @https, ctx.priv, T.unique_sub(), dev())
      sbody = T.cross_signing_keys(stranger.user_id, "S1")
      assert T.device_signing_upload(stranger.at, sbody).status == 200
      conn = T.device_signing_upload(stranger.at, with_auth(T.cross_signing_keys(stranger.user_id, "S2"), %{"session" => sid}))
      assert conn.status == 401
      assert T.uia_row(sid)["consumed"] == false
      assert T.stored_master(stranger.user_id) == sbody["master_key"], "the stranger's keys are unchanged"
      keys_still_old(ctx.uid)

      del_sid = Nebu.Matrix.Uia.mint_session(ctx.uid, "delete_devices", Nebu.Matrix.Uia.canonical_params([ctx.s.device_id]))
      T.sql!("UPDATE uia_sessions SET stage_complete = TRUE WHERE session_id = $1", [del_sid])
      _ = assert_challenge(T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => del_sid})))
      keys_still_old(ctx.uid)
    end

    test "Must #25: an approval expires at most 600 s after approval (and the row 900 s after mint)", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      assert T.uia_row(sid)["expires_at"] <= now() + 600
      T.sql!("UPDATE uia_sessions SET expires_at = $2 WHERE session_id = $1", [sid, now() - 1])
      _ = assert_challenge(T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid})))
      keys_still_old(ctx.uid)
    end

    test "Must #26: key write failure after the consume => 500 M_UNKNOWN, keys unchanged, the approval still consumable", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      remove = T.block_cross_signing_writes!(ctx.uid)

      conn = T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid}))
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      keys_still_old(ctx.uid)
      assert T.uia_row(sid)["consumed"] == false, "transaction rolled back: the approval is not burned"

      remove.()
      assert T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid})).status == 200
    end

    # story sync-token-per-device, review cycle 0 m3 / m4: put_keys/2 RETURNS the error now (no raise); the replacement path logs the kind only
    test "Must #26 (sync-token-per-device): a failed key write logs only the error kind, never key material; no position stamped; the approval stays usable", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      material = body["master_key"]["keys"] |> Map.values() |> hd()
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      {pos_before, _} = Nebu.Matrix.CrossSigningKeyStore.changed_since?(ctx.uid, 0)
      remove = T.block_cross_signing_writes!(ctx.uid)

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:resp, T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid}))}) end)
      assert_received {:resp, conn}
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      assert log =~ "m.oauth cross-signing key write failed: Postgrex.Error", "the error kind is logged: #{inspect(log)}"
      refute log =~ material, "no key material in the log"
      refute log =~ "write blocked", "the error message is never logged"
      keys_still_old(ctx.uid)
      assert {^pos_before, _} = Nebu.Matrix.CrossSigningKeyStore.changed_since?(ctx.uid, 0), "the rolled-back write stamped no changed_pos"
      assert T.uia_row(sid)["consumed"] == false, "the approval is not burned"

      remove.()
      assert T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid})).status == 200
      assert T.stored_master(ctx.uid) == body["master_key"]
    end

    test "Must #27: mint failure => 500 M_UNKNOWN, never a challenge for a session that does not exist", ctx do
      _remove = T.block_uia_inserts!(ctx.uid)
      conn = T.device_signing_upload(ctx.s.at, T.cross_signing_keys(ctx.uid, "NEW"))
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      keys_still_old(ctx.uid)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — unchanged branches, corrected rule, OAuth not live, legacy (Must #28, #29, #46)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/A14 steps 1-5 — unchanged branches and the corrected unchanged rule" do
    test "Must #28: OAuth not live => replacement 403 'Cannot replace existing cross-signing keys' (no challenge)", ctx do
      T.disable_oauth()
      conn = T.device_signing_upload(ctx.s.at, T.cross_signing_keys(ctx.uid, "NEW"))
      assert conn.status == 403
      assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "Cannot replace existing cross-signing keys"}
      assert T.uia_count(ctx.uid, "cross_signing_reset") == 0
    end

    test "Must #28: OAuth callers: identical re-upload 200 (also with an auth block), key-id collision 400", ctx do
      old = T.cross_signing_keys(ctx.uid, "OLD")
      assert T.device_signing_upload(ctx.s.at, old).status == 200
      assert T.device_signing_upload(ctx.s.at, with_auth(old, %{"session" => "whatever"})).status == 200

      T.seed_device_keys!(ctx.uid, ctx.s.device_id)
      collide = %{"master_key" => %{"user_id" => ctx.uid, "usage" => ["master"], "keys" => %{"ed25519:#{ctx.s.device_id}" => ctx.s.device_id}}}
      conn = T.device_signing_upload(ctx.s.at, collide)
      assert conn.status == 400
      assert T.json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "Must #46: master-only matching re-upload with stored SSK/USK => 200 without UIA (OAuth)", ctx do
      assert T.device_signing_upload(ctx.s.at, Map.take(T.cross_signing_keys(ctx.uid, "OLD"), ["master_key"])).status == 200
      assert T.device_signing_upload(ctx.s.at, Map.take(T.cross_signing_keys(ctx.uid, "OLD"), ["master_key", "self_signing_key"])).status == 200
      assert T.uia_count(ctx.uid, "cross_signing_reset") == 0
    end

    test "Must #46: SSK-only with a stored master => replacement (OAuth challenge)", ctx do
      _ = assert_challenge(T.device_signing_upload(ctx.s.at, Map.take(T.cross_signing_keys(ctx.uid, "NEW"), ["self_signing_key"])))
      keys_still_old(ctx.uid)
    end
  end

  describe "AC8/A14 step 4/Must #29, #46 — legacy callers byte-identical (status + body), no uia row" do
    setup ctx do
      lsub = T.unique_sub()
      luid = T.provision_user!(lsub)
      legacy = T.legacy_session!(luid, dev())
      jwt = T.bound_jwt!(ctx.priv, lsub, dev())
      assert T.device_signing_upload(legacy.at, T.cross_signing_keys(luid, "LOLD")).status == 200
      {:ok, luid: luid, tokens: [legacy.at, jwt]}
    end

    test "replacement => 403 'Cannot replace existing cross-signing keys', with and without auth; no uia row", ctx do
      for token <- ctx.tokens, body <- [T.cross_signing_keys(ctx.luid, "LNEW"), with_auth(T.cross_signing_keys(ctx.luid, "LNEW"), %{"type" => "m.oauth", "session" => "x"})] do
        conn = T.device_signing_upload(token, body)
        assert {conn.status, T.json(conn)} == {403, %{"errcode" => "M_FORBIDDEN", "error" => "Cannot replace existing cross-signing keys"}}
      end

      assert T.uia_count(ctx.luid, "cross_signing_reset") == 0
    end

    test "identical re-upload 200 {}; master-only matching re-upload with stored SSK/USK => 200 (corrected rule); SSK-only => 403", ctx do
      [token | _] = ctx.tokens
      assert {200, %{}} == then(T.device_signing_upload(token, T.cross_signing_keys(ctx.luid, "LOLD")), &{&1.status, T.json(&1)})
      assert T.device_signing_upload(token, Map.take(T.cross_signing_keys(ctx.luid, "LOLD"), ["master_key"])).status == 200,
             "spec v1.18: a request whose supplied keys all match needs no UIA (was 403 before story 6)"
      assert T.device_signing_upload(token, Map.take(T.cross_signing_keys(ctx.luid, "LNEW"), ["self_signing_key"])).status == 403
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8/AC9 — m.oauth never elsewhere; legacy SSO never completes a reset (Must #31, #43)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/AC9/A15/Must #31, #43 — separation from the legacy UIA" do
    test "Must #43: m.oauth never appears in the flows of DELETE /devices, /delete_devices (legacy challenge)", ctx do
      T.put_env_scoped(:uia_fresh_auth_seconds, 1)
      legacy = T.legacy_session!(ctx.uid, dev())
      T.sql!("UPDATE matrix_sessions SET auth_time = 1000 WHERE access_token_hash = $1", [T.token_hash(legacy.at)])
      target = dev()
      Nebu.Matrix.DeviceKeyStore.upsert_device(ctx.uid, target)

      for conn <- [T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> target, legacy.at, body: %{}),
                   T.matrix_request(:post, "/_matrix/client/v3/delete_devices", legacy.at, body: %{"devices" => [target]})] do
        assert conn.status == 401
        refute conn.resp_body =~ "m.oauth"
        assert T.json(conn)["flows"] == [%{"stages" => ["m.login.sso"]}]
      end
    end

    test "Must #31: the legacy SSO fallback refuses a reset session (400) and Uia.complete/2 => :error, row unchanged", ctx do
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, T.cross_signing_keys(ctx.uid, "NEW")))
      before = T.uia_row(sid)
      conn = T.get("/_matrix/client/v3/auth/m.login.sso/fallback/web?session=" <> URI.encode_www_form(sid))
      assert conn.status == 400
      assert T.json(conn)["error"] == "Unknown or expired UIA session"
      assert Nebu.Matrix.Uia.complete(sid, ctx.uid) == :error
      assert T.uia_row(sid) == before
    end

    test "Must #31: the approval functions touch only cross_signing_reset rows", ctx do
      del_sid = Nebu.Matrix.Uia.mint_session(ctx.uid, "delete_devices", "{}")
      assert approve(ctx.uid, del_sid) == {:error, :not_found}
      assert apply(Nebu.Matrix, :decline_cross_signing_reset, [ctx.uid, del_sid]) == {:error, :not_found}
      assert T.uia_row(del_sid)["stage_complete"] == false and T.uia_row(del_sid)["consumed"] == false
    end
  end

  describe "A1 — facade contracts" do
    test "cross_signing_reset_requests/1 lists the pending request with device + times; reset url facade", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      assert {:ok, [req]} = apply(Nebu.Matrix, :cross_signing_reset_requests, [ctx.uid])
      assert req.session_id == sid and req.device_id == ctx.s.device_id
      assert is_integer(req.requested_at) and is_integer(req.expires_at)
      assert Map.has_key?(req, :device_display_name)
      assert apply(Nebu.OAuth, :cross_signing_reset_url, []) == {:ok, @reset_url}
      T.disable_oauth()
      assert apply(Nebu.OAuth, :cross_signing_reset_url, []) == :unavailable
    end
  end
  # ════════════════════════════════════════════════════════════════════════════
  # story oauth-authorize-freshness — AC13 / FR16 (gate ak (1)-(3))
  #
  # `do_device_signing_upload/1` normalizes the supplied keys BEFORE the guard, the digest and the merge,
  # for EVERY caller: an explicit `null` key is dropped (absent); a non-object value => 400 M_BAD_JSON
  # "Invalid cross-signing key". Nebu choice (oracle correction 9): `{}` / all-null while a master is
  # stored => 400 M_MISSING_PARAM without UIA for legacy AND OAuth callers (legacy answered 403 before).
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC13.1 / FR16 (1) — explicit null keys are absent keys (OAuth)" do
    test "an APPROVED session presented with {\"master_key\": null} (or all-null) => 400 M_MISSING_PARAM, keys unchanged, the approval is NOT consumed", ctx do
      body = T.cross_signing_keys(ctx.uid, "NEW")
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      auth = %{"session" => sid}

      for nullish <- [
            %{"master_key" => nil},
            %{"master_key" => nil, "self_signing_key" => nil, "user_signing_key" => nil}
          ] do
        conn = T.device_signing_upload(ctx.s.at, with_auth(nullish, auth))
        assert conn.status == 400, "got #{conn.status}: #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_MISSING_PARAM"
        keys_still_old(ctx.uid)
        assert T.uia_row(sid)["consumed"] == false, "the approval must survive a body that supplies no key"
      end

      assert T.device_signing_upload(ctx.s.at, with_auth(body, auth)).status == 200, "the approval still works for the real body"
    end

    test "{\"master_key\": new, \"self_signing_key\": null} merges master-ONLY and KEEPS the stored SSK / USK", ctx do
      new_master = T.cross_signing_keys(ctx.uid, "NEWM")["master_key"]
      body = %{"master_key" => new_master, "self_signing_key" => nil}

      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      assert T.uia_row(sid)["params"] =~ T.keys_hash(%{"master_key" => new_master}), "the approval is bound to the NORMALIZED supplied keys (null dropped)"
      :ok = approve(ctx.uid, sid)

      conn = T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid}))
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      assert T.stored_master(ctx.uid) == new_master
      old = T.cross_signing_keys(ctx.uid, "OLD")
      stored = Nebu.Matrix.CrossSigningKeyStore.get_keys(ctx.uid)
      assert stored["self_signing_key"] == old["self_signing_key"], "a null SSK is not a request to delete the SSK"
      assert stored["user_signing_key"] == old["user_signing_key"]
    end

    test "{\"master_key\": <stored>, \"self_signing_key\": null} => 200 {} WITHOUT UIA (the supplied keys all match)", ctx do
      stored_master = T.cross_signing_keys(ctx.uid, "OLD")["master_key"]
      conn = T.device_signing_upload(ctx.s.at, %{"master_key" => stored_master, "self_signing_key" => nil})
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == %{}
      assert T.uia_count(ctx.uid, "cross_signing_reset") == 0
      keys_still_old(ctx.uid)
    end

    test "MINOR 10: a null master with a NEW self-signing key, and the STORED master with a NEW self-signing key, still need UIA", ctx do
      old = T.cross_signing_keys(ctx.uid, "OLD")
      new = T.cross_signing_keys(ctx.uid, "NEWS")

      for body <- [
            %{"master_key" => nil, "self_signing_key" => new["self_signing_key"]},
            %{"master_key" => old["master_key"], "self_signing_key" => new["self_signing_key"]}
          ] do
        sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
        assert T.uia_row(sid)["consumed"] == false
        keys_still_old(ctx.uid)
      end
    end

    test "a first upload with a null self-signing key stores the others", ctx do
      stranger = T.oauth_device!(ctx.cid, @https, ctx.priv, T.unique_sub(), dev())
      keys = T.cross_signing_keys(stranger.user_id, "FIRST")
      conn = T.device_signing_upload(stranger.at, %{"master_key" => keys["master_key"], "self_signing_key" => nil, "user_signing_key" => keys["user_signing_key"]})
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      stored = Nebu.Matrix.CrossSigningKeyStore.get_keys(stranger.user_id)
      assert stored["master_key"] == keys["master_key"]
      assert stored["self_signing_key"] == nil
      assert stored["user_signing_key"] == keys["user_signing_key"]
    end
  end

  describe "AC13.1 — {} / all-null with a stored master is 400 M_MISSING_PARAM for EVERY caller (pinned Nebu choice, no UIA)" do
    setup ctx do
      lsub = T.unique_sub()
      luid = T.provision_user!(lsub)
      legacy = T.legacy_session!(luid, dev())
      assert T.device_signing_upload(legacy.at, T.cross_signing_keys(luid, "LOLD")).status == 200
      {:ok, luid: luid, legacy: legacy, ctx: ctx}
    end

    test "OAuth caller", ctx do
      for body <- [%{}, %{"master_key" => nil}, %{"master_key" => nil, "self_signing_key" => nil, "user_signing_key" => nil}] do
        conn = T.device_signing_upload(ctx.s.at, body)
        assert conn.status == 400, "#{inspect(body)} => #{conn.status}: #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_MISSING_PARAM"
      end

      assert T.uia_count(ctx.uid, "cross_signing_reset") == 0, "no UIA session is minted for a body without keys"
      keys_still_old(ctx.uid)
    end

    test "LEGACY caller (was 403 before): 400 M_MISSING_PARAM, no uia row, keys unchanged", ctx do
      for body <- [%{}, %{"master_key" => nil}, %{"master_key" => nil, "self_signing_key" => nil, "user_signing_key" => nil}] do
        conn = T.device_signing_upload(ctx.legacy.at, body)
        assert conn.status == 400, "#{inspect(body)} => #{conn.status}: #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_MISSING_PARAM"
      end

      assert T.uia_count(ctx.luid, "cross_signing_reset") == 0
      assert T.stored_master(ctx.luid) == T.cross_signing_keys(ctx.luid, "LOLD")["master_key"]
    end

    test "LEGACY caller: {master: <stored>, ssk: null} => 200 {} (unchanged rule on the supplied keys)", ctx do
      stored = T.cross_signing_keys(ctx.luid, "LOLD")["master_key"]
      conn = T.device_signing_upload(ctx.legacy.at, %{"master_key" => stored, "self_signing_key" => nil})
      assert conn.status == 200
      assert T.json(conn) == %{}
    end

    test "LEGACY caller: a replacement is still 403 'Cannot replace existing cross-signing keys' (unchanged)", ctx do
      conn = T.device_signing_upload(ctx.legacy.at, T.cross_signing_keys(ctx.luid, "LNEW"))
      assert {conn.status, T.json(conn)} == {403, %{"errcode" => "M_FORBIDDEN", "error" => "Cannot replace existing cross-signing keys"}}
    end
  end

  describe "AC13.2 / FR16 — a non-object key is 400 M_BAD_JSON (legacy and OAuth)" do
    setup ctx do
      lsub = T.unique_sub()
      luid = T.provision_user!(lsub)
      legacy = T.legacy_session!(luid, dev())
      assert T.device_signing_upload(legacy.at, T.cross_signing_keys(luid, "LOLD")).status == 200
      {:ok, luid: luid, legacy: legacy, ctx: ctx}
    end

    test "string, list and number for each of the three keys", ctx do
      good = T.cross_signing_keys(ctx.uid, "NEW")

      for key <- ~w(master_key self_signing_key user_signing_key), junk <- ["a string", [1, 2], 7, true, [%{"a" => 1}]] do
        body = Map.put(good, key, junk)

        for {who, token} <- [{"oauth", ctx.s.at}, {"legacy", ctx.legacy.at}] do
          conn = T.device_signing_upload(token, body)
          assert conn.status == 400, "#{who} #{key}=#{inspect(junk)} => #{conn.status}: #{conn.resp_body}"
          assert T.json(conn)["errcode"] == "M_BAD_JSON"
          assert T.json(conn)["error"] == "Invalid cross-signing key"
        end
      end

      assert T.uia_count(ctx.uid, "cross_signing_reset") == 0, "no UIA session for an invalid body"
      keys_still_old(ctx.uid)
      assert T.stored_master(ctx.luid) == T.cross_signing_keys(ctx.luid, "LOLD")["master_key"]
    end

    test "also on a FIRST upload: nothing is stored", ctx do
      fresh = T.oauth_device!(ctx.cid, @https, ctx.priv, T.unique_sub(), dev())
      keys = T.cross_signing_keys(fresh.user_id, "FIRST")
      conn = T.device_signing_upload(fresh.at, %{"master_key" => keys["master_key"], "self_signing_key" => "not-an-object"})
      assert conn.status == 400
      assert T.json(conn)["errcode"] == "M_BAD_JSON"
      assert T.stored_master(fresh.user_id) == nil, "the valid master of a rejected body is not stored either"
    end

    test "normalization runs BEFORE the key-id guard: a junk key never reaches the device-id check", ctx do
      body = %{"master_key" => "junk", "self_signing_key" => T.cross_signing_keys(ctx.uid, "NEW")["self_signing_key"]}
      conn = T.device_signing_upload(ctx.s.at, body)
      assert T.json(conn)["errcode"] == "M_BAD_JSON"
    end
  end

  describe "AC13.3 / FR16 (2) — merge base read FOR UPDATE inside the transaction" do
    test "a concurrent change of the USK made while the request waits for the row lock is NOT overwritten by a stale merge base", ctx do
      new_master = T.cross_signing_keys(ctx.uid, "NEWM")["master_key"]
      body = %{"master_key" => new_master}
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)
      concurrent_usk = T.cross_signing_keys(ctx.uid, "CONC")["user_signing_key"]

      {:ok, task} =
        Nebu.Repo.transaction(fn ->
          T.sql!("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [ctx.uid])
          task = Task.async(fn -> T.safely(fn -> T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid})) end) end)
          # the ONLY evidence that the request really waits for the row lock: a backend with an UNGRANTED lock
          # (pg_locks), not a timeout (a slow request would also look "not finished yet")
          wait_for_ungranted_lock!()
          assert Task.yield(task, 0) == nil, "the request must still be blocked on the cross_signing_keys row lock"

          # a concurrent writer changes the USK while the approved request is blocked on the lock
          stored = Nebu.Matrix.CrossSigningKeyStore.get_keys(ctx.uid)
          :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(ctx.uid, Map.put(stored, "user_signing_key", concurrent_usk))
          task
        end)

      assert {:ok, conn} = Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill)
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"

      stored = Nebu.Matrix.CrossSigningKeyStore.get_keys(ctx.uid)
      assert stored["master_key"] == new_master
      assert stored["user_signing_key"] == concurrent_usk, "the merge base must be read under the lock (FOR UPDATE), after the consume"
      assert stored["self_signing_key"] == T.cross_signing_keys(ctx.uid, "OLD")["self_signing_key"]
    end

    test "a FAILING locked read answers 500, rolls back (the approval is NOT consumed) and never opens the UIA-free branch", ctx do
      new_master = T.cross_signing_keys(ctx.uid, "NEWM")["master_key"]
      body = %{"master_key" => new_master}
      sid = assert_challenge(T.device_signing_upload(ctx.s.at, body))
      :ok = approve(ctx.uid, sid)

      # Fault injection: `SELECT ... FOR UPDATE` needs the UPDATE privilege, a plain SELECT does not. Without it
      # the unlocked first read works and only the locked read INSIDE the transaction fails. Restored in on_exit.
      T.privileged_sql!("REVOKE UPDATE ON cross_signing_keys FROM nebu_app")
      on_exit(fn -> T.privileged_sql!("GRANT UPDATE ON cross_signing_keys TO nebu_app") end)

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:resp, T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid}))}) end)
      assert_received {:resp, conn}
      assert conn.status == 500, "a failing locked read must be an error, got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      refute log =~ new_master["keys"] |> Map.values() |> hd(), "no key material in the log"

      T.privileged_sql!("GRANT UPDATE ON cross_signing_keys TO nebu_app")
      keys_still_old(ctx.uid)
      assert T.uia_row(sid)["consumed"] == false, "rolled back: the approval is not burned"
      assert T.stored_master(ctx.uid) != nil, "the stored keys were never wiped (no all-nil 'no master' read)"

      # and the approval still works once the fault is gone
      assert T.device_signing_upload(ctx.s.at, with_auth(body, %{"session" => sid})).status == 200
      assert T.stored_master(ctx.uid) == new_master
    end

    test "M2 / L-4: when the key read fails the branch decision is a 500 for EVERY caller, never the UIA-free first-upload or idempotent branch", ctx do
      stored_master = T.cross_signing_keys(ctx.uid, "OLD")["master_key"]
      T.privileged_sql!("REVOKE UPDATE ON cross_signing_keys FROM nebu_app")
      on_exit(fn -> T.privileged_sql!("GRANT UPDATE ON cross_signing_keys TO nebu_app") end)

      # an idempotent re-upload would be `200 {}` from the unlocked read; with the failing read it is an error
      conn = T.device_signing_upload(ctx.s.at, %{"master_key" => stored_master})
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"

      # a NEW user's first upload (no row) also needs the read: the failed read is not "no master stored"
      stranger = T.oauth_device!(ctx.cid, @https, ctx.priv, T.unique_sub(), dev())
      keys = T.cross_signing_keys(stranger.user_id, "FIRST")
      assert T.device_signing_upload(stranger.at, keys).status == 500
      T.privileged_sql!("GRANT UPDATE ON cross_signing_keys TO nebu_app")
      assert T.stored_master(stranger.user_id) == nil, "nothing was written during the outage"
    end

    # story cross-signing-upload-races (D-A2): the row-only `get_keys_for_update/1` is removed; its successor is the locked read
    # `lock_keys/1` (row lock, advisory lock, then the read), with the same result contract
    test "lock_keys/1 (successor of get_keys_for_update/1): {:ok, keys} (all-nil for an unknown user), {:error, _} when the query fails", ctx do
      assert {:module, _} = Code.ensure_loaded(Nebu.Matrix.CrossSigningKeyStore)
      assert function_exported?(Nebu.Matrix.CrossSigningKeyStore, :lock_keys, 1)
      refute function_exported?(Nebu.Matrix.CrossSigningKeyStore, :get_keys_for_update, 1)

      {:ok, {known, unknown}} =
        Nebu.Repo.transaction(fn ->
          {apply(Nebu.Matrix.CrossSigningKeyStore, :lock_keys, [ctx.uid]),
           apply(Nebu.Matrix.CrossSigningKeyStore, :lock_keys, ["@nobody-#{T.rand()}:test.local"])}
        end)

      assert {:ok, %{"master_key" => master}} = known
      assert master == T.cross_signing_keys(ctx.uid, "OLD")["master_key"]
      assert {:ok, %{"master_key" => nil, "self_signing_key" => nil, "user_signing_key" => nil}} = unknown

      # an error is an ERROR (the caller rolls back => 500), never an all-nil "no master stored" map (trap 8)
      assert {:error, _} = apply(Nebu.Matrix.CrossSigningKeyStore, :lock_keys, ["a\0b"])
    end
  end

  describe "AC13.4 — the Account moduledoc states the real limits of the Origin / navigation checks (gate ag)" do
    test "the moduledoc names the Origin: null fallback and that a scripted form.submit() is NOT stopped" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Nebu.OAuth.Account)

      assert doc =~ "Origin: null", "the Origin: null fallback is documented"
      assert doc =~ "Sec-Fetch-Site: same-origin"
      assert doc =~ "form.submit()", "the navigation check stops fetch/XHR but not a scripted form.submit()"
      assert doc =~ ~r/gate ag|\bag\b/, "the open gate is named"
      refute doc =~ "`Sec-Fetch-Site` (when present) not `cross-site`", "the earlier, too optimistic sentence is replaced"
    end
  end
end
