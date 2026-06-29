defmodule Nebu.Matrix.DeviceId do
  @moduledoc """
  Ingress validation for Matrix device IDs (story s3-matrix-device-endpoints, F-2).

  A device_id is opaque, but it is persisted, echoed back, and used in URL path
  segments, so the ingress boundary must reject pathological values before they
  reach the store:

    * length: at most 255 bytes (a generous cap — real device_ids are UUID-shaped).
    * no control characters: bytes `\\x00`–`\\x1f` and `\\x7f` (NUL, newline, DEL, …)
      are rejected so a device_id can never inject log/header/path artifacts.

  Applied at the two ingress points that accept a client-supplied device_id:
  `POST /login` (`device_id`) and `POST /keys/upload` (`device_keys.device_id`).
  """

  @max_bytes 255
  # \x00-\x1f (C0 controls incl. NUL/TAB/LF/CR) and \x7f (DEL).
  @control_chars ~r/[\x00-\x1f\x7f]/

  @doc """
  True when `id` is a non-empty, ≤255-byte, control-char-free binary. A non-binary
  or empty id is invalid.
  """
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id) and id != "" do
    byte_size(id) <= @max_bytes and not String.match?(id, @control_chars)
  end

  def valid?(_), do: false
end
