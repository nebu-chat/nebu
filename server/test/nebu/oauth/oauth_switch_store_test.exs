defmodule Nebu.OAuth.OAuthSwitchStoreTest do
  @moduledoc """
  Story `admin-oauth-switch`, AC4 / AC7 (decisions D3, D7, D8), no database: the orchestration of `Nebu.OAuth.save_switch/2`
  (`Nebu.OAuth.SwitchStore`) around the transaction function. The transaction itself (two upserts and the audit function in
  ONE transaction) is replaced by the test seam `:nebu_http, :oauth_switch_tx`, a 2-arity `fn changes, audit -> :ok | {:error, term}`,
  where `audit` is a 0-arity function or `nil`; the database behaviour is covered by `oauth_switch_store_db_test.exs`.

  Contract:

    * `Nebu.OAuth.save_switch(changes, opts)`, `changes = %{"oauth_enabled" => "true" | "false", "oauth_issuer_url" => binary}`;
      options `:audit` (0-arity, `:ok | {:error, reason}`, a raise counts as failed) and `:unaudited_ok` (boolean, default false).
    * `{:ok, %{audited: true}}`; `{:error, {:audit, reason}}` (nothing persisted); `{:ok, %{audited: false}}` after the retry
      without the audit function (only with `unaudited_ok: true`; one value-free ERROR log); `{:error, reason}` (no retry).
    * defence in depth: `oauth_enabled = "true"` with an issuer the runtime refuses is `{:error, :invalid_issuer}` BEFORE the
      transaction; any other key, or another `oauth_enabled` value, is `{:error, :invalid_changes}`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @on %{"oauth_enabled" => "true", "oauth_issuer_url" => "https://chat.example.com"}
  @off %{"oauth_enabled" => "false", "oauth_issuer_url" => "https://chat.example.com"}

  setup do
    test_pid = self()

    Application.put_env(:nebu_http, :oauth_switch_tx, fn changes, audit ->
      send(test_pid, {:tx, changes, audit != nil})

      case audit && audit.() do
        nil -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, {:audit, reason}}
      end
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :oauth_switch_tx) end)
    :ok
  end

  test "the audit function succeeds: one transaction, audited: true" do
    assert {:ok, %{audited: true}} = Nebu.OAuth.save_switch(@on, audit: fn -> :ok end)
    assert_received {:tx, @on, true}
    refute_received {:tx, _, _}
  end

  test "no audit function at all is refused: an unaudited change is never silently accepted" do
    assert {:error, :audit_required} = Nebu.OAuth.save_switch(@on, [])
    refute_received {:tx, _, _}
  end

  test "the audit function fails: {:error, {:audit, reason}}, ONE attempt, no retry without audit (switching on)" do
    assert {:error, {:audit, :boom}} = Nebu.OAuth.save_switch(@on, audit: fn -> {:error, :boom} end)
    assert_received {:tx, _, true}
    refute_received {:tx, _, _}
  end

  test "a raising audit function counts as failed (the caller never sees the exception)" do
    assert {:error, {:audit, _}} = Nebu.OAuth.save_switch(@on, audit: fn -> raise "audit boom" end)
    assert_received {:tx, _, true}
  end

  test "unaudited_ok: the retry runs WITHOUT the audit function, audited: false, one value-free ERROR log" do
    log =
      capture_log([level: :error], fn ->
        send(self(), {:result, Nebu.OAuth.save_switch(@off, audit: fn -> {:error, :audit_write_failed} end, unaudited_ok: true)})
      end)

    assert_received {:result, {:ok, %{audited: false}}}
    assert_received {:tx, _, true}
    assert_received {:tx, @off, false}
    refute_received {:tx, _, _}
    assert log =~ ~r/audit/i
    refute log =~ "chat.example.com"
  end

  test "unaudited_ok with a failing retry is an error (nothing was persisted)" do
    n = :counters.new(1, [])

    Application.put_env(:nebu_http, :oauth_switch_tx, fn _changes, audit ->
      :counters.add(n, 1, 1)
      if audit, do: {:error, {:audit, :x}}, else: {:error, :db_down}
    end)

    assert {:error, :db_down} = Nebu.OAuth.save_switch(@off, audit: fn -> :ok end, unaudited_ok: true)
    assert :counters.get(n, 1) == 2
  end

  test "a transaction error that is not an audit error is returned as is, no retry" do
    Application.put_env(:nebu_http, :oauth_switch_tx, fn changes, audit ->
      send(self(), {:tx, changes, audit != nil})
      {:error, :db_down}
    end)

    assert {:error, :db_down} = Nebu.OAuth.save_switch(@off, audit: fn -> :ok end, unaudited_ok: true)
    assert_received {:tx, _, true}
    refute_received {:tx, _, _}
  end

  describe "defence in depth" do
    test "enabling with an issuer the runtime refuses never reaches the transaction" do
      for issuer <- ["", "http://chat.example.com", "https://chat.example.com/x", "https://u@chat.example.com", "junk"] do
        assert {:error, :invalid_issuer} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => issuer}, audit: fn -> :ok end)
      end

      refute_received {:tx, _, _}
    end

    test "switching off with an empty issuer is fine (the empty string)" do
      assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => ""}, audit: fn -> :ok end)
      assert_received {:tx, %{"oauth_issuer_url" => ""}, true}
    end

    test "switching off with a junk issuer is refused too (nothing but a valid https issuer or the empty string is stored)" do
      for issuer <- ["junk", "http://x.example", "https://x.example/path"] do
        assert {:error, :invalid_issuer} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => issuer}, audit: fn -> :ok end), issuer
      end

      refute_received {:tx, _, _}
    end

    test "only the two keys with their exact values: anything else is :invalid_changes" do
      for bad <- [
            %{"oauth_enabled" => "yes", "oauth_issuer_url" => ""},
            %{"oauth_enabled" => "true"},
            %{"oauth_issuer_url" => "https://a.example"},
            Map.put(@off, "oauth_pending_cap", "1"),
            Map.put(@off, "oidc_user_id_claim", "email"),
            %{}
          ] do
        assert {:error, :invalid_changes} = Nebu.OAuth.save_switch(bad, audit: fn -> :ok end), inspect(bad)
      end

      refute_received {:tx, _, _}
    end
  end

  describe "no repository process (a unit run, early boot)" do
    @describetag :no_repo

    test "the real transaction answers an error, nothing is raised, and the kill switch does not loop" do
      Application.delete_env(:nebu_http, :oauth_switch_tx)
      assert {:error, _} = Nebu.OAuth.save_switch(@on, audit: fn -> :ok end)
      assert {:error, _} = Nebu.OAuth.save_switch(@off, audit: fn -> :ok end, unaudited_ok: true)
    end
  end

  describe "the public helpers" do
    test "normalize_issuer/1 is the runtime function" do
      assert Nebu.OAuth.normalize_issuer("https://chat.example.com/") == {:ok, "https://chat.example.com"}
      assert Nebu.OAuth.normalize_issuer("http://chat.example.com") == :error
      assert Nebu.OAuth.normalize_issuer(nil) == :error
    end

    test "config_cache_ms/0 follows the configured TTL (0 = cache off)" do
      T.put_env_scoped(:oauth_config_cache_ms, 3000)
      assert Nebu.OAuth.config_cache_ms() == 3000
      T.put_env_scoped(:oauth_config_cache_ms, 0)
      assert Nebu.OAuth.config_cache_ms() == 0
      T.put_env_scoped(:oauth_config_cache_ms, 99_999)
      assert Nebu.OAuth.config_cache_ms() == 0, "an out of range value is read as no cache, like Config does"
    end
  end

  describe "static hygiene" do
    test "the SQL lives in the store (ADR-018) and the admin controller reaches the domain only through Nebu.OAuth (ADR-020)" do
      store = File.read!(Path.expand("../../../lib/nebu/oauth/switch_store.ex", __DIR__))
      assert store =~ "oauth_enabled" and store =~ "INSERT INTO server_config"

      for file <- ["config_controller.ex", "oauth_switch.ex"] do
        src = File.read!(Path.expand("../../../lib/nebu/admin/#{file}", __DIR__))
        refute src =~ "Nebu.OAuth.SwitchStore", "#{file} must call Nebu.OAuth, not the store"
        refute src =~ "Nebu.OAuth.Config.", "#{file} must call Nebu.OAuth, not the config module"
        refute src =~ "Nebu.OAuth.Metadata", "#{file} must call Nebu.OAuth, not the metadata module"
      end
    end

    test "the transaction seam is compile-guarded (a stray Application.put_env in a release can never write the switch)" do
      src = File.read!(Path.expand("../../../lib/nebu/oauth/switch_store.ex", __DIR__))
      assert src =~ ~r/if Mix\.env\(\) == :test do/
    end
  end
end
