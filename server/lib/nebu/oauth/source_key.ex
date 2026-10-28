defmodule Nebu.OAuth.SourceKey do
  @moduledoc """
  The per-source grouping key of the OAuth abuse caps (epic oauth-broker, story
  oauth-dcr-abuse-hardening, AH3): which pending registrations / live authorization requests /
  live account-login requests "come from the same client".

  `from_ip/1` takes the resolved client address string (what `Nebu.Web.ClientIP.get/1` returns) and
  normalises it before hashing:

    * IPv4 => `"v4:a.b.c.d"` (per full address)
    * IPv6 => `"v6:"` + the first 64 bits as 16 lowercase hex characters (per /64, because one routed
      /64 gives a single client 2^64 addresses); an IPv4-mapped address is its IPv4 form
    * anything unparseable (the fail-closed fallback of the resolver) => `"raw:"` + the input
      truncated to 64 bytes

  The key is the lowercase hex SHA-256 of `"nebu-oauth-source-v1|" <> normalised`: a fixed-length
  (64 characters) grouping value. It is pseudonymous, NOT anonymous: an IPv4 address is
  enumerable. It is deliberately not keyed with the internal secret (per-purpose subkeys are a
  follow-up, gate item al); exposure is bounded because only pending registrations and in-flight
  login requests carry it (decided registrations lose it, AH7). It is never logged.

  `for_conn/1` is `from_ip(Nebu.Web.ClientIP.get(conn))`: the trusted-proxy resolution of story
  oauth-trusted-proxy-client-ip is the ONLY source of the address (this module never reads the
  socket peer or a forwarding header itself).
  """

  @prefix "nebu-oauth-source-v1|"
  @max_raw_bytes 64

  @doc "The source key of the request's resolved client address (64 lowercase hex characters)."
  @spec for_conn(Plug.Conn.t()) :: String.t()
  def for_conn(%Plug.Conn{} = conn), do: conn |> Nebu.Web.ClientIP.get() |> from_ip()

  @doc "The source key of an address string; never raises (unparseable input is keyed as `raw:`)."
  @spec from_ip(term()) :: String.t()
  def from_ip(ip) do
    :crypto.hash(:sha256, @prefix <> normalise(ip)) |> Base.encode16(case: :lower)
  end

  defp normalise(ip) when is_binary(ip) do
    case parse(ip) do
      {:ok, tuple} -> format(tuple)
      :error -> raw(ip)
    end
  end

  defp normalise(other), do: raw(inspect(other))

  defp parse(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  rescue
    # a charlist cannot be built from invalid UTF-8
    _ -> :error
  end

  defp format({a, b, c, d}), do: "v4:#{a}.#{b}.#{c}.#{d}"
  # IPv4-mapped IPv6 (::ffff:a.b.c.d) is the IPv4 address
  defp format({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: format({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp format({a, b, c, d, _, _, _, _}) do
    "v6:" <> Enum.map_join([a, b, c, d], &(&1 |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")))
  end

  defp raw(input), do: "raw:" <> binary_part(input, 0, min(byte_size(input), @max_raw_bytes))
end
