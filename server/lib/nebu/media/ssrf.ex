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
  @spec checked_target(String.t(), keyword()) :: {:ok, target()} | {:error, atom()}
  def checked_target(url, opts \\ [])

  def checked_target(url, opts) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :bad_scheme}
      is_nil(uri.host) or uri.host == "" -> {:error, :no_host}
      true -> check_host(uri.scheme, uri.host, Keyword.get(opts, :allow_private, false))
    end
  end

  def checked_target(_, _opts), do: {:error, :invalid_url}

  @doc """
  Whether the operator opted in (`NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS=true`,
  wired in `config/runtime.exs`) to object-storage endpoints that resolve to a
  private address. Only the admin-configured storage endpoints
  (`endpoint`/`iam_endpoint`/`sts_endpoint`) consult this — `preview_url` and
  webhooks never do.

  UpCloud's `*-private.upcloudobjects.com` endpoints resolve to carrier-grade
  NAT addresses (100.64.0.0/10), which are blocked by default.
  """
  @spec allow_private_storage?() :: boolean()
  def allow_private_storage? do
    Application.get_env(:nebu_http, :media_storage_allow_private_endpoints, false) == true
  end

  @doc """
  Human-readable reason for a `checked_target/2` error, for admin-facing
  messages (never for attacker-controlled flows).
  """
  @spec describe_error(atom()) :: String.t()
  def describe_error(:blocked_address),
    do:
      "the host resolves to a private, loopback, link-local or carrier-grade-NAT address " <>
        "(set NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS=true to allow private storage endpoints)"

  def describe_error(:bad_scheme), do: "the URL scheme must be http:// or https://"
  def describe_error(:no_host), do: "the URL has no host"

  def describe_error(reason) when reason in [:nxdomain, :no_address, :timeout],
    do: "the host could not be resolved via DNS (#{reason})"

  def describe_error(reason), do: "the endpoint could not be validated (#{inspect(reason)})"

  defp check_host(scheme, host, allow_private) do
    case resolve(host) do
      {:ok, [first | _] = addrs} ->
        if Enum.any?(addrs, &blocked_ip?(&1, allow_private)) do
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

  # With `allow_private` (storage endpoints only, operator opt-in) the
  # private/internal ranges — RFC1918, CGNAT, IPv6 unique-local — are allowed.
  # Loopback, link-local (incl. the 169.254.169.254 metadata address),
  # unspecified and multicast/reserved addresses stay blocked unconditionally.
  defp blocked_ip?(ip, allow_private) do
    cond do
      always_blocked?(ip) -> true
      allow_private -> false
      true -> private_ip?(ip)
    end
  end

  # ── Always blocked ─────────────────────────────────────────────────────────
  defp always_blocked?({0, _, _, _}), do: true
  defp always_blocked?({127, _, _, _}), do: true
  defp always_blocked?({169, 254, _, _}), do: true
  defp always_blocked?({a, _, _, _}) when a >= 224, do: true
  defp always_blocked?({_, _, _, _}), do: false
  # ::1 loopback
  defp always_blocked?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # :: unspecified
  defp always_blocked?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # fe80::/10 link-local
  defp always_blocked?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  # IPv4-mapped ::ffff:a.b.c.d — re-check the embedded v4 address.
  defp always_blocked?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    always_blocked?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  defp always_blocked?({_, _, _, _, _, _, _, _}), do: false
  defp always_blocked?(_), do: true

  # ── Private ranges (blocked unless `allow_private`) ────────────────────────
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  # RFC 6598 carrier-grade NAT 100.64.0.0/10
  defp private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_ip?({_, _, _, _}), do: false
  # fc00::/7 unique-local
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true

  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    private_ip?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  defp private_ip?(_), do: false
end
