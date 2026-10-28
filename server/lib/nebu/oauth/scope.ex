defmodule Nebu.OAuth.Scope do
  @moduledoc """
  Pure parser of the `scope` parameter of `GET /oauth2/authorize` (epic oauth-broker, story
  oauth-authorize-idp-delegation-code, AC4b, decisions D6-D8 and D23). No I/O.

  Matrix scope tokens exist with two prefixes: the stable `urn:matrix:client:` and the unstable
  `urn:matrix:org.matrix.msc2967.client:` (matrix-js-sdk 41.3.0 and the Dart SDK send the
  unstable one). A request is accepted when

    * the scope is present, at most 2048 bytes, and every space-separated token is in the
      RFC 6749 3.3 charset (`%x21 / %x23-5B / %x5D-7E`; otherwise the request is malformed),
    * it carries EXACTLY ONE `<prefix>device:<id>` token (occurrences are counted, two identical
      tokens are rejected too) with a device id that passes `valid_device_id?/1` (D8),
    * it carries `<prefix>api:*` (Nebu policy D6, not a spec MUST),
    * all recognised Matrix tokens (`api:*`, `device:`) use the SAME prefix (Nebu policy D7: the
      granted scope echoes "the request's prefix").

  Unknown but well-formed tokens (`profile`, `urn:matrix:client:api:read:*`, other namespaced
  tokens) are ignored and never echoed (RFC 6749 3.3 "MAY fully or partially ignore", D7).
  `openid` is not unknown: it is kept and reported as `openid: true` (D23; story 3 must then issue
  a Nebu id_token).

  The granted scope is normalized to `"[openid ]<prefix>api:* <prefix>device:<id>"`, independent
  of the token order in the request.
  """

  @stable "urn:matrix:client:"
  @unstable "urn:matrix:org.matrix.msc2967.client:"
  @max_scope_bytes 2048
  @max_device_id_bytes 255

  @type result :: %{scope: String.t(), prefix: String.t(), device_id: String.t(), openid: boolean()}

  @doc "The two accepted Matrix scope prefixes: `[stable, unstable]`."
  @spec prefixes() :: [String.t()]
  def prefixes, do: [@stable, @unstable]

  @doc "Parses and validates a requested scope (see the moduledoc). `{:error, :invalid_scope}` on any violation."
  @spec parse(String.t() | nil) :: {:ok, result()} | {:error, :invalid_scope}
  def parse(scope) when is_binary(scope) and byte_size(scope) <= @max_scope_bytes do
    tokens = String.split(scope, " ", trim: true)

    with false <- tokens == [],
         true <- Enum.all?(tokens, &scope_token?/1),
         {apis, devices} <- classify(tokens),
         [{prefix, device_id}] <- devices,
         true <- valid_device_id?(device_id),
         true <- prefix in apis,
         true <- Enum.all?(apis, &(&1 == prefix)) do
      openid = "openid" in tokens
      granted = [if(openid, do: "openid"), prefix <> "api:*", prefix <> "device:" <> device_id]

      {:ok,
       %{
         scope: granted |> Enum.reject(&is_nil/1) |> Enum.join(" "),
         prefix: prefix,
         device_id: device_id,
         openid: openid
       }}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def parse(_scope), do: {:error, :invalid_scope}

  @doc """
  D8 device-id validator: 1..255 bytes, every byte in `%x21 / %x23-5B / %x5D-7E` (the RFC 6749
  3.3 scope-token charset). Deliberately NOT `Nebu.Matrix.DeviceId.valid?/1`, which admits `"`,
  `\\` and non-ASCII. No minimum length beyond 1 (rejecting what clients legitimately send is the
  bigger interoperability risk).
  """
  @spec valid_device_id?(term()) :: boolean()
  def valid_device_id?(id) when is_binary(id) and byte_size(id) in 1..@max_device_id_bytes, do: charset?(id)
  def valid_device_id?(_id), do: false

  # `{api_prefixes, [{prefix, device_id}]}` of the recognised Matrix tokens; everything else is
  # ignored (unknown tokens, D7).
  defp classify(tokens) do
    Enum.reduce(tokens, {[], []}, fn token, {apis, devices} = acc ->
      case matrix_token(token) do
        {prefix, "api:*"} -> {[prefix | apis], devices}
        {prefix, "device:" <> id} -> {apis, [{prefix, id} | devices]}
        _ -> acc
      end
    end)
  end

  defp matrix_token(@stable <> rest), do: {@stable, rest}
  defp matrix_token(@unstable <> rest), do: {@unstable, rest}
  defp matrix_token(_token), do: nil

  defp scope_token?(token), do: token != "" and charset?(token)

  # RFC 6749 3.3: scope-token = 1*( %x21 / %x23-5B / %x5D-7E )
  defp charset?(<<>>), do: true
  defp charset?(<<c, rest::binary>>) when c == 0x21 or c in 0x23..0x5B or c in 0x5D..0x7E, do: charset?(rest)
  defp charset?(_), do: false
end
