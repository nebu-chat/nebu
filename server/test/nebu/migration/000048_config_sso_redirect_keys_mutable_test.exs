defmodule Nebu.Migration.Migration000048ConfigSsoRedirectKeysMutableTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC15.1 / AC15.2 / D13: migration
  `000048_config_sso_redirect_keys_mutable`. It re-creates the `server_config` `config_update_mutable` RLS policy
  with 000042's allowlist VERBATIM (000042 is the latest re-creation: it added `oauth_access_token_ttl_seconds` /
  `oauth_idp_revalidation`, which must not be dropped) plus

    * `sso_extra_redirect_schemes` - a PRE-EXISTING gap: the key was never added, so `upsert_server_config/1`'s
      `INSERT ... ON CONFLICT DO UPDATE` on an existing row fails the UPDATE `USING` check (PostgreSQL raises an
      RLS error for `ON CONFLICT DO UPDATE`): the SECOND save of the SSO schemes form crashes today;
    * `sso_redirect_allowed_origins` - the new operator list.

  Down restores 000042's policy verbatim (existing rows of the two keys stay, write-once again). No INSERT of
  values, no BEGIN / COMMIT, no CONCURRENTLY, no other object touched. Mirrors
  `000042_oauth_sessions_signing_keys_test.exs`: static SQL-file analysis (no DB) + `:integration` behaviour as the
  RUNTIME role (`nebu_app`, FORCE RLS) + a down / up round trip on the privileged role inside a rolled-back
  transaction. After adding the migration reset the throwaway database (`docker rm -f nebu-oauth-pg`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000048_config_sso_redirect_keys_mutable.up.sql"
  @down "000048_config_sso_redirect_keys_mutable.down.sql"
  @m42 "000042_oauth_sessions_and_signing_keys.up.sql"
  @new_keys ~w(sso_extra_redirect_schemes sso_redirect_allowed_origins)

  # SHA-256 of every committed migration of the epic (000040-000047): "NEVER edit an already committed migration"
  @committed %{
    "000040_oauth_clients_and_auth_metadata.down.sql" => "15833d94f34ee17191db7ab9fefb589c6dcaaace9e4c8a4a54007a957c697ed9",
    "000040_oauth_clients_and_auth_metadata.up.sql" => "a8c4be163090571c15ae08148857fe3e1203c303bae54647f28cc4be2ba46dbe",
    "000041_oauth_authz_requests_and_codes.down.sql" => "c2ef95ca65c5f965a55cc38ed5be1e51059bcde077b52e1b36d18322964daf1a",
    "000041_oauth_authz_requests_and_codes.up.sql" => "4889491d05208db62fef06a5a89cd9e9fadb215046138ff67ede34745a3c04b6",
    "000042_oauth_sessions_and_signing_keys.down.sql" => "ae35d18e6b92ab4bf28d328df01e8ce99acba3677b20201c7862c441a5f6d49f",
    "000042_oauth_sessions_and_signing_keys.up.sql" => "552202bc1e4c73a4ddb69ab5c8f2e5cd2e4c95f577ffc6a18ebe3a6905dfa61c",
    "000043_oauth_account_management.down.sql" => "c8efb9fb474e60955b79b52a78eee4583cee6633ed835552c153118c7cd24c83",
    "000043_oauth_account_management.up.sql" => "5e7ad94c972f3f4c0f9cd0bad286891d7d1d2f9e68f8c4926a088627ca438596",
    "000044_oauth_abuse_hardening.down.sql" => "af31485f809ff7ea58eeb2ca4c2e528236f3d59de1340a40b186cc1e14d8b2e3",
    "000044_oauth_abuse_hardening.up.sql" => "6f79d3e9e3031b7aae7c88ae037919d0787f50841206c2a96241209a7290b4ae",
    "000045_oauth_consent_and_refresh_leases.down.sql" => "5fd3bd17f02a01549f66515a6adf3db84cdde37051f081bdc93f0be0e056a6d9",
    "000045_oauth_consent_and_refresh_leases.up.sql" => "75f1e56e62c39c9483fbd88d21ee4799fca69e3c7d2873a8656021cf1a92d26c",
    "000046_oauth_client_revocation.down.sql" => "3ba8a206a0b2e25bffae6cf2b5d432a41d20a59092e5e644341c18fe5150c147",
    "000046_oauth_client_revocation.up.sql" => "51d9805caecabe76f5517595c715c8578deeeb49a4e4caf1a6f1e491c5d9dc76",
    "000047_oauth_signing_key_next.down.sql" => "735384c344a06f7faf13b7a7c6ead91840b168616e3ab923469aa9bf6e2931ab",
    "000047_oauth_signing_key_next.up.sql" => "ab93e00d83c5b56eddfe1741f99d8f2ac21077be89cc11c1ddf8b0e8b99cf132"
  }

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  defp policy_sql(file) do
    sql = code_sql(file)
    [_, policy] = String.split(sql, "CREATE POLICY config_update_mutable ON server_config", parts: 2)
    policy |> String.split(";", parts: 2) |> hd()
  end

  defp keys_of(policy), do: Regex.scan(~r/'([a-z_]+)'/, policy) |> Enum.map(&List.last/1)
  defp likes_of(policy), do: Regex.scan(~r/LIKE\s+'[^']+'/, policy) |> Enum.map(&hd/1)

  # ════════════════════════════════════════════════════════════════════════════
  # AC15.1 — static
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC15.1 — migration files (static)" do
    test "up and down exist as the next free number and are the only 000048" do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000048_*.up.sql")) == [Path.join(@dir, @up)], "exactly one 000048 up migration"
      assert Path.wildcard(Path.join(@dir, "000048_*.down.sql")) == [Path.join(@dir, @down)], "exactly one 000048 down migration"
      # (a later story's 000049 is allowed: story admin-config-privileged-forms-sweep added one)
    end

    test "000040 - 000047 are byte-for-byte untouched (a new migration instead of an edit)" do
      for {file, expected} <- @committed do
        actual = :crypto.hash(:sha256, read!(file)) |> Base.encode16(case: :lower)
        assert actual == expected, "#{file} was edited (committed migrations are never edited)"
      end
    end

    test "the up policy keeps EVERY key and both LIKE families of 000042's policy (parsed, not hard-coded) plus the two new keys" do
      sql = code_sql(@up)
      assert sql =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config"
      assert sql =~ "CREATE POLICY config_update_mutable ON server_config"

      prev = policy_sql(@m42)
      new = policy_sql(@up)
      prev_keys = keys_of(prev)
      assert length(prev_keys) >= 30, "failed to parse the 000042 allowlist"
      assert "oauth_access_token_ttl_seconds" in prev_keys and "oauth_idp_revalidation" in prev_keys

      for k <- prev_keys, do: assert(new =~ "'#{k}'", "key #{k} dropped from config_update_mutable (000042 added it)")
      assert length(likes_of(prev)) == 2
      for l <- likes_of(prev), do: assert(new =~ l, "pattern #{l} dropped from config_update_mutable")
      for k <- @new_keys, do: assert(new =~ "'#{k}'", "new key #{k} missing")
      assert new =~ ~r/FOR\s+UPDATE/i
    end

    test "the up policy contains no key that is not 000042's or one of the two new keys (no silent widening)" do
      allowed = keys_of(policy_sql(@m42)) ++ @new_keys
      extra = keys_of(policy_sql(@up)) -- allowed
      assert extra == [], "unexpected keys in the new allowlist: #{inspect(extra)}"
    end

    test "down restores 000042's policy VERBATIM (keys and LIKE families) and removes the two new keys" do
      down = code_sql(@down)
      assert down =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config"
      assert down =~ "CREATE POLICY config_update_mutable ON server_config"
      restored = policy_sql(@down)
      prev = policy_sql(@m42)
      assert Enum.sort(keys_of(restored)) == Enum.sort(keys_of(prev)), "down restores 000042's key list exactly"
      assert Enum.sort(likes_of(restored)) == Enum.sort(likes_of(prev))
      for k <- @new_keys, do: refute(restored =~ k)
      assert restored =~ ~r/FOR\s+UPDATE/i
    end

    test "no INSERT, no table / grant / index DDL: only DROP POLICY + CREATE POLICY on server_config" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/INSERT\s+INTO/i, "#{f}: no values are inserted"
        refute sql =~ ~r/\b(CREATE|ALTER|DROP)\s+(TABLE|INDEX|FUNCTION|TRIGGER|VIEW|SEQUENCE)\b/i, "#{f}: no other object is touched"
        refute sql =~ ~r/\b(GRANT|REVOKE)\b/i
        # a statement, never the `FOR UPDATE USING` of the policy itself
        refute sql =~ ~r/^\s*(UPDATE\s+\w+\s+SET|DELETE\s+FROM)\b/im, "#{f}: no data statements"
        assert Regex.scan(~r/\bON\s+(\w+)/, sql) |> Enum.map(&List.last/1) |> Enum.uniq() == ["server_config"], "#{f}: only server_config"
      end
    end

    test "both files are transaction-safe: no BEGIN / COMMIT, no CONCURRENTLY" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im, "#{f} must not manage transactions"
        refute sql =~ ~r/CONCURRENTLY/i, "#{f} must not use CONCURRENTLY"
      end
    end

    test "the up header comment documents the rationale, the rolling-deploy safety and the reset hint for the throwaway DB" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      assert header =~ "sso_extra_redirect_schemes"
      assert header =~ "sso_redirect_allowed_origins"
      assert header =~ ~r/rolling/i, "rolling-deploy safety (old nodes never write the new key)"
      assert header =~ ~r/reset/i, "the throwaway-DB reset hint"
      assert header =~ ~r/000042/, "names the policy it re-creates"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC15.2 — behaviour as the runtime role
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC15.2 — runtime role (nebu_app, FORCE RLS)" do
    @describetag :integration

    setup do
      %{rows: prior} = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = ANY($1)", [@new_keys])

      on_exit(fn ->
        T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@new_keys])
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
      end)

      T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@new_keys])
      :ok
    end

    defp value_of(key) do
      case T.sql!("SELECT value FROM server_config WHERE key = $1", [key]) do
        %{rows: [[v]]} -> v
        %{rows: []} -> nil
      end
    end

    test "upsert_server_config/1 writes sso_extra_redirect_schemes twice (a1, then a2): the second value is stored, no RLS error" do
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{"sso_extra_redirect_schemes" => "a1"})
      assert value_of("sso_extra_redirect_schemes") == "a1"
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{"sso_extra_redirect_schemes" => "a2"})
      assert value_of("sso_extra_redirect_schemes") == "a2"
    end

    test "upsert_server_config/1 writes sso_redirect_allowed_origins twice: the second value is stored each time" do
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{"sso_redirect_allowed_origins" => "https://one.example"})
      assert value_of("sso_redirect_allowed_origins") == "https://one.example"
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{"sso_redirect_allowed_origins" => "https://two.example, https://three.example:8443"})
      assert value_of("sso_redirect_allowed_origins") == "https://two.example, https://three.example:8443"
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{"sso_redirect_allowed_origins" => ""})
      assert value_of("sso_redirect_allowed_origins") == ""
    end

    test "a plain UPDATE of an existing row of each new key matches exactly one row (the policy allows it)" do
      for key <- @new_keys do
        T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, 'probe', 0)", [key])
        assert T.sql!("UPDATE server_config SET value = 'changed' WHERE key = $1", [key]).num_rows == 1, "UPDATE of #{key} is a silent no-op"
      end
    end

    test "every other key of 000042's list (and both LIKE families) is still updatable" do
      keys = keys_of(policy_sql(@m42))
      for key <- keys, do: assert_updatable!(key, "probe")
      for probe <- ["log_min_level_atddprobe", "log_retention_days_atddprobe"], do: assert_updatable!(probe, "1")
    end

    test "a key that is NOT in the allowlist is still write-once (the policy was not widened)" do
      key = "sso_not_in_the_allowlist_" <> T.rand(4)
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, 'v', 0)", [key])
      on_exit(fn -> T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [key]) end)
      assert T.sql!("UPDATE server_config SET value = 'x' WHERE key = $1", [key]).num_rows == 0
    end

    # Inserts a probe row if the key is absent (removed again with the privileged role), then proves an UPDATE
    # matches 1 row WITHOUT changing an existing value (`value = value`).
    defp assert_updatable!(key, probe_value) do
      absent? = T.sql!("SELECT 1 FROM server_config WHERE key = $1", [key]).num_rows == 0
      if absent?, do: T.sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, 0)", [key, probe_value])

      try do
        n = T.sql!("UPDATE server_config SET value = value WHERE key = $1", [key]).num_rows
        assert n == 1, "UPDATE of server_config key #{key} is a silent no-op (missing from config_update_mutable)"
      after
        if absent?, do: T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [key])
      end
    end

    test "down / up round trip (privileged role, rolled back): down removes the two keys and keeps 000042's; up restores them" do
      down = read!(@down)
      up = read!(@up)

      probe = fn tx ->
        %{rows: [[qual]]} = Postgrex.query!(tx, "SELECT qual FROM pg_policies WHERE policyname = 'config_update_mutable' AND tablename = 'server_config'", [])
        {Enum.all?(@new_keys, &String.contains?(qual, &1)), String.contains?(qual, "oauth_access_token_ttl_seconds") and String.contains?(qual, "oauth_idp_revalidation")}
      end

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, down, [], query_type: :text)
            after_down = probe.(tx)
            Postgrex.query!(tx, up, [], query_type: :text)
            after_up = probe.(tx)
            Postgrex.rollback(tx, {:round_trip, after_down, after_up})
          end)
        end)

      assert {:error, {:round_trip, after_down, after_up}} = result
      assert after_down == {false, true}, "after down: 000042's policy (no new keys, the token keys kept)"
      assert after_up == {true, true}, "after up: the new keys AND 000042's keys"
    end
  end
end
