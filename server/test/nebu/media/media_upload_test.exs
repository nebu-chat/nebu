defmodule Nebu.Web.MediaUploadTest do
  @moduledoc """
  RED-phase ATDD tests for `media-gateway-migration` — AC1 (upload).

  PUT /_matrix/media/v3/upload:
    * authenticated upload stores the file (via the injected storage boundary)
      and returns 200 `%{"content_uri" => "mxc://<server>/<mediaId>"}`.
    * unauthenticated upload → 401 M_MISSING_TOKEN / M_UNKNOWN_TOKEN (OidcPlug).
    * body over the configured size limit → 413 M_TOO_LARGE (security: missing
      body-size limit, oracle MUST §7).
    * a blocked/disallowed content type is rejected (oracle inline allowlist).

  ## Why this MUST FAIL now

  No media route is wired into `Nebu.Web.Router` yet (only /_matrix/client/* and
  /health). PUT /_matrix/media/v3/upload currently falls through to the
  top-level `match _` → 404 "not found" (plain text), so every assertion below
  fails until `Nebu.Media` (forwarded as `Nebu.Web.Router.Media`) exists.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @upload_path "/_matrix/media/v3/upload"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("uploader", priv)

    # Point the storage boundary at our fake and capture what was stored.
    test_pid = self()

    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)

    Application.put_env(:nebu_http, :media_storage_put_fun, fn key, bytes ->
      send(test_pid, {:stored, key, bytes})
      :ok
    end)

    # F-1: upload now carries a per-IP rate limit (router/media.ex, burst 5). These
    # AC1 tests fire several uploads from the shared Plug.Test peer IP and are not
    # about throttling, so disable rate limiting here (the limiter is exercised by
    # rate_limit_test.exs / url_preview_test.exs F-1). Restore the prior value.
    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_storage_put_fun)
      Application.delete_env(:nebu_http, :media_max_upload_bytes)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token, user_id: uid}
  end

  defp put_upload(body, headers) do
    conn =
      conn(:put, @upload_path, body)
      |> Map.put(:req_headers, [])

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    Nebu.Web.Router.call(conn, S.router_opts())
  end

  # ── AC1 happy path ─────────────────────────────────────────────────────────

  test "authenticated PUT upload → 200 with mxc:// content_uri and file stored", %{token: token} do
    body = "\xFF\xD8\xFF\xE0jpeg-bytes"

    conn =
      put_upload(body, [
        {"content-type", "image/jpeg"} | S.auth(token)
      ])

    assert conn.status == 200,
           "expected 200 from PUT #{@upload_path}, got #{conn.status} — media upload route not implemented"

    body_json = S.json(conn)
    uri = body_json["content_uri"]
    assert is_binary(uri)

    # mxc://<server_name>/<media_id> (oracle §3)
    assert String.starts_with?(uri, "mxc://#{S.server_name()}/")
    media_id = uri |> String.replace_prefix("mxc://#{S.server_name()}/", "")
    assert media_id != "" and not String.contains?(media_id, "/")

    # The bytes must have reached the storage boundary.
    assert_received {:stored, _key, _stored_bytes}
  end

  # ── 401 unauthenticated (M_MISSING_TOKEN) ──────────────────────────────────

  test "PUT upload with NO Bearer token → 401 M_MISSING_TOKEN" do
    conn = put_upload("data", [{"content-type", "image/jpeg"}])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
  end

  test "PUT upload with a garbage Bearer token → 401 M_UNKNOWN_TOKEN" do
    conn =
      put_upload("data", [
        {"content-type", "image/jpeg"},
        {"authorization", "Bearer not-a-real-jwt"}
      ])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  # ── 413 body-size limit (M_TOO_LARGE) ──────────────────────────────────────

  test "PUT upload exceeding the configured size limit → 413 M_TOO_LARGE", %{token: token} do
    # Configure a tiny limit and send more than that.
    Application.put_env(:nebu_http, :media_max_upload_bytes, 16)
    big = :binary.copy("A", 1024)

    conn =
      put_upload(big, [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 413,
           "over-limit upload must return 413 M_TOO_LARGE, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_TOO_LARGE"
  end

  # ── F1/F3 — empty / truncated body must NOT be stored as a zero-byte object ──

  test "PUT upload with an EMPTY body → 400 M_UNKNOWN and nothing stored", %{token: token} do
    conn =
      put_upload("", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 400,
           "an empty upload body must be rejected with 400, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_UNKNOWN"

    # The storage boundary must NOT have been called for an empty body.
    refute_received {:stored, _key, _bytes}
  end

  # An application/json upload body is consumed (and capped) by the top-level
  # Plug.Parsers before reaching the handler, which then sees an empty body. That
  # must surface as a 400, never a stored zero-byte file returning 200 (F3).
  test "PUT upload with application/json content-type → empty body rejected, not stored", %{
    token: token
  } do
    conn =
      put_upload(~s({"hello":"world"}), [
        {"content-type", "application/json"} | S.auth(token)
      ])

    assert conn.status == 400,
           "a JSON-content-type upload (body eaten by Plug.Parsers) must be rejected, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_UNKNOWN"
    refute_received {:stored, _key, _bytes}
  end
end
