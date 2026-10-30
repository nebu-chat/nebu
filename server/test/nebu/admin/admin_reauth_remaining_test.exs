defmodule Nebu.Admin.AdminReauthRemainingTest do
  @moduledoc """
  Story `admin-reauth-button-flow`: the read-only accessor `Nebu.Admin.Auth.reauth_remaining_minutes(conn, path)` the pages use for the validity line.

  ## Pinned contract

    * `{:ok, minutes}` exactly when `Nebu.Admin.Auth.reauth_fresh(conn, path)` is `{:ok, _}` (same subject, same path, at most 300 s old, not from the future
      beyond the 5 s skew); otherwise `:stale`. A stale marker gives NO number.
    * `minutes` = the FLOOR of the remaining whole minutes of the 300 s the marker is usable for: `0` means "less than a minute" (below 60 s), never
      more than 5, never negative (a marker from the near future is capped at 5).
    * Read only: it never writes the session (the marker is still there, unchanged, after the call) and adds no state.

  The seconds used here stay clear of the minute boundaries by 10 s or more (a test must not flip when the clock ticks between the marker and the call).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth
  alias Nebu.OAuth.TestSupport, as: T

  @page "/admin/config"
  @sub "admin-1"

  defp conn_with(marker, sub \\ @sub) do
    conn(:get, @page)
    |> init_test_session(%{"current_user" => %{"admin" => true, "sub" => sub}, "admin_reauth" => marker})
  end

  defp marker(ago, opts \\ []), do: T.fresh_marker(Keyword.get(opts, :sub, @sub), ago, "auth_time", Keyword.get(opts, :path, @page))

  describe "the number of whole minutes left (floor)" do
    for {ago, expected} <- [{30, 4}, {70, 3}, {130, 2}, {190, 1}, {250, 0}, {270, 0}] do
      test "a marker #{ago} s old (about #{300 - ago} s left) has #{expected} whole minutes left" do
        assert Auth.reauth_remaining_minutes(conn_with(marker(unquote(ago))), @page) == {:ok, unquote(expected)}
      end
    end

    test "a marker made just now has 4 or 5 minutes left (299 s or 300 s, depending on the second the call lands in), never more than 5" do
      assert {:ok, minutes} = Auth.reauth_remaining_minutes(conn_with(marker(0)), @page)
      assert minutes in [4, 5]
    end

    test "a marker from the near future (within the 5 s skew of reauth_fresh) is capped at 5 minutes" do
      assert {:ok, 5} = Auth.reauth_remaining_minutes(conn_with(marker(-3)), @page)
    end
  end

  describe "stale gives no number" do
    test "no marker at all" do
      conn = conn(:get, @page) |> init_test_session(%{"current_user" => %{"admin" => true, "sub" => @sub}})
      assert Auth.reauth_remaining_minutes(conn, @page) == :stale
    end

    test "an expired marker (older than 300 s) and one from the far future" do
      assert Auth.reauth_remaining_minutes(conn_with(marker(310)), @page) == :stale
      assert Auth.reauth_remaining_minutes(conn_with(marker(3_600)), @page) == :stale
      assert Auth.reauth_remaining_minutes(conn_with(marker(-60)), @page) == :stale
    end

    test "a marker bound to another page" do
      for other <- ["/admin/config/claim-mapping", "/admin/config/role-mapping", "/admin/media/settings", "/admin/oauth/registrations/c1/approve", "/admin/oauth/clients/c1/revoke", "/admin/config/"] do
        assert Auth.reauth_remaining_minutes(conn_with(marker(30, path: other)), @page) == :stale, other
      end
    end

    test "a marker of another subject, a marker without a path (the old shape), a marker of another shape" do
      assert Auth.reauth_remaining_minutes(conn_with(marker(30, sub: "admin-2")), @page) == :stale
      assert Auth.reauth_remaining_minutes(conn_with(T.fresh_marker(@sub, 30, "auth_time", nil)), @page) == :stale
      assert Auth.reauth_remaining_minutes(conn_with(%{"sub" => @sub, "at" => "yesterday", "kind" => "auth_time", "path" => @page}), @page) == :stale
      assert Auth.reauth_remaining_minutes(conn_with("not-a-map"), @page) == :stale
    end

    test "no signed-in admin session: stale" do
      conn = conn(:get, @page) |> init_test_session(%{"admin_reauth" => marker(30)})
      assert Auth.reauth_remaining_minutes(conn, @page) == :stale
    end
  end

  describe "it agrees with reauth_fresh/2 and writes nothing" do
    test "{:ok, _} exactly when reauth_fresh is {:ok, _}, across the whole lifetime" do
      for ago <- [-3, 0, 1, 59, 60, 61, 119, 120, 179, 180, 239, 240, 241, 270, 299, 301, 400, 3_600] do
        conn = conn_with(marker(ago))
        fresh? = match?({:ok, _}, Auth.reauth_fresh(conn, @page))
        remaining = Auth.reauth_remaining_minutes(conn, @page)
        # 299 / 301 may land on either side of the 300 s edge when the second ticks: only the pairing at one instant counts
        if ago not in [299, 301], do: assert(match?({:ok, _}, remaining) == fresh?, "ago #{ago}: #{inspect(remaining)} vs fresh #{fresh?}")
      end
    end

    test "the call leaves the marker of the session exactly as it was" do
      m = marker(30)
      conn = conn_with(m)
      _ = Auth.reauth_remaining_minutes(conn, @page)
      assert get_session(conn, "admin_reauth") == m
    end

    test "the remaining minutes of one marker never grow between two calls" do
      conn = conn_with(marker(130))
      assert {:ok, a} = Auth.reauth_remaining_minutes(conn, @page)
      assert {:ok, b} = Auth.reauth_remaining_minutes(conn, @page)
      assert b <= a
    end
  end
end
