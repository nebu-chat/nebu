defmodule Nebu.OAuth.SwitchStore do
  @moduledoc """
  The write side of the OAuth switch (`server_config` keys `oauth_enabled` and `oauth_issuer_url`) for the Admin UI
  (story `admin-oauth-switch`, ADR-033 "Admin UI switch", AS1 - AS12). Private to the OAuth domain; the Admin domain reaches
  it ONLY through `Nebu.OAuth.save_switch/2` (ADR-020). The read side is `Nebu.OAuth.Config`. SQL is inline (ADR-018).

  ## One transaction (AS7)

  `save/2` upserts BOTH keys and runs the caller's audit function in ONE transaction (the carve-out pattern of the OAuth client
  decisions, `Nebu.Compliance.AuditWriter`: `Repo.transaction/1` nests): a change is unaudited only through `unaudited_ok` and an audit row never
  describes a change that did not happen. A failing (or raising) audit function rolls both upserts back:
  `{:error, {:audit, reason}}`.

  The asymmetry is the caller's choice through `unaudited_ok: true` (the Admin UI sets it exactly when the new state is OFF): after
  a failed audit the transaction is retried ONCE without the audit function, so the kill switch can never be blocked by an
  unwritable audit table. That retry logs ONE value-free ERROR and answers `{:ok, %{audited: false}}`.

  ## After the commit (AS8)

  The saving node drops its own entry of the per-node switch cache (`Nebu.OAuth.Config.invalidate_cache/0`), so it answers
  with the new state at once. Every other node picks the change up within `NEBU_OAUTH_CONFIG_CACHE_MS` (bounded staleness,
  ADR-033 HY2). A read that started before the commit can refill the cache with the old value for at most one TTL: accepted.

  ## Defence in depth

  Only the two keys with the values `"true"` / `"false"` and a text issuer are accepted (`{:error, :invalid_changes}`); an issuer
  the runtime refuses (`Nebu.OAuth.Metadata.normalize_issuer/1`; the empty string only while OFF) is `{:error, :invalid_issuer}` before the transaction:
  this API never persists "on" with an issuer that the runtime would read as "off", nor a junk issuer while off. No migration is needed: both keys are in the
  `config_update_mutable` allowlist (migrations 000040 / 000042 / 000048 / 000049).

  Test seam (test builds only, compile-guarded like `Nebu.OAuth.Config`'s seams): `:nebu_http, :oauth_switch_tx`, a 2-arity
  `fn changes, audit -> :ok | {:error, term()} end` that replaces the database transaction.
  """

  require Logger

  alias Nebu.OAuth.Config

  @keys ["oauth_enabled", "oauth_issuer_url"]
  @upsert """
  INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
  """

  @type changes :: %{required(String.t()) => String.t()}

  @doc """
  Persists the switch. Options: `:audit` (0-arity, `:ok | {:error, reason}`; required), `:unaudited_ok` (boolean, default false).
  `{:ok, %{audited: boolean}}`, `{:error, :audit_required | :invalid_changes | :invalid_issuer}`, `{:error, {:audit, reason}}` or
  `{:error, reason}` (nothing persisted).
  """
  @spec save(changes(), keyword()) :: {:ok, %{audited: boolean()}} | {:error, term()}
  def save(changes, opts) when is_map(changes) and is_list(opts) do
    audit = Keyword.get(opts, :audit)
    unaudited_ok? = Keyword.get(opts, :unaudited_ok, false) == true

    with :ok <- check_changes(changes),
         :ok <- check_audit(audit) do
      persist(changes, safe_audit(audit), unaudited_ok?)
    end
  end

  defp check_audit(fun) when is_function(fun, 0), do: :ok
  defp check_audit(_other), do: {:error, :audit_required}

  defp check_changes(%{"oauth_enabled" => enabled, "oauth_issuer_url" => issuer} = changes)
       when enabled in ["true", "false"] and is_binary(issuer) do
    cond do
      Map.keys(changes) |> Enum.sort() != @keys -> {:error, :invalid_changes}
      # a junk issuer is never stored, also while off; the empty string (no issuer) is valid only while off
      issuer == "" and enabled == "false" -> :ok
      Nebu.OAuth.Metadata.normalize_issuer(issuer) == :error -> {:error, :invalid_issuer}
      true -> :ok
    end
  end

  defp check_changes(_other), do: {:error, :invalid_changes}

  # a raise of the audit function counts as a failed audit (the transaction rolls back), never as a crash of the caller
  defp safe_audit(audit) do
    fn ->
      try do
        case audit.() do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
      rescue
        _ -> {:error, :audit_raised}
      end
    end
  end

  defp persist(changes, audit, unaudited_ok?) do
    case run_tx(changes, audit) do
      :ok ->
        Config.invalidate_cache()
        {:ok, %{audited: true}}

      {:error, {:audit, _reason}} when unaudited_ok? ->
        # value-free: neither the issuer, the actor nor the writer's reason
        Logger.error("OAuth.SwitchStore: the audit row of the OAuth switch could not be written; the change to OFF is applied without it")

        case run_tx(changes, nil) do
          :ok ->
            Config.invalidate_cache()
            {:ok, %{audited: false}}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  # the transaction: both upserts, then the audit function; any failure rolls everything back
  if Mix.env() == :test do
    defp run_tx(changes, audit) do
      case Application.get_env(:nebu_http, :oauth_switch_tx) do
        fun when is_function(fun, 2) -> fun.(changes, audit)
        _ -> run_tx_db(changes, audit)
      end
    end
  else
    defp run_tx(changes, audit), do: run_tx_db(changes, audit)
  end

  defp run_tx_db(changes, audit) do
    repo = Nebu.Repo
    now = System.system_time(:millisecond)

    result =
      repo.transaction(fn ->
        for key <- @keys do
          case Ecto.Adapters.SQL.query(repo, @upsert, [key, Map.fetch!(changes, key), now]) do
            {:ok, _} -> :ok
            {:error, reason} -> repo.rollback(reason)
          end
        end

        case audit && audit.() do
          nil -> :ok
          :ok -> :ok
          {:error, reason} -> repo.rollback({:audit, reason})
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # repo down / not started
    e in [RuntimeError, DBConnection.ConnectionError, UndefinedFunctionError] -> {:error, e}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
