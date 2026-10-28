defmodule Nebu.OAuth.TestSupport do
  @moduledoc """
  Shared helpers for the oauth-broker story `oauth-metadata-dcr-admin-approval` tests.

  ## Test seams this story's implementation MUST honour

  The story requires `oauth_enabled` (default `false`) and an issuer URL to be loaded by
  a new `Nebu.OAuth.Config` module (`server/lib/nebu/oauth/config.ex`, persisted in
  `server_config`). Unit tests have no live Postgres, so — exactly like
  `Nebu.Web.OidcConfig` / `:oidc_config_source` (ADR-022 test idiom, see
  `Nebu.Web.OidcTestSupport`) — the config MUST be overridable through a 0-arity fun:

      Application.put_env(:nebu_http, :oauth_config_source, fn ->
        %{enabled: true, issuer_url: "https://nebu.example.com"}
      end)

  When the seam is NOT installed and no DB is reachable the config MUST fall back to
  `enabled: false` (story: "`oauth_enabled` (boolean, default false)").

  Rate limiting reuses the existing `Nebu.Web.Plugs.RateLimit` bucket table
  (`:nebu_http_rate_limit_buckets`) and its `:rate_limit_clock_fn` seam. Every request
  helper here uses a UNIQUE peer IP so per-IP buckets never bleed between tests.
  """
  import Plug.Test
  import Plug.Conn

  @router_opts Nebu.Web.Router.init([])

  @issuer "https://nebu.example.com"

  def issuer, do: @issuer

  # ── config seam ────────────────────────────────────────────────────────────

  def enable_oauth(issuer_url \\ @issuer) do
    Application.put_env(:nebu_http, :oauth_config_source, fn ->
      %{enabled: true, issuer_url: issuer_url}
    end)

    :ok
  end

  @doc """
  Story 3 (oauth-token-endpoint, AC15): like `enable_oauth/1`, plus extra seam keys merged into the
  config map: `:access_token_ttl_seconds` / `:idp_revalidation`. The values are what
  `server_config` stores (RAW text such as `"900"`, `"off"`, `"per_refresh"`, junk); an integer TTL
  or an atom mode is normalized the same way. `Nebu.OAuth.Config.token_settings/0` must honour them.
  """
  def enable_oauth(issuer_url, extra) when is_map(extra) do
    Application.put_env(:nebu_http, :oauth_config_source, fn ->
      Map.merge(%{enabled: true, issuer_url: issuer_url}, extra)
    end)

    :ok
  end

  def disable_oauth do
    Application.put_env(:nebu_http, :oauth_config_source, fn ->
      %{enabled: false, issuer_url: @issuer}
    end)

    :ok
  end

  @doc "Simulates an UNREADABLE server_config (DB timeout etc.): `Nebu.OAuth.Config` state `:unknown` (security review N-4)."
  def unreadable_oauth_config do
    Application.put_env(:nebu_http, :oauth_config_source, fn -> :unknown end)
    :ok
  end

  def clear_oauth_config, do: Application.delete_env(:nebu_http, :oauth_config_source)

  # ── rate-limit isolation ───────────────────────────────────────────────────

  @bucket_table :nebu_http_rate_limit_buckets
  @rl_keys [:rate_limit_disabled, :rate_limit_clock_fn]
  @rl_saved :oauth_test_prior_rate_limit_env

  @doc """
  Re-enable the limiter, freeze its clock (no refill => deterministic) and empty the buckets.

  The PRIOR values of `:rate_limit_disabled` / `:rate_limit_clock_fn` are remembered (first call
  wins, so nested/repeated resets keep the original) and put back by `restore_rate_limits/0`
  instead of being blindly deleted — a suite-wide setting must survive these tests.
  """
  def reset_rate_limits do
    if Application.get_env(:nebu_http, @rl_saved) == nil do
      prior = Map.new(@rl_keys, fn k -> {k, Application.fetch_env(:nebu_http, k)} end)
      Application.put_env(:nebu_http, @rl_saved, prior)
    end

    Application.delete_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 1_000_000 end)
    clear_buckets()
    :ok
  end

  @doc "Restore the rate-limit env captured by `reset_rate_limits/0` (no-op if nothing was captured) and empty the buckets."
  def restore_rate_limits do
    case Application.get_env(:nebu_http, @rl_saved) do
      nil ->
        :ok

      prior ->
        for {k, v} <- prior do
          case v do
            {:ok, value} -> Application.put_env(:nebu_http, k, value)
            :error -> Application.delete_env(:nebu_http, k)
          end
        end

        Application.delete_env(:nebu_http, @rl_saved)
    end

    clear_buckets()
    :ok
  end

  defp clear_buckets do
    if :ets.whereis(@bucket_table) != :undefined, do: :ets.delete_all_objects(@bucket_table)
    :ok
  end

  @doc "A peer IP unique per call (10.x.y.z) so per-IP buckets are fresh."
  def unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  # ── request helpers (full Nebu.Web.Router, no Admin endpoint) ──────────────

  def get_metadata(opts \\ []) do
    conn(:get, "/_matrix/client/v1/auth_metadata")
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "GET an arbitrary path through the full router (unique peer IP unless `:ip` is given)."
  def get(path, opts \\ []) do
    conn(:get, path)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  def options(path, opts \\ []) do
    conn(:options, path)
    |> put_req_header("origin", "https://client.example.com")
    |> put_req_header("access-control-request-method", Keyword.get(opts, :request_method, "POST"))
    |> put_req_header(
      "access-control-request-headers",
      Keyword.get(opts, :request_headers, "content-type, authorization")
    )
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "POST /oauth2/register with a map (JSON-encoded) or a raw binary body."
  def register(body, opts \\ []) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    conn(:post, "/oauth2/register", raw)
    |> put_req_header("content-type", "application/json")
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  defp with_opts(conn, opts) do
    conn =
      case Keyword.get(opts, :origin) do
        nil -> conn
        origin -> put_req_header(conn, "origin", origin)
      end

    # Story oauth-trusted-proxy-client-ip (AC5.2): optional `:xff` => one `x-forwarded-for` request
    # header. Without `NEBU_TRUSTED_PROXY_CIDRS` configured it is ignored by the server, so every
    # existing test keeps its own per-peer bucket.
    conn =
      case Keyword.get(opts, :xff) do
        nil -> conn
        xff -> put_req_header(conn, "x-forwarded-for", xff)
      end

    %{conn | remote_ip: Keyword.get(opts, :ip, unique_ip())}
  end

  def json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, body} ->
        body

      {:error, _} ->
        ExUnit.Assertions.flunk(
          "expected a JSON response body, got HTTP #{conn.status} #{inspect(conn.resp_body)}"
        )
    end
  end

  def header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  # ── request bodies ─────────────────────────────────────────────────────────

  @doc """
  Valid web client metadata on a FIXED client_uri host (example.com); client_name is unique.

  The name carries a random suffix besides `unique_integer` (which restarts on every VM boot):
  approved/rejected rows cannot be deleted by the runtime role, so on a non-fresh database a
  name from an earlier run would dedup onto an already decided registration.
  """
  def web_body(overrides \\ %{}) do
    n = "#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    Map.merge(
      %{
        "client_name" => "TestApp-#{n}",
        "client_uri" => "https://example.com",
        "redirect_uris" => ["https://example.com/callback"],
        "application_type" => "web"
      },
      overrides
    )
  end

  def native_body(overrides \\ %{}) do
    web_body(
      Map.merge(
        %{"application_type" => "native", "redirect_uris" => ["com.example.app:/oauth2/callback"]},
        overrides
      )
    )
  end

  # ── RFC 7591 3.2.2 error assertions ────────────────────────────────────────

  import ExUnit.Assertions

  def assert_oauth_error(conn, status, error_code) do
    assert conn.status == status,
           "expected HTTP #{status}, got #{conn.status} (body: #{inspect(conn.resp_body)})"

    body = json(conn)
    assert body["error"] == error_code, "expected error=#{error_code}, got #{inspect(body)}"
    assert is_binary(body["error_description"]) and body["error_description"] != "",
           "RFC 7591 3.2.2 requires a human-readable error_description"

    refute Map.has_key?(body, "errcode"),
           "DCR errors use the OAuth shape, NOT the Matrix error shape (no errcode)"

    assert (header(conn, "content-type") || "") =~ "application/json"
    conn
  end

  def assert_unrecognized_404(conn) do
    assert conn.status == 404, "expected 404, got #{conn.status} (body: #{inspect(conn.resp_body)})"
    body = json(conn)
    assert body["errcode"] == "M_UNRECOGNIZED", "expected errcode M_UNRECOGNIZED, got #{inspect(body)}"
    assert is_binary(body["error"]) and body["error"] != ""
    refute Map.has_key?(body, "error_description"), "disabled OAuth uses the MATRIX error shape"
    conn
  end

  @doc """
  Story 3 review cycle 1 (MINOR 1): the kill-switch 404 of `/oauth2/token`, `/oauth2/jwks` and
  `/.well-known/openid-configuration` keeps `errcode: M_UNRECOGNIZED` but has NO `error` member
  (oidc-client-ts turns ANY JSON with `error` into an ErrorResponse => matrix-js-sdk logout, so an
  operator flipping the kill switch must not log refreshing clients out; oracle C2).
  """
  def assert_unrecognized_404_no_error(conn) do
    assert conn.status == 404, "expected 404, got #{conn.status} (body: #{inspect(conn.resp_body)})"
    body = json(conn)
    assert body == %{"errcode" => "M_UNRECOGNIZED"}, "expected exactly errcode M_UNRECOGNIZED (no `error` member), got #{inspect(body)}"
    conn
  end

  # ── DB helpers (integration only) ──────────────────────────────────────────

  def sql!(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Nebu.Repo, sql, params)

  @doc """
  Polls (<= 10 s, every 20 ms) until a backend of the test database waits for a row lock: the deterministic replacement
  for `Task.yield(task, 500) == nil` ("the teardown waits for the held devices row"). The request-path device locks are
  bounded (300 ms, story revoke-lock-bounds D6), so a test that holds a lock must not sit on it for 500 ms before it
  proceeds; it only has to know that the other side is parked on the lock.
  """
  def await_lock_wait!(n \\ 1, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    sql!("SELECT pg_stat_clear_snapshot()")

    %{rows: [[waiting]]} =
      sql!("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()")

    cond do
      waiting >= n -> :ok
      System.monotonic_time(:millisecond) > deadline -> raise "only #{waiting} of #{n} backends wait for a lock: the request was not blocked by the held row"
      true -> Process.sleep(20) && await_lock_wait!(n, deadline)
    end
  end

  def client_row(client_id) do
    %{rows: rows, columns: cols} =
      sql!("SELECT * FROM oauth_clients WHERE client_id = $1", [client_id])

    case rows do
      [] -> nil
      [row] -> cols |> Enum.zip(row) |> Map.new()
    end
  end

  @doc """
  Creates a registration row in the given status the way the database allows it (security review
  F-3: the INSERT policy admits only `pending` rows without decision data): INSERT pending, then
  UPDATE the decision. `created_at_sql` is a SQL expression for `created_at`.
  """
  def insert_row!(client_id, metadata, hash, status, created_at_sql \\ "NOW()", application_type \\ "web", extra \\ []) do
    # Story oauth-dcr-abuse-hardening: `extra` (keyword) may set `:client_host`, `:client_domain`
    # and `:source_key` at INSERT time. Only the columns that are GIVEN are written, so every
    # existing caller keeps working on a schema without migration 000044.
    # object-typed jsonb, as production stores it (a JSON TEXT passed to a `::jsonb` parameter would be stored as a
    # jsonb STRING); callers may pass a JSON text or an already decoded map
    metadata = if is_binary(metadata), do: Jason.decode!(metadata), else: metadata
    extra_cols = for {k, v} <- extra, k in [:client_host, :client_domain, :source_key], v != nil, do: {Atom.to_string(k), v}
    col_sql = Enum.map_join(extra_cols, "", fn {c, _} -> ", " <> c end)
    val_sql = extra_cols |> Enum.with_index(5) |> Enum.map_join("", fn {_, i} -> ", $#{i}" end)

    sql!(
      "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type, created_at, created_from_ip, user_agent#{col_sql}) " <>
        "VALUES ($1, $2::jsonb, $3, $4, #{created_at_sql}, '203.0.113.7', 'TestAgent/1.0'#{val_sql})",
      [client_id, metadata, hash, application_type | Enum.map(extra_cols, &elem(&1, 1))]
    )

    case status do
      "pending" ->
        :ok

      "approved" ->
        sql!(
          "UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = NOW() WHERE client_id = $1",
          [client_id]
        )

      "rejected" ->
        sql!(
          "UPDATE oauth_clients SET status = 'rejected', rejected_by = '@admin:test.local', rejected_at = NOW() WHERE client_id = $1",
          [client_id]
        )

      # story oauth-client-revocation: approved first (the attribution is kept), then revoked (000046)
      "revoked" ->
        sql!(
          "UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = NOW() WHERE client_id = $1",
          [client_id]
        )

        :ok = mark_revoked!(client_id, Keyword.get(extra, :revoked_by, "@admin:test.local"), Keyword.get(extra, :revoked_reason))
    end

    :ok
  end

  def count_by_hash(hash) do
    %{rows: [[n]]} = sql!("SELECT count(*) FROM oauth_clients WHERE metadata_hash = $1", [hash])
    n
  end

  def count_by_client_name(name) do
    %{rows: [[n]]} =
      sql!("SELECT count(*) FROM oauth_clients WHERE metadata->>'client_name' = $1", [name])

    n
  end

  @doc """
  Deletes the given registrations as the PRIVILEGED migrate role.

  `oauth_clients` has FORCE ROW LEVEL SECURITY and the runtime role (`nebu_app`) may only DELETE
  `pending` rows, so a DELETE through `Nebu.Repo` silently removes 0 approved/rejected rows and
  leaks them into persistent databases. This opens a short-lived connection with
  `NEBU_DB_URL_MIGRATE` (the table owner / BYPASSRLS role, set in the Makefile, docker-compose and
  both CI integration jobs; falls back to `NEBU_DB_URL` exactly like `Nebu.Release.migrate/0`) and
  raises if a row is still there afterwards — a failed cleanup is never swallowed.
  """
  def cleanup_clients([]), do: :ok

  def cleanup_clients(client_ids) do
    url =
      System.get_env("NEBU_DB_URL_MIGRATE") || System.get_env("NEBU_DB_URL") ||
        raise "NEBU_DB_URL_MIGRATE (or NEBU_DB_URL) is not set - cannot clean up oauth_clients"

    uri = URI.parse(url)
    {user, pass} = userinfo(uri.userinfo)

    {:ok, conn} =
      Postgrex.start_link(
        [
          hostname: uri.host || "localhost",
          port: uri.port || 5432,
          username: user,
          password: pass,
          database: String.trim_leading(uri.path || "", "/"),
          pool_size: 1
        ] ++ Nebu.Release.postgres_ssl_opts(uri.host)
      )

    try do
      # Story 3 (oauth-token-endpoint, Trap 9): `matrix_sessions.client_id` REFERENCES
      # oauth_clients ON DELETE RESTRICT, so the clients' session rows go first. Guarded on the
      # column's existence so the story-1/2 suites keep working on a schema without 000042.
      case Postgrex.query!(
             conn,
             "SELECT 1 FROM information_schema.columns WHERE table_name = 'matrix_sessions' AND column_name = 'client_id'",
             []
           ) do
        %{num_rows: 0} -> :ok
        _ -> Postgrex.query!(conn, "DELETE FROM matrix_sessions WHERE client_id = ANY($1)", [client_ids])
      end

      Postgrex.query!(conn, "DELETE FROM oauth_clients WHERE client_id = ANY($1)", [client_ids])

      %{rows: [[left]]} =
        Postgrex.query!(conn, "SELECT count(*) FROM oauth_clients WHERE client_id = ANY($1)", [client_ids])

      if left != 0 do
        raise "oauth_clients cleanup left #{left} row(s) behind - the cleanup connection is not " <>
                "privileged (set NEBU_DB_URL_MIGRATE to a BYPASSRLS/owner role)"
      end

      :ok
    after
      GenServer.stop(conn)
    end
  end

  defp userinfo(nil), do: {nil, nil}

  defp userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [u, p] -> {u, p}
      [u] -> {u, nil}
    end
  end

  @doc """
  Runs `fun.(postgrex_conn)` on a short-lived connection as the PRIVILEGED migrate role
  (`NEBU_DB_URL_MIGRATE`, falls back to `NEBU_DB_URL`; same resolution as `cleanup_clients/1`).
  Used by the 000041 down/up round trip (inside a rolled-back transaction).
  """
  def with_privileged_conn(fun) do
    url =
      System.get_env("NEBU_DB_URL_MIGRATE") || System.get_env("NEBU_DB_URL") ||
        raise "NEBU_DB_URL_MIGRATE (or NEBU_DB_URL) is not set"

    uri = URI.parse(url)
    {user, pass} = userinfo(uri.userinfo)

    {:ok, conn} =
      Postgrex.start_link(
        [
          hostname: uri.host || "localhost",
          port: uri.port || 5432,
          username: user,
          password: pass,
          database: String.trim_leading(uri.path || "", "/"),
          pool_size: 1
        ] ++ Nebu.Release.postgres_ssl_opts(uri.host)
      )

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story 2 (oauth-authorize-idp-delegation-code): authorize / IdP callback helpers
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Seams and names the implementation MUST honour (also recorded in the story under
  # "ATDD Decisions (story 2)"):
  #
  #   * `:nebu_http, :oauth_config_source` (story 1) enables OAuth; the issuer must be https.
  #   * The IdP leg uses the EXISTING SsoLogin seams: `:oidc_metadata_override` (discovery doc,
  #     incl. an optional `prompt_values_supported`), `:sso_bootstrap_reader` (IdP client id /
  #     secret), `:matrix_sso_token_override` (0-arity fun => `{:ok, id_token, idp_rt | nil}`),
  #     `:oidc_jwks` (id_token verification), `:matrix_oidc_extra_scopes_reader`,
  #     `:matrix_oidc_refresh_mode_reader`, `:server_name`, `:admin_secret_at_rest` (SecretBox).
  #   * The nonce of the IdP leg is read from the IdP `Location` URL (`nonce` param), the
  #     IdP-leg state from its `state` param; the binding cookie from `set-cookie`.
  #   * Hashes are lowercase hex SHA-256 (`sha256_hex/1`).

  @callback_path "/_matrix/client/v3/login/sso/redirect/oidc"
  @idp_issuer "https://idp.example.com/realms/nebu"
  @idp_audience "nebu-client"
  @idp_kid "oauth-authz-test-key-1"
  @idp_authorize "https://idp.example.com/realms/nebu/auth"
  @idp_token "https://idp.example.com/realms/nebu/token"
  @server_name "test.local"

  @stable "urn:matrix:client:"
  @unstable "urn:matrix:org.matrix.msc2967.client:"

  def callback_path, do: @callback_path
  def idp_issuer, do: @idp_issuer
  def idp_authorize_endpoint, do: @idp_authorize
  def server_name, do: @server_name
  def stable_prefix, do: @stable
  def unstable_prefix, do: @unstable

  @doc "Lowercase hex SHA-256 (the hash format of `state_hash`, `code_hash`, `browser_binding_hash`)."
  def sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc "A fresh RFC 7636 S256 pair `{verifier, challenge}` (challenge = 43 chars base64url)."
  def pkce_pair do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)}
  end

  def rand(n \\ 6), do: Base.encode16(:crypto.strong_rand_bytes(n), case: :lower)

  @doc "Matrix scope string for `prefix` with device `device_id` (api:* first)."
  def matrix_scope(prefix \\ @stable, device_id \\ "AbCdEfGhIj"),
    do: "#{prefix}api:* #{prefix}device:#{device_id}"

  @doc "The EXACT matrix-js-sdk 41.3.0 scope string (openid + unstable prefix)."
  def js_sdk_scope(device_id \\ "AbCdEfGhIj"), do: "openid " <> matrix_scope(@unstable, device_id)

  @doc """
  A fully valid authorization request as an ORDERED list of `{name, value}` pairs. `overrides`
  is a map/keyword: a `nil` value removes the parameter, any other value replaces/adds it.
  """
  def authorize_params(client_id, redirect_uri, overrides \\ %{}) do
    {_verifier, challenge} = pkce_pair()

    base = [
      {"response_type", "code"},
      {"client_id", client_id},
      {"redirect_uri", redirect_uri},
      {"scope", matrix_scope()},
      {"state", "client-state-" <> rand()},
      {"code_challenge", challenge},
      {"code_challenge_method", "S256"}
    ]

    Enum.reduce(overrides, base, fn {k, v}, acc ->
      k = to_string(k)

      cond do
        v == nil -> List.keydelete(acc, k, 0)
        List.keymember?(acc, k, 0) -> List.keyreplace(acc, k, 0, {k, v})
        true -> acc ++ [{k, v}]
      end
    end)
  end

  @doc "Encodes pairs (order + duplicates preserved) into `/oauth2/authorize?...`."
  def authorize_url(pairs) when is_list(pairs) do
    "/oauth2/authorize?" <>
      Enum.map_join(pairs, "&", fn {k, v} -> URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v) end)
  end

  @doc "GET /oauth2/authorize with the pairs (or a raw query string). Options: `:ip`, `:origin`, `:headers`, `:method`."
  def authorize(pairs_or_qs, opts \\ []) do
    path =
      case pairs_or_qs do
        qs when is_binary(qs) -> "/oauth2/authorize?" <> qs
        pairs -> authorize_url(pairs)
      end

    conn(Keyword.get(opts, :method, :get), path)
    |> put_headers(Keyword.get(opts, :headers, []))
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc """
  GET the SHARED IdP callback with the given query pairs. `cookies` is a list of
  `{name, value}` sent in ONE `cookie` request header.
  """
  def callback(pairs, cookies \\ [], opts \\ []) do
    qs = Enum.map_join(pairs, "&", fn {k, v} -> URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v) end)

    conn =
      conn(:get, @callback_path <> if(qs == "", do: "", else: "?" <> qs))
      |> put_headers(Keyword.get(opts, :headers, []))

    conn =
      case cookies do
        [] -> conn
        list -> put_req_header(conn, "cookie", Enum.map_join(list, "; ", fn {k, v} -> "#{k}=#{v}" end))
      end

    conn
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  # Plug.Test refuses put_req_header("host", ...); the IdP-leg callback URL (SsoLogin.callback_url/1)
  # reads the Host REQUEST HEADER, so it is placed into req_headers directly.
  def put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn
      {"host", v}, acc -> %{acc | req_headers: [{"host", v} | List.keydelete(acc.req_headers, "host", 0)]}
      {k, v}, acc -> put_req_header(acc, k, v)
    end)
  end

  def location(conn), do: header(conn, "location")

  @doc """
  Splits a client redirect `Location` into `{base_without_params, mode, params_map, ordered_names}`.
  `mode` is `"fragment"` when the params travel after `#`, else `"query"`.
  """
  def client_redirect(conn_or_location) do
    loc = if is_binary(conn_or_location), do: conn_or_location, else: location(conn_or_location)
    assert is_binary(loc), "expected a Location header"

    case String.split(loc, "#", parts: 2) do
      [base, frag] ->
        {base, "fragment", URI.decode_query(frag), names(frag)}

      [only] ->
        %URI{query: q} = uri = URI.parse(only)
        base = %{uri | query: nil} |> URI.to_string()
        {base, "query", URI.decode_query(q || ""), names(q || "")}
    end
  end

  defp names(""), do: []

  defp names(qs),
    do: qs |> String.split("&", trim: true) |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd() |> URI.decode_www_form()))

  @doc "Query params of the IdP authorize `Location` (asserts it points at the IdP authorize endpoint)."
  def idp_params(conn) do
    loc = location(conn)

    assert is_binary(loc) and String.starts_with?(loc, @idp_authorize <> "?"),
           "expected a 302 to the IdP authorize endpoint, got HTTP #{conn.status} Location=#{inspect(loc)} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    loc |> URI.parse() |> Map.get(:query) |> URI.decode_query()
  end

  @doc "All `set-cookie` values of the response (headers + `resp_cookies`), as raw strings."
  def set_cookies(conn) do
    from_headers = get_resp_header(conn, "set-cookie")

    from_map =
      for {name, %{value: value} = opts} <- conn.resp_cookies || %{} do
        attrs =
          [
            opts[:path] && "path=#{opts[:path]}",
            opts[:max_age] && "max-age=#{opts[:max_age]}",
            opts[:secure] && "secure",
            opts[:http_only] && "HttpOnly",
            opts[:same_site] && "SameSite=#{opts[:same_site]}"
          ]
          |> Enum.reject(&(&1 in [nil, false]))

        Enum.join(["#{name}=#{value}" | attrs], "; ")
      end

    Enum.uniq(from_headers ++ from_map)
  end

  @doc """
  The D4 binding cookie `{name, value, raw_set_cookie}` set by the authorize 302 (flunks if absent).
  Story oauth-hardening-hygiene (HY9): on an https request the name is `__Host-nebu_oa_<16 hex>`
  (`Path=/; Secure`), on plain http `nebu_oa_<16 hex>`; both are found here.
  """
  def binding_cookie(conn) do
    case Enum.find(set_cookies(conn), &(String.starts_with?(&1, "nebu_oa_") or String.starts_with?(&1, "__Host-nebu_oa_"))) do
      nil ->
        flunk("expected a (__Host-)nebu_oa_* binding cookie, got set-cookie=#{inspect(set_cookies(conn))}")

      raw ->
        [pair | _] = String.split(raw, ";")
        [name, value] = String.split(pair, "=", parts: 2)
        {name, value, raw}
    end
  end

  @doc "Expected D4 cookie name for an IdP-leg state (`https? = true`: the `__Host-` name of an https request, HY9)."
  def binding_cookie_name(state, https? \\ false),
    do: if(https?, do: "__Host-nebu_oa_", else: "nebu_oa_") <> String.slice(sha256_hex(state), 0, 16)

  @doc "Expected account-login binding cookie name for a state (`https? = true`: `__Host-nebu_acct_<16 hex>`, HY9)."
  def account_binding_cookie_name(state, https? \\ false),
    do: if(https?, do: "__Host-nebu_acct_", else: "nebu_acct_") <> String.slice(sha256_hex(state), 0, 16)

  # ── fixture clients (approved/pending/rejected rows the way the DB allows them) ──

  @doc """
  Creates an OAuth client row and registers its privileged cleanup (cascade-deletes its
  `oauth_authz_requests` / `oauth_codes` rows). MUST be called from the test process.

  Options: `:status` ("approved"), `:application_type` (derived), `:client_uri`
  ("https://client.example.com"), `:client_name`, `:response_types` (["code"]), `:grant_types`.
  """
  def oauth_client!(redirect_uris, opts \\ []) do
    status = Keyword.get(opts, :status, "approved")
    id = "atdd-oa-" <> rand(8)

    app_type =
      Keyword.get_lazy(opts, :application_type, fn ->
        if Enum.all?(redirect_uris, &String.starts_with?(&1, "https://")), do: "web", else: "native"
      end)

    metadata = %{
      "client_name" => Keyword.get(opts, :client_name, "ATDD OAuth Client " <> id),
      "client_uri" => Keyword.get(opts, :client_uri, "https://client.example.com"),
      "redirect_uris" => redirect_uris,
      "application_type" => app_type,
      "token_endpoint_auth_method" => "none",
      "response_types" => Keyword.get(opts, :response_types, ["code"]),
      "grant_types" => Keyword.get(opts, :grant_types, ["authorization_code", "refresh_token"])
    }

    # story oauth-authorize-freshness: `:metadata` merges extra registered metadata (`tos_uri`, `policy_uri`, ...);
    # a `nil` `:client_name` / `:client_uri` option removes that member (an app that gave none)
    metadata =
      metadata
      |> Map.merge(Map.new(Keyword.get(opts, :metadata, %{})))
      |> Enum.reject(fn {k, v} -> k in ["client_name", "client_uri"] and is_nil(v) end)
      |> Map.new()

    ExUnit.Callbacks.on_exit(fn -> cleanup_clients([id]) end)
    :ok = insert_row!(id, Jason.encode!(metadata), "atdd-hash-" <> id, status, "NOW()", app_type)
    id
  end

  # ── IdP stub (existing SsoLogin seams; no network) ─────────────────────────

  @idp_keys [
    :server_name,
    :oidc_jwks,
    :admin_secret_at_rest,
    :sso_bootstrap_reader,
    :oidc_metadata_override,
    :matrix_sso_token_override,
    :matrix_oidc_refresh_mode_reader,
    :matrix_oidc_extra_scopes_reader
  ]

  @doc """
  Installs the IdP stub seams (issuer/audience, JWKS, discovery, bootstrap credentials, online
  refresh mode, no extra scopes, SecretBox key) and registers their removal. Returns the
  PRIVATE JWK used by `sign_id_token/2`. Options: `:discovery` (map merged into the discovery
  document), `:secret` (SecretBox key, `nil` = none).
  """
  def setup_idp!(opts \\ []) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.merge(%{"kid" => @idp_kid, "alg" => "RS256", "use" => "sig"})

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@idp_issuer, @idp_audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub])
    Application.put_env(:nebu_http, :admin_secret_at_rest, Keyword.get(opts, :secret, "oauth-authz-test-key"))

    # The IdP client secret is a NON-hex value: decrypt_secret/1 then yields "" without touching
    # the at-rest key, so tests that remove the SecretBox key still resolve the IdP client.
    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> @idp_audience
      "oidc_client_secret" -> "not-hex-client-secret"
      _ -> nil
    end)

    Application.put_env(
      :nebu_http,
      :oidc_metadata_override,
      Map.merge(
        %{
          "issuer" => @idp_issuer,
          "authorization_endpoint" => @idp_authorize,
          "token_endpoint" => @idp_token,
          "jwks_uri" => @idp_issuer <> "/jwks"
        },
        Keyword.get(opts, :discovery, %{})
      )
    )

    Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> "online" end)
    Application.put_env(:nebu_http, :matrix_oidc_extra_scopes_reader, fn -> nil end)

    if Process.whereis(Nebu.Matrix.SsoStore) == nil,
      do: ExUnit.Callbacks.start_supervised!(Nebu.Matrix.SsoStore)

    ExUnit.Callbacks.on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()
      for k <- @idp_keys, do: Application.delete_env(:nebu_http, k)
      Application.delete_env(:session_manager, :validator_module)
    end)

    Map.put(priv_map, "kid", @idp_kid)
  end

  def sign_id_token(priv_jwk, claims) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{"iss" => @idp_issuer, "aud" => @idp_audience, "sub" => "alex", "exp" => now + 3600, "iat" => now},
        claims
      )

    {_, compact} =
      JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), %{"alg" => "RS256", "kid" => @idp_kid}, claims)
      |> JOSE.JWS.compact()

    compact
  end

  @doc "Installs the 0-arity IdP token-exchange stub returning `result`."
  def stub_idp_exchange(result),
    do: Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> result end)

  @doc "A unique IdP subject (users created by the flow never collide across runs)."
  def unique_sub, do: "atdd-oa-" <> rand(5)

  @doc "The Matrix user id the server derives for `claims` (same derivation as login)."
  def user_id_for(claims), do: Nebu.Matrix.UserId.from_claims(claims, @server_name)

  @doc """
  Starts a flow: authorize (asserting the 302 to the IdP) and returns
  `%{conn, pairs, idp: idp_params, state, nonce, cookie: {name, value}}`.
  """
  def start_flow(client_id, redirect_uri, overrides \\ %{}, opts \\ []) do
    pairs = authorize_params(client_id, redirect_uri, overrides)
    conn = authorize(pairs, opts)

    assert conn.status == 302,
           "authorize must 302 to the IdP, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 400)}"

    idp = idp_params(conn)
    {name, value, _raw} = binding_cookie(conn)

    %{
      conn: conn,
      pairs: pairs,
      idp: idp,
      state: idp["state"],
      nonce: idp["nonce"],
      cookie: {name, value}
    }
  end

  @doc """
  Completes `flow` at the shared callback: stubs the IdP exchange with a signed id_token carrying
  the IdP-leg nonce (claims overridable; a `nil` claim value REMOVES the claim, e.g.
  `"auth_time" => nil`; by default NO `auth_time` claim is sent = the IdP reports none) and an
  IdP refresh token (default a random value; `idp_rt: nil` = none), then GETs the callback with the flow's binding cookie. Options:
  `:claims`, `:idp_rt`, `:cookies`, `:extra_params`, `:code` ("idp-code-" <> rand), `:ip`.

  Story oauth-authorize-freshness (FR1/FR5): a SUCCESSFUL callback no longer redirects to the
  client. It answers `303 Location: /oauth2/consent` with the consent cookie; the client redirect
  (code) only follows the user's Allow (`consent!/3`, `finish_allow/3`). Error outcomes (IdP error,
  verification failure, deactivated user, gate l, ...) are still RFC 6749 error redirects (302).
  """
  def finish_flow(flow, priv_jwk, opts \\ []) do
    claims =
      %{"sub" => unique_sub(), "nonce" => flow.nonce}
      |> Map.merge(Keyword.get(opts, :claims, %{}))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    # The IdP issues a refresh token by default (gate l, FR13: with `per_refresh` a login without one is
    # refused); pass `idp_rt: nil` (or "") for an IdP that returns none.
    stub_idp_exchange({:ok, sign_id_token(priv_jwk, claims), Keyword.get(opts, :idp_rt, "idp-rt-" <> rand(10))})

    pairs =
      [{"code", Keyword.get(opts, :code, "idp-code-" <> rand())}, {"state", flow.state}] ++
        Keyword.get(opts, :extra_params, [])

    callback(pairs, Keyword.get(opts, :cookies, [flow.cookie]), Keyword.take(opts, [:ip, :headers]))
  end

  def param(pairs, name), do: pairs |> List.keyfind(name, 0) |> elem(1)

  # ════════════════════════════════════════════════════════════════════════════
  # Story oauth-authorize-freshness (P3): the consent step between the IdP callback and the code
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Contracts pinned here (story FR6-FR8, FR12; ATDD role):
  #
  #   * route `/oauth2/consent`: `GET` renders (no mutation), `POST` decides (`csrf_token`,
  #     `decision=allow|deny`, `application/x-www-form-urlencoded`).
  #   * cookie `__Host-nebu_oauth_consent` (`Path=/; Secure`) on an https request, else
  #     `nebu_oauth_consent` (`Path=/oauth2/consent`); value = 256-bit random, base64url, 43 chars;
  #     `HttpOnly; SameSite=Lax; Max-Age=300`.
  #   * table `oauth_consent_requests`, PK `binding_hash` = sha256 hex of the cookie value.
  #   * CSRF token = `base64url_nopad(SHA-256("nebu-oauth-consent-csrf:" <> cookie_value))`; the page
  #     carries it as the hidden input `csrf_token`.
  #   * POST fetch-metadata headers of a real top-level form submit: `Origin` = issuer origin,
  #     `Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`,
  #     `Sec-Fetch-User: ?1`.
  #   * Allow / Deny answer `303 See Other` (never 302/307).

  @consent_path "/oauth2/consent"
  @consent_cookie "nebu_oauth_consent"
  @consent_cookie_https "__Host-nebu_oauth_consent"

  def consent_path, do: @consent_path
  def consent_cookie_name(https? \\ false), do: if(https?, do: @consent_cookie_https, else: @consent_cookie)

  @doc "The CSRF token the consent page must carry for a cookie value (FR8, nothing stored)."
  def consent_csrf(cookie_value),
    do: :crypto.hash(:sha256, "nebu-oauth-consent-csrf:" <> cookie_value) |> Base.url_encode64(padding: false)

  @doc "Raw `set-cookie` strings of the consent cookie (either name) of a response."
  def consent_set_cookies(conn),
    do: Enum.filter(set_cookies(conn), &(String.starts_with?(&1, @consent_cookie <> "=") or String.starts_with?(&1, @consent_cookie_https <> "=")))

  @doc """
  The consent cookie `{name, value, raw}` set by the callback `303` (flunks if absent). A cookie that
  is only being CLEARED (`Max-Age=0`) is not returned.
  """
  def consent_cookie(conn) do
    live = Enum.reject(consent_set_cookies(conn), &(&1 =~ ~r/max-age=0(;|\z)/i))

    case live do
      [raw | _] ->
        [pair | _] = String.split(raw, ";")
        [name, value] = String.split(pair, "=", parts: 2)
        {name, value, raw}

      [] ->
        flunk(
          "expected a consent cookie on the response (HTTP #{conn.status}, Location=#{inspect(location(conn))}), got set-cookie=#{inspect(set_cookies(conn))} body=#{String.slice(conn.resp_body || "", 0, 200)}"
        )
    end
  end

  defp consent_pair(%Plug.Conn{} = conn), do: consent_cookie(conn) |> then(fn {n, v, _} -> {n, v} end)
  defp consent_pair({name, value}), do: {name, value}
  defp consent_pair({name, value, _raw}), do: {name, value}

  @doc "`GET /oauth2/consent` with the cookie (conn of the callback or `{name, value}`); options `:https`, `:headers`, `:ip`, `:method`."
  def consent_get(cookie, opts \\ []) do
    {name, value} = consent_pair(cookie)

    conn(Keyword.get(opts, :method, :get), @consent_path <> Keyword.get(opts, :query, ""))
    |> put_req_header("cookie", "#{name}=#{value}")
    |> put_headers(Keyword.get(opts, :headers, []))
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc """
  `POST /oauth2/consent` as a real top-level form submit would (all fetch-metadata headers set; every
  one can be replaced/removed through `:headers` with `{name, nil}`). `params`: pairs, a map or a RAW
  body. Options: `:cookie` (cookie pair/conn; `nil` = no cookie), `:https`, `:headers`, `:ip`,
  `:content_type`, `:query` (raw query string), `:method`, `:origin` (default the issuer origin).
  """
  def consent_post(params, opts \\ []) do
    body = if is_binary(params), do: params, else: form_encode(params)
    path = @consent_path <> if(q = Keyword.get(opts, :query), do: "?" <> q, else: "")
    c = conn(Keyword.get(opts, :method, :post), path, body)

    c =
      case Keyword.get(opts, :content_type, "application/x-www-form-urlencoded") do
        nil -> c
        ct -> put_req_header(c, "content-type", ct)
      end

    c =
      case Keyword.get(opts, :cookie) do
        nil ->
          c

        cookie ->
          {name, value} = consent_pair(cookie)
          put_req_header(c, "cookie", "#{name}=#{value}")
      end

    defaults = [
      {"origin", Keyword.get(opts, :origin, @issuer)},
      {"sec-fetch-site", "same-origin"},
      {"sec-fetch-mode", "navigate"},
      {"sec-fetch-dest", "document"},
      {"sec-fetch-user", "?1"}
    ]

    overrides = Keyword.get(opts, :headers, [])

    headers =
      Enum.reject(defaults, fn {k, _} -> List.keymember?(overrides, k, 0) end) ++
        Enum.reject(overrides, fn {_k, v} -> is_nil(v) end)

    c
    |> put_headers(headers)
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc """
  The user's decision: GET the consent page (asserting it renders), then POST `decision`
  (`:allow` | `:deny`) with the cookie, the page's CSRF token and the fetch-metadata headers of a
  top-level form submit. `cookie` is the callback conn (its consent cookie is used) or `{name,
  value}`. Returns the POST response. Options: `:https`, `:ip`, `:headers` (POST), `:get` (false =
  skip the GET and derive the token), `:csrf` (override), `:decision_value` (raw `decision`).
  """
  def consent!(cookie, decision, opts \\ []) when decision in [:allow, :deny] do
    {_name, value} = pair = consent_pair(cookie)

    csrf =
      cond do
        Keyword.has_key?(opts, :csrf) ->
          Keyword.fetch!(opts, :csrf)

        Keyword.get(opts, :get, true) ->
          page = consent_get(pair, Keyword.take(opts, [:https]))

          assert page.status == 200,
                 "the consent page must render (200), got #{page.status}: #{String.slice(page.resp_body || "", 0, 300)}"

          assert page.resp_body =~ ~r/<main[^>]*data-page="oauth-consent"/, "page hook data-page=\"oauth-consent\" missing"
          csrf_from(page) || flunk("the consent page carries no csrf_token input")

        true ->
          consent_csrf(value)
      end

    consent_post(
      [{"csrf_token", csrf}, {"decision", Keyword.get(opts, :decision_value, Atom.to_string(decision))}],
      [cookie: pair] ++ Keyword.take(opts, [:https, :ip, :headers, :origin])
    )
  end

  @doc """
  `finish_flow/3` + the user's Allow (what `flow_code!/4` does for a code): asserts the callback
  answered `303 /oauth2/consent`, then `consent!(cb, :allow)`. Returns the Allow response (the `303`
  to the client). Options of `finish_flow/3` plus `:https`.
  """
  def finish_allow(flow, priv_jwk, opts \\ []), do: finish_consent(flow, priv_jwk, :allow, opts)
  def finish_deny(flow, priv_jwk, opts \\ []), do: finish_consent(flow, priv_jwk, :deny, opts)

  defp finish_consent(flow, priv_jwk, decision, opts) do
    cb = finish_flow(flow, priv_jwk, opts)
    assert_consent_redirect(cb)
    consent!(cb, decision, Keyword.take(opts, [:https]))
  end

  @doc "The callback answered `303 Location: /oauth2/consent` with a consent cookie, no code, the flow headers."
  def assert_consent_redirect(conn) do
    assert conn.status == 303,
           "the callback must answer 303 to the consent page, got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    assert location(conn) == @consent_path, "Location must be exactly #{@consent_path}, got #{inspect(location(conn))}"
    assert conn.resp_body in [nil, ""]
    {name, value, raw} = consent_cookie(conn)
    assert name in [@consent_cookie, @consent_cookie_https]
    assert value =~ ~r/\A[A-Za-z0-9_-]{43}\z/, "consent cookie = base64url(32 random bytes)"
    assert raw =~ ~r/HttpOnly/i and raw =~ ~r/SameSite=Lax/i and raw =~ ~r/max-age=300/i
    assert header(conn, "cache-control") =~ "no-store"
    assert header(conn, "access-control-allow-origin") == nil
    conn
  end

  @doc "A consent row of `cookie_value` (map) or nil."
  def consent_row(cookie_value) when is_binary(cookie_value) do
    case sql!("SELECT * FROM oauth_consent_requests WHERE binding_hash = $1", [sha256_hex(cookie_value)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  def consent_row_of(conn_or_pair), do: conn_or_pair |> consent_pair() |> elem(1) |> consent_row()

  @doc """
  Inserts a consent row DIRECTLY (runtime role) for edge cases the real flow cannot produce
  (hostile display values, a redirect URI that fails the CSP source check, an expired row, a held
  device). Returns `%{cookie: {name, value}, value, hash, csrf}`. Attrs (all optional but `user_id`):
  `:user_id`, `:redirect_uri`, `:device_id`, `:response_mode`, `:client_state`, `:client_nonce`,
  `:login_fresh` (true), `:scope_prefix`, `:openid`, `:auth_time_sql`, `:created_sql`,
  `:expires_sql` ("now() + interval '300 seconds'"), `:idp_rt` (plaintext, encrypted here), `:source_key` (the per-source cap key, default NULL).
  """
  def insert_consent!(client_id, attrs) do
    attrs = Map.new(attrs)
    value = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {_verifier, challenge} = pkce_pair()
    device_id = Map.get(attrs, :device_id, "AbCdEfGhIj")
    prefix = Map.get(attrs, :scope_prefix, @stable)
    openid = Map.get(attrs, :openid, false)
    scope = if(openid, do: "openid ", else: "") <> matrix_scope(prefix, device_id)
    idp_rt = Map.get(attrs, :idp_rt, "idp-rt-" <> rand(12))

    sql!(
      "INSERT INTO oauth_consent_requests (binding_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, " <>
        "response_mode, client_state, client_nonce, openid_requested, idp_rt_enc, auth_time, login_fresh, source_key, created_at, expires_at) VALUES " <>
        "($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, #{Map.get(attrs, :auth_time_sql, "NULL")}, $14, $15, " <>
        "#{Map.get(attrs, :created_sql, "now()")}, #{Map.get(attrs, :expires_sql, "now() + interval '300 seconds'")})",
      [
        sha256_hex(value),
        client_id,
        Map.get(attrs, :redirect_uri, "https://app.example.com/cb"),
        challenge,
        device_id,
        Map.fetch!(attrs, :user_id),
        scope,
        prefix,
        Map.get(attrs, :response_mode, "query"),
        Map.get(attrs, :client_state, "client-state-" <> rand()),
        Map.get(attrs, :client_nonce),
        openid,
        if(idp_rt, do: Nebu.Web.SecretBox.encrypt(idp_rt)),
        Map.get(attrs, :login_fresh, true),
        Map.get(attrs, :source_key)
      ]
    )

    %{cookie: {@consent_cookie, value}, value: value, hash: sha256_hex(value), csrf: consent_csrf(value), challenge: challenge, scope: scope}
  end

  @doc """
  Success redirect of an ALLOW (story FR12): `303 See Other` (never 302/307) to `redirect_uri` in
  `mode` with `code`, `state` (or none when `state == nil`) and `iss`, in the order `code state
  iss`; flow headers, no CORS. Returns the params map.
  """
  def assert_allow_redirect(conn, redirect_uri, mode, state, iss \\ @issuer) do
    assert conn.status == 303,
           "expected 303 See Other to the client (Allow), got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    {base, got_mode, params, order} = client_redirect(conn)
    assert base == expected_base(redirect_uri, got_mode), "Allow must redirect to the row's redirect URI, got #{base}"
    assert got_mode == mode, "expected response mode #{mode}, got #{got_mode} (#{location(conn)})"
    assert params["code"] =~ ~r/\A[A-Za-z0-9_-]{43}\z/, "code = base64url(32 random bytes), got #{inspect(params["code"])}"
    assert params["iss"] == iss
    if state, do: assert(params["state"] == state), else: refute(Map.has_key?(params, "state"))
    refute Map.has_key?(params, "error")
    refute Map.has_key?(params, "errcode")
    # the registered query (`tenant=1`) comes first and is not ours
    order = Enum.filter(order, &(&1 in ~w(code state iss)))
    assert order == Enum.filter(~w(code state iss), &(&1 in order)), "parameter order #{inspect(order)}"
    assert header(conn, "cache-control") =~ "no-store"
    assert header(conn, "access-control-allow-origin") == nil
    params
  end

  # `client_redirect/1` splits the registered query of a QUERY-mode redirect into `params`: the expected base is
  # then the registered URI without that query (a fragment-mode base keeps it).
  defp expected_base(redirect_uri, "query"), do: %{URI.parse(redirect_uri) | query: nil} |> URI.to_string()
  defp expected_base(redirect_uri, _fragment), do: redirect_uri

  @doc """
  Error redirect of a DENY (or any 303 error redirect of the consent step): like
  `assert_error_redirect/6` but `303 See Other`.
  """
  def assert_deny_redirect(conn, redirect_uri, mode, state, iss \\ @issuer, error \\ "access_denied") do
    assert conn.status == 303,
           "expected 303 See Other to the client (Deny), got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    {base, got_mode, params, order} = client_redirect(conn)
    assert base == expected_base(redirect_uri, got_mode), "the redirect must go to the row's redirect URI, got #{base}"
    assert got_mode == mode, "expected response mode #{mode}, got #{got_mode} (#{location(conn)})"
    assert params["error"] == error, "expected error=#{error}, got #{inspect(params)}"
    assert params["error_description"] =~ ~r/\A[\x20-\x21\x23-\x5B\x5D-\x7E]+\z/, "fixed ASCII description without \" or \\"
    assert params["iss"] == iss
    if state, do: assert(params["state"] == state), else: refute(Map.has_key?(params, "state"))
    refute Map.has_key?(params, "errcode")
    refute Map.has_key?(params, "code")
    order = Enum.filter(order, &(&1 in ~w(error error_description state iss)))
    assert order == Enum.filter(~w(error error_description state iss), &(&1 in order)), "parameter order #{inspect(order)}"
    assert header(conn, "cache-control") =~ "no-store"
    assert header(conn, "access-control-allow-origin") == nil
    params
  end

  # ── IdP refresh lease / rotating IdP (story FR15, gate n) ──────────────────

  @doc """
  A ROTATING IdP refresh stub with a barrier (installed through `stub_idp_refresh/1`): the FIRST
  call with `x` (the session's IdP refresh token, `s.idp_rt`) blocks until the test sends it
  `:release_idp` (it first sends `{:idp_blocked, pid}` to the test process), then answers `{:ok, claims,
  y}`; every LATER call with `x` answers `{:error, {:token_endpoint_status, 400}}` (a rotated-away
  token); any other token answers `{:ok, claims, nil}`. Options: `:block` (false = never block).
  Returns `%{calls: (-> [rt]), rotated: y, release: (pid -> :ok)}`; `calls.()` lists every IdP call in
  order (the DECRYPTED token sent).
  """
  def rotating_idp_with_barrier(sub, x, opts \\ []) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> %{redeemed: false, calls: []} end)
    y = "idp-rt-rotated-" <> rand(8)
    block? = Keyword.get(opts, :block, true)

    stub_idp_refresh(fn rt ->
      first? =
        Agent.get_and_update(agent, fn %{redeemed: redeemed, calls: calls} = st ->
          first? = rt == x and not redeemed
          {first?, %{st | redeemed: redeemed or rt == x, calls: [rt | calls]}}
        end)

      claims = %{"sub" => sub, "exp" => System.system_time(:second) + 3600}

      cond do
        first? ->
          if block? do
            send(test, {:idp_blocked, self()})

            receive do
              :release_idp -> :ok
            after
              20_000 -> :ok
            end
          end

          {:ok, claims, y}

        rt == x ->
          {:error, {:token_endpoint_status, 400}}

        true ->
          {:ok, claims, nil}
      end
    end)

    %{
      calls: fn -> agent |> Agent.get(& &1.calls) |> Enum.reverse() end,
      rotated: y,
      release: fn pid ->
        send(pid, :release_idp)
        :ok
      end
    }
  end

  @doc """
  Turns an APPROVED client into a REJECTED one the way the database normally forbids (a decision is
  final, the guard trigger of 000040): the trigger is disabled for one privileged transaction. Used for
  "the client is no longer approved when the user clicks Allow" (FR12; P4's `revoked` counts as rejected).
  """
  def reject_approved_client!(client_id) do
    with_privileged_conn(fn conn ->
      {:ok, _} =
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "ALTER TABLE oauth_clients DISABLE TRIGGER oauth_clients_guard_status", [])

          Postgrex.query!(
            tx,
            "UPDATE oauth_clients SET status = 'rejected', approved_by = NULL, approved_at = NULL, " <>
              "rejected_by = '@admin:test.local', rejected_at = now() WHERE client_id = $1",
            [client_id]
          )

          Postgrex.query!(tx, "ALTER TABLE oauth_clients ENABLE TRIGGER oauth_clients_guard_status", [])
        end)
    end)

    :ok
  end

  # ── story oauth-client-revocation (P4): revoked clients, admin strictness ──────────────────────────

  @doc """
  Turns an APPROVED client into a REVOKED one with one plain UPDATE as the RUNTIME role (what migration 000046
  allows: approved -> revoked is the only new transition of the guard trigger). Never goes through the
  cascade (no sessions are ended): use it for "a row that is revoked" fixtures, `Nebu.OAuth.revoke_client/3`
  for the real teardown.
  """
  def mark_revoked!(client_id, by \\ "@admin:test.local", reason \\ nil) do
    %{num_rows: 1} =
      sql!(
        "UPDATE oauth_clients SET status = 'revoked', revoked_by = $2, revoked_at = now(), revoked_reason = $3 " <>
          "WHERE client_id = $1 AND status = 'approved'",
        [client_id, by, reason]
      )

    :ok
  end

  @doc "The four fetch-metadata headers of a user-clicked top-level form submit (SO2 strict level)."
  def strict_fetch_headers,
    do: [{"sec-fetch-site", "same-origin"}, {"sec-fetch-mode", "navigate"}, {"sec-fetch-dest", "document"}, {"sec-fetch-user", "?1"}]

  @doc "Puts the strict fetch-metadata headers on a conn (replacing earlier values)."
  def put_strict_fetch_headers(conn), do: Enum.reduce(strict_fetch_headers(), conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

  # story safari-fetch-metadata-compat: Safari / WebKit sends Sec-Fetch-Site, -Mode and -Dest but NEVER Sec-Fetch-User.
  @safari_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
  @chrome_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
  @firefox_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:142.0) Gecko/20100101 Firefox/142.0"

  @doc "A real Safari `User-Agent` (WebKit, no Chrome / Chromium / Firefox token)."
  def safari_user_agent, do: @safari_user_agent
  def chrome_user_agent, do: @chrome_user_agent
  def firefox_user_agent, do: @firefox_user_agent

  @doc "The hidden form field the click-proof script fills on a trusted click (value `\"1\"`)."
  def click_proof_param, do: "_click_proof"

  @doc "What Safari sends on a user-clicked top-level form submit: the three fetch metadata headers it implements plus its `User-Agent`; NO `Sec-Fetch-User`."
  def safari_fetch_headers,
    do: [{"sec-fetch-site", "same-origin"}, {"sec-fetch-mode", "navigate"}, {"sec-fetch-dest", "document"}, {"user-agent", @safari_user_agent}]

  @doc "Puts the Safari header set on a conn and removes any `Sec-Fetch-User` (the strict set of an earlier helper call included)."
  def put_safari_fetch_headers(conn) do
    conn = %{conn | req_headers: List.keydelete(conn.req_headers, "sec-fetch-user", 0)}
    Enum.reduce(safari_fetch_headers(), conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  @doc "`params` plus the click proof (`_click_proof=1`), as a trusted click would have filled it."
  def with_click_proof(params) when is_map(params), do: Map.put(params, "_click_proof", "1")
  def with_click_proof(params) when is_list(params), do: params ++ [{"_click_proof", "1"}]

  @doc """
  The admin re-authentication marker (SO4) as stored in the signed admin session under `"admin_reauth"`:
  `%{"sub", "at", "kind", "path"}`; `at` = unix seconds (`ago` seconds in the past), `kind` `"auth_time"` | `"flow"`,
  `path` = the ONE confirm page it was started for (Kassandra M-1: `/admin/oauth/registrations/:id/approve` or
  `/admin/oauth/clients/:id/revoke`); without a `path` the marker is the old, unbound shape (refused).
  """
  def fresh_marker(sub, ago \\ 0, kind \\ "auth_time", path \\ nil) do
    base = %{"sub" => sub, "at" => System.os_time(:second) - ago, "kind" => kind}
    if path, do: Map.put(base, "path", path), else: base
  end

  @doc "The lease rows of a device (maps)."
  def lease_rows(user_id, device_id) do
    %{rows: rows, columns: cols} =
      sql!("SELECT * FROM oauth_idp_refresh_leases WHERE user_id = $1 AND device_id = $2", [user_id, device_id])

    Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new() end)
  end

  @doc "Makes the lease of a device EXPIRED (what a crashed holder leaves behind): `lease_until` in the past."
  def expire_lease!(user_id, device_id) do
    # exactly ONE lease must exist: expiring nothing would make a test that "proves" T28 / the stale-lease rule vacuous
    assert %{num_rows: 1} =
             sql!(
               "UPDATE oauth_idp_refresh_leases SET lease_until = now() - interval '1 second' WHERE user_id = $1 AND device_id = $2",
               [user_id, device_id]
             )

    :ok
  end

  @doc "Inserts a lease held by a FOREIGN holder for `seconds` (<= 120): a request for the device must wait / get 503."
  def hold_lease!(user_id, device_id, seconds \\ 60) do
    sql!(
      "INSERT INTO oauth_idp_refresh_leases (user_id, device_id, holder, acquired_at, lease_until) " <>
        "VALUES ($1, $2, $3, now(), now() + ($4::int * interval '1 second')) " <>
        "ON CONFLICT (user_id, device_id) DO UPDATE SET holder = EXCLUDED.holder, acquired_at = EXCLUDED.acquired_at, lease_until = EXCLUDED.lease_until",
      [user_id, device_id, "atdd-foreign-" <> rand(8), seconds]
    )

    :ok
  end

  # ── assertions ─────────────────────────────────────────────────────────────

  @doc """
  AC12/AC13 page assertions: status, `data-page="oauth-error"` + `data-error`, text/html, no
  `Location`, no-store, CSP `default-src 'none'`, no `<script>`, no CORS.
  """
  def assert_page(conn, status, error_code) do
    assert conn.status == status,
           "expected HTTP #{status} page #{error_code}, got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    assert location(conn) == nil, "an error page is never a redirect"
    assert (header(conn, "content-type") || "") =~ ~r{^text/html;\s*charset=utf-8}i
    body = conn.resp_body
    assert body =~ ~r/<main[^>]*data-page="oauth-error"/, "page hook data-page=\"oauth-error\" missing"
    assert body =~ ~s(data-error="#{error_code}"), "expected data-error=\"#{error_code}\" in #{String.slice(body, 0, 400)}"
    refute body =~ ~r/<script/i
    assert header(conn, "cache-control") =~ "no-store"
    assert (header(conn, "content-security-policy") || "") =~ ~r/^default-src 'none'/
    assert header(conn, "access-control-allow-origin") == nil
    conn
  end

  @doc """
  RFC 6749 4.1.2.1 error redirect: 302 to `redirect_uri` in `mode` with `error`, a non-empty
  `error_description`, `state` (or none when `state == nil`) and `iss`; never `errcode`/`error_uri`.
  Returns the params map.
  """
  def assert_error_redirect(conn, redirect_uri, error, mode, state, iss \\ @issuer) do
    assert conn.status == 302,
           "expected an error redirect #{error}, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    {base, got_mode, params, order} = client_redirect(conn)
    assert base == redirect_uri, "error redirect must go to the validated redirect URI, got #{base}"
    assert got_mode == mode, "expected response mode #{mode}, got #{got_mode} (#{location(conn)})"
    assert params["error"] == error, "expected error=#{error}, got #{inspect(params)}"
    assert is_binary(params["error_description"]) and params["error_description"] != ""
    assert params["error_description"] =~ ~r/\A[\x20-\x7E]+\z/, "error_description must be fixed ASCII"
    assert params["iss"] == iss, "RFC 9207: iss=#{iss} expected, got #{inspect(params["iss"])}"

    if state, do: assert(params["state"] == state), else: refute(Map.has_key?(params, "state"))

    refute Map.has_key?(params, "errcode"), "never the Matrix error shape (js-sdk checks errcode)"
    refute Map.has_key?(params, "error_uri")
    refute Map.has_key?(params, "code")
    order = Enum.filter(order, &(&1 in ~w(error error_description state iss)))
    assert order == Enum.filter(~w(error error_description state iss), &(&1 in order)), "parameter order #{inspect(order)}"
    assert header(conn, "cache-control") =~ "no-store"
    assert header(conn, "access-control-allow-origin") == nil
    params
  end

  @doc "Rows of a table for a client (maps). `table` is a trusted literal."
  def rows_for(table, client_id) when table in ["oauth_authz_requests", "oauth_codes", "oauth_consent_requests"] do
    %{rows: rows, columns: cols} = sql!("SELECT * FROM #{table} WHERE client_id = $1", [client_id])
    Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new() end)
  end

  def count_for(table, client_id), do: length(rows_for(table, client_id))

  # ════════════════════════════════════════════════════════════════════════════
  # Story 3 (oauth-token-endpoint): token endpoint / refresh / id_token / JWKS helpers
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Seams the implementation MUST honour (recorded in the story under "ATDD Decisions (story 3)"):
  #
  #   * `:oauth_config_source` map keys `:access_token_ttl_seconds` / `:idp_revalidation`
  #     (`enable_oauth/2`), read by `Nebu.OAuth.Config.token_settings/0`.
  #   * `:nebu_http, :oauth_repo` (NoSuchRepo) also covers `Nebu.OAuth.SigningKeyStore` and the
  #     error-aware client lookup (=> 503 `{}`).
  #   * `:nebu_http, :oauth_session_repo` (NEW, default `Nebu.Repo`): the repo module of
  #     `Nebu.Matrix.Session.OAuthSessionStore` AND of the T19 error-aware `is_active` read. NoSuchRepo
  #     => every OAuth session read/write fails => `:unavailable` => 503 `{}`. Legacy paths
  #     (`MatrixSessionStore`, `OidcPlug`) keep `Nebu.Repo`.
  #   * `:nebu_http, :oauth_user_active_override` (NEW): 1-arity fun `user_id -> {:ok, boolean} |
  #     {:error, term}` replacing the T19 read (code grant AC7.1; refresh in `off` mode).
  #   * `:nebu_http, :oauth_rotate_override` (NEW): 1-arity fun called INSTEAD of the OAuth rotation
  #     (`OAuthSessionStore.rotate/1`) with its params map; `:error` = lost race (re-resolve, bounded,
  #     exhaustion => 503), a raise = crash (=> 503, session intact).
  #   * `:nebu_http, :oauth_token_test_hook` (NEW): 0-arity fun `Nebu.OAuth.Token.handle_token/2`
  #     calls (when set) after the AC2 parsing and before the grant dispatch; a raise there is the
  #     "unexpected exception" of AC10 (=> rescued 500 `{}` + Retry-After).
  #   * `:matrix_oidc_refresh_override` (existing, 1-arity, receives the DECRYPTED IdP RT) for
  #     `per_refresh`; `:session_manager, :validator_module` (existing) for `check_still_active`.

  @token_path "/oauth2/token"
  @form "application/x-www-form-urlencoded"

  def token_path, do: @token_path

  @doc "Form-encodes pairs (list, order + duplicates kept) or a map (RFC 6749 appendix B)."
  def form_encode(pairs) when is_map(pairs), do: pairs |> Enum.to_list() |> form_encode()

  def form_encode(pairs) when is_list(pairs),
    do: Enum.map_join(pairs, "&", fn {k, v} -> URI.encode_www_form(to_string(k)) <> "=" <> URI.encode_www_form(to_string(v)) end)

  @doc """
  `POST /oauth2/token` through the full router. `params`: pairs (list/map) or a RAW body binary.
  Options: `:method` (:post), `:content_type` (form; `nil` = no header), `:query` (raw query
  string), `:headers`, `:ip`, `:origin`.
  """
  def token_request(params, opts \\ []) do
    body = if is_binary(params), do: params, else: form_encode(params)
    path = if q = Keyword.get(opts, :query), do: @token_path <> "?" <> q, else: @token_path

    conn = conn(Keyword.get(opts, :method, :post), path, body)

    conn =
      case Keyword.get(opts, :content_type, @form) do
        nil -> conn
        ct -> put_req_header(conn, "content-type", ct)
      end

    conn
    |> put_headers(Keyword.get(opts, :headers, []))
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "Applies `overrides` (map/keyword; `nil` removes, else replace/append) to ordered pairs."
  def override_pairs(base, overrides) do
    Enum.reduce(overrides, base, fn {k, v}, acc ->
      k = to_string(k)

      cond do
        v == nil -> List.keydelete(acc, k, 0)
        List.keymember?(acc, k, 0) -> List.keyreplace(acc, k, 0, {k, v})
        true -> acc ++ [{k, v}]
      end
    end)
  end

  @doc "The matrix-js-sdk 41.3.0 authorization_code request (form pairs)."
  def code_grant(client_id, code, redirect_uri, verifier, overrides \\ %{}) do
    override_pairs(
      [
        {"grant_type", "authorization_code"},
        {"code", code},
        {"redirect_uri", redirect_uri},
        {"code_verifier", verifier},
        {"client_id", client_id}
      ],
      overrides
    )
  end

  @doc "The matrix-js-sdk refresh request (no scope, no redirect_uri)."
  def refresh_grant(client_id, refresh_token, overrides \\ %{}) do
    override_pairs(
      [{"grant_type", "refresh_token"}, {"refresh_token", refresh_token}, {"client_id", client_id}],
      overrides
    )
  end

  @doc """
  Runs the REAL flow (authorize -> IdP stub -> shared callback -> consent Allow, story
  oauth-authorize-freshness) with a KNOWN PKCE pair and
  returns a grant map: `%{code, verifier, challenge, client_id, redirect_uri, sub, user_id,
  device_id, scope, client_nonce}`. Options: `:authorize` (authorize-param overrides, e.g. scope,
  nonce, response_mode), `:sub`, `:claims`, `:idp_rt` (IdP refresh token; default a random value,
  `nil` = the IdP returned none), `:ip`.
  """
  def flow_code!(client_id, redirect_uri, priv, opts \\ []) do
    {verifier, challenge} = pkce_pair()
    overrides = Map.merge(%{"code_challenge" => challenge}, Map.new(Keyword.get(opts, :authorize, %{}), fn {k, v} -> {to_string(k), v} end))
    flow = start_flow(client_id, redirect_uri, overrides)
    sub = Keyword.get(opts, :sub, unique_sub())
    idp_rt = Keyword.get(opts, :idp_rt, "idp-rt-" <> rand(12))

    # The IdP reports the sign-in time by default (story oauth-authorize-freshness FR4: the stored
    # auth_time is the raw claim or NULL); `claims: %{"auth_time" => nil}` = an IdP that reports none.
    conn =
      finish_allow(flow, priv,
        claims: Map.merge(%{"sub" => sub, "auth_time" => System.system_time(:second)}, Keyword.get(opts, :claims, %{})),
        idp_rt: idp_rt
      )

    assert conn.status == 303,
           "the consent Allow must 303 to the client, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    {_base, _mode, params, _} = client_redirect(conn)
    code = params["code"] || flunk("no code in the client redirect: #{inspect(Map.keys(params))}")
    scope = param(flow.pairs, "scope")

    %{
      code: code,
      verifier: verifier,
      challenge: challenge,
      client_id: client_id,
      redirect_uri: redirect_uri,
      sub: sub,
      user_id: user_id_for(%{"sub" => sub}),
      device_id: scope_device(scope),
      scope: scope,
      client_nonce: overrides["nonce"],
      idp_rt: idp_rt
    }
  end

  @doc "The device id of a Matrix scope string (either prefix)."
  def scope_device(scope) do
    case Regex.run(~r/device:(\S+)/, scope || "") do
      [_, id] -> id
      _ -> nil
    end
  end

  @doc "Redeems a grant map (`flow_code!/4` / `insert_code!/2`) at the token endpoint."
  def redeem(grant, overrides \\ %{}, opts \\ []),
    do: token_request(code_grant(grant.client_id, grant.code, grant.redirect_uri, grant.verifier, overrides), opts)

  @doc "Redeems and asserts 200; returns the decoded JSON body."
  def redeem!(grant, overrides \\ %{}, opts \\ []) do
    conn = redeem(grant, overrides, opts)

    assert conn.status == 200,
           "code grant must succeed, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    json(conn)
  end

  @doc "flow_code!/4 + redeem!/1: a live OAuth session. Adds `:at`, `:rt`, `:body` to the grant map."
  def session!(client_id, redirect_uri, priv, opts \\ []) do
    grant = flow_code!(client_id, redirect_uri, priv, opts)
    body = redeem!(grant)
    Map.merge(grant, %{at: body["access_token"], rt: body["refresh_token"], body: body})
  end

  def refresh(client_id, refresh_token, overrides \\ %{}, opts \\ []),
    do: token_request(refresh_grant(client_id, refresh_token, overrides), opts)

  @doc "Refresh and assert 200; returns the decoded JSON body."
  def refresh!(client_id, refresh_token, overrides \\ %{}, opts \\ []) do
    conn = refresh(client_id, refresh_token, overrides, opts)

    assert conn.status == 200,
           "refresh must succeed, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    json(conn)
  end

  # ── IdP refresh stub (per_refresh re-validation) ───────────────────────────

  @doc """
  Installs `:matrix_oidc_refresh_override` (1-arity, receives the DECRYPTED IdP refresh token) and
  registers its removal. MUST be called from the test process.
  """
  def stub_idp_refresh(fun) when is_function(fun, 1) do
    Application.put_env(:nebu_http, :matrix_oidc_refresh_override, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:nebu_http, :matrix_oidc_refresh_override) end)
    :ok
  end

  @doc "IdP refresh succeeds for `sub` (optionally rotating to `new_rt`); sends `{:idp_refresh, rt}` to the caller."
  def idp_refresh_ok(sub, new_rt \\ nil) do
    pid = self()

    stub_idp_refresh(fn rt ->
      send(pid, {:idp_refresh, rt})
      {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, new_rt}
    end)
  end

  @doc """
  story oauth-client-revocation: the IdP refresh stub for SEVERAL sessions at once: every refresh whose decrypted IdP
  refresh token belongs to one of `sessions` (maps from `session!/4`, with `:idp_rt` and `:sub`) succeeds for its own
  `sub` (no rotation); any other token fails. Needed because `per_refresh` is the default re-validation mode.
  """
  def idp_refresh_for(sessions) when is_list(sessions) do
    by_rt = Map.new(sessions, &{&1.idp_rt, &1.sub})

    stub_idp_refresh(fn rt ->
      case Map.fetch(by_rt, rt) do
        {:ok, sub} -> {:ok, %{"sub" => sub, "exp" => System.system_time(:second) + 3600}, nil}
        :error -> {:error, :unknown_idp_refresh_token}
      end
    end)
  end

  @doc "IdP refresh fails with `reason`; sends `{:idp_refresh, rt}` to the caller."
  def idp_refresh_error(reason) do
    pid = self()

    stub_idp_refresh(fn rt ->
      send(pid, {:idp_refresh, rt})
      {:error, reason}
    end)
  end

  # ── scoped env seams ───────────────────────────────────────────────────────

  @doc "Sets `:nebu_http` env `key` for this test only (prior value restored on exit)."
  def put_env_scoped(key, value, app \\ :nebu_http) do
    prior = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)

    :ok
  end

  @doc "AC10 rescued-500 seam: the token handler raises after parsing (`:oauth_token_test_hook`)."
  def inject_token_handler_fault!,
    do: put_env_scoped(:oauth_token_test_hook, fn -> raise RuntimeError, "atdd injected token-handler fault" end)

  # ── JWKS / id_token ────────────────────────────────────────────────────────

  def jwks(opts \\ []), do: get("/oauth2/jwks", opts)

  @doc "GET /oauth2/jwks, asserts 200, returns the `keys` list."
  def jwks_keys! do
    conn = jwks()
    assert conn.status == 200, "GET /oauth2/jwks must answer 200, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
    keys = json(conn)["keys"]
    assert is_list(keys) and keys != [], "JWKS must be a non-empty `keys` array"
    keys
  end

  @doc "The decoded protected header of a compact JWS (no verification)."
  def jws_header(compact) do
    [h | _] = String.split(compact, ".")
    h |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  @doc """
  Verifies an id_token with `JOSE.JWT.verify_strict(jwk, ["ES256"], token)` against the JWKS key of
  its `kid` (fetched from `GET /oauth2/jwks`). Returns `{header, claims}`. Never inspects a key in a
  failure message (Trap 8): only kids are printed.
  """
  def verify_id_token!(id_token) do
    assert is_binary(id_token) and length(String.split(id_token, ".")) == 3, "id_token must be a compact JWS"
    header = jws_header(id_token)
    keys = jwks_keys!()

    key =
      Enum.find(keys, &(&1["kid"] == header["kid"])) ||
        flunk("id_token kid #{inspect(header["kid"])} is not in the JWKS (kids: #{inspect(Enum.map(keys, & &1["kid"]))})")

    refute Map.has_key?(key, "d"), "the JWKS must never carry the private member d"

    case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["ES256"], id_token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {header, claims}
      _ -> flunk("id_token signature does not verify with the JWKS key #{inspect(header["kid"])}")
    end
  end

  # ── matrix_sessions inspection ─────────────────────────────────────────────

  def token_hash(token), do: Nebu.Matrix.Session.MatrixSessionStore.hash_token(token)

  @doc "All matrix_sessions rows of a device (maps, oldest first)."
  def session_rows(user_id, device_id) do
    %{rows: rows, columns: cols} =
      sql!("SELECT * FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 ORDER BY created_at, access_token_hash", [user_id, device_id])

    Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new() end)
  end

  def active_rows(user_id, device_id), do: user_id |> session_rows(device_id) |> Enum.filter(&is_nil(&1["revoked_at"]))

  @doc "The matrix_sessions row of an access token (map) or nil."
  def row_by_at(at) do
    case sql!("SELECT * FROM matrix_sessions WHERE access_token_hash = $1", [token_hash(at)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  def row_by_rt(rt) do
    case sql!("SELECT * FROM matrix_sessions WHERE refresh_token_hash = $1", [token_hash(rt)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  @doc "Snapshot of a device's rows for 'nothing changed' assertions (hash, revoked, grace, expiry)."
  def rows_snapshot(user_id, device_id),
    do: user_id |> session_rows(device_id) |> Enum.map(&Map.take(&1, ~w(access_token_hash refresh_token_hash revoked_at grace_until expires_at)))

  # ── Matrix requests with a Bearer token ────────────────────────────────────

  def matrix_request(method, path, token, opts \\ []) do
    body = Keyword.get(opts, :body)
    conn = if body, do: conn(method, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json"), else: conn(method, path)

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  def whoami(token), do: matrix_request(:get, "/_matrix/client/v3/account/whoami", token)
  def sync(token), do: matrix_request(:get, "/_matrix/client/v3/sync?timeout=0", token)

  # ── assertions (RFC 6749 5.1 / 5.2, AC1, T20) ──────────────────────────────

  @doc "AC1 headers of EVERY token-endpoint response."
  def assert_token_headers(conn) do
    assert (header(conn, "content-type") || "") =~ ~r{^application/json}i, "token responses are JSON, got #{inspect(header(conn, "content-type"))}"
    assert (header(conn, "cache-control") || "") =~ "no-store", "Cache-Control: no-store (RFC 6749 5.1)"
    assert header(conn, "pragma") == "no-cache", "Pragma: no-cache (RFC 6749 5.1)"
    assert header(conn, "access-control-allow-origin") == "*", "browser clients need ACAO * (T32)"
    assert header(conn, "access-control-allow-credentials") == nil, "never Allow-Credentials with * (C15)"
    conn
  end

  @doc """
  RFC 6749 5.2 error: status, `error` = code, a fixed ASCII `error_description`, nothing else (no
  `errcode`, no `error_uri`), plus the AC1 headers. `too_many_requests` may omit the description.
  """
  def assert_token_error(conn, status, code) do
    assert conn.status == status,
           "expected HTTP #{status} #{code}, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    body = json(conn)
    assert body["error"] == code, "expected error=#{code}, got #{inspect(body)}"
    refute Map.has_key?(body, "errcode"), "OAuth errors never use the Matrix shape (js-sdk checks errcode first)"
    refute Map.has_key?(body, "error_uri")
    assert body |> Map.keys() |> Enum.all?(&(&1 in ["error", "error_description"])), "unexpected members: #{inspect(Map.keys(body))}"

    if code != "too_many_requests" do
      desc = body["error_description"]
      assert is_binary(desc) and desc =~ ~r/\A[\x20-\x7E]+\z/, "error_description must be fixed ASCII text"
    end

    assert_token_headers(conn)
  end

  @doc "T20/C1: a 5xx with `Retry-After` (positive integer seconds) and the body EXACTLY `{}`."
  def assert_5xx_empty(conn, status \\ 503) do
    assert conn.status == status,
           "expected HTTP #{status} {}, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    assert Jason.decode!(conn.resp_body) == %{},
           "every 5xx body is exactly {} (no `error` member: oidc-client-ts would log the client out), got #{conn.resp_body}"

    assert {secs, ""} = Integer.parse(header(conn, "retry-after") || ""), "5xx must carry Retry-After"
    assert secs > 0
    assert (header(conn, "content-type") || "") =~ ~r{^application/json}i
    conn
  end

  @doc "Token-endpoint 5xx: `assert_5xx_empty/2` + the AC1 token headers."
  def assert_token_5xx(conn, status \\ 503), do: conn |> assert_5xx_empty(status) |> assert_token_headers()

  @doc "AC8 success body: exactly the RFC 6749 5.1 members (+ id_token when expected)."
  def assert_token_success(conn, opts \\ []) do
    assert conn.status == 200, "expected 200, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"
    assert_token_headers(conn)
    body = json(conn)
    hex64 = ~r/\A[0-9a-f]{64}\z/
    assert body["access_token"] =~ hex64, "access_token = 64 lowercase hex"
    assert body["refresh_token"] =~ hex64, "refresh_token ALWAYS present (C11), 64 lowercase hex"
    refute body["access_token"] == body["refresh_token"]
    assert body["token_type"] == "Bearer"
    assert is_integer(body["expires_in"]) and body["expires_in"] >= 1
    assert body["expires_in"] <= Keyword.get(opts, :max_expires_in, 900)
    assert is_binary(body["scope"])

    expected = ~w(access_token token_type expires_in refresh_token scope) ++ if(Keyword.get(opts, :id_token, false), do: ["id_token"], else: [])
    assert Enum.sort(Map.keys(body)) == Enum.sort(expected), "AC8: no other members, got #{inspect(Map.keys(body))}"
    body
  end

  # ── fixtures: users, legacy sessions, raw-JWT bindings, direct codes ────────

  @doc "Provisions (via the real TokenValidator) the Matrix user of `sub`; returns its user id."
  def provision_user!(sub \\ unique_sub()) do
    uid = user_id_for(%{"sub" => sub})
    {:ok, _} = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "ATDD " <> sub, sub <> "@example.com")
    uid
  end

  @doc "A legacy opaque session row (MatrixSessionStore.create/1). Returns `%{at, rt}`."
  def legacy_session!(user_id, device_id, opts \\ []) do
    at = Nebu.Matrix.Session.MatrixSessionStore.generate_opaque_token()
    rt = Nebu.Matrix.Session.MatrixSessionStore.generate_opaque_token()

    :ok =
      Nebu.Matrix.Session.MatrixSessionStore.create(%{
        access_token: at,
        refresh_token: rt,
        user_id: user_id,
        device_id: device_id,
        expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 3600, :second)),
        oidc_refresh_token: Keyword.get(opts, :oidc_refresh_token),
        auth_time: Keyword.get(opts, :auth_time, System.system_time(:second))
      })

    %{at: at, rt: rt}
  end

  @doc """
  A raw IdP JWT for `sub` (signed with the `setup_idp!/1` key) bound to `device_id` via
  DeviceBinding.put/4.

  Story 5 (oauth-legacy-coexistence, C13 blast radius, changed deliberately): the `devices` row is
  upserted FIRST (what `POST /login`'s `register_device/4` does), because a JWT bound to a device
  WITHOUT a `devices` row is refused from story 5 on. A unique `jti` keeps two JWTs minted in the
  same second distinct (deterministic RS256 signatures over identical claims).
  """
  def bound_jwt!(priv, sub, device_id) do
    exp = System.system_time(:second) + 3600
    user_id = user_id_for(%{"sub" => sub})
    jwt = sign_id_token(priv, %{"sub" => sub, "exp" => exp, "jti" => "atdd-bjwt-" <> rand()})
    :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(user_id, device_id, last_seen_ts: System.system_time(:millisecond))
    :ok = Nebu.Matrix.Session.DeviceBinding.put(jwt, user_id, device_id, exp)
    jwt
  end

  @doc """
  Inserts an `oauth_codes` row DIRECTLY (runtime role, story-2 schema) for edge cases the real flow
  cannot produce deterministically (expired code, chosen auth_time, no IdP refresh token). Returns
  a grant map like `flow_code!/4`. Attrs: `:user_id` (required, provisioned), `:redirect_uri`,
  `:device_id`, `:prefix`, `:openid`, `:client_nonce`, `:idp_rt` (plaintext, encrypted here; `nil`
  = none), `:auth_time_sql` (`"now()"`), `:created_sql`, `:expires_sql`.
  """
  def insert_code!(client_id, attrs) do
    attrs = Map.new(attrs)
    {verifier, challenge} = pkce_pair()
    code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    device_id = Map.get(attrs, :device_id, "AbCdEfGhIj")
    prefix = Map.get(attrs, :prefix, @stable)
    openid = Map.get(attrs, :openid, false)
    scope = if(openid, do: "openid ", else: "") <> matrix_scope(prefix, device_id)
    redirect_uri = Map.get(attrs, :redirect_uri, "https://app.example.com/cb")
    idp_rt = Map.get(attrs, :idp_rt, "idp-rt-" <> rand(12))
    idp_rt_enc = if idp_rt, do: Nebu.Web.SecretBox.encrypt(idp_rt), else: nil

    sql!(
      "INSERT INTO oauth_codes (code_hash, client_id, redirect_uri, code_challenge, device_id, user_id, scope, scope_prefix, " <>
        "response_mode, client_nonce, openid_requested, idp_rt_enc, auth_time, created_at, expires_at) VALUES " <>
        "($1, $2, $3, $4, $5, $6, $7, $8, 'query', $9, $10, $11, #{Map.get(attrs, :auth_time_sql, "now()")}, " <>
        "#{Map.get(attrs, :created_sql, "now()")}, #{Map.get(attrs, :expires_sql, "now() + interval '60 seconds'")})",
      [sha256_hex(code), client_id, redirect_uri, challenge, device_id, Map.fetch!(attrs, :user_id), scope, prefix,
       Map.get(attrs, :client_nonce), openid, idp_rt_enc]
    )

    %{
      code: code,
      verifier: verifier,
      challenge: challenge,
      client_id: client_id,
      redirect_uri: redirect_uri,
      user_id: Map.fetch!(attrs, :user_id),
      device_id: device_id,
      scope: scope,
      client_nonce: Map.get(attrs, :client_nonce),
      idp_rt: idp_rt
    }
  end

  # ── signing keys (privileged role: the runtime role cannot DELETE, AC14) ────

  @doc "Runs `sql` with `params` as the PRIVILEGED migrate role (bypasses RLS; triggers still fire)."
  def privileged_sql!(sql, params \\ []), do: with_privileged_conn(fn c -> Postgrex.query!(c, sql, params) end)

  @doc "Empties oauth_signing_keys (privileged). Fails (right reason) while the table does not exist."
  def reset_signing_keys!, do: privileged_sql!("DELETE FROM oauth_signing_keys")

  def signing_key_rows do
    %{rows: rows, columns: cols} = sql!("SELECT * FROM oauth_signing_keys ORDER BY created_at")
    Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new() end)
  end

  @doc """
  Makes every DELETE of `matrix_sessions` rows of `user_id` fail (privileged BEFORE DELETE trigger),
  simulating a database error on the revocation. Removed again by `on_exit` (MUST be called from the
  test process). Returns a 0-arity fun that removes the trigger early.
  """
  def block_session_deletes!(user_id, opts \\ []) do
    name = "atdd_block_del_" <> rand(5)
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, user_id)

    # review cycle 1 (story 4): optional `auth_api: "legacy" | "oauth"` limits the blocked rows
    api_check =
      case Keyword.get(opts, :auth_api) do
        nil -> ""
        api when api in ["legacy", "oauth"] -> " AND OLD.auth_api = '#{api}'"
      end

    privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF OLD.user_id = '#{user_id}'#{api_check} THEN " <>
        "RAISE EXCEPTION 'atdd: delete blocked'; END IF; RETURN OLD; END $$ LANGUAGE plpgsql"
    )

    privileged_sql!("CREATE TRIGGER #{name} BEFORE DELETE ON matrix_sessions FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON matrix_sessions")
      privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc """
  Story 4: like `block_session_deletes!/1` for another table (`devices`, `device_keys`, ...): every
  DELETE of a row of `user_id` in `table` fails (privileged BEFORE DELETE trigger). Removed by
  `on_exit`; returns a 0-arity fun that removes it early.
  """
  def block_deletes!(table, user_id) when table in ["devices", "device_keys", "device_one_time_keys", "device_fallback_keys"] do
    name = "atdd_block_del_" <> rand(5)
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, user_id)

    privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF OLD.user_id = '#{user_id}' THEN " <>
        "RAISE EXCEPTION 'atdd: delete blocked'; END IF; RETURN OLD; END $$ LANGUAGE plpgsql"
    )

    privileged_sql!("CREATE TRIGGER #{name} BEFORE DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  # ── rate limits ────────────────────────────────────────────────────────────

  def ip_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  @doc "Takes `burst - leave` tokens of `{family, ip}` (frozen clock via `reset_rate_limits/0`)."
  def drain!(family, ip, rate, burst, leave \\ 0) do
    for _ <- 1..(burst - leave)//1, do: Nebu.Web.Plugs.RateLimit.take({family, ip_string(ip)}, rate, burst)
    :ok
  end

  @doc """
  The rate-limit bucket key of ONE live legacy SSO confirmation (story sso-confirm-bucket-order, cv): the lower-case hex SHA-256 of the binding
  cookie value, family `"sso_confirm"` (refill 2 / min, burst 60). Drain it with `RateLimit.take({"sso_confirm", sso_confirm_binding_bucket(value)}, 2, 60)`.
  """
  def sso_confirm_binding_bucket(cookie_value), do: :crypto.hash(:sha256, cookie_value) |> Base.encode16(case: :lower)

  @doc "Drains the per-binding bucket of `cookie_value` (leaving `leave` tokens)."
  def drain_binding!(cookie_value, leave \\ 0) do
    for _ <- 1..(60 - leave)//1, do: Nebu.Web.Plugs.RateLimit.take({"sso_confirm", sso_confirm_binding_bucket(cookie_value)}, 2, 60)
    :ok
  end

  # ── log assertions ─────────────────────────────────────────────────────────

  @doc "No secret (binary >= 6 bytes) of `secrets` appears in `log` (failure prints the secret's NAME only)."
  def refute_secrets_in_log(log, secrets) when is_map(secrets) do
    for {name, value} <- secrets, is_binary(value), byte_size(value) >= 6 do
      refute String.contains?(log, value), "secret #{name} leaked into the log"
    end

    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story 4 (oauth-token-revocation-logout): revoke / logout / device-state helpers
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Seams the implementation MUST honour (recorded in the story under "ATDD Decisions (story 4)"):
  #
  #   * `:nebu_http, :oauth_session_repo` (story 3) also covers every new `OAuthSessionStore`
  #     function (`end_session_for_token/1`, `end_device/2`, `oauth_device_ids/1`): NoSuchRepo =>
  #     `{:error, :unavailable}` => `503 {}` at `/oauth2/revoke`, `500 M_UNKNOWN` at `/logout`.
  #   * `:nebu_http, :oauth_revoke_test_hook` (NEW, compile-time guarded): 0-arity fun that
  #     `Nebu.OAuth.Revoke.handle_revoke/1` calls FIRST inside its rescue; a raise => `500 {}`.
  #   * Rate-limit key `{"oauth_revoke", ip}` (60/min, burst 600), ip = `:inet.ntoa/1` string.

  @revoke_path "/oauth2/revoke"

  def revoke_path, do: @revoke_path

  @doc """
  `POST /oauth2/revoke` through the full router. `params`: pairs (list/map) or a RAW body binary.
  Options: `:method` (:post), `:content_type` (form; `nil` = no header), `:query` (raw query
  string), `:path` (default `/oauth2/revoke`), `:headers`, `:ip`, `:origin`.
  """
  def revoke(params, opts \\ []) do
    body = if is_binary(params), do: params, else: form_encode(params)
    base = Keyword.get(opts, :path, @revoke_path)
    path = if q = Keyword.get(opts, :query), do: base <> "?" <> q, else: base

    conn = conn(Keyword.get(opts, :method, :post), path, body)

    conn =
      case Keyword.get(opts, :content_type, @form) do
        nil -> conn
        ct -> put_req_header(conn, "content-type", ct)
      end

    conn
    |> put_headers(Keyword.get(opts, :headers, []))
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "Form pairs of a revocation request: `token` plus optional `token_type_hint` / `client_id` (nil = omitted)."
  def revoke_params(token, hint \\ nil, client_id \\ nil) do
    [{"token", token}, {"token_type_hint", hint}, {"client_id", client_id}]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  AC1 headers of EVERY `/oauth2/revoke` response: the token-endpoint headers (JSON, `no-store`,
  `Pragma`, ACAO `*`, never ACAC) plus no `Set-Cookie` and no `WWW-Authenticate`.
  """
  def assert_revoke_headers(conn) do
    assert_token_headers(conn)
    assert get_resp_header(conn, "set-cookie") == [] and (conn.resp_cookies || %{}) == %{}, "revoke never sets a cookie"
    assert header(conn, "www-authenticate") == nil, "revoke never answers WWW-Authenticate (no client authentication, R4)"
    conn
  end

  @doc "R6 / oracle O3: `200`, body EXACTLY `{}`, `application/json`, AC1 headers."
  def assert_revoke_ok(conn) do
    assert conn.status == 200,
           "expected revoke 200 {}, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    assert Jason.decode!(conn.resp_body) == %{}, "the 200 body is exactly {} (oracle O3), got #{inspect(conn.resp_body)}"
    assert_revoke_headers(conn)
  end

  @doc "RFC 6749 5.2 error of `/oauth2/revoke` (shape as the token endpoint) + the AC1 revoke headers."
  def assert_revoke_error(conn, status, code), do: conn |> assert_token_error(status, code) |> assert_revoke_headers()

  @doc "Every 5xx of `/oauth2/revoke`: exactly `{}` + `Retry-After` + the AC1 revoke headers."
  def assert_revoke_5xx(conn, status \\ 503), do: conn |> assert_5xx_empty(status) |> assert_revoke_headers()

  @doc "AC2 rescued-500 seam: the revoke handler raises (`:oauth_revoke_test_hook`, called first inside the rescue)."
  def inject_revoke_handler_fault!,
    do: put_env_scoped(:oauth_revoke_test_hook, fn -> raise RuntimeError, "atdd injected revoke-handler fault" end)

  # ── device / key-table state ───────────────────────────────────────────────

  @device_tables ~w(devices device_keys device_one_time_keys device_fallback_keys)

  @doc "Row counts of the device tables for `(user_id, device_id)`: `%{\"devices\" => n, \"device_keys\" => n, ...}`."
  def device_state(user_id, device_id) do
    Map.new(@device_tables, fn table ->
      %{rows: [[n]]} = sql!("SELECT count(*) FROM #{table} WHERE user_id = $1 AND device_id = $2", [user_id, device_id])
      {table, n}
    end)
  end

  @doc "True when the device and all its key material are gone."
  def device_gone?(user_id, device_id), do: device_state(user_id, device_id) |> Map.values() |> Enum.all?(&(&1 == 0))

  @doc """
  Content fingerprint of the device tables for `(user_id, device_id)` (md5 over the whole rows, ordered): unlike
  `device_state/2` (counts) it notices a changed or replaced key row (bugfix legacy-logout-per-device).
  """
  def device_fingerprint(user_id, device_id) do
    Map.new(@device_tables, fn table ->
      %{rows: [[h]]} =
        sql!(
          "SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t::text), '')) FROM #{table} t WHERE t.user_id = $1 AND t.device_id = $2",
          [user_id, device_id]
        )

      {table, h}
    end)
  end

  @doc """
  Seeds the per-device LEGACY `sessions` + `sync_tokens` rows of `(user_id, device_id)` (what the old user-wide
  `invalidate_user_sessions` wiped for EVERY device; pattern of `oauth_device_teardown_test.exs`).
  """
  def seed_legacy_session_rows!(user_id, device_id) do
    now = System.system_time(:millisecond)
    sql!("INSERT INTO sessions (session_id, user_id, device_id, last_active_at, created_at) VALUES ($1, $2, $3, $4, $4)", ["atdd-" <> rand(6), user_id, device_id, now])
    sql!("INSERT INTO sync_tokens (user_id, since_token, updated_at, device_id) VALUES ($1, 's1', $2, $3)", [user_id, now, device_id])
    :ok
  end

  @doc "The legacy `sessions` / `sync_tokens` rows (identity columns only, no timestamps) of `user_ids`, ordered."
  def legacy_session_state(user_ids) when is_list(user_ids) do
    %{
      sessions: sql!("SELECT user_id, device_id FROM sessions WHERE user_id = ANY($1) ORDER BY 1, 2", [user_ids]).rows,
      sync_tokens: sql!("SELECT user_id, device_id, since_token FROM sync_tokens WHERE user_id = ANY($1) ORDER BY 1, 2", [user_ids]).rows
    }
  end

  @doc "Seeds `device_keys` (+ the `devices` row), one one-time key and one fallback key for the device."
  def seed_device_keys!(user_id, device_id) do
    :ok =
      Nebu.Matrix.DeviceKeyStore.put_device_keys(user_id, device_id, %{
        "user_id" => user_id,
        "device_id" => device_id,
        "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
        "keys" => %{"curve25519:#{device_id}" => "atdd-curve-" <> rand(4), "ed25519:#{device_id}" => "atdd-ed-" <> rand(4)},
        "signatures" => %{}
      })

    :ok = Nebu.Matrix.DeviceKeyStore.store_one_time_keys(user_id, device_id, %{"signed_curve25519:AAAA" <> rand(2) => %{"key" => "otk-" <> rand(4)}})
    :ok = Nebu.Matrix.DeviceKeyStore.store_fallback_keys(user_id, device_id, %{"signed_curve25519:FBK" <> rand(2) => %{"key" => "fbk-" <> rand(4), "fallback" => true}})
    state = device_state(user_id, device_id)
    assert Enum.all?(state, fn {_t, n} -> n >= 1 end), "seed failed: #{inspect(state)}"
    :ok
  end

  @doc "Stores a master cross-signing key for the user (per-user, never deleted by revocation / logout)."
  def seed_cross_signing!(user_id) do
    :ok =
      Nebu.Matrix.CrossSigningKeyStore.put_keys(user_id, %{
        "master_key" => %{"user_id" => user_id, "usage" => ["master"], "keys" => %{"ed25519:atddmaster" => "atdd-master-" <> rand(4)}}
      })
  end

  def cross_signing_count(user_id) do
    %{rows: [[n]]} = sql!("SELECT count(*) FROM cross_signing_keys WHERE user_id = $1 AND master_key_json IS NOT NULL", [user_id])
    n
  end

  @doc """
  'Nothing changed' snapshot of everything a revocation may touch for the given users: every
  `matrix_sessions` row (hashes, state columns, auth_api), the device tables and the JWT bindings.
  """
  def world_snapshot(user_ids) when is_list(user_ids) do
    sessions =
      sql!(
        "SELECT user_id, device_id, auth_api, access_token_hash, refresh_token_hash, revoked_at, grace_until, expires_at, oidc_refresh_token " <>
          "FROM matrix_sessions WHERE user_id = ANY($1) ORDER BY access_token_hash",
        [user_ids]
      ).rows

    tables =
      for t <- @device_tables ++ ["jwt_device_bindings"], into: %{} do
        {t, sql!("SELECT user_id, device_id FROM #{t} WHERE user_id = ANY($1) ORDER BY 1, 2", [user_ids]).rows}
      end

    %{sessions: sessions, tables: tables}
  end

  @doc "Inserts a raw-JWT binding row DIRECTLY (DeviceBinding.put/4 refuses OAuth devices, T25 b). Returns the JWT."
  def insert_jwt_binding!(priv, sub, user_id, device_id) do
    exp = System.system_time(:second) + 3600
    jwt = sign_id_token(priv, %{"sub" => sub, "exp" => exp, "jti" => "atdd-bound-" <> rand()})

    sql!(
      "INSERT INTO jwt_device_bindings (token_hash, user_id, device_id, exp, created_at) VALUES ($1, $2, $3, $4, $5)",
      [Nebu.Matrix.Session.DeviceBinding.hash(jwt), user_id, device_id, exp, System.system_time(:millisecond)]
    )

    jwt
  end

  # ── Matrix logout requests (body variants, AC8 / AC9 / oracle extra tests) ──

  @doc """
  `POST /_matrix/client/v3/logout` (`path: :all` => `/logout/all`) with a Bearer token. `:body`:
  `:none` (no body, no Content-Type, the default), `:empty_json` (empty body WITH
  `Content-Type: application/json`), `:object` (`{}` as JSON), `:invalid` (a NON-empty invalid JSON body).
  """
  def logout(token, opts \\ []) do
    path = if Keyword.get(opts, :path) == :all, do: "/_matrix/client/v3/logout/all", else: "/_matrix/client/v3/logout"

    conn =
      case Keyword.get(opts, :body, :none) do
        :none -> conn(:post, path)
        :empty_json -> conn(:post, path, "") |> put_req_header("content-type", "application/json")
        :object -> conn(:post, path, "{}") |> put_req_header("content-type", "application/json")
        :invalid -> conn(:post, path, "{not json") |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "AC8 / AC9: `200 {}` with `Content-Type: application/json`."
  def assert_logout_ok(conn) do
    assert conn.status == 200, "logout must answer 200 {}, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"
    assert Jason.decode!(conn.resp_body) == %{}
    assert (header(conn, "content-type") || "") =~ ~r{^application/json}i
    conn
  end

  @doc "401 M_UNKNOWN_TOKEN; `soft_logout?: false` asserts the key is ABSENT (R20 consistency choice)."
  def assert_unknown_token(conn, soft_logout?) do
    assert conn.status == 401, "expected 401 M_UNKNOWN_TOKEN, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
    body = json(conn)
    assert body["errcode"] == "M_UNKNOWN_TOKEN", "expected M_UNKNOWN_TOKEN, got #{inspect(body)}"

    if soft_logout?,
      do: assert(body["soft_logout"] == true, "expected soft_logout: true, got #{inspect(body)}"),
      else: refute(Map.has_key?(body, "soft_logout"), "a destroyed session has NO soft_logout key (spec 6 / R20), got #{inspect(body)}")

    body
  end

  @doc "Legacy `POST /_matrix/client/v3/refresh` (JSON body)."
  def legacy_refresh(rt) do
    conn(:post, "/_matrix/client/v3/refresh", Jason.encode!(%{"refresh_token" => rt}))
    |> put_req_header("content-type", "application/json")
    |> with_opts([])
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "Runs `fun` and returns its value, or `{:raised, exception_module}` (Tasks stay unlinked-crash free)."
  def safely(fun) do
    fun.()
  rescue
    e -> {:raised, e.__struct__}
  catch
    :exit, reason -> {:exit, reason}
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story 5 (oauth-legacy-coexistence): GET /login, SSO action, device teardown, JWT kill-switch
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Seams the implementation MUST honour (recorded in the story under "ATDD Decisions (story 5)"):
  #
  #   * `:oauth_config_source` (story 1) decides `Nebu.OAuth.oauth_aware?/0`; a RAISING source fun
  #     is the "exception in the config read" case (=> false, never a 5xx at GET /login).
  #   * `:oidc_metadata_override` (existing) is the IdP discovery document the legacy redirect reads;
  #     `set_idp_prompt_values/1` edits its `prompt_values_supported`.
  #   * NEW `:nebu_http, :device_binding_put_override` (compile-time guarded): 4-arity fun called
  #     INSTEAD of the guarded INSERT of `DeviceBinding.put/4`, its result is put/4's result
  #     (`:ok | {:error, :oauth_device}`); forces the C11 login-race refusal deterministically.
  #   * `:oauth_session_repo` NoSuchRepo (story 3/4) covers the atomic teardown (C12).
  #   * Privileged triggers: `fail_denylist_db!/1` (`invalidated_tokens` INSERT of one hash fails),
  #     `block_device_upserts!/1` (`devices` INSERT/UPDATE of one user fails).

  @legacy_redirect "http://localhost:7070/#/home"

  def legacy_redirect_url, do: @legacy_redirect

  @doc "GET /_matrix/client/v3/login (full router)."
  def login_flows(opts \\ []), do: get("/_matrix/client/v3/login", opts)

  @doc "The `m.login.sso` flow object of a GET /login response (flunks if absent)."
  def sso_flow(conn) do
    json(conn)["flows"] |> Enum.find(&(&1["type"] == "m.login.sso")) || flunk("no m.login.sso flow: #{conn.resp_body}")
  end

  @doc """
  GET the legacy SSO redirect with `pairs` (ordered, duplicates kept; values are encoded) plus
  `redirectUrl` (default the allowlisted legacy URL; `redirect_url: nil` omits it). Options:
  `:idp` (path suffix `/{idpId}`), `:redirect_url`, `:headers`, `:raw_query` (appended verbatim).
  """
  def sso_redirect(pairs, opts \\ []) do
    base = [{"redirectUrl", Keyword.get(opts, :redirect_url, @legacy_redirect)}] |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    qs =
      (base ++ pairs)
      |> Enum.map_join("&", fn {k, v} -> URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v) end)

    qs = if raw = Keyword.get(opts, :raw_query), do: qs <> "&" <> raw, else: qs
    path = "/_matrix/client/v3/login/sso/redirect" <> if(idp = Keyword.get(opts, :idp), do: "/" <> idp, else: "")

    conn(:get, path <> "?" <> qs)
    |> put_headers(Keyword.get(opts, :headers, []))
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "The ORDERED `{name, value}` pairs of a 302 Location query string."
  def location_pairs(conn) do
    loc = location(conn) || flunk("expected a Location header, got HTTP #{conn.status}: #{conn.resp_body}")
    q = URI.parse(loc).query || ""
    q |> String.split("&", trim: true) |> Enum.map(fn kv -> kv |> String.split("=", parts: 2) |> then(fn [k, v] -> {URI.decode_www_form(k), URI.decode_www_form(v)} end) end)
  end

  @doc "Sets (`list`/any value), or removes (`:absent`) `prompt_values_supported` in the IdP discovery override."
  def set_idp_prompt_values(value) do
    doc = Application.get_env(:nebu_http, :oidc_metadata_override) || flunk("setup_idp!/1 must run first")
    doc = if value == :absent, do: Map.delete(doc, "prompt_values_supported"), else: Map.put(doc, "prompt_values_supported", value)
    Application.put_env(:nebu_http, :oidc_metadata_override, doc)
  end

  @doc """
  Legacy `POST /login` (`m.login.token`, NO `refresh_token`) for `sub` through the real SSO
  redirect + callback: the raw-JWT branch. `device_id` nil => server-generated. Returns the conn.
  """
  def legacy_login(priv, sub, device_id \\ nil, opts \\ []) do
    init = get("/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(@legacy_redirect))
    idp = idp_params(init)
    stub_idp_exchange({:ok, sign_id_token(priv, %{"sub" => sub, "nonce" => idp["nonce"]}), Keyword.get(opts, :idp_rt)})
    cb = callback([{"code", "c-" <> rand()}, {"state", idp["state"]}])
    token = cb |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.fetch!("loginToken")

    body =
      %{"type" => "m.login.token", "token" => token}
      |> then(fn b -> if device_id, do: Map.put(b, "device_id", device_id), else: b end)
      |> then(fn b -> if Keyword.get(opts, :refresh_token), do: Map.put(b, "refresh_token", true), else: b end)

    conn(:post, "/_matrix/client/v3/login", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> with_opts([])
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "An UNBOUND raw IdP JWT for `sub` (never redeemed through POST /login)."
  def unbound_jwt!(priv, sub),
    do: sign_id_token(priv, %{"sub" => sub, "exp" => System.system_time(:second) + 3600, "jti" => "atdd-ujwt-" <> rand()})

  @doc "The denylist DB write (`invalidated_tokens` INSERT) of `token_hash` fails (privileged trigger, removed on exit)."
  def fail_denylist_db!(token_hash) do
    true = Regex.match?(~r/\A[0-9a-f]{64}\z/, token_hash)
    name = "atdd_fail_deny_" <> rand(5)

    privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.token_hash = '#{token_hash}' THEN " <>
        "RAISE EXCEPTION 'atdd: denylist write blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON invalidated_tokens FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON invalidated_tokens")
      privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc """
  Bugfix legacy-logout-per-device: like `fail_denylist_db!/1` for ANY denylist DB key (`token_hash` column): the
  plain SHA-256 hex of a token or the `"jti:" <> jti` key of a JWT that carries a `jti` (the key
  `TokenDenylist.revoke_checked/3` writes first). Removed on exit; returns a 0-arity fun that removes it early.
  """
  def fail_denylist_key!(key) do
    true = Regex.match?(~r/\A(?:[0-9a-f]{64}|jti:[A-Za-z0-9._\-]{1,100})\z/, key)
    name = "atdd_fail_deny_" <> rand(5)

    privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.token_hash = '#{key}' THEN " <>
        "RAISE EXCEPTION 'atdd: denylist write blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON invalidated_tokens FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON invalidated_tokens")
      privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc """
  Bugfix legacy-logout-per-device (L2): every SELECT of `table` fails for the runtime role (privileged REVOKE, the
  grant is restored by `on_exit`): a database ERROR on the read path. Returns a 0-arity fun that restores it early.
  """
  def revoke_select!(table) when table in ["jwt_device_bindings"] do
    privileged_sql!("REVOKE SELECT ON #{table} FROM nebu_app")
    restore = fn -> privileged_sql!("GRANT SELECT ON #{table} TO nebu_app") end
    ExUnit.Callbacks.on_exit(restore)
    restore
  end

  @doc "The `jti` claim of a compact JWT (nil when absent)."
  def jwt_jti(jwt) do
    [_, payload, _] = String.split(jwt, ".")
    (payload |> Base.url_decode64!(padding: false) |> Jason.decode!())["jti"]
  end

  @doc "Rows of the DATABASE denylist (`invalidated_tokens`) for `key` (`\"jti:<jti>\"` or a SHA-256 hex): 0 or 1."
  def denylist_db_count(key) do
    %{rows: [[n]]} = sql!("SELECT count(*) FROM invalidated_tokens WHERE token_hash = $1", [key])
    n
  end

  @doc "Every INSERT/UPDATE of a `devices` row of `user_id` fails (privileged trigger, removed on exit)."
  def block_device_upserts!(user_id) do
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, user_id)
    name = "atdd_block_dev_" <> rand(5)

    privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.user_id = '#{user_id}' THEN " <>
        "RAISE EXCEPTION 'atdd: device upsert blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT OR UPDATE ON devices FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON devices")
      privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc "Every INSERT into `jwt_device_bindings` for `user_id` fails (privileged trigger, removed on exit): a DB error in put/4."
  def block_binding_inserts!(user_id) do
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, user_id)
    name = "atdd_block_bind_" <> rand(5)

    privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.user_id = '#{user_id}' THEN " <>
        "RAISE EXCEPTION 'atdd: binding insert blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON jwt_device_bindings FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON jwt_device_bindings")
      privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc "True when a binding row for exactly this token exists."
  def binding_exists?(jwt) do
    %{rows: [[n]]} = sql!("SELECT count(*) FROM jwt_device_bindings WHERE token_hash = $1", [Nebu.Matrix.Session.DeviceBinding.hash(jwt)])
    n == 1
  end

  @doc """
  Simulates ANOTHER cluster node for `jwt`: removes the node-local ETS denylist entries (hash and
  jti) and the DeviceBinding lookup-cache entry, so only the database decides (C13).
  """
  def forget_node_local_jwt_state!(jwt) do
    h = Nebu.Matrix.Session.DeviceBinding.hash(jwt)

    jti =
      case String.split(jwt, ".") do
        [_, payload, _] -> (payload |> Base.url_decode64!(padding: false) |> Jason.decode!())["jti"]
        _ -> nil
      end

    for {table, key} <- [{:nebu_http_token_denylist, {:hash, h}}, {:nebu_http_token_denylist, {:jti, jti}}, {:nebu_jwt_device_binding_cache, h}],
        :ets.whereis(table) != :undefined,
        do: :ets.delete(table, key)

    :ok
  end

  def binding_rows(user_id, device_id) do
    %{rows: [[n]]} = sql!("SELECT count(*) FROM jwt_device_bindings WHERE user_id = $1 AND device_id = $2", [user_id, device_id])
    n
  end

  @doc "A UIA session for `user_id` (`op` \"delete_devices\"); `complete: true` marks the SSO stage done."
  def uia_session!(user_id, params \\ "{}", opts \\ []) do
    sid = Nebu.Matrix.Uia.mint_session(user_id, "delete_devices", params)
    if Keyword.get(opts, :complete), do: {:ok, _} = Nebu.Matrix.Uia.complete(sid, user_id)
    sid
  end

  def uia_rows(user_id) do
    sql!("SELECT session_id, stage_complete, consumed FROM uia_sessions WHERE user_id = $1 ORDER BY session_id", [user_id]).rows
  end

  @doc "A Bearer request with a RAW body (`nil` = no body) and an optional content type."
  def raw_request(method, path, token, body, content_type \\ nil) do
    c = if body, do: conn(method, path, body), else: conn(method, path)
    c = if content_type, do: put_req_header(c, "content-type", content_type), else: c

    c
    |> put_req_header("authorization", "Bearer " <> token)
    |> with_opts([])
    |> Nebu.Web.Router.call(@router_opts)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story 6 (oauth-account-management): /account page, account sessions, m.oauth reset
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Seams / pinned schema the implementation MUST honour (story "ATDD Decisions (story 6)"):
  #
  #   * `:oauth_config_source` (story 1) decides liveness (A3); `:oauth_repo` NoSuchRepo is the
  #     repo of `Nebu.OAuth.AccountStore` (=> `unavailable` page).
  #   * NEW `:nebu_http, :account_matrix_repo` (compile-time guarded): repo of the Matrix account
  #     facade reads/updates (`account_identity/1`, `account_devices/1`, `account_profile/1`,
  #     `cross_signing_reset_requests/1`, approve/decline); NoSuchRepo => `{:error, :unavailable}`.
  #   * `oauth_account_sessions`: `session_hash` = sha256 hex of the cookie value, `csrf_hash` = sha256
  #     hex of the CSRF token, `user_id`, `auth_time` (unix s), `created_at`, `last_seen_at`,
  #     `idle_expires_at`, `expires_at` (timestamptz). Cookie `nebu_account` (http request) /
  #     `__Host-nebu_account` (https request); binding cookie `nebu_acct_<16 hex of state_hash>` (https request: `__Host-nebu_acct_<16 hex>`, HY9);
  #     hidden form field `csrf_token`; state `o2.acct.` + 43 base64url.
  #   * Key-write / mint failures are privileged triggers (`block_cross_signing_writes!/1`,
  #     `block_uia_inserts!/1`), no production seam.

  @account_cookie "nebu_account"
  @account_cookie_https "__Host-nebu_account"

  def account_cookie_name, do: @account_cookie

  @doc """
  GET an `/account*` path. Options: `:cookie` (the account cookie value), `:cookies` (extra
  `{name, value}`), `:headers`, `:ip`, `:https` (true => `conn.scheme = :https`), `:method`.
  """
  def account_get(path, opts \\ []) do
    conn(Keyword.get(opts, :method, :get), path)
    |> account_cookies(opts)
    |> put_headers(Keyword.get(opts, :headers, []))
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "Form POST to an `/account*` path: `params` pairs (CSRF included by the caller) or a raw body. Same options as `account_get/2` plus `:content_type`."
  def account_post(path, params, opts \\ []) do
    body = if is_binary(params), do: params, else: form_encode(params)

    c = conn(:post, path, body)

    c =
      case Keyword.get(opts, :content_type, @form) do
        nil -> c
        ct -> put_req_header(c, "content-type", ct)
      end

    c
    |> account_cookies(opts)
    |> put_headers(Keyword.get(opts, :headers, []))
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  defp account_cookies(conn, opts) do
    name = if Keyword.get(opts, :https), do: @account_cookie_https, else: @account_cookie
    base = if c = Keyword.get(opts, :cookie), do: [{name, c}], else: []
    all = base ++ Keyword.get(opts, :cookies, [])

    case all do
      [] -> conn
      list -> put_req_header(conn, "cookie", Enum.map_join(list, "; ", fn {k, v} -> "#{k}=#{v}" end))
    end
  end

  defp account_scheme(conn, opts), do: if(Keyword.get(opts, :https), do: %{conn | scheme: :https, port: 443}, else: conn)

  @doc """
  A live account session inserted DIRECTLY (runtime role). `opts`: `:auth_time` (unix s, default
  now), `:created_sql` / `:idle_sql` / `:expires_sql` (SQL expressions). Returns `%{cookie, csrf, hash}`.
  """
  def account_session!(user_id, opts \\ []) do
    cookie = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    csrf = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    auth_time = Keyword.get(opts, :auth_time, System.system_time(:second))

    sql!(
      "INSERT INTO oauth_account_sessions (session_hash, user_id, auth_time, csrf_hash, created_at, last_seen_at, idle_expires_at, expires_at) " <>
        "VALUES ($1, $2, $3, $4, #{Keyword.get(opts, :created_sql, "now()")}, now(), " <>
        "#{Keyword.get(opts, :idle_sql, "now() + interval '900 seconds'")}, #{Keyword.get(opts, :expires_sql, "now() + interval '3600 seconds'")})",
      [sha256_hex(cookie), user_id, auth_time, sha256_hex(csrf)]
    )

    %{cookie: cookie, csrf: csrf, hash: sha256_hex(cookie)}
  end

  def account_session_row(cookie) do
    case sql!("SELECT * FROM oauth_account_sessions WHERE session_hash = $1", [sha256_hex(cookie)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  def account_session_count(user_id) do
    %{rows: [[n]]} = sql!("SELECT count(*) FROM oauth_account_sessions WHERE user_id = $1", [user_id])
    n
  end

  @doc "Starts the account sign-in (`GET path`, no session) and returns `%{conn, idp, state, nonce, binding: {name, value}}`."
  def account_start!(path \\ "/account", opts \\ []) do
    conn = account_get(path, opts)
    assert conn.status == 302, "GET #{path} without a session must 302 to the IdP, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"
    idp = idp_params(conn)

    {name, value} =
      case Enum.find(set_cookies(conn), &(String.starts_with?(&1, "nebu_acct_") or String.starts_with?(&1, "__Host-nebu_acct_"))) do
        nil -> flunk("expected a (__Host-)nebu_acct_* binding cookie, got #{inspect(set_cookies(conn))}")
        raw -> raw |> String.split(";") |> hd() |> String.split("=", parts: 2) |> List.to_tuple()
      end

    %{conn: conn, idp: idp, state: idp["state"], nonce: idp["nonce"], binding: {name, value}}
  end

  @doc """
  Completes an account sign-in at the SHARED callback: stubs the IdP exchange (claims merged; pass
  `"auth_time" => nil` to omit it, default now) and calls the callback with the binding cookie.
  Options: `:claims`, `:cookies` (replaces the binding cookie list), `:extra_cookies`, `:https`.
  Returns the callback conn.
  """
  def account_finish(flow, priv, sub, opts \\ []) do
    claims =
      %{"sub" => sub, "nonce" => flow.nonce, "auth_time" => System.system_time(:second)}
      |> Map.merge(Keyword.get(opts, :claims, %{}))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    stub_idp_exchange({:ok, sign_id_token(priv, claims), "idp-rt-acct-" <> rand(6)})
    cookies = Keyword.get(opts, :cookies, [flow.binding]) ++ Keyword.get(opts, :extra_cookies, [])
    c = conn(:get, @callback_path <> "?" <> URI.encode_query(%{"code" => "acct-code-" <> rand(), "state" => flow.state}))

    c =
      case cookies do
        [] -> c
        list -> put_req_header(c, "cookie", Enum.map_join(list, "; ", fn {k, v} -> "#{k}=#{v}" end))
      end

    c
    |> put_headers(Keyword.get(opts, :headers, []))
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "The account session cookie value set by a response (nil when none)."
  def account_cookie_from(conn, name \\ @account_cookie) do
    case Enum.find(set_cookies(conn), &String.starts_with?(&1, name <> "=")) do
      nil -> nil
      raw -> raw |> String.split(";") |> hd() |> String.split("=", parts: 2) |> List.last()
    end
  end

  def raw_set_cookie(conn, name), do: Enum.find(set_cookies(conn), &String.starts_with?(&1, name <> "="))

  @doc "Full sign-in through the real flow; returns `%{cookie, csrf, conn}` (csrf read from the landing page)."
  def account_login!(priv, sub, opts \\ []) do
    flow = account_start!(Keyword.get(opts, :path, "/account?action=org.matrix.devices_list"))
    cb = account_finish(flow, priv, sub, opts)
    assert cb.status == 303, "account callback must 303, got #{cb.status}: #{String.slice(cb.resp_body || "", 0, 300)}"
    cookie = account_cookie_from(cb) || flunk("no account session cookie set: #{inspect(set_cookies(cb))}")
    page = account_get(location(cb), cookie: cookie)
    %{cookie: cookie, csrf: csrf_from(page), conn: page, callback: cb}
  end

  @doc "The hidden `csrf_token` value of a page (nil when absent)."
  def csrf_from(conn) do
    case Regex.run(~r/name="csrf_token"\s+value="([^"]+)"|value="([^"]+)"\s+name="csrf_token"/, conn.resp_body || "") do
      [_, a] -> a
      [_, "", b] -> b
      [_, a, _] -> a
      _ -> nil
    end
  end

  @doc "A20 page hook: `<main data-page=\"account\" data-action=action>`, status, html, the A20 headers."
  def assert_account_page(conn, action, status \\ 200) do
    assert conn.status == status, "expected account page #{action} (#{status}), got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"
    assert conn.resp_body =~ ~r/<main[^>]*data-page="account"/, "page hook data-page=\"account\" missing"
    assert conn.resp_body =~ ~s(data-action="#{action}"), "expected data-action=\"#{action}\""
    assert_account_headers(conn)
  end

  @doc "A20 error page `<main data-page=\"account-error\" data-error=code>` with `status`."
  def assert_account_error(conn, status, code) do
    assert conn.status == status, "expected account error #{code} (#{status}), got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"
    assert conn.resp_body =~ ~r/<main[^>]*data-page="account-error"/
    assert conn.resp_body =~ ~s(data-error="#{code}"), "expected data-error=\"#{code}\" in #{String.slice(conn.resp_body, 0, 300)}"
    assert_account_headers(conn)
  end

  @doc "AC1 headers of EVERY /account response."
  def assert_account_headers(conn) do
    if conn.status in [200, 400, 403, 404, 405, 429, 500, 503] do
      assert (header(conn, "content-type") || "") =~ ~r{^text/html;\s*charset=utf-8}i
      csp = header(conn, "content-security-policy") || ""
      assert csp =~ ~r/^default-src 'none'/
      for part <- ["style-src 'sha256-", "img-src 'none'", "form-action 'self'", "base-uri 'none'", "frame-ancestors 'none'"],
          do: assert(csp =~ part, "CSP lacks #{part}: #{csp}")
    end

    assert (header(conn, "cache-control") || "") =~ "no-store"
    assert header(conn, "pragma") == "no-cache"
    assert header(conn, "referrer-policy") == "same-origin"
    assert header(conn, "x-frame-options") == "DENY"
    refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end), "no CORS header on /account (A4)"
    conn
  end

  def notice_of(conn) do
    loc = location(conn) || ""
    URI.decode_query(URI.parse(loc).query || "")["notice"]
  end

  @doc "An OAuth device session for a user of `sub` on `device_id` (story-3 flow)."
  def oauth_device!(cid, redirect_uri, priv, sub, device_id),
    do: session!(cid, redirect_uri, priv, sub: sub, authorize: %{"scope" => matrix_scope(@stable, device_id)})

  @doc "Deterministic cross-signing key objects (master / ssk / usk) for `user_id`, tagged by `tag`."
  def cross_signing_keys(user_id, tag) do
    k = fn usage, name -> %{"user_id" => user_id, "usage" => [usage], "keys" => %{"ed25519:#{name}#{tag}" => "#{name}#{tag}"}} end
    %{"master_key" => k.("master", "MSK"), "self_signing_key" => k.("self_signing", "SSK"), "user_signing_key" => k.("user_signing", "USK")}
  end

  def device_signing_upload(token, body), do: matrix_request(:post, "/_matrix/client/v3/keys/device_signing/upload", token, body: body)

  def stored_master(user_id), do: Nebu.Matrix.CrossSigningKeyStore.get_keys(user_id)["master_key"]

  def master_hash(master), do: :crypto.hash(:sha256, Nebu.Matrix.CanonicalJson.encode!(master)) |> Base.encode16(case: :lower)

  @doc """
  Test review M7 (design decision): the UIA / approval session is bound to the SHA-256 hex of the
  canonical JSON (`Nebu.Matrix.CanonicalJson`) of ALL supplied keys: the map of the present
  `master_key` / `self_signing_key` / `user_signing_key` of the request body.
  """
  def keys_hash(body),
    do: :crypto.hash(:sha256, Nebu.Matrix.CanonicalJson.encode!(Map.take(body, ["master_key", "self_signing_key", "user_signing_key"]))) |> Base.encode16(case: :lower)

  def uia_row(session_id) do
    case sql!("SELECT * FROM uia_sessions WHERE session_id = $1", [session_id]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      _ -> nil
    end
  end

  def uia_count(user_id, op) do
    %{rows: [[n]]} = sql!("SELECT count(*) FROM uia_sessions WHERE user_id = $1 AND op = $2", [user_id, op])
    n
  end

  @doc "Every INSERT/UPDATE of `cross_signing_keys` of `user_id` fails (privileged trigger; key-write failure)."
  def block_cross_signing_writes!(user_id), do: block_table_writes!("cross_signing_keys", user_id, "INSERT OR UPDATE")

  @doc "Every INSERT into `uia_sessions` for `user_id` fails (privileged trigger; mint failure)."
  def block_uia_inserts!(user_id), do: block_table_writes!("uia_sessions", user_id, "INSERT")

  @doc "Every INSERT/UPDATE of `oauth_idp_refresh_leases` for `user_id` fails (privileged trigger; lease SQL error, story oauth-authorize-freshness FR15)."
  def block_lease_writes!(user_id), do: block_table_writes!("oauth_idp_refresh_leases", user_id, "INSERT OR UPDATE")

  defp block_table_writes!(table, user_id, events) when table in ["cross_signing_keys", "uia_sessions", "oauth_idp_refresh_leases"] do
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, user_id)
    name = "atdd_block_w_" <> rand(5)

    privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.user_id = '#{user_id}' THEN " <>
        "RAISE EXCEPTION 'atdd: write blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    privileged_sql!("CREATE TRIGGER #{name} BEFORE #{events} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story 9 (oauth-versions-switch): /versions, parity snapshot, contract crawler helpers
  # ════════════════════════════════════════════════════════════════════════════

  @versions_off ~w(v1.1 v1.2 v1.3 v1.4 v1.5 v1.6 v1.7 v1.8 v1.9 v1.10 v1.11)
  @versions_on @versions_off ++ ~w(v1.12 v1.13 v1.14 v1.15)
  @unstable %{"uk.half-shot.msc2666.query_mutual_rooms" => true}

  def versions_off, do: @versions_off
  def versions_on, do: @versions_on

  @doc "The pre-story-9 `/versions` body, byte for byte (V1, Trap 8)."
  def versions_off_bytes, do: Jason.encode!(%{"versions" => @versions_off, "unstable_features" => @unstable})

  def versions_on_map, do: %{"versions" => @versions_on, "unstable_features" => @unstable}
  def versions_off_map, do: %{"versions" => @versions_off, "unstable_features" => @unstable}

  @doc "GET `/_matrix/client/versions` (full router). Options: `:bearer` (token), `:authorization` (raw header), `:path`, `:ip`, `:method`, `:headers`."
  def versions(opts \\ []) do
    path = Keyword.get(opts, :path, "/_matrix/client/versions")
    c = conn(Keyword.get(opts, :method, :get), path)

    c =
      cond do
        b = Keyword.get(opts, :bearer) -> put_req_header(c, "authorization", "Bearer " <> b)
        a = Keyword.get(opts, :authorization) -> put_req_header(c, "authorization", a)
        true -> c
      end

    c
    |> put_headers(Keyword.get(opts, :headers, []))
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc "Installs a config-source seam that counts its calls (message `:config_read` to the caller) and returns `value`."
  def counting_config_source(value) do
    pid = self()

    Application.put_env(:nebu_http, :oauth_config_source, fn ->
      send(pid, :config_read)
      value
    end)
  end

  def drain_config_reads(acc \\ 0) do
    receive do
      :config_read -> drain_config_reads(acc + 1)
    after
      0 -> acc
    end
  end

  @doc """
  AC3 parity snapshot: one map over every surface, reduced to what the parity table compares.
  Requests run without DB-dependent payloads (no session, empty forms).
  """
  def parity_snapshot do
    v = versions()
    meta = get_metadata()
    unstable = get("/_matrix/client/unstable/org.matrix.msc2965/auth_metadata")
    issuer = get("/_matrix/client/v1/auth_issuer")
    login = login_flows()
    sso = (Jason.decode(login.resp_body || "") |> elem(1) |> then(&if(is_map(&1), do: &1["flows"], else: [])) || []) |> Enum.find(%{}, &(&1["type"] == "m.login.sso"))
    oidc = get("/.well-known/openid-configuration")
    jwks = get("/oauth2/jwks")
    token = token_request([])
    register = register(%{})
    authorize = get("/oauth2/authorize")
    account = account_get("/account")
    revoke = revoke([{"token", "junk"}])

    %{
      v115: "v1.15" in ((Jason.decode(v.resp_body || "") |> elem(1) |> then(&if(is_map(&1), do: &1["versions"], else: []))) || []),
      versions_status: v.status,
      sso_action_prompt: sso_action_prompt(),
      metadata: meta.status,
      metadata_body: meta.resp_body,
      unstable: unstable.status,
      unstable_body: unstable.resp_body,
      auth_issuer: issuer.status,
      flags: Map.has_key?(sso, "oauth_aware_preferred") and Map.has_key?(sso, "org.matrix.msc3824.delegated_oidc_compatibility"),
      openid: oidc.status,
      jwks: jwks.status,
      token: token.status,
      token_body: token.resp_body,
      register: register.status,
      authorize: authorize.status,
      account: account.status,
      account_unavailable: (account.resp_body || "") =~ ~s(data-error="unavailable"),
      revoke: revoke.status,
      # the raw conns, for the per-state detail assertions of Must #12-#15
      conns: %{versions: v, metadata: meta, unstable: unstable, auth_issuer: issuer,
               unstable_auth_issuer: get("/_matrix/client/unstable/org.matrix.msc2965/auth_issuer"),
               openid: oidc, jwks: jwks, token: token, register: register, authorize: authorize, account: account, revoke: revoke}
    }
  end

  # SSO `action=register` parity (story 5 C5): the IdP prompt of the legacy redirect ("create" only
  # while OAuth is offered; needs setup_idp!/1 + set_idp_prompt_values(["login", "create"])).
  defp sso_action_prompt do
    c = sso_redirect([{"action", "register"}])
    if c.status == 302, do: URI.decode_query(URI.parse(location(c)).query || "")["prompt"], else: {:status, c.status}
  end

  @doc "V10 (a): every string value of the document that starts with the issuer => `[{field, url}]` (+ the issuer's openid-configuration)."
  def advertised_urls(doc) do
    issuer = doc["issuer"]

    fields =
      for {k, v} <- doc, is_binary(v), k != "issuer", String.starts_with?(v, issuer), do: {k, v}

    fields ++ [{"openid-configuration", URI.merge(issuer <> "/", ".well-known/openid-configuration") |> to_string()}]
  end

  @doc "Strips scheme + host of an advertised URL: the router path (+ query)."
  def router_path(url) do
    u = URI.parse(url)
    (u.path || "/") <> if(u.query, do: "?" <> u.query, else: "")
  end

  @doc """
  True for the 'not implemented' answers the contract forbids: the top router's plain `404 "not found"`,
  a `M_NOT_FOUND` body (the former Protected / Media / HttpPublic fall-through answer) or `M_UNRECOGNIZED`
  (since story oauth-room-summary-unrecognized the answer of every Matrix fall-through: 404 for an unrouted
  endpoint, 405 for an unsupported method). The logic is unchanged: the three body checks cover all of them.
  """
  def unimplemented_answer?(conn) do
    body = conn.resp_body || ""
    (conn.status == 404 and body == "not found") or body =~ "M_NOT_FOUND" or body =~ "M_UNRECOGNIZED"
  end

  @oauth_keys ["oauth_enabled", "oauth_issuer_url"]

  @doc """
  Integration variant (AC3): writes the real `server_config` rows (privileged). On the FIRST call in a
  test the prior rows are captured and their restore is registered with `on_exit` BEFORE anything is
  written (a crash between the write and the registration can never leak `oauth_enabled = true`).
  Returns the prior rows.
  """
  def set_oauth_rows!(values) when is_map(values) do
    prior =
      case Process.get(:atdd_oauth_rows_prior) do
        nil ->
          %{rows: rows} = privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = ANY($1)", [@oauth_keys])
          Process.put(:atdd_oauth_rows_prior, rows)
          ExUnit.Callbacks.on_exit(fn -> restore_oauth_rows!(rows) end)
          rows

        rows ->
          rows
      end

    for {k, v} <- values, k in @oauth_keys do
      privileged_sql!(
        "INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at",
        [k, v, System.system_time(:millisecond)]
      )
    end

    prior
  end

  def restore_oauth_rows!(prior) do
    privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@oauth_keys])
    for [k, v, at] <- prior, do: privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story legacy-sso-redirect-confirmation (G3-3): the confirmation page of the legacy SSO login
  # ════════════════════════════════════════════════════════════════════════════
  #
  # Contracts pinned here (story D3, D7-D10, D12; ATDD role):
  #
  #   * the callback for an UNLISTED https redirectUrl answers `303 Location: /_matrix/client/v3/login/sso/confirm`
  #     with the binding cookie `__Host-nebu_sso_confirm` (`Path=/; Secure`) on an https request, else
  #     `nebu_sso_confirm` (`Path=/_matrix/client/v3/login/sso/confirm`); value = 43 chars base64url; always
  #     `HttpOnly; SameSite=Lax; Max-Age=300`.
  #   * `Nebu.Matrix.SsoStore` `:confirm` tag: `put_confirm(key, entry, ttl)`, `peek_confirm(key)`,
  #     `pop_confirm(key)`; the key is derived from SHA-256 of the cookie value. The story leaves RAW 32 bytes
  #     or lower-case HEX open (D7), so every helper here accepts BOTH (`confirm_keys/1`).
  #   * CSRF token = `base64url_nopad(SHA-256("nebu-sso-confirm-csrf:" <> cookie))`, hidden input `csrf_token`.
  #   * POST fetch metadata of a real top-level form submit: `Origin` = the request's own origin (scheme + Host
  #     header), `Sec-Fetch-Site: same-origin`, `-Mode: navigate`, `-Dest: document`, `-User: ?1`.
  #   * seams (story "Seams"): `:sso_redirect_origins_reader` (0-arity -> string | list), `:sso_trusted_origin_check`
  #     (1-arity fn origin -> boolean | raise), `:server_name`, `:sso_redirect_schemes_reader`.

  @sso_confirm_path "/_matrix/client/v3/login/sso/confirm"
  @sso_confirm_cookie "nebu_sso_confirm"
  @sso_confirm_cookie_https "__Host-nebu_sso_confirm"
  @sso_host "nebu.test"
  @sso_store Nebu.Matrix.SsoStore

  def sso_confirm_path, do: @sso_confirm_path
  def sso_confirm_cookie_name(https? \\ false), do: if(https?, do: @sso_confirm_cookie_https, else: @sso_confirm_cookie)
  def sso_host, do: @sso_host

  @doc "The CSRF token the confirmation page must carry for a cookie value (D8, nothing stored)."
  def sso_confirm_csrf(cookie_value),
    do: :crypto.hash(:sha256, "nebu-sso-confirm-csrf:" <> cookie_value) |> Base.url_encode64(padding: false)

  @doc "Both candidate `SsoStore` keys of a cookie value: raw SHA-256 bytes and lower-case hex (story D7 leaves it open)."
  def confirm_keys(cookie_value), do: [:crypto.hash(:sha256, cookie_value), sha256_hex(cookie_value)]

  @doc "The pending `:confirm` entry of a cookie value (map) or nil; either key form is looked up."
  def confirm_entry(cookie_value) when is_binary(cookie_value) do
    Enum.find_value(confirm_keys(cookie_value), fn key ->
      case apply(@sso_store, :peek_confirm, [key]) do
        {:ok, entry} -> entry
        _ -> nil
      end
    end)
  end

  @doc "Puts an entry under BOTH key forms (a peer-replicated or hand-made entry); `ttl` seconds."
  def put_confirm_both!(cookie_value, entry, ttl \\ 300) do
    for key <- confirm_keys(cookie_value), do: :ok = apply(@sso_store, :put_confirm, [key, entry, ttl])
    :ok
  end

  @doc "A well-formed pending confirmation entry (maps keyed like D7); `overrides` merge in."
  def confirm_entry_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        id_token: "fixture-id-token-" <> rand(8),
        oidc_refresh_token: "fixture-idp-rt-" <> rand(8),
        redirect_url: "https://unlisted.example/cb",
        origin: "https://unlisted.example",
        host: "unlisted.example",
        port: nil,
        path: "/cb",
        user_id: "@fixture:test.local"
      },
      Map.new(overrides)
    )
  end

  defp sso_table!, do: :sys.get_state(@sso_store).table

  @doc "Number of live-or-expired entries of one SsoStore tag (`:state`, `:token`, `:confirm`) on this node."
  def sso_count(tag) do
    :ets.foldl(fn {{t, _}, _}, acc when t == tag -> acc + 1; _, acc -> acc end, 0, sso_table!())
  end

  @doc "The set of loginToken keys of this node's SsoStore (compare before / after instead of absolute counts)."
  def sso_token_keys do
    :ets.foldl(fn {{:token, k}, _}, acc -> MapSet.put(acc, k); _, acc -> acc end, MapSet.new(), sso_table!())
  end

  @doc "How many loginTokens exist now that were not in `before` (a `sso_token_keys/0` snapshot)."
  def sso_new_tokens(before), do: sso_token_keys() |> MapSet.difference(before) |> MapSet.size()

  @doc "Remaining lifetime in seconds of a live loginToken in this node's SsoStore (nil when absent)."
  def sso_token_ttl(token) do
    case :ets.lookup(sso_table!(), {:token, token}) do
      [{_, {_payload, exp}}] -> exp - System.system_time(:second)
      _ -> nil
    end
  end

  @doc """
  Removes every `:confirm` entry of this node (test hygiene after a cap test). Deleted inside the store process
  (`:sys.replace_state/2`: the ETS table is protected) so it works without any store API and never raises.
  """
  def drop_confirm_entries!, do: sso_delete_tag(:confirm)

  @doc "Removes every `:token` (loginToken) entry of this node."
  def drop_token_entries!, do: sso_delete_tag(:token)

  defp sso_delete_tag(tag) do
    if Process.whereis(@sso_store) do
      try do
        :sys.replace_state(@sso_store, fn %{table: t} = st ->
          :ets.match_delete(t, {{tag, :_}, :_})
          st
        end)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # -- seams ----------------------------------------------------------------

  @doc "Installs the operator-list seam (a string or a list of origins) for this test only."
  def sso_origins!(value), do: put_env_scoped(:sso_redirect_origins_reader, fn -> value end)

  @doc """
  Installs `fun` (2-arity, `fn origin, raw_redirect_url -> boolean`, may raise) as the trusted-URL check of the
  OAuth sources (issuer origin, approved clients' registered redirect URIs) for this test only.
  """
  def sso_trusted_check!(fun) when is_function(fun, 2), do: put_env_scoped(:sso_trusted_origin_check, fun)

  @doc "No auto-trusted OAuth source (no DB): every origin that is not listed by 1/2 is NOT trusted."
  def sso_no_trusted_origins!, do: sso_trusted_check!(fn _origin, _raw_url -> false end)

  # -- the legacy flow ----------------------------------------------------------

  defp sso_conn(method, path, body \\ nil), do: if(body, do: conn(method, path, body), else: conn(method, path))

  defp sso_host_headers(opts) do
    host = Keyword.get(opts, :host, @sso_host)
    [{"host", host}]
  end

  @doc """
  `GET /sso/redirect[/{idp}]` for `redirect_url` through the full router; asserts the 302 to the IdP and
  returns `%{conn, idp, state, nonce}`. Options: `:ip`, `:headers`, `:idp` (path suffix).
  """
  def sso_start!(redirect_url, opts \\ []) do
    path = "/_matrix/client/v3/login/sso/redirect" <> if(idp = Keyword.get(opts, :idp), do: "/" <> idp, else: "")

    conn =
      sso_conn(:get, path <> "?redirectUrl=" <> URI.encode_www_form(redirect_url))
      |> put_headers(Keyword.get(opts, :headers, []))
      |> with_opts(opts)
      |> Nebu.Web.Router.call(@router_opts)

    assert conn.status == 302,
           "the redirect leg must 302 to the IdP for #{inspect(redirect_url)}, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"

    idp = idp_params(conn)
    %{conn: conn, idp: idp, state: idp["state"], nonce: idp["nonce"]}
  end

  @doc """
  Completes a legacy flow at the shared callback (stubbed IdP exchange with a signed id_token carrying the
  flow's nonce). Options: `:sub`, `:claims` (a `nil` value removes the claim), `:idp_rt` (default a random
  value, `nil` = none), `:https`, `:headers`, `:ip`, `:host`, `:code`.
  """
  def sso_finish(flow, priv_jwk, opts \\ []) do
    claims =
      %{"sub" => Keyword.get(opts, :sub, unique_sub()), "nonce" => flow.nonce}
      |> Map.merge(Keyword.get(opts, :claims, %{}))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    stub_idp_exchange({:ok, sign_id_token(priv_jwk, claims), Keyword.get(opts, :idp_rt, "idp-rt-" <> rand(10))})

    qs = URI.encode_query([{"code", Keyword.get(opts, :code, "idp-code-" <> rand())}, {"state", flow.state}])

    sso_conn(:get, "/_matrix/client/v3/login/sso/redirect/oidc?" <> qs)
    |> put_headers(sso_host_headers(opts) ++ Keyword.get(opts, :headers, []))
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc """
  The story's `legacy_callback!(priv, sub, redirect_url)`: redirect leg + stubbed exchange + callback; returns
  the CALLBACK conn. Options of `sso_start!/2` and `sso_finish/3`.
  """
  def legacy_callback!(priv_jwk, sub, redirect_url, opts \\ []) do
    flow = sso_start!(redirect_url, Keyword.take(opts, [:headers, :ip]))
    sso_finish(flow, priv_jwk, Keyword.put(opts, :sub, sub))
  end

  @doc """
  Like `legacy_callback!/4` but the SSO state is inserted DIRECTLY (a redirect URL the redirect leg would
  refuse, e.g. a state created by an older node during a rolling deploy). Returns the callback conn.
  """
  def legacy_callback_for_state!(priv_jwk, sub, redirect_url, opts \\ []) do
    state = rand(16)
    nonce = rand(32)
    :ok = @sso_store.put_state(state, %{verifier: "v-" <> rand(16), nonce: nonce, redirect_url: redirect_url, uia_session: nil}, 600)
    sso_finish(%{state: state, nonce: nonce}, priv_jwk, Keyword.put(opts, :sub, sub))
  end

  @doc "The `loginToken` query parameter(s) of a `Location` (a list; nil Location => [])."
  def login_tokens_of(conn_or_location) do
    loc = if is_binary(conn_or_location), do: conn_or_location, else: location(conn_or_location)

    case loc do
      nil ->
        []

      loc ->
        uri = URI.parse(loc)
        frag_q = (uri.fragment || "") |> String.split("?", parts: 2) |> Enum.at(1)

        for q <- [uri.query, frag_q], is_binary(q), {"loginToken", v} <- URI.query_decoder(q) |> Enum.to_list(), do: v
    end
  end

  @doc "`POST /login {type: m.login.token}` (JSON, unique peer IP unless `:ip`); options `:ip`, `:device_id`, `:refresh_token`."
  def sso_token_login(token, opts \\ []) do
    body = %{"type" => "m.login.token", "token" => token}
    body = if d = Keyword.get(opts, :device_id), do: Map.put(body, "device_id", d), else: body
    body = if Keyword.get(opts, :refresh_token), do: Map.put(body, "refresh_token", true), else: body

    sso_conn(:post, "/_matrix/client/v3/login", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  # -- the confirmation page ----------------------------------------------------

  @doc "Raw `set-cookie` strings of the confirmation cookie (either name) of a response."
  def sso_confirm_set_cookies(conn),
    do: Enum.filter(set_cookies(conn), &(String.starts_with?(&1, @sso_confirm_cookie <> "=") or String.starts_with?(&1, @sso_confirm_cookie_https <> "=")))

  @doc "True when the response CLEARS the confirmation cookie (`Max-Age=0` / empty value)."
  def sso_confirm_cookie_cleared?(conn) do
    Enum.any?(sso_confirm_set_cookies(conn), &(&1 =~ ~r/max-age=0(;|\z)/i))
  end

  @doc "The live confirmation cookie `{name, value, raw}` (a clearing cookie is not returned); flunks if absent."
  def sso_confirm_cookie(conn) do
    live = Enum.reject(sso_confirm_set_cookies(conn), &(&1 =~ ~r/max-age=0(;|\z)/i))

    case live do
      [raw | _] ->
        [pair | _] = String.split(raw, ";")
        [name, value] = String.split(pair, "=", parts: 2)
        {name, value, raw}

      [] ->
        flunk(
          "expected a confirmation cookie on the response (HTTP #{conn.status}, Location=#{inspect(location(conn))}), got set-cookie=#{inspect(set_cookies(conn))} body=#{String.slice(conn.resp_body || "", 0, 200)}"
        )
    end
  end

  defp sso_pair(%Plug.Conn{} = conn), do: sso_confirm_cookie(conn) |> then(fn {n, v, _} -> {n, v} end)
  defp sso_pair({name, value}), do: {name, value}
  defp sso_pair({name, value, _raw}), do: {name, value}

  @doc "`GET /sso/confirm` with the cookie (callback conn or `{name, value}`; nil = none); options `:https`, `:headers`, `:ip`, `:method`, `:host`."
  def sso_confirm_get(cookie, opts \\ []) do
    c = sso_conn(Keyword.get(opts, :method, :get), @sso_confirm_path <> Keyword.get(opts, :query, ""))

    c =
      case cookie do
        nil ->
          c

        cookie ->
          {name, value} = sso_pair(cookie)
          put_req_header(c, "cookie", "#{name}=#{value}")
      end

    c
    |> put_headers(sso_host_headers(opts) ++ Keyword.get(opts, :headers, []))
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc """
  `POST /sso/confirm` as a real top-level form submit (all fetch-metadata headers set; every one can be
  replaced/removed through `:headers` with `{name, nil}`). `params`: pairs, a map or a RAW body. Options:
  `:cookie` (pair / callback conn; nil = none), `:https`, `:headers`, `:ip`, `:content_type`, `:query`,
  `:method`, `:host`, `:origin` (default = the request's own origin), `:extra_headers` (raw, duplicates kept).
  """
  def sso_confirm_post(params, opts \\ []) do
    body = if is_binary(params), do: params, else: form_encode(params)
    path = @sso_confirm_path <> if(q = Keyword.get(opts, :query), do: "?" <> q, else: "")
    c = sso_conn(Keyword.get(opts, :method, :post), path, body)

    c =
      case Keyword.get(opts, :content_type, "application/x-www-form-urlencoded") do
        nil -> c
        ct -> put_req_header(c, "content-type", ct)
      end

    c =
      case Keyword.get(opts, :cookie) do
        nil ->
          c

        cookie ->
          {name, value} = sso_pair(cookie)
          put_req_header(c, "cookie", "#{name}=#{value}")
      end

    host = Keyword.get(opts, :host, @sso_host)
    own_origin = (if(Keyword.get(opts, :https), do: "https://", else: "http://")) <> host

    defaults = [
      {"host", host},
      {"origin", Keyword.get(opts, :origin, own_origin)},
      {"sec-fetch-site", "same-origin"},
      {"sec-fetch-mode", "navigate"},
      {"sec-fetch-dest", "document"},
      {"sec-fetch-user", "?1"}
    ]

    overrides = Keyword.get(opts, :headers, [])

    headers =
      Enum.reject(defaults, fn {k, _} -> List.keymember?(overrides, k, 0) end) ++
        Enum.reject(overrides, fn {_k, v} -> is_nil(v) end)

    c = c |> put_headers(headers)
    # `:extra_headers` are appended RAW (duplicates allowed): two `Origin` headers, a repeated `Sec-Fetch-Site`
    c = %{c | req_headers: c.req_headers ++ Keyword.get(opts, :extra_headers, [])}

    c
    |> account_scheme(opts)
    |> with_opts(opts)
    |> Nebu.Web.Router.call(@router_opts)
  end

  @doc """
  The user's decision: GET the page (asserting it renders), then POST `decision` (`:continue` | `:cancel`) with
  the cookie, the page's CSRF token and the fetch-metadata headers of a top-level form submit. Returns the POST
  response. Options: `:https`, `:ip`, `:headers` (POST), `:host`, `:get` (false = skip the GET and derive the
  token), `:csrf` (override), `:decision_value` (raw `decision`), `:origin`.
  """
  def confirm!(cookie, decision, opts \\ []) when decision in [:continue, :cancel] do
    {_name, value} = pair = sso_pair(cookie)

    csrf =
      cond do
        Keyword.has_key?(opts, :csrf) ->
          Keyword.fetch!(opts, :csrf)

        Keyword.get(opts, :get, true) ->
          page = sso_confirm_get(pair, Keyword.take(opts, [:https, :host]))

          assert page.status == 200,
                 "the confirmation page must render (200), got #{page.status}: #{String.slice(page.resp_body || "", 0, 300)}"

          assert page.resp_body =~ ~r/<main[^>]*data-page="sso-confirm"/, "page hook data-page=\"sso-confirm\" missing"
          csrf_from(page) || flunk("the confirmation page carries no csrf_token input")

        true ->
          sso_confirm_csrf(value)
      end

    sso_confirm_post(
      [{"csrf_token", csrf}, {"decision", Keyword.get(opts, :decision_value, Atom.to_string(decision))}],
      [cookie: pair] ++ Keyword.take(opts, [:https, :ip, :headers, :origin, :host])
    )
  end

  @doc """
  The callback answered `303 Location: /_matrix/client/v3/login/sso/confirm` with the binding cookie and the D9
  flow headers, and minted NOTHING: no loginToken and no target host in any header. Option `:https`.
  """
  def assert_confirm_redirect(conn, opts \\ []) do
    https? = Keyword.get(opts, :https, false)

    assert conn.status == 303,
           "the callback must answer 303 to the confirmation page, got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    assert location(conn) == @sso_confirm_path, "Location must be exactly #{@sso_confirm_path}, got #{inspect(location(conn))}"
    assert conn.resp_body in [nil, ""]
    {name, value, raw} = sso_confirm_cookie(conn)
    assert name == sso_confirm_cookie_name(https?)
    assert value =~ ~r/\A[A-Za-z0-9_-]{43}\z/, "binding cookie = base64url(32 random bytes)"
    assert raw =~ ~r/HttpOnly/i and raw =~ ~r/SameSite=Lax/i and raw =~ ~r/max-age=300/i
    if https?, do: assert(raw =~ ~r/path=\/(;|\z)/i and raw =~ ~r/Secure/i, "__Host- cookie: Path=/; Secure: #{raw}")
    unless https?, do: assert(raw =~ ~r/path=\/_matrix\/client\/v3\/login\/sso\/confirm(;|\z)/i, "http cookie path: #{raw}")
    assert_sso_flow_headers(conn)
    refute Enum.any?(conn.resp_headers, fn {_k, v} -> v =~ "loginToken" end), "no header carries a loginToken"
    conn
  end

  @doc "D9 / AC6.3 headers of every `303` of the flow and (without CORS / COOP) of every other response."
  def assert_sso_flow_headers(conn) do
    assert header(conn, "cache-control") =~ "no-store"
    assert header(conn, "pragma") =~ "no-cache"
    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "referrer-policy") in ["no-referrer", "same-origin"]
    refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end), "no CORS header"
    assert header(conn, "cross-origin-opener-policy") == nil, "COOP must be ABSENT on every response of the flow (oracle M1)"
    conn
  end

  @doc "Error page: status, `data-page=\"sso-confirm-error\"` + `data-error`, html, no Location, D9 headers, no script."
  def assert_confirm_error(conn, status, error_code) do
    assert conn.status == status,
           "expected HTTP #{status} page #{error_code}, got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    assert location(conn) == nil, "an error page is never a redirect"
    assert (header(conn, "content-type") || "") =~ ~r{^text/html;\s*charset=utf-8}i
    body = conn.resp_body
    assert body =~ ~r/<main[^>]*data-page="sso-confirm-error"/, "page hook data-page=\"sso-confirm-error\" missing"
    assert body =~ ~s(data-error="#{error_code}"), "expected data-error=\"#{error_code}\" in #{String.slice(body, 0, 400)}"
    refute body =~ ~r/<script/i
    assert header(conn, "cache-control") =~ "no-store"
    assert header(conn, "pragma") =~ "no-cache"
    assert header(conn, "x-frame-options") == "DENY"
    assert (header(conn, "content-security-policy") || "") =~ ~r/^default-src 'none'/
    assert (header(conn, "content-security-policy") || "") =~ "form-action 'none'"
    assert header(conn, "referrer-policy") == "no-referrer"
    assert header(conn, "access-control-allow-origin") == nil
    assert header(conn, "cross-origin-opener-policy") == nil
    conn
  end

  @doc "Continue answered `303` (never 302/307) to the client target with exactly one new loginToken; returns the token."
  def assert_continue_redirect(conn) do
    assert conn.status == 303,
           "Continue must answer 303 See Other, got #{conn.status} Location=#{inspect(location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    assert [token] = login_tokens_of(conn), "exactly one loginToken in Location #{inspect(location(conn))}"
    assert token =~ ~r/\A[0-9a-f]{64}\z/ or byte_size(token) >= 16
    assert_sso_flow_headers(conn)
    token
  end

  @doc "The Matrix user id the server derives for `claims` with the CURRENT `:server_name`."
  def sso_user_id(claims),
    do: Nebu.Matrix.UserId.from_claims(claims, Application.get_env(:nebu_http, :server_name, "localhost"))
end

defmodule Nebu.OAuth.TestSupport.NoSuchRepo do
  @moduledoc "Never started: installed as `:nebu_http, :oauth_repo` to simulate an unavailable database."
end

defmodule Nebu.OAuth.TestSupport.DeactivatedValidator do
  @moduledoc "`:session_manager, :validator_module` stub: every user is deactivated (AC7.11 / D18)."
  def validate(_user_id, _role, _display_name, _email), do: {:error, :deactivated}
end

defmodule Nebu.OAuth.TestSupport.FailingValidator do
  @moduledoc "`:session_manager, :validator_module` stub: provisioning fails with a non-deactivation error."
  def validate(_user_id, _role, _display_name, _email), do: {:error, :db_down}
end
