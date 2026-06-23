defmodule Nebu.Media.Storage do
  @moduledoc """
  S3/MinIO object storage via `ExAws.S3`. Production default for the
  `:media_storage_module` seam; tests swap it for `Nebu.Web.MediaFakes.Storage`.

  Objects are stored encrypted-at-rest (AES-256-GCM, ADR-011); this module only
  moves opaque bytes. The bucket is read from `:nebu_http, :media_bucket`
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

  defp bucket, do: Application.get_env(:nebu_http, :media_bucket, "nebu-media")
end
