defmodule Nebu.Matrix.Uia do
  @moduledoc """
  User-Interactive-Authentication gate for sensitive device operations
  (story s3-matrix-device-endpoints, AC5 / G1 / G2).

  Nebu is OIDC-only, so the single UIA stage is `m.login.sso` (CS v1.18
  §"SSO during User-Interactive Authentication"). Option B: a recent fresh login
  (the session's `auth_time`, ≤ `NEBU_UIA_FRESH_AUTH_SECONDS`, default 900s)
  satisfies UIA directly; otherwise the caller is challenged and must complete a
  fresh SSO login out-of-band via the auth fallback before re-submitting.

  ## Cluster correctness (ADR-020)

  A UIA `session` is minted on the node that handled the first (challenged) request,
  its `m.login.sso` stage is completed by the browser SSO callback that may land on
  ANOTHER node, and the re-submit may hit a THIRD node. A node-local ETS store would
  break that flow across nodes. So the UIA session lives in the DB-backed
  `uia_sessions` table (inline parameterised SQL, ADR-018) — every node reads the
  same authoritative row, and "single-use" is enforced by a conditional UPDATE
  (`consumed = TRUE WHERE consumed = FALSE`) that is atomic in PostgreSQL.

  ## The `cross_signing_reset` op is NOT an `m.login.sso` op (story oauth-account-management, A15)

  The `m.oauth` UIA stage of `POST /keys/device_signing/upload` (OAuth callers replacing their
  cross-signing keys) reuses this table with `op = "cross_signing_reset"`; `stage_complete = TRUE`
  means "approved on the account page" (`Nebu.Matrix.approve_cross_signing_reset/2`). Such a row
  must never be completed by the legacy `m.login.sso` fallback (an IdP login there would approve a
  reset): `complete/2` and `load/1` exclude the op, and conversely the approval functions touch ONLY
  that op. `find_pending/3` / `mint_session_checked/3` / `consume/4` (run inside the caller's
  transaction together with the key write) serve the challenge of the device-signing endpoint.

  ## Security invariants (G2)

    * The `session` is server-issued (256-bit random) and bound to
      `(user_id, op, params)`. A foreign user, a different op, or different params
      never matches → re-challenge / reject.
    * Single-use: the first successful `consume/4` flips `consumed = TRUE`; a replay
      (same or different op) then finds `consumed` and is rejected.
    * The fresh auth it grants does not widen beyond the window: completion refreshes
      `auth_time` for the user, and the gate still compares `now - auth_time`.
  """

  alias Nebu.Matrix.Session.MatrixSessionStore

  @default_window_seconds 900
  @session_ttl_seconds 900

  @doc "The configurable fresh-auth window in seconds (NEBU_UIA_FRESH_AUTH_SECONDS, default 900)."
  @spec window_seconds() :: non_neg_integer()
  def window_seconds do
    Application.get_env(:nebu_http, :uia_fresh_auth_seconds, @default_window_seconds)
  end

  @doc """
  True when `auth_time` (unix seconds, or nil) is within the fresh-auth window.
  A nil/absent auth_time is never fresh (always challenge). The comparison is
  STRICT so a zero window (test seam `uia_fresh_auth_seconds: 0`) makes every
  session immediately stale — `now - auth_time` (≥ 0) is never `< 0`.
  """
  @spec fresh?(integer() | nil) :: boolean()
  def fresh?(auth_time) when is_integer(auth_time) do
    System.system_time(:second) - auth_time < window_seconds()
  end

  def fresh?(_), do: false

  @doc """
  Canonicalises an operation's params into a stable string so the same logical op
  binds to the same UIA session regardless of map key ordering. A device op binds to
  the sorted list of target device_ids.
  """
  @spec canonical_params(term()) :: String.t()
  def canonical_params(device_ids) when is_list(device_ids) do
    device_ids |> Enum.filter(&is_binary/1) |> Enum.sort() |> Jason.encode!()
  end

  def canonical_params(other), do: Jason.encode!(other)

  @doc """
  Mints a new UIA session bound to `(user_id, op, params)` and returns its id.
  Best-effort persistence; the id is always returned so the caller can challenge.
  """
  @spec mint_session(String.t(), String.t(), String.t()) :: String.t()
  def mint_session(user_id, op, params)
      when is_binary(user_id) and is_binary(op) and is_binary(params) do
    session_id = random_id()
    now = System.system_time(:second)

    _ =
      safe_query(
        """
        INSERT INTO uia_sessions
          (session_id, user_id, op, params, stage_complete, consumed, created_at, expires_at)
        VALUES ($1, $2, $3, $4, FALSE, FALSE, $5, $6)
        """,
        [session_id, user_id, op, params, now, now + @session_ttl_seconds]
      )

    session_id
  end

  @doc """
  Like `mint_session/3`, but CHECKED: `{:ok, session_id}` only when the row was really inserted,
  `:error` otherwise (story oauth-account-management, A14: never a challenge for a session that does
  not exist).
  """
  @spec mint_session_checked(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def mint_session_checked(user_id, op, params)
      when is_binary(user_id) and is_binary(op) and is_binary(params) do
    session_id = random_id()
    now = System.system_time(:second)

    case safe_query(
           """
           INSERT INTO uia_sessions
             (session_id, user_id, op, params, stage_complete, consumed, created_at, expires_at)
           VALUES ($1, $2, $3, $4, FALSE, FALSE, $5, $6)
           """,
           [session_id, user_id, op, params, now, now + @session_ttl_seconds]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, session_id}
      _ -> :error
    end
  end

  @doc """
  The caller's still PENDING session for `(user_id, op, params)` — not approved, not consumed, not
  expired (newest first): `{:ok, session_id}`, `:none`, or `:error` when the store cannot be read.
  Used to make the `m.oauth` challenge idempotent (a retry before approval gets the SAME session).
  An approved-but-unconsumed session is never returned here.
  """
  @spec find_pending(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :none | :error
  def find_pending(user_id, op, params) when is_binary(user_id) and is_binary(op) and is_binary(params) do
    case safe_query(
           """
           SELECT session_id FROM uia_sessions
            WHERE user_id = $1 AND op = $2 AND params = $3
              AND stage_complete = FALSE AND consumed = FALSE AND expires_at > $4
            ORDER BY created_at DESC, session_id
            LIMIT 1
           """,
           [user_id, op, params, System.system_time(:second)]
         ) do
      {:ok, %{rows: [[session_id]]}} -> {:ok, session_id}
      {:ok, %{rows: []}} -> :none
      _ -> :error
    end
  end

  @reset_op "cross_signing_reset"
  # At most this many PENDING reset requests per user (review cycle 1, Kassandra F-3).
  @pending_reset_cap 5

  @doc """
  The canonical `params` of a `cross_signing_reset` session: the requesting `device_id` first, then the
  `keys_sha256` of ALL supplied keys (the approval binds both, A14). Stable: a two-key map encodes in key
  order, so `open_reset_request/3` can find the device of a row by the prefix.
  """
  @spec reset_params(String.t(), String.t()) :: String.t()
  def reset_params(device_id, keys_sha256) when is_binary(device_id) and is_binary(keys_sha256),
    do: canonical_params(%{"device_id" => device_id, "keys_sha256" => keys_sha256})

  @doc """
  The session of the `m.oauth` challenge for `(user_id, device_id, params)` (`params` from
  `reset_params/2`): `{:ok, session_id}` or `:error` (nothing was written). Review cycle 1 (Kassandra F-3,
  code review m3/m4), ONE transaction serialized per `(user, device)` by `pg_advisory_xact_lock`:

    * the same user's still PENDING session for the same `params` is reused (idempotent challenges: Element
      asks twice and retries without polling);
    * otherwise the device's OTHER pending requests are consumed (at most ONE pending request per
      `(user, device)`, so requests of one device can never be told apart or piled up), the user's pending
      requests are trimmed to #{@pending_reset_cap - 1} (the newest stay) and a new session is minted
      with a CHECKED insert.

  An approved-but-unconsumed session is never touched or re-issued.
  """
  @spec open_reset_request(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def open_reset_request(user_id, device_id, params)
      when is_binary(user_id) and is_binary(device_id) and is_binary(params) do
    result =
      if Process.whereis(Nebu.Repo) do
        Nebu.Repo.transaction(fn ->
          with {:ok, _} <- safe_query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [user_id <> "|" <> device_id]),
               {:ok, session_id} <- reuse_or_mint(user_id, device_id, params) do
            session_id
          else
            _ -> Nebu.Repo.rollback(:reset_request_failed)
          end
        end)
      else
        {:error, :repo_not_started}
      end

    case result do
      {:ok, session_id} -> {:ok, session_id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp reuse_or_mint(user_id, device_id, params) do
    case find_pending(user_id, @reset_op, params) do
      {:ok, session_id} ->
        {:ok, session_id}

      :none ->
        now = System.system_time(:second)
        device_prefix = ~s({"device_id":#{Jason.encode!(device_id)},)

        with {:ok, _} <-
               safe_query(
                 """
                 UPDATE uia_sessions SET consumed = TRUE
                  WHERE user_id = $1 AND op = $2 AND consumed = FALSE AND stage_complete = FALSE
                    AND expires_at > $3 AND starts_with(params, $4)
                 """,
                 [user_id, @reset_op, now, device_prefix]
               ),
             {:ok, _} <-
               safe_query(
                 """
                 UPDATE uia_sessions SET consumed = TRUE
                  WHERE session_id IN (
                    SELECT session_id FROM uia_sessions
                     WHERE user_id = $1 AND op = $2 AND consumed = FALSE AND stage_complete = FALSE AND expires_at > $3
                     ORDER BY created_at DESC, session_id
                     OFFSET $4)
                 """,
                 [user_id, @reset_op, now, @pending_reset_cap - 1]
               ) do
          mint_session_checked(user_id, @reset_op, params)
        else
          _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  The spec UIA challenge body for the `m.login.sso` stage:
  `%{"flows" => [%{"stages" => ["m.login.sso"]}], "session" => id, "params" => %{}}`.
  """
  @spec challenge_body(String.t()) :: map()
  def challenge_body(session_id) do
    %{"flows" => [%{"stages" => ["m.login.sso"]}], "session" => session_id, "params" => %{}}
  end

  @doc """
  Single-use redemption of a UIA session for `(user_id, op, params)`.

  Returns `:ok` only when the session exists, belongs to THIS user, is for THIS
  op+params, is not expired, has its `m.login.sso` stage complete, and is not yet
  consumed — and the consume itself wins the atomic `consumed = TRUE WHERE
  consumed = FALSE` race. Any other case → `:error` (the caller re-challenges 401).
  """
  @spec consume(String.t(), String.t(), String.t(), String.t()) :: :ok | :error
  def consume(session_id, user_id, op, params)
      when is_binary(session_id) and is_binary(user_id) and is_binary(op) and is_binary(params) do
    now = System.system_time(:second)

    case safe_query(
           """
           UPDATE uia_sessions
              SET consumed = TRUE
            WHERE session_id = $1
              AND user_id = $2
              AND op = $3
              AND params = $4
              AND stage_complete = TRUE
              AND consumed = FALSE
              AND expires_at > $5
           """,
           [session_id, user_id, op, params, now]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> :error
    end
  end

  @doc """
  Loads a UIA session for the SSO auth-fallback start. Returns the bound `user_id`
  (so the fallback can drive a fresh SSO login) or `:error` if unknown/expired.
  """
  @spec load(String.t()) :: {:ok, %{user_id: String.t()}} | :error
  def load(session_id) when is_binary(session_id) do
    now = System.system_time(:second)

    # A15: a `cross_signing_reset` session (the `m.oauth` approval record) is never offered to the
    # legacy SSO fallback: an IdP login there must not be able to approve a reset.
    case safe_query(
           "SELECT user_id FROM uia_sessions WHERE session_id = $1 AND expires_at > $2 AND op <> 'cross_signing_reset'",
           [session_id, now]
         ) do
      {:ok, %{rows: [[user_id]]}} -> {:ok, %{user_id: user_id}}
      _ -> :error
    end
  end

  @doc """
  Completes the `m.login.sso` stage for the given UIA `session_id` (called from the
  validated OIDC callback, which knows the session via the SSO state it tagged).

  SECURITY (H-1): the stage is completed ONLY when the freshly-authenticated identity
  (`authenticated_user`, the Matrix user_id derived from the verified id_token's
  claims) equals the UIA session's bound `user_id`. This is enforced in SQL by an
  `AND user_id = $authenticated_user` clause: a mismatched fresh login (any other IdP
  account completing a victim's pending fallback) matches 0 rows, flips nothing, and
  returns `:error`. Without this binding, a holder of a victim's open access token
  could complete the fallback with their OWN IdP account and satisfy the step-up for
  the victim's pending sensitive op (the exact threat the gate defends against).

  On a match: marks `stage_complete = TRUE` and refreshes the user's opaque-session
  `auth_time` so the subsequent re-submit is within the fresh-auth window (Option B).
  Returns `{:ok, user_id}`; on no match (unknown/expired/consumed session, OR an
  identity mismatch) returns `:error` — the caller renders no completion, never marks
  the stage complete, and never refreshes auth_time.
  """
  @spec complete(String.t(), String.t()) :: {:ok, String.t()} | :error
  def complete(session_id, authenticated_user)
      when is_binary(session_id) and session_id != "" and
             is_binary(authenticated_user) and authenticated_user != "" do
    now = System.system_time(:second)

    case safe_query(
           """
           UPDATE uia_sessions
              SET stage_complete = TRUE
            WHERE session_id = $1
              AND user_id = $2
              AND op <> 'cross_signing_reset'
              AND consumed = FALSE
              AND expires_at > $3
           RETURNING user_id
           """,
           [session_id, authenticated_user, now]
         ) do
      {:ok, %{rows: [[user_id]]}} ->
        # Refresh the user's fresh-auth time so the re-submit on the same opaque
        # token satisfies the window (Option B).
        _ = MatrixSessionStore.refresh_auth_time(user_id, now)
        {:ok, user_id}

      _ ->
        :error
    end
  end

  def complete(_, _), do: :error

  @doc "Deletes expired UIA sessions. Returns the count. Best-effort sweeper helper."
  @spec cleanup_expired() :: non_neg_integer()
  def cleanup_expired do
    case safe_query("DELETE FROM uia_sessions WHERE expires_at < $1", [System.system_time(:second)]) do
      {:ok, %{num_rows: n}} -> n
      _ -> 0
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp random_id, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp safe_query(sql, params) do
    if Process.whereis(Nebu.Repo) do
      Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  end
end
