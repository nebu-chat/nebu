defmodule Nebu.Web.MediaAsyncUploadTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/2b-put-media-upload`.

  `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` — the async-upload
  companion to the existing synchronous `PUT /_matrix/media/v3/upload`
  (Matrix v1.7+, core-stable, no MSC label). Validates the reservation
  created earlier via `POST /_matrix/media/v1/create` (Story 2a) and, on
  success, runs the shared persist-transition-enqueue seam (hash -> compress
  -> encrypt -> S3 write -> persist -> transition `:reserved -> :quarantined`
  -> enqueue scan job).

  ## Why this MUST FAIL now

  No route for `PUT /_matrix/media/v3/upload/:server_name/:media_id` exists
  yet in `Nebu.Web.Router.Media` — every request below falls through to that
  router's `match _` catch-all (plain 404 `{"errcode": "M_NOT_FOUND", "error":
  "Unrecognized request"}`), never the real 200/403/404/409/413/400 bodies
  asserted here. This stays RED until the dev-story wires the route,
  `Nebu.Media.upload_async/3`, the `lookup_reservation/2`/`persist_upload/1`
  DB seams, and the shared persist-transition-enqueue seam.

  ## Coordinator-resolved schema gaps (see the story's own Dev Agent Record,
  section "Scope Adaptation", 2026-07-14)

    * There is NO persisted `unused_expires_at` column. Expiry is derived
      live as `row.uploaded_at + unused_expires_ms() < System.system_time(
      :millisecond)`. Tests below seed `uploaded_at` (ms-epoch) directly on
      the fake reservation row — never a fictitious `unused_expires_at` key.
    * `filename` IS a real column now (migration `000025`, coordinator-
      approved guardrail exception) — tests assert it round-trips through
      the persist seam.
    * The row's ownership field is `uploader_user_id` (not `uploader_id` —
      that name was a typo in the story's original draft).

  ## New test seams introduced by this story (added to `media_fakes.exs`)

    * `:media_lookup_reservation_fun`       — `MediaFakes.DB.lookup_reservation/2`,
      a reservation-capable lookup returning `uploader_user_id`/`state`/
      `uploaded_at` for ANY state (not just `:reserved` — AC3/AC5 need to
      distinguish 403 from 409 for non-`:reserved` rows too).
    * `:media_persist_upload_fun`           — `MediaFakes.DB.persist_upload/1`,
      the write-side counterpart: persists `storage_key`/`file_hash`/
      `compressed`/`content_type`/`filename`/key material onto the row. This
      seam is a dev-story-time addition beyond the story's own literal File
      List (which only names `lookup_reservation/2`) — the story's Technical
      Requirements step 6 explicitly requires persisting these fields
      "through `Nebu.Media.StateMachine`", but `transition/4`'s only
      metadata channel is the `media_state_transitions` JSONB ledger column,
      NOT the `media_files` row itself, so a distinct `media_files` UPDATE
      is required. Naming this `persist_upload/1` is this ATDD pass's design
      decision — the dev agent may rename it, but SOME such seam is required
      for AC8's persisted-field assertions to be observable at all.
    * `:media_state_machine_transition_fun` — `MediaFakes.StateMachine.transition/4`
      (the existing fake only covered `create/1` from Story 2a).
    * `:media_scan_enqueue_fun`             — `MediaFakes.ScanEnqueue.enqueue/1`.
      Oban is NOT a dependency of this codebase yet (Story 4b introduces it
      later) — this is an injectable, no-op/log-only-until-4b-lands seam
      identifying the media_id, per this story's own File List note ("add
      an Oban-enqueue fake seam if Story 4b's worker module isn't landed yet
      at this story's dev time"). Do NOT assert against
      `Oban.Testing.assert_enqueued/2` — that API does not exist in this
      codebase.

  ## Wiring assertions for previously-standalone dependencies

  This story is the FIRST caller of three units that shipped standalone/
  unwired in earlier stories of this epic:

    * `Nebu.Media.mime_denylist_rejected?/1` (Story 9c) — see the
      "mime_denylist wiring" test below.
    * `Nebu.Media.Storage.compress/1` (Story 12) — see the "file_hash /
      compression" test below.
    * `Nebu.Media.StorageConfig.compute_key/2` (Story 11c) — see the
      "storage key template wiring" test below. The Guardrails' "flat
      media_id fallback ... until 11c lands" and 11c's own wiring
      instruction are NOT in conflict: 11c's own default
      `s3_key_prefix_template` is `"{media_id}"`, which `compute_key/2`
      interpolates to the exact same flat key — so calling `compute_key/2`
      with the (unconfigured) default template already IS the flat
      fallback.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @base_path "/_matrix/media/v3/upload"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("uploader", priv)
    {other_uid, other_token} = S.bearer_for("someone-else", priv)

    test_pid = self()

    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)
    Application.put_env(:nebu_http, :media_scan_enqueue_module, MediaFakes.ScanEnqueue)

    Application.put_env(:nebu_http, :media_storage_put_fun, fn key, bytes ->
      send(test_pid, {:stored, key, bytes})
      :ok
    end)

    Application.put_env(:nebu_http, :media_persist_upload_fun, fn fields ->
      send(test_pid, {:persisted, fields})
      :ok
    end)

    Application.put_env(:nebu_http, :media_state_machine_transition_fun, fn media_id,
                                                                             to_state,
                                                                             actor,
                                                                             metadata ->
      send(test_pid, {:transition, media_id, to_state, actor, metadata})
      {:ok, to_state}
    end)

    Application.put_env(:nebu_http, :media_scan_enqueue_fun, fn media_id ->
      send(test_pid, {:scan_enqueued, media_id})
      :ok
    end)

    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_scan_enqueue_module)
      Application.delete_env(:nebu_http, :media_storage_put_fun)
      Application.delete_env(:nebu_http, :media_persist_upload_fun)
      Application.delete_env(:nebu_http, :media_lookup_reservation_fun)
      Application.delete_env(:nebu_http, :media_state_machine_transition_fun)
      Application.delete_env(:nebu_http, :media_scan_enqueue_fun)
      Application.delete_env(:nebu_http, :media_max_upload_bytes)
      Application.delete_env(:nebu_http, :media_unused_expires_ms)
      Application.delete_env(:nebu_http, :media_config_source)
      Application.delete_env(:nebu_http, :media_storage_config_source)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token, user_id: uid, other_token: other_token, other_user_id: other_uid}
  end

  defp upload_path(media_id, query \\ "") do
    base = "#{@base_path}/#{S.server_name()}/#{media_id}"
    if query == "", do: base, else: base <> "?" <> query
  end

  defp put_upload(media_id, body, headers, query \\ "") do
    conn =
      conn(:put, upload_path(media_id, query), body)
      |> Map.put(:req_headers, [])

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    Nebu.Web.Router.call(conn, S.router_opts())
  end

  # Seeds the `:media_lookup_reservation_fun` fake with a reservation row.
  # `uploaded_at` defaults to "now" so the default 24h TTL never trips
  # unintentionally in tests that aren't specifically exercising expiry.
  defp seed_reservation(_media_id, opts) do
    row = %{
      uploader_user_id: Keyword.get(opts, :uploader_user_id, "@uploader:#{S.server_name()}"),
      state: Keyword.get(opts, :state, :reserved),
      uploaded_at: Keyword.get(opts, :uploaded_at, System.system_time(:millisecond))
    }

    Application.put_env(:nebu_http, :media_lookup_reservation_fun, fn _server_name, _media_id ->
      {:ok, row}
    end)

    row
  end

  defp media_id, do: "async-upload-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 1 — happy path: 200 {}, stored, reserved -> quarantined,
  # scan enqueued (AC8)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload/:server/:media_id happy path -> 200 {}, bytes stored, state transitions " <>
         "reserved to quarantined, scan job enqueued",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(mid, "hello world bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 200,
           "expected 200 from PUT #{upload_path(mid)}, got #{conn.status} " <>
             "(#{inspect(S.json(conn))}) — async upload route not implemented"

    assert S.json(conn) == %{}, "response body must be the empty JSON object {} per spec, " <>
             "no content_uri echo"

    assert_received {:stored, _key, _ciphertext}
    assert_received {:transition, ^mid, :quarantined, {:system, nil}, _metadata}
    assert_received {:scan_enqueued, ^mid}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 2 — file_hash is SHA-256 of the ORIGINAL bytes, computed
  # before compression; compressed flag reflects the real gzip decision (AC8)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload happy path -> file_hash is SHA-256 of the ORIGINAL bytes, computed " <>
         "before compression",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    # Highly compressible body so Storage.compress/1 (Story 12) actually
    # shrinks it — proves compression really ran, not merely a no-op pass-
    # through, and that the STORED (encrypted) bytes reflect the smaller
    # compressed size, not the plaintext original.
    original_body = String.duplicate("A", 8000)
    expected_hash = :crypto.hash(:sha256, original_body) |> Base.encode16(case: :lower)

    conn =
      put_upload(mid, original_body, [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 200

    assert_received {:persisted, fields}
    assert fields.file_hash == expected_hash
    assert fields.compressed == true,
           "an 8000-byte run of a single repeated character MUST compress smaller via gzip"

    assert_received {:stored, _key, ciphertext}

    assert byte_size(ciphertext) < byte_size(original_body),
           "stored (encrypted) bytes must reflect the compressed size, not the 8000-byte original"
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 3 — ADR-032 consistency: storage_key only persisted
  # after Storage.put/2 succeeds (AC9)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload happy path -> Postgres row and S3 object agree (ADR-032 consistency): " <>
         "storage_key is only persisted after Storage.put/2 succeeds",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    Application.put_env(:nebu_http, :media_storage_put_fun, fn _key, _bytes ->
      {:error, :simulated_s3_failure}
    end)

    conn_fail =
      put_upload(mid, "some bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    refute conn_fail.status == 200,
           "an S3 write failure must not return 200"

    refute_received {:persisted, _fields},
                     "storage_key/file_hash must NOT be persisted when the S3 write fails (AC9)"

    refute_received {:transition, _mid, _to_state, _actor, _metadata},
                     "the row must remain :reserved — no state transition on S3 failure (AC9)"

    # Retry: the storage boundary now succeeds. Row is still :reserved (per
    # AC9, no partial write happened), so the retry is a normal AC8 attempt.
    Application.put_env(:nebu_http, :media_storage_put_fun, fn key, bytes ->
      send(self(), {:stored, key, bytes})
      :ok
    end)

    conn_retry =
      put_upload(mid, "some bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn_retry.status == 200,
           "a retry against an unexpired :reserved row after a prior S3 failure must succeed " <>
             "normally, got #{conn_retry.status} (#{inspect(S.json(conn_retry))})"

    assert_received {:persisted, _fields}
    assert_received {:transition, ^mid, :quarantined, _actor, _metadata}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Code-review MAJOR-1 fix (2026-07-14): a persist_upload/1 or transition/4
  # failure AFTER a successful S3 write must surface as a real error, never
  # a false-success 200 — the original implementation discarded both return
  # values.
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload where persist_upload/1 fails AFTER a successful S3 write -> " <>
         "a real error (not 200), and the state is NOT transitioned",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    Application.put_env(:nebu_http, :media_persist_upload_fun, fn _fields ->
      {:error, :simulated_db_failure}
    end)

    conn =
      put_upload(mid, "bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    refute conn.status == 200,
           "a persist_upload/1 failure after a successful S3 write must NOT return 200 " <>
             "(silent data loss), got #{conn.status}"

    refute_received {:transition, _mid, _to_state, _actor, _metadata},
                     "the state must NOT transition to :quarantined if persist_upload/1 failed"

    refute_received {:scan_enqueued, _mid},
                     "no scan should be enqueued for a row that failed to persist"
  end

  test "PUT .../upload where StateMachine.transition/4 fails AFTER a successful persist_upload/1 -> " <>
         "a real error (not 200), and no scan is enqueued",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    Application.put_env(:nebu_http, :media_state_machine_transition_fun, fn _media_id,
                                                                             _to_state,
                                                                             _actor,
                                                                             _metadata ->
      {:error, {:invalid_transition, :reserved, :quarantined}}
    end)

    conn =
      put_upload(mid, "bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    refute conn.status == 200,
           "a transition/4 failure after a successful persist_upload/1 must NOT return 200, " <>
             "got #{conn.status}"

    assert_received {:persisted, _fields}
    refute_received {:scan_enqueued, _mid},
                     "no scan should be enqueued if the state transition itself failed"
  end

  # ══════════════════════════════════════════════════════════════════════
  # Code-review MAJOR-2 fix (2026-07-14): the async path must enforce the
  # SAME hardcoded stored-XSS-vector blocklist (@blocked_upload_types) the
  # sync upload/1 path already enforces — in ADDITION to (not instead of)
  # the admin-configurable mime_denylist_rejected?/1 check. Mirrors the
  # regression guard already present for the sync path in
  # media_upload_test.exs.
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload with a @blocked_upload_types content type (image/svg+xml) -> " <>
         "400 M_BAD_JSON, nothing stored",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(mid, "<svg onload=\"alert(1)\"></svg>", [
        {"content-type", "image/svg+xml"} | S.auth(token)
      ])

    assert conn.status == 400,
           "a blocked (stored-XSS-vector) content type must be rejected on the async path " <>
             "exactly as it is on the sync path, got #{conn.status} (#{inspect(S.json(conn))})"

    assert S.json(conn)["errcode"] == "M_BAD_JSON"
    assert S.json(conn)["error"] == "Content-Type not permitted for upload"

    refute_received {:stored, _key, _bytes}
    refute_received {:persisted, _fields}
  end

  test "PUT .../upload with a @blocked_upload_types content type (text/html) -> " <>
         "400 M_BAD_JSON, nothing stored",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(mid, "<script>alert(1)</script>", [
        {"content-type", "text/html"} | S.auth(token)
      ])

    assert conn.status == 400
    assert S.json(conn)["errcode"] == "M_BAD_JSON"
    assert S.json(conn)["error"] == "Content-Type not permitted for upload"
    refute_received {:stored, _key, _bytes}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Code-review MINOR-2 fix (2026-07-14): empty body must not be stored as
  # a zero-byte object, mirroring upload/1's F3 behavior (media_upload_test.exs).
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload with an EMPTY body -> 400 M_UNKNOWN and nothing stored", %{
    token: token,
    user_id: uid
  } do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(mid, "", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 400,
           "an empty async-upload body must be rejected with 400, got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_UNKNOWN"
    refute_received {:stored, _key, _bytes}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 4 — 403 M_FORBIDDEN (ownership), regardless of state (AC3)
  # ══════════════════════════════════════════════════════════════════════

  for state <- [:reserved, :quarantined, :released, :infected] do
    test "PUT .../upload from a DIFFERENT user than the reservation's owner -> 403 M_FORBIDDEN " <>
           "regardless of the reservation's current state (state: #{state})",
         %{other_token: other_token, user_id: uid} do
      mid = media_id()
      seed_reservation(mid, uploader_user_id: uid, state: unquote(state))

      conn =
        put_upload(mid, "bytes", [
          {"content-type", "application/octet-stream"} | S.auth(other_token)
        ])

      assert conn.status == 403,
             "a mismatched-user PUT against a :#{unquote(state)} reservation must be 403, " <>
               "got #{conn.status} (#{inspect(S.json(conn))})"

      assert S.json(conn)["errcode"] == "M_FORBIDDEN"

      refute_received {:stored, _key, _bytes}
      refute_received {:persisted, _fields}
      refute_received {:transition, _mid, _to_state, _actor, _metadata}
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 5 — 404 M_NOT_FOUND, unknown media_id (AC4)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload with an unknown media_id -> 404 M_NOT_FOUND", %{token: token} do
    conn =
      put_upload("no-such-media-id", "bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 404
    assert S.json(conn)["errcode"] == "M_NOT_FOUND"
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 6 — 404 M_NOT_FOUND, expired reservation, checked live
  # (AC4, coordinator-resolved derivation: uploaded_at + unused_expires_ms())
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload with a reservation whose derived expiry has already elapsed -> " <>
         "404 M_NOT_FOUND, checked live (not dependent on the cleanup cron having run)",
       %{token: token, user_id: uid} do
    # A tiny TTL + an uploaded_at just past it — this is the LIVE derivation
    # (row.uploaded_at + unused_expires_ms() < now), not a persisted
    # unused_expires_at column (there is none — see this file's moduledoc).
    Application.put_env(:nebu_http, :media_unused_expires_ms, 1_000)
    mid = media_id()

    seed_reservation(mid,
      uploader_user_id: uid,
      uploaded_at: System.system_time(:millisecond) - 5_000
    )

    conn =
      put_upload(mid, "bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 404,
           "an expired-by-derivation reservation must 404 even though no cleanup cron has " <>
             "run, got #{conn.status} (#{inspect(S.json(conn))})"

    assert S.json(conn)["errcode"] == "M_NOT_FOUND"
    refute_received {:stored, _key, _bytes}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 7 — 409 M_CANNOT_OVERWRITE_MEDIA, already past :reserved (AC5)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload on a media_id already past :reserved (e.g. :quarantined) -> " <>
         "409 M_CANNOT_OVERWRITE_MEDIA",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid, state: :quarantined)

    conn =
      put_upload(mid, "bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 409
    assert S.json(conn)["errcode"] == "M_CANNOT_OVERWRITE_MEDIA"
    refute_received {:stored, _key, _bytes}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 8 — retried with byte-identical body after a prior 200 ->
  # still 409, no idempotency exception (AC5)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload retried with byte-identical body after a prior 200 success -> " <>
         "still 409 M_CANNOT_OVERWRITE_MEDIA (no idempotency exception)",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid, state: :reserved)

    body = "identical bytes"
    headers = [{"content-type", "application/octet-stream"} | S.auth(token)]

    conn1 = put_upload(mid, body, headers)
    assert conn1.status == 200, "first PUT must succeed, got #{conn1.status}"

    # Simulate the row now being :quarantined after the first successful PUT.
    seed_reservation(mid, uploader_user_id: uid, state: :quarantined)

    conn2 = put_upload(mid, body, headers)

    assert conn2.status == 409,
           "a byte-identical retry after a prior success must still be 409, never a cached " <>
             "200, got #{conn2.status} (#{inspect(S.json(conn2))})"

    assert S.json(conn2)["errcode"] == "M_CANNOT_OVERWRITE_MEDIA"
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 9/10 — 413 M_TOO_LARGE (AC6), both pre-check and streamed
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload exceeding max_upload_size_bytes (Content-Length pre-check) -> " <>
         "413 M_TOO_LARGE, nothing stored",
       %{token: token, user_id: uid} do
    Application.put_env(:nebu_http, :media_max_upload_bytes, 16)
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    big = :binary.copy("A", 1024)

    conn =
      put_upload(mid, big, [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 413
    assert S.json(conn)["errcode"] == "M_TOO_LARGE"
    refute_received {:stored, _key, _bytes}
    refute_received {:persisted, _fields}
    refute_received {:transition, _mid, _to_state, _actor, _metadata}
  end

  test "PUT .../upload exceeding max_upload_size_bytes (streamed, relying on the running-total " <>
         "check rather than Content-Length) -> 413 M_TOO_LARGE, nothing stored",
       %{token: token, user_id: uid} do
    Application.put_env(:nebu_http, :media_max_upload_bytes, 16)
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    # Plug.Test always sets a correct Content-Length for a binary body, so
    # this exercises the SAME running-total-during-read guard the sync path
    # relies on (`read_full_body/2`'s bail-as-soon-as-over-limit clause) —
    # mirrors media_upload_test.exs's equivalent 413 case, which documents
    # the identical constraint on simulating a "no/incorrect Content-Length"
    # client with Plug.Test.
    big = :binary.copy("B", 1024)

    conn =
      put_upload(mid, big, [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 413
    assert S.json(conn)["errcode"] == "M_TOO_LARGE"
    refute_received {:stored, _key, _bytes}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 11 — Content-Type optional (v1.12+), defaults to
  # application/octet-stream (AC1)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload without a Content-Type header -> defaults to application/octet-stream, " <>
         "upload still succeeds (v1.12 optionality)",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn = put_upload(mid, "bytes with no content-type", S.auth(token))

    assert conn.status == 200,
           "an upload with no Content-Type header must succeed (v1.12 made it optional), " <>
             "got #{conn.status} (#{inspect(S.json(conn))})"

    assert_received {:persisted, fields}
    assert fields.content_type == "application/octet-stream"
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 12 — ?filename=... is persisted (AC2)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload with ?filename=report.pdf -> filename persisted on the media_files row",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(
        mid,
        "pdf bytes",
        [{"content-type", "application/pdf"} | S.auth(token)],
        "filename=report.pdf"
      )

    assert conn.status == 200

    assert_received {:persisted, fields}
    assert fields.filename == "report.pdf"
  end

  test "PUT .../upload with NO ?filename= query param -> filename persisted as nil",
       %{token: token, user_id: uid} do
    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(mid, "bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 200
    assert_received {:persisted, fields}
    assert fields.filename == nil
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 13 — validation order: 403 wins over 404/409/413 (AC7)
  # ══════════════════════════════════════════════════════════════════════

  test "Validation order: an ownership mismatch (403) is returned even when the reservation " <>
         "is ALSO expired, over-size, and in a terminal state",
       %{other_token: other_token, user_id: uid} do
    Application.put_env(:nebu_http, :media_unused_expires_ms, 1_000)
    Application.put_env(:nebu_http, :media_max_upload_bytes, 4)
    mid = media_id()

    # Owned by `uid`, but the request below authenticates as `other_token` —
    # ALSO expired (uploaded_at far in the past) AND in a terminal state
    # (:infected, not :reserved) AND the body exceeds the tiny size limit.
    seed_reservation(mid,
      uploader_user_id: uid,
      state: :infected,
      uploaded_at: System.system_time(:millisecond) - 60_000
    )

    conn =
      put_upload(mid, "a body that is definitely over 4 bytes", [
        {"content-type", "application/octet-stream"} | S.auth(other_token)
      ])

    assert conn.status == 403,
           "ownership (403) must win over expiry/state/size-limit when all apply " <>
             "simultaneously, got #{conn.status} (#{inspect(S.json(conn))})"

    assert S.json(conn)["errcode"] == "M_FORBIDDEN"
  end

  # test-review (pre-dev): the combined test above only proves ownership (403)
  # wins over everything else — it does NOT isolate whether the state guard
  # (409) is checked BEFORE the size limit (413) for a correctly-owned,
  # non-expired request, which is the other adjacent pair in AC7's full order
  # (lookup -> ownership -> expiry -> state -> size -> body read). Closing
  # that gap here rather than leaving it as a deferred finding.
  test "Validation order: the state guard (409) is checked BEFORE the size limit (413) for " <>
         "a correctly-owned, non-expired request that is BOTH in the wrong state AND over-size",
       %{token: token, user_id: uid} do
    Application.put_env(:nebu_http, :media_max_upload_bytes, 4)
    mid = media_id()

    # Right owner, not expired, but already past :reserved AND the body
    # exceeds the tiny size limit — AC7 requires 409 (state, checked earlier
    # in the order), never 413 (size, checked later).
    seed_reservation(mid, uploader_user_id: uid, state: :quarantined)

    conn =
      put_upload(mid, "a body that is definitely over 4 bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 409,
           "the state guard (409) must be checked BEFORE the size limit (413) per AC7's " <>
             "validation order, got #{conn.status} (#{inspect(S.json(conn))})"

    assert S.json(conn)["errcode"] == "M_CANNOT_OVERWRITE_MEDIA"
  end

  # ══════════════════════════════════════════════════════════════════════
  # Wiring: Story 9c's mime_denylist_rejected?/1 (previously standalone/
  # unwired) — this story is the first caller.
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload with a Content-Type on the admin mime_denylist -> 400 M_BAD_JSON, " <>
         "nothing stored (Story 9c wiring)",
       %{token: token, user_id: uid} do
    Application.put_env(:nebu_http, :media_config_source, fn ->
      %{"mime_denylist" => "application/x-msdownload"}
    end)

    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(mid, "MZ...", [
        {"content-type", "application/x-msdownload"} | S.auth(token)
      ])

    assert conn.status == 400,
           "a Content-Type matching the admin mime_denylist must be rejected, " <>
             "got #{conn.status} (#{inspect(S.json(conn))})"

    assert S.json(conn)["errcode"] == "M_BAD_JSON"
    refute_received {:stored, _key, _bytes}
    refute_received {:persisted, _fields}
  end

  # ══════════════════════════════════════════════════════════════════════
  # Wiring: Story 11c's StorageConfig.compute_key/2 (previously standalone/
  # unwired) — this story is the first (and only sanctioned) caller.
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload computes the storage key via StorageConfig.compute_key/2 using the " <>
         "currently-active s3_key_prefix_template (Story 11c wiring)",
       %{token: token, user_id: uid} do
    Application.put_env(:nebu_http, :media_storage_config_source, fn ->
      %{s3_key_prefix_template: "prefix/{media_id}"}
    end)

    mid = media_id()
    seed_reservation(mid, uploader_user_id: uid)

    conn =
      put_upload(mid, "bytes", [
        {"content-type", "application/octet-stream"} | S.auth(token)
      ])

    assert conn.status == 200

    assert_received {:stored, key, _ciphertext}

    assert key == "prefix/#{mid}",
           "storage key must be computed via StorageConfig.compute_key/2 against the " <>
             "currently-active template, got #{inspect(key)}"
  end

  # ══════════════════════════════════════════════════════════════════════
  # 401 unauthenticated (mirrors every other media_*_test.exs convention)
  # ══════════════════════════════════════════════════════════════════════

  test "PUT .../upload with NO Bearer token -> 401 M_MISSING_TOKEN" do
    conn = put_upload(media_id(), "bytes", [{"content-type", "application/octet-stream"}])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
  end

  test "PUT .../upload with a garbage Bearer token -> 401 M_UNKNOWN_TOKEN" do
    conn =
      put_upload(media_id(), "bytes", [
        {"content-type", "application/octet-stream"},
        {"authorization", "Bearer not-a-real-jwt"}
      ])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end
end
