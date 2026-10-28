defmodule Nebu.OAuth.OAuthConfigTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-metadata-dcr-admin-approval`
  (test-review m2): the REAL config path of `Nebu.OAuth.Config`
  (`server/lib/nebu/oauth/config.ex`).

  Every other test in `server/test/nebu/oauth/` injects the config through the
  `:oauth_config_source` seam; this file deliberately does NOT install it, so
  `Nebu.OAuth.Config.get/0` must read `oauth_enabled` from `server_config` itself:

    * `"true"`  => `%{enabled: true}`
    * `"false"` => `%{enabled: false}`
    * any other / unparsable value => `enabled: false` (fail closed)
    * key absent => `enabled: false` (story: "`oauth_enabled` (boolean, default false)")

  The read is request-scoped and uncached (metadata test moduledoc: "stateless, request-scoped
  config read"), so an UPDATE is visible to the very next `get/0` call and to the HTTP endpoints.

  The key the issuer URL is read from is NOT pinned here (dev's choice, see ATDD Decisions);
  issuer handling (https-only, fail closed) is covered through the seam in
  `oauth_metadata_test.exs`.

  `server_config` is under FORCE ROW LEVEL SECURITY and the runtime role cannot DELETE, so the
  tests write through UPDATE (which requires migration 000040 to extend `config_update_mutable`
  with `oauth_enabled`, see `000040_oauth_clients_test.exs`) and restore the prior value.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  # Module attribute indirection: keeps this DB-backed test file free of a compile-time
  # dependency on the config module (CI runs --warnings-as-errors).
  @config Nebu.OAuth.Config
  defp config_get, do: apply(@config, :get, [])

  setup do
    T.clear_oauth_config()
    prior = T.sql!("SELECT value FROM server_config WHERE key = 'oauth_enabled'").rows

    on_exit(fn ->
      value =
        case prior do
          [[v]] -> v
          _ -> "false"
        end

      T.sql!(
        "INSERT INTO server_config (key, value, set_at) VALUES ('oauth_enabled', $1, 0) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        [value]
      )
    end)

    {:ok, prior: prior}
  end

  defp set_enabled!(value) do
    T.sql!(
      "INSERT INTO server_config (key, value, set_at) VALUES ('oauth_enabled', $1, 0) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [value]
    )
  end

  test "module Nebu.OAuth.Config exists and exposes get/0" do
    assert Code.ensure_loaded?(@config), "Nebu.OAuth.Config is not loadable"
    assert function_exported?(@config, :get, 0)
  end

  test "oauth_enabled = 'true' in server_config => enabled: true (no seam installed)" do
    set_enabled!("true")
    assert %{enabled: true} = config_get()
  end

  test "oauth_enabled = 'false' in server_config => enabled: false" do
    set_enabled!("false")
    assert %{enabled: false} = config_get()
  end

  # story oauth-hardening-hygiene HY1: config/test.exs sets :oauth_config_cache_ms to 0, so ExUnit stays read-through;
  # the TTL cache itself is covered by oauth_config_cache_test.exs
  test "a changed value is visible immediately (TTL 0 in ExUnit: no stale cache between get/0 calls)" do
    set_enabled!("false")
    assert %{enabled: false} = config_get()
    set_enabled!("true")
    assert %{enabled: true} = config_get()
    set_enabled!("false")
    assert %{enabled: false} = config_get()
  end

  test "an unparsable value fails closed (enabled: false)" do
    set_enabled!("definitely-not-a-boolean")
    assert %{enabled: false} = config_get()
  end

  test "key absent => enabled: false (default)" do
    # The runtime role cannot DELETE from server_config, so absence is only observable while no
    # test/stack has written the key yet (fresh CI stack, first run); otherwise this is a no-op.
    case T.sql!("SELECT 1 FROM server_config WHERE key = 'oauth_enabled'").rows do
      [] -> assert %{enabled: false} = config_get()
      _present -> :ok
    end
  end

  describe "N-4 — three states: enabled / disabled / unknown" do
    test "the database values map to :enabled and :disabled" do
      set_enabled!("true")
      assert %{state: :enabled} = config_get()
      set_enabled!("false")
      assert %{state: :disabled} = config_get()
      set_enabled!("garbage")
      assert %{state: :disabled, enabled: false} = config_get()
    end

    test "a server_config read that FAILS is :unknown (not :disabled), still fail closed (enabled: false)" do
      # A registered process that is no Ecto repo: Ecto.Adapters.SQL.query/3 raises on it.
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: Nebu.OAuth.TestSupport.BrokenRepo)
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.BrokenRepo)

      on_exit(fn ->
        Application.delete_env(:nebu_http, :oauth_config_repo)
        if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
      end)

      assert %{state: :unknown, enabled: false, issuer_url: nil} = config_get()
    end

    test "no repository process at all (unit/boot) is :disabled, i.e. the pre-broker behaviour" do
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.NoSuchRepo)
      on_exit(fn -> Application.delete_env(:nebu_http, :oauth_config_repo) end)

      assert %{state: :disabled, enabled: false} = config_get()
    end

    test "discovery answers 503 (no IdP passthrough) while the config is unreadable" do
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: Nebu.OAuth.TestSupport.BrokenRepo)
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.BrokenRepo)

      on_exit(fn ->
        Application.delete_env(:nebu_http, :oauth_config_repo)
        if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
      end)

      assert T.get("/_matrix/client/v1/auth_issuer").status == 503
    end
  end

  # ── story oauth-token-endpoint (story 3), AC15 — token settings from server_config ──
  describe "AC15 (story 3) — token_settings/0 reads oauth_access_token_ttl_seconds / oauth_idp_revalidation" do
    setup do
      on_exit(fn ->
        T.privileged_sql!(
          "DELETE FROM server_config WHERE key IN ('oauth_access_token_ttl_seconds', 'oauth_idp_revalidation')"
        )
      end)

      :ok
    end

    defp put_key!(key, value) do
      T.sql!(
        "INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, 0) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        [key, value]
      )
    end

    test "both keys are read from server_config (no seam installed); later UPDATEs are visible" do
      put_key!("oauth_access_token_ttl_seconds", "600")
      put_key!("oauth_idp_revalidation", "off")
      assert apply(@config, :token_settings, []) == %{access_token_ttl_seconds: 600, idp_revalidation: :off}

      put_key!("oauth_access_token_ttl_seconds", "1200")
      put_key!("oauth_idp_revalidation", "per_refresh")
      assert apply(@config, :token_settings, []) == %{access_token_ttl_seconds: 1200, idp_revalidation: :per_refresh}
    end

    test "invalid stored values fall back to the defaults (900, :per_refresh)" do
      put_key!("oauth_access_token_ttl_seconds", "999999")
      put_key!("oauth_idp_revalidation", "sometimes")
      assert apply(@config, :token_settings, []) == %{access_token_ttl_seconds: 900, idp_revalidation: :per_refresh}
    end

    test "an unreadable server_config => defaults, never raises" do
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: Nebu.OAuth.TestSupport.BrokenRepo)
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.BrokenRepo)

      on_exit(fn ->
        Application.delete_env(:nebu_http, :oauth_config_repo)
        if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
      end)

      assert apply(@config, :token_settings, []) == %{access_token_ttl_seconds: 900, idp_revalidation: :per_refresh}
    end
  end

  describe "end to end through the HTTP endpoints (no seam, server_config only)" do
    setup do
      T.reset_rate_limits()
      on_exit(&T.restore_rate_limits/0)
      :ok
    end

    test "oauth_enabled = 'false' => /oauth2/register and auth_metadata answer 404 M_UNRECOGNIZED" do
      set_enabled!("false")
      T.register(T.web_body()) |> T.assert_unrecognized_404()
      T.get_metadata() |> T.assert_unrecognized_404()
    end

    test "oauth_enabled = 'true' => /oauth2/register is live (an invalid body is a 400, not a 404)" do
      set_enabled!("true")
      T.register(%{"client_uri" => "http://bad"}) |> T.assert_oauth_error(400, "invalid_client_metadata")
    end
  end
end

defmodule Nebu.OAuth.OAuthTokenSettingsTest do
  @moduledoc """
  RED-phase unit tests for story `oauth-token-endpoint` (story 3), AC15 / T4 / T5:
  `Nebu.OAuth.Config.token_settings/0 :: %{access_token_ttl_seconds: 60..3600, idp_revalidation:
  :per_refresh | :off}` through the `:oauth_config_source` seam (optional map keys
  `:access_token_ttl_seconds` / `:idp_revalidation`, raw server_config text or integer/atom).
  Defaults 900 / `:per_refresh` for absent, invalid or unreadable values; never raises; never
  "unlimited". Red today: `token_settings/0` does not exist.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @config Nebu.OAuth.Config

  setup do
    on_exit(&T.clear_oauth_config/0)
    :ok
  end

  defp settings(extra) do
    T.enable_oauth(T.issuer(), extra)
    apply(@config, :token_settings, [])
  end

  test "defaults without the seam keys: 900 s, :per_refresh" do
    T.enable_oauth()
    assert apply(@config, :token_settings, []) == %{access_token_ttl_seconds: 900, idp_revalidation: :per_refresh}
  end

  for {v, expected} <- [{"600", 600}, {600, 600}, {"60", 60}, {"3600", 3600}, {60, 60}, {3600, 3600}] do
    test "TTL #{inspect(v)} => #{expected}" do
      assert %{access_token_ttl_seconds: unquote(expected)} = settings(%{access_token_ttl_seconds: unquote(v)})
    end
  end

  for v <- [59, 3601, "59", "3601", "abc", "-5", "0", "", "900.5", nil, 0] do
    test "TTL #{inspect(v)} (out of range / junk) => 900, never unlimited" do
      assert %{access_token_ttl_seconds: 900} = settings(%{access_token_ttl_seconds: unquote(v)})
    end
  end

  for {v, expected} <- [{"off", :off}, {:off, :off}, {"per_refresh", :per_refresh}, {:per_refresh, :per_refresh},
                        {"bogus", :per_refresh}, {"", :per_refresh}, {nil, :per_refresh}] do
    test "idp_revalidation #{inspect(v)} => #{inspect(expected)} (fail safe default)" do
      assert %{idp_revalidation: unquote(expected)} = settings(%{idp_revalidation: unquote(v)})
    end
  end

  test ":unknown (unreadable) config => defaults, never raises" do
    T.unreadable_oauth_config()
    assert apply(@config, :token_settings, []) == %{access_token_ttl_seconds: 900, idp_revalidation: :per_refresh}
  end

  test "a disabled config still yields valid settings (the endpoints are off anyway)" do
    T.disable_oauth()
    assert %{access_token_ttl_seconds: 900, idp_revalidation: :per_refresh} = apply(@config, :token_settings, [])
  end
end
