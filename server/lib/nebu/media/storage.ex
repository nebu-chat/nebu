defmodule Nebu.Media.Storage do
  @moduledoc """
  S3/MinIO object storage via `ExAws.S3`. Production default for the
  `:media_storage_module` seam; tests swap it for `Nebu.Web.MediaFakes.Storage`.

  Objects are stored encrypted-at-rest (AES-256-GCM, ADR-011); `get/1`/`put/2`
  move opaque bytes as-is, while `compress/1` gzips plaintext before encryption
  (store-smaller-of-two, ADR-029).

  Every call addresses the object store resolved at that moment by
  `Nebu.Media.StorageConfig.request_target/0` (saved admin target > `NEBU_MINIO_*`
  env > default): endpoint, region, credentials, bucket and archive bucket are
  handed to ExAws as per-request overrides, so a target saved under
  /admin/media/settings is used without a restart. The boot-time `:ex_aws` config
  from `config/runtime.exs` is not consulted for them. A target that cannot be
  used (blank or invalid endpoint, missing / unreadable credentials, saved settings
  that cannot be read) fails the call with an error atom of
  `StorageConfig.request_target/0` before any request is sent. A saved endpoint is
  only ever used with the credentials saved with it (or, for the environment's own
  endpoint, with the environment's). Errors are a closed set that carries no text of
  the storage server: an atom, or `{:error, {:http_error, status}}`.

  GCM requires the whole blob to authenticate, so download decrypts in memory —
  `get/1` returns the full object body rather than a stream.
  """

  alias Nebu.Media.StorageConfig

  require Logger

  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(key) do
    request(&ExAws.S3.get_object(&1.bucket, key))
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, bytes) when is_binary(bytes) do
    request(&ExAws.S3.put_object(&1.bucket, key, bytes))
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
    request(&ExAws.S3.delete_object(&1.bucket, key))
    |> case do
      {:ok, _} -> :ok
      {:error, {:http_error, 404}} -> :ok
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
  # row's storage_key and the configured archive bucket" phrasing. The copy
  # source is the effective primary bucket.
  @spec put_object_copy(String.t(), String.t()) :: :ok | {:error, term()}
  def put_object_copy(key, dest_bucket) do
    request(&ExAws.S3.put_object_copy(dest_bucket, key, &1.bucket, key))
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # media-security-admin-control/8c-media-archive-worker (AC11): the
  # download-path counterpart of get/1 above, read by
  # Nebu.Media.fetch_and_decrypt/3 only when row.archived_at is truthy.
  # Reads from the effective archive bucket (unlike put_object_copy/2, whose
  # caller already has the bucket name at hand from the worker's own
  # archive_bucket/0 helper) since the download path has no other reason to
  # read the archive bucket name itself.
  @spec get_from_archive(String.t()) :: {:ok, binary()} | {:error, term()}
  def get_from_archive(key) do
    request(&ExAws.S3.get_object(&1.archive_bucket, key))
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The effective archive-bucket name: saved under /admin/media/settings, else
  # NEBU_MINIO_ARCHIVE_BUCKET, else "nebu-media-archive" (see
  # StorageConfig.archive_bucket/0). Usable even when the endpoint is not.
  @spec archive_bucket() :: String.t()
  def archive_bucket, do: StorageConfig.archive_bucket()

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

  # Resolves the target now and sends `build.(target)` to it with the target's connection overrides. A target that
  # cannot be used (see `StorageConfig.request_target/0`) never reaches ExAws, so it never falls back to the boot-time
  # config. The target (it carries the credentials) is never logged or returned; one warning names the problem.
  defp request(build) do
    case StorageConfig.request_target() do
      {:ok, target} ->
        target |> build.() |> ExAws.request(target.overrides) |> closed_error()

      {:error, reason} ->
        Logger.warning("Nebu.Media.Storage: request not sent, #{problem(reason)}")
        {:error, reason}
    end
  end

  # The errors that leave this module are a closed set: an atom, or `{:http_error, status}`. What the storage server
  # sent is dropped: the signature error XML names the access key id and the string that was signed, and other ExAws
  # error shapes (`{type, message}` from a JSON body) carry server-controlled text. Callers log and audit the reason.
  defp closed_error({:error, {:http_error, status, _body}}) when is_integer(status), do: {:error, {:http_error, status}}
  defp closed_error({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp closed_error({:error, _other}), do: {:error, :storage_error}
  defp closed_error(result), do: result

  defp problem(:storage_endpoint_blank), do: "the storage endpoint (admin media settings / NEBU_MINIO_ENDPOINT) is blank"
  defp problem(:storage_endpoint_invalid), do: "the storage endpoint (admin media settings / NEBU_MINIO_ENDPOINT) is invalid"
  defp problem(:storage_credentials_missing), do: "the storage credentials saved for the endpoint are missing or cannot be decrypted"
  defp problem(:storage_credentials_unreadable), do: "the storage credentials cannot be read (NEBU_MINIO_*_FILE or the at-rest key)"
  defp problem(:storage_config_unavailable), do: "the saved storage settings cannot be read"
end
