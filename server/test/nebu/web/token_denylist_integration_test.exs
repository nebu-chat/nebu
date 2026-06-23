defmodule Nebu.Web.TokenDenylistIntegrationTest do
  @moduledoc """
  RED-PHASE ATDD — PostgreSQL persistence for `Nebu.Web.TokenDenylist`.

  Story: token-denylist-postgres-persistence
  Gate: ATDD — failing tests generated before any implementation code.

  These integration tests MUST FAIL until the implementation is complete because
  the current `TokenDenylist` module does NOT write to or read from PostgreSQL.

  Tagged `@moduletag :integration` — excluded from `mix test` (no DB); runs via
  `make test-integration` where Nebu.Repo is started and the DB is available.

  ## AC coverage (integration level)

  | AC  | Test name                                         | P  |
  |-----|---------------------------------------------------|----|
  | AC1 | DB write on revoke — row inserted                 | P0 |
  | AC2 | DB cache miss fallback — revoked? reads DB        | P0 |
  | AC4 | Restart survival — ETS cleared, DB still answers  | P0 |
  | AC5 | DB key encoding — jti:<jti> and hex formats       | P0 |
  | AC6 | Lazy DB expiry — expired row returns false        | P1 |

  See `Nebu.Web.TokenDenylistDurabilityTest` (below) for unit-level AC3, AC7, AC8.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Web.TokenDenylist

  @table :nebu_http_token_denylist

  # ── helpers ────────────────────────────────────────────────────────────────

  defp future_exp, do: System.system_time(:second) + 3600
  defp past_exp, do: System.system_time(:second) - 1

  defp clear_ets do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
  end

  defp delete_db_row(token_hash) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "DELETE FROM invalidated_tokens WHERE token_hash = $1",
      [token_hash]
    )
  end

  defp insert_db_row(token_hash, expires_at) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO invalidated_tokens (token_hash, expires_at) VALUES ($1, $2) ON CONFLICT (token_hash) DO NOTHING",
      [token_hash, expires_at]
    )
  end

  defp select_db_rows(token_hash) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "SELECT token_hash, expires_at FROM invalidated_tokens WHERE token_hash = $1",
        [token_hash]
      )

    rows
  end

  # ── AC1 — DB write on revoke ───────────────────────────────────────────────

  describe "AC1 — DB write on revoke" do
    setup do
      clear_ets()
      on_exit(fn -> clear_ets() end)
      :ok
    end

    # [P0] AC1: revoke/3 must INSERT a row into `invalidated_tokens`.
    # FAILS NOW: current TokenDenylist.revoke/3 only writes to ETS, never to DB.
    test "[P0] revoke writes jti key to invalidated_tokens table" do
      jti = "ac1-jti-db-write-#{System.unique_integer([:positive])}"
      db_key = "jti:#{jti}"
      token = "raw.token.for.ac1.#{jti}"
      exp = future_exp()

      on_exit(fn -> delete_db_row(db_key) end)

      :ok = TokenDenylist.revoke(jti, token, exp)

      rows = select_db_rows(db_key)

      assert length(rows) == 1,
             "Expected 1 row in invalidated_tokens for key '#{db_key}', got #{length(rows)}. " <>
               "TokenDenylist.revoke/3 must INSERT into the DB."

      [[stored_hash, stored_exp]] = rows
      assert stored_hash == db_key
      assert stored_exp == exp
    end

    # [P0] AC1 + AC5: jti absent → DB key is the plain SHA-256 hex string of the raw token.
    # FAILS NOW: no DB write happens.
    test "[P0] revoke without jti writes bare SHA-256 hex key to invalidated_tokens" do
      token = "raw.token.no.jti.ac1.#{System.unique_integer([:positive])}"
      exp = future_exp()
      expected_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

      on_exit(fn -> delete_db_row(expected_hash) end)

      :ok = TokenDenylist.revoke(nil, token, exp)

      rows = select_db_rows(expected_hash)

      assert length(rows) == 1,
             "Expected 1 row with SHA-256 hex key '#{expected_hash}', got #{length(rows)}. " <>
               "TokenDenylist.revoke/3 must INSERT the hash-based key (plain hex string, not tuple)."
    end

    # [P0] AC1: Second revoke of the same token must not error (ON CONFLICT DO NOTHING).
    # FAILS NOW: no DB write happens at all.
    test "[P0] revoke is idempotent — ON CONFLICT DO NOTHING" do
      jti = "ac1-idempotent-#{System.unique_integer([:positive])}"
      db_key = "jti:#{jti}"
      token = "raw.token.idempotent.#{jti}"
      exp = future_exp()

      on_exit(fn -> delete_db_row(db_key) end)

      assert :ok = TokenDenylist.revoke(jti, token, exp)
      assert :ok = TokenDenylist.revoke(jti, token, exp)

      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT count(*) FROM invalidated_tokens WHERE token_hash = $1",
          [db_key]
        )

      assert count == 1,
             "Expected exactly 1 row after two identical revoke calls (idempotent), got #{count}"
    end
  end

  # ── AC2 — DB cache miss fallback ──────────────────────────────────────────

  describe "AC2 — DB cache miss fallback" do
    setup do
      clear_ets()
      on_exit(fn -> clear_ets() end)
      :ok
    end

    # [P0] AC2: When key is NOT in ETS but IS in DB (non-expired), revoked?/2 returns true.
    # FAILS NOW: revoked?/2 only checks ETS; never queries the DB.
    test "[P0] revoked? returns true on DB hit when ETS is cold" do
      jti = "ac2-cache-miss-#{System.unique_integer([:positive])}"
      db_key = "jti:#{jti}"
      exp = future_exp()

      # Pre-seed DB row directly (bypassing ETS — simulates token revoked by a different
      # process or a previous node before the current node started).
      insert_db_row(db_key, exp)
      on_exit(fn -> delete_db_row(db_key) end)

      # Confirm ETS is empty for this key
      ets_miss =
        :ets.whereis(@table) == :undefined or
          :ets.lookup(@table, {:jti, jti}) == []

      assert ets_miss, "Test precondition failed: ETS should not contain the key"

      result = TokenDenylist.revoked?(jti, "any.raw.token")

      assert result == true,
             "Expected revoked?/2 to return true via DB fallback, got #{inspect(result)}. " <>
               "AC2 requires a SELECT on `invalidated_tokens` when ETS misses."
    end

    # [P0] AC2: DB result is NOT back-populated into ETS (no back-fill on cache miss).
    # FAILS NOW: (fails at the DB read step before we can even check back-fill)
    test "[P0] revoked? does NOT back-populate ETS after a DB hit" do
      jti = "ac2-no-backfill-#{System.unique_integer([:positive])}"
      db_key = "jti:#{jti}"
      exp = future_exp()

      insert_db_row(db_key, exp)
      on_exit(fn -> delete_db_row(db_key) end)

      # Trigger DB read via revoked?/2
      TokenDenylist.revoked?(jti, "raw.tok")

      # ETS must remain empty for this key even after the DB hit
      ets_hit =
        :ets.whereis(@table) != :undefined and
          :ets.lookup(@table, {:jti, jti}) != []

      refute ets_hit,
             "revoked?/2 must NOT back-populate ETS from a DB hit (AC2 spec)."
    end
  end

  # ── AC4 — Restart survival ────────────────────────────────────────────────

  describe "AC4 — Restart survival" do
    setup do
      on_exit(fn -> clear_ets() end)
      :ok
    end

    # [P0] AC4: After ETS is wiped (simulating a node restart), a previously revoked
    # token is still rejected because the DB row persists.
    # FAILS NOW: revoke/3 doesn't write to DB, so after ETS.delete_all_objects the entry vanishes.
    test "[P0] token revoked before restart is still rejected after ETS is cleared" do
      jti = "ac4-restart-#{System.unique_integer([:positive])}"
      db_key = "jti:#{jti}"
      token = "raw.token.restart.#{jti}"
      exp = future_exp()

      # Step 1: revoke (must write to DB for this test to pass)
      :ok = TokenDenylist.revoke(jti, token, exp)
      on_exit(fn -> delete_db_row(db_key) end)

      # Step 2: simulate node restart — wipe ETS entirely
      if :ets.whereis(@table) != :undefined do
        :ets.delete_all_objects(@table)
      end

      ets_empty =
        :ets.whereis(@table) == :undefined or
          :ets.lookup(@table, {:jti, jti}) == []

      assert ets_empty, "Test precondition failed: ETS wipe did not clear the key"

      # Step 3: revoked?/2 must still return true via DB read
      result = TokenDenylist.revoked?(jti, token)

      assert result == true,
             "Expected revoked?/2 to return true after ETS clear (DB must persist the revocation). " <>
               "Current implementation returns #{inspect(result)} — AC4 is NOT met."
    end
  end

  # ── AC5 — DB key encoding ─────────────────────────────────────────────────

  describe "AC5 — DB key encoding" do
    setup do
      clear_ets()
      on_exit(fn -> clear_ets() end)
      :ok
    end

    # [P0] AC5: jti present → DB key is the STRING "jti:<jti_value>", not an Erlang tuple.
    # FAILS NOW: no DB write happens.
    test "[P0] DB key for jti token is the string 'jti:<jti_value>'" do
      jti = "ac5-key-enc-jti-#{System.unique_integer([:positive])}"
      db_key = "jti:#{jti}"
      token = "raw.#{jti}"
      exp = future_exp()

      on_exit(fn -> delete_db_row(db_key) end)

      :ok = TokenDenylist.revoke(jti, token, exp)

      rows = select_db_rows(db_key)

      assert length(rows) == 1,
             "Expected DB row with text key '#{db_key}'. " <>
               "AC5 requires jti-based DB key to be the string \"jti:<jti>\", not {:jti, \"...\"} tuple."

      [[stored_hash, _]] = rows
      assert stored_hash == "jti:#{jti}"
    end

    # [P0] AC5: jti absent → DB key is the BARE SHA-256 hex string, not {:hash, "..."} tuple.
    # FAILS NOW: no DB write happens.
    test "[P0] DB key for no-jti token is the bare SHA-256 hex string" do
      token = "raw.token.nojti.ac5.#{System.unique_integer([:positive])}"
      exp = future_exp()
      expected_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

      on_exit(fn -> delete_db_row(expected_hash) end)

      :ok = TokenDenylist.revoke(nil, token, exp)

      rows = select_db_rows(expected_hash)

      assert length(rows) == 1,
             "Expected DB row with bare hex key '#{expected_hash}'. " <>
               "AC5 requires no-jti DB key to be the plain hex string, not {:hash, hex} tuple."

      [[stored_hash, _]] = rows
      assert stored_hash == expected_hash
    end
  end

  # ── AC6 — Lazy expiry in DB ───────────────────────────────────────────────

  describe "AC6 — Lazy expiry in DB" do
    setup do
      clear_ets()
      on_exit(fn -> clear_ets() end)
      :ok
    end

    # [P1] AC6: A DB row whose `expires_at` is in the past is treated as absent.
    # FAILS NOW: no DB read in revoked?/2 at all.
    test "[P1] revoked? returns false for an expired DB row" do
      jti = "ac6-expired-#{System.unique_integer([:positive])}"
      db_key = "jti:#{jti}"
      exp = past_exp()

      # Insert an already-expired row directly to simulate a row that lingered
      insert_db_row(db_key, exp)
      on_exit(fn -> delete_db_row(db_key) end)

      result = TokenDenylist.revoked?(jti, "raw.tok")

      refute result,
             "Expected revoked?/2 to return false for an expired DB row (exp=#{exp}, now=#{System.system_time(:second)}). " <>
               "AC6: DB lookup must check expires_at > unix_now() — got #{inspect(result)}."
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Unit tests — Repo must NOT be started. These run in standard `mix test`.
# They test ETS fast path (AC3), best-effort write (AC7), and best-effort read (AC8).
# ─────────────────────────────────────────────────────────────────────────────

defmodule Nebu.Web.TokenDenylistDurabilityTest do
  @moduledoc """
  RED-PHASE ATDD — Unit-level durability tests for `Nebu.Web.TokenDenylist`.

  These tests run WITHOUT a database (no `@moduletag :integration`).
  They validate that:
    * AC3: The ETS fast path is preserved — works without DB.
    * AC7: revoke/3 returns :ok and writes ETS even when Repo is absent.
    * AC8: revoked?/2 returns false (no crash) when Repo is absent and token not in ETS.

  NOTE: AC7 and AC8 currently PASS with the existing ETS-only implementation because
  ETS-only never touches the DB. After the DB integration is added, these tests act as
  regression guards ensuring the `safe_query` pattern is correctly applied.
  """

  use ExUnit.Case, async: false

  alias Nebu.Web.TokenDenylist

  @table :nebu_http_token_denylist

  defp future_exp, do: System.system_time(:second) + 3600

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    end)

    :ok
  end

  # ── AC3 — ETS fast path ───────────────────────────────────────────────────

  describe "AC3 — ETS fast path preserved" do
    # [P0] AC3: When the key IS in ETS (non-expired), revoked?/2 returns true immediately.
    # This is a regression guard — the ETS fast path must survive the DB integration.
    # PASSES with current impl; MUST keep passing after DB integration is added.
    test "[P0] revoked? returns true from ETS without needing the DB" do
      jti = "ac3-ets-hit-#{System.unique_integer([:positive])}"
      token = "raw.token.#{jti}"
      exp = future_exp()

      # Insert directly into ETS to isolate the fast path from any DB interaction
      TokenDenylist.init_table()
      :ets.insert(@table, {{:jti, jti}, exp})

      result = TokenDenylist.revoked?(jti, token)

      assert result == true,
             "Expected revoked?/2 to return true via ETS fast path. Got #{inspect(result)}. " <>
               "AC3: ETS hot path must not be broken by the DB integration."
    end

    # [P0] AC3: ETS hit must not crash regardless of whether Repo is running.
    test "[P0] ETS fast path does not crash when Repo may be absent" do
      jti = "ac3-no-crash-#{System.unique_integer([:positive])}"
      token = "raw.token.no.crash.#{jti}"
      exp = future_exp()

      TokenDenylist.init_table()
      :ets.insert(@table, {{:jti, jti}, exp})

      result =
        try do
          TokenDenylist.revoked?(jti, token)
        rescue
          e -> flunk("revoked?/2 raised #{inspect(e)} — ETS fast path must never crash (AC3)")
        end

      assert result == true
    end
  end

  # ── AC7 — Best-effort DB write ────────────────────────────────────────────

  describe "AC7 — Best-effort DB write (Repo unavailable)" do
    # [P1] AC7: revoke/3 returns :ok when Repo is not started.
    # PASSES with current ETS-only impl.
    # WILL FAIL after DB integration if the safe_query guard is missing.
    test "[P1] revoke returns :ok when Repo is not started (no crash)" do
      jti = "ac7-no-repo-#{System.unique_integer([:positive])}"
      token = "raw.token.no.repo.#{jti}"
      exp = future_exp()

      # Confirm Repo is not running in the unit test environment
      if Process.whereis(Nebu.Repo) do
        # Integration environment: still verify :ok is returned
        assert :ok = TokenDenylist.revoke(jti, token, exp)
      else
        result =
          try do
            TokenDenylist.revoke(jti, token, exp)
          rescue
            e ->
              flunk(
                "TokenDenylist.revoke/3 raised #{inspect(e)} — must not crash when Repo is absent (AC7)"
              )
          end

        assert result == :ok,
               "Expected :ok from revoke/3 when Repo is absent, got #{inspect(result)}"
      end
    end

    # [P1] AC7: ETS entry IS written even when the DB write is skipped (Repo absent).
    test "[P1] ETS entry is written even when Repo is not started" do
      if Process.whereis(Nebu.Repo) do
        # Integration mode: DB write succeeds, ETS is also written — both are expected
        jti = "ac7-ets-integration-#{System.unique_integer([:positive])}"
        token = "raw.token.#{jti}"
        exp = future_exp()
        TokenDenylist.revoke(jti, token, exp)
        TokenDenylist.init_table()
        ets_result = :ets.lookup(@table, {:jti, jti})
        assert ets_result != [], "ETS entry missing after revoke/3 in integration mode"
      else
        jti = "ac7-ets-unit-#{System.unique_integer([:positive])}"
        token = "raw.token.#{jti}"
        exp = future_exp()

        TokenDenylist.revoke(jti, token, exp)

        TokenDenylist.init_table()
        ets_result = :ets.lookup(@table, {:jti, jti})

        assert ets_result != [],
               "ETS entry missing after revoke/3 when Repo absent — AC7 requires ETS write regardless"
      end
    end
  end

  # ── AC8 — Best-effort DB read ─────────────────────────────────────────────

  describe "AC8 — Best-effort DB read (Repo unavailable)" do
    # [P1] AC8: revoked?/2 returns false (no crash) when Repo absent and token not in ETS.
    # PASSES with current ETS-only impl.
    # WILL FAIL after DB integration if the safe_query guard is missing.
    test "[P1] revoked? returns false when Repo absent and token not in ETS (no crash)" do
      result =
        try do
          TokenDenylist.revoked?(nil, "raw.token.#{System.unique_integer([:positive])}")
        rescue
          e ->
            flunk(
              "TokenDenylist.revoked?/2 raised #{inspect(e)} — must not crash when Repo absent (AC8)"
            )
        end

      refute result,
             "Expected false from revoked?/2 when Repo absent and token not in ETS. Got #{inspect(result)}"
    end

    # [P1] AC8: ETS positive result is unaffected when Repo may be absent.
    test "[P1] ETS positive result is unaffected regardless of Repo state" do
      jti = "ac8-ets-positive-#{System.unique_integer([:positive])}"
      token = "raw.token.#{jti}"
      exp = future_exp()

      TokenDenylist.init_table()
      :ets.insert(@table, {{:jti, jti}, exp})

      result =
        try do
          TokenDenylist.revoked?(jti, token)
        rescue
          e ->
            flunk(
              "revoked?/2 raised #{inspect(e)} when ETS hit (Repo may be absent) (AC8)"
            )
        end

      assert result == true,
             "Expected true from ETS fast path (AC8: ETS positive path unaffected by Repo state)"
    end
  end
end
