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

  Classic token bucket. Each entry is `{key, tokens, last_refill_ms}` in a named ETS set. On each request the bucket is refilled
  by `elapsed_ms * rate_per_ms`, capped at `burst`; if the cost (one token) is available it is consumed and the request proceeds,
  otherwise it is rejected with a `Retry-After` computed from the time to accrue the missing tokens (a denied request consumes
  nothing). Every consume is a compare-and-swap on the row it read (`:ets.select_replace/2` with the exact old tuple as the
  pattern, `:ets.insert_new/2` for a first touch) and is retried when another process changed the row in between, so concurrent
  requests of one key on one node can never take more than the bucket holds (review cycle 1 of story
  rate-limits-join-invite-create-room, code review MINOR-1: before, lookup + insert let a burst of simultaneous requests through
  up to about twice the burst once per bucket fill).

  ## Several buckets per request: `take_all/1`

  `take_all/1` charges ONE request against several buckets of the same table, all or nothing (story
  rate-limits-join-invite-create-room, D3): every bucket is charged with its own compare-and-swap, and when any bucket cannot pay
  the buckets already charged are refunded (the refund is a compare-and-swap too) and the answer carries the LARGEST wait over the
  buckets that cannot pay. `POST /createRoom` uses it to charge its own bucket and one invite unit per invitee in one step. It
  shares the table, the clock seam and the disable switch with the plug and `take/3`. A refused multi-bucket request can hold a
  token of a bucket for the few microseconds between the charge and the refund: a concurrent request of the same user then sees
  the bucket a little emptier (never fuller) than it is.

  ## Persistence / restart strategy (CLAUDE.md GenServer-state rule)

  State is VOLATILE: a named, public ETS set, lazily created on first use (same
  posture as the Go in-memory limiter and the OidcPlug provisioning cache). On a
  node restart all buckets reset to full — a restart cannot be used to bypass a
  sustained attack because the steady-state rate (`rate_per_min`) still bounds
  throughput within seconds of restart. No persistence is required or desirable.

  ## Bucket key (`key:` option)

  `key: :ip` (default) buckets by the client IP. `key: :user` buckets by
  `{tier, conn.assigns[:current_user]}` (falls back to the IP when no user is assigned)
  so an authenticated write route is limited per account, not per shared NAT address.
  Idle buckets are evicted by `Nebu.Web.RateLimitSweeper` (see `sweep_idle/0`), so ETS growth
  is bounded by the number of keys active within the last hour (roughly 100 bytes each).

  ## IP extraction

  The key is `Nebu.Web.ClientIP.bucket/1`: the client address of `Nebu.Web.ClientIP.get/1`
  (the direct peer, unless that peer is listed in `NEBU_TRUSTED_PROXY_CIDRS`, story
  oauth-trusted-proxy-client-ip; then the
  rightmost untrusted element of the forwarding header, trusted hops skipped). A client that reaches
  Nebu directly (an untrusted peer) can never choose its bucket by sending a header, and without
  configuration the key is the direct peer exactly as before for IPv4. A native IPv6 client is
  bucketed by its /64 network (one routed /64 must not mint unlimited buckets; security review
  cycle 1), e.g. `2001:db8:1:2::/64`; the exact address stays in `get/1`.

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

  alias Nebu.Web.ClientIP

  @table :nebu_http_rate_limit_buckets

  @doc """
  Eagerly creates the backing ETS bucket table (called from the Application
  supervisor at boot, R-2). Idempotent. Returns `:ok`.
  """
  @spec init_table() :: :ok
  def init_table, do: ensure_table()

  @idle_ms 3_600_000

  @doc """
  Deletes every bucket idle for more than one hour from this node's table and returns the number
  of rows removed. Every bucket of this module refills completely within one hour
  (`burst / rate <= 60 min`), so a deleted idle bucket is indistinguishable from a fresh one: the
  eviction never grants a client extra budget. Rows are `{key, tokens, last_ms}`; uses the same
  (injectable) clock as `take/3`. Per node, no coordination needed (the table is node-local).
  """
  @spec sweep_idle() :: non_neg_integer()
  def sweep_idle do
    ensure_table()
    cutoff = now_ms() - @idle_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  rescue
    ArgumentError -> 0
  end

  @doc """
  Takes one token from an arbitrary named bucket (same token-bucket algorithm, same ETS table,
  same `:rate_limit_clock_fn` / `NEBU_RATE_LIMIT_DISABLED` seams as the plug).

  For callers that need a limit with a NON-Matrix response shape and/or several buckets per
  request (e.g. `POST /oauth2/register`: per-IP bucket + GLOBAL bucket, OAuth-style 429 body) and
  therefore cannot use the plug, which always answers with the Matrix `M_LIMIT_EXCEEDED` envelope.

  `key` is any term (use a tuple with a tier tag so it can never collide with the plug's own
  IP-string / `{tier, user}` keys). `rate_per_min` is the steady-state refill, `burst` the bucket
  capacity. Returns `:ok` or `{:deny, retry_after_seconds}` (>= 1). The bucket table is lazily
  recreated if it vanished at runtime.
  """
  @spec take(term(), number(), pos_integer()) :: :ok | {:deny, pos_integer()}
  def take(key, rate_per_min, burst) when rate_per_min > 0 and burst > 0 do
    if disabled?() do
      :ok
    else
      take_token(key, now_ms(), rate_per_min / 60_000.0, burst)
    end
  end

  @doc """
  All-or-nothing take over one or more buckets of the SAME table (story rate-limits-join-invite-create-room, D3).

  `buckets` is a list of `{key, cost, rate_per_min, burst}`. Every bucket is refilled; `cost` tokens are consumed from each
  ONLY if EVERY bucket holds at least its cost. Otherwise nothing is consumed (a bucket charged before the denial is refunded)
  and the answer is `{:deny, retry_after_seconds}` with the LARGEST wait over the buckets that cannot pay (>= 1), so
  a client that waits that long finds every bucket able to pay. A `cost` above `burst` is charged as `burst` (a request is never
  unsatisfiable). Same keys as the plug (`{tier, user}`), same clock and disable seams; the table is lazily recreated like in
  `take/3` (a vanished table fails open).
  """
  @spec take_all([{term(), pos_integer(), number(), pos_integer()}]) :: :ok | {:deny, pos_integer()}
  def take_all(buckets) when is_list(buckets) do
    if disabled?() or buckets == [] do
      :ok
    else
      charge_buckets(for({key, cost, rate_per_min, burst} <- buckets, do: {key, cost, rate_per_min / 60_000.0, burst}), now_ms())
    end
  end

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

  # Seconds until `needed` more tokens accrue (>= 1, Go parity).
  defp wait_seconds(needed, rate_per_ms), do: max(1, ceil(needed / rate_per_ms / 1000.0))

  # Charges `cost` tokens from EVERY bucket `{key, cost, rate_per_ms, burst}` or from none (see the moduledoc). Each bucket is
  # charged by `charge_bucket/2` (a compare-and-swap); when one cannot pay, the charged ones are refunded and the largest wait wins.
  defp charge_buckets(buckets, now) do
    ensure_table()
    results = for {key, cost, rate_per_ms, burst} <- buckets, do: charge_bucket({key, min(cost, burst), rate_per_ms, burst}, now)

    case for({:deny, wait} <- results, do: wait) do
      [] ->
        :ok

      waits ->
        for {:charged, bucket} <- results, do: refund_bucket(bucket, now)
        {:deny, Enum.max(waits)}
    end
  rescue
    ArgumentError -> :ok
  end

  # `{:charged, bucket}` or `{:deny, wait_s}`. A denial stores nothing: the refill is a pure function of the stored `{tokens, last}`
  # (linear, capped), so a denied request leaves the bucket exactly as full as it was.
  defp charge_bucket({key, cost, rate_per_ms, burst} = bucket, now) do
    case :ets.lookup(@table, key) do
      [{^key, tokens, last} = row] ->
        refilled = min(burst * 1.0, tokens + max(0, now - last) * rate_per_ms)

        cond do
          refilled < cost -> {:deny, wait_seconds(cost - refilled, rate_per_ms)}
          swap(row, {key, refilled - cost, now}) -> {:charged, bucket}
          true -> charge_bucket(bucket, now)
        end

      _ ->
        # first touch: a full bucket (cost <= burst), inserted only if nobody else created it meanwhile
        if :ets.insert_new(@table, {key, burst * 1.0 - cost, now}), do: {:charged, bucket}, else: charge_bucket(bucket, now)
    end
  end

  # Gives `cost` tokens back (refilled up to `now`, capped at `burst`); a row the sweeper removed meanwhile is simply gone (the
  # next request starts from a full bucket anyway, which is what the refund would have approached).
  defp refund_bucket({key, cost, rate_per_ms, burst} = bucket, now) do
    case :ets.lookup(@table, key) do
      [{^key, tokens, last} = row] ->
        refilled = min(burst * 1.0, tokens + max(0, now - last) * rate_per_ms)
        unless swap(row, {key, min(burst * 1.0, refilled + cost), now}), do: refund_bucket(bucket, now)

      _ ->
        :ok
    end
  end

  # Compare-and-swap: replaces `old` by `new` (same key) only if the row still IS `old`.
  defp swap(old, new), do: :ets.select_replace(@table, [{old, [], [{:const, new}]}]) == 1

  # Refill then consume one token for `ip`. Returns :ok or {:deny, retry_after_s}.
  defp take_token(ip, now, rate_per_ms, burst), do: charge_buckets([{ip, 1, rate_per_ms, burst}], now)

  defp too_many(conn, retry_after_s), do: respond_limited(conn, retry_after_s)

  @doc """
  Sends the Matrix `429 M_LIMIT_EXCEEDED` envelope (`retry_after_ms` + `Retry-After`) and halts: the answer of the
  plug, for callers that take a token with `take/3` themselves (story oauth-hardening-hygiene, `GET /login`).
  """
  @spec respond_limited(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def respond_limited(conn, retry_after_s) do
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
      _ -> ClientIP.bucket(conn)
    end
  end

  defp bucket_key(conn, _opts), do: ClientIP.bucket(conn)

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
