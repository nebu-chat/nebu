defmodule Nebu.Migration.Migration000056ConfigSessionLifetimeMutableTest do
  @moduledoc """
  Story `session-lifetime-setting` (epic oauth-session-and-consent): migration `000056_config_session_lifetime_mutable` re-creates the `server_config`
  `config_update_mutable` RLS policy (the allowlist of keys the runtime role `nebu_app` may UPDATE; every other key is write-once) with the allowlist of
  000049 VERBATIM plus ONE key, `matrix_session_ttl_seconds`: without it the SECOND save of the session lifetime fails with an RLS error (`INSERT ... ON
  CONFLICT DO UPDATE` on the existing row). Down restores 000049's policy verbatim. Same shape as the 000048 / 000049 tests: static SQL analysis (no DB) +
  `:integration` behaviour as the RUNTIME role. After adding the migration reset the throwaway database.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000056_config_session_lifetime_mutable.up.sql"
  @down "000056_config_session_lifetime_mutable.down.sql"
  @m49 "000049_config_admin_group_claim_mutable.up.sql"
  @new_key "matrix_session_ttl_seconds"

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  defp policy_sql(file) do
    [_, policy] = String.split(code_sql(file), "CREATE POLICY config_update_mutable ON server_config", parts: 2)
    policy |> String.split(";", parts: 2) |> hd()
  end

  defp keys_of(policy), do: Regex.scan(~r/'([a-z_]+)'/, policy) |> Enum.map(&List.last/1)
  defp likes_of(policy), do: Regex.scan(~r/LIKE\s+'[^']+'/, policy) |> Enum.map(&hd/1)

  describe "static" do
    test "up and down exist and are the only 000056" do
      assert Path.wildcard(Path.join(@dir, "000056_*.up.sql")) == [Path.join(@dir, @up)]
      assert Path.wildcard(Path.join(@dir, "000056_*.down.sql")) == [Path.join(@dir, @down)]
    end

    test "the up policy keeps EVERY key and LIKE family of 000049 plus matrix_session_ttl_seconds only (no silent widening)" do
      prev = policy_sql(@m49)
      new = policy_sql(@up)
      prev_keys = keys_of(prev)
      assert length(prev_keys) >= 30
      for k <- prev_keys, do: assert(new =~ "'#{k}'", "key #{k} dropped")
      for l <- likes_of(prev), do: assert(new =~ l)
      assert new =~ "'#{@new_key}'"
      assert keys_of(new) -- (prev_keys ++ [@new_key]) == [], "no silent widening"
      assert new =~ ~r/FOR\s+UPDATE/i
    end

    test "down restores 000049's policy verbatim and removes the key" do
      restored = policy_sql(@down)
      prev = policy_sql(@m49)
      assert Enum.sort(keys_of(restored)) == Enum.sort(keys_of(prev))
      assert Enum.sort(likes_of(restored)) == Enum.sort(likes_of(prev))
      refute @new_key in keys_of(restored)
    end

    test "only DROP POLICY + CREATE POLICY on server_config, no values, transaction-safe" do
      for f <- [@up, @down] do
        sql = code_sql(f)
        refute sql =~ ~r/INSERT\s+INTO/i
        refute sql =~ ~r/\b(CREATE|ALTER|DROP)\s+(TABLE|INDEX|FUNCTION|TRIGGER|VIEW|SEQUENCE)\b/i
        refute sql =~ ~r/\b(GRANT|REVOKE)\b/i
        refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
        refute sql =~ ~r/CONCURRENTLY/i
        assert Regex.scan(~r/\bON\s+(\w+)/, sql) |> Enum.map(&List.last/1) |> Enum.uniq() == ["server_config"]
      end
    end

    test "the header names the key, the failure it prevents, the rolling-deploy safety and the reset hint" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      assert header =~ @new_key
      assert header =~ ~r/RLS|row-level/i
      assert header =~ ~r/rolling/i
      assert header =~ ~r/reset/i
      assert header =~ "000049"
    end
  end

  describe "behaviour as the runtime role (nebu_app, FORCE RLS)" do
    @describetag :integration

    setup do
      %{rows: prior} = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = $1", [@new_key])

      on_exit(fn ->
        T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [@new_key])
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
      end)

      T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [@new_key])
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, '28800', 1)", [@new_key])
      :ok
    end

    test "upsert_server_config/1 updates the EXISTING row twice: no RLS error" do
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{@new_key => "7200"})
      assert %{rows: [["7200"]]} = T.sql!("SELECT value FROM server_config WHERE key = $1", [@new_key])
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{@new_key => "10800"})
      assert %{rows: [["10800"]]} = T.sql!("SELECT value FROM server_config WHERE key = $1", [@new_key])
    end

    test "a plain UPDATE matches exactly one row (not a silent no-op)" do
      assert T.sql!("UPDATE server_config SET value = '3600' WHERE key = $1", [@new_key]).num_rows == 1
    end

    test "a key that is not in the allowlist stays write-once (no silent widening)" do
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('server_name_probe_immutable', 'x', 1) ON CONFLICT (key) DO NOTHING")
      on_exit(fn -> T.privileged_sql!("DELETE FROM server_config WHERE key = 'server_name_probe_immutable'") end)
      assert T.sql!("UPDATE server_config SET value = 'changed' WHERE key = 'server_name_probe_immutable'").num_rows == 0
    end
  end
end
