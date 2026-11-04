defmodule Nebu.SessionLifetime.TestSupport do
  @moduledoc """
  Shared helpers of the story `session-lifetime-setting` tests (epic oauth-session-and-consent).

  ## The contract the tests pin

    * The setting is the `server_config` key `matrix_session_ttl_seconds`: whole seconds as text, `3600..7_776_000`. No row (or a row that is
      damaged / out of range) means: the env value `NEBU_MATRIX_SESSION_TTL_SECONDS` (`:nebu_http, :matrix_session_ttl_seconds`), else 8 hours.
    * `Nebu.Web.SessionConfig.matrix_session_ttl_seconds/0` is the ONE accessor every Matrix session issuer reads.
    * Test seam for DB-less tests: the existing `:nebu_http, :oauth_config_source` fun of `Nebu.OAuth.Config` may carry the optional map key
      `:matrix_session_ttl_seconds` (the raw text as stored, or an integer), like `:access_token_ttl_seconds`.
    * `real_seams!/0` touches the global `:compliance, :audit_writer` env: every test module that uses it is `async: false` (the guard of
      audit_writer_seam_race_regression_test.exs scans for that literal in every file that injects the key).
    * The admin write goes through `Nebu.Admin.DB.save_config_audited/2` (test seam `:admin_config_tx`), audit action `session_lifetime_changed`.
  """
  import ExUnit.Assertions

  alias Nebu.OAuth.TestSupport, as: T

  @key "matrix_session_ttl_seconds"
  @default 8 * 3600
  @min 3600
  @max 7_776_000

  def key, do: @key
  def default, do: @default
  def min, do: @min
  def max, do: @max

  @doc "The `:oauth_config_source` seam with a saved lifetime (`raw`: the text as stored, an integer, or `:absent`). OAuth itself stays off."
  def seam_stored(raw) do
    Application.put_env(:nebu_http, :oauth_config_source, fn ->
      base = %{enabled: false, issuer_url: nil}
      if raw == :absent, do: base, else: Map.put(base, :matrix_session_ttl_seconds, raw)
    end)

    :ok
  end

  @doc "Removes the `:matrix_session_ttl_seconds` env of the test (restored on exit): no env value, no short e2e ceiling."
  def clear_env_ttl! do
    T.put_env_scoped(:matrix_session_ttl_seconds, nil)
    Application.delete_env(:nebu_http, :matrix_session_ttl_seconds)
    reset_last_good!()
    ExUnit.Callbacks.on_exit(&reset_last_good!/0)
    :ok
  end

  @config Nebu.OAuth.Config

  @doc """
  Forgets the per-node last-known-good saved lifetime (cycle 1, Kassandra #1: `Nebu.OAuth.Config` keeps the last successfully read value for as long as the node
  lives, so a read failure never lengthens the ceiling). The state is node-global: every test that can read a saved value calls this in its setup AND on exit
  (`clear_env_ttl!/0` does both). Contract: `Nebu.OAuth.Config.reset_last_good_for_test/0` (test builds only). Tolerant of its absence so that the tests of the
  OTHER behaviour keep running against a build that has no such state.
  """
  def reset_last_good! do
    if Code.ensure_loaded?(@config) and function_exported?(@config, :reset_last_good_for_test, 0), do: apply(@config, :reset_last_good_for_test, [])
    :ok
  end

  @doc "Sets the env value `NEBU_MATRIX_SESSION_TTL_SECONDS` (`:matrix_session_ttl_seconds`) for this test only (restored on exit)."
  def put_env_ttl!(seconds), do: T.put_env_scoped(:matrix_session_ttl_seconds, seconds)

  @doc """
  Real-database tests: removes the test seams that would replace the config transaction / reader and the audit writer module (the REAL ones run), and
  restores every one of them on exit.
  """
  def real_seams! do
    for k <- [:admin_config_tx, :admin_server_config_reader] do
      prior = Application.fetch_env(:nebu_http, k)
      Application.delete_env(:nebu_http, k)
      ExUnit.Callbacks.on_exit(fn -> restore_env(:nebu_http, k, prior) end)
    end

    prior = Application.fetch_env(:compliance, :audit_writer)
    Application.delete_env(:compliance, :audit_writer)
    ExUnit.Callbacks.on_exit(fn -> restore_env(:compliance, :audit_writer, prior) end)
    :ok
  end

  defp restore_env(app, key, {:ok, v}), do: Application.put_env(app, key, v)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  # ── the real row (integration) ─────────────────────────────────────────────

  @doc "Writes the row as the owner role (a value the Admin form would never write is fine); the prior state of the row is restored on exit."
  def set_row!(value) when is_binary(value) do
    remember_prior!()

    T.privileged_sql!(
      "INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at",
      [@key, value, System.system_time(:millisecond)]
    )

    :ok
  end

  def delete_row! do
    remember_prior!()
    T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [@key])
    :ok
  end

  defp remember_prior! do
    if Process.get(:session_lifetime_prior) == nil do
      %{rows: rows} = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = $1", [@key])
      Process.put(:session_lifetime_prior, {:saved, rows})

      ExUnit.Callbacks.on_exit(fn ->
        T.privileged_sql!("DELETE FROM server_config WHERE key = $1", [@key])
        for [k, v, at] <- rows, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
      end)
    end

    :ok
  end

  @doc "The stored text of the row as the runtime role sees it, or nil."
  def row_value do
    case T.sql!("SELECT value FROM server_config WHERE key = $1", [@key]) do
      %{rows: [[v]]} -> v
      %{rows: []} -> nil
    end
  end

  @doc "The audit rows of the action `session_lifetime_changed` (maps), oldest first."
  def audit_rows do
    %{rows: rows, columns: cols} =
      T.privileged_sql!(
        "SELECT actor_user_id, action, target_type, target_id, metadata, outcome FROM audit_log WHERE action = 'session_lifetime_changed' ORDER BY id",
        []
      )

    Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new() end)
  end

  def clear_audit_rows!, do: T.privileged_sql!("DELETE FROM audit_log WHERE action = 'session_lifetime_changed'", [])

  @doc "Asserts `dt` (DateTime or unix seconds) lies `seconds` after `from` (unix seconds), within `slack` seconds."
  def assert_ceiling(dt, from, seconds, slack \\ 20) do
    unix = if is_struct(dt, DateTime), do: DateTime.to_unix(dt), else: dt
    assert_in_delta unix, from + seconds, slack, "ceiling #{unix - from}s after the login, expected #{seconds}s"
  end
end
