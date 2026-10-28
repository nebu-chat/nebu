defmodule Nebu.OAuth.OAuthVersionsBoundedTest do
  @moduledoc """
  Review cycle 1 of story `oauth-versions-switch` (Kassandra F-1 / code review MINOR 4): `GET
  /_matrix/client/versions` is the load-balancer health check path and runs one UNCACHED `server_config`
  read per request in every deployment. The read on THIS path is bounded (500 ms for the pool checkout and
  the query): a slow or locked table answers `200` v1.1-v1.11 (fail closed) within the bound instead of
  hanging the health check, and the "could not read server_config" WARNING is throttled on this path (at most
  one per minute per node). Every other caller of `Config.live_state/0` keeps the default timeouts.

  The slowness is real: a second connection holds `LOCK TABLE server_config IN ACCESS EXCLUSIVE MODE`.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @off ~w(v1.1 v1.2 v1.3 v1.4 v1.5 v1.6 v1.7 v1.8 v1.9 v1.10 v1.11)

  setup do
    T.clear_oauth_config()
    T.reset_rate_limits()
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # Holds an ACCESS EXCLUSIVE lock on server_config for `ms`; returns once the lock is taken.
  defp lock_server_config(ms) do
    parent = self()

    task =
      Task.async(fn ->
        Nebu.Repo.transaction(
          fn ->
            Ecto.Adapters.SQL.query!(Nebu.Repo, "LOCK TABLE server_config IN ACCESS EXCLUSIVE MODE", [])
            send(parent, :locked)
            Process.sleep(ms)
          end,
          timeout: ms + 5_000
        )
      end)

    assert_receive :locked, 5_000
    task
  end

  test "a locked server_config answers 200 v1.1-v1.11 within the bound (no hang, no 5xx)" do
    task = lock_server_config(2_500)
    t0 = System.monotonic_time(:millisecond)
    conn = T.get("/_matrix/client/versions")
    elapsed = System.monotonic_time(:millisecond) - t0
    Task.await(task, 10_000)

    assert conn.status == 200
    assert T.json(conn)["versions"] == @off
    assert elapsed < 1_500, "the /versions read is bounded (took #{elapsed} ms)"
  end

  test "the WARNING of a failing read is throttled on the /versions path (not one line per request)" do
    task = lock_server_config(3_000)

    log =
      capture_log(fn ->
        for _ <- 1..3, do: assert(T.get("/_matrix/client/versions").status == 200)
      end)

    Task.await(task, 10_000)
    assert length(Regex.scan(~r/OAuth\.Config: /, log)) <= 1, "at most one warning per throttle window: #{log}"
  end

  test "after the lock is released the next request reads the real state again" do
    Task.await(lock_server_config(300), 10_000)
    conn = T.get("/_matrix/client/versions")
    assert conn.status == 200 and T.json(conn)["versions"] == @off
  end

  test "static: only the /versions path asks for the bounded read; live_state/0 keeps its default timeouts" do
    lib = Path.expand("../../../lib", __DIR__)
    code = fn f -> f |> Path.join() |> then(&Path.join(lib, &1)) |> File.read!() end
    assert code.(["nebu/matrix/http_public.ex"]) =~ "bounded: true"
    refute code.(["nebu/oauth/http.ex"]) =~ "bounded: true"
    refute code.(["nebu/oauth/authorize.ex"]) =~ "bounded: true"
  end
end
