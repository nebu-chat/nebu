defmodule Nebu.Admin.UsersIndexLinkTest do
  @moduledoc """
  RED-phase ATDD acceptance tests for the `device-management` bugfix story,
  Bug 1 — Admin UI Link.

  ## What is tested here

  AC1/AC2/AC3/AC4 from the story:

    * AC1 — GET /admin/users renders each user_id as a hyperlink <a> pointing
             to /admin/users/<uri-encoded-user_id>
    * AC2 — Clicking the link (i.e. the href value) points to the user detail
             page (/admin/users/:user_id) — covered by verifying the href value
    * AC3 — The link is keyboard-navigable (a standard <a href> element, no JS
             required). Asserted by the presence of a plain <a href="..."> tag.
    * AC4 — user_ids containing URL-unsafe characters (e.g. "@user:localhost")
             are correctly percent-encoded in the href attribute.

  ## Why these MUST FAIL NOW (RED)

  The current `index.html.heex` template renders user_id as a plain text cell:

      <td>{user.user_id}</td>

  There is NO <a href=...> wrapping the user_id. Every assertion checking for
  an anchor element in the rendered HTML will fail until the dev step wraps
  the cell content in:

      <a href={"/admin/users/" <> URI.encode(user.user_id, &URI.char_unreserved?(&1))} ...>

  ## Auth strategy

  Mirrors admin_http_controllers_test.exs and device_management_test.exs:
  build a signed admin-session conn via `build_admin_conn/2` (real endpoint
  session plug), call `Nebu.Admin.Endpoint.call/2` directly.

  ## Test seams

  The UsersController reads users from the DB via inline SQL (ADR-018). For
  unit tests we override the `:admin_users_loader` app-env key so no live
  Postgres is required. The controller's production path calls the real DB
  when the seam is absent.

  ## Crash/restart — NOT APPLICABLE

  HTTP controllers are stateless (Persistenz Option C). No GenServer.
  """
  # async: false — uses Application.put_env; cannot run concurrently
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)

  @admin "@admin:test.local"

  # ── Session helpers (mirror device_management_test.exs) ─────────────────────

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

  defp endpoint_call(conn) do
    @endpoint.call(conn, @endpoint.init([]))
  end

  defp enc(id), do: URI.encode(id, &URI.char_unreserved?(&1))

  defp restore_env(key, nil), do: Application.delete_env(:nebu_http, key)
  defp restore_env(key, val), do: Application.put_env(:nebu_http, key, val)

  # Set up CSRF bypass and a fake users loader before each test.
  setup do
    # Save + restore the prior value rather than delete_env: the test baseline
    # (config/test.exs) is `admin_csrf_bypass: true`; `delete_env` would drop it to the
    # `false` default and leak CSRF enforcement into admin tests that run LATER in the full
    # suite (order/seed-dependent → spurious InvalidCSRFTokenError).
    prior_csrf = Application.get_env(:nebu_http, :admin_csrf_bypass)
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    on_exit(fn ->
      restore_env(:admin_csrf_bypass, prior_csrf)
      Application.delete_env(:nebu_http, :admin_users_loader)
    end)

    :ok
  end

  # ── AC1 + AC3: user_id rendered as <a href> (keyboard-navigable) ─────────────

  test "AC1/AC3 — GET /admin/users renders each user_id as a hyperlink <a href>" do
    # RED: the index template has <td>{user.user_id}</td>, no <a> wrapper.
    # This test will fail until the dev wraps the cell in an anchor.
    Application.put_env(:nebu_http, :admin_users_loader, fn ->
      [
        %{user_id: "@alice:test.local", role: "user", is_active: true}
      ]
    end)

    conn = build_admin_conn(:get, "/admin/users") |> endpoint_call()

    assert conn.status == 200
    body = conn.resp_body

    # The user_id must appear inside an anchor tag, not bare text.
    assert body =~ ~r/<a\s[^>]*href=[^>]*>/i,
           "expected at least one <a href=...> element on the users index page"

    # The href must point to the user detail page.
    assert body =~ "/admin/users/",
           "expected href to contain /admin/users/ path prefix"
  end

  # ── AC2: href value leads to the user detail page ─────────────────────────────

  test "AC2 — the href in the users index points to /admin/users/<encoded_user_id>" do
    # RED: no <a href> exists yet, so this href pattern will not be found.
    user_id = "@bob:test.local"

    Application.put_env(:nebu_http, :admin_users_loader, fn ->
      [%{user_id: user_id, role: "user", is_active: true}]
    end)

    conn = build_admin_conn(:get, "/admin/users") |> endpoint_call()

    assert conn.status == 200
    expected_href = "/admin/users/" <> enc(user_id)

    assert conn.resp_body =~ expected_href,
           "expected href=\"#{expected_href}\" in the rendered page"
  end

  # ── AC4: URL-unsafe characters in user_id are percent-encoded ────────────────

  test "AC4 — user_id '@testuser:localhost' is percent-encoded as %40testuser%3Alocalhost in the href" do
    # RED: no <a href> exists yet; the user_id is rendered as bare text, not
    # percent-encoded inside an anchor href.
    user_id = "@testuser:localhost"
    encoded = enc(user_id)
    # enc/1 uses URI.char_unreserved?/1, so '@' → %40 and ':' → %3A.
    # Verify the helper produces the expected encoding before asserting.
    assert encoded == "%40testuser%3Alocalhost",
           "test helper enc/1 must produce %40testuser%3Alocalhost for @testuser:localhost"

    Application.put_env(:nebu_http, :admin_users_loader, fn ->
      [%{user_id: user_id, role: "user", is_active: true}]
    end)

    conn = build_admin_conn(:get, "/admin/users") |> endpoint_call()

    assert conn.status == 200

    expected_href = "/admin/users/" <> encoded

    assert conn.resp_body =~ expected_href,
           "expected href=\"#{expected_href}\" — '@' and ':' must be percent-encoded"

    # The raw unencoded user_id must NOT appear inside an href attribute value.
    # (It may still appear as link text, which is fine; we only reject it as an href.)
    refute conn.resp_body =~ ~r/href="[^"]*@testuser:localhost/,
           "the raw user_id with '@' and ':' must not appear unencoded inside an href"
  end

  # ── AC1: multiple users all get hyperlinks ────────────────────────────────────

  test "AC1 — every user row in the table has an anchor link for their user_id" do
    # RED: no rows have <a href> links yet.
    users = [
      %{user_id: "@alice:test.local", role: "admin", is_active: true},
      %{user_id: "@bob:test.local", role: "user", is_active: false},
      %{user_id: "@carol:test.local", role: "user", is_active: true}
    ]

    Application.put_env(:nebu_http, :admin_users_loader, fn -> users end)

    conn = build_admin_conn(:get, "/admin/users") |> endpoint_call()

    assert conn.status == 200
    body = conn.resp_body

    # Each user must have their own detail-page link.
    for user <- users do
      expected_href = "/admin/users/" <> enc(user.user_id)

      assert body =~ expected_href,
             "expected href=\"#{expected_href}\" for user #{user.user_id}"
    end
  end
end
