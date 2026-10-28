defmodule Nebu.Release do
  @moduledoc """
  Release task that applies the canonical SQL schema migrations.

  ## Why raw SQL, not `Ecto.Migrator`

  Per ADR-018 the SQL migrations under `priv/migrations/*.up.sql` are the SOLE
  canonical data model — there is no `Ecto.Schema`. These files were previously
  applied by the Go gateway via `golang-migrate`. When the Go layer was removed
  (story `go-removal-cleanup`) the migration runner was re-homed here so the
  schema still provisions on a fresh database and existing installs are
  recognised as already-migrated.

  ## State tracking — compatible with golang-migrate

  golang-migrate tracks state in a `schema_migrations(version BIGINT PRIMARY KEY,
  dirty BOOLEAN)` table holding only the latest applied version. We reuse that
  exact table and format so a database already migrated by the old Go gateway
  (currently at version 3) is seen as up-to-date and DDL is NOT re-run — critical
  for existing deployments. A fresh database has no table; we create it and apply
  every file from version 1.

  Run from the release:

      bin/nebu eval "Nebu.Release.migrate()"

  ## Connection / role

  Migrations connect as the migration role (table owner) via
  `NEBU_DB_URL_MIGRATE`, falling back to `NEBU_DB_URL` (the runtime `nebu_app`
  role) when the dedicated migrate URL is not set — exactly the fallback the Go
  `RunMigrations(dbURL, migrateURL...)` had. The runtime Repo is NOT started for
  this task; we open a short-lived Postgrex connection and close it.
  """

  require Logger

  @app :nebu

  @doc """
  Applies all pending `*.up.sql` migrations in version order. Idempotent: only
  files with a version greater than the recorded `schema_migrations.version` are
  applied. Raises on a dirty schema (a previous migration left the table marked
  dirty) — that cannot self-heal and needs manual recovery.
  """
  @spec migrate() :: :ok
  def migrate do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    url = migrate_url()
    {:ok, conn} = Postgrex.start_link(parse_url(url))

    try do
      ensure_version_table(conn)
      {current, dirty?} = current_version(conn)

      if dirty? do
        raise "database schema is dirty (version #{current}) — manual recovery required " <>
                "before migrations can continue"
      end

      pending = pending_migrations(current)

      if pending == [] do
        Logger.info("Nebu.Release.migrate: schema up to date at version #{current}")
      else
        Enum.each(pending, fn {version, path} ->
          apply_migration(conn, version, path)
        end)
      end

      :ok
    after
      GenServer.stop(conn)
    end
  end

  # ── operator OAuth revocation (story oauth-client-revocation, CR10) ─────────────────────────
  #
  # Run in the RUNNING node: `bin/nebu rpc 'Nebu.Release.revoke_oauth_client("<client_id>", "<reason>")'`. Shell
  # access is the operator's strong authentication (and the escape hatch when the admin IdP is down or cannot
  # pass the fresh re-authentication of the admin UI). They need the running application (Repo, audit writer):
  # `bin/nebu eval` does not start it.

  @operator "operator:rpc"

  @doc """
  Revokes an APPROVED OAuth client exactly like the admin UI (`Nebu.OAuth.revoke_client/3`: status `revoked`,
  every session, device and E2EE device key of the client, its codes and requests, one `oauth_client_revoked`
  audit row with `reauth: "rpc"`, all in one transaction), actor `"operator:rpc"`. `reason` is optional text
  (normalised by `Nebu.OAuth.normalize_reason/1`: control characters stripped, at most 500 characters).

  `{:ok, %{devices: n}}`, `{:error, :not_approved}` (unknown / pending / rejected / already revoked) or
  `{:error, reason}` (rolled back).
  """
  @spec revoke_oauth_client(String.t(), String.t() | nil) :: {:ok, %{devices: non_neg_integer()}} | {:error, term()}
  def revoke_oauth_client(client_id, reason \\ nil) when is_binary(client_id) do
    reason = Nebu.OAuth.normalize_reason(reason)

    audit = fn pairs ->
      metadata = %{"devices" => length(pairs), "reauth" => "rpc"} |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
      write_audit("oauth_client_revoked", client_id, metadata, "success")
    end

    Nebu.OAuth.revoke_client(client_id, @operator, reason: reason, audit: audit)
  end

  @doc """
  Ends EVERY OAuth session of EVERY user (the operator's kill switch: run it AFTER switching `oauth_enabled`
  off): each device with an OAuth session is torn down atomically (sessions, device, E2EE keys), in batches of
  500. Clients stay approved (they may sign in again once OAuth is back on); legacy sessions and devices are
  untouched. Writes ONE `oauth_sessions_revoked_all` audit row with the number of devices.

  `{:ok, devices_ended}` (a second run returns `{:ok, 0}`) or `{:error, reason}` (a partial run is audited with
  outcome `failure`; the call is idempotent: run it again).
  """
  @spec revoke_all_oauth_sessions() :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_oauth_sessions do
    case Nebu.Matrix.oauth_end_all_sessions() do
      {:ok, n} ->
        case write_audit("oauth_sessions_revoked_all", "all", %{"devices" => n}, "success") do
          :ok -> {:ok, n}
          {:error, reason} -> {:error, {:audit, reason}}
        end

      {:error, {:unavailable, ended}} ->
        _ = write_audit("oauth_sessions_revoked_all", "all", %{"devices" => ended}, "failure")
        {:error, :unavailable}
    end
  end

  # ── operator emergency paths for the Admin UI settings (SEC delta gate admin-switch, X2-6) ────────────────────────
  #
  # The Admin UI writers need a fresh admin sign-in; on an instance without a database console a wrong value (a role mapping that locks all
  # administrators out, invalid scopes that break the IdP sign-in) or an IdP outage would leave no way back. Run in the RUNNING node:
  #   bin/nebu rpc 'IO.inspect(Nebu.Release.disable_oauth())'
  #   bin/nebu rpc 'IO.inspect(Nebu.Release.reset_admin_group_claim())'        # or reset_admin_group_claim("my-admin-group")
  #   bin/nebu rpc 'IO.inspect(Nebu.Release.reset_oidc_scopes())'
  # Each writes its audit row (actor `operator:rpc`, `reauth: "rpc"`).

  @doc """
  Switches OAuth OFF (the kill switch without the Admin UI): `oauth_enabled = false`, a valid stored issuer is kept, an invalid one is cleared. Takes
  effect on this node at once and on the others within `NEBU_OAUTH_CONFIG_CACHE_MS`. One `oauth_switch_changed` audit row; like the Admin UI the switch is
  applied even if the audit row cannot be written. `{:ok, %{audited: boolean}}` or `{:error, reason}`.
  """
  @spec disable_oauth() :: {:ok, %{audited: boolean()}} | {:error, term()}
  def disable_oauth do
    stored = Nebu.OAuth.config()

    issuer =
      case Nebu.OAuth.normalize_issuer(stored.issuer_url) do
        {:ok, normalized} -> normalized
        :error -> ""
      end

    audit = fn ->
      write_audit("oauth_switch_changed", "server_config", "oauth_enabled", %{"enabled_before" => stored.enabled, "enabled_after" => false, "issuer_before" => stored.issuer_url || "", "issuer_after" => issuer, "reauth" => "rpc"}, "success")
    end

    Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => issuer}, audit: audit, unaudited_ok: true)
  end

  @doc """
  Sets the admin group VALUE (`server_config` `admin_group_claim`, the value the admin check looks for under the configured claim path) back to
  `value` (default `"instance_admin"`): the way out of a role mapping that locked all administrators out. The admin check reads the value on every
  request, no restart is needed. One `admin_group_claim_changed` audit row. `:ok` or `{:error, reason}`.
  """
  @spec reset_admin_group_claim(String.t()) :: :ok | {:error, term()}
  def reset_admin_group_claim(value \\ "instance_admin") when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, :empty_value}
    else
      with :ok <- upsert_config(%{"admin_group_claim" => value}) do
        write_audit("admin_group_claim_changed", "server_config", "admin_group_claim", %{"admin_group_claim" => value, "reauth" => "rpc"}, "success")
      end
    end
  end

  @doc """
  Clears the extra OIDC scopes of the Matrix and the admin client (`matrix_oidc_extra_scopes`, `admin_oidc_extra_scopes` = the empty string: only
  `openid`): the way out of invalid scopes that break the IdP sign-in. One `oidc_scopes_changed` audit row. `:ok` or `{:error, reason}`.
  """
  @spec reset_oidc_scopes() :: :ok | {:error, term()}
  def reset_oidc_scopes do
    changes = %{"matrix_oidc_extra_scopes" => "", "admin_oidc_extra_scopes" => ""}

    with :ok <- upsert_config(changes) do
      write_audit("oidc_scopes_changed", "server_config", "oidc_extra_scopes", Map.put(changes, "reauth", "rpc"), "success")
    end
  end

  defp upsert_config(changes) do
    # `upsert_server_config/1` answers :ok or raises (database error, row-level policy)
    Nebu.Admin.DB.upsert_server_config(changes)
  rescue
    e -> {:error, {:raised, e.__struct__}}
  end

  # ── operator id_token signing-key rotation (story oauth-hardening-hygiene, HY12 / HY13) ──────────────────────────
  #
  # Run in the RUNNING node (the output goes through IO.inspect; `bin/nebu rpc` prints nothing by itself):
  #   bin/nebu rpc 'IO.inspect(Nebu.Release.rotate_oauth_signing_key())'
  # Both functions return kids and atoms only; no key material is ever returned or logged.

  @doc """
  Two-phase rotation of the id_token signing key. Call 1 (no pending `next` key) publishes a new ES256 key as
  `next` (it appears in the JWKS, it does not sign): `{:ok, {:published, kid, activate_after_iso8601}}`. Call 2,
  at least 900 s later (JWKS max-age 600 s + id_token lifetime 300 s, enforced by the database), retires the
  active key (kept in the JWKS for 900 s more) and promotes `next`: `{:ok, {:activated, new_kid, retired_kid}}`.
  Too early: `{:error, {:too_early, seconds_left}}` (no change); a `next` key that cannot be decrypted:
  `{:error, :next_key_unavailable}` (use `replace_oauth_signing_key(:emergency)`); a lost race:
  `{:error, :conflict}` (another operator's call changed the `next` key while this one waited: re-read the JWKS and run it again if needed); nothing to rotate yet: `{:error, :no_active_key}`. Each successful call
  writes one audit row (`oauth_signing_key_published` / `oauth_signing_key_rotated`, actor `operator:rpc`).
  """
  @spec rotate_oauth_signing_key() :: {:ok, tuple()} | {:error, term()}
  def rotate_oauth_signing_key do
    case Nebu.OAuth.rotate_signing_key(audit: &signing_key_audit/3) do
      {:ok, {:published, kid, %DateTime{} = activate_after}} -> {:ok, {:published, kid, DateTime.to_iso8601(activate_after)}}
      other -> other
    end
  end

  @doc """
  Emergency replacement of an active signing key that can no longer be decrypted (for instance after
  `NEBU_INTERNAL_SECRET` changed): `replace_oauth_signing_key(:emergency)` retires the active key and any
  `next` key and installs a freshly generated active key in one transaction (`{:ok, {:replaced, new_kid,
  old_kid}}`, audit `oauth_signing_key_replaced`). Clients holding a cached JWKS (up to 10 minutes) cannot verify
  new id_tokens until they refetch; no session is revoked. Any other argument (or none):
  `{:error, :confirmation_required}`.
  """
  @spec replace_oauth_signing_key(term()) :: {:ok, tuple()} | {:error, term()}
  def replace_oauth_signing_key(confirmation \\ nil)
  def replace_oauth_signing_key(:emergency), do: Nebu.OAuth.replace_signing_key(audit: &signing_key_audit/3)
  def replace_oauth_signing_key(_other), do: {:error, :confirmation_required}

  # metadata values are kids only (the caller builds them)
  defp signing_key_audit(action, new_kid, metadata),
    do: write_audit(action, "oauth_signing_key", new_kid, metadata, "success")

  defp write_audit(action, target_id, metadata, outcome),
    do: write_audit(action, "oauth_client", target_id, metadata, outcome)

  defp write_audit(action, target_type, target_id, metadata, outcome) do
    writer = Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    case writer.log(@operator, action, target_type, target_id, metadata, outcome, nil) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    e -> {:error, {:raised, e.__struct__}}
  end

  # ── version table ──────────────────────────────────────────────────────────

  defp ensure_version_table(conn) do
    # Same shape golang-migrate creates. IF NOT EXISTS so an install already
    # migrated by the Go gateway keeps its recorded version.
    Postgrex.query!(
      conn,
      "CREATE TABLE IF NOT EXISTS schema_migrations (version BIGINT NOT NULL PRIMARY KEY, dirty BOOLEAN NOT NULL DEFAULT false)",
      []
    )
  end

  defp current_version(conn) do
    case Postgrex.query!(
           conn,
           "SELECT version, dirty FROM schema_migrations ORDER BY version DESC LIMIT 1",
           []
         ) do
      %{rows: [[version, dirty]]} -> {version, dirty}
      %{rows: []} -> {0, false}
    end
  end

  defp set_version(conn, version) do
    # golang-migrate keeps a single row (latest version). Mirror that: clear and
    # insert so `schema_migrations` always holds exactly the current version.
    Postgrex.query!(conn, "DELETE FROM schema_migrations", [])
    Postgrex.query!(conn, "INSERT INTO schema_migrations (version, dirty) VALUES ($1, false)", [
      version
    ])
  end

  # ── migration discovery + application ────────────────────────────────────────

  defp pending_migrations(current) do
    migrations_dir()
    |> list_up_migrations()
    |> select_pending(current)
  end

  @doc false
  # Pure: given a list of {version, path} and the current applied version,
  # return only the strictly-newer ones, sorted ascending. Exposed for unit
  # testing the version-selection logic without a database.
  @spec select_pending([{integer(), String.t()}], integer()) :: [{integer(), String.t()}]
  def select_pending(migrations, current) do
    migrations
    |> Enum.filter(fn {version, _path} -> version > current end)
    |> Enum.sort_by(fn {version, _path} -> version end)
  end

  @doc false
  # Pure: parse golang-migrate-style filenames ("000002_name.up.sql") into
  # {version, path} tuples, keeping only `.up.sql` files. Exposed for testing.
  @spec list_up_migrations(String.t()) :: [{integer(), String.t()}]
  def list_up_migrations(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".up.sql"))
    |> Enum.map(fn name ->
      version =
        name
        |> String.split("_", parts: 2)
        |> hd()
        |> String.to_integer()

      {version, Path.join(dir, name)}
    end)
  end

  defp apply_migration(conn, version, path) do
    Logger.info("Nebu.Release.migrate: applying #{Path.basename(path)} (version #{version})")
    sql = File.read!(path)

    # Wrap each migration in a transaction so a failing file leaves no partial
    # DDL and the version is only bumped on success.
    #
    # query_type: :text uses the PostgreSQL *simple* query protocol, which is the
    # only one that accepts a multi-statement script in a single call. The default
    # :binary (extended/prepared) protocol rejects them with 42601 "cannot insert
    # multiple commands into a prepared statement" — these squashed migration files
    # contain many statements (incl. $$-quoted function bodies), so they MUST run
    # via the simple protocol. (Fresh-install bug surfaced by the otp-consolidation
    # integration gate; the runner had only ever been exercised against DBs already
    # migrated by the former Go golang-migrate, which Release skips.)
    Postgrex.transaction(conn, fn tx ->
      Postgrex.query!(tx, sql, [], query_type: :text)
      set_version(tx, version)
    end)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise "migration #{Path.basename(path)} failed: #{inspect(reason)}"
    end
  end

  defp migrations_dir do
    Path.join(:code.priv_dir(@app), "migrations")
  end

  # ── connection config ────────────────────────────────────────────────────────

  defp migrate_url do
    System.get_env("NEBU_DB_URL_MIGRATE") ||
      System.get_env("NEBU_DB_URL") ||
      raise "NEBU_DB_URL_MIGRATE (or NEBU_DB_URL) is not set — cannot run migrations"
  end

  @doc false
  @spec postgres_ssl_opts() :: [ssl: false | keyword()]
  @spec postgres_ssl_opts(String.t() | nil) :: [ssl: false | keyword()]
  def postgres_ssl_opts(hostname \\ nil) do
    case System.get_env("NEBU_POSTGRES_SSL", "false") do
      "true" ->
        ssl_opts =
          case System.get_env("NEBU_POSTGRES_CA_CERT_FILE") do
            nil ->
              [verify: :verify_none]

            path ->
              base = [
                verify: :verify_peer,
                cacertfile: to_charlist(path),
                customize_hostname_check: [
                  match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                ]
              ]

              if is_binary(hostname) and hostname != "" do
                [{:server_name_indication, to_charlist(hostname)} | base]
              else
                base
              end
          end

        [ssl: ssl_opts]

      _ ->
        [ssl: false]
    end
  end

  # Parse a postgres[ql]://user:pass@host:port/db URL into Postgrex start opts.
  defp parse_url(url) do
    uri = URI.parse(url)
    [user, pass] =
      case uri.userinfo do
        nil -> [nil, nil]
        info -> case String.split(info, ":", parts: 2) do
                  [u, p] -> [u, p]
                  [u] -> [u, nil]
                end
      end

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: user,
      password: pass,
      database: String.trim_leading(uri.path || "", "/"),
      # A single connection is enough for the migrate-and-exit task.
      pool_size: 1
    ] ++ postgres_ssl_opts(uri.host)
  end
end
