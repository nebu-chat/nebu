defmodule Nebu.OAuth.TokenRequest do
  @moduledoc """
  Pure parsing / validation helpers of `POST /oauth2/token` (story oauth-token-endpoint, T23,
  AC2 steps 2 + 5-6, AC5.4 PKCE, AC9 refresh-token format, AC11 / T13 scope narrowing). No I/O:
  the body is read once by `Nebu.OAuth.Token` and parsed with the story-2 raw parser
  `Nebu.OAuth.AuthorizeRequest.parse_query/1` (order and duplicates kept, `x[]` literal).

    * `validate_params/1` — a parameter name occurring more than once (also with identical values,
      also when one occurrence is empty) or a value with a `\\p{Cc}` character / invalid UTF-8 =>
      `{:error, :invalid_request}` (RFC 6749 3.2; PostgreSQL text cannot store NUL). Afterwards
      parameters with an EMPTY value are dropped (RFC 6749 3.1: empty = omitted). Unknown parameters
      are kept (the caller ignores them).
    * `pkce_valid?/2` — RFC 7636 4.6, S256 only: the verifier format first, then
      `BASE64URL(SHA256(verifier))` compared with `Plug.Crypto.secure_compare/2` (constant time).
    * `narrow_scope/2` — T13: set comparison with the Matrix tokens prefix-normalized (stable
      `urn:matrix:client:` == unstable `urn:matrix:org.matrix.msc2967.client:`); only `openid` can
      be dropped; the result is the STORED granted string (stored prefix + order).
  """

  @stable "urn:matrix:client:"
  @unstable "urn:matrix:org.matrix.msc2967.client:"

  @max_scope_bytes 2048

  @doc "Duplicate / control-char / UTF-8 check, then empty values dropped. `{:ok, map}` or `{:error, :invalid_request}`."
  @spec validate_params([{String.t(), String.t()}]) :: {:ok, %{String.t() => String.t()}} | {:error, :invalid_request}
  def validate_params(pairs) when is_list(pairs) do
    names = Enum.map(pairs, &elem(&1, 0))

    cond do
      length(Enum.uniq(names)) != length(names) -> {:error, :invalid_request}
      not Enum.all?(pairs, fn {k, v} -> clean?(k) and clean?(v) end) -> {:error, :invalid_request}
      true -> {:ok, pairs |> Enum.reject(fn {_k, v} -> v == "" end) |> Map.new()}
    end
  end

  def validate_params(_other), do: {:error, :invalid_request}

  defp clean?(value) when is_binary(value), do: String.valid?(value) and not Regex.match?(~r/\p{Cc}/u, value)
  defp clean?(_value), do: false

  @doc "True for `application/x-www-form-urlencoded` (case-insensitive media type, parameters such as `charset` allowed)."
  @spec valid_content_type?(String.t() | nil) :: boolean()
  def valid_content_type?(header) when is_binary(header) do
    media = header |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
    media == "application/x-www-form-urlencoded"
  end

  def valid_content_type?(_header), do: false

  @doc "RFC 7636 4.1: 43..128 characters of `[A-Za-z0-9._~-]`."
  @spec valid_verifier?(term()) :: boolean()
  def valid_verifier?(v) when is_binary(v), do: Regex.match?(~r/\A[A-Za-z0-9._~-]{43,128}\z/, v)
  def valid_verifier?(_v), do: false

  @doc "PKCE S256 (RFC 7636 4.6): format check first, then a constant-time comparison."
  @spec pkce_valid?(term(), term()) :: boolean()
  def pkce_valid?(verifier, challenge) when is_binary(challenge) do
    if valid_verifier?(verifier) do
      computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      Plug.Crypto.secure_compare(computed, challenge)
    else
      false
    end
  end

  def pkce_valid?(_verifier, _challenge), do: false

  @doc "Nebu refresh tokens are 64 LOWERCASE hex characters; anything else is refused before any DB access."
  @spec valid_refresh_token_format?(term()) :: boolean()
  def valid_refresh_token_format?(v) when is_binary(v), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, v)
  def valid_refresh_token_format?(_v), do: false

  @doc """
  T13 / AC11: `nil` or `""` => the granted scope unchanged. Otherwise every requested token (split
  on spaces, empty tokens dropped, RFC 6749 3.3 charset, at most #{@max_scope_bytes} bytes) must be
  in the granted set, and the `api:*` and `device:<id>` tokens must still be present (Nebu policy,
  story-2 D6) — so effectively only `openid` can be dropped. Matrix tokens are compared
  prefix-normalized. The result is the granted string (stored prefix and order) minus a dropped
  `openid`; anything else is `{:error, :invalid_scope}`.
  """
  @spec narrow_scope(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, :invalid_scope}
  def narrow_scope(nil, granted), do: {:ok, granted}
  def narrow_scope("", granted), do: {:ok, granted}

  def narrow_scope(requested, granted) when is_binary(requested) and is_binary(granted) do
    granted_tokens = String.split(granted, " ", trim: true)
    granted_set = MapSet.new(granted_tokens, &normalize/1)

    with true <- byte_size(requested) <= @max_scope_bytes,
         tokens = String.split(requested, " ", trim: true),
         true <- tokens != [],
         true <- Enum.all?(tokens, &valid_scope_token?/1),
         requested_set = MapSet.new(tokens, &normalize/1),
         true <- MapSet.subset?(requested_set, granted_set),
         true <- MapSet.equal?(MapSet.delete(granted_set, "openid"), MapSet.delete(requested_set, "openid")) do
      if MapSet.member?(requested_set, "openid") do
        {:ok, granted}
      else
        {:ok, granted_tokens |> Enum.reject(&(&1 == "openid")) |> Enum.join(" ")}
      end
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def narrow_scope(_requested, _granted), do: {:error, :invalid_scope}

  # RFC 6749 3.3: scope-token = 1*( %x21 / %x23-5B / %x5D-7E )
  defp valid_scope_token?(t), do: Regex.match?(~r/\A[\x21\x23-\x5B\x5D-\x7E]+\z/, t)

  defp normalize(@unstable <> rest), do: @stable <> rest
  defp normalize(token), do: token
end
