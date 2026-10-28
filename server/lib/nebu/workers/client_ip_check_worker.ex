defmodule Nebu.Workers.ClientIPCheckWorker do
  @moduledoc """
  Oban-cron job every 6 hours (`37 */6 * * *`; epic oauth-broker, story
  `client-ip-misconfiguration-warnings`, W2, SEC gate 3 finding G3-2) that WARNs when the client address
  of the devices looks collapsed: at least 10 devices of at least 5 users were all seen within the last
  24 h from at most 2 addresses (`devices.last_seen_ip`). That is the signature of a load balancer or
  proxy that does not pass the client address on, where EVERY client shares one rate-limit bucket and
  per-source cap and one anonymous source can lock all users out of login.

  Read-only and informational: it decides nothing and never blocks `oauth_enabled` (the POSITIVE client-IP
  test of 07-deployment stays a manual gate; the absence of this warning proves nothing). A real deployment
  whose users all sit behind one NAT gets the same line (documented residual).

  The data comes from `Nebu.Matrix.device_address_spread/1` (ADR-020: `devices` is Matrix domain), which
  runs one count-only aggregate under a 5 s statement timeout and never selects an address; the log line
  carries three integers and the OAuth state, never an address, user or device id.

  Cluster safe: Cron enqueues from the Oban leader only (one evaluation per cluster and run); a concurrent
  duplicate run would only log a duplicate line. `max_attempts: 1`: the next cron run is the retry. It uses
  the existing limit-1 `oauth_cleanup` housekeeping queue (no new queue) although it only reads.
  """
  use Oban.Worker, queue: :oauth_cleanup, max_attempts: 1

  require Logger

  @min_devices 10
  @min_users 5
  @max_addresses 2
  @window_ms 24 * 3_600_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    since_ms = now_ms() - @window_ms

    case spread(since_ms) do
      {:ok, %{devices: _, users: _, addresses: _} = counts} ->
        if assess(counts) == :collapsed, do: log_collapsed(counts)
        :ok

      {:error, reason} ->
        Logger.warning("client IP: device address check failed: #{log_reason(reason)}")
        {:error, reason}

      other ->
        Logger.warning("client IP: device address check failed: unexpected result")
        {:error, {:unexpected_result, other}}
    end
  end

  @doc false
  @spec assess(%{devices: integer(), users: integer(), addresses: integer()}) :: :collapsed | :ok
  def assess(%{devices: devices, users: users, addresses: addresses}) do
    if devices >= @min_devices and users >= @min_users and addresses in 1..@max_addresses//1,
      do: :collapsed,
      else: :ok
  end

  defp log_collapsed(%{devices: devices, users: users, addresses: addresses}) do
    oauth_offered = Nebu.OAuth.oauth_aware?()

    Logger.warning(
      "client IP: all #{devices} devices of #{users} users active in the last 24 h were seen from at most " <>
        "#{addresses} client address(es). Behind a load balancer or proxy that does not pass the client address on " <>
        "(for example tls_mode alb / dynamic with an empty lb_real_ip_cidrs) every client shares ONE rate-limit bucket " <>
        "and per-source cap, so one source can lock all users out of login. Run the POSITIVE client-IP test " <>
        "(07-deployment, \"Client IP behind a reverse proxy\"); if all your users really share one network address " <>
        "(single NAT), this is expected. oauth_offered=#{oauth_offered}",
      oauth_offered: oauth_offered
    )
  end

  # Test builds only: the clock and the data source can be replaced (zero-arity / one-arity functions in
  # `Application.get_env(:nebu_http, ...)`). Every other build uses the system clock and the Matrix facade.
  if Mix.env() == :test do
    defp now_ms do
      case Application.get_env(:nebu_http, :client_ip_check_now_ms_fn) do
        fun when is_function(fun, 0) -> fun.()
        _ -> System.system_time(:millisecond)
      end
    end

    defp spread(since_ms) do
      case Application.get_env(:nebu_http, :client_ip_check_spread_fn) do
        fun when is_function(fun, 1) -> fun.(since_ms)
        _ -> Nebu.Matrix.device_address_spread(since_ms)
      end
    end
  else
    # the SAME clock that writes `devices.last_seen_ts` (DeviceKeyStore.now_ms/0)
    defp now_ms, do: System.system_time(:millisecond)
    defp spread(since_ms), do: Nebu.Matrix.device_address_spread(since_ms)
  end

  # Only the exception type / SQLSTATE, never row data or a server message.
  defp log_reason(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp log_reason(%{__struct__: struct}), do: inspect(struct)
  defp log_reason(other) when is_atom(other), do: inspect(other)
  defp log_reason(_other), do: "unexpected error"
end
