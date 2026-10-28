defmodule Nebu.Admin.ConfigControllerTest do
  @moduledoc """
  RED-phase ATDD tests for story `fix-and-configure-sso-redirect-schemes`, AC9 + AC5.

  ## What is under test

  ### AC9 — POST /admin/config/sso-schemes validates + persists sso_extra_redirect_schemes

  A new `Nebu.Admin.ConfigController.save_sso_schemes/2` action (mirrors
  `save_scopes/2` in `config_controller.ex`) handles `POST /admin/config/sso-schemes`.
  It validates each comma-separated scheme token per AC5 (RFC 3986 syntax +
  denylist + non-empty) and persists valid values to `server_config` under the
  `sso_extra_redirect_schemes` key.

  ### AC5 — Admin UI input validation rules

  1. RFC 3986 scheme syntax: `[A-Za-z][A-Za-z0-9+.-]*`.
  2. Denylist check, case-insensitive (javascript, data, file, vbscript, blob).
  3. Empty/whitespace-only tokens are rejected.

  ## Why these tests are RED

  1. `Nebu.Admin.ConfigController.save_sso_schemes/2` does not exist yet →
     UndefinedFunctionError / Phoenix action clause error.
  2. The route `post "/config/sso-schemes", ConfigController, :save_sso_schemes`
     does not exist in the router yet → 404.
  3. `validate_sso_schemes/1` and `persist_sso_schemes/1` helpers do not exist yet.

  ## Auth strategy

  Mirrors `config_scopes_test.exs`: build a signed admin session conn, call
  `Nebu.Admin.Endpoint.call/2` directly. Same `@endpoint`/`@secret_key_base`
  convention as the sibling scopes test file.

  ## Test seams

  * `:admin_csrf_bypass` — skip CSRF protection for POST requests in tests
    (existing seam, reused unchanged).
  * `:admin_config_sso_schemes_writer` — injectable fn(changes :: map) ->
    :ok | {:error, _} for the POST /admin/config/sso-schemes write path.
    Mirrors `:admin_config_scopes_writer`. The dev agent must wire this seam
    into `persist_sso_schemes/1` (mirrors `persist_scopes/1`).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-sso-schemes-test-key-b", 2)

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    on_exit(fn ->
      for k <- [
            :admin_csrf_bypass,
            :admin_config_sso_schemes_writer
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-1",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp post_sso_schemes(value) do
    # story sso-origins-admin-hardening: the strict fetch metadata of a form submit and a fresh re-authentication marker
    build_admin_conn(:post, "/admin/config/sso-schemes")
    |> put_session("admin_reauth", Nebu.OAuth.TestSupport.fresh_marker("admin-1", 0, "auth_time", "/admin/config"))
    |> Nebu.OAuth.TestSupport.put_strict_fetch_headers()
    |> Map.put(:body_params, %{"sso_extra_redirect_schemes" => value})
    |> endpoint_call()
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — POST /admin/config/sso-schemes: route exists and save_sso_schemes/2 works
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9: POST /admin/config/sso-schemes persists valid scheme values" do
    test "valid comma-separated scheme list is persisted and redirects to /admin/config" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("myorg-matrix, custom-app")

      assert conn.status == 302,
             "Valid SSO schemes POST must redirect (302); got #{conn.status}\n#{conn.resp_body}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/config",
             "Must redirect to /admin/config; got: #{location}"

      assert_received {:sso_schemes_written, changes}

      assert changes["sso_extra_redirect_schemes"] == "myorg-matrix, custom-app",
             "Persisted value must match trimmed submitted string; got: #{inspect(changes)}"
    end

    test "persisted value normalizes interior whitespace between tokens, not just the outer string" do
      # Code-review finding: validate_sso_schemes/1 validates per-token-trimmed
      # values, but an earlier implementation persisted only String.trim/1 on the
      # WHOLE raw string, leaving interior whitespace between tokens intact in
      # server_config (e.g. "element,   custom-app" instead of the normalized
      # "element, custom-app"). Not a security bypass (the read side re-trims
      # independently) but a real deviation from AC4's "space-trimmed" storage
      # format and a confusing round-trip in the Admin UI (the raw, messy string
      # would be redisplayed verbatim in the form's value=).
      #
      # NOTE: this uses only cosmetic space padding around commas, NOT an
      # embedded/trailing "\n" — a token with a newline is a DIFFERENT case
      # (an invalid RFC 3986 token, correctly REJECTED — see the "\\z anchor"
      # describe block below, which covers that scenario instead of this one).
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("element,   custom-app  ,schildichat")

      assert conn.status == 302,
             "Valid (if messily-formatted) SSO schemes POST must redirect (302); got #{conn.status}\n#{conn.resp_body}"

      assert_received {:sso_schemes_written, changes}

      assert changes["sso_extra_redirect_schemes"] == "element, custom-app, schildichat",
             "Persisted value must be fully normalized (each token trimmed, rejoined with \", \"), " <>
               "not just outer-trimmed; got: #{inspect(changes["sso_extra_redirect_schemes"])}"
    end

    test "route POST /admin/config/sso-schemes exists (not 404/405)" do
      conn = post_sso_schemes("myorg-matrix")

      refute conn.status == 404,
             "POST /admin/config/sso-schemes must be a registered route (got 404 — route missing)"

      refute conn.status == 405,
             "POST /admin/config/sso-schemes must accept POST method (got 405 — method not allowed)"
    end

    test "empty scheme string persists empty string (operator clears custom schemes, falls back to defaults)" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("")

      assert conn.status == 302,
             "Empty SSO schemes value is valid input (clears custom schemes); got #{conn.status}"

      assert_received {:sso_schemes_written, changes}
      assert changes["sso_extra_redirect_schemes"] == ""
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 / AC9 — Server-side validation: invalid RFC 3986 syntax rejected
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5: RFC 3986 scheme syntax validation" do
    test "invalid RFC 3986 token (starts with a digit) is rejected with 200 re-render, no DB write" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("1invalid-scheme")

      assert conn.status == 200,
             "Invalid RFC 3986 scheme token must return 200 re-render (no redirect); got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|not a valid|RFC 3986/i,
             "Error message about invalid RFC 3986 scheme expected; got:\n#{conn.resp_body}"

      refute_received {:sso_schemes_written, _},
                       "Invalid input must NOT reach the persistence writer (no DB write)"
    end

    test "invalid RFC 3986 token (contains an illegal character) is rejected" do
      conn = post_sso_schemes("my org matrix!")

      assert conn.status == 200,
             "Scheme token with illegal characters must return 200 re-render; got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|not a valid|RFC 3986/i
    end

    test "valid scheme with allowed punctuation (plus, dash, dot) is accepted" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("im.fluffychat.auth, my-org+app")

      assert conn.status == 302,
             "RFC 3986-valid scheme tokens (dot/dash/plus) must be accepted; got #{conn.status}\n#{conn.resp_body}"

      assert_received {:sso_schemes_written, changes}
      assert changes["sso_extra_redirect_schemes"] == "im.fluffychat.auth, my-org+app"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — \z anchor — trailing newline is rejected, not just embedded newline
  #
  # Mirrors Nebu.Web.OidcScopes's own regression test (server/test/nebu/web/
  # oidc_scopes_test.exs, "AC7: \\z anchor — trailing newline is rejected").
  # Code review caught @scheme_regex initially anchored with $ instead of \z —
  # PCRE/Erlang :re $ matches immediately before a trailing "\n", so a
  # $-anchored whitelist regex wrongly ACCEPTS a token like "element\n" even
  # though it contains a control character. \z only matches the true end of
  # the string. This is an established codebase rule since the
  # configurable-oidc-scopes security review; @scheme_regex must follow it too.
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5: \\z anchor — trailing newline is rejected, not just embedded newline" do
    test "a scheme token with a trailing newline is rejected" do
      conn = post_sso_schemes("element\n")

      assert conn.status == 200,
             "A scheme token with a trailing '\\n' must be rejected (200 re-render), not accepted " <>
               "(a regex anchored with $ instead of \\z would wrongly accept this — PCRE/Erlang :re " <>
               "$ matches before a trailing \\n); got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|not a valid|RFC 3986/i,
             "Error message about invalid RFC 3986 scheme expected; got:\n#{conn.resp_body}"
    end

    test "a scheme token with an embedded newline is rejected" do
      conn = post_sso_schemes("ele\nment")

      assert conn.status == 200,
             "A scheme token with an embedded newline must be rejected; got #{conn.status}"
    end

    test "a plain valid multi-token scheme string is accepted (no false positive from the anchor fix)" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("element, schildichat")

      assert conn.status == 302,
             "A plain valid scheme string must still be accepted after the \\z anchor fix; got #{conn.status}\n#{conn.resp_body}"

      assert_received {:sso_schemes_written, changes}
      assert changes["sso_extra_redirect_schemes"] == "element, schildichat"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 / AC9 — Server-side validation: denylist collision rejected (case-insensitive)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5: denylist collision validation (case-insensitive)" do
    test "denylisted scheme 'javascript' is rejected with 200 re-render, no DB write" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("javascript")

      assert conn.status == 200,
             "Denylisted scheme must return 200 re-render (no redirect); got #{conn.status}"

      assert conn.resp_body =~ ~r/blocked|denylist|not allowed/i,
             "Error message about blocked scheme expected; got:\n#{conn.resp_body}"

      refute_received {:sso_schemes_written, _},
                       "Denylisted scheme submission must NOT reach the persistence writer"
    end

    test "denylist check is case-insensitive — 'JavaScript' is also rejected" do
      conn = post_sso_schemes("JavaScript")

      assert conn.status == 200,
             "Denylist check must be case-insensitive; 'JavaScript' must be rejected; got #{conn.status}"

      assert conn.resp_body =~ ~r/blocked|denylist|not allowed/i
    end

    test "denylisted scheme mixed into an otherwise-valid list rejects the whole submission" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("myorg-matrix, DATA, custom-app")

      assert conn.status == 200,
             "A denylisted token anywhere in the list must reject the entire submission; got #{conn.status}"

      refute_received {:sso_schemes_written, _},
                       "No partial persistence allowed when any token is denylisted"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 / AC9 — Server-side validation: empty/whitespace token in list rejected
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5: empty/whitespace token validation" do
    test "a blank token within a comma-separated list is rejected" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_sso_schemes_writer, fn changes ->
        send(test_pid, {:sso_schemes_written, changes})
        :ok
      end)

      conn = post_sso_schemes("myorg-matrix,, custom-app")

      assert conn.status == 200,
             "An empty token in the list must return 200 re-render; got #{conn.status}"

      assert conn.resp_body =~ ~r/empty/i,
             "Error message about an empty scheme expected; got:\n#{conn.resp_body}"

      refute_received {:sso_schemes_written, _}
    end

    test "a whitespace-only token within a comma-separated list is rejected" do
      conn = post_sso_schemes("myorg-matrix,   , custom-app")

      assert conn.status == 200,
             "A whitespace-only token in the list must return 200 re-render; got #{conn.status}"

      assert conn.resp_body =~ ~r/empty/i
    end
  end
end
