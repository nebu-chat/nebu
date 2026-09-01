defmodule Nebu.Web.MediaUploadTest do
  @moduledoc """
  RED-phase ATDD tests for `media-gateway-migration` — AC1 (upload).

  POST /_matrix/media/v3/upload:
    * authenticated upload stores the file (via the injected storage boundary)
      and returns 200 `%{"content_uri" => "mxc://<server>/<mediaId>"}`.
    * unauthenticated upload → 401 M_MISSING_TOKEN / M_UNKNOWN_TOKEN (OidcPlug).
    * body over the configured size limit → 413 M_TOO_LARGE (security: missing
      body-size limit, oracle MUST §7).
    * a blocked/disallowed content type is rejected (oracle inline allowlist).

  ## Current status

  The media route is wired into `Nebu.Web.Router` (forwarded to
  `Nebu.Web.Router.Media`), so all tests below pass against the real route.

  NOTE (bugfix-fix-matrix-media-upload-post-verb): this route was originally
  wired as `put "/v3/upload"` (a spec-noncompliant verb) and this file's tests
  drove it via PUT. The router fix changed the verb to `post`; these tests were
  updated in the same change to drive the route via POST (matching Element /
  matrix-js-sdk and the Matrix Client-Server spec) so they do not regress to a
  404 self-inflicted by the verb fix.
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

    # Pin the DB boundary to the fake explicitly (mirrors every sibling
    # media_*_test.exs file's convention). MediaFakes.DB has no insert/1, so
    # Nebu.Media's function_exported?/3 guard in insert_media_row/7 no-ops the
    # DB write — this test only asserts on the storage boundary/content_uri.
    # Previously this relied on the IMPLICIT default (:media_db_module unset
    # -> real Nebu.Media.DB), which only worked by accident: function_exported?/3
    # returns false for a real module that has not yet been *loaded* into the
    # VM in this test run, so it silently no-op'd only as long as nothing else
    # in the suite had referenced Nebu.Media.DB directly yet. The first test
    # anywhere that calls into the real module (e.g. a direct unit test of a
    # DB.ex helper) loads it for the rest of the run, flips function_exported?
    # to true, and this test then hits the real (unstarted, no NEBU_DB_URL)
    # Nebu.Repo. Pinning the fake here removes that ordering dependency.
    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)

    # 2c-sync-upload-shared-pipeline infra upkeep: once store_upload/4 is
    # refactored to create its media_files row via Nebu.Media.StateMachine
    # (AC1) instead of the old insert_media_row/7 path, the default
    # :media_state_machine_module resolves to the REAL Nebu.Media.StateMachine
    # (a live-Postgres-backed module — see server/lib/nebu/media/
    # state_machine.ex). Without pinning it here, this file's tests would
    # start hitting an unstarted/unconfigured Nebu.Repo the moment the
    # refactor lands. Pinning the fake (which has a harmless default-success
    # fallback for the not-yet-existing create_quarantined/1 seam) keeps this
    # file's pre-existing assertions (which only care about the storage
    # boundary/response contract, not the state-machine seam) working
    # unmodified, exactly like media_async_upload_test.exs/media_create_test.exs
    # already pin this module for the same reason.
    Application.put_env(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
    Application.put_env(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)

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
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_scan_enqueue_module)
      Application.delete_env(:nebu_http, :media_storage_put_fun)
      Application.delete_env(:nebu_http, :media_db_insert_fun)
      Application.delete_env(:nebu_http, :media_state_machine_create_quarantined_fun)
      Application.delete_env(:nebu_http, :media_scan_enqueue_fun)
      Application.delete_env(:nebu_http, :media_max_upload_bytes)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token, user_id: uid}
  end

  defp post_upload(body, headers) do
    conn =
      conn(:post, @upload_path, body)
      |> Map.put(:req_headers, [])

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    Nebu.Web.Router.call(conn, S.router_opts())
  end

  # ── AC1 happy path ─────────────────────────────────────────────────────────

  test "authenticated POST upload → 200 with mxc:// content_uri and file stored", %{token: token} do
    body = "\xFF\xD8\xFF\xE0jpeg-bytes"

    conn =
      post_upload(body, [
        {"content-type", "image/jpeg"} | S.auth(token)
      ])

    assert conn.status == 200,
           "expected 200 from POST #{@upload_path}, got #{conn.status} — media upload route not implemented"

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

  test "POST upload with NO Bearer token → 401 M_MISSING_TOKEN" do
    conn = post_upload("data", [{"content-type", "image/jpeg"}])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
  end

  test "POST upload with a garbage Bearer token → 401 M_UNKNOWN_TOKEN" do
    conn =
      post_upload("data", [
        {"content-type", "image/jpeg"},
        {"authorization", "Bearer not-a-real-jwt"}
      ])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  # ── 413 body-size limit (M_TOO_LARGE) ──────────────────────────────────────

  test "POST upload exceeding the configured size limit → 413 M_TOO_LARGE", %{token: token} do
    # Configure a tiny limit and send more than that.
    Application.put_env(:nebu_http, :media_max_upload_bytes, 16)
    big = :binary.copy("A", 1024)

    conn =
      post_upload(big, [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 413,
           "over-limit upload must return 413 M_TOO_LARGE, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_TOO_LARGE"
  end

  # ── F1/F3 — empty / truncated body must NOT be stored as a zero-byte object ──

  test "POST upload with an EMPTY body → 400 M_UNKNOWN and nothing stored", %{token: token} do
    conn =
      post_upload("", [
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
  test "POST upload with application/json content-type → empty body rejected, not stored", %{
    token: token
  } do
    conn =
      post_upload(~s({"hello":"world"}), [
        {"content-type", "application/json"} | S.auth(token)
      ])

    assert conn.status == 400,
           "a JSON-content-type upload (body eaten by Plug.Parsers) must be rejected, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_UNKNOWN"
    refute_received {:stored, _key, _bytes}
  end

  # ── @blocked_upload_types regression guard (story 9c test-review MAJOR) ────
  #
  # `@blocked_upload_types` (stored-XSS-vector types, hardcoded, non-admin-
  # editable) is a SEPARATE mechanism from story 9c's admin-configurable
  # `mime_denylist` (Nebu.Media.Config) — see that story's Dev Agent
  # Guardrails: the two lists must remain independently active and must never
  # be merged. This module's moduledoc (line 11) already claimed "a
  # blocked/disallowed content type is rejected" as covered, but no test
  # actually exercised it until now — this closes that gap so a future
  # refactor cannot silently fold the two lists together (or drop this one)
  # without a test failing.
  test "POST upload with a @blocked_upload_types content type (text/html) → 400 M_BAD_JSON, nothing stored",
       %{token: token} do
    conn =
      post_upload("<script>alert(1)</script>", [
        {"content-type", "text/html"} | S.auth(token)
      ])

    assert conn.status == 400,
           "a blocked (stored-XSS-vector) content type must be rejected with 400, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_BAD_JSON"
    assert S.json(conn)["error"] == "Content-Type not permitted for upload"

    # No bytes reach the storage boundary for a blocked content type.
    refute_received {:stored, _key, _bytes}
  end
end
