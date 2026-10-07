defmodule Nebu.Matrix.PageToken do
  @moduledoc """
  Shared opaque offset-pagination token scheme.

  A small opaque offset-pagination token codec shared by
  `Nebu.Matrix.SpaceHierarchy`'s `"h1:"` hierarchy cursor and
  `Nebu.Matrix.EventDispatcher.Server`'s `"mr1:"` mutual_rooms cursor: both
  callers need identical encode/decode logic, differing only in the string
  literal prefix, so this module holds that logic once and each caller
  supplies its own prefix. The prefix parameterization keeps the two cursor
  namespaces distinct — a mutual_rooms token can never be replayed as a
  hierarchy token and vice versa, since the prefix check fails closed.

  The cursor is just an integer offset, wrapped in url-safe Base64 so a client
  cannot read or forge internal state meaningfully. Format: url-safe Base64 of
  `"<prefix><offset>"`. Decoding rejects anything that is not exactly that
  shape for the given prefix — fail closed.
  """

  @doc "Encodes a non-negative offset into an opaque url-safe Base64 cursor with `prefix`."
  @spec encode(String.t(), non_neg_integer()) :: String.t()
  def encode(prefix, offset) when is_binary(prefix) and is_integer(offset) and offset >= 0 do
    Base.url_encode64(prefix <> Integer.to_string(offset), padding: false)
  end

  @doc """
  Decodes an opaque cursor back to its offset, given the expected `prefix`.

  Returns `{:ok, offset}` or `{:error, :invalid_token}` for anything that is
  not a well-formed token for THIS prefix (forged, truncated, non-numeric,
  negative, or encoded under a different prefix).
  """
  @spec decode(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_token}
  def decode(prefix, token) when is_binary(prefix) and is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         true <- String.starts_with?(decoded, prefix),
         rest = String.replace_prefix(decoded, prefix, ""),
         {offset, ""} <- Integer.parse(rest),
         true <- offset >= 0 do
      {:ok, offset}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def decode(_prefix, _token), do: {:error, :invalid_token}
end
