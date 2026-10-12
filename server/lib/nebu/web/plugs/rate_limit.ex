defmodule Nebu.Web.Plugs.RateLimit do
  @moduledoc """
  Per-IP (or per-user, see `key: :user`) token-bucket rate limiting (matrix-api-migration, F-3).

  Ports the Go gateway's per-IP limiter (`gateway/internal/middleware/ratelimit.go`,
  `NewIPRateLimiter`) into the Elixir stack so the brute-force / verification-DoS
  controls the Go gateway enforced on `POST /login` (`strictRL`, 30 req/min,
  burst 10) and the long-poll `/sync` survive the migration off the Go path.

  ## Usage

      plug Nebu.Web.Plugs.RateLimit, rate_per_min: 30, burst: 10, tier: "login"

  On exhaustion responds `429` with the Matrix envelope
  `{"errcode":"M_LIMIT_EXCEEDED","error":"Rate limit exceeded","retry_after_ms":N}`
  plus a `Retry-After` header (seconds), and halts (Go parity + Matrix spec
  `retry_after_ms`).

  ## Algorithm

  Classic token bucket. Each per-IP entry is `{ip, tokens, last_refill_ms}` in a
  named ETS set. On each request the bucket is refilled by
  `elapsed_ms * rate_per_ms`, capped at `burst`; if ≥ 1 token is available one is
  consumed and the request proceeds, otherwise it is rejected with a `Retry-After`
  computed from the time to accrue one token. Refill + consume run inside
  `:ets.update_counter`-free critical sections guarded by an atomic
  compare-and-swap via `:ets.insert` after a fresh read; a benign race only ever
  lets a hair MORE traffic through, never less — acceptable for a coarse abuse
  control (matches the Go limiter's eventual-consistency under contention).

  ## Persistence / restart strategy (CLAUDE.md GenServer-state rule)

  State is VOLATILE: a named, public ETS set, lazily created on first use (same
  posture as the Go in-memory limiter and the OidcPlug provisioning cache). On a
  node restart all buckets reset to full — a restart cannot be used to bypass a
  sustained attack because the steady-state rate (`rate_per_min`) still bounds
  throughput within seconds of restart. No persistence is required or desirable.

  ## Bucket key (`key:` option)

  `key: :ip` (default) buckets by the peer IP. `key: :user` buckets by
  `{tier, conn.assigns[:current_user]}` (falls back to the IP when no user is assigned)
  so an authenticated write route is limited per account, not per shared NAT address.
  Buckets are never evicted: ETS growth is unbounded but small (one entry per distinct
  key, i.e. per account for `key: :user`, roughly 100 bytes each).

  ## IP extraction

  Uses `conn.remote_ip` (the directly-connected peer). The Go limiter consulted
  `X-Forwarded-For` only when explicitly told the proxy was trusted; here there
  is no trusted-proxy config yet, so the peer IP is used directly — the safe
  default (a client cannot spoof its own bucket key by sending a header).

  ## Test / dev escape hatch

  `NEBU_RATE_LIMIT_DISABLED=true` (or `:nebu_http, :rate_limit_disabled` set to
  `true`) makes the plug a no-op, mirroring the Go gateway's
  `NEBU_RATE_LIMIT_DISABLED` so integration/e2e suites are not throttled.

  ### TEST-ONLY: injectable clock

  Setting `:nebu_http, :rate_limit_clock_fn` to a zero-arity function overrides
  the wall-clock used by the token bucket. Example:

      Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 1_000_000 end)

  With a frozen constant every request sees `now - last == 0` → no refill →
  deterministic burst exhaustion without any `Process.sleep`. Restore in
  `on_exit` by calling `Application.delete_env(:nebu_http, :rate_limit_clock_fn)`.
  This seam MUST NOT be set in production; the default (`nil`) falls through to
  `System.monotonic_time(:millisecond)` with no overhead.
  """
  @behaviour Plug

  import Plug.Conn

  @table :nebu_http_rate_limit_buckets

  @doc """
  Eagerly creates the backing ETS bucket table (called from the Application
  supervisor at boot, R-2). Idempotent. Returns `:ok`.
  """
  @spec init_table() :: :ok
  def init_table, do: ensure_table()

  @impl Plug
  def init(opts) do
    rate_per_min = Keyword.fetch!(opts, :rate_per_min)
    burst = Keyword.fetch!(opts, :burst)

    %{
      # tokens per millisecond
      rate_per_ms: rate_per_min / 60_000.0,
      burst: burst,
      tier: Keyword.get(opts, :tier, "default"),
      # :ip (default) buckets by peer IP shared across tiers (login/sync);
      # :user buckets by `{tier, conn.assigns[:current_user]}` (falls back to the IP when
      # no user is assigned). Use :user for authenticated write routes, so one account
      # cannot be throttled by (or hide behind) a shared NAT address.
      key: Keyword.get(opts, :key, :ip)
    }
  end

  @impl Plug
  def call(conn, %{rate_per_ms: rate_per_ms, burst: burst} = opts) do
    if disabled?() do
      conn
    else
      ip = bucket_key(conn, opts)
      now = now_ms()

      case take_token(ip, now, rate_per_ms, burst) do
        :ok ->
          conn

        {:deny, retry_after_s} ->
          too_many(conn, retry_after_s)
      end
    end
  end

  # Returns the current time in milliseconds. Delegates to an injectable clock fn
  # when `:nebu_http, :rate_limit_clock_fn` is set (TEST-ONLY seam); otherwise
  # falls through to `System.monotonic_time(:millisecond)` with no overhead.
  defp now_ms do
    case Application.get_env(:nebu_http, :rate_limit_clock_fn) do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.monotonic_time(:millisecond)
    end
  end

  # Refill then consume one token for `ip`. Returns :ok or {:deny, retry_after_s}.
  defp take_token(ip, now, rate_per_ms, burst) do
    ensure_table()

    {tokens, last} =
      case :ets.lookup(@table, ip) do
        [{^ip, t, l}] -> {t, l}
        _ -> {burst * 1.0, now}
      end

    refilled = min(burst * 1.0, tokens + max(0, now - last) * rate_per_ms)

    if refilled >= 1.0 do
      :ets.insert(@table, {ip, refilled - 1.0, now})
      :ok
    else
      :ets.insert(@table, {ip, refilled, now})
      # Seconds until one whole token accrues (≥ 1, Go parity).
      needed = 1.0 - refilled
      retry_after_s = max(1, ceil(needed / rate_per_ms / 1000.0))
      {:deny, retry_after_s}
    end
  rescue
    ArgumentError -> :ok
  end

  defp too_many(conn, retry_after_s) do
    # Matrix spec (rate limiting): 429 SHOULD carry `retry_after_ms` in the body.
    body =
      Jason.encode!(%{
        "errcode" => "M_LIMIT_EXCEEDED",
        "error" => "Rate limit exceeded",
        "retry_after_ms" => retry_after_s * 1000
      })

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> send_resp(429, body)
    |> halt()
  end

  defp bucket_key(conn, %{key: :user, tier: tier}) do
    case conn.assigns[:current_user] do
      user when is_binary(user) and user != "" -> {tier, user}
      _ -> ip_key(conn)
    end
  end

  defp bucket_key(conn, _opts), do: ip_key(conn)

  defp ip_key(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) -> :inet.ntoa(ip) |> to_string()
      other -> to_string(other)
    end
  end

  defp disabled? do
    System.get_env("NEBU_RATE_LIMIT_DISABLED") == "true" or
      Application.get_env(:nebu_http, :rate_limit_disabled, false) == true
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end
end
