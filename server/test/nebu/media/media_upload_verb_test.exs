defmodule Nebu.Web.MediaUploadVerbTest do
  @moduledoc """
  RED-phase ATDD tests for `bugfix-fix-matrix-media-upload-post-verb`.

  Bug: `server/lib/nebu/web/router/media.ex:55` wires the classic one-shot
  upload endpoint as `put "/v3/upload"` instead of `post "/v3/upload"`. Per the
  Matrix Client-Server spec (and as sent by Element / matrix-js-sdk), this
  endpoint is `POST`. Because `Plug.Router` matches method + path exactly, a
  real client's `POST /_matrix/media/v3/upload` currently falls through to the
  generic 404 catch-all instead of reaching the already-implemented
  `Nebu.Media.upload/1` (`server/lib/nebu/media.ex:160`).

  This story is a ONE-LINE verb fix (`put` → `post`) — no change to
  `Media.upload/1`, no change to the `@upload_rate_limit` plug call.

  ## Coverage (story Acceptance Tests 1-4)

    1. `POST /_matrix/media/v3/upload` → 200, reaches `Media.upload/1`.
       RED now (falls through to 404 catch-all); GREEN once the router verb
       is `post`.
    2. `PUT /_matrix/media/v3/upload` → 405 `M_UNRECOGNIZED` + `Allow: POST, OPTIONS`
       (story oauth-room-summary-unrecognized (af): the router fall-through answers a known
       path with the wrong method as 405; it was the generic 404 `M_NOT_FOUND` catch-all).
    3. `PUT /_matrix/media/v3/upload/:server_name/:media_id` → unaffected.
       CORRECTED (fix-media-download-gzip-decompression, cycle 1): this route
       DOES exist — `put "/v3/upload/:server_name/:media_id"` in
       `Nebu.Web.Router.Media` dispatches to `Media.upload_async/3`
       (`server/lib/nebu/media.ex:343`). This test's setup fakes
       `:media_db_module` as `MediaFakes.DB`, whose `lookup_reservation/2`
       returns `{:error, :not_found}` by default with no matching row seeded
       — so `upload_async/3` itself returns 404 M_NOT_FOUND (its own
       no-reservation-found branch), not the router's generic catch-all. The
       assertion below is still a valid regression guard (the verb fix must
       not affect this distinct route or handler), just not via the
       mechanism originally documented here.
    4. Rate limiting (`@upload_rate_limit`, burst 5) still applies to the
       corrected `POST` route.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @upload_path "/_matrix/media/v3/upload"
  @async_upload_path "/_matrix/media/v3/upload/test.local/some-media-id"
  @rate_limit_table :nebu_http_rate_limit_buckets

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("uploader-verb", priv)

    test_pid = self()

    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
    Application.put_env(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)

    Application.put_env(:nebu_http, :media_storage_put_fun, fn key, bytes ->
      send(test_pid, {:stored, key, bytes})
      :ok
    end)

    # Default: rate limiting disabled so AC1-AC3 assertions are not incidentally
    # affected by the shared-IP bucket. The AC4 test below re-enables it
    # explicitly and uses its own dedicated remote_ip + a fresh ETS table.
    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_scan_enqueue_module)
      Application.delete_env(:nebu_http, :media_storage_put_fun)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token, user_id: uid}
  end

  defp request(method, path, body, headers) do
    conn =
      conn(method, path, body)
      |> Map.put(:req_headers, [])

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    Nebu.Web.Router.call(conn, S.router_opts())
  end

  # ── AC1 — POST /_matrix/media/v3/upload reaches Media.upload/1 ────────────

  test "AC1: authenticated POST upload -> 200 with mxc:// content_uri and file stored", %{
    token: token
  } do
    body = "\xFF\xD8\xFF\xE0jpeg-bytes"

    conn =
      request(:post, @upload_path, body, [
        {"content-type", "image/jpeg"} | S.auth(token)
      ])

    assert conn.status == 200,
           "expected 200 from POST #{@upload_path} (Media.upload/1 reached), " <>
             "got #{conn.status} — router still wired as `put \"/v3/upload\"` instead of `post`"

    body_json = S.json(conn)
    uri = body_json["content_uri"]
    assert is_binary(uri)
    assert String.starts_with?(uri, "mxc://#{S.server_name()}/")

    assert_received {:stored, _key, _stored_bytes}
  end

  # ── AC2 — PUT /_matrix/media/v3/upload no longer matches (405 M_UNRECOGNIZED) ──

  # story oauth-room-summary-unrecognized (af): changed deliberately. The route is `post`-only, so PUT on
  # the same path is "known endpoint, wrong method": 405 M_UNRECOGNIZED + Allow (was 404 M_NOT_FOUND).
  test "AC2: PUT /_matrix/media/v3/upload -> 405 M_UNRECOGNIZED + Allow: POST, OPTIONS, no longer an alias",
       %{token: token} do
    conn =
      request(:put, @upload_path, "data", [
        {"content-type", "image/jpeg"} | S.auth(token)
      ])

    assert conn.status == 405,
           "PUT #{@upload_path} must fall through to the 405 M_UNRECOGNIZED catch-all once the " <>
             "route is `post`-only, got #{conn.status} — the old PUT verb must not keep working " <>
             "as an undocumented alias"

    assert S.json(conn) == %{"errcode" => "M_UNRECOGNIZED", "error" => "Unsupported method"}

    assert conn
           |> Plug.Conn.get_resp_header("allow")
           |> List.first()
           |> String.split(",")
           |> Enum.map(&String.trim/1)
           |> Enum.sort() == ["OPTIONS", "POST"]

    refute_received {:stored, _key, _bytes}
  end

  # ── AC3 — PUT /v3/upload/:server_name/:media_id unaffected ────────────────

  test "AC3: PUT /_matrix/media/v3/upload/:server_name/:media_id is unaffected by the verb fix",
       %{token: token} do
    conn =
      request(:put, @async_upload_path, "data", [
        {"content-type", "image/jpeg"} | S.auth(token)
      ])

    # This route DOES exist (Media.upload_async/3) — it 404s here because
    # this test's faked MediaFakes.DB.lookup_reservation/2 finds no matching
    # reservation row, which is upload_async/3's own not-found branch, not
    # the router's generic catch-all. This test guards against the `/v3/upload`
    # verb fix accidentally widening its match to swallow this distinct path.
    assert conn.status == 404,
           "the async-upload-shaped path must keep 404ing (no reservation found), " <>
             "got #{conn.status} — the `/v3/upload` verb fix must not affect this distinct path"

    assert S.json(conn)["errcode"] == "M_NOT_FOUND"
  end

  # ── AC4 — rate limiting preserved on the corrected POST route ─────────────

  test "AC4: @upload_rate_limit (burst 5) still applies to POST /_matrix/media/v3/upload", %{
    token: token
  } do
    # Re-enable rate limiting for this test only (setup disables it above) and
    # use a dedicated remote_ip so this test's bucket cannot collide with any
    # other test file sharing the same named ETS table.
    Application.delete_env(:nebu_http, :rate_limit_disabled)

    if :ets.whereis(@rate_limit_table) != :undefined,
      do: :ets.delete_all_objects(@rate_limit_table)

    on_exit(fn ->
      if :ets.whereis(@rate_limit_table) != :undefined,
        do: :ets.delete_all_objects(@rate_limit_table)
    end)

    remote_ip = {203, 0, 113, 77}

    post_upload = fn ->
      conn =
        conn(:post, @upload_path, "\xFF\xD8\xFF\xE0jpeg-bytes")
        |> Map.put(:req_headers, [])
        |> Map.put(:remote_ip, remote_ip)

      conn =
        Enum.reduce([{"content-type", "image/jpeg"} | S.auth(token)], conn, fn {k, v}, acc ->
          put_req_header(acc, k, v)
        end)

      Nebu.Web.Router.call(conn, S.router_opts())
    end

    # Burst is 5 — five back-to-back requests from the same IP should pass.
    for i <- 1..5 do
      conn = post_upload.()

      assert conn.status == 200,
             "upload ##{i} (within burst 5) must pass, got #{conn.status}"
    end

    # The 6th request from the same IP within the same window must be
    # rate-limited, proving @upload_rate_limit is still wired on the corrected
    # POST route.
    blocked = post_upload.()

    assert blocked.status == 429,
           "the request past the upload burst must be rejected by @upload_rate_limit, " <>
             "got #{blocked.status} — rate limiting may have been dropped when fixing the verb"

    assert S.json(blocked)["errcode"] == "M_LIMIT_EXCEEDED"
  end
end
