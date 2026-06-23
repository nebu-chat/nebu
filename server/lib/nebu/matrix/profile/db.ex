defmodule Nebu.Matrix.Profile.DB do
  @moduledoc "PostgreSQL persistence for user profiles."

  @sql_upsert """
  INSERT INTO profiles (user_id, displayname, avatar_url, updated_at)
  VALUES ($1, $2, $3, $4)
  ON CONFLICT (user_id)
  DO UPDATE SET
    displayname = COALESCE(EXCLUDED.displayname, profiles.displayname),
    avatar_url  = COALESCE(EXCLUDED.avatar_url, profiles.avatar_url),
    updated_at  = EXCLUDED.updated_at
  """

  @doc """
  Upserts a profile row for the given user.

  Pass `nil` for a field to leave the existing value unchanged (COALESCE logic ensures
  nil values do not overwrite existing data — only non-nil values are written).

  Returns `:ok` on success or `{:error, reason}` on DB failure.
  """
  @spec upsert_profile(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def upsert_profile(user_id, displayname, avatar_url) do
    now_ms = System.system_time(:millisecond)

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_upsert, [user_id, displayname, avatar_url, now_ms]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_get_profile """
  SELECT displayname, avatar_url FROM profiles WHERE user_id = $1
  """

  @doc """
  Reads the public-facing profile (displayname, avatar_url) for `user_id`.

  Mirrors the Go gateway's `SELECT displayname, avatar_url FROM profiles WHERE user_id = $1`
  (gateway/internal/db/profile_store.go). NULL columns are normalised to `nil`.

  Returns:
    * `{:ok, %{displayname: String.t() | nil, avatar_url: String.t() | nil}}` when a row exists
    * `{:error, :not_found}` when no profile row exists for `user_id`
    * `{:error, reason}` on DB failure
  """
  @spec get_profile(String.t()) ::
          {:ok, %{displayname: String.t() | nil, avatar_url: String.t() | nil}}
          | {:error, :not_found}
          | {:error, term()}
  def get_profile(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_get_profile, [user_id]) do
      {:ok, %{rows: [[displayname, avatar_url] | _]}} ->
        {:ok, %{displayname: displayname, avatar_url: avatar_url}}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
