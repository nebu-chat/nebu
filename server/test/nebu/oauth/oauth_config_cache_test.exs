defmodule Nebu.OAuth.OAuthConfigCacheTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-hardening-hygiene`,
  AC1 / AC2 (HY1, HY2, HY4): the per-node TTL cache of `Nebu.OAuth.Config.get/1` and the kill
  switch under that cache.

  ## Contracts pinned here

    * ETS table `:nebu_oauth_config_cache` (public, named, owned by `Nebu.OAuth.CacheOwner`, a
      child of `Nebu.Supervisor` with child id `Nebu.OAuth.CacheOwner`); entry `{:config, map, loaded_at_ms}`.
    * TTL: `Application.get_env(:nebu_http, :oauth_config_cache_ms)` (integer, 0 = cache off;
      `config/test.exs` sets 0). `Nebu.OAuth.Config.parse_cache_ms/1` parses `NEBU_OAUTH_CONFIG_CACHE_MS`.
    * Clock seam (test-only, compile-guarded): `:nebu_http, :oauth_config_cache_clock_fn`, a 0-arity
      fun returning integer MILLISECONDS. An entry is served while `now - loaded_at < ttl`.
    * Only `{:ok, rows}` reads are cached (`:enabled` / `:disabled`); `:unknown` and `:no_repo` never;
      the `:oauth_config_source` seam bypasses the cache entirely.
    * `pending_limits/0` / `token_settings/0` stay uncached.

  Queries are counted with the Repo telemetry event of the TEST process (`[:nebu, :repo, :query]`),
  so the DB is the real one and nothing is faked. Every test restores the TTL env, the clock seam
  and empties the cache.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @config Nebu.OAuth.Config
  @owner Nebu.OAuth.CacheOwner
  @cache :nebu_oauth_config_cache
  @t0 1_000_000

  setup do
    T.clear_oauth_config()
    T.setup_idp!()
    T.reset_rate_limits()

    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, @t0)

    prior_ttl = Application.fetch_env(:nebu_http, :oauth_config_cache_ms)
    prior_clock = Application.fetch_env(:nebu_http, :oauth_config_cache_clock_fn)
    Application.put_env(:nebu_http, :oauth_config_cache_ms, 2000)
    Application.put_env(:nebu_http, :oauth_config_cache_clock_fn, fn -> :atomics.get(clock, 1) end)
    clear_cache()

    on_exit(fn ->
      restore(:oauth_config_cache_ms, prior_ttl)
      restore(:oauth_config_cache_clock_fn, prior_clock)
      Application.delete_env(:nebu_http, :oauth_config_repo)
      Application.delete_env(:nebu_http, :oauth_config_source)

      # a test that stopped the owner must leave it running
      case Supervisor.restart_child(Nebu.Supervisor, @owner) do
        {:ok, _} -> :ok
        {:ok, _, _} -> :ok
        {:error, _} -> :ok
      end

      clear_cache()
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, clock: clock}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp restore(key, {:ok, value}), do: Application.put_env(:nebu_http, key, value)
  defp restore(key, :error), do: Application.delete_env(:nebu_http, key)

  defp clear_cache, do: if(:ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache))

  defp set_clock(clock, offset_ms), do: :atomics.put(clock, 1, @t0 + offset_ms)

  defp get, do: apply(@config, :get, [])

  defp on!, do: T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => T.issuer()})
  defp off!, do: T.set_oauth_rows!(%{"oauth_enabled" => "false", "oauth_issuer_url" => T.issuer()})

  @doc false
  def handle_query(_event, _measurements, %{query: query}, %{pid: pid}) do
    if self() == pid, do: send(pid, {:db_query, query})
    :ok
  end

  # Runs `fun` and returns `{result, [sql of every query the TEST process issued]}`.
  defp with_queries(fun) do
    id = "cfg-cache-" <> T.rand()
    :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

    try do
      result = fun.()
      {result, drain_queries([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:db_query, q} -> drain_queries([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp config_reads(queries), do: Enum.count(queries, &(&1 =~ "server_config"))

  defp break_repo! do
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: Nebu.OAuth.TestSupport.BrokenRepo)
    Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.BrokenRepo)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :oauth_config_repo)
      if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
    end)
  end

  defp fix_repo!, do: Application.delete_env(:nebu_http, :oauth_config_repo)

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — the cache
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1.1 — one server_config read per TTL window" do
    test "two get/0 calls within the TTL issue ONE query; the call at now - loaded_at = TTL reads again", %{clock: clock} do
      on!()

      {_, queries} =
        with_queries(fn ->
          assert %{enabled: true, state: :enabled} = get()
          set_clock(clock, 1999)
          assert %{enabled: true, state: :enabled} = get()
        end)

      assert config_reads(queries) == 1, "the second call within the TTL must be served from the cache"

      {_, later} =
        with_queries(fn ->
          set_clock(clock, 2000)
          assert %{state: :enabled} = get()
        end)

      assert config_reads(later) == 1, "after the TTL the next call reads again"
    end

    test "live_state/1, enabled?/0 and Nebu.OAuth.config/0 share the same cached entry", %{clock: clock} do
      on!()

      {_, queries} =
        with_queries(fn ->
          assert {:live, issuer} = apply(@config, :live_state, [])
          assert issuer == T.issuer()
          set_clock(clock, 10)
          assert apply(@config, :enabled?, []) == true
          assert %{enabled: true} = apply(Nebu.OAuth, :config, [])
          assert {:live, _} = apply(@config, :live_state, [[bounded: true]])
        end)

      assert config_reads(queries) == 1
    end

    test "the entry is {:config, map, loaded_at_ms} in :nebu_oauth_config_cache", %{clock: _clock} do
      on!()
      assert %{state: :enabled} = get()
      assert [{:config, %{enabled: true, issuer_url: issuer, state: :enabled}, loaded_at}] = :ets.lookup(@cache, :config)
      assert issuer == T.issuer()
      assert loaded_at == @t0
    end

    test "pending_limits/0 and token_settings/0 stay uncached: every call reads", %{clock: _clock} do
      on!()

      {_, queries} =
        with_queries(fn ->
          apply(@config, :pending_limits, [])
          apply(@config, :pending_limits, [])
          apply(@config, :token_settings, [])
          apply(@config, :token_settings, [])
        end)

      assert config_reads(queries) == 4, "pending_limits/0 and token_settings/0 must read through (HY1)"
    end
  end

  describe "AC1.2 — an operator write becomes visible after the TTL, not before" do
    test "oauth_enabled false -> true -> false", %{clock: clock} do
      off!()
      assert %{enabled: false, state: :disabled} = get()

      on!()
      set_clock(clock, 1999)
      assert %{enabled: false, state: :disabled} = get(), "before the TTL the old value is served (bounded staleness, HY2)"
      set_clock(clock, 2000)
      assert %{enabled: true, state: :enabled} = get()

      off!()
      set_clock(clock, 2000 + 1999)
      assert %{enabled: true} = get()
      set_clock(clock, 4000)
      assert %{enabled: false, state: :disabled} = get()
    end

    test "an issuer change is visible after the TTL", %{clock: clock} do
      on!()
      assert %{issuer_url: "https://nebu.example.com"} = get()
      T.set_oauth_rows!(%{"oauth_issuer_url" => "https://other.example.com"})
      set_clock(clock, 1000)
      assert %{issuer_url: "https://nebu.example.com"} = get()
      set_clock(clock, 2500)
      assert %{issuer_url: "https://other.example.com"} = get()
    end
  end

  describe "AC1.3 — :unknown and :no_repo are never cached" do
    test "repo error => :unknown (fail closed); the next call with a healthy repo reads fresh", %{clock: _clock} do
      on!()
      break_repo!()
      assert %{state: :unknown, enabled: false, issuer_url: nil} = get()
      assert :ets.lookup(@cache, :config) == [], "an :unknown answer must not be written to the cache"

      fix_repo!()

      {conf, queries} = with_queries(fn -> get() end)
      assert %{state: :enabled, enabled: true} = conf
      assert config_reads(queries) == 1, "the healthy call right after the failure must read, not serve :unknown"
    end

    test "every call during an outage re-reads (nothing cached)", %{clock: _clock} do
      break_repo!()
      for _ <- 1..3, do: assert(%{state: :unknown} = get())
      assert :ets.lookup(@cache, :config) == []
    end

    test ":no_repo (no repository process) is :disabled and never cached", %{clock: _clock} do
      on!()
      Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.NoSuchRepo)
      assert %{state: :disabled, enabled: false} = get()
      assert :ets.lookup(@cache, :config) == []

      fix_repo!()
      assert %{state: :enabled, enabled: true} = get()
    end

    test "an expired :enabled entry followed by a read error => :unknown, not the stale value", %{clock: clock} do
      on!()
      assert %{state: :enabled} = get()
      break_repo!()
      set_clock(clock, 2000)
      assert %{state: :unknown, enabled: false} = get()
    end
  end

  describe "AC1.4 — TTL 0 and the NEBU_OAUTH_CONFIG_CACHE_MS parsing" do
    test "TTL 0 => every call reads (today's behaviour)", %{clock: _clock} do
      Application.put_env(:nebu_http, :oauth_config_cache_ms, 0)
      on!()

      {_, queries} =
        with_queries(fn ->
          get()
          get()
          get()
        end)

      assert config_reads(queries) == 3
      assert :ets.lookup(@cache, :config) == [], "TTL 0 does not write the cache either"
    end

    test "parse_cache_ms/1: \"0\" -> 0, \"5000\" -> 5000, junk / negative / too large / unset -> 2000" do
      for {input, expected} <- [
            {"0", 0},
            {"5000", 5000},
            {"1", 1},
            {"2500", 2500},
            {"abc", 2000},
            {"-1", 2000},
            {"5001", 2000},
            {"", 2000},
            {"1.5", 2000},
            {nil, 2000}
          ] do
        assert apply(@config, :parse_cache_ms, [input]) == expected, "parse_cache_ms(#{inspect(input)})"
      end
    end
  end

  describe "AC1.5 — the :oauth_config_source seam bypasses the cache" do
    test "neither read nor written; a pre-filled entry is ignored", %{clock: _clock} do
      :ets.insert(@cache, {:config, %{enabled: true, issuer_url: "https://stale.example.com", state: :enabled}, @t0})
      T.disable_oauth()

      assert %{enabled: false, state: :disabled} = get()

      T.enable_oauth("https://seam.example.com")
      assert %{enabled: true, issuer_url: "https://seam.example.com"} = get()

      assert [{:config, %{issuer_url: "https://stale.example.com"}, @t0}] = :ets.lookup(@cache, :config),
             "the seam must not touch the cache entry"
    end

    test "the seam with an empty cache writes nothing", %{clock: _clock} do
      T.enable_oauth()
      get()
      assert :ets.lookup(@cache, :config) == []
    end
  end

  describe "AC1.6 / HY4 — table absent (CacheOwner not running) => read-through, no exception, no table created" do
    test "get/0 and /versions work without the owner and create no table", %{clock: _clock} do
      on!()
      assert :ok = Supervisor.terminate_child(Nebu.Supervisor, @owner)
      assert :ets.whereis(@cache) == :undefined, "the owner's tables are gone with it"

      assert %{state: :enabled, enabled: true} = get()
      assert {:live, _} = apply(@config, :live_state, [])
      assert T.versions().status == 200
      assert T.get_metadata().status == 200

      assert :ets.whereis(@cache) == :undefined, "a request process must never create the cache table"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — /versions, discovery and the kill switch under the cache
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2.1 — /versions" do
    test "a warm cache answers v1.1-v1.15 with ZERO DB queries", %{clock: _clock} do
      on!()
      assert %{state: :enabled} = get()

      {conn, queries} = with_queries(fn -> T.versions() end)
      assert conn.status == 200
      assert T.json(conn) == T.versions_on_map()
      assert config_reads(queries) == 0, "a cache hit must not read server_config, got #{inspect(queries)}"
      assert Enum.all?(queries, &(not (&1 =~ "oauth"))), "no OAuth query either: #{inspect(queries)}"
    end

    test "a broken repo and a cold cache answer v1.1-v1.11 (fail closed, never 5xx) and cache nothing", %{clock: _clock} do
      on!()
      break_repo!()
      conn = T.versions()
      assert conn.status == 200
      assert T.json(conn) == T.versions_off_map()
      assert :ets.lookup(@cache, :config) == []
    end

    test "a cold-cache bounded read fills the cache for the next request (hit without a query)", %{clock: _clock} do
      on!()
      assert T.json(T.versions()) == T.versions_on_map()

      {conn, queries} = with_queries(fn -> T.versions() end)
      assert T.json(conn) == T.versions_on_map()
      assert config_reads(queries) == 0
    end
  end

  # (name, request fun, predicate "OAuth is on") — the ONE cached state drives all of them
  @probes [
    {"auth_metadata", :probe_metadata, :on_200},
    {"auth_issuer", :probe_issuer, :nebu_issuer},
    {"unstable auth_metadata alias", :probe_unstable, :nebu_issuer},
    {"openid-configuration", :probe_openid, :on_200},
    {"jwks", :probe_jwks, :on_200},
    {"token endpoint", :probe_token, :not_404},
    {"authorize", :probe_authorize, :not_404},
    {"account", :probe_account, :not_404},
    {"GET /login flags", :probe_login, :flags},
    {"/versions", :probe_versions, :v115}
  ]

  @pure_discovery ["auth_metadata", "auth_issuer", "unstable auth_metadata alias", "openid-configuration", "GET /login flags", "/versions"]

  @doc false
  def probe_metadata, do: T.get_metadata()
  @doc false
  def probe_issuer, do: T.get("/_matrix/client/v1/auth_issuer")
  @doc false
  def probe_unstable, do: T.get("/_matrix/client/unstable/org.matrix.msc2965/auth_metadata")
  @doc false
  def probe_openid, do: T.get("/.well-known/openid-configuration")
  @doc false
  def probe_jwks, do: T.jwks()
  @doc false
  def probe_token, do: T.token_request([])
  @doc false
  def probe_authorize, do: T.get("/oauth2/authorize")
  @doc false
  def probe_account, do: T.account_get("/account")
  @doc false
  def probe_login, do: T.login_flows()
  @doc false
  def probe_versions, do: T.versions()

  defp oauth_on?(conn, :on_200), do: conn.status == 200
  defp oauth_on?(conn, :not_404), do: conn.status != 404

  # the OAuthDiscovery paths answer 200 in BOTH states: Nebu's issuer while OAuth is on, the legacy IdP passthrough
  # (the IdP's issuer) while it is off; only the issuer tells the two apart
  defp oauth_on?(conn, :nebu_issuer), do: conn.status == 200 and Jason.decode!(conn.resp_body)["issuer"] == T.issuer()

  defp oauth_on?(conn, :flags) do
    flows = (Jason.decode!(conn.resp_body)["flows"] || [])
    sso = Enum.find(flows, %{}, &(&1["type"] == "m.login.sso"))
    Map.has_key?(sso, "oauth_aware_preferred")
  end

  defp oauth_on?(conn, :v115), do: "v1.15" in (Jason.decode!(conn.resp_body)["versions"] || [])

  describe "AC2.2 — every surface observes the SAME cached state within one TTL window" do
    for {name, probe, mode} <- @probes do
      test "#{name}: flip via DB => old answer before the TTL, new answer after", %{clock: clock} do
        probe = fn -> apply(__MODULE__, unquote(probe), []) end
        mode = unquote(mode)

        on!()
        assert oauth_on?(probe.(), mode), "#{unquote(name)}: expected the ON answer first"

        off!()
        set_clock(clock, 1999)
        assert oauth_on?(probe.(), mode), "#{unquote(name)}: still the ON answer within the TTL (cached)"

        set_clock(clock, 2000)
        refute oauth_on?(probe.(), mode), "#{unquote(name)}: the OFF answer once the TTL has elapsed"
      end
    end

    test "the surfaces read ONE shared entry: a single query serves a whole round of requests", %{clock: _clock} do
      on!()

      {_, queries} =
        with_queries(fn ->
          for {name, probe, _mode} <- @probes, name in @pure_discovery, do: apply(__MODULE__, probe, [])
        end)

      # only the pure discovery surfaces: token / account / jwks touch other tables or the uncached settings
      assert config_reads(queries) == 1, "expected ONE server_config read for all probes, got #{config_reads(queries)}"
    end
  end

  describe "AC2.3 — enabled -> :unknown while a cached :enabled entry is younger than the TTL" do
    test "the cached value is served until it expires; then :unknown answers on every surface", %{clock: clock} do
      on!()
      assert %{state: :enabled} = get()
      break_repo!()

      set_clock(clock, 1999)
      assert %{state: :enabled, enabled: true} = get(), "documented bounded staleness: the cached value is served"
      assert T.get_metadata().status == 200

      set_clock(clock, 2000)
      assert %{state: :unknown, enabled: false} = get()

      # the OAuthDiscovery paths: 503 (no IdP passthrough)
      # the stable v1 auth_metadata is Nebu's own document (not an OAuthDiscovery path): fail closed 404 M_UNRECOGNIZED
      assert T.get_metadata().status == 404
      assert T.get("/_matrix/client/v1/auth_issuer").status == 503
      assert T.get("/_matrix/client/unstable/org.matrix.msc2965/auth_metadata").status == 503

      # token / JWKS / openid-configuration: 503 with an empty JSON object
      T.token_request([]) |> T.assert_token_5xx()
      T.jwks() |> T.assert_5xx_empty(503)
      T.get("/.well-known/openid-configuration") |> T.assert_5xx_empty(503)

      # /versions: v1.1-v1.11
      assert T.json(T.versions()) == T.versions_off_map()
    end
  end
end

defmodule Nebu.OAuth.OAuthConfigCacheDefaultsTest do
  @moduledoc """
  Story `oauth-hardening-hygiene` HY1: no DB needed. The ExUnit run reads through (TTL 0 from
  `config/test.exs`; `config/runtime.exs` must not override it), and the pure parser.
  """
  use ExUnit.Case, async: false

  test "config/test.exs sets the TTL to 0 (ExUnit stays read-through)" do
    assert Application.get_env(:nebu_http, :oauth_config_cache_ms) == 0
  end

  test "parse_cache_ms/1 is a pure function with the documented table" do
    assert Code.ensure_loaded?(Nebu.OAuth.Config)
    assert function_exported?(Nebu.OAuth.Config, :parse_cache_ms, 1)

    table = [{"0", 0}, {"5000", 5000}, {"abc", 2000}, {"-1", 2000}, {"5001", 2000}, {nil, 2000}]

    for {input, expected} <- table do
      assert apply(Nebu.OAuth.Config, :parse_cache_ms, [input]) == expected
    end
  end
end
