defmodule Nebu.Web.MediaDownloadGateTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control` — the download/
  thumbnail lifecycle-state gate (AC1-AC7).

  `Nebu.Media.with_authorised_media/4` must consult `row.state` IMMEDIATELY
  after the `media_files` lookup — before the room-membership check and
  before any storage fetch / AES-256-GCM decrypt work (AC7). The gate is an
  explicit ALLOW-LIST on `:released` (AC5) with a catch-all-DENY tail (AC6),
  never a catch-all-serve:

    * `:reserved` / `:quarantined` / `:scanning` → 451 M_NOT_YET_UPLOADED (AC1)
    * `:admin_blocked` → byte-identical 404 M_NOT_FOUND status AND body,
      indistinguishable from a genuine 404 (AC2) — CORRECTED 2026-07-19
      (media-security-admin-control/6a-routine-state-actions, Kassandra
      security-review): a prior revision of this gate returned 451 status
      here (only the errcode/body were anonymized), which made the bare
      status line itself a fingerprint for "an admin blocked this" — see
      `Nebu.Media`'s own `download_gate(:admin_blocked)` comment and
      ADR-026's 2026-07-19 correction. True indistinguishability requires an
      identical status line, not just an identical body.
    * `:infected` / `:deleted` / `:hard_deleted` → 404 M_NOT_FOUND (AC3)
    * `:released` → 200, unchanged from today (AC4)
    * anything else (including states not yet invented, e.g. Story 4a's
      `:scan_failed`) → 451 M_NOT_YET_UPLOADED, never 200, never 500 (AC5/AC6)

  ## Why this MUST FAIL now

  `Nebu.Media.with_authorised_media/4` (server/lib/nebu/media.ex) has no state
  gate at all yet: it goes straight from `{:ok, row}` to the membership check,
  then to `fetch_and_decrypt/3`, ignoring `row.state` entirely. Every
  non-released-state test below observes whatever the existing
  lookup→membership→fetch→decrypt pipeline produces today — typically 200,
  since the fake storage/crypto path succeeds regardless of `row.state` — so
  the status/errcode assertions fail (not a compile error: `media_row/1`
  already threads a `:state` field through the injected row). The AC7
  "storage boundary" test goes further: it makes the fake storage boundary
  `flunk/1` if invoked at all, so today it fails via a raised assertion
  (proving the boundary IS reached pre-gate) rather than via a plain
  `refute` mismatch.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes
  alias Nebu.Repo

  @plaintext "the-quick-brown-fox-jumps-over-the-lazy-dog-image-bytes"
  @media_id "gatemedia123"
  @room_id "!room:test.local"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)
    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(@plaintext)

    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)

    # kai IS a room member in every scenario below — these tests exist to prove
    # the STATE gate denies regardless of membership (it runs before the
    # membership check, per the story's technical requirements).
    Application.put_env(:nebu_http, :media_member_fun, fn room, user ->
      room == @room_id and user == uid
    end)

    # Default storage boundary: serves the correct ciphertext for @media_id.
    # Individual denied-state tests swap this for a flunking fake (AC7).
    Application.put_env(:nebu_http, :media_storage_get_fun, fn key ->
      if key == @media_id, do: {:ok, ciphertext}, else: {:error, :not_found}
    end)

    on_exit(fn ->
      for k <- [
            :media_db_module,
            :media_storage_module,
            :media_membership_module,
            :media_lookup_fun,
            :media_storage_get_fun,
            :media_member_fun
          ],
          do: Application.delete_env(:nebu_http, k)
    end)

    {:ok,
     token: token,
     user_id: uid,
     ciphertext: ciphertext,
     key_hex: key_hex,
     nonce_hex: nonce_hex}
  end

  defp get(path, headers) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp download_path(media_id \\ @media_id),
    do: "/_matrix/media/v3/download/#{S.server_name()}/#{media_id}"

  defp thumbnail_path(media_id \\ @media_id),
    do: "/_matrix/media/v3/thumbnail/#{S.server_name()}/#{media_id}"

  # Injects a media_files row for `media_id` with the given lifecycle `state`,
  # wiring the fake DB lookup exactly like media_download_test.exs does.
  defp put_row(media_id, state, ctx) do
    row =
      S.media_row(
        media_id: media_id,
        content_type: "image/jpeg",
        file_size: byte_size(@plaintext),
        aes_key_hex: ctx.key_hex,
        nonce_hex: ctx.nonce_hex,
        room_id: @room_id,
        storage_key: media_id,
        state: state
      )

    Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
      if server == S.server_name() and id == media_id, do: {:ok, row}, else: {:error, :not_found}
    end)

    row
  end

  # AC7: the storage boundary must never be invoked for a denied state.
  defp forbid_storage_access do
    Application.put_env(:nebu_http, :media_storage_get_fun, fn _key ->
      flunk("AC7 violated: Nebu.Media.Storage.get/1 (fake) was called for a denied media state")
    end)
  end

  # ── AC1 — pending states → 451 M_NOT_YET_UPLOADED ──────────────────────────

  test "state :reserved → 451 M_NOT_YET_UPLOADED", %{token: token} = ctx do
    put_row(@media_id, :reserved, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 451,
           "state :reserved must return 451, got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"
    assert body["error"] == "Media not yet available"
  end

  test "state :quarantined → 451 M_NOT_YET_UPLOADED", %{token: token} = ctx do
    put_row(@media_id, :quarantined, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 451,
           "state :quarantined must return 451, got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"
    assert body["error"] == "Media not yet available"
  end

  test "state :scanning → 451 M_NOT_YET_UPLOADED", %{token: token} = ctx do
    put_row(@media_id, :scanning, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 451,
           "state :scanning must return 451, got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"
    assert body["error"] == "Media not yet available"
  end

  # ── AC2 — admin_blocked → byte-identical 404 status + M_NOT_FOUND body ────
  #
  # CORRECTED 2026-07-19 (media-security-admin-control/6a-routine-state-actions,
  # Kassandra security-review): this test previously asserted `conn.status ==
  # 451`, treating a distinguishable status line as acceptable as long as the
  # errcode was anonymized. That reasoning was wrong — see ADR-026's own
  # 2026-07-19 correction and Nebu.Media's download_gate(:admin_blocked)
  # comment. The status must be 404, identical to every other terminal-negative
  # state, not merely the body.

  test "state :admin_blocked → 404 status with M_NOT_FOUND errcode (byte-identical to a genuine 404)",
       %{token: token} = ctx do
    put_row(@media_id, :admin_blocked, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 404,
           "admin_blocked must return HTTP 404 — an identical status line to every other " <>
             "terminal-negative state, not a distinguishing 451 (AC2), got #{conn.status}"

    body = S.json(conn)

    assert body["errcode"] == "M_NOT_FOUND",
           "admin_blocked errcode must be anonymized to M_NOT_FOUND (indistinguishable from a real 404), got #{inspect(body["errcode"])}"

    assert body["error"] == "Media not found"
  end

  # ── AC3 — terminal-negative states → 404 M_NOT_FOUND ───────────────────────

  test "state :infected → 404 M_NOT_FOUND", %{token: token} = ctx do
    put_row(@media_id, :infected, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 404
    body = S.json(conn)
    assert body["errcode"] == "M_NOT_FOUND"
    assert body["error"] == "Media not found"
  end

  test "state :deleted → 404 M_NOT_FOUND", %{token: token} = ctx do
    put_row(@media_id, :deleted, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 404,
           "state :deleted must still reach the handler-level gate as 404 (the SQL layer must " <>
             "no longer filter it out via WHERE deleted = false)"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_FOUND"
    assert body["error"] == "Media not found"
  end

  test "state :hard_deleted → 404 M_NOT_FOUND", %{token: token} = ctx do
    put_row(@media_id, :hard_deleted, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 404
    body = S.json(conn)
    assert body["errcode"] == "M_NOT_FOUND"
    assert body["error"] == "Media not found"
  end

  # ── AC4 — :released → 200 OK, no regression to existing bytes/headers ─────

  test "state :released → 200 OK with original decrypted bytes", %{token: token} = ctx do
    put_row(@media_id, :released, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 200,
           "state :released must serve 200 exactly as today, got #{conn.status}"

    assert conn.resp_body == @plaintext,
           "released must still serve the AES-256-GCM-decrypted original bytes (ADR-011, no regression)"

    cd = S.header(conn, "content-disposition")
    assert cd != "", "Content-Disposition must not regress for :released"
    assert String.starts_with?(cd, "inline")

    ct = S.header(conn, "content-type")
    assert String.contains?(ct, "image/jpeg")
    assert S.header(conn, "x-content-type-options") == "nosniff"
  end

  # ── AC5/AC6 — unrecognized/future states default to deny, never 200/500 ──

  test "unrecognized future state :scan_failed → 451 M_NOT_YET_UPLOADED, never 200/500",
       %{token: token} = ctx do
    put_row(@media_id, :scan_failed, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 451,
           "an unmapped state (:scan_failed, Story 4a's future scope) must fall through to the " <>
             "AC1 default-deny response, not 200 and not a 500, got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"
    assert body["error"] == "Media not yet available"
  end

  test "arbitrary unmapped atom state → 451 M_NOT_YET_UPLOADED, never 200/500",
       %{token: token} = ctx do
    put_row(@media_id, :totally_bogus_state_no_handler_knows_this, ctx)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 451,
           "an atom the handler has never heard of must default-deny (AC5: the success path is " <>
             "an explicit allow-list on :released, not a deny-list with a catch-all-serve tail), " <>
             "got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"
    assert body["error"] == "Media not yet available"
  end

  # ── AC7 — denied states never reach the storage boundary ──────────────────

  test "denied states never reach the storage boundary", %{token: token} = ctx do
    forbid_storage_access()

    denied_states = [
      :reserved,
      :quarantined,
      :scanning,
      :admin_blocked,
      :infected,
      :deleted,
      :hard_deleted
    ]

    for state <- denied_states do
      put_row(@media_id, state, ctx)
      conn = get(download_path(), S.auth(token))

      refute conn.status == 200,
             "state #{inspect(state)} must be denied before storage is ever consulted"
    end
  end

  # ── AC2 anonymity — admin_blocked response is byte-identical to a genuine 404 ─
  #
  # CORRECTED 2026-07-19 (media-security-admin-control/6a-routine-state-actions,
  # Kassandra security-review): this test previously asserted the STATUS line
  # was allowed to differ (451 for admin_blocked vs 404 for hard_deleted/
  # unknown) as long as the body matched — and documented that as "AC2" full
  # anonymity. It was not: the (451, M_NOT_FOUND) pairing was itself unique to
  # admin_blocked and therefore a perfect status-line-only oracle. Both the
  # status AND the body must now be identical across all three cases.

  test "admin_blocked response (status AND body) is identical to a genuine 404 M_NOT_FOUND response",
       %{token: token} = ctx do
    put_row(@media_id, :admin_blocked, ctx)
    blocked_conn = get(download_path(), S.auth(token))

    put_row(@media_id, :hard_deleted, ctx)
    hard_deleted_conn = get(download_path(), S.auth(token))

    # The lookup fun installed by the last put_row/3 call above (:hard_deleted)
    # returns {:error, :not_found} for any other media id — same as the
    # existing "unknown media id" 404 branch in media_download_test.exs.
    unknown_conn = get(download_path("does-not-exist-at-all"), S.auth(token))

    blocked_body = S.json(blocked_conn)
    hard_deleted_body = S.json(hard_deleted_conn)
    unknown_body = S.json(unknown_conn)

    assert blocked_body == hard_deleted_body,
           "admin_blocked body must be byte-identical to a genuine terminal-state 404 body"

    assert blocked_body == unknown_body,
           "admin_blocked body must be byte-identical to the genuine unknown-media-id 404 body"

    # AC2 (corrected): the HTTP status line must ALSO be identical — a
    # distinguishable status alone defeats anonymity even with an identical
    # body (Kassandra security-review, 2026-07-19).
    assert blocked_conn.status == 404,
           "admin_blocked must return the SAME 404 status as a genuine not-found — a " <>
             "differing status line (e.g. 451) is itself a fingerprint, got #{blocked_conn.status}"

    assert hard_deleted_conn.status == 404
    assert unknown_conn.status == 404
  end

  # ── corollary (bonus, not a formal AC) — thumbnail inherits the same gate ─

  test "GET thumbnail for a non-released state is denied the same way as download",
       %{token: token} = ctx do
    put_row(@media_id, :infected, ctx)

    conn = get(thumbnail_path() <> "?width=64&height=64", S.auth(token))

    assert conn.status == 404,
           "thumbnail must inherit the shared with_authorised_media/4 gate for free, got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_FOUND"
    assert body["error"] == "Media not found"
  end

  # ── review cycle 3 — parse_state/1 rescue, exercised without a live DB ─────
  #
  # Replaces a deleted @moduletag :integration test that grew the media_state
  # Postgres ENUM at runtime (ALTER TYPE ... ADD VALUE), which required
  # DDL privileges the test-integration harness's nebu_app role deliberately
  # does not have (least-privilege role architecture, Story 5.29a/AC3) and
  # failed CI with insufficient_privilege. This proves the same bug class —
  # an unrecognized-atom ArgumentError inside String.to_existing_atom/1 being
  # rescued instead of crashing — with a synthetic string built from
  # System.unique_integer/1, guaranteed to have never been interned as an
  # atom anywhere in the running VM, and needs no DB connection at all.

  test "parse_state/1 does not raise on a raw string never interned as an atom, falls back to the sentinel" do
    never_seen_state = "totally_unseen_media_state_#{System.unique_integer([:positive])}"

    assert Nebu.Media.DB.parse_state(never_seen_state) == :__unrecognized_media_state__
  end

  test "parse_state/1 still converts already-known state strings normally" do
    assert Nebu.Media.DB.parse_state("released") == :released
    assert Nebu.Media.DB.parse_state("admin_blocked") == :admin_blocked
  end

  # ── AC5 (media-security-admin-control/4a-scan-failed-enum-migration) ──────
  #
  # Every test above exercises download_gate/1's `:scan_failed` handling
  # through `MediaFakes.DB` — a bare Elixir atom injected directly, never
  # touching the real `media_state` ENUM column. Story 4a's AC5 requires
  # this to also be proven against a REAL `media_files` row, seeded through
  # the real `Nebu.Media.DB.lookup/2` (and therefore through `parse_state/1`'s
  # `String.to_existing_atom/1` conversion), now that the ENUM actually has a
  # `'scan_failed'` value (this story's own migration,
  # `000028_media_scan_failed_state.up.sql`). This is a genuine regression
  # check, not a duplicate of the fake-based test above: if `download_gate/1`
  # needed ANY code change to handle a real `:scan_failed` row, this is the
  # test that would catch it — the fake-based test above could not, since it
  # never exercises `Nebu.Media.DB` at all.
  #
  # Unlike the deleted runtime-ENUM-growing test noted above (which failed
  # CI with `insufficient_privilege` because it tried an `ALTER TYPE` DDL
  # statement using the least-privileged `nebu_app` role), this test performs
  # only a plain DML `INSERT` — the `'scan_failed'` value already exists by
  # the time this test runs, added by this story's own migration
  # (`000028_media_scan_failed_state.up.sql`) as part of the normal, already-
  # privileged migration step, not by anything this test does at runtime.
  @tag :integration
  test "state :scan_failed against a live media_state enum value → 451 M_NOT_YET_UPLOADED, " <>
         "no code change needed in download_gate/1",
       %{token: token} do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    media_id = "gate_scan_failed_live_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM media_files WHERE media_id = $1", [media_id])
    end)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        INSERT INTO media_files
          (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
           uploader_user_id, uploaded_at, deleted, state)
        VALUES ($1, $2, 'image/jpeg', 10, 'aeskeyhex', 'noncehex',
                '@tester:test.local', $3, false, 'scan_failed')
        """,
        [media_id, S.server_name(), System.system_time(:millisecond)]
      )

    # Use the REAL Nebu.Media.DB module for this one test, not the fake the
    # shared `setup` block wires up for every other test in this file — the
    # shared `on_exit` list already deletes this env key afterward.
    Application.put_env(:nebu_http, :media_db_module, Nebu.Media.DB)

    conn = get(download_path(media_id), S.auth(token))

    assert conn.status == 451,
           "a real, live media_state = 'scan_failed' row must fall through download_gate/1's " <>
             "catch-all to the AC1 default-deny response, not 200 and not a 500 " <>
             "(no code change to download_gate/1 should be needed for this to pass), " <>
             "got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"
    assert body["error"] == "Media not yet available"
  end

  # ── media-security-admin-control/8c-media-archive-worker (AC11) ───────────
  #
  # fetch_and_decrypt/3's bucket switch: row.archived_at truthy -> archive
  # bucket via Nebu.Media.Storage.get_from_archive/1; falsy (the default,
  # every test above) -> unchanged primary-bucket Storage.get/1. These two
  # tests prove BOTH directions of the switch — a download must keep working
  # after archiving (not silently 404/502 the moment MediaArchiveWorker sets
  # archived_at), and a non-archived :released file must NOT be accidentally
  # routed to the archive bucket.

  test "downloads still work after archiving (archived_at set routes to the archive bucket)",
       %{token: token} = ctx do
    row =
      put_row(@media_id, :released, ctx)
      |> Map.put(:archived_at, ~U[2026-01-01 00:00:00Z])

    Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
      if server == S.server_name() and id == @media_id, do: {:ok, row}, else: {:error, :not_found}
    end)

    # AC11: the primary bucket must never be consulted once archived_at is set.
    Application.put_env(:nebu_http, :media_storage_get_fun, fn _key ->
      flunk("AC11 violated: primary Storage.get/1 was called for an archived row")
    end)

    Application.put_env(:nebu_http, :media_storage_get_from_archive_fun, fn key ->
      if key == @media_id, do: {:ok, ctx.ciphertext}, else: {:error, :not_found}
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :media_storage_get_from_archive_fun) end)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 200,
           "an archived :released file must still download successfully, got #{conn.status}"

    assert conn.resp_body == @plaintext
  end

  test "downloads for a non-archived :released file still use the primary bucket",
       %{token: token} = ctx do
    put_row(@media_id, :released, ctx)

    # Regression guard for AC11's new branch: a non-archived row must never
    # reach the archive-bucket accessor.
    Application.put_env(:nebu_http, :media_storage_get_from_archive_fun, fn _key ->
      flunk("AC11 regression: archive-bucket Storage.get_from_archive/1 was called for a " <>
              "non-archived (archived_at: nil) row")
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :media_storage_get_from_archive_fun) end)

    conn = get(download_path(), S.auth(token))

    assert conn.status == 200
    assert conn.resp_body == @plaintext
  end
end
