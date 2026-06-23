defmodule Nebu.Media.SSRF do
  @moduledoc """
  SSRF guard for `preview_url` (Kassandra security requirement). The `url` query
  parameter is fully attacker-controlled, so before ANY outbound fetch we:

    * require an `http`/`https` scheme (reject `file://`, `gopher://`, etc.);
    * require a host;
    * resolve the host to its IP address(es) and reject if ANY resolved address
      is loopback, private (RFC1918), link-local, unique-local (fc00::/7),
      carrier-grade NAT, or the cloud-metadata address (169.254.169.254).

  ## DNS-rebinding (TOCTOU)

  Checking every returned address (not just the first) closes the *multi-record*
  rebinding case where a single response carries both a public and a private IP.
  It does NOT by itself close the *time-of-check/time-of-use* gap: if the guard
  resolves a host and then the fetch client re-resolves it independently, a DNS
  server can return a public IP to the guard and a private IP to the client.

  `checked_target/1` closes that gap by resolving the host ONCE here and returning
  the validated IP, so the caller (`Nebu.Media.HttpFetch`) can connect to the
  checked IP instead of re-resolving. For `http`, the fetch connects directly to
  the pinned IP with the original `Host` header preserved. For `https`, pinning
  the IP in the URL would break TLS SNI/cert-hostname validation, so the fetch
  keeps the hostname in the URL — see the residual https caveat in `HttpFetch`.

  Returns `:ok` (legacy) / `{:error, reason}` from `check/1`, or a validated
  target from `checked_target/1`.
  """

  @type target :: %{scheme: String.t(), host: String.t(), ip: :inet.ip_address()}

  @doc "Validates `url` for outbound fetch. `:ok` to allow, `{:error, reason}` to block."
  @spec check(String.t()) :: :ok | {:error, atom()}
  def check(url) when is_binary(url) do
    case checked_target(url) do
      {:ok, _target} -> :ok
      {:error, _} = err -> err
    end
  end

  def check(_), do: {:error, :invalid_url}

  @doc """
  Validates `url` and resolves its host ONCE, returning the validated IP so the
  fetch can connect to the checked address (closing the DNS-rebinding TOCTOU gap).

  Returns `{:ok, %{scheme, host, ip}}` where `ip` is the first resolved address
  (all resolved addresses are checked; if any is blocked the whole url is
  rejected), or `{:error, reason}`.
  """
  @spec checked_target(String.t()) :: {:ok, target()} | {:error, atom()}
  def checked_target(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :bad_scheme}
      is_nil(uri.host) or uri.host == "" -> {:error, :no_host}
      true -> check_host(uri.scheme, uri.host)
    end
  end

  def checked_target(_), do: {:error, :invalid_url}

  defp check_host(scheme, host) do
    case resolve(host) do
      {:ok, [first | _] = addrs} ->
        if Enum.any?(addrs, &blocked_ip?/1) do
          {:error, :blocked_address}
        else
          {:ok, %{scheme: scheme, host: host, ip: first}}
        end

      {:error, _} = err ->
        err
    end
  end

  # Literal IP (v4 or v6) — no DNS lookup needed.
  defp resolve(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} ->
        {:ok, [addr]}

      {:error, _} ->
        with {:error, _} <- lookup(host, :inet),
             {:error, _} = err <- lookup(host, :inet6) do
          err
        else
          {:ok, addrs} -> {:ok, addrs}
        end
    end
  end

  defp lookup(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, addrs} when addrs != [] -> {:ok, addrs}
      {:ok, []} -> {:error, :no_address}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── IPv4 blocked ranges ────────────────────────────────────────────────────
  defp blocked_ip?({0, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  # RFC 6598 carrier-grade NAT 100.64.0.0/10
  defp blocked_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp blocked_ip?({a, _, _, _}) when a >= 224, do: true
  defp blocked_ip?({_, _, _, _}), do: false

  # ── IPv6 blocked ranges ────────────────────────────────────────────────────
  # ::1 loopback
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # :: unspecified
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # fc00::/7 unique-local
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  # fe80::/10 link-local
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  # IPv4-mapped ::ffff:a.b.c.d — re-check the embedded v4 address.
  defp blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    blocked_ip?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  defp blocked_ip?({_, _, _, _, _, _, _, _}), do: false
  defp blocked_ip?(_), do: true
end
