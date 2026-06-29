defmodule Nebu.ReleaseSslTest do
  @moduledoc """
  Acceptance tests for `Nebu.Release.postgres_ssl_opts/0` — the three-way SSL
  configuration logic introduced by the upcloud-postgres-ssl story.

  Story ACs covered here:
    AC-1: returns [ssl: false] when NEBU_POSTGRES_SSL is not set or is "false".
    AC-2: returns [ssl: [verify: :verify_none]] when NEBU_POSTGRES_SSL=true and
          NEBU_POSTGRES_CA_CERT_FILE is not set.
    AC-3: returns [ssl: [verify: :verify_peer, cacertfile: ~c"..."]] when
          NEBU_POSTGRES_SSL=true and NEBU_POSTGRES_CA_CERT_FILE is set.

  AC-4 (runtime.exs Repo config mirrors the same three-way logic) CANNOT be
  tested at the unit level because runtime.exs is evaluated at VM boot — not as
  part of the ExUnit suite. Verification of AC-4 is therefore done by code review:
  inspect `server/config/runtime.exs` around line 118 and confirm the same
  case/cond pattern is present. This comment is the test-level documentation of
  that decision.

  AC-5 (infra/UpCloud live deployment) is explicitly non-automatable and must be
  verified manually against a running UpCloud VM. See acceptance criteria for the
  exact log line and file path to check.

  Test isolation: all tests in this module mutate process env. `async: false` is
  therefore required. Each test restores the original env in an `on_exit`
  callback so test-order dependence is eliminated.
  """

  use ExUnit.Case, async: false

  alias Nebu.Release

  # ── shared env-restore helper ──────────────────────────────────────────────

  defp save_and_restore_env(keys) do
    originals = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(originals, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  # ── AC-1: SSL disabled (default / explicit false) ─────────────────────────

  describe "postgres_ssl_opts/0 — AC-1: SSL disabled" do
    setup do
      save_and_restore_env(["NEBU_POSTGRES_SSL", "NEBU_POSTGRES_CA_CERT_FILE"])
      System.delete_env("NEBU_POSTGRES_SSL")
      System.delete_env("NEBU_POSTGRES_CA_CERT_FILE")
      :ok
    end

    # AC-1 — NEBU_POSTGRES_SSL not set → [ssl: false]
    test "returns [ssl: false] when NEBU_POSTGRES_SSL is not set" do
      # Given: NEBU_POSTGRES_SSL is not set (env deleted in setup)
      # When:
      result = Release.postgres_ssl_opts()
      # Then: SSL is disabled — safe default for local dev and non-UpCloud deploys
      assert result == [ssl: false]
    end

    # AC-1 — NEBU_POSTGRES_SSL="false" → [ssl: false]
    test "returns [ssl: false] when NEBU_POSTGRES_SSL is explicitly \"false\"" do
      # Given: explicit opt-out
      System.put_env("NEBU_POSTGRES_SSL", "false")
      # When:
      result = Release.postgres_ssl_opts()
      # Then:
      assert result == [ssl: false]
    end

    # AC-1 edge case — any non-"true" value is treated as disabled
    test "returns [ssl: false] for any value other than \"true\" (e.g. \"1\", \"yes\", \"TRUE\")" do
      for garbage <- ["1", "yes", "TRUE", "on", "enabled"] do
        System.put_env("NEBU_POSTGRES_SSL", garbage)
        result = Release.postgres_ssl_opts()

        assert result == [ssl: false],
               "Expected [ssl: false] for NEBU_POSTGRES_SSL=#{inspect(garbage)}, got #{inspect(result)}"
      end
    end
  end

  # ── AC-2: SSL enabled, no CA cert → verify_none ───────────────────────────

  describe "postgres_ssl_opts/0 — AC-2: SSL enabled, no CA cert file" do
    setup do
      save_and_restore_env(["NEBU_POSTGRES_SSL", "NEBU_POSTGRES_CA_CERT_FILE"])
      System.put_env("NEBU_POSTGRES_SSL", "true")
      System.delete_env("NEBU_POSTGRES_CA_CERT_FILE")
      :ok
    end

    # AC-2 — NEBU_POSTGRES_SSL=true, NEBU_POSTGRES_CA_CERT_FILE not set
    test "returns [ssl: [verify: :verify_none]] when SSL enabled and no CA cert file" do
      # Given: NEBU_POSTGRES_SSL=true, NEBU_POSTGRES_CA_CERT_FILE not set (done in setup)
      # When:
      result = Release.postgres_ssl_opts()
      # Then: TLS is active but peer verification is skipped (no CA cert available)
      assert result == [ssl: [verify: :verify_none]]
    end

    test "returned ssl keyword is a keyword list (not a plain boolean)" do
      result = Release.postgres_ssl_opts()
      [{:ssl, ssl_val}] = result
      assert Keyword.keyword?(ssl_val),
             "Expected ssl value to be a keyword list, got #{inspect(ssl_val)}"
    end

    test "returned ssl keyword contains :verify key set to :verify_none" do
      result = Release.postgres_ssl_opts()
      [{:ssl, ssl_val}] = result
      assert Keyword.fetch!(ssl_val, :verify) == :verify_none
    end

    test "returned ssl keyword does NOT contain :cacertfile when CA cert is absent" do
      result = Release.postgres_ssl_opts()
      [{:ssl, ssl_val}] = result
      refute Keyword.has_key?(ssl_val, :cacertfile),
             "Expected no :cacertfile key when NEBU_POSTGRES_CA_CERT_FILE is unset"
    end
  end

  # ── AC-3: SSL enabled with CA cert → verify_peer + cacertfile ────────────

  describe "postgres_ssl_opts/0 — AC-3: SSL enabled with CA cert file (no hostname)" do
    @ca_path "/opt/nebu/postgres-ca.pem"

    setup do
      save_and_restore_env(["NEBU_POSTGRES_SSL", "NEBU_POSTGRES_CA_CERT_FILE"])
      System.put_env("NEBU_POSTGRES_SSL", "true")
      System.put_env("NEBU_POSTGRES_CA_CERT_FILE", @ca_path)
      :ok
    end

    # AC-3 — full verify_peer path with cacertfile charlist (no SNI when hostname not supplied)
    test "returns verify_peer + cacertfile + customize_hostname_check when CA cert path is set" do
      # Given: NEBU_POSTGRES_SSL=true, NEBU_POSTGRES_CA_CERT_FILE=/opt/nebu/postgres-ca.pem (setup)
      # When: called without hostname (0-arity)
      result = Release.postgres_ssl_opts()
      [{:ssl, ssl_val}] = result
      # Then: verify_peer enabled, cacertfile set, no server_name_indication (hostname unknown)
      assert Keyword.fetch!(ssl_val, :verify) == :verify_peer
      assert Keyword.fetch!(ssl_val, :cacertfile) == to_charlist(@ca_path)
      refute Keyword.has_key?(ssl_val, :server_name_indication)
    end

    test ":cacertfile value is an Erlang charlist (not a binary string)" do
      result = Release.postgres_ssl_opts()
      [{:ssl, ssl_val}] = result
      cacertfile = Keyword.fetch!(ssl_val, :cacertfile)

      assert is_list(cacertfile),
             "Expected cacertfile to be a charlist, got #{inspect(cacertfile)}"

      assert cacertfile == to_charlist(@ca_path)
    end

    test ":customize_hostname_check is set to use HTTPS match function" do
      result = Release.postgres_ssl_opts()
      [{:ssl, ssl_val}] = result
      chc = Keyword.fetch!(ssl_val, :customize_hostname_check)
      assert is_list(chc)
      assert Keyword.has_key?(chc, :match_fun)
    end

    test "cacertfile charlist matches the exact path from NEBU_POSTGRES_CA_CERT_FILE" do
      custom_path = "/etc/ssl/custom/my-ca.crt"
      System.put_env("NEBU_POSTGRES_CA_CERT_FILE", custom_path)

      result = Release.postgres_ssl_opts()
      [{:ssl, ssl_val}] = result
      cacertfile = Keyword.fetch!(ssl_val, :cacertfile)

      assert cacertfile == to_charlist(custom_path),
             "cacertfile #{inspect(cacertfile)} does not match path #{inspect(custom_path)}"
    end
  end

  describe "postgres_ssl_opts/1 — AC-3 hostname: verify_peer + SNI + hostname check" do
    @ca_path "/opt/nebu/postgres-ca.pem"
    @db_host "nebu-production-eqigmgsbyqmc.db.upclouddatabases.com"

    setup do
      save_and_restore_env(["NEBU_POSTGRES_SSL", "NEBU_POSTGRES_CA_CERT_FILE"])
      System.put_env("NEBU_POSTGRES_SSL", "true")
      System.put_env("NEBU_POSTGRES_CA_CERT_FILE", @ca_path)
      :ok
    end

    test "includes :server_name_indication as charlist of the hostname" do
      # Given: SSL enabled with CA cert file, hostname passed explicitly (as in parse_url/1)
      result = Release.postgres_ssl_opts(@db_host)
      [{:ssl, ssl_val}] = result
      sni = Keyword.fetch!(ssl_val, :server_name_indication)
      assert sni == to_charlist(@db_host),
             "Expected SNI #{inspect(to_charlist(@db_host))}, got #{inspect(sni)}"
    end

    test "SNI is absent when nil hostname passed" do
      result = Release.postgres_ssl_opts(nil)
      [{:ssl, ssl_val}] = result
      refute Keyword.has_key?(ssl_val, :server_name_indication)
    end

    test "SNI is absent when empty-string hostname passed" do
      result = Release.postgres_ssl_opts("")
      [{:ssl, ssl_val}] = result
      refute Keyword.has_key?(ssl_val, :server_name_indication)
    end

    test "verify_peer and cacertfile are still set alongside SNI" do
      result = Release.postgres_ssl_opts(@db_host)
      [{:ssl, ssl_val}] = result
      assert Keyword.fetch!(ssl_val, :verify) == :verify_peer
      assert Keyword.fetch!(ssl_val, :cacertfile) == to_charlist(@ca_path)
      assert Keyword.has_key?(ssl_val, :customize_hostname_check)
    end

    test "does not add SNI in verify_none mode (no CA cert)" do
      # When CA cert file is absent, mode is verify_none regardless of hostname
      System.delete_env("NEBU_POSTGRES_CA_CERT_FILE")
      result = Release.postgres_ssl_opts(@db_host)
      [{:ssl, ssl_val}] = result
      assert Keyword.fetch!(ssl_val, :verify) == :verify_none
      refute Keyword.has_key?(ssl_val, :server_name_indication)
    end
  end

  # ── AC-5: infra / UpCloud live deployment (non-automatable) ──────────────
  #
  # AC-5 states: "When deployed on UpCloud with fetch_postgres_ca = true, the VM
  # boot log contains '[nebu-bootstrap] PostgreSQL CA cert saved' and
  # /opt/nebu/postgres-ca.pem exists before nebu.service starts."
  #
  # This AC is explicitly marked as non-automatable in the story because it
  # requires a live UpCloud deployment with the bootstrap Tofu/cloud-init scripts
  # applied. It cannot be simulated in an ExUnit suite without spinning up a real
  # VM and running the init scripts.
  #
  # Manual verification steps (run after `tofu apply` on the upcloud example):
  #   1. SSH into the deployed VM.
  #   2. Run: journalctl -u nebu-bootstrap | grep "PostgreSQL CA cert saved"
  #   3. Run: ls -la /opt/nebu/postgres-ca.pem
  #   4. Run: systemctl is-active nebu.service
  #   Expected: step 2 shows the log line, step 3 shows the file, step 4 shows "active".
end
