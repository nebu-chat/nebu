defmodule Nebu.OAuth.OAuthCodeStoreTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC9 (code consumption
  API for story 3, D17) and AC11 (purge of expired flow state, `Nebu.Workers.OAuthFlowPurgeWorker`).

  Codes and authorization requests are inserted DIRECTLY (runtime role, migration 000041 RLS
  allows INSERT of unused codes) with explicit `created_at`/`expires_at`, so expiry is
  deterministic without sleeps: the database clock decides, exactly like production.

      Nebu.OAuth.consume_authorization_code(code) ::
        {:ok, map} | {:error, :invalid} | {:error, {:reused, map}} | {:error, :storage}
        map keys (atoms) = every AC8 column: code_hash client_id redirect_uri code_challenge
        device_id user_id scope scope_prefix response_mode openid_requested client_nonce
        idp_rt_enc (still encrypted) auth_time expires_at (+ created_at, used_at)

      Nebu.OAuth.purge_expired_flow_state() :: {:ok, %{authz_requests: n, codes: m}} | {:error, term}

  Cluster safety: exactly one of N concurrent consumers wins (atomic UPDATE ... RETURNING);
  purges of several nodes run concurrently without errors (FOR UPDATE SKIP LOCKED) and are
  idempotent. Crash/restart: no in-memory state; a restarted node sees the same rows.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @oauth Nebu.OAuth
  defp consume(code), do: apply(@oauth, :consume_authorization_code, [code])
  defp purge, do: apply(@oauth, :purge_expired_flow_state, [])

  @worker Nebu.Workers.OAuthFlowPurgeWorker

  defp new_code, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # created_at / expires_at as SQL expressions (trusted literals).
  defp insert_code!(cid, code, opts \\ []) do
    created = Keyword.get(opts, :created, "now()")
    expires = Keyword.get(opts, :expires, "now() + interval '60 seconds'")

    T.sql!(
      "INSERT INTO oauth_codes (code_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, " <>
        "response_mode, client_nonce, openid_requested, idp_rt_enc, auth_time, created_at, expires_at) " <>
        "VALUES ($1, $2, 'https://app.example.com/cb', $3, 'DEV1', '@alice:test.local', " <>
        "'openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:DEV1', " <>
        "'urn:matrix:org.matrix.msc2967.client:', 'query', 'cn-1', true, 'enc-rt', now() - interval '5 seconds', #{created}, #{expires})",
      [T.sha256_hex(code), cid, String.duplicate("c", 43)]
    )

    code
  end

  defp insert_authz!(cid, opts) do
    key = "atdd-authz-" <> T.rand(8)
    created = Keyword.get(opts, :created, "now()")
    expires = Keyword.get(opts, :expires, "now() + interval '10 minutes'")

    T.sql!(
      "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
        "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, created_at, expires_at) " <>
        "VALUES ($1, $2, 'https://app.example.com/cb', 'c', 'D', 's', 'urn:matrix:client:', 'fragment', 'enc', 'n', 'b', #{created}, #{expires})",
      [key, cid]
    )

    key
  end

  defp code_exists?(code), do: T.sql!("SELECT 1 FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(code)]).num_rows == 1
  defp authz_exists?(key), do: T.sql!("SELECT 1 FROM oauth_authz_requests WHERE state_hash = $1", [key]).num_rows == 1

  # ── AC11 static wiring (no DB) ─────────────────────────────────────────────

  describe "AC11 — purge worker wiring (static)" do
    test "Oban cron runs OAuthFlowPurgeWorker every 10 minutes, next to the pending purge" do
      oban = Application.get_env(:nebu, Oban)
      {_plugin, cron_opts} = Enum.find(oban[:plugins], fn {mod, _} -> mod == Oban.Plugins.Cron end)
      assert {"*/10 * * * *", @worker} in cron_opts[:crontab]
      assert Enum.any?(cron_opts[:crontab], fn {_e, w} -> w == Nebu.Workers.OAuthPendingPurgeWorker end)
    end

    test "queue oauth_cleanup, max_attempts 3" do
      assert Code.ensure_loaded?(@worker), "Nebu.Workers.OAuthFlowPurgeWorker missing"
      opts = apply(@worker, :__opts__, [])
      assert to_string(opts[:queue]) == "oauth_cleanup"
      assert opts[:max_attempts] == 3
    end
  end

  # ── AC9 consume (D17) ──────────────────────────────────────────────────────

  describe "AC9/D17 — consume_authorization_code/1" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!(["https://app.example.com/cb"])}
    end

    test "a valid code is consumed once: {:ok, row} with every AC8 column, used_at set in the DB", %{cid: cid} do
      code = insert_code!(cid, new_code())
      assert {:ok, row} = consume(code)

      for k <- ~w(code_hash client_id redirect_uri code_challenge device_id user_id scope scope_prefix response_mode
                  openid_requested client_nonce idp_rt_enc auth_time expires_at)a,
          do: assert(Map.has_key?(row, k), "consume result lacks #{k}")

      assert row.client_id == cid
      assert row.code_hash == T.sha256_hex(code)
      assert row.device_id == "DEV1"
      assert row.user_id == "@alice:test.local"
      assert row.openid_requested == true
      assert row.client_nonce == "cn-1"
      assert row.idp_rt_enc == "enc-rt", "idp_rt_enc stays encrypted (story 3 decrypts)"

      %{rows: [[used]]} = T.sql!("SELECT used_at IS NOT NULL FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(code)])
      assert used
    end

    test "a second consume is reuse: {:error, {:reused, row}} with (user_id, device_id, client_id) for story-3 revocation", %{cid: cid} do
      code = insert_code!(cid, new_code())
      assert {:ok, _} = consume(code)
      assert {:error, {:reused, row}} = consume(code)
      assert row.client_id == cid
      assert row.user_id == "@alice:test.local"
      assert row.device_id == "DEV1"
    end

    test "reuse of a used code stays detectable after expiry (within the 24 h retention)", %{cid: cid} do
      # a code that was used and has expired since (used_at may only go NULL -> NOT NULL)
      code = insert_code!(cid, new_code(), created: "now() - interval '2 hours'", expires: "now() - interval '2 hours' + interval '60 seconds'")
      T.sql!("UPDATE oauth_codes SET used_at = now() - interval '2 hours' WHERE code_hash = $1", [T.sha256_hex(code)])
      assert {:error, {:reused, row}} = consume(code)
      assert row.client_id == cid
    end

    test "an unknown code => :invalid; non-binary input => :invalid", %{} do
      assert consume(new_code()) == {:error, :invalid}
      assert consume("") == {:error, :invalid}
      assert consume(nil) == {:error, :invalid}
    end

    test "an expired, unused code => :invalid (expiry checked in the UPDATE, not by the purge)", %{cid: cid} do
      code = insert_code!(cid, new_code(), created: "now() - interval '2 minutes'", expires: "now() - interval '1 minute'")
      assert consume(code) == {:error, :invalid}
      %{rows: [[unused]]} = T.sql!("SELECT used_at IS NULL FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(code)])
      assert unused, "an expired code is never marked used"
    end

    test "N concurrent consumers: exactly one {:ok, _}, the others {:reused, _} (must-test 18)", %{cid: cid} do
      code = insert_code!(cid, new_code())

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> consume(code) end) end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1, "results: #{inspect(results)}"
      assert Enum.count(results, &match?({:error, {:reused, _}}, &1)) == 9
    end

    test "storage failure => {:error, :storage}, never a raise" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:nebu_http, :oauth_repo) end)
      assert consume(new_code()) == {:error, :storage}
    end
  end

  # ── AC9/AC11 purge ─────────────────────────────────────────────────────────

  describe "AC9/AC11 — purge_expired_flow_state/0" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!(["https://app.example.com/cb"])}
    end

    test "boundaries: expired requests go; codes only 24 h AFTER expiry; live rows stay", %{cid: cid} do
      live_req = insert_authz!(cid, [])
      expired_req = insert_authz!(cid, created: "now() - interval '11 minutes'", expires: "now() - interval '1 minute'")

      live_code = insert_code!(cid, new_code())
      recent_expired = insert_code!(cid, new_code(), created: "now() - interval '23 hours 1 minute'", expires: "now() - interval '23 hours'")
      old_expired = insert_code!(cid, new_code(), created: "now() - interval '25 hours 1 minute'", expires: "now() - interval '25 hours'")

      assert {:ok, %{authz_requests: n, codes: m}} = purge()
      assert n >= 1 and m >= 1

      assert authz_exists?(live_req)
      refute authz_exists?(expired_req)
      assert code_exists?(live_code)
      assert code_exists?(recent_expired), "kept 24 h after expiry for reuse detection (D17)"
      refute code_exists?(old_expired)
    end

    test "idempotent: a second run removes nothing of ours and succeeds", %{cid: cid} do
      _ = insert_authz!(cid, created: "now() - interval '11 minutes'", expires: "now() - interval '1 minute'")
      assert {:ok, _} = purge()
      assert {:ok, %{authz_requests: n, codes: m}} = purge()
      assert is_integer(n) and is_integer(m)
      assert T.count_for("oauth_authz_requests", cid) == 0
    end

    test "batched: more expired rows than one batch (1000) are removed in one call", %{cid: cid} do
      T.sql!(
        "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
          "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, created_at, expires_at) " <>
          "SELECT 'atdd-bulk-' || $1::text || '-' || g, $2, 'u', 'c', 'D', 's', 'urn:matrix:client:', 'query', 'e', 'n', 'b', " <>
          "now() - interval '20 minutes', now() - interval '15 minutes' FROM generate_series(1, 1500) g",
        [T.rand(), cid]
      )

      assert {:ok, %{authz_requests: n}} = purge()
      assert n >= 1500
      assert T.count_for("oauth_authz_requests", cid) == 0
    end

    test "concurrent purges (several nodes) never fail and together remove every expired row", %{cid: cid} do
      expired = for _ <- 1..30, do: insert_authz!(cid, created: "now() - interval '11 minutes'", expires: "now() - interval '1 minute'")
      old_codes = for _ <- 1..30, do: insert_code!(cid, new_code(), created: "now() - interval '26 hours'", expires: "now() - interval '26 hours' + interval '60 seconds'")
      live = insert_authz!(cid, [])

      results = 1..4 |> Enum.map(fn _ -> Task.async(fn -> purge() end) end) |> Task.await_many(30_000)
      assert Enum.all?(results, &match?({:ok, %{authz_requests: _, codes: _}}, &1)), inspect(results)

      for k <- expired, do: refute(authz_exists?(k))
      for c <- old_codes, do: refute(code_exists?(c))
      assert authz_exists?(live)
    end

    test "an unavailable DB => {:error, _} from the purge and the worker (Oban retries)" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:nebu_http, :oauth_repo) end)
      assert {:error, _} = purge()
      assert {:error, _} = apply(@worker, :perform, [%Oban.Job{}])
    end

    test "the worker runs the purge and returns :ok", %{cid: cid} do
      expired = insert_authz!(cid, created: "now() - interval '11 minutes'", expires: "now() - interval '1 minute'")
      assert :ok = apply(@worker, :perform, [%Oban.Job{}])
      refute authz_exists?(expired)
    end
  end
end
