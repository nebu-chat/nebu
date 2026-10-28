defmodule Nebu.Matrix.AccountManagement do
  @moduledoc """
  The Matrix-domain half of the OAuth account-management page (epic oauth-broker, story
  oauth-account-management, A1/A7/A12/A15/A16). PRIVATE to the Matrix domain: the OAuth domain
  reaches these functions only through the `Nebu.Matrix` facade (ADR-020), which delegates here.

  Matrix owns `users`, `profiles`, `devices`, `matrix_sessions` and `uia_sessions`, so every read and
  update of the page is inline SQL here (ADR-018, no repository layer). All functions are
  ERROR-AWARE (a database problem is `{:error, :unavailable}`, never an empty result: the page must
  not render "no devices" for an outage) and never raise.

    * `identity/1` — the Matrix user of verified IdP claims (A7): derived EXACTLY like the login
      (`Nebu.Matrix.UserId.from_claims/2` with the configured `server_name`), then an error-aware
      `is_active` read. NO provisioning (the page manages existing accounts).
    * `profile/1` — user id, display name, activity (A8 re-checks it on every request).
    * `devices/1` — the user's `devices` with the newest live session's `auth_api` / `client_id`
      (A12). Bounded at 5000 rows (the page renders 500 and says how many are not shown).
    * `device_holder/2` — who holds ONE device id (story oauth-authorize-freshness, FR11): the one-row
      variant of `devices/1` for the consent page and the Allow check.
    * `cross_signing_reset_requests/1`, `approve/2`, `decline/2` — the approval record of the
      `m.oauth` UIA stage is a `uia_sessions` row with `op = 'cross_signing_reset'`
      (`stage_complete = TRUE` = approved); both updates are ONE atomic conditional UPDATE and touch
      ONLY that op (A15/A16).

  ## Clocks

  `uia_sessions` and `auth_time` are unix SECONDS, `devices.last_seen_ts` / `created_at` epoch
  MILLISECONDS: no conversion happens here, the page formats them.

  ## Test seam (compile-time guarded)

  In the `:test` environment the repo of these reads / updates can be replaced with
  `Application.put_env(:nebu_http, :account_matrix_repo, SomeRepo)` (an unavailable-database
  simulation). The seam is chosen at COMPILE time: production builds always use `Nebu.Repo`.
  """

  @device_limit 5000
  @approval_ttl_seconds 600
  @request_limit 20

  if Mix.env() == :test do
    defp repo, do: Application.get_env(:nebu_http, :account_matrix_repo, Nebu.Repo)
  else
    defp repo, do: Nebu.Repo
  end

  # ── identity (A7) ───────────────────────────────────────────────────────────

  @doc "See `Nebu.Matrix.account_identity/1`."
  @spec identity(map()) ::
          {:ok, %{user_id: String.t(), auth_time: integer() | nil}}
          | {:error, :unknown_user | :deactivated | :unavailable}
  def identity(claims) when is_map(claims) do
    server = Application.get_env(:nebu_http, :server_name, "localhost")
    user_id = Nebu.Matrix.UserId.from_claims(claims, server)

    # story gdpr-erasure-global-data (D17): an erased user (`deletion_status IS NOT NULL`) is deactivated for every gate
    case query("SELECT (is_active AND deletion_status IS NULL) FROM users WHERE user_id = $1", [user_id]) do
      {:ok, %{rows: [[true]]}} -> {:ok, %{user_id: user_id, auth_time: auth_time(claims)}}
      {:ok, %{rows: [[_inactive]]}} -> {:error, :deactivated}
      {:ok, %{rows: []}} -> {:error, :unknown_user}
      _ -> {:error, :unavailable}
    end
  rescue
    # a claim set without a usable subject cannot name a Matrix user
    _ -> {:error, :unknown_user}
  end

  # The raw `auth_time` claim ONLY (Trap 10: `iat` is not a substitute). The OAuth domain's
  # `Nebu.OAuth.Freshness.auth_time/1` is the same rule; the Matrix domain keeps its own copy (ADR-020:
  # it never calls a private module of another domain) and the OAuth side uses ITS rule on the claims.
  defp auth_time(%{"auth_time" => t}) when is_integer(t), do: t
  defp auth_time(%{"auth_time" => t}) when is_float(t), do: trunc(t)
  defp auth_time(_claims), do: nil

  # ── profile (A5, A8) ────────────────────────────────────────────────────────

  @doc "See `Nebu.Matrix.account_profile/1`."
  @spec profile(String.t()) ::
          {:ok, %{user_id: String.t(), display_name: String.t() | nil}}
          | {:error, :not_found | :deactivated | :unavailable}
  def profile(user_id) when is_binary(user_id) do
    case query(
           "SELECT (u.is_active AND u.deletion_status IS NULL), p.displayname FROM users u LEFT JOIN profiles p ON p.user_id = u.user_id WHERE u.user_id = $1",
           [user_id]
         ) do
      {:ok, %{rows: [[true, name]]}} -> {:ok, %{user_id: user_id, display_name: blank_to_nil(name)}}
      {:ok, %{rows: [[_inactive, _name]]}} -> {:error, :deactivated}
      {:ok, %{rows: []}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  defp blank_to_nil(name) when is_binary(name) and name != "", do: name
  defp blank_to_nil(_name), do: nil

  # ── devices (A12) ───────────────────────────────────────────────────────────

  @doc "See `Nebu.Matrix.account_devices/1`."
  @spec devices(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def devices(user_id) when is_binary(user_id) do
    sql = """
    SELECT device_id, display_name, last_seen_ts, last_seen_ip, created_at
      FROM devices
     WHERE user_id = $1
     ORDER BY last_seen_ts DESC NULLS LAST, device_id
     LIMIT $2
    """

    # The session columns come from the session store (the only module that reads `matrix_sessions`).
    with {:ok, %{rows: rows}} <- query(sql, [user_id, @device_limit]),
         {:ok, sessions} <- Nebu.Matrix.Session.OAuthSessionStore.device_sessions(user_id) do
      {:ok,
       Enum.map(rows, fn [device_id, display_name, last_seen_ts, last_seen_ip, created_at] ->
         session = Map.get(sessions, device_id, %{})

         %{
           device_id: device_id,
           display_name: blank_to_nil(display_name),
           last_seen_ts: last_seen_ts,
           last_seen_ip: last_seen_ip,
           created_at: created_at,
           auth_api: session[:auth_api],
           client_id: session[:client_id]
         }
       end)}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "See `Nebu.Matrix.oauth_device_holder/2`."
  @spec device_holder(String.t(), String.t()) ::
          {:ok, :none | %{display_name: String.t() | nil, last_seen_ts: integer() | nil, auth_api: String.t() | nil, client_id: String.t() | nil}}
          | {:error, :unavailable}
  def device_holder(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    sql = "SELECT display_name, last_seen_ts FROM devices WHERE user_id = $1 AND device_id = $2"

    with {:ok, %{rows: rows}} <- query(sql, [user_id, device_id]),
         {:ok, session} <- Nebu.Matrix.Session.OAuthSessionStore.device_session(user_id, device_id) do
      case {rows, session} do
        {[], nil} ->
          {:ok, :none}

        {[[name, last_seen_ts]], session} ->
          {:ok, holder(blank_to_nil(name), last_seen_ts, session)}

        # a live session row without a devices row (a half-torn-down device): still a holder
        {[], session} ->
          {:ok, holder(nil, nil, session)}
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  defp holder(display_name, last_seen_ts, session) do
    %{
      display_name: display_name,
      last_seen_ts: last_seen_ts,
      auth_api: session && session.auth_api,
      client_id: session && session.client_id
    }
  end

  # ── cross-signing reset approvals (A15, A16) ────────────────────────────────

  @doc "See `Nebu.Matrix.cross_signing_reset_requests/1`."
  @spec cross_signing_reset_requests(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def cross_signing_reset_requests(user_id) when is_binary(user_id) do
    sql = """
    SELECT session_id, params, created_at, expires_at
      FROM uia_sessions
     WHERE user_id = $1 AND op = 'cross_signing_reset'
       AND stage_complete = FALSE AND consumed = FALSE AND expires_at > $2
     ORDER BY created_at DESC, session_id
     LIMIT $3
    """

    with {:ok, %{rows: rows}} <- query(sql, [user_id, now(), @request_limit]),
         {:ok, names} <- device_names(user_id, rows) do
      {:ok,
       Enum.map(rows, fn [session_id, params, created_at, expires_at] ->
         device_id = device_id_of(params)

         %{
           session_id: session_id,
           device_id: device_id,
           device_display_name: Map.get(names, device_id),
           requested_at: created_at,
           expires_at: expires_at,
           keys_fingerprint: keys_fingerprint(params)
         }
       end)}
    else
      _ -> {:error, :unavailable}
    end
  end

  # The requesting device lives in the canonical `params` JSON of the UIA session (a row minted
  # without it, e.g. by another caller of the table, simply has no device).
  # The first 8 hex characters of the `keys_sha256` the request is bound to: lets the user tell two
  # requests of the same device apart (review cycle 1, Kassandra F-3); nil for a row without it.
  defp keys_fingerprint(params) do
    case Jason.decode(params) do
      {:ok, %{"keys_sha256" => <<fp::binary-size(8), _::binary>>}} -> fp
      _ -> nil
    end
  end

  defp device_id_of(params) do
    case Jason.decode(params) do
      {:ok, %{"device_id" => id}} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp device_names(user_id, rows) do
    ids = rows |> Enum.map(fn [_sid, params, _c, _e] -> device_id_of(params) end) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      {:ok, %{}}
    else
      case query("SELECT device_id, display_name FROM devices WHERE user_id = $1 AND device_id = ANY($2)", [user_id, ids]) do
        {:ok, %{rows: found}} -> {:ok, Map.new(found, fn [id, name] -> {id, blank_to_nil(name)} end)}
        _ -> :error
      end
    end
  end

  @doc "See `Nebu.Matrix.approve_cross_signing_reset/2`."
  @spec approve_cross_signing_reset(String.t(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def approve_cross_signing_reset(user_id, session_id) when is_binary(user_id) and is_binary(session_id) do
    now = now()

    # ONE atomic conditional UPDATE: of two parallel approvals exactly one matches. The approval is
    # valid for at most 10 minutes, never longer than the 900 s the session was minted with.
    case query(
           """
           UPDATE uia_sessions
              SET stage_complete = TRUE, expires_at = LEAST(expires_at, $3)
            WHERE session_id = $1 AND user_id = $2 AND op = 'cross_signing_reset'
              AND stage_complete = FALSE AND consumed = FALSE AND expires_at > $4
           """,
           [session_id, user_id, now + @approval_ttl_seconds, now]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  @doc "See `Nebu.Matrix.decline_cross_signing_reset/2`."
  @spec decline_cross_signing_reset(String.t(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def decline_cross_signing_reset(user_id, session_id) when is_binary(user_id) and is_binary(session_id) do
    case query(
           """
           UPDATE uia_sessions
              SET consumed = TRUE
            WHERE session_id = $1 AND user_id = $2 AND op = 'cross_signing_reset'
              AND consumed = FALSE AND expires_at > $3
           """,
           [session_id, user_id, now()]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp now, do: System.system_time(:second)

  # Never raises: an unavailable repo (the seam's NoSuchRepo, a stopped pool) is `{:error, _}`.
  defp query(sql, params) do
    Ecto.Adapters.SQL.query(repo(), sql, params)
  rescue
    e in [RuntimeError, ArgumentError, UndefinedFunctionError, DBConnection.ConnectionError, DBConnection.EncodeError] ->
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
