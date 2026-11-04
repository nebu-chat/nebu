defmodule Nebu.OAuth.ConsentGrantStore do
  @moduledoc """
  Remembered consent: what a user last allowed for an OAuth client (`oauth_consent_grants`, migration 000057) - epic
  oauth-session-and-consent, story persistent-consent-grants (REQ-2026-003).

  ADR-018: inline SQL. ADR-020 (cluster safety): the table is the only state, any node reads and writes it.

    * `skip_consent?/4` - ONE statement: the grant joined with the client row. True only for an `approved` client, the binding equal to the client's
      CURRENT `approved_at`, an equal redirect URI and a covered scope (`covers?/2`). A revocation that has committed can never be missed by a
      second statement.
    * `upsert/1` - an Allow: replaces scope and redirect URI with what the user just allowed (`ON CONFLICT (user_id, client_id)`), only for an
      approved client; the binding is read from the client row inside the statement.
    * `list_for_user/1`, `withdraw/2` - the account page.

  The scope is stored normalised (`normalize_scope/1`): sorted unique tokens WITHOUT the `<prefix>device:<id>` token (a new device id per login must
  not defeat the skip; the device is bound as before). Test seam: `:nebu_http, :oauth_repo` (like `Nebu.OAuth.ClientStore`).
  """

  require Logger

  @device_token ~r/\A(urn:matrix:client:|urn:matrix:org\.matrix\.msc2967\.client:)device:/

  @sql_skip """
  SELECT g.scope
  FROM oauth_consent_grants g
  JOIN oauth_clients c ON c.client_id = g.client_id
  WHERE g.user_id = $1 AND g.client_id = $2 AND g.redirect_uri = $3
    AND c.status = 'approved' AND c.approved_at = g.client_approved_at
  """

  @sql_upsert """
  INSERT INTO oauth_consent_grants (user_id, client_id, scope, redirect_uri, client_approved_at)
  SELECT $1::text, c.client_id, $3::text, $4::text, c.approved_at
  FROM oauth_clients c
  WHERE c.client_id = $2::text AND c.status = 'approved'
  ON CONFLICT (user_id, client_id) DO UPDATE
    SET scope = EXCLUDED.scope, redirect_uri = EXCLUDED.redirect_uri,
        client_approved_at = EXCLUDED.client_approved_at, granted_at = now()
  """

  @sql_list """
  SELECT g.client_id, c.metadata, g.scope, g.redirect_uri, g.granted_at, c.client_host
  FROM oauth_consent_grants g
  JOIN oauth_clients c ON c.client_id = g.client_id
  WHERE g.user_id = $1 AND c.status = 'approved' AND c.approved_at = g.client_approved_at
  ORDER BY g.granted_at DESC, g.client_id
  LIMIT 500
  """

  @sql_withdraw "DELETE FROM oauth_consent_grants WHERE user_id = $1 AND client_id = $2"

  @doc "The scope as sorted, unique, space-joined tokens without the device token."
  @spec normalize_scope(String.t() | nil) :: String.t()
  def normalize_scope(scope) when is_binary(scope), do: scope |> tokens() |> Enum.join(" ")
  def normalize_scope(_scope), do: ""

  @doc "Every normalised token of `requested` is in `granted`; an empty request is never covered."
  @spec covers?(String.t() | nil, String.t() | nil) :: boolean()
  def covers?(granted, requested) do
    wanted = tokens(requested || "")
    wanted != [] and Enum.all?(wanted, &(&1 in tokens(granted || "")))
  end

  defp tokens(scope) do
    scope |> String.split(" ", trim: true) |> Enum.reject(&Regex.match?(@device_token, &1)) |> Enum.uniq() |> Enum.sort()
  end

  @spec skip_consent?(String.t(), String.t(), String.t(), String.t()) :: {:ok, boolean()} | {:error, :storage}
  def skip_consent?(user_id, client_id, scope, redirect_uri) do
    case query(@sql_skip, [user_id, client_id, redirect_uri]) do
      {:ok, %{rows: [[granted]]}} -> {:ok, covers?(granted, scope)}
      {:ok, %{rows: []}} -> {:ok, false}
      {:error, reason} -> storage_error("read", reason)
    end
  end

  @spec upsert(map()) :: :ok | {:error, term()}
  def upsert(%{user_id: user_id, client_id: client_id, scope: scope, redirect_uri: redirect_uri}) do
    normalized = normalize_scope(scope)

    if normalized == "" or not is_binary(redirect_uri) or redirect_uri == "" do
      {:error, :nothing_to_remember}
    else
      case query(@sql_upsert, [user_id, client_id, normalized, redirect_uri]) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> {:error, :client_not_approved}
        # the caller logs (one value-free line); nothing is raised
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec list_for_user(String.t()) :: {:ok, [map()]} | {:error, :storage}
  def list_for_user(user_id) do
    case query(@sql_list, [user_id]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         for [client_id, metadata, scope, redirect_uri, granted_at, host] <- rows do
           %{client_id: client_id, client_name: name(metadata), client_host: host, scope: scope, redirect_uri: redirect_uri, granted_at: granted_at}
         end}

      {:error, reason} ->
        storage_error("list", reason)
    end
  end

  @spec withdraw(String.t(), String.t()) :: {:ok, :withdrawn | :not_found} | {:error, :storage}
  def withdraw(user_id, client_id) do
    case query(@sql_withdraw, [user_id, client_id]) do
      {:ok, %{num_rows: 0}} -> {:ok, :not_found}
      {:ok, %{num_rows: _}} -> {:ok, :withdrawn}
      {:error, reason} -> storage_error("withdraw", reason)
    end
  end

  defp name(%{"client_name" => n}) when is_binary(n) and n != "", do: n
  defp name(_metadata), do: nil

  # `client_host` is the STORED, verified host of the registration (never the app-claimed `client_uri`: Kassandra INFO #4)

  # value-free: the error TYPE only, never the row
  defp storage_error(what, reason) do
    Logger.warning("OAuth consent grants: #{what} failed: #{error_type(reason)}")
    {:error, :storage}
  end

  defp error_type(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp error_type(%{__struct__: struct}), do: inspect(struct)
  defp error_type(_other), do: "unexpected error"

  defp repo, do: Application.get_env(:nebu_http, :oauth_repo, Nebu.Repo)

  defp query(sql, params) do
    Ecto.Adapters.SQL.query(repo(), sql, params)
  rescue
    e in [RuntimeError, ArgumentError, UndefinedFunctionError, DBConnection.ConnectionError, DBConnection.EncodeError] ->
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
