defmodule Nebu.Matrix.Session.PgStore do
  @moduledoc """
  Behaviour and delegation module for PostgreSQL since-token persistence.

  Handles:
  - Persisting since-tokens for incremental /sync checkpointing
  - Retrieving since-tokens for /sync resume after gateway restarts
  - Session invalidation (deletes from sync_tokens + sessions in a single
    PostgreSQL transaction, then evicts from ETS)

  Real implementation: `Nebu.Matrix.Session.PgStore.Postgres` (uses Nebu.Repo).
  Test implementation: configured via Application.put_env in test setup.

  ## Atomicity rule

  `invalidate_session/1` MUST evict from ETS *only after* the PostgreSQL
  transaction commits. If the DB transaction fails, the ETS entry must NOT
  be deleted — ETS is the hot-path view of what is currently active;
  PostgreSQL is the authoritative store (ADR-002).
  """

  @callback persist_since_token(
              user_id :: String.t(),
              since_token :: String.t(),
              last_event_id :: String.t() | nil
            ) :: :ok | {:error, term()}

  @callback persist_since_token(
              user_id :: String.t(),
              device_id :: String.t(),
              since_token :: String.t(),
              last_event_id :: String.t() | nil
            ) :: :ok | {:error, term()}

  # Story sync-stream-position (D6 / D8): the real store also answers `stream_version`, `generation` and `prev_since_token`; the
  # dispatcher reads a row without them as a row of the timestamp era (an initial-sync fallback).
  @type token_row :: %{
          required(:since_token) => String.t(),
          required(:last_event_id) => String.t() | nil,
          optional(:stream_version) => non_neg_integer(),
          optional(:generation) => non_neg_integer(),
          optional(:prev_since_token) => String.t() | nil
        }

  @callback get_since_token(user_id :: String.t()) :: {:ok, token_row()} | {:error, :not_found}

  @callback get_since_token(user_id :: String.t(), device_id :: String.t()) :: {:ok, token_row()} | {:error, :not_found}

  @callback invalidate_session(user_id :: String.t()) ::
              :ok | {:error, term()}

  @callback invalidate_session(user_id :: String.t(), device_id :: String.t()) ::
              :ok | {:error, term()}

  # Story sync-token-per-device (D9): the two per-device delivery positions of the device's sync_tokens row. Optional, so
  # that store implementations which do not know them (test fakes) need not implement them: the facade then answers
  # {0, 0} / :ok (deliver everything, never miss).
  @callback get_positions(user_id :: String.t(), device_id :: String.t()) ::
              {non_neg_integer(), non_neg_integer()}

  @callback advance_positions(
              user_id :: String.t(),
              device_id :: String.t(),
              since_token :: String.t(),
              account_data_pos :: non_neg_integer(),
              cross_signing_pos :: non_neg_integer()
            ) :: :ok | {:error, term()}

  @callback rewind_account_data_position(
              user_id :: String.t(),
              device_id :: String.t(),
              since_token :: String.t(),
              cross_signing_pos :: non_neg_integer()
            ) :: :ok | {:error, term()}

  # Story sync-stream-position (D8): the two positions of the generation the client's core token names (the current one, or the
  # previous one for exactly its token). Optional like `get_positions/2`.
  @callback get_positions(user_id :: String.t(), device_id :: String.t(), core_token :: String.t() | nil) ::
              {non_neg_integer(), non_neg_integer()}

  # Story sync-stream-position (D7 / D12): the ONE write of a /sync response, the token row and the device's cursor rows in one
  # transaction, a delta guarded by its base token (`:stale`: refused, nothing written). See `Postgres.persist_sync_position/3`.
  # Optional for the test fakes of the session suites; the facade answers an error without it (fail closed: no 200).
  @callback persist_sync_position(user_id :: String.t(), device_id :: String.t(), spec :: map()) :: :ok | :stale | {:error, term()}

  @optional_callbacks get_positions: 2,
                      get_positions: 3,
                      advance_positions: 5,
                      rewind_account_data_position: 4,
                      persist_sync_position: 3

  @doc """
  Upserts a since-token row in the `sync_tokens` table for `user_id`.

  `since_token` is an opaque string — never a sequential integer.
  `last_event_id` is nullable (nil until the first event is processed).

  Story sync-stream-position: `/sync` no longer calls this (its ONE write is `persist_sync_position/3`, which also writes the
  cursor rows and the token era); kept for the store contract and its tests. A row written here keeps `stream_version` as it
  was, and its token is never continued by `/sync` unless it is an `s2_` token of the row's era.

  Returns `:ok` on success, `{:error, reason}` on DB failure.
  """
  @spec persist_since_token(String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def persist_since_token(user_id, since_token, last_event_id) do
    pg_store_module().persist_since_token(user_id, since_token, last_event_id)
  end

  @doc "Per-device variant: upserts a since-token row for `(user_id, device_id)`."
  @spec persist_since_token(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def persist_since_token(user_id, device_id, since_token, last_event_id) do
    pg_store_module().persist_since_token(user_id, device_id, since_token, last_event_id)
  end

  @doc """
  Returns `{:ok, %{since_token: t, last_event_id: id, stream_version: v, generation: g, prev_since_token: p}}` for the
  device-less `''` row of `user_id`, or `{:error, :not_found}` if no row exists in `sync_tokens`. Story sync-stream-position
  (D6 / D8): `/sync` reads `stream_version` (1 = the `s2_` era), `generation` and `prev_since_token` (the previous generation's
  token, valid for one generation); `last_event_id` is informational.
  """
  @spec get_since_token(String.t()) :: {:ok, token_row()} | {:error, :not_found}
  def get_since_token(user_id) do
    pg_store_module().get_since_token(user_id)
  end

  @doc "Per-device variant: looks up by `(user_id, device_id)` composite key; the same five keys."
  @spec get_since_token(String.t(), String.t()) :: {:ok, token_row()} | {:error, :not_found}
  def get_since_token(user_id, device_id) do
    pg_store_module().get_since_token(user_id, device_id)
  end

  @doc """
  Invalidates all sessions for `user_id`:

  1. Deletes from `sync_tokens` (since-token row)
  2. Deletes from `sessions` (all device sessions)

  Both deletes run in a single PostgreSQL transaction. If the transaction
  commits, `Nebu.Matrix.Session.EtsStore.delete_session/1` is called to evict
  the in-memory cache entry.

  If the DB transaction fails, returns `{:error, reason}` and the ETS
  entry is NOT modified (atomicity guarantee).
  """
  @spec invalidate_session(String.t()) :: :ok | {:error, term()}
  def invalidate_session(user_id) do
    pg_store_module().invalidate_session(user_id)
  end

  @doc "Per-device variant: deletes the `(user_id, device_id)` row from `sync_tokens` AND the matching row from `sessions`, both in a single PostgreSQL transaction."
  @spec invalidate_session(String.t(), String.t()) :: :ok | {:error, term()}
  def invalidate_session(user_id, device_id) do
    pg_store_module().invalidate_session(user_id, device_id)
  end

  @doc """
  `{account_data_pos, cross_signing_pos}` of the `(user_id, device_id)` row: the highest global account data position
  and the highest own cross-signing position this device has been sent (story sync-token-per-device, D9). `{0, 0}`
  without a row, with a store that does not implement the optional callback, or when the read fails (the failure
  direction is "deliver again", never "miss"). Never raises.
  """
  @spec get_positions(String.t(), String.t()) :: {non_neg_integer(), non_neg_integer()}
  def get_positions(user_id, device_id) do
    mod = pg_store_module()

    if exports?(mod, :get_positions, 2),
      do: mod.get_positions(user_id, device_id),
      else: {0, 0}
  rescue
    _ -> {0, 0}
  end

  @doc """
  `get_positions/2` for the token generation the client presented (story sync-stream-position, D8): the previous generation's
  positions for exactly the row's previous token, the current ones otherwise. A store without the 3-argument read answers through
  `get_positions/2`. Same failure direction (`{0, 0}`), never raises.
  """
  @spec get_positions(String.t(), String.t(), String.t() | nil) :: {non_neg_integer(), non_neg_integer()}
  def get_positions(user_id, device_id, core_token) do
    mod = pg_store_module()

    if exports?(mod, :get_positions, 3),
      do: mod.get_positions(user_id, device_id, core_token),
      else: get_positions(user_id, device_id)
  rescue
    _ -> {0, 0}
  end

  @doc """
  The ONE write of a `/sync` response (story sync-stream-position, D7): `:ok | :stale | {:error, reason}`, see
  `Nebu.Matrix.Session.PgStore.Postgres.persist_sync_position/3`. A store without it answers `{:error, :not_supported}` (the
  sync fails closed: nothing is written, no 200 with a token that was never stored).
  """
  @spec persist_sync_position(String.t(), String.t(), map()) :: :ok | :stale | {:error, term()}
  def persist_sync_position(user_id, device_id, spec) do
    mod = pg_store_module()

    if exports?(mod, :persist_sync_position, 3),
      do: mod.persist_sync_position(user_id, device_id, spec),
      else: {:error, :not_supported}
  end

  @doc """
  Advances the two positions of the `(user_id, device_id)` row, each column ONLY to the maximum of its own source
  (`GREATEST`: a lower value never moves it back) and only while the row still holds `since_token` (the core token of
  the response that delivered up to these positions: a superseded response never advances them). Never inserts a row
  (no orphan for a deleted device). Failures are returned, never raised.
  """
  @spec advance_positions(String.t(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def advance_positions(user_id, device_id, since_token, account_data_pos, cross_signing_pos) do
    mod = pg_store_module()

    if exports?(mod, :advance_positions, 5),
      do: mod.advance_positions(user_id, device_id, since_token, account_data_pos, cross_signing_pos),
      else: :ok
  rescue
    e -> {:error, e}
  end

  @doc """
  For an INITIAL-SHAPED `/sync` answer whose global account data read FAILED (it delivered none): sets the row's
  `account_data_pos` back to 0 (a plain SET, not GREATEST: the client of an initial-shaped answer may have reset its
  state, so every row must be delivered again) and advances `cross_signing_pos` with GREATEST as usual. Same guards as
  `advance_positions/5`: only the row that still holds `since_token` (only the one response carrying that token writes,
  so lowering the column races with nobody), never an INSERT. Failures are returned, never raised.
  """
  @spec rewind_account_data_position(String.t(), String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def rewind_account_data_position(user_id, device_id, since_token, cross_signing_pos) do
    mod = pg_store_module()

    if exports?(mod, :rewind_account_data_position, 4),
      do: mod.rewind_account_data_position(user_id, device_id, since_token, cross_signing_pos),
      else: :ok
  rescue
    e -> {:error, e}
  end

  defp exports?(mod, fun, arity), do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  defp pg_store_module do
    Application.get_env(:session_manager, :pg_store_module, Nebu.Matrix.Session.PgStore.Postgres)
  end
end
