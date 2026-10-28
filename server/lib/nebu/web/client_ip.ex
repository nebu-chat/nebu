defmodule Nebu.Web.ClientIP do
  @moduledoc """
  Client-address resolution for every per-IP decision (story `oauth-trusted-proxy-client-ip`,
  gate item 1 of epic oauth-broker; ADR-033 section "Trusted-proxy client IP", TP1-TP14).

  This module and `Nebu.Web.Plugs.ClientIP` are the ONLY places in `server/lib` that read the
  socket peer (`remote_ip`, Plug/Bandit peer data) or the forwarding header (contract test). Every consumer (RateLimit plug, OAuth endpoints,
  `created_from_ip`, `devices.last_seen_ip`) calls `get/1`.

  ## Contract

    * `NEBU_TRUSTED_PROXY_CIDRS` (explicit CIDR allowlist, default empty = the direct peer is the
      client, byte-identical to the behaviour before this story) lists the proxies Nebu trusts.
    * The forwarding header is honoured ONLY when the direct peer is in that list. The header
      is then walked right-to-left; trusted hops are skipped and the first (rightmost) untrusted
      element is the client. Anything malformed, empty, oversized or fully trusted falls back to
      the direct peer, never to the leftmost element (TP5).
    * `RFC 7239` forwarded-element headers and the real-ip header of some proxies are ignored
      entirely (TP6).
    * IPv4-mapped IPv6 addresses are converted to IPv4 before matching and in the result (TP7).
    * `bucket/1` is the rate-limit key: `get/1` for IPv4, the /64 network for native IPv6.
    * The result is stored by the plug in `conn.private[:nebu_client_ip]`; the socket peer on the
      conn is never rewritten (TP9). `get/1` of a conn that never passed the plug returns the
      normalised direct peer, never a header-derived value (TP10, fail closed).

  ## Cluster safety (TP11)

  The resolution is a pure function of the request and of the boot configuration. The parsed CIDR
  list is cached in `:persistent_term` (written at boot by `load_config/0`; `configure/1` is the
  TEST/boot-only writer). Nothing here is correctness state of a node.

  ## Logging (TP13)

  The boot lines and ONE throttled WARNING (story `client-ip-misconfiguration-warnings`, W1) are logged:
  `note_untrusted_forwarding/0`, called by the plug when a request carries `X-Forwarded-For` but its
  direct peer is not trusted, at most once per 10 minutes per node (a node-local `:atomics` slot that
  `configure/1` creates; NOT `Nebu.Web.Plugs.RateLimit`, which is switched off by
  `NEBU_RATE_LIMIT_DISABLED`). Never a resolved client address, a peer address, a header value or the
  full list. The warning is informational only and decides nothing (cluster safety, TP11).
  """

  import Bitwise
  require Logger

  @type family :: :inet | :inet6
  @type cidr :: {family(), non_neg_integer(), 0..128}

  @pt_key {__MODULE__, :trusted}
  # W1 throttle: an :atomics slot holding the monotonic second of the last warning (node-local, informational).
  @xff_key {__MODULE__, :xff_warn}
  @xff_interval_s 600

  @max_entries 64
  @max_value_bytes 4096
  @max_entry_bytes 64
  @max_header_bytes 2048
  @max_hops 20
  @max_literal_bytes 45
  @max_logged_entries 5

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  The client address string of the request: the value stored by `Nebu.Web.Plugs.ClientIP`, or,
  for a conn that never passed the plug, the normalised direct peer (never header-derived).
  """
  @spec get(Plug.Conn.t()) :: String.t()
  def get(%Plug.Conn{private: %{nebu_client_ip: ip}}) when is_binary(ip), do: ip
  def get(%Plug.Conn{remote_ip: peer}), do: peer_string(peer)

  @doc """
  The RATE-LIMIT bucket key of the request's client (TP8, security review cycle 1): the IPv4 string
  of `get/1` unchanged; a native IPv6 client is aggregated to its /64 network in canonical form
  (`2001:db8:1:2::/64`), because one routed /64 gives a single client 2^64 addresses and would
  otherwise mint unlimited fresh buckets. IPv4-mapped addresses are already IPv4 here. Only
  per-IP LIMITS use this; stored data (`devices.last_seen_ip`, `oauth_clients.created_from_ip`)
  keeps the exact `get/1` address.
  """
  @spec bucket(Plug.Conn.t()) :: String.t()
  def bucket(%Plug.Conn{private: %{nebu_client_bucket: key}}) when is_binary(key), do: key

  def bucket(%Plug.Conn{} = conn) do
    ip = get(conn)

    case :inet.parse_strict_address(:erlang.binary_to_list(ip)) do
      {:ok, tuple} -> bucket_for(tuple)
      _ -> ip
    end
  end

  @doc false
  @spec bucket_for(term()) :: String.t()
  def bucket_for(ip) do
    case normalize(ip) do
      {a, b, c, d, _, _, _, _} when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) ->
        format({a, b, c, d, 0, 0, 0, 0}) <> "/64"

      other ->
        format(other)
    end
  end

  @doc """
  Pure resolver. `xff` is the list of all values of the forwarding header in request order.
  Returns `{:forwarded, ip}` when the header identified a client behind a trusted peer, otherwise
  `{:peer, ip}`. The returned address is IPv4-normalised.
  """
  @spec resolve(:inet.ip_address(), [binary()], [cidr()]) :: {:peer | :forwarded, :inet.ip_address()}
  def resolve(peer, xff, trusted) do
    peer = normalize(peer)

    if trusted?(peer, trusted) do
      walk(peer, xff, trusted)
    else
      {:peer, peer}
    end
  end

  @doc """
  Parses the raw value of `NEBU_TRUSTED_PROXY_CIDRS` (entries separated by commas and/or
  whitespace). Returns `{trusted, invalid}`; fail-closed (TP2): an invalid entry is ignored and
  reported, more than #{@max_entries} entries or more than #{@max_value_bytes} bytes invalidate the
  whole value.
  """
  @spec parse_cidrs(String.t() | nil) :: {[cidr()], [String.t()]}
  def parse_cidrs(nil), do: {[], []}

  def parse_cidrs(spec) when is_binary(spec) do
    cond do
      byte_size(spec) > @max_value_bytes ->
        {[], ["whole value ignored (over #{@max_value_bytes} bytes)"]}

      true ->
        entries = :binary.split(spec, [",", " ", "\t", "\n", "\r", "\v", "\f"], [:global, :trim_all])

        if length(entries) > @max_entries do
          {[], ["whole value ignored (more than #{@max_entries} entries: #{length(entries)})"]}
        else
          Enum.reduce(entries, {[], []}, fn entry, {ok, bad} ->
            case parse_entry(entry) do
              {:ok, cidr} -> {[cidr | ok], bad}
              :error -> {ok, [truncate(entry) | bad]}
            end
          end)
          |> then(fn {ok, bad} -> {Enum.reverse(ok), Enum.reverse(bad)} end)
        end
    end
  end

  def parse_cidrs(_other), do: {[], []}

  @doc "Boot: reads `:nebu_http, :trusted_proxy_cidrs` (raw env string or nil), parses, stores, logs."
  @spec load_config() :: :ok
  def load_config, do: configure(Application.get_env(:nebu_http, :trusted_proxy_cidrs))

  @doc """
  Parses `spec`, stores the trusted set in `:persistent_term` and logs the boot lines. Boot and
  TEST only (a global writer); `configure(nil)` restores "no trusted proxy".
  """
  @spec configure(String.t() | nil) :: :ok
  def configure(spec) do
    spec = if is_binary(spec), do: spec, else: nil
    {trusted, invalid} = parse_cidrs(spec)
    :persistent_term.put(@pt_key, trusted)
    reset_xff_throttle()
    log_config(trusted, invalid)
    :ok
  end

  # W1 (story client-ip-misconfiguration-warnings, D1): a request carried the forwarding header but its direct
  # peer is not trusted. Called by `Nebu.Web.Plugs.ClientIP` on the untrusted path only. At most one WARNING per
  # node and 600 s (`compare_exchange` makes a concurrent burst log exactly once); the text is static (no peer
  # address, no header value, no path). Without a throttle slot (the plug used without `configure/1`) nothing is
  # logged. Never raises.
  @spec note_untrusted_forwarding() :: :ok
  @doc false
  def note_untrusted_forwarding do
    case :persistent_term.get(@xff_key, nil) do
      nil ->
        :ok

      ref ->
        now = now_s()
        last = :atomics.get(ref, 1)

        if now - last >= @xff_interval_s and :atomics.compare_exchange(ref, 1, last, now) == :ok do
          Logger.warning(
            "client IP: a request carried X-Forwarded-For but its direct peer is not in NEBU_TRUSTED_PROXY_CIDRS, " <>
              "so the header was ignored. If Nebu runs behind a proxy or load balancer, every client behind it shares " <>
              "ONE rate-limit bucket and per-source cap (one source can lock all users out of login): list the proxy in " <>
              "NEBU_TRUSTED_PROXY_CIDRS (07-deployment, \"Client IP behind a reverse proxy\"). A client can also send " <>
              "this header itself (never widen the list to silence this line; your own negative test against a direct port " <>
              "also triggers it). Logged at most once per 10 minutes per node."
          )
        end

        :ok
    end
  end

  # First occurrence after `configure/1` logs immediately: the slot starts one interval in the past
  # (`System.monotonic_time/1` may be negative, so 0 is never used as a sentinel).
  defp reset_xff_throttle do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, now_s() - @xff_interval_s)
    :persistent_term.put(@xff_key, ref)
  end

  # Seams exist only in test builds: the clock of the W1 throttle (zero-arity, seconds).
  if Mix.env() == :test do
    defp now_s do
      case Application.get_env(:nebu_http, :client_ip_warn_clock_fn) do
        fun when is_function(fun, 0) -> fun.()
        _ -> System.monotonic_time(:second)
      end
    end
  else
    defp now_s, do: System.monotonic_time(:second)
  end

  @doc "The configured trusted CIDR list (`[]` when nothing was ever loaded)."
  @spec trusted() :: [cidr()]
  def trusted, do: :persistent_term.get(@pt_key, [])

  @doc false
  @spec trusted?(term(), [cidr()]) :: boolean()
  def trusted?(ip, trusted) do
    case to_int(ip) do
      {family, int} ->
        Enum.any?(trusted, fn
          {^family, net, prefix} -> bsr(int, bits(family) - prefix) == bsr(net, bits(family) - prefix)
          _ -> false
        end)

      :error ->
        false
    end
  end

  @doc false
  @spec peer_string(term()) :: String.t()
  def peer_string(peer) when is_tuple(peer), do: peer |> normalize() |> format()
  def peer_string(other) when is_binary(other), do: other
  def peer_string(other) do
    if String.Chars.impl_for(other), do: to_string(other), else: inspect(other)
  end

  @doc false
  @spec format(term()) :: String.t()
  def format(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> inspect(ip)
      chars -> List.to_string(chars)
    end
  end

  def format(other), do: peer_string(other)

  @doc false
  @spec normalize(term()) :: term()
  def normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) when hi in 0..0xFFFF and lo in 0..0xFFFF,
    do: {hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255}

  def normalize(ip), do: ip

  # ── Resolver internals ─────────────────────────────────────────────────────

  defp walk(peer, lines, trusted) do
    # The size cap is checked BEFORE any join/split (TP5): a hostile header costs O(1).
    total = Enum.reduce(lines, max(length(lines) - 1, 0), fn l, acc -> acc + byte_size(l) end)

    if total == 0 or total > @max_header_bytes do
      {:peer, peer}
    else
      elements = lines |> Enum.join(",") |> then(&:binary.split(&1, ",", [:global])) |> Enum.reverse()
      walk_elements(elements, 0, peer, trusted)
    end
  end

  # Every element reached was trusted: nothing identifies a client.
  defp walk_elements([], _hops, peer, _trusted), do: {:peer, peer}
  # Hop cap: more than @max_hops elements would have to be examined.
  defp walk_elements(_elements, hops, peer, _trusted) when hops >= @max_hops, do: {:peer, peer}

  defp walk_elements([element | rest], hops, peer, trusted) do
    case parse_ip(trim(element)) do
      {:ok, ip} ->
        ip = normalize(ip)
        if trusted?(ip, trusted), do: walk_elements(rest, hops + 1, peer, trusted), else: {:forwarded, ip}

      :error ->
        {:peer, peer}
    end
  end

  # ASCII space / tab only, byte-wise (never raises on invalid UTF-8).
  defp trim(bin) do
    bin |> trim_leading() |> trim_trailing()
  end

  defp trim_leading(<<c, rest::binary>>) when c in [?\s, ?\t], do: trim_leading(rest)
  defp trim_leading(bin), do: bin

  defp trim_trailing(bin) do
    size = byte_size(bin)

    if size > 0 and :binary.last(bin) in [?\s, ?\t],
      do: trim_trailing(binary_part(bin, 0, size - 1)),
      else: bin
  end

  # ── Parsing internals ──────────────────────────────────────────────────────

  defp parse_entry(entry) when byte_size(entry) > @max_entry_bytes, do: :error

  defp parse_entry(entry) do
    case :binary.split(entry, "/", [:global]) do
      [addr] -> build_cidr(addr, nil)
      [addr, prefix] -> build_cidr(addr, prefix)
      _ -> :error
    end
  end

  defp build_cidr(addr, prefix_s) do
    with {:ok, ip} <- parse_ip(addr),
         true <- normalize(ip) == ip,
         {family, net} <- to_int(ip),
         {:ok, prefix} <- parse_prefix(prefix_s, bits(family)),
         true <- host_bits_clear?(net, bits(family), prefix) do
      {:ok, {family, net, prefix}}
    else
      _ -> :error
    end
  end

  defp parse_prefix(nil, max), do: {:ok, max}

  defp parse_prefix(s, max) do
    if Regex.match?(~r/\A(0|[1-9][0-9]{0,2})\z/, s) do
      p = String.to_integer(s)
      if p <= max, do: {:ok, p}, else: :error
    else
      :error
    end
  end

  defp host_bits_clear?(net, bits, prefix) do
    host = bits - prefix
    bsl(bsr(net, host), host) == net
  end

  # IP literal without prefix, TP2 address rules. Byte-wise: never raises on any binary.
  defp parse_ip(bin) when is_binary(bin) and byte_size(bin) in 1..@max_literal_bytes do
    cond do
      :binary.match(bin, ["%", "[", "]"]) != :nomatch -> :error
      leading_zero_octet?(bin) -> :error
      true -> bin |> :erlang.binary_to_list() |> :inet.parse_strict_address()
    end
    |> case do
      {:ok, ip} when is_tuple(ip) -> {:ok, ip}
      _ -> :error
    end
  end

  defp parse_ip(_), do: :error

  # `010.0.0.1`: octal ambiguity. Only the dotted part is inspected (hex groups may carry zeros).
  defp leading_zero_octet?(bin) do
    if :binary.match(bin, ".") == :nomatch do
      false
    else
      tail = bin |> :binary.split(":", [:global]) |> List.last()
      Regex.match?(~r/(^|\.)0[0-9]/, tail)
    end
  end

  defp to_int({a, b, c, d}) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do: {:inet, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

  defp to_int({_, _, _, _, _, _, _, _} = ip) do
    words = Tuple.to_list(ip)

    if Enum.all?(words, &(is_integer(&1) and &1 in 0..0xFFFF)),
      do: {:inet6, Enum.reduce(words, 0, fn w, acc -> acc <<< 16 ||| w end)},
      else: :error
  end

  defp to_int(_), do: :error

  defp bits(:inet), do: 32
  defp bits(:inet6), do: 128

  defp truncate(bin) when byte_size(bin) > @max_entry_bytes, do: binary_part(bin, 0, @max_entry_bytes)
  defp truncate(bin), do: bin

  # ── Boot logging (TP2, TP3, TP13) ──────────────────────────────────────────

  defp log_config(trusted, invalid) do
    if invalid != [] do
      shown = invalid |> Enum.take(@max_logged_entries) |> Enum.map_join(", ", &inspect(truncate(&1)))

      Logger.warning(
        "NEBU_TRUSTED_PROXY_CIDRS: ignored #{length(invalid)} invalid entry(ies), never widening the trusted set: #{shown}"
      )
    end

    if Enum.any?(trusted, fn {_, _, prefix} -> prefix == 0 end) do
      Logger.warning(
        "NEBU_TRUSTED_PROXY_CIDRS: trusting X-Forwarded-For from every peer: " <>
          "any client that reaches Nebu directly can choose its rate-limit bucket"
      )
    end

    if trusted != [] do
      Logger.info("NEBU_TRUSTED_PROXY_CIDRS: #{length(trusted)} trusted proxy CIDR(s) configured")
    end

    :ok
  end
end
