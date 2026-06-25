defmodule Nebu.Matrix.AccountDataStore do
  @moduledoc """
  Volatile, node-local ETS store for per-user Matrix account data.

  Matrix CS API §PUT /user/{userId}/account_data/{type} and
  §GET /user/{userId}/account_data/{type} are backed by this module.

  ## Design choices

  * `:public` — Plug processes write directly via `:ets.insert/2` without a
    GenServer serialiser (same as `Nebu.Web.TokenDenylist`).
  * `ensure_table/0` is called defensively in `put/3` and `get/2` so tests that
    start without the Application can still exercise the store lazily.
  * No cluster replication — account_data is a node-local volatile stub per
    ADR-002 (No Redis/NATS) and ADR-011 (Managed E2EE stub). Full server-side
    decryption is tracked separately.
  * No TTL or size limit — stub data is bounded by session lifetime.
  """

  @table :NebuAccountData

  @doc """
  Eagerly creates the backing ETS table (called from `Nebu.Application.start/2`
  before Bandit starts, matching the R-2 pattern). Idempotent. Returns `:ok`.
  """
  @spec init_table() :: :ok
  def init_table, do: ensure_table()

  @doc """
  Stores `json_body` (a pre-encoded JSON string) keyed by `{user_id, type}`.

  Idempotent — a second call for the same key overwrites the previous value.
  """
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(user_id, type, json_body)
      when is_binary(user_id) and is_binary(type) and is_binary(json_body) do
    ensure_table()
    :ets.insert(@table, {{user_id, type}, json_body})
    :ok
  end

  @doc """
  Retrieves the stored JSON body for `{user_id, type}`.

  Returns `{:ok, json_body}` when found, `:error` when no entry exists.
  """
  @spec get(String.t(), String.t()) :: {:ok, String.t()} | :error
  def get(user_id, type) when is_binary(user_id) and is_binary(type) do
    ensure_table()

    case :ets.lookup(@table, {user_id, type}) do
      [{{^user_id, ^type}, body}] -> {:ok, body}
      [] -> :error
    end
  end

  # Lazily create the public, named set on first use. Two processes can race to
  # create it — the loser gets ArgumentError, which is fine (it already exists).
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end
end
