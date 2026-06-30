defmodule Nebu.Admin.ConfigScopesTest do
  @moduledoc """
  RED-phase ATDD tests for story `configurable-oidc-scopes`, AC7 + AC8.

  ## What is under test

  ### AC7 — GET /admin/config shows scopes

  The Admin Config page (`GET /admin/config`) must display the current values of
  `matrix_oidc_extra_scopes` and `admin_oidc_extra_scopes` from `server_config`.
  Today these keys do NOT appear in the rendered config table because they are not
  written to `server_config` at bootstrap. RED until:
    * Bootstrap promotion writes both keys into `server_config`.
    * ConfigController.load_config/0 consults the `:admin_server_config_reader` seam.

  ### AC8 — POST /admin/config/scopes validates + persists scope values

  A new `ConfigController.save_scopes/2` action (analog to `save_refresh_mode/2`)
  handles `POST /admin/config/scopes`. It validates the submitted scope strings
  against `[a-zA-Z0-9_:.-]` and persists valid values to `server_config`.
  The route `post "/config/scopes", ConfigController, :save_scopes` does NOT exist yet.

  ## Why these tests are RED

  1. The `POST /admin/config/scopes` route is missing from the router → 404.
  2. `ConfigController.save_scopes/2` does not exist → UndefinedFunctionError.
  3. `ConfigController.load_config/0` does not consult `:admin_server_config_reader` seam.

  ## Auth strategy

  Mirrors `admin_http_controllers_test.exs`: build a signed admin session conn,
  call `Nebu.Admin.Endpoint.call/2` directly.

  ## Test seams

  * `:admin_csrf_bypass` — skip CSRF protection for POST requests in tests.
  * `:admin_config_scopes_writer` — injectable fn(changes :: map) → :ok | {:error, _}
    for the POST /admin/config/scopes write path (mirrors `:admin_config_refresh_mode_writer`).
  * `:admin_server_config_reader` — injectable fn() → {:ok, [{key, value}]} | {:error, _}
    for ConfigController.load_config/0 read path. The dev agent must add this seam to
    load_config/0 (checked BEFORE the Nebu.Repo path). Avoids DB dependency in unit tests.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-scopes-test-key-base-!!", 2)

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    on_exit(fn ->
      for k <- [
            :admin_csrf_bypass,
            :admin_config_scopes_writer,
            :admin_server_config_reader
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

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — GET /admin/config shows matrix_oidc_extra_scopes and admin_oidc_extra_scopes
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7: GET /admin/config renders scope keys from server_config" do
    test "config page shows matrix_oidc_extra_scopes when present in server_config" do
      # Inject the `:admin_server_config_reader` seam so load_config/0 returns
      # pre-populated scope rows without a live DB.
      # The dev agent must add this seam to ConfigController.load_config/0:
      #   case Application.get_env(:nebu_http, :admin_server_config_reader) do
      #     reader when is_function(reader, 0) -> reader.()
      #     _ -> (existing Nebu.Repo path)
      #   end
      Application.put_env(:nebu_http, :admin_server_config_reader, fn ->
        {:ok,
         [
           {"admin_oidc_extra_scopes", "profile email groups"},
           {"matrix_oidc_extra_scopes", "profile email"}
         ]}
      end)

      conn =
        build_admin_conn(:get, "/admin/config")
        |> endpoint_call()

      assert conn.status == 200
      html = conn.resp_body

      assert html =~ "matrix_oidc_extra_scopes",
             "GET /admin/config must show matrix_oidc_extra_scopes row; got:\n#{html}"

      assert html =~ "admin_oidc_extra_scopes",
             "GET /admin/config must show admin_oidc_extra_scopes row; got:\n#{html}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — POST /admin/config/scopes: route exists and save_scopes/2 handler works
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8: POST /admin/config/scopes persists valid scope values" do
    test "valid scope values are persisted and redirect to /admin/config" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_scopes_writer, fn changes ->
        send(test_pid, {:scopes_written, changes})
        :ok
      end)

      conn =
        build_admin_conn(:post, "/admin/config/scopes")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email",
          "admin_oidc_extra_scopes" => "profile email groups"
        })
        |> endpoint_call()

      assert conn.status == 302,
             "Valid scopes POST must redirect (302); got #{conn.status}\n#{conn.resp_body}"

      [location] = get_resp_header(conn, "location")
      assert location == "/admin/config",
             "Must redirect to /admin/config; got: #{location}"

      assert_received {:scopes_written, changes}
      assert changes["matrix_oidc_extra_scopes"] == "profile email"
      assert changes["admin_oidc_extra_scopes"] == "profile email groups"
    end

    test "invalid scope characters cause 200 re-render with error" do
      conn =
        build_admin_conn(:post, "/admin/config/scopes")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email!",
          "admin_oidc_extra_scopes" => "profile email groups"
        })
        |> endpoint_call()

      # Invalid value → must NOT redirect, must re-render (200) with error.
      # Matches the established save_refresh_mode/2 pattern (200 re-render, no 422).
      assert conn.status == 200,
             "Invalid scope must return 200 re-render; got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i,
             "Error about invalid scope characters expected; got:\n#{conn.resp_body}"
    end

    test "scope value with embedded newline is rejected with 200 re-render" do
      conn =
        build_admin_conn(:post, "/admin/config/scopes")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile\nemail",
          "admin_oidc_extra_scopes" => "profile email groups"
        })
        |> endpoint_call()

      assert conn.status == 200,
             "Embedded newline in scope must return 200 re-render; got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i
    end

    test "scope value with trailing newline is rejected with 200 re-render" do
      conn =
        build_admin_conn(:post, "/admin/config/scopes")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email\n",
          "admin_oidc_extra_scopes" => "profile email groups"
        })
        |> endpoint_call()

      assert conn.status == 200,
             "Trailing newline in scope must return 200 re-render (\\z anchor required); got #{conn.status}"

      assert conn.resp_body =~ ~r/invalid|Invalid|scope/i
    end

    test "empty scope values are accepted (valid, no invalid chars) and redirect" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_scopes_writer, fn changes ->
        send(test_pid, {:scopes_written, changes})
        :ok
      end)

      # Empty string contains no invalid chars — controller persists and redirects.
      # Runtime scope_list/0 and admin_oidc_scope/0 fall back to their defaults
      # when the DB value is empty.
      conn =
        build_admin_conn(:post, "/admin/config/scopes")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "",
          "admin_oidc_extra_scopes" => ""
        })
        |> endpoint_call()

      assert conn.status == 302,
             "Empty scope values must redirect (valid input); got #{conn.status}"
    end

    test "route POST /admin/config/scopes exists (not 404/405)" do
      conn =
        build_admin_conn(:post, "/admin/config/scopes")
        |> Map.put(:body_params, %{
          "matrix_oidc_extra_scopes" => "profile email",
          "admin_oidc_extra_scopes" => "profile email groups"
        })
        |> endpoint_call()

      refute conn.status == 404,
             "POST /admin/config/scopes must be a registered route (got 404 — route missing)"

      refute conn.status == 405,
             "POST /admin/config/scopes must accept POST method (got 405 — method not allowed)"
    end
  end
end
