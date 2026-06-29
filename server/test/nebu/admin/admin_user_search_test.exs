defmodule Nebu.Admin.UserSearchTest do
  @moduledoc """
  Acceptance + security tests for GET /admin/users/search — the JSON backend of the
  add-member typeahead (admin-add-user-autocomplete).

  Verifies:
    * AC: an admin GET with a matching query returns a JSON `{"users": [...]}` body with
      the expected user_id shape.
    * AC: a query matching no user returns an empty list (drives the no-suggestions UI).
    * Security (authz): an unauthenticated caller is NOT served JSON — `:require_admin`
      redirects to /admin/login (no user-directory data leaked to anonymous callers).
    * Security (SQLi / parameterization): the query string is passed verbatim to the
      `Nebu.Admin.UserSuggest` search layer (which binds it as a SQL PARAMETER). A query
      containing SQL/ILIKE metacharacters is forwarded as the literal term, never
      interpolated — verified through the injectable `:admin_user_searcher` seam.

  No live Postgres needed: the search is driven through the `:admin_user_searcher`
  app-env seam (the established ADR-018 test-seam pattern used across the admin tests).

  Crash/restart — NOT APPLICABLE: stateless HTTP controller (Persistenz Option C).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)
  @admin "@admin:test.local"

  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-1",
      "matrix_user_id" => @admin
    })
  end

  defp build_anon_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp seam(fun) do
    Application.put_env(:nebu_http, :admin_user_searcher, fun)
    on_exit(fn -> Application.delete_env(:nebu_http, :admin_user_searcher) end)
  end

  test "admin GET /admin/users/search?q=al returns matching users as JSON" do
    seam(fn query ->
      assert query == "al"
      [%{user_id: "@alex:localhost"}, %{user_id: "@alice:localhost"}]
    end)

    conn = build_admin_conn(:get, "/admin/users/search?q=al") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"

    assert Jason.decode!(conn.resp_body) == %{
             "users" => [
               %{"user_id" => "@alex:localhost"},
               %{"user_id" => "@alice:localhost"}
             ]
           }
  end

  test "admin GET /admin/users/search with no match returns an empty list" do
    seam(fn _query -> [] end)

    conn = build_admin_conn(:get, "/admin/users/search?q=zzqqxx") |> endpoint_call()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"users" => []}
  end

  test "missing q param is treated as a blank query (no crash, empty list)" do
    # UserSuggest gates blank/short queries to [] WITHOUT calling the searcher, so the
    # seam is never reached here — set it to a sentinel that would fail loudly if it were.
    seam(fn _query -> raise "searcher must not be called for a blank query" end)

    conn = build_admin_conn(:get, "/admin/users/search") |> endpoint_call()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"users" => []}
  end

  test "SECURITY authz — unauthenticated search is redirected to /admin/login, no JSON" do
    # No seam set: if the controller ran, it would hit the real searcher. require_admin
    # must short-circuit BEFORE the action — anonymous callers get no directory data.
    conn = build_anon_conn(:get, "/admin/users/search?q=al") |> endpoint_call()

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ "/admin/login"
    refute conn.resp_body =~ "user_id"
  end

  test "SECURITY SQLi — metacharacter query is forwarded verbatim (parameter-bound)" do
    # The term must reach the search layer UNMODIFIED (it is bound as a SQL parameter
    # there, never interpolated). Asserting the exact passthrough proves the controller
    # does not pre-build or interpolate any SQL of its own.
    malicious = "%' OR 1=1 --"
    seam(fn query ->
      assert query == malicious
      []
    end)

    conn =
      build_admin_conn(:get, "/admin/users/search?q=" <> URI.encode_www_form(malicious))
      |> endpoint_call()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"users" => []}
  end
end
