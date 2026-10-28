defmodule Nebu.OAuth.OAuthSigningKeyRotationTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-hardening-hygiene`, AC9-AC12
  (HY4, HY11-HY14): the supervised cache owner, migration-000047-backed pre-published signing key, the
  two-phase `Nebu.Release.rotate_oauth_signing_key/0` and `Nebu.Release.replace_oauth_signing_key(:emergency)`.

  ## Contracts pinned here

    * `Nebu.OAuth.CacheOwner` (child id `Nebu.OAuth.CacheOwner` of `Nebu.Supervisor`, started after `Nebu.Repo`,
      before Bandit) owns the public named tables `:nebu_oauth_config_cache` and `:nebu_oauth_signing_key_cache`.
      Restart => empty tables. Table absent => requests read through, never create a table.
    * `Nebu.Release.rotate_oauth_signing_key/0`:
        call 1 (no `next` row) => `{:ok, {:published, kid, activate_after_iso8601}}` (the key is inserted `next`);
        call 2 with a loadable `next` row older than 900 s => `{:ok, {:activated, new_kid, retired_kid}}`
        (active retired with `not_after = now() + 900 s`, next promoted, ONE transaction);
        too early => `{:error, {:too_early, seconds_left}}`, no change;
        a `next` row that does not load (decrypt / thumbprint / public part) => `{:error, :next_key_unavailable}`;
        lost race (another call changed the `next` row while this one waited for the rotation advisory lock) => `{:error, :conflict}`.
    * `Nebu.Release.replace_oauth_signing_key(:emergency)` => `{:ok, {:replaced, new_kid, old_kid}}` (old active
      retired with `not_after = now() + 900 s`, any `next` row retired, a fresh active key inserted, one
      transaction); any other argument (also none) => `{:error, :confirmation_required}`, no change.
    * Audit rows (`audit_log`, actor `operator:rpc`, target_type `oauth_signing_key`, target_id = the NEW kid;
      actions `oauth_signing_key_published` / `oauth_signing_key_rotated` / `oauth_signing_key_replaced`); the
      metadata holds kids only (every value is one of the kids involved).
    * No key material anywhere: no `"d":` member, no ciphertext, no `%JOSE.JWK{}` in a log line or a result.

  The 900 s promotion rule is enforced by the DATABASE (migration 000047): the guard trigger forbids a
  `next -> active` of a row younger than 900 s; created_at is immutable, so aged rows are INSERTED backdated.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @release Nebu.Release
  @store Nebu.OAuth.SigningKeyStore
  @owner Nebu.OAuth.CacheOwner
  @https "https://app.example.com/cb"
  @test_secret "oauth-authz-test-key"
  @key_cache :nebu_oauth_signing_key_cache
  @config_cache :nebu_oauth_config_cache

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.reset_signing_keys!()

    prior_writer = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)
    secret = Application.get_env(:nebu_http, :admin_secret_at_rest)
    # audit_log is append-only: every test only looks at the rows written after its own start
    %{rows: [[floor]]} = T.sql!("SELECT coalesce(max(id), 0) FROM audit_log")
    Process.put(:audit_floor, floor)

    on_exit(fn ->
      T.reset_signing_keys!()
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.put_env(:nebu_http, :admin_secret_at_rest, secret)

      case prior_writer do
        {:ok, writer} -> Application.put_env(:compliance, :audit_writer, writer)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end

      case Supervisor.restart_child(Nebu.Supervisor, @owner) do
        {:ok, _} -> :ok
        {:ok, _, _} -> :ok
        {:error, _} -> :ok
      end

      Application.delete_env(:nebu_http, :oauth_repo)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  # ── helpers (never print key material) ─────────────────────────────────────

  defp ensure_active! do
    case apply(@store, :ensure_active_key, []) do
      {:ok, %{kid: kid}} when is_binary(kid) -> kid
      {:error, reason} -> flunk("ensure_active_key/0 failed: #{inspect(reason)}")
    end
  end

  defp rotate, do: apply(@release, :rotate_oauth_signing_key, [])

  defp rows, do: T.signing_key_rows()
  defp status_of(kid), do: Enum.find_value(rows(), fn r -> if r["kid"] == kid, do: r["status"] end)
  defp row_of(kid), do: Enum.find(rows(), &(&1["kid"] == kid))

  defp new_key do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pub} = JOSE.JWK.to_public_map(jwk)
    {_, priv} = JOSE.JWK.to_map(jwk)
    %{kid: JOSE.JWK.thumbprint(jwk), pub: pub, priv_json: Jason.encode!(priv)}
  end

  # A loadable `next` row. created_at is immutable (guard trigger), so an aged row is inserted backdated.
  defp insert_next!(created_sql, opts \\ []) do
    k = new_key()
    enc = Keyword.get(opts, :enc, Nebu.Web.SecretBox.encrypt(k.priv_json))

    T.privileged_sql!(
      "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status, created_at) " <>
        "VALUES ($1, 'ES256', $2::text::jsonb, $3, 'next', #{created_sql})",
      [k.kid, Jason.encode!(k.pub), enc]
    )

    k.kid
  end

  defp jwks_kids, do: T.jwks_keys!() |> Enum.map(& &1["kid"])

  defp seconds_until_not_after(kid) do
    %{rows: [[s]]} = T.sql!("SELECT extract(epoch FROM (not_after - now()))::float8 FROM oauth_signing_keys WHERE kid = $1", [kid])
    s
  end

  defp audit(action) do
    %{rows: rows} =
      T.sql!(
        "SELECT actor_user_id, target_type, target_id, metadata, outcome FROM audit_log WHERE action = $1 AND id > $2 ORDER BY id DESC",
        [action, Process.get(:audit_floor, 0)]
      )

    rows
  end

  defp issue_id_token_kid(cid, priv) do
    grant = T.flow_code!(cid, @https, priv, authorize: %{"scope" => T.js_sdk_scope(), "nonce" => "n-" <> T.rand()})
    body = T.redeem!(grant)
    assert is_binary(body["id_token"]), "an openid scope yields an id_token"
    T.jws_header(body["id_token"])["kid"]
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — supervised cache owner
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9.1 — Nebu.OAuth.CacheOwner is a supervised child that owns both tables" do
    test "child of Nebu.Supervisor; both public named tables exist after boot and are owned by its pid" do
      children = Supervisor.which_children(Nebu.Supervisor)
      assert {@owner, pid, :worker, _} = List.keyfind(children, @owner, 0), "CacheOwner must be a child of Nebu.Supervisor"
      assert is_pid(pid)

      for table <- [@config_cache, @key_cache] do
        assert :ets.info(table, :owner) == pid, "#{table} must be owned by the CacheOwner"
        assert :ets.info(table, :protection) == :public
        assert :ets.info(table, :named_table) == true
      end

      assert :ets.info(@config_cache, :read_concurrency) == true
    end

    test "started after Nebu.Repo and before Bandit (children list is in reverse start order)" do
      ids = Supervisor.which_children(Nebu.Supervisor) |> Enum.map(&elem(&1, 0))
      owner_at = Enum.find_index(ids, &(&1 == @owner))
      repo_at = Enum.find_index(ids, &(&1 == Nebu.Repo))
      bandit_at = Enum.find_index(ids, &(&1 == Bandit or match?({Bandit, _}, &1)))

      assert owner_at && repo_at && bandit_at, "owner=#{inspect(owner_at)} repo=#{inspect(repo_at)} bandit=#{inspect(bandit_at)}"
      assert bandit_at < owner_at, "Bandit must be started AFTER the owner"
      assert owner_at < repo_at, "the owner must be started AFTER the Repo"
    end

    test "killing a request process that loaded a key leaves the signing-key cache intact" do
      kid = ensure_active_key_in_a_dying_process()

      assert :ets.whereis(@key_cache) != :undefined, "the table must survive the request process"
      # (only "a row for the kid exists": the row layout is the store's business)
      assert [_ | _] = :ets.lookup(@key_cache, kid), "the decoded key stays cached after the loading process died"
    end

    test "killing the owner restarts it under the supervisor with EMPTY tables; signing keeps working" do
      kid = ensure_active_key_in_a_dying_process()
      assert [_ | _] = :ets.lookup(@key_cache, kid)

      {_, old_pid, _, _} = List.keyfind(Supervisor.which_children(Nebu.Supervisor), @owner, 0)
      sup = Process.whereis(Nebu.Supervisor)
      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}, 2_000

      new_pid = await_new_owner(old_pid)
      assert Process.whereis(Nebu.Supervisor) == sup, "the application supervisor survives"
      assert :ets.info(@key_cache, :owner) == new_pid
      assert :ets.info(@config_cache, :owner) == new_pid
      assert :ets.tab2list(@key_cache) == [], "a restart starts with empty tables"
      assert :ets.tab2list(@config_cache) == []

      assert ensure_active!() == kid
      assert [_ | _] = :ets.lookup(@key_cache, kid), "the new owner's table is used again"
    end
  end

  # The key is loaded in a request-like process that is DEAD (monitored: its :DOWN was received) before the caller
  # looks at the table.
  defp ensure_active_key_in_a_dying_process do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:loaded, apply(@store, :ensure_active_key, [])}) end)

    assert_receive {:loaded, {:ok, %{kid: kid}}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    kid
  end

  # `:sys.get_state/1` is a synchronous call to the supervisor: it returns only after the supervisor has handled
  # the child's EXIT and restarted it, so no sleeping is needed (bounded retry as a safety net).
  defp await_new_owner(old_pid, tries \\ 200) do
    _ = :sys.get_state(Nebu.Supervisor)

    case List.keyfind(Supervisor.which_children(Nebu.Supervisor), @owner, 0) do
      {@owner, pid, :worker, _} when is_pid(pid) and pid != old_pid ->
        pid

      _ when tries > 0 ->
        await_new_owner(old_pid, tries - 1)

      _ ->
        flunk("the CacheOwner was not restarted by its supervisor")
    end
  end

  describe "AC9.2 — owner absent: signing works uncached, no table is created by a request" do
    test "ensure_active_key/0 and published_keys/0 work without the owner" do
      assert :ok = Supervisor.terminate_child(Nebu.Supervisor, @owner)
      assert :ets.whereis(@key_cache) == :undefined

      kid = ensure_active!()
      assert {:ok, [%{"kid" => ^kid}]} = apply(@store, :published_keys, [])
      assert T.jwks_keys!() |> Enum.map(& &1["kid"]) == [kid]

      assert :ets.whereis(@key_cache) == :undefined, "a request process must never create the cache table"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 — rotation tool
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11.1 — call 1 publishes the next key" do
    test "returns {:ok, {:published, kid, iso8601}}; the row is `next`; the active key is unchanged", %{cid: _cid} do
      active = ensure_active!()
      assert {:ok, {:published, next, after_iso}} = rotate()

      assert is_binary(next) and next != active
      assert status_of(next) == "next"
      assert status_of(active) == "active"
      assert {:ok, activate_after, 0} = DateTime.from_iso8601(after_iso)
      delta = DateTime.diff(activate_after, DateTime.utc_now())
      assert delta in 880..905, "activate_after is ~900 s from now, got #{delta} s"
    end

    test "JWKS lists the active key first, then the next key (both use: sig, alg: ES256)" do
      active = ensure_active!()
      {:ok, {:published, next, _}} = rotate()

      keys = T.jwks_keys!()
      assert Enum.map(keys, & &1["kid"]) == [active, next]
      for k <- keys, do: assert(k["use"] == "sig" and k["alg"] == "ES256" and k["kty"] == "EC")
      for k <- keys, do: refute(Map.has_key?(k, "d"), "JWKS must never carry the private member")
    end

    test "id_tokens are still signed with the ACTIVE key after call 1", %{cid: cid, priv: priv} do
      active = ensure_active!()
      {:ok, {:published, _next, _}} = rotate()
      assert issue_id_token_kid(cid, priv) == active
    end
  end

  describe "AC11.2 — call 2" do
    test "before 900 s => {:error, {:too_early, s}} and NOTHING changes" do
      active = ensure_active!()
      {:ok, {:published, next, _}} = rotate()
      before = rows()

      assert {:error, {:too_early, secs}} = rotate()
      assert is_integer(secs) and secs > 0 and secs <= 900
      assert rows() == before
      assert status_of(active) == "active" and status_of(next) == "next"
      assert audit("oauth_signing_key_rotated") == []
    end

    test "after 900 s (backdated row) => {:ok, {:activated, new, old}}: next promoted, old retired with not_after ~ now + 900 s" do
      old = ensure_active!()
      new = insert_next!("now() - interval '901 seconds'")

      assert {:ok, {:activated, ^new, ^old}} = rotate()

      assert status_of(new) == "active"
      assert status_of(old) == "retired"
      retired = row_of(old)
      assert retired["retired_at"] != nil
      assert seconds_until_not_after(old) |> then(&(&1 > 895 and &1 < 905)), "old not_after within now() + 900 s +- 5 s"
    end

    test "after activation the token endpoint signs with the NEW kid; JWKS lists new, then old", %{cid: cid, priv: priv} do
      old = ensure_active!()
      new = insert_next!("now() - interval '901 seconds'")
      assert {:ok, {:activated, ^new, ^old}} = rotate()

      assert issue_id_token_kid(cid, priv) == new
      assert jwks_kids() == [new, old]
    end

    test "published_keys/0 / JWKS: active first, then next, then retired keys with not_after > now() (an expired retired key is not published)" do
      active = ensure_active!()
      next = insert_next!("now() - interval '10 seconds'")
      live_retired = insert_retired!("now() + interval '10 minutes'")
      _expired_retired = insert_retired!("now() - interval '1 minute'")

      assert jwks_kids() == [active, next, live_retired]
      assert {:ok, keys} = apply(@store, :published_keys, [])
      assert Enum.map(keys, & &1["kid"]) == [active, next, live_retired]
    end

    test "a call after an activation (no next row) is call 1 again: it publishes a fresh next key" do
      _old = ensure_active!()
      new = insert_next!("now() - interval '901 seconds'")
      assert {:ok, {:activated, ^new, _}} = rotate()
      assert {:ok, {:published, next2, _}} = rotate()
      refute next2 == new
      assert status_of(next2) == "next"
      assert status_of(new) == "active"
    end
  end

  # a retired row (privileged insert: the runtime role can only INSERT active / next rows)
  defp insert_retired!(not_after_sql) do
    k = new_key()

    T.privileged_sql!(
      "INSERT INTO oauth_signing_keys (kid, alg, public_jwk, private_jwk_enc, status, retired_at, not_after, created_at) " <>
        "VALUES ($1, 'ES256', $2::text::jsonb, $3, 'retired', now(), #{not_after_sql}, now() - interval '3 hours')",
      [k.kid, Jason.encode!(k.pub), Nebu.Web.SecretBox.encrypt(k.priv_json)]
    )

    k.kid
  end

  describe "AC11.3 — a next row that does not load" do
    test "garbage ciphertext => {:error, :next_key_unavailable}, no change" do
      active = ensure_active!()
      nxt = insert_next!("now() - interval '901 seconds'", enc: String.duplicate("ab", 64))
      before = rows()

      assert {:error, :next_key_unavailable} = rotate()
      assert rows() == before
      assert status_of(active) == "active" and status_of(nxt) == "next"
      assert audit("oauth_signing_key_rotated") == []
    end

    test "a ciphertext swapped from another key (thumbprint mismatch) => {:error, :next_key_unavailable}" do
      ensure_active!()
      other = new_key()
      nxt = insert_next!("now() - interval '901 seconds'", enc: Nebu.Web.SecretBox.encrypt(other.priv_json))
      before = rows()

      assert {:error, :next_key_unavailable} = rotate()
      assert rows() == before
      assert status_of(nxt) == "next"
    end

    test "a ciphertext written under a different secret => {:error, :next_key_unavailable}" do
      ensure_active!()
      Application.put_env(:nebu_http, :admin_secret_at_rest, "another-secret-" <> T.rand())
      nxt = insert_next!("now() - interval '901 seconds'")
      Application.put_env(:nebu_http, :admin_secret_at_rest, @test_secret)
      # the active key was written under the test secret: restore it and the next row is the undecryptable one
      before = rows()

      assert {:error, :next_key_unavailable} = rotate()
      assert rows() == before
      assert status_of(nxt) == "next"
    end

    test "too early wins over an undecryptable row only in the documented order: a young garbage row is {:too_early, _}" do
      ensure_active!()
      insert_next!("now() - interval '10 seconds'", enc: String.duplicate("ab", 64))
      assert {:error, {:too_early, _}} = rotate()
    end
  end

  describe "AC11.4 — two concurrent invocations (the rotation lock is an advisory lock)" do
    # The overlap is FORCED: a privileged transaction holds the rotation advisory lock, both callers are started and
    # take their snapshot of the `next` row, the test waits until both are blocked on the lock, then releases it.
    # The winner proceeds; the loser finds the `next` row in a different state than it saw => `:conflict`, no change.
    defp with_rotation_lock_held(fun) do
      T.with_privileged_conn(fn conn ->
        {:ok, tasks} =
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, "SELECT pg_advisory_xact_lock(hashtext('nebu_oauth_signing_key_rotation'))", [])
            tasks = fun.()
            await_blocked(tx, 2)
            tasks
          end)

        Task.await_many(tasks, 30_000)
      end)
    end

    test "call 2 twice: exactly one :activated, the loser is EXACTLY {:error, :conflict}; one active key, one rotation audit row" do
      old = ensure_active!()
      new = insert_next!("now() - interval '901 seconds'")

      results = with_rotation_lock_held(fn -> Enum.map(1..2, fn _ -> Task.async(fn -> rotate() end) end) end)

      assert [{:ok, {:activated, ^new, ^old}}, {:error, :conflict}] = Enum.sort_by(results, &elem(&1, 0), :desc),
             "got #{inspect(results)}"

      %{rows: [[active_count]]} = T.sql!("SELECT count(*) FROM oauth_signing_keys WHERE status = 'active'")
      assert active_count == 1
      assert status_of(new) == "active"
      assert status_of(old) == "retired"
      %{rows: [[0]]} = T.sql!("SELECT count(*) FROM oauth_signing_keys WHERE status = 'next'")
      assert length(audit("oauth_signing_key_rotated")) == 1, "only the winner writes the rotation audit row"
    end

    test "call 1 twice: exactly one :published, the loser is EXACTLY {:error, :conflict}; one next key" do
      ensure_active!()

      results = with_rotation_lock_held(fn -> Enum.map(1..2, fn _ -> Task.async(fn -> rotate() end) end) end)

      assert [{:error, :conflict}, {:ok, {:published, next, _}}] = Enum.sort_by(results, &elem(&1, 0))
      assert status_of(next) == "next"
      %{rows: [[1]]} = T.sql!("SELECT count(*) FROM oauth_signing_keys WHERE status = 'next'")
      assert length(audit("oauth_signing_key_published")) == 1
    end

    test "a call that starts AFTER the other one committed is an ordinary new call (no conflict)" do
      ensure_active!()
      assert {:ok, {:published, first, _}} = rotate()
      assert {:error, {:too_early, _}} = rotate()
      assert status_of(first) == "next"
    end
  end

  # waits (bounded) until `n` callers are queued behind the transaction's advisory lock
  defp await_blocked(tx, n, tries \\ 400) do
    %{rows: [[blocked]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype = 'advisory'", [])

    cond do
      blocked >= n ->
        :ok

      tries == 0 ->
        flunk("the two rotation calls never blocked on the rotation lock (#{blocked} waiting)")

      true ->
        receive do
        after
          25 -> await_blocked(tx, n, tries - 1)
        end
    end
  end

  describe "AC11.5 — audit rows and the logging law" do
    test "call 1 writes oauth_signing_key_published, call 2 oauth_signing_key_rotated (actor operator:rpc, target oauth_signing_key, kids only)" do
      old = ensure_active!()
      assert {:ok, {:published, published, _}} = rotate()

      assert [[actor, "oauth_signing_key", target_id, metadata, "success"]] = audit("oauth_signing_key_published")
      assert actor == "operator:rpc"
      assert target_id == published
      assert kids_only?(metadata, [published, old])
      assert published in metadata_values(metadata)

      # age the key: replace it by a backdated one (created_at is immutable)
      T.reset_signing_keys!()
      old2 = ensure_active!()
      new2 = insert_next!("now() - interval '901 seconds'")
      assert {:ok, {:activated, ^new2, ^old2}} = rotate()

      assert [[actor2, "oauth_signing_key", target2, metadata2, "success"]] = audit("oauth_signing_key_rotated")
      assert actor2 == "operator:rpc"
      assert target2 == new2
      assert kids_only?(metadata2, [new2, old2])
      assert new2 in metadata_values(metadata2) and old2 in metadata_values(metadata2)
    end

    test "a too-early / failed call writes no success audit row" do
      ensure_active!()
      {:ok, {:published, _, _}} = rotate()
      before = length(audit("oauth_signing_key_rotated")) + length(audit("oauth_signing_key_published"))
      assert {:error, {:too_early, _}} = rotate()
      assert length(audit("oauth_signing_key_rotated")) + length(audit("oauth_signing_key_published")) == before
    end

    test "no key material in the log, the audit rows or the results (no `\"d\":`, no ciphertext, no JWK struct)" do
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      {{results, ds}, log} =
        with_log(fn ->
          old = ensure_active!()
          r1 = rotate()
          r_early = rotate()
          ds1 = private_d_values()
          T.reset_signing_keys!()
          old2 = ensure_active!()
          new2 = insert_next!("now() - interval '901 seconds'")
          r2 = rotate()
          insert_next!("now() - interval '901 seconds'", enc: String.duplicate("cd", 64))
          r_bad = rotate()
          {[old, r1, r_early, old2, new2, r2, r_bad], ds1 ++ private_d_values()}
        end)

      ciphertexts = T.signing_key_rows() |> Enum.map(& &1["private_jwk_enc"])
      refute log =~ ~r/"d"\s*(:|=>)/, "a private JWK member reached the log"
      refute log =~ "%JOSE.JWK{"
      for enc <- ciphertexts, do: refute(String.contains?(log, enc), "a ciphertext reached the log")

      text = inspect(results)
      refute text =~ ~r/"d"\s*(:|=>)/
      refute text =~ "%JOSE.JWK{"
      for enc <- ciphertexts, do: refute(String.contains?(text, enc))

      assert ds != [], "the test must have private values to look for"
      for d <- ds, do: refute(String.contains?(log, d) or String.contains?(text, d), "the decoded private key value leaked")

      for table <- ["oauth_signing_key_published", "oauth_signing_key_rotated"], [_, _, _, metadata, _] <- audit(table) do
        for enc <- ciphertexts, do: refute(String.contains?(inspect(metadata), enc))
        for d <- ds, do: refute(String.contains?(inspect(metadata), d))
      end
    end
  end

  # the base64url `d` member of every signing-key row that decrypts under the CURRENT secret (test helper only)
  defp private_d_values do
    for r <- T.signing_key_rows(),
        {:ok, plain} <- [Nebu.Web.SecretBox.decrypt(r["private_jwk_enc"])],
        {:ok, %{"d" => d}} <- [Jason.decode(plain)],
        do: d
  end

  defp metadata_values(metadata), do: metadata |> Map.values() |> List.flatten()

  # every metadata value is a kid of the keys involved: no other data, no key material
  defp kids_only?(metadata, kids) when is_map(metadata), do: Enum.all?(metadata_values(metadata), &(&1 in kids))

  # ════════════════════════════════════════════════════════════════════════════
  # AC12 — emergency replacement
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12.1 — replace_oauth_signing_key(:emergency)" do
    setup %{priv: _priv} do
      old = ensure_active!()
      ds = private_d_values()
      # the secret changes: the active key's ciphertext was written under another secret
      Application.put_env(:nebu_http, :admin_secret_at_rest, "rotated-secret-" <> T.rand())
      # the per-node cache holds the DECODED key (keyed by kid + ciphertext); a restarted node would not have it
      if :ets.whereis(@key_cache) != :undefined, do: :ets.delete_all_objects(@key_cache)
      {:ok, old: old, ds: ds}
    end

    test "the undecryptable active key stays :key_unavailable (unchanged), emergency replaces it, signing works again", %{old: old, cid: cid, priv: priv} do
      assert {:error, :key_unavailable} = apply(@store, :ensure_active_key, [])

      assert {:ok, {:replaced, new, ^old}} = apply(@release, :replace_oauth_signing_key, [:emergency])
      assert is_binary(new) and new != old
      assert status_of(new) == "active"
      assert status_of(old) == "retired"
      assert seconds_until_not_after(old) |> then(&(&1 > 895 and &1 < 905)), "not_after = now() + 900 s: the PUBLIC key still verifies old id_tokens"

      assert ensure_active!() == new
      assert issue_id_token_kid(cid, priv) == new
      assert jwks_kids() == [new, old], "the old public key stays in JWKS until not_after"
    end

    test "an existing next row is retired too; the replacement is never promoted from it", %{old: old} do
      nxt = insert_next!("now() - interval '901 seconds'", enc: String.duplicate("ab", 64))

      assert {:ok, {:replaced, new, ^old}} = apply(@release, :replace_oauth_signing_key, [:emergency])
      refute new == nxt, "a next row (possibly undecryptable under the same secret change) is never promoted"
      assert status_of(nxt) == "retired"
      assert row_of(nxt)["retired_at"] != nil
      assert status_of(new) == "active"
      %{rows: [[0]]} = T.sql!("SELECT count(*) FROM oauth_signing_keys WHERE status = 'next'")
    end

    test "writes ONE oauth_signing_key_replaced audit row (operator:rpc, target = the new kid, kids only)", %{old: old} do
      assert {:ok, {:replaced, new, ^old}} = apply(@release, :replace_oauth_signing_key, [:emergency])

      assert [[actor, "oauth_signing_key", target_id, metadata, "success"]] = audit("oauth_signing_key_replaced")
      assert actor == "operator:rpc"
      assert target_id == new
      assert kids_only?(metadata, [new, old])
      assert new in metadata_values(metadata) and old in metadata_values(metadata)
    end

    test "no key material in the log or the result", %{old: _old, ds: ds} do
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      {result, log} = with_log(fn -> apply(@release, :replace_oauth_signing_key, [:emergency]) end)
      refute log =~ ~r/"d"\s*(:|=>)/
      refute inspect(result) =~ ~r/"d"\s*(:|=>)/
      assert ds != []
      for d <- ds ++ private_d_values(), do: refute(String.contains?(log, d) or String.contains?(inspect(result), d), "a private key value leaked")
      for enc <- T.signing_key_rows() |> Enum.map(& &1["private_jwk_enc"]), do: refute(String.contains?(log, enc))
    end
  end

  describe "AC12.2 — confirmation is required" do
    test ":yes, other atoms, strings and no argument => {:error, :confirmation_required}, nothing changes" do
      active = ensure_active!()
      before = rows()

      for arg <- [:yes, :confirm, :EMERGENCY, "emergency", true, nil, 1] do
        assert {:error, :confirmation_required} = apply(@release, :replace_oauth_signing_key, [arg]), "argument #{inspect(arg)}"
      end

      assert {:error, :confirmation_required} = apply(@release, :replace_oauth_signing_key, [])
      assert rows() == before
      assert status_of(active) == "active"
      assert audit("oauth_signing_key_replaced") == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Atomicity (test review M5): a failing statement or audit write rolls the whole step back
  # ════════════════════════════════════════════════════════════════════════════

  # a privileged BEFORE trigger on oauth_signing_keys that fails every row matching `when_sql`
  defp inject_failure!(event, when_sql) do
    name = "atdd_sk_fail_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'atdd: write blocked'; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE #{event} ON oauth_signing_keys FOR EACH ROW WHEN (#{when_sql}) EXECUTE FUNCTION #{name}()")

    on_exit(fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON oauth_signing_keys")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end)
  end

  defmodule FailingAuditWriter do
    @moduledoc false
    def log(_actor, _action, _target_type, _target_id, _metadata, _outcome, _detail), do: {:error, :atdd_audit_down}
  end

  describe "atomicity of the rotation steps" do
    test "call 2: a failing promote UPDATE rolls the retire of the old key back too; no audit row" do
      old = ensure_active!()
      nxt = insert_next!("now() - interval '901 seconds'")
      before = rows()
      inject_failure!("UPDATE", "NEW.status = 'active' AND OLD.status = 'next'")

      assert {:error, reason} = rotate()
      assert reason in [:storage, :conflict], "got #{inspect(reason)}"

      assert rows() == before, "the failed promotion must leave every row as it was (the old key still active)"
      assert status_of(old) == "active" and status_of(nxt) == "next"
      assert audit("oauth_signing_key_rotated") == []
      assert ensure_active!() == old, "signing keeps working with the old key"
    end

    test "call 1: a failing INSERT of the next key leaves no row and no audit row" do
      old = ensure_active!()
      before = rows()
      inject_failure!("INSERT", "NEW.status = 'next'")

      assert {:error, reason} = rotate()
      assert reason in [:storage, :conflict]
      assert rows() == before
      assert status_of(old) == "active"
      assert audit("oauth_signing_key_published") == []
    end

    test "call 2: a failing audit write rolls the promotion back (an unaudited rotation never commits)" do
      old = ensure_active!()
      nxt = insert_next!("now() - interval '901 seconds'")
      before = rows()
      Application.put_env(:compliance, :audit_writer, FailingAuditWriter)

      assert {:error, {:audit, _}} = rotate()
      assert rows() == before
      assert status_of(old) == "active" and status_of(nxt) == "next"
    end

    test "emergency replacement: a failing INSERT of the new active key rolls the retirements back; no audit row" do
      old = ensure_active!()
      nxt = insert_next!("now() - interval '901 seconds'", enc: String.duplicate("ab", 64))
      Application.put_env(:nebu_http, :admin_secret_at_rest, "rotated-secret-" <> T.rand())
      before = rows()
      inject_failure!("INSERT", "NEW.status = 'active'")

      assert {:error, reason} = apply(@release, :replace_oauth_signing_key, [:emergency])
      assert reason in [:storage, :conflict]
      assert rows() == before, "the old active key and the next row stay exactly as they were"
      assert status_of(old) == "active" and status_of(nxt) == "next"
      assert audit("oauth_signing_key_replaced") == []
    end

    test "emergency replacement: a failing audit write rolls everything back" do
      old = ensure_active!()
      before = rows()
      Application.put_env(:compliance, :audit_writer, FailingAuditWriter)

      assert {:error, {:audit, _}} = apply(@release, :replace_oauth_signing_key, [:emergency])
      assert rows() == before
      assert status_of(old) == "active"
    end
  end
end
