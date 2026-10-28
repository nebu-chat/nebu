defmodule Nebu.OAuth.OAuthClientRevocationTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-client-revocation` (P4): AC3 (the cascade
  teardown of `Nebu.OAuth.revoke_client/3`, CR4), AC4 (every entry point refuses `revoked`, CR6), AC9 (the operator
  RPC functions, CR10) and the logging law of AC11. The race against token issuance is `oauth_client_revocation_race_test.exs`,
  the admin UI is `oauth_admin_clients_test.exs`, the migration is `000046_oauth_client_revocation_test.exs`.

  ## Pinned contracts (implemented; changing one means changing this test)

    * `Nebu.OAuth.revoke_client(client_id, actor, opts) :: {:ok, %{devices: n}} | {:error, :not_approved} |
      {:error, {:audit, term}} | {:error, term}` (ADR-020 facade over `ClientStore.revoke/3`). `actor` is the
      attribution (`revoked_by`). Options: `:reason` (binary | nil, stored as `revoked_reason`, already
      normalised by the caller) and `:audit` (1-arity fun, receives the list of `{user_id, device_id}` pairs that
      were torn down, returns `:ok | {:error, _}`; runs INSIDE the transaction as the last step: a failed audit
      rolls EVERYTHING back and yields `{:error, {:audit, reason}}`; an audit fun that raises counts as failed).
    * ONE transaction (CR4): status UPDATE -> teardown of every `(user_id, device_id)` that has a `matrix_sessions`
      row of the client (also expired / revoked rows, rotated rows, any `auth_api`) -> `oauth_codes.used_at` for
      the unused codes -> DELETE of the client's `oauth_authz_requests` AND (P3 follow-up) its
      `oauth_consent_requests` -> audit. IdP refresh leases die with the devices (FK cascade).
    * After the commit the JWT denylist / binding deletion of the torn-down devices runs (best effort).
    * `Nebu.Release.revoke_oauth_client(client_id, reason) :: {:ok, %{devices: n}} | {:error, :not_approved | term}`
      (actor `"operator:rpc"`) and `Nebu.Release.revoke_all_oauth_sessions() :: {:ok, n} | {:error, term}`; audit
      actions `oauth_client_revoked` (metadata `devices`, `reauth: "rpc"`, `reason` only when given) and
      `oauth_sessions_revoked_all` (metadata `devices` = n), target_type `oauth_client`, target_id the client id /
      `"all"`. Both are called with `apply/3` here so the suite compiles before the functions exist.
    * Entry points (CR6): authorize / token (both grants) / revoke / resource server / DCR dedup / consent as
      asserted below.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @admin "@admin:test.local"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    prior_writer = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      case prior_writer do
        {:ok, writer} -> Application.put_env(:compliance, :audit_writer, writer)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end

      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo, :oauth_client_revoke_hook], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp dev, do: "RV" <> String.upcase(T.rand(4))

  defp revoke(cid, opts \\ []), do: apply(Nebu.OAuth, :revoke_client, [cid, Keyword.get(opts, :actor, @admin), Keyword.delete(opts, :actor)])

  defp device_session(cid, priv, sub, device_id),
    do: T.session!(cid, @https, priv, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), device_id)})

  defp client_sessions(cid) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM matrix_sessions WHERE client_id = $1", [cid])
    n
  end

  defp audit_rows(action, target_id) do
    %{rows: rows} =
      T.sql!("SELECT actor_user_id, metadata, outcome, target_type FROM audit_log WHERE action = $1 AND target_id = $2", [action, target_id])

    rows
  end

  # The full fixture of AC3: client A with 3 devices of 2 users (one rotated, one expired), seeded keys, an unused
  # and the used codes, two authorize requests, two consent rows, a lease; client B with 1 device.
  defp fixture(priv) do
    a = T.oauth_client!([@https], client_name: "Revoke Target", client_uri: "https://app.example.com")
    b = T.oauth_client!(["https://other.example.com/cb"], client_uri: "https://other.example.com")
    {sub1, sub2, sub3} = {T.unique_sub(), T.unique_sub(), T.unique_sub()}
    {d1, d2, d3, db} = {dev(), dev(), dev(), dev()}

    s1 = device_session(a, priv, sub1, d1)
    s2 = device_session(a, priv, sub1, d2)
    s3 = device_session(a, priv, sub2, d3)
    sb = T.session!(b, "https://other.example.com/cb", priv, sub: sub3, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), db)})

    # rotated rows: the old row is in its grace window, the new one is the live one
    T.idp_refresh_for([s2])
    rotated = T.refresh!(a, s2.rt)
    # one expired session (still has to be listed and torn down)
    T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '2 hours', session_expires_at = now() - interval '1 hour' WHERE user_id = $1 AND device_id = $2", [s3.user_id, d3])

    for s <- [s1, s2, s3], do: T.seed_device_keys!(s.user_id, s.device_id)
    T.seed_cross_signing!(s1.user_id)
    T.seed_device_keys!(sb.user_id, db)

    unused = T.insert_code!(a, user_id: s1.user_id, device_id: dev())
    f1 = T.start_flow(a, @https)
    f2 = T.start_flow(a, @https)
    c1 = T.insert_consent!(a, user_id: s1.user_id)
    c2 = T.insert_consent!(a, user_id: s3.user_id)
    :ok = T.hold_lease!(s1.user_id, d1, 30)

    # client B: one of each, none of which may be touched
    _b_unused = T.insert_code!(b, user_id: sb.user_id, device_id: dev(), redirect_uri: "https://other.example.com/cb")
    _b_flow = T.start_flow(b, "https://other.example.com/cb")
    _b_consent = T.insert_consent!(b, user_id: sb.user_id, redirect_uri: "https://other.example.com/cb")

    %{a: a, b: b, s: [s1, s2, s3], sb: sb, rotated: rotated, unused: unused, flows: [f1, f2], consents: [c1, c2], users: [s1.user_id, s3.user_id, sb.user_id]}
  end

  defp snapshot(cid, users) do
    %{
      world: T.world_snapshot(users),
      client: T.client_row(cid),
      codes: T.rows_for("oauth_codes", cid),
      requests: T.rows_for("oauth_authz_requests", cid),
      consents: T.rows_for("oauth_consent_requests", cid)
    }
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — cascade teardown
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3.1 — revoke_client/3 tears down everything of the client in one transaction" do
    test "sessions, devices (+ keys), codes, authorize requests, consent rows and leases of A are gone/used; A is revoked; B is untouched", %{priv: priv} do
      f = fixture(priv)
      [s1, s2, s3] = f.s
      b_before = snapshot(f.b, [f.sb.user_id])

      assert {:ok, %{devices: 3}} = revoke(f.a, reason: "lost the signing key")

      assert client_sessions(f.a) == 0, "no matrix_sessions row of the client (live, rotated, expired) is left"
      for s <- [s1, s2, s3], do: assert(T.device_gone?(s.user_id, s.device_id), "device #{s.device_id} + its keys are deleted")
      assert T.lease_rows(s1.user_id, s1.device_id) == [], "the IdP refresh lease dies with the device (FK cascade)"
      assert T.cross_signing_count(s1.user_id) == 1, "cross-signing keys are per user: never deleted"

      codes = T.rows_for("oauth_codes", f.a)
      assert codes != [] and Enum.all?(codes, &(&1["used_at"] != nil)), "every code (used or not) is used afterwards; live ones cannot be deleted"
      assert T.rows_for("oauth_authz_requests", f.a) == [], "the callback of an open authorize request answers invalid_state"
      assert T.rows_for("oauth_consent_requests", f.a) == [], "P3 follow-up: the client's consent requests are deleted too"

      row = T.client_row(f.a)
      assert row["status"] == "revoked" and row["revoked_by"] == @admin and row["revoked_at"] != nil
      assert row["revoked_reason"] == "lost the signing key"
      assert row["approved_by"] != nil and row["approved_at"] != nil, "the approval attribution is kept"

      assert snapshot(f.b, [f.sb.user_id]) == b_before, "client B (sessions, device, keys, codes, requests, consent) is untouched"
      assert T.client_row(f.b)["status"] == "approved"
      assert T.whoami(f.sb.at).status == 200
    end

    test "the former tokens of the revoked client are dead: access token 401 M_UNKNOWN_TOKEN, refresh token (also a rotated one) invalid", %{priv: priv} do
      f = fixture(priv)
      [s1, s2, _s3] = f.s
      assert {:ok, %{devices: 3}} = revoke(f.a)

      T.assert_unknown_token(T.whoami(s1.at), false)
      T.assert_unknown_token(T.whoami(f.rotated["access_token"]), false)
      T.refresh(f.a, s1.rt) |> T.assert_token_error(401, "invalid_client")
      T.refresh(f.a, f.rotated["refresh_token"]) |> T.assert_token_error(401, "invalid_client")
      T.refresh(f.a, s2.rt) |> T.assert_token_error(401, "invalid_client")
    end

    test "the audit function runs inside the transaction and receives the torn-down {user_id, device_id} pairs", %{priv: priv} do
      f = fixture(priv)
      parent = self()

      audit = fn pairs ->
        send(parent, {:audit_pairs, pairs, client_sessions(f.a), T.client_row(f.a)["status"]})
        :ok
      end

      assert {:ok, %{devices: 3}} = revoke(f.a, audit: audit)
      assert_received {:audit_pairs, pairs, _sessions_seen_inside, _status_seen_inside}
      assert Enum.sort(pairs) == Enum.sort(for s <- f.s, do: {s.user_id, s.device_id})
    end

    test "a client without any device is revoked too ({:ok, %{devices: 0}})" do
      cid = T.oauth_client!([@https])
      assert {:ok, %{devices: 0}} = revoke(cid)
      assert T.client_row(cid)["status"] == "revoked"
    end
  end

  describe "AC3.2 — bound raw-JWT credentials of a revoked device" do
    test "are denylisted and the bindings deleted after the commit", %{priv: priv} do
      cid = T.oauth_client!([@https])
      sub = T.unique_sub()
      d = dev()
      s = device_session(cid, priv, sub, d)
      jwt = T.insert_jwt_binding!(priv, sub, s.user_id, d)
      assert T.binding_rows(s.user_id, d) == 1
      refute Nebu.Web.TokenDenylist.revoked?(nil, jwt)

      assert {:ok, %{devices: 1}} = revoke(cid)
      assert Nebu.Web.TokenDenylist.revoked?(nil, jwt), "the bound JWT is denylisted"
      assert T.binding_rows(s.user_id, d) == 0
    end
  end

  describe "AC3.3 / AC3.4 — nothing half-done: a failed audit or a failed teardown statement rolls EVERYTHING back" do
    # review finding: the post-commit part (JWT denylist + binding deletion) must NOT run for a rolled-back revocation
    defp bind_jwt!(priv, session) do
      jwt = T.insert_jwt_binding!(priv, session.sub, session.user_id, session.device_id)
      refute Nebu.Web.TokenDenylist.revoked?(nil, jwt)
      assert T.binding_rows(session.user_id, session.device_id) == 1
      jwt
    end

    defp assert_binding_untouched(jwt, session) do
      refute Nebu.Web.TokenDenylist.revoked?(nil, jwt), "a rolled-back revocation denylists nothing (the after-commit part never ran)"
      assert T.binding_rows(session.user_id, session.device_id) == 1, "and keeps the binding"
    end

    test "an audit function returning {:error, _} => {:error, {:audit, _}} and the world is unchanged", %{priv: priv} do
      f = fixture(priv)
      jwt = bind_jwt!(priv, hd(f.s))
      before = snapshot(f.a, f.users)

      assert {:error, {:audit, :boom}} = revoke(f.a, reason: "x", audit: fn _ -> {:error, :boom} end)
      assert snapshot(f.a, f.users) == before
      assert T.client_row(f.a)["status"] == "approved"
      assert T.whoami(hd(f.s).at).status == 200, "the session still works"
      assert_binding_untouched(jwt, hd(f.s))
    end

    test "an audit function that RAISES counts as a failed audit (rolled back)", %{priv: priv} do
      f = fixture(priv)
      jwt = bind_jwt!(priv, hd(f.s))
      before = snapshot(f.a, f.users)
      {result, _log} = with_log(fn -> revoke(f.a, audit: fn _ -> raise "audit store down" end) end)
      assert {:error, {:audit, _}} = result
      assert snapshot(f.a, f.users) == before
      assert_binding_untouched(jwt, hd(f.s))
    end

    test "a teardown DELETE failing on the LAST device => {:error, _}, no partial state, the WARNING names the error TYPE only", %{priv: priv} do
      f = fixture(priv)
      # the cascade tears the (user_id, device_id) pairs down in sorted order: block the user of the LAST pair, so the
      # devices before it were already deleted inside the transaction when the failure hits (a real partial rollback)
      {last_user, _last_device} = f.s |> Enum.map(&{&1.user_id, &1.device_id}) |> Enum.sort() |> List.last()
      first = f.s |> Enum.sort_by(&{&1.user_id, &1.device_id}) |> hd()
      assert first.user_id != last_user or length(Enum.filter(f.s, &(&1.user_id == last_user))) > 1
      jwt = bind_jwt!(priv, first)
      before = snapshot(f.a, f.users)
      remove = T.block_session_deletes!(last_user)

      {result, log} = with_log(fn -> revoke(f.a, reason: "secret-reason-text-4711") end)
      assert {:error, _} = result
      refute match?({:error, :not_approved}, result)
      assert snapshot(f.a, f.users) == before, "ALL of it rolled back: status, sessions, devices, keys, codes, requests, consents"
      assert_binding_untouched(jwt, first)
      refute log =~ "secret-reason-text-4711", "the reason text is never logged (CR12)"
      T.refute_secrets_in_log(log, %{at: hd(f.s).at, rt: hd(f.s).rt, at_hash: T.token_hash(hd(f.s).at)})

      # the failure is transient: once it is gone the same call succeeds
      remove.()
      assert {:ok, %{devices: 3}} = revoke(f.a)
      assert Nebu.Web.TokenDenylist.revoked?(nil, jwt), "after the real commit the binding is denylisted"
    end

    test "a device-table DELETE failing (keys of one device) rolls everything back as well", %{priv: priv} do
      f = fixture(priv)
      jwt = bind_jwt!(priv, hd(f.s))
      before = snapshot(f.a, f.users)
      _remove = T.block_deletes!("device_keys", hd(f.s).user_id)
      assert {:error, _} = revoke(f.a)
      assert snapshot(f.a, f.users) == before
      assert_binding_untouched(jwt, hd(f.s))
    end

    test "the unreachable session repo (seam) => {:error, _} and nothing changed", %{priv: priv} do
      f = fixture(priv)
      before = snapshot(f.a, f.users)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      {result, _log} = with_log(fn -> revoke(f.a) end)
      assert {:error, _} = result
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert snapshot(f.a, f.users) == before
    end
  end

  describe "CR4 — a deadlock victim is retried ONCE (review cycle 1, m2)" do
    defp deadlock, do: {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected, message: "atdd injected deadlock"}}}

    defp failing_hook(failures) do
      counter = :counters.new(1, [])

      T.put_env_scoped(:oauth_client_revoke_hook, fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) <= failures, do: deadlock(), else: :ok
      end)

      counter
    end

    test "one deadlock rolls the first attempt back and the second one succeeds, completely", %{priv: priv} do
      f = fixture(priv)
      counter = failing_hook(1)

      assert {:ok, %{devices: 3}} = revoke(f.a, reason: "retry")
      assert :counters.get(counter, 1) == 2, "exactly one retry"
      assert T.client_row(f.a)["status"] == "revoked"
      assert client_sessions(f.a) == 0
    end

    test "a persistent deadlock gives up after the retry: {:error, _}, the world is unchanged", %{priv: priv} do
      f = fixture(priv)
      before = snapshot(f.a, f.users)
      counter = failing_hook(5)

      {result, log} = with_log(fn -> revoke(f.a) end)
      assert {:error, %Postgrex.Error{}} = result
      assert :counters.get(counter, 1) == 2, "one retry, not a loop"
      assert snapshot(f.a, f.users) == before
      refute log =~ "atdd injected deadlock", "the driver message is never logged"
    end

    test "other errors are NOT retried", %{priv: priv} do
      f = fixture(priv)
      counter = :counters.new(1, [])

      T.put_env_scoped(:oauth_client_revoke_hook, fn ->
        :counters.add(counter, 1, 1)
        {:error, :something_else}
      end)

      assert {:error, :something_else} = revoke(f.a)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "AC3.5 — only an approved client can be revoked" do
    for status <- ["pending", "rejected"] do
      test "#{status} => {:error, :not_approved}, nothing changed" do
        cid = T.oauth_client!([@https], status: unquote(status))
        before = T.client_row(cid)

        assert {:error, :not_approved} = revoke(cid, reason: "again")
        assert T.client_row(cid) == before
        assert audit_rows("oauth_client_revoked", cid) == []
      end
    end

    test "an already revoked client => {:error, :not_approved}, nothing changed" do
      cid = T.oauth_client!([@https])
      :ok = T.mark_revoked!(cid, @admin, "first")
      before = T.client_row(cid)
      assert {:error, :not_approved} = revoke(cid, reason: "again")
      assert T.client_row(cid) == before
    end

    test "an unknown client id => {:error, :not_approved}" do
      assert {:error, :not_approved} = revoke("no-such-client-" <> T.rand())
    end

    test "a second revoke of the same client is refused and does not re-attribute", %{priv: priv} do
      cid = T.oauth_client!([@https])
      _ = device_session(cid, priv, T.unique_sub(), dev())
      assert {:ok, %{devices: 1}} = revoke(cid, actor: "@first:test.local", reason: "first")
      assert {:error, :not_approved} = revoke(cid, actor: "@second:test.local", reason: "second")
      row = T.client_row(cid)
      assert row["revoked_by"] == "@first:test.local" and row["revoked_reason"] == "first"
    end
  end

  describe "AC3.6 — scale" do
    test "200 devices of one client revoke in one call", %{priv: priv} do
      cid = T.oauth_client!([@https])
      uid = T.provision_user!()
      _ = priv

      for i <- 1..200 do
        assert {:ok, _} =
                 Nebu.Matrix.Session.OAuthSessionStore.insert_replacing_device(%{
                   access_token: T.rand(32),
                   refresh_token: T.rand(32),
                   user_id: uid,
                   device_id: "SC" <> Integer.to_string(i),
                   client_id: cid,
                   scope: T.matrix_scope(T.stable_prefix(), "SC" <> Integer.to_string(i)),
                   oauth_code_hash: nil,
                   idp_rt_enc: nil,
                   auth_time: nil,
                   access_ttl_seconds: 300,
                   session_ttl_seconds: 3600
                 })
      end

      assert client_sessions(cid) == 200
      {micros, result} = :timer.tc(fn -> revoke(cid) end)
      assert {:ok, %{devices: 200}} = result
      assert micros < 120_000_000, "inside the 120 s transaction timeout"
      assert client_sessions(cid) == 0
      assert T.sql!("SELECT count(*) FROM devices WHERE user_id = $1", [uid]).rows == [[0]]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — every entry point refuses a revoked client
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — entry points (CR6)" do
    setup %{priv: priv} do
      cid = T.oauth_client!([@https], client_name: "Entry Point App", client_uri: "https://app.example.com")
      s = device_session(cid, priv, T.unique_sub(), dev())
      pre_code = T.flow_code!(cid, @https, priv, sub: T.unique_sub())
      open_flow = T.start_flow(cid, @https)
      pending_consent = T.finish_flow(T.start_flow(cid, @https), priv)
      T.assert_consent_redirect(pending_consent)

      assert {:ok, %{devices: 1}} = revoke(cid, reason: "withdrawn")
      {:ok, cid: cid, s: s, pre_code: pre_code, open_flow: open_flow, pending_consent: pending_consent}
    end

    test "AC4.1 GET /oauth2/authorize => 403 client_rejected page, no redirect", %{cid: cid} do
      conn = T.authorize(T.authorize_params(cid, @https))
      T.assert_page(conn, 403, "client_rejected")
    end

    test "AC4.2 an authorize request created before the revoke: the IdP callback answers invalid_state (the row is gone)", %{priv: priv, open_flow: flow} do
      T.assert_page(T.finish_flow(flow, priv), 400, "invalid_state")
    end

    test "AC4.3 code grant with a pre-revoke code and refresh grant with the former refresh token => 401 invalid_client (RFC 6749 shape)", ctx do
      T.redeem(ctx.pre_code) |> T.assert_token_error(401, "invalid_client")
      T.refresh(ctx.cid, ctx.s.rt) |> T.assert_token_error(401, "invalid_client")
      # the code of the revoked client stays used
      assert Enum.all?(T.rows_for("oauth_codes", ctx.cid), &(&1["used_at"] != nil))
    end

    test "AC4.4 POST /oauth2/revoke with a former token => 200 {}, byte-identical to an unknown token", ctx do
      known = T.revoke(T.revoke_params(ctx.s.at)) |> T.assert_revoke_ok()
      unknown = T.revoke(T.revoke_params(T.rand(32))) |> T.assert_revoke_ok()
      assert known.resp_body == unknown.resp_body
      assert T.header(known, "content-type") == T.header(unknown, "content-type")
    end

    test "AC4.5 a Matrix request with the former access token => 401 M_UNKNOWN_TOKEN", ctx do
      T.assert_unknown_token(T.whoami(ctx.s.at), false)
      T.assert_unknown_token(T.sync(ctx.s.at), false)
    end

    test "the pending consent of the revoked client died with it: Allow => invalid_state, no code (row deleted); GET too", ctx do
      assert T.rows_for("oauth_consent_requests", ctx.cid) == []
      T.assert_page(T.consent_get(ctx.pending_consent), 400, "invalid_state")
      conn = T.consent!(ctx.pending_consent, :allow, get: false)
      T.assert_page(conn, 400, "invalid_state")
      assert Enum.all?(T.rows_for("oauth_codes", ctx.cid), &(&1["used_at"] != nil)), "no new live code"
    end

    test "a consent row that slipped in for a revoked client: GET and Allow => 403 client_rejected (like a rejected client), no code", %{cid: cid} do
      before = T.count_for("oauth_codes", cid)
      c = T.insert_consent!(cid, user_id: T.provision_user!())
      T.assert_page(T.consent_get(c.cookie), 403, "client_rejected")
      T.assert_page(T.consent!(c.cookie, :allow, get: false), 403, "client_rejected")
      assert T.count_for("oauth_codes", cid) == before, "no code was minted"
    end
  end

  describe "AC4.6 — DCR dedup on a revoked metadata hash" do
    test "identical metadata => 201 with the SAME client_id like a rejected hit; the row stays revoked, no new row, no audit; authorize => client_rejected" do
      body = T.web_body(%{"client_name" => "Revoked-Dedup-" <> T.rand()})
      first = T.register(body)
      assert first.status == 201
      cid = T.json(first)["client_id"]
      on_exit(fn -> T.cleanup_clients([cid]) end)

      T.sql!("UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = now(), source_key = NULL WHERE client_id = $1", [cid])
      assert {:ok, %{devices: 0}} = revoke(cid, reason: "withdrawn")
      hash = T.client_row(cid)["metadata_hash"]
      before = T.client_row(cid)
      audit_before = T.sql!("SELECT count(*) FROM audit_log WHERE target_id = $1", [cid]).rows

      again = T.register(body)
      assert again.status == 201, "answers like a rejected dedup hit: #{again.resp_body}"
      assert T.json(again)["client_id"] == cid

      assert T.client_row(cid) == before, "status stays revoked, attribution and reason untouched: never resurrected, never pending, never auto-approved"
      assert T.client_row(cid)["status"] == "revoked"
      assert T.count_by_hash(hash) == 1, "no new row"
      assert T.sql!("SELECT count(*) FROM audit_log WHERE target_id = $1", [cid]).rows == audit_before, "no audit row"
      T.assert_page(T.authorize(T.authorize_params(cid, "https://example.com/callback")), 403, "client_rejected")
    end

    test "CHANGED metadata is a new registration: pending, a different client_id, needs a new approval" do
      base = T.web_body(%{"client_name" => "Revoked-Changed-" <> T.rand()})
      cid = T.register(base) |> T.json() |> Map.fetch!("client_id")
      T.sql!("UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = now(), source_key = NULL WHERE client_id = $1", [cid])
      assert {:ok, _} = revoke(cid)

      changed = Map.put(base, "client_name", base["client_name"] <> "-v2")
      conn = T.register(changed)
      assert conn.status == 201
      new_id = T.json(conn)["client_id"]
      on_exit(fn -> T.cleanup_clients([cid, new_id]) end)
      refute new_id == cid
      assert T.client_row(new_id)["status"] == "pending"
      assert T.client_row(cid)["status"] == "revoked"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — operator RPC
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9.1 — Nebu.Release.revoke_oauth_client/2" do
    test "= AC3 behaviour, actor operator:rpc, audit with devices + reauth rpc (+ reason)", %{priv: priv} do
      f = fixture(priv)
      before_b = snapshot(f.b, [f.sb.user_id])

      assert {:ok, %{devices: 3}} = apply(Nebu.Release, :revoke_oauth_client, [f.a, "operator decision"])

      row = T.client_row(f.a)
      assert row["status"] == "revoked" and row["revoked_by"] == "operator:rpc" and row["revoked_reason"] == "operator decision"
      assert client_sessions(f.a) == 0
      for s <- f.s, do: assert(T.device_gone?(s.user_id, s.device_id))
      assert snapshot(f.b, [f.sb.user_id]) == before_b

      assert [[actor, metadata, "success", "oauth_client"]] = audit_rows("oauth_client_revoked", f.a)
      assert actor == "operator:rpc"
      assert metadata["devices"] == 3 and metadata["reauth"] == "rpc" and metadata["reason"] == "operator decision"
      refute inspect(metadata) =~ "Revoke Target", "never client metadata"
      refute inspect(metadata) =~ hd(f.s).user_id, "never user / device ids"
    end

    test "a nil reason is allowed (no reason key); not approved => {:error, :not_approved}, no audit row" do
      cid = T.oauth_client!([@https])
      assert {:ok, %{devices: 0}} = apply(Nebu.Release, :revoke_oauth_client, [cid, nil])
      assert [[_, metadata, _, _]] = audit_rows("oauth_client_revoked", cid)
      refute Map.has_key?(metadata, "reason")

      assert {:error, :not_approved} = apply(Nebu.Release, :revoke_oauth_client, [cid, "again"])
      assert length(audit_rows("oauth_client_revoked", cid)) == 1

      pending = T.oauth_client!([@https], status: "pending")
      assert {:error, :not_approved} = apply(Nebu.Release, :revoke_oauth_client, [pending, nil])
      assert {:error, :not_approved} = apply(Nebu.Release, :revoke_oauth_client, ["no-such-" <> T.rand(), nil])
    end

    test "the audit write is part of the transaction: a failing audit writer rolls the revocation back", %{priv: priv} do
      cid = T.oauth_client!([@https])
      s = device_session(cid, priv, T.unique_sub(), dev())

      Application.put_env(:compliance, :audit_writer, Nebu.OAuth.OAuthClientRevocationTest.FailingAudit)
      {result, _log} = with_log(fn -> apply(Nebu.Release, :revoke_oauth_client, [cid, nil]) end)
      assert {:error, _} = result
      assert T.client_row(cid)["status"] == "approved"
      assert T.whoami(s.at).status == 200
    end
  end

  describe "AC9.2 — Nebu.Release.revoke_all_oauth_sessions/0" do
    test "ends every OAuth device (several clients), clients stay approved, legacy sessions/devices untouched, ONE audit row, second call {:ok, 0}", %{priv: priv} do
      a = T.oauth_client!([@https])
      b = T.oauth_client!(["https://other.example.com/cb"], client_uri: "https://other.example.com")
      s1 = device_session(a, priv, T.unique_sub(), dev())
      s2 = T.session!(b, "https://other.example.com/cb", priv, sub: T.unique_sub(), authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      T.seed_device_keys!(s1.user_id, s1.device_id)

      legacy_uid = T.provision_user!()
      legacy_dev = dev()
      legacy = T.legacy_session!(legacy_uid, legacy_dev)
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(legacy_uid, legacy_dev, last_seen_ts: System.system_time(:millisecond))
      legacy_before = T.world_snapshot([legacy_uid])

      audits_before = T.sql!("SELECT count(*) FROM audit_log WHERE action = 'oauth_sessions_revoked_all'").rows

      assert {:ok, n} = apply(Nebu.Release, :revoke_all_oauth_sessions, [])
      assert is_integer(n) and n >= 2

      T.assert_unknown_token(T.whoami(s1.at), false)
      T.assert_unknown_token(T.whoami(s2.at), false)
      assert T.device_gone?(s1.user_id, s1.device_id)
      assert client_sessions(a) == 0 and client_sessions(b) == 0
      assert T.client_row(a)["status"] == "approved" and T.client_row(b)["status"] == "approved", "clients stay approved (they may sign in again)"
      assert T.world_snapshot([legacy_uid]) == legacy_before, "the legacy session and device are untouched"
      assert T.whoami(legacy.at).status == 200

      %{rows: [[audits_after]]} = T.sql!("SELECT count(*) FROM audit_log WHERE action = 'oauth_sessions_revoked_all'")
      assert audits_after == hd(hd(audits_before)) + 1, "exactly ONE audit row for the run"

      %{rows: [[metadata]]} = T.sql!("SELECT metadata FROM audit_log WHERE action = 'oauth_sessions_revoked_all' ORDER BY id DESC LIMIT 1")
      assert metadata["devices"] == n

      assert {:ok, 0} = apply(Nebu.Release, :revoke_all_oauth_sessions, [])
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 — logging law
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11 — logging" do
    test "a successful revoke logs no token, hash, reason text or client metadata", %{priv: priv} do
      # the test env logs at :warning; admit :debug so the capture sees every line the revocation could emit
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)
      f = fixture(priv)
      [s1 | _] = f.s

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{devices: 3}} = revoke(f.a, reason: "confidential-reason-9981", audit: fn _ -> :ok end)
          _ = apply(Nebu.Release, :revoke_oauth_client, [f.b, "another-confidential-reason"])
        end)

      T.refute_secrets_in_log(log, %{
        at: s1.at,
        rt: s1.rt,
        at_hash: T.token_hash(s1.at),
        rotated_at: f.rotated["access_token"],
        rotated_rt: f.rotated["refresh_token"],
        code: f.unused.code,
        reason: "confidential-reason-9981",
        reason2: "another-confidential-reason",
        name: "Revoke Target",
        idp_rt: s1.idp_rt
      })
    end
  end
end

defmodule Nebu.OAuth.OAuthClientRevocationTest.FailingAudit do
  @moduledoc false
  def log(_actor, _action, _type, _id, _metadata, _outcome, _error_detail \\ nil), do: {:error, :audit_down}
end
