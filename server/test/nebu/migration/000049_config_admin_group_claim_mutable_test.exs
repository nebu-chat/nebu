defmodule Nebu.Migration.Migration000049ConfigAdminGroupClaimMutableTest do
  @moduledoc """
  Story `admin-config-privileged-forms-sweep` (found by its code review): migration `000049_config_admin_group_claim_mutable`
  re-creates the `server_config` `config_update_mutable` RLS policy with 000048's allowlist VERBATIM plus `admin_group_claim`: a
  PRE-EXISTING gap (the key was in 000001's policy and dropped by 000002), so every save of the "Role mapping" page on a bootstrapped
  instance raised an RLS error (`INSERT ... ON CONFLICT DO UPDATE` on the existing row). Down restores 000048's policy verbatim.
  Static SQL analysis (no DB) + `:integration` behaviour as the RUNTIME role (`nebu_app`, FORCE RLS). After adding the migration reset
  the throwaway database (`docker rm -f nebu-oauth-pg`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @dir Path.expand("../../../priv/migrations", __DIR__)
  @up "000049_config_admin_group_claim_mutable.up.sql"
  @down "000049_config_admin_group_claim_mutable.down.sql"
  @m48 "000048_config_sso_redirect_keys_mutable.up.sql"
  @new_key "admin_group_claim"

  defp read!(f), do: File.read!(Path.join(@dir, f))
  defp code_sql(f), do: f |> read!() |> String.replace(~r/--[^\n]*/, "")

  defp policy_sql(file) do
    [_, policy] = String.split(code_sql(file), "CREATE POLICY config_update_mutable ON server_config", parts: 2)
    policy |> String.split(";", parts: 2) |> hd()
  end

  defp keys_of(policy), do: Regex.scan(~r/'([a-z_]+)'/, policy) |> Enum.map(&List.last/1)
  defp likes_of(policy), do: Regex.scan(~r/LIKE\s+'[^']+'/, policy) |> Enum.map(&hd/1)

  describe "static" do
    test "up and down exist and are the only 000049" do
      assert Path.wildcard(Path.join(@dir, "000049_*.up.sql")) == [Path.join(@dir, @up)]
      assert Path.wildcard(Path.join(@dir, "000049_*.down.sql")) == [Path.join(@dir, @down)]
    end

    test "000048 is byte-for-byte untouched is checked by its own test; the up policy keeps EVERY key and LIKE family of 000048 plus admin_group_claim only" do
      prev = policy_sql(@m48)
      new = policy_sql(@up)
      prev_keys = keys_of(prev)
      assert length(prev_keys) >= 30
      for k <- prev_keys, do: assert(new =~ "'#{k}'", "key #{k} dropped")
      for l <- likes_of(prev), do: assert(new =~ l)
      assert new =~ "'#{@new_key}'"
      assert keys_of(new) -- (prev_keys ++ [@new_key]) == [], "no silent widening"
      assert new =~ ~r/FOR\s+UPDATE/i
    end

    test "down restores 000048's policy verbatim and removes the key" do
      restored = policy_sql(@down)
      prev = policy_sql(@m48)
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

    test "the header names the pre-existing gap, the rolling-deploy safety and the reset hint" do
      header = read!(@up) |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "--")) |> Enum.join("\n")
      assert header =~ "admin_group_claim"
      assert header =~ ~r/PRE-EXISTING/
      assert header =~ ~r/rolling/i
      assert header =~ ~r/reset/i
      assert header =~ "000048"
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
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, 'bootstrap-value', 1)", [@new_key])
      :ok
    end

    test "upsert_server_config/1 updates the EXISTING admin_group_claim row twice (the Role mapping page): no RLS error" do
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{@new_key => "groups"})
      assert %{rows: [["groups"]]} = T.sql!("SELECT value FROM server_config WHERE key = $1", [@new_key])
      assert :ok = Nebu.Admin.DB.upsert_server_config(%{@new_key => "admins"})
      assert %{rows: [["admins"]]} = T.sql!("SELECT value FROM server_config WHERE key = $1", [@new_key])
    end

    test "a plain UPDATE matches exactly one row (not a silent no-op)" do
      assert T.sql!("UPDATE server_config SET value = 'changed' WHERE key = $1", [@new_key]).num_rows == 1
    end

    test "a key that is not in the allowlist stays write-once (no silent widening)" do
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('server_name_probe_immutable', 'x', 1) ON CONFLICT (key) DO NOTHING")
      on_exit(fn -> T.privileged_sql!("DELETE FROM server_config WHERE key = 'server_name_probe_immutable'") end)
      assert T.sql!("UPDATE server_config SET value = 'changed' WHERE key = 'server_name_probe_immutable'").num_rows == 0
    end
  end
end
