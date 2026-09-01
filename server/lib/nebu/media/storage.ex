defmodule Nebu.Media.Storage do
  @moduledoc """
  S3/MinIO object storage via `ExAws.S3`. Production default for the
  `:media_storage_module` seam; tests swap it for `Nebu.Web.MediaFakes.Storage`.

  Objects are stored encrypted-at-rest (AES-256-GCM, ADR-011); `get/1`/`put/2`
  move opaque bytes as-is, while `compress/1` gzips plaintext before encryption
  (store-smaller-of-two, ADR-029). The bucket is read from `:nebu_http, :media_bucket`
  (NEBU_MINIO_BUCKET), the ExAws connection config (host/scheme/port/keys/region)
  is set in `config/runtime.exs` from the NEBU_MINIO_* env vars.

  GCM requires the whole blob to authenticate, so download decrypts in memory —
  `get/1` returns the full object body rather than a stream.
  """

  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(key) do
    bucket()
    |> ExAws.S3.get_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, bytes) when is_binary(bytes) do
    bucket()
    |> ExAws.S3.put_object(key, bytes)
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # media-security-admin-control/8a-media-cleanup-worker (AC6): permanently
  # removes the S3/MinIO object for a hard-deleted media_files row, called by
  # Nebu.Workers.MediaCleanupWorker after Nebu.Media.StateMachine.transition/4
  # has already moved the row to :hard_deleted (ADR-032 step 2, between the
  # state transition and nulling storage_key/uploader_user_id). A 404 means
  # the object is already gone -- re-issuing a delete against a non-existent
  # S3 key is a safe no-op per ADR-032, so it is treated as :ok rather than an
  # error the caller must handle specially.
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    bucket()
    |> ExAws.S3.delete_object(key)
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # media-security-admin-control/8c-media-archive-worker (AC5/AC6/AC11):
  # bucket-to-bucket server-side copy of an already-encrypted object into a
  # second, admin-configured "archive" bucket, under the SAME object key
  # (ADR-029: storage_key is immutable, never recomputed) — no bytes are ever
  # pulled into this process, decrypted, or re-uploaded. `dest_bucket` is the
  # caller's already-resolved `archive_bucket/0` value (Nebu.Workers.
  # MediaArchiveWorker's own `archive_bucket/0` helper calls this), not
  # re-resolved here, matching the acceptance tests' own "called with the
  # row's storage_key and the configured archive bucket" phrasing.
  @spec put_object_copy(String.t(), String.t()) :: :ok | {:error, term()}
  def put_object_copy(key, dest_bucket) do
    dest_bucket
    |> ExAws.S3.put_object_copy(key, bucket(), key)
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # media-security-admin-control/8c-media-archive-worker (AC11): the
  # download-path counterpart of get/1 above, read by
  # Nebu.Media.fetch_and_decrypt/3 only when row.archived_at is truthy.
  # Resolves archive_bucket/0 internally (unlike put_object_copy/2, whose
  # caller already has the bucket name at hand from the worker's own
  # archive_bucket/0 helper) since the download path has no other reason to
  # read the archive bucket name itself.
  @spec get_from_archive(String.t()) :: {:ok, binary()} | {:error, term()}
  def get_from_archive(key) do
    archive_bucket()
    |> ExAws.S3.get_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # media-security-admin-control/8c-media-archive-worker (AC1, Dependencies —
  # Story 11b): the archive-bucket name. Story 11b (Object Storage Target
  # Config) has not landed a DB-backed source for this on this branch yet —
  # this falls back to a static env/config.exs value as a placeholder (TODO:
  # rewire to whatever 11b's eventual admin-configurable source is, mirroring
  # the same not-yet-rewired posture Story 8a/8b's own config.exs values
  # already document for Story 9a's Nebu.Media.Config).
  @spec archive_bucket() :: String.t()
  def archive_bucket, do: Application.get_env(:nebu_http, :media_archive_bucket, "nebu-media-archive")

  @doc """
  Gzips `original` and returns whichever of {gzipped, original} is smaller,
  per ADR-029 (compression before encryption, store-smaller-of-two).
  Returns `{bytes_to_store, compressed?}`.
  """
  @spec compress(binary()) :: {binary(), boolean()}
  def compress(original) when is_binary(original) do
    gzipped = :zlib.gzip(original)

    if byte_size(gzipped) < byte_size(original) do
      {gzipped, true}
    else
      {original, false}
    end
  end

  defp bucket, do: Application.get_env(:nebu_http, :media_bucket, "nebu-media")
end
