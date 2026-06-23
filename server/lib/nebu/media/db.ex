defmodule Nebu.Media.DB do
  @moduledoc """
  Inline-SQL `media_files` access (ADR-018: no domain model, locality of behavior).

  Mirrors the legacy Go media gateway's `MediaStore` (insert on upload, lookup on
  download) but as a direct `Ecto.Adapters.SQL.query/3` call against `Nebu.Repo` —
  no Ecto schema, changeset, or repository layer. SQL duplication with other DB
  modules (room/db.ex, search/db.ex) is a deliberate ADR-018 feature.

  The production default for the `:media_db_module` seam: tests swap it for a
  function-backed fake (`Nebu.Web.MediaFakes.DB`).

  ## Row shape returned by `lookup/2`

  An atom-keyed map mirroring the `media_files` columns plus a derived
  `:storage_key` and `:room_id`:

    * `media_files` has NO `room_id` column. Media is uploaded by a user, not a
      room; Nebu's room-membership access check (AC4) scopes a download to the
      rooms the requesting user belongs to. So `:room_id` is left `nil` here and
      the handler treats a media file as accessible to any room the user is a
      member of (see `Nebu.Media.Membership`). The injected test fake carries
      an explicit `:room_id` because the membership fake keys on it; production
      derives access from the user's own memberships instead.

  ## KNOWN LIMITATION (tracked follow-up) — per-media room scoping

  Because `media_files` carries no `room_id`, production cannot pin a media file
  to the room it was shared in. `lookup/2` therefore always returns `room_id: nil`,
  and `Membership.member?(nil, user)` degrades to "is the user a member of ANY
  room". Net effect: any authenticated user who is a member of at least one room
  can download any media id. This is FAIL-CLOSED (a user in zero rooms is denied)
  and stricter than the Matrix spec (which allows unauthenticated media), but it
  is broader than ideal per-media scoping. Tightening this to a true per-media
  room link requires a schema change (add `media_files.room_id` or a join table)
  and is a tracked follow-up flagged to security-review as a known, accepted gap.
  """

  @sql_lookup """
  SELECT media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted
  FROM media_files
  WHERE server_name = $1 AND media_id = $2 AND deleted = false
  LIMIT 1
  """

  @sql_insert """
  INSERT INTO media_files
    (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
     uploader_user_id, uploaded_at, deleted)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, false)
  """

  @doc """
  Looks up a `media_files` row by `(server_name, media_id)`.

  Returns `{:ok, row_map}` (atom keys) or `{:error, :not_found}`. A DB error also
  maps to `{:error, :not_found}` fail-closed so an unreachable store yields a
  404, never a bytes leak.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(server_name, media_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lookup, [server_name, media_id]) do
      {:ok, %{rows: [row]}} ->
        {:ok, to_map(row)}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Inserts a `media_files` row on upload. Returns `:ok` or `{:error, reason}`.
  """
  @spec insert(map()) :: :ok | {:error, term()}
  def insert(%{} = row) do
    params = [
      row.media_id,
      row.server_name,
      row.content_type,
      row.file_size,
      row.aes_key_hex,
      row.nonce_hex,
      row.uploader_user_id,
      row.uploaded_at
    ]

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_insert, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_map([media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex, uploader, uploaded_at, deleted]) do
    %{
      media_id: media_id,
      server_name: server_name,
      content_type: content_type,
      file_size: file_size,
      aes_key_hex: aes_key_hex,
      nonce_hex: nonce_hex,
      uploader_user_id: uploader,
      uploaded_at: uploaded_at,
      deleted: deleted,
      # media_files has no room_id; storage_key mirrors media_id (the legacy Go
      # gateway keyed objects under "<server>/<mediaId>", but the Elixir handler
      # uses the row's storage_key so tests can pin it — production stores under
      # the media_id directly, see Nebu.Media.Storage).
      room_id: nil,
      storage_key: media_id
    }
  end
end
