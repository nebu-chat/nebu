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
  @spec postgres_ssl_opts() :: [ssl: boolean()]
  def postgres_ssl_opts do
    [ssl: System.get_env("NEBU_POSTGRES_SSL", "false") == "true"]
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
    ] ++ postgres_ssl_opts()
  end
end
