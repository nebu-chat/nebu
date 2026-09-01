defmodule Nebu.Media do
  @moduledoc """
  Matrix content-repository handlers (deprecated `/_matrix/media/v3/*`), ported
  from the Go media gateway (`media/internal/{upload,download,crypto,storage,
  thumbnail}`). Routed via `Nebu.Web.Router.Media`, which runs `OidcPlug` so every
  endpoint here is authenticated (`conn.assigns.current_user` is the trusted
  `@user:server` id).

  ## Boundaries (ADR-018 injected seams)

  All external effects go through swappable boundary modules read from app env, so
  the full Plug pipeline can be unit-tested without S3/Postgres/network. Production
  defaults:

    * `:media_storage_module`        → `Nebu.Media.Storage`        (ExAws.S3)
    * `:media_db_module`             → `Nebu.Media.DB`             (inline SQL)
    * `:media_membership_module`     → `Nebu.Media.Membership`     (room_members SQL)
    * `:media_http_fetch_module`     → `Nebu.Media.HttpFetch`      (Finch)
    * `:media_permission_module`     → `Nebu.Media.Permission`     (account-deactivation check)
    * `:media_state_machine_module`  → `Nebu.Media.StateMachine`   (media_files.state writer)
    * `:media_scan_enqueue_module`   → `Nebu.Media.ScanEnqueue`    (async scan job enqueue, Story 2b/4b)
    * `:media_audit_writer_module`   → `Nebu.Compliance.AuditWriter` (admin-action audit bridge, Story 6a)

  ## At-rest encryption (ADR-011)

  Objects are AES-256-GCM encrypted (`Nebu.Media.Crypto`, byte-compatible with
  the Go gateway). GCM authenticates the whole blob, so download decrypts in memory
  and serves (and ranges over) the decrypted plaintext.
  """

  import Plug.Conn

  require Logger

  alias Nebu.Media.{Crypto, SSRF}

  # Matrix v1.12 safe-inline allowlist (mirrors download/handler.go
  # safeInlineContentTypes). Everything else → application/octet-stream + attachment.
  @safe_inline_types ~w(
    image/jpeg image/png image/gif image/webp image/avif
    audio/mpeg audio/ogg
    video/mp4 video/webm
    application/pdf
    text/plain
  )

  # Content types rejected at upload — renderable as HTML/JS (stored-XSS vector).
  # Mirrors upload.go blockedContentTypes.
  @blocked_upload_types ~w(
    text/html application/xhtml+xml
    text/javascript application/javascript
    image/svg+xml application/x-shockwave-flash
  )

  @default_max_upload_bytes 52_428_800

  # ── mime_denylist enforcement (story 9c, standalone unit — see @doc) ───────

  @doc """
  Admin-configurable MIME-prefix policy gate (story `9c-mime-denylist-
  enforcement`, epic `media-security-admin-control`).

  Standalone, PUBLIC unit — **not yet wired into any handler**. Story 2b
  (`Nebu.Media.upload_async/3`, `PUT
  /_matrix/media/v3/upload/{serverName}/{mediaId}`) has not landed on this
  branch. Once it does, 2b's handler MUST call this function immediately
  after resolving `Content-Type` (2b AC1) and before the size-limit check
  (2b AC6/413) — i.e. slot 5 of the validation order documented in this
  story's Technical Requirements:

      1. lookup_reservation           -> 404 if no row
      2. ownership check              -> 403
      3. expiry check                 -> 404
      4. state guard (:reserved?)     -> 409
      5. mime_denylist check (NEW)    -> 400 M_BAD_JSON   <- call this fn here
      6. size limit check             -> 413
      7. body read
      8. store_and_quarantine seam    -> 200

  Expected call site:

      content_type = base_content_type(conn) || "application/octet-stream"

      if Nebu.Media.mime_denylist_rejected?(content_type) do
        error(conn, 400, "M_BAD_JSON", "Content-Type not permitted by admin policy")
      else
        # ... continue to the size check ...
      end

  Contract:

    * `content_type` must already be resolved/defaulted by the caller — this
      function does NO header parsing (mirrors how `upload/1` resolves
      `Content-Type` once, up front, before checking `@blocked_upload_types`).
    * **The caller MUST pass an already-lowercased, parameter-stripped value**
      (exactly what `base_content_type/1` → `base_type/1` in this module
      produce: `String.split(";", parts: 2) |> List.first() |> String.trim()
      |> String.downcase()`). This function itself does **no** normalization
      and matches with strict case-sensitive `String.starts_with?/2` — passing
      it a raw, mixed-case, or param-suffixed header value will silently
      produce wrong results. Concretely: `Plug` only lowercases HTTP header
      *field names* (`"Content-Type"` vs `"content-type"`), never header
      *values* — a client-sent `Content-Type: Application/X-MSDownload`
      arrives at this function completely unchanged unless the caller runs it
      through `base_content_type/1` first. All case-insensitivity guarantees
      come entirely from that caller-side `String.downcase()` step, not from
      Plug. A future call site that resolves `Content-Type` some other way
      (skipping `base_content_type/1`) would silently case-sensitively bypass
      the denylist (e.g. an admin blocks `application/x-msdownload` but a
      client-declared `Application/X-MSDownload` slips through unmatched).
    * Reads `Nebu.Media.Config.get/0` on EVERY call — no local caching here;
      `Nebu.Media.Config`'s own ETS/`:pg`/TTL mechanism (story 9a) is the sole
      cache layer, which is what makes "no restart needed" (AC5) true.
    * `mime_denylist` (comma-separated prefixes, default `""`) is split on
      `,`, each token trimmed, LOWERCASED, and empty tokens discarded — `""`
      parses to `[]` (AC4). Discarding is required: `String.starts_with?(x,
      "")` is always `true`, so a stray empty token would silently deny
      everything.
    * Returns `true` if `content_type` starts with ANY parsed prefix
      (`String.starts_with?/2`, no content sniffing — AC3), else `false`.

  ## Prefix-side lowercasing (security-review 2026-07-13, MEDIUM-1b)

  Parsed prefixes are lowercased here (read time, this function only — NOT a
  second config cache, NOT a change to `Nebu.Media.Config`/`config.ex`,
  which stores/validates `mime_denylist` case-as-entered). This closes a gap
  the `content_type`-side caller-normalization contract above cannot: an
  admin who enters a mixed-case prefix (e.g. `Application/Zip`) would
  otherwise have it silently never match a correctly-lowercased incoming
  `content_type`, with no error or audit signal that their policy is a
  no-op. This is INTENTIONALLY asymmetric with the `content_type` side — see
  above — which stays caller-normalized, NOT re-downcased here, because the
  story's Technical Requirements explicitly specify "do not add a second
  normalization step" for `content_type` (mirroring `@blocked_upload_types`
  in `upload/1`, which has the identical caller-trusts-normalization
  property today). Lowercasing the admin-supplied prefix is a distinct,
  uncontroversial fix — it does not touch how `content_type` is resolved or
  compared, only how the denylist's own configured values are read.

  This function is independent of `@blocked_upload_types` (see Dev Agent
  Guardrails in the story) — the two lists are never merged.
  """
  @spec mime_denylist_rejected?(String.t()) :: boolean()
  def mime_denylist_rejected?(content_type) when is_binary(content_type) do
    %{mime_denylist: mime_denylist} = Nebu.Media.Config.get()

    mime_denylist
    |> parse_mime_denylist()
    |> Enum.any?(&String.starts_with?(content_type, &1))
  end

  defp parse_mime_denylist(mime_denylist) do
    mime_denylist
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  # ── PUT /_matrix/media/v3/upload (AC1) ─────────────────────────────────────

  @spec upload(Plug.Conn.t()) :: Plug.Conn.t()
  def upload(conn) do
    user = conn.assigns[:current_user]
    content_type = base_content_type(conn) || "application/octet-stream"
    max_bytes = max_upload_bytes()

    cond do
      content_type in @blocked_upload_types ->
        error(conn, 400, "M_BAD_JSON", "Content-Type not permitted for upload")

      over_content_length?(conn, max_bytes) ->
        error(conn, 413, "M_TOO_LARGE", "Upload exceeds maximum allowed size")

      true ->
        case read_full_body(conn, max_bytes) do
          {:too_large, conn} ->
            error(conn, 413, "M_TOO_LARGE", "Upload exceeds maximum allowed size")

          # F1: a transport read error must NOT be persisted as a complete body.
          {:read_error, conn} ->
            error(conn, 400, "M_UNKNOWN", "Failed to read upload body")

          # F3: an empty body (incl. a JSON content-type whose body Plug.Parsers
          # already consumed) must not be stored as a zero-byte object.
          {:ok, "", conn} ->
            error(conn, 400, "M_UNKNOWN", "Empty upload body not allowed")

          {:ok, body, conn} ->
            store_upload(conn, user, content_type, body)
        end
    end
  end

  # media-security-admin-control/2c-sync-upload-shared-pipeline: the sync
  # handler now creates its media_files row DIRECTLY in :quarantined via
  # Nebu.Media.StateMachine.create_quarantined/1 (AC1/AC4) — never via the
  # old bespoke Nebu.Media.DB.insert/1 SQL path, and never via create/1 +
  # transition/4 composed together (that would leave a spurious extra
  # media_state_transitions row, see create_quarantined/1's own moduledoc).
  # The bytes themselves flow through encrypt_compress_and_store/5, the same
  # shared pipeline function store_and_quarantine/7 (Story 2b's async
  # handler) uses below — there is exactly ONE hash->compress->encrypt->
  # S3-write->persist implementation in this module (AC2).
  defp store_upload(conn, user, content_type, body) do
    server = server_name()
    create_and_store(conn, server, user, content_type, body, _retried? = false)
  end

  # `retried?` caps the media_id-collision retry to exactly one attempt,
  # mirroring do_create/3's own convention for create/1 above — a SECOND
  # {:error, :media_id_taken} in a row surfaces as a 500 instead of looping.
  defp create_and_store(conn, server, user, content_type, body, retried?) do
    media_id = generate_media_id()

    case state_machine_module().create_quarantined(%{
           media_id: media_id,
           server_name: server,
           uploader_user_id: user
         }) do
      {:ok, created_media_id} ->
        # Code-review MINOR-1 (2c cycle 1, accepted risk, 2026-07-14): if
        # create_quarantined/1 above succeeded but encrypt_compress_and_store/5
        # below fails (S3 put or the persist_upload UPDATE), this row is left
        # permanently in :quarantined with placeholder key material and NO scan
        # job ever enqueued. This is inherent to AC4's "create directly into
        # :quarantined" design and is NOT covered by the existing
        # unused-reservation reaper (which only sweeps :reserved rows) — a
        # stuck :quarantined row with no scan job is invisible to it. Left
        # unaddressed here (avoiding that would mean changing the create-order
        # or adding a compensating transition/new reaper, out of scope for this
        # story); a candidate for a future lifecycle/reaper story (ADR-030) to
        # sweep stuck :quarantined rows that never got a scan job, alongside
        # whatever mechanism that story already plans for :reserved rows.
        case encrypt_compress_and_store(created_media_id, server, content_type, nil, body) do
          :ok ->
            scan_enqueue_module().enqueue(created_media_id)
            send_json(conn, 200, %{"content_uri" => "mxc://#{server}/#{created_media_id}"})

          {:error, _reason} ->
            error(conn, 500, "M_UNKNOWN", "Failed to store media file")
        end

      {:error, :media_id_taken} when not retried? ->
        create_and_store(conn, server, user, content_type, body, true)

      {:error, _reason} ->
        error(conn, 500, "M_UNKNOWN", "Failed to store media file")
    end
  end

  # ── POST /_matrix/media/v1/create (media-security-admin-control/2a-post-media-create) ─
  #
  # Reservation half of Matrix's async upload flow (core-stable since spec
  # v1.7, no MSC label, no capability-discovery gate — clients simply try
  # this and fall back to the synchronous PUT above on failure). Reserves a
  # media_id via Nebu.Media.StateMachine.create/1 (the sole permitted writer
  # of a brand-new media_files row) and returns {content_uri,
  # unused_expires_at}. Reads no request body and accepts/ignores any query
  # parameters (AC6) — never trusts a client-supplied expiry (AC2/AC6). Never
  # touches Nebu.Media.Storage/Crypto and never stores a single byte — that
  # begins with Story 2b's PUT .../upload/{serverName}/{mediaId}.
  @default_max_pending_per_user 20
  @default_unused_expires_ms 86_400_000
  @default_pending_retry_after_ms 60_000

  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn) do
    user = conn.assigns[:current_user]

    cond do
      # Technical Requirements §6: permission (403) MUST be checked before the
      # pending-count check (429) — a forbidden user must never learn their
      # pending-upload count via a different error code.
      not permission_module().can_upload?(user) ->
        error(conn, 403, "M_FORBIDDEN", "You do not have permission to upload media")

      db_module().count_pending_reservations(user) >= max_pending_per_user() ->
        error_with_retry(conn, 429, "M_LIMIT_EXCEEDED", "Too many pending uploads")

      true ->
        do_create(conn, user, _retried? = false)
    end
  end

  # `retried?` caps the media_id-collision retry to exactly one attempt
  # (Technical Requirements §5, AC5) — a SECOND {:error, :media_id_taken} in
  # a row surfaces as a 500 instead of looping.
  defp do_create(conn, user, retried?) do
    server = server_name()
    media_id = generate_media_id()

    case state_machine_module().create(%{
           media_id: media_id,
           server_name: server,
           uploader_user_id: user
         }) do
      {:ok, created_media_id} ->
        expires_at = System.system_time(:millisecond) + unused_expires_ms()

        send_json(conn, 200, %{
          "content_uri" => "mxc://#{server}/#{created_media_id}",
          "unused_expires_at" => expires_at
        })

      {:error, :media_id_taken} when not retried? ->
        do_create(conn, user, true)

      {:error, _reason} ->
        error(conn, 500, "M_UNKNOWN", "Failed to reserve media")
    end
  end

  defp error_with_retry(conn, status, errcode, message) do
    send_json(conn, status, %{
      "errcode" => errcode,
      "error" => message,
      "retry_after_ms" => retry_after_ms()
    })
  end

  # ── PUT /_matrix/media/v3/upload/{serverName}/{mediaId} (media-security-admin-control/2b-put-media-upload) ─
  #
  # Async companion to upload/1 above: receives the bytes for a reservation
  # created earlier via create/1 (Story 2a). Validation order (AC7): lookup
  # (404) -> ownership (403) -> expiry (404) -> state guard (409) ->
  # blocked-type/mime_denylist (400, see validate_and_store_async/4) -> size
  # limit (413) -> body read -> store_and_quarantine/7 (the shared
  # persist-transition-enqueue seam Story 2c will also call).
  #
  # Code-review MINOR-1 (accepted risk, 2026-07-14): the state guard below
  # reads via lookup_reservation/2 with no row lock — two concurrent PUTs
  # against the same reservation could both pass this guard and both reach
  # store_and_quarantine/7. `StateMachine.transition/4`'s own `SELECT ... FOR
  # UPDATE` guarantees only one `:reserved -> :quarantined` transition
  # succeeds (the loser now surfaces a 500, per the MAJOR-1 fix below,
  # rather than a silent false-200), but nothing today serializes the two
  # S3 writes/persists themselves. Left unaddressed here — Story 2c's
  # shared-pipeline consolidation (this seam's other caller) is the more
  # appropriate place to add real serialization if this proves to matter in
  # practice, since it will need to reason about both upload paths at once.
  @spec upload_async(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def upload_async(conn, server_name, media_id) do
    user = conn.assigns[:current_user]

    case db_module().lookup_reservation(server_name, media_id) do
      {:error, :not_found} ->
        error(conn, 404, "M_NOT_FOUND", "Media not found")

      {:ok, row} ->
        cond do
          row.uploader_user_id != user ->
            error(conn, 403, "M_FORBIDDEN", "You did not create this media reservation")

          reservation_expired?(row.uploaded_at) ->
            error(conn, 404, "M_NOT_FOUND", "Media not found")

          row.state != :reserved ->
            error(conn, 409, "M_CANNOT_OVERWRITE_MEDIA", "This media has already been uploaded")

          true ->
            validate_and_store_async(conn, server_name, media_id, user)
        end
    end
  end

  # AC4: unused_expires_at is NOT a persisted column (2a computes it
  # in-memory only) — derived live from uploaded_at + the same config
  # resolver create/1 uses, so no cron dependency.
  defp reservation_expired?(uploaded_at) do
    uploaded_at + unused_expires_ms() < System.system_time(:millisecond)
  end

  defp validate_and_store_async(conn, server_name, media_id, user) do
    content_type = base_content_type(conn) || "application/octet-stream"
    max_bytes = max_upload_bytes()

    cond do
      # Code-review MAJOR-2 fix (2026-07-14): the hardcoded stored-XSS-vector
      # blocklist (text/html, image/svg+xml, etc. — see @blocked_upload_types)
      # already enforced by the sync upload/1 path was missing here, meaning
      # this route silently accepted content types the sync route deliberately
      # rejects. Same defense-in-depth relationship as story 9c's own intent
      # for the admin-configurable mime_denylist below: this hardcoded,
      # non-admin-editable list is checked FIRST (mirrors upload/1's own
      # ordering), the admin-configurable denylist SECOND — the two lists are
      # independent and are never merged (see Dev Agent Guardrails).
      content_type in @blocked_upload_types ->
        error(conn, 400, "M_BAD_JSON", "Content-Type not permitted for upload")

      # Story 9c wiring: mime_denylist_rejected?/1 was standalone/unwired
      # until this story. Must run on the already-normalized content_type,
      # before the size check (validation order, slot 5).
      mime_denylist_rejected?(content_type) ->
        error(conn, 400, "M_BAD_JSON", "Content-Type not permitted by admin policy")

      over_content_length?(conn, max_bytes) ->
        error(conn, 413, "M_TOO_LARGE", "Upload exceeds maximum allowed size")

      true ->
        conn = fetch_query_params(conn)
        filename = conn.query_params["filename"]

        case read_full_body(conn, max_bytes) do
          {:too_large, conn} ->
            error(conn, 413, "M_TOO_LARGE", "Upload exceeds maximum allowed size")

          {:read_error, conn} ->
            error(conn, 400, "M_UNKNOWN", "Failed to read upload body")

          # Code-review MINOR-2 fix (2026-07-14): match upload/1's F3 "empty
          # body must not be stored as a zero-byte object" behavior — the
          # async path was missing this guard entirely.
          {:ok, "", conn} ->
            error(conn, 400, "M_UNKNOWN", "Empty upload body not allowed")

          {:ok, body, conn} ->
            store_and_quarantine(conn, media_id, server_name, user, content_type, filename, body)
        end
    end
  end

  # ── shared persist-transition-enqueue seam (Story 2c reuses this) ─────────
  #
  # hash -> compress -> encrypt -> S3 write -> persist -> transition ->
  # enqueue. ADR-032 ordering (AC8/AC9): the S3 write MUST succeed before
  # persist_upload/1 or the state transition run — on failure the row stays
  # :reserved with storage_key still NULL, and the client's retry of the
  # same PUT is a normal, valid attempt (not a 409). The hash/compress/
  # encrypt/S3-write/persist sequence itself now lives in
  # encrypt_compress_and_store/5 — the SAME function store_upload/4's
  # create_and_store/6 calls above (media-security-admin-control/2c). This
  # function only adds what is specific to the ASYNC flow: transitioning an
  # EXISTING :reserved row to :quarantined (the sync flow has no such
  # transition — its row is created directly in :quarantined).
  defp store_and_quarantine(conn, media_id, server_name, _user, content_type, filename, body) do
    case encrypt_compress_and_store(media_id, server_name, content_type, filename, body) do
      :ok ->
        # Code-review MAJOR-1 fix (2026-07-14): persist_upload/1 and
        # transition/4 return values were previously discarded, so a failure
        # of either after a successful S3 write silently returned 200 to the
        # client while leaving the row in an inconsistent state (:quarantined
        # with NULL storage_key/placeholder key material, permanently
        # unretrievable — a retry would then 409 instead of succeeding).
        # Mirrors upload/1's own with/else gate onto a real 500.
        case state_machine_module().transition(media_id, :quarantined, {:system, nil}) do
          {:ok, _to_state} ->
            # Story 4b (not yet landed): real Oban enqueue. Until then this is
            # a safe no-op (see Nebu.Media.ScanEnqueue's own moduledoc).
            scan_enqueue_module().enqueue(media_id)
            send_json(conn, 200, %{})

          _ ->
            error(conn, 500, "M_UNKNOWN", "Failed to finalize media upload")
        end

      {:error, {:put_failed, _reason}} ->
        error(conn, 500, "M_UNKNOWN", "Failed to store media file")

      {:error, {:persist_failed, _reason}} ->
        error(conn, 500, "M_UNKNOWN", "Failed to finalize media upload")
    end
  end

  # ── shared hash -> compress -> encrypt -> S3-write -> persist pipeline ────
  # (media-security-admin-control/2c-sync-upload-shared-pipeline, AC2)
  #
  # The ONE implementation of this sequence in Nebu.Media — both the sync
  # handler (store_upload/4 -> create_and_store/6, above) and the async
  # handler (store_and_quarantine/7, below) call this exact function. Do NOT
  # add a second call site that reimplements hash/gzip/AES-256-GCM/S3-write —
  # that is precisely the duplication this story eliminates.
  #
  # Returns:
  #   * `:ok` once the S3 write AND the media_files persist both succeed.
  #   * `{:error, {:put_failed, reason}}` if the S3 write itself fails — the
  #     row is left exactly as it was (no storage_key/hash written).
  #   * `{:error, {:persist_failed, reason}}` if the S3 write succeeded but
  #     the media_files UPDATE failed — per ADR-032, the S3 write already
  #     happened by this point (an orphaned object, not a data-loss risk).
  defp encrypt_compress_and_store(media_id, server_name, content_type, filename, body) do
    file_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    {store_bytes, compressed?} = Nebu.Media.Storage.compress(body)

    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)
    ciphertext = Crypto.encrypt(store_bytes, key, nonce)

    # Story 11c wiring: compute_key/2 was standalone/unwired until 2b — this
    # is its only sanctioned call site in the codebase. The default template
    # ("{media_id}") interpolates to the same flat key the pre-11c fallback
    # used, so this does not change behavior until an admin configures a
    # non-default template.
    template = Nebu.Media.StorageConfig.get().s3_key_prefix_template

    storage_key =
      Nebu.Media.StorageConfig.compute_key(template, %{
        media_id: media_id,
        server_name: server_name,
        uploaded_at: DateTime.utc_now()
      })

    case storage_module().put(storage_key, ciphertext) do
      :ok ->
        case db_module().persist_upload(%{
               media_id: media_id,
               storage_key: storage_key,
               file_hash: file_hash,
               compressed: compressed?,
               content_type: content_type,
               filename: filename,
               aes_key_hex: Base.encode16(key, case: :lower),
               nonce_hex: Base.encode16(nonce, case: :lower),
               file_size: byte_size(body)
             }) do
          :ok -> :ok
          {:error, reason} -> {:error, {:persist_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:put_failed, reason}}
    end
  end

  # ── GET /_matrix/media/v3/download/{serverName}/{mediaId}[/{fileName}] (AC2/3/4) ─

  @spec download(Plug.Conn.t(), String.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  def download(conn, server_name, media_id, file_name \\ nil) do
    # media-security-admin-control/2d-download-stall-mechanism: opt-in
    # `?timeout_ms=N` stall. Absent/malformed => 0 => byte-for-byte 1c behavior
    # (no lookup, no subscribe, no wait — AC1/AC7). For a valid clamped
    # timeout > 0 AND a stallable state (:quarantined/:scanning), block on a
    # PubSub-driven wait BEFORE falling through to the exact same 1c
    # with_authorised_media/download_gate/serve_bytes path, which re-reads the
    # (possibly changed) state and applies the ADR-026 mapping to it.
    conn = fetch_query_params(conn)
    maybe_await_stall(server_name, media_id, clamped_stall_ms(conn.query_params["timeout_ms"]))

    with_authorised_media(conn, server_name, media_id, fn conn, row, plaintext ->
      serve_bytes(conn, row.content_type, plaintext, file_name || media_id)
    end)
  end

  # ── media-security-admin-control/2d-download-stall-mechanism ──────────────
  #
  # Config accessors kept tiny so Story 9's Nebu.Media.Config.get/0 swap is a
  # one-line change here, not a call-site change in the download handler.
  @default_max_stall_ms 20_000
  @default_max_concurrent_stalls 500

  @doc "Effective ceiling (ms) a `?timeout_ms` stall is clamped to (config)."
  @spec max_stall_ms() :: pos_integer()
  def max_stall_ms, do: media_config(:max_stall_ms, @default_max_stall_ms)

  @doc "Max number of simultaneously held download-stall requests (config)."
  @spec max_concurrent_stalls() :: pos_integer()
  def max_concurrent_stalls,
    do: media_config(:max_concurrent_stalls, @default_max_concurrent_stalls)

  defp media_config(key, default),
    do: Application.get_env(:nebu, Nebu.Media, []) |> Keyword.get(key, default)

  # Parse/validate/clamp `?timeout_ms`. Non-integer, negative, or zero (and
  # absent) all collapse to 0 = "do not stall", exactly 1c behavior (AC1/AC7).
  # A value above the cap is silently clamped, not an error (AC2).
  defp clamped_stall_ms(nil), do: 0

  defp clamped_stall_ms(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      # `n` is already guarded > 0; the only way this can go non-positive is a
      # misconfigured negative `max_stall_ms` in config — `max(0, …)` collapses
      # that to 0 = "do not stall" instead of yielding a negative clamped value
      # that would crash the stall-eligible download (fix-cycle 1, MINOR-2).
      {n, ""} when n > 0 -> min(n, max(0, max_stall_ms()))
      _ -> 0
    end
  end

  # `conn.query_params["timeout_ms"]` is a `String.t()` for a normal
  # `?timeout_ms=N` query string, but Plug parses a repeated/array-shaped key
  # (e.g. `?timeout_ms[]=1`) into a list, and Plug.Conn.Query.decode/1 can also
  # nest a map for `?timeout_ms[x]=1`. Neither `nil` nor `is_binary/1` above
  # matches those shapes — this catch-all treats any non-string, non-nil value
  # identically to "absent" (AC7's "not a client error" posture extended to
  # match), instead of raising FunctionClauseError/500 on a malformed request
  # (fix-cycle 2, MINOR — a graceful-degradation gap left by MINOR-2's fix).
  defp clamped_stall_ms(_other), do: 0

  # Only :quarantined/:scanning are stalled on (AC3): a scan is pending/running
  # so a terminal broadcast may still arrive. :reserved (no scan job yet) and
  # every other state fall straight through to the immediate 1c response. The
  # `<= 0` guard (not just `== 0`) also absorbs a misconfigured negative
  # `max_stall_ms` defensively — such a request degrades to the immediate 1c
  # response rather than raising FunctionClauseError (fix-cycle 1, MINOR-2).
  defp maybe_await_stall(_server_name, _media_id, clamped_ms) when clamped_ms <= 0, do: :ok

  defp maybe_await_stall(server_name, media_id, clamped_ms) when clamped_ms > 0 do
    case current_state(server_name, media_id) do
      state when state in [:quarantined, :scanning] ->
        Nebu.Media.DownloadStall.await(
          media_id,
          clamped_ms,
          max_concurrent_stalls(),
          fn -> current_state(server_name, media_id) end
        )

        :ok

      _other ->
        :ok
    end
  end

  defp current_state(server_name, media_id) do
    case db_module().lookup(server_name, media_id) do
      {:ok, row} -> row.state
      {:error, :not_found} -> nil
    end
  end

  # ── GET /_matrix/media/v3/thumbnail/{serverName}/{mediaId} (AC7) ───────────

  @spec thumbnail(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def thumbnail(conn, server_name, media_id) do
    with_authorised_media(conn, server_name, media_id, fn conn, row, plaintext ->
      # Thumbnail generation via libvips/Image is intentionally NOT used: the
      # Alpine build/test container has no native vips toolchain, and the Matrix
      # spec permits streaming the original for small images. We serve the
      # decrypted original inline as an image/* response (AC7 asserts the response
      # contract — 200 + image Content-Type + bytes + inline Content-Disposition —
      # not exact pixel dimensions). On-demand resizing is a tracked follow-up.
      ct = if image_type?(row.content_type), do: row.content_type, else: "image/png"
      serve_inline_image(conn, ct, plaintext, media_id)
    end)
  end

  # ── GET /_matrix/media/v3/preview_url?url=... (AC5) ────────────────────────

  @spec preview_url(Plug.Conn.t()) :: Plug.Conn.t()
  def preview_url(conn) do
    conn = fetch_query_params(conn)
    url = conn.query_params["url"]

    cond do
      is_nil(url) or url == "" ->
        error(conn, 400, "M_MISSING_PARAM", "Missing required 'url' parameter")

      true ->
        # SSRF guard runs BEFORE any fetch (Kassandra). On a blocked target the
        # fetch boundary is never reached.
        case SSRF.check(url) do
          :ok -> do_preview(conn, url)
          {:error, _reason} -> error(conn, 403, "M_FORBIDDEN", "URL not permitted")
        end
    end
  end

  defp do_preview(conn, url) do
    case fetch_module().fetch(url) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        send_json(conn, 200, extract_og_tags(body))

      _ ->
        error(conn, 502, "M_UNKNOWN", "Failed to fetch preview")
    end
  end

  # Parse Open Graph meta tags into a flat JSON map (oracle §5). Floki is a pure
  # Elixir HTML parser; only OG `property` meta tags are surfaced.
  defp extract_og_tags(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("meta[property^=\"og:\"]")
        |> Enum.reduce(%{}, fn node, acc ->
          prop = Floki.attribute(node, "property") |> List.first()
          content = Floki.attribute(node, "content") |> List.first()

          if is_binary(prop) and is_binary(content) and not Map.has_key?(acc, prop) do
            Map.put(acc, prop, content)
          else
            acc
          end
        end)

      _ ->
        %{}
    end
  end

  # ── Admin actions (media-security-admin-control/6a-routine-state-actions) ──
  #
  # ADR-020: these are the ONLY sanctioned entry points `Nebu.Admin.MediaLive`
  # (Story 5a/6a) may call for a write against `media_files.state` — never
  # `Nebu.Media.StateMachine` directly. Each function does exactly two things
  # transactionally-adjacent to each other: (1) drive `state` through
  # `Nebu.Media.StateMachine.transition/4` (the only legal write path, Story
  # 1b), and (2) bridge the admin-driven event into the global `audit_log` via
  # `Nebu.Compliance.AuditWriter.log/6` (the same bridge pattern Story 4c
  # established for system-driven `:infected`/`:scan_failed` events, ADR-028).
  #
  # `admin_id` is a plain Matrix-ID string (e.g. `"@kai:test.local"`) — the
  # SAME identity shape as `audit_log.actor_user_id`/`users.user_id`, read
  # from `socket.assigns.current_user["matrix_user_id"]` by the caller, never
  # a UUID. See migration `000029_media_state_transitions_actor_id_text` and
  # `Nebu.Media.StateMachine`'s `@type actor` for why this matters: 6a is the
  # first real caller of the `{:admin, admin_id}` actor tuple, and it
  # surfaced a latent mismatch (the column used to be UUID; no such identity
  # exists anywhere in this app's real data model).
  #
  # On `{:error, {:invalid_transition, _, _}}` from `transition/4` (AC8): no
  # audit write happens — a rejected, no-op attempt is not itself a
  # compliance-relevant admin action (nothing changed). AC9's idempotent
  # no-ops (Block already-blocked, Unblock already-released) are checked
  # BEFORE calling `transition/4` at all, in this module, not inside the
  # state machine's guard table — there is no `:admin_blocked ->
  # :admin_blocked`/`:released -> :released` edge, and there should not be
  # one; idempotency here is this story's own admin-facing UX decision.

  @spec admin_block(media_id :: String.t(), admin_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, :admin_blocked}
          | {:ok, :already_blocked}
          | {:error, {:invalid_transition, atom(), atom()}}
          | {:error, :not_found}
  def admin_block(media_id, admin_id, reason \\ nil) do
    case db_module().lookup_state(media_id) do
      {:ok, :admin_blocked} ->
        {:ok, :already_blocked}

      {:ok, _other_state} ->
        metadata = %{reason: blank_to_nil(reason)}

        case state_machine_module().transition(
               media_id,
               :admin_blocked,
               {:admin, admin_id},
               metadata
             ) do
          {:ok, :admin_blocked} ->
            write_admin_audit(admin_id, "media_blocked", media_id, metadata)
            {:ok, :admin_blocked}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec admin_unblock(media_id :: String.t(), admin_id :: String.t()) ::
          {:ok, :released}
          | {:ok, :already_released}
          | {:error, {:invalid_transition, atom(), atom()}}
          | {:error, :not_found}
  def admin_unblock(media_id, admin_id) do
    case db_module().lookup_state(media_id) do
      {:ok, :released} ->
        {:ok, :already_released}

      {:ok, _other_state} ->
        case state_machine_module().transition(media_id, :released, {:admin, admin_id}, %{}) do
          {:ok, :released} ->
            write_admin_audit(admin_id, "media_unblocked", media_id, %{})
            {:ok, :released}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec admin_delete(media_id :: String.t(), admin_id :: String.t()) ::
          {:ok, :deleted}
          | {:error, {:invalid_transition, atom(), atom()}}
          | {:error, :not_found}
  def admin_delete(media_id, admin_id) do
    case db_module().lookup_state(media_id) do
      {:ok, from_state} ->
        case state_machine_module().transition(media_id, :deleted, {:admin, admin_id}, %{}) do
          {:ok, :deleted} ->
            write_admin_audit(admin_id, "media_deleted", media_id, %{from_state: from_state})
            {:ok, :deleted}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # AC4: Rescan does NOT call StateMachine.transition/4 at all — it only
  # validates the current state is eligible, then re-enqueues a scan job via
  # the EXISTING `:media_scan_enqueue_module` seam (`Nebu.Media.ScanEnqueue`,
  # already wired to a real `Oban.insert/1` since Story 4b — the same seam
  # `create_and_store/6`/`store_and_quarantine/7` above already call). Story
  # 4b's own worker performs the real `:quarantined -> :scanning` transition
  # once it picks the job up; this function never simulates or duplicates
  # that.
  @spec admin_rescan(media_id :: String.t(), admin_id :: String.t()) ::
          {:ok, :rescan_queued}
          | {:error, :invalid_state_for_rescan}
          | {:error, :not_found}
  def admin_rescan(media_id, admin_id) do
    case db_module().lookup_state(media_id) do
      {:ok, state} when state in [:quarantined, :scan_failed] ->
        scan_enqueue_module().enqueue(media_id)
        write_admin_audit(admin_id, "media_rescanned", media_id, %{from_state: state})
        {:ok, :rescan_queued}

      {:ok, _other_state} ->
        {:error, :invalid_state_for_rescan}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ── Infected override (media-security-admin-control/6c-infected-override) ──
  #
  # The deliberate, narrow exception to the guard table's "infected is
  # terminal beyond -> deleted" rule (Story 1b): a ClamAV false positive is a
  # real operational scenario, and this is the ONE sanctioned way out of it.
  # Three things keep this an exception rather than a scanner bypass: (1) the
  # :infected -> :released edge is reachable through exactly this function,
  # gated by the distinct `media_admin_override` grant (AC6) — narrower than
  # generic admin, checked here independently of whatever the LiveView
  # already hid; (2) a mandatory, server-validated, non-cached reason (AC2/
  # AC8) — never a UI-only affordance; (3) the event bridges into the global
  # audit_log with that reason and the original ClamAV signature preserved
  # (AC4/AC5), same bridge pattern as 6a's other admin_* actions above.
  #
  # Order matters and is deliberate (AC2/AC6): reason validation and the role
  # check both happen BEFORE any state lookup or transition attempt — a blank
  # reason or an unauthorized caller never even reaches the guard table, so
  # no {:error, {:invalid_transition, ...}} noise obscures the real rejection
  # reason.
  @spec admin_override_infected(
          media_id :: String.t(),
          admin_id :: String.t(),
          reason :: String.t() | nil
        ) ::
          {:ok, :released}
          | {:error, :reason_required}
          | {:error, :forbidden}
          | {:error, {:invalid_transition, atom(), atom()}}
          | {:error, :not_found}
  def admin_override_infected(media_id, admin_id, reason) do
    with :ok <- validate_reason(reason),
         :ok <- authorize_override(admin_id),
         {:ok, current_state} <- db_module().lookup_state(media_id),
         :ok <- check_infected(current_state) do
      metadata = %{reason: String.trim(reason), original_signature: scan_signature(media_id)}

      case state_machine_module().transition(media_id, :released, {:admin, admin_id}, metadata) do
        {:ok, :released} = ok ->
          write_admin_audit(admin_id, "media_infected_override", media_id, metadata)
          ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # AC1: this action's whole purpose is the narrow :infected -> :released
  # exception — the shared guard table's `allowed?/2` alone is NOT sufficient
  # to enforce that, because :scanning -> :released (clean-scan result),
  # :admin_blocked -> :released (admin_unblock, 6a), and :scan_failed ->
  # :released (admin manual clear, 4a) are ALL independently legal edges in
  # `@transitions` for OTHER callers/actions. Without this explicit check,
  # calling admin_override_infected/3 against a genuinely-:scanning,
  # -:admin_blocked, or -:scan_failed file would silently succeed via that
  # shared edge instead of being rejected — caught by this story's own
  # table-driven Acceptance Test 9 (RED against the first non-infected state
  # with such an edge, :scanning, before this check was added). Mirrors AC1's
  # own error shape exactly: {:error, {:invalid_transition, from, :released}},
  # written before any transition/4 call or audit write.
  defp check_infected(:infected), do: :ok
  defp check_infected(other), do: {:error, {:invalid_transition, other, :released}}

  # AC2: rejects nil/absent, empty-string, and whitespace-only reasons —
  # trimmed BEFORE the emptiness check, so "   " is caught, not just "". This
  # is the enforcement point of record: it runs regardless of whatever the
  # LiveView's own client-side "disabled while blank" affordance does or
  # doesn't intercept first (Dev Agent Guardrails — do not weaken this).
  defp validate_reason(reason) do
    if is_binary(reason) and String.trim(reason) != "" do
      :ok
    else
      {:error, :reason_required}
    end
  end

  # AC6: re-checked here independent of the LiveView's own row-rendering
  # decision — a replayed/forged phx-click payload against an admin session
  # that never actually holds this grant must still be rejected.
  defp authorize_override(admin_id) do
    if db_module().check_override_role(admin_id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  # AC4: reads the ClamAV signature the file was originally flagged under —
  # `media_files.scan_metadata["clamav_signature"]`, the key Story 4b's
  # worker actually persists (NOT the epic narrative's shorthand
  # "signature" key, which is not a real column key; same schema-reality
  # drift 6b already hit and fixed for its own read path).
  defp scan_signature(media_id) do
    case db_module().lookup_scan_metadata(media_id) do
      %{} = metadata -> Map.get(metadata, "clamav_signature")
      _ -> nil
    end
  end

  # AuditWriter.log/6 never raises; a failed audit write is logged and does
  # not affect this module's own return value (no transaction coupling with
  # the state-machine write already committed — same posture as
  # Nebu.Workers.MediaScanWorker's own write_audit/4, 4c).
  defp write_admin_audit(admin_id, action, media_id, metadata) do
    case audit_writer().log(admin_id, action, "media", media_id, metadata, "success") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Nebu.Media: audit write failed action=#{action} media_id=#{media_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(reason) when is_binary(reason), do: reason
  defp blank_to_nil(_), do: nil

  # ── shared: lookup → membership → fetch → decrypt ──────────────────────────

  defp with_authorised_media(conn, server_name, media_id, on_ok) do
    user = conn.assigns[:current_user]

    case db_module().lookup(server_name, media_id) do
      {:ok, row} ->
        case download_gate(row.state) do
          :serve ->
            if membership_module().member?(row.room_id, user) do
              fetch_and_decrypt(conn, row, on_ok)
            else
              error(conn, 403, "M_FORBIDDEN", "You are not a member of this room")
            end

          {status, errcode} ->
            error(conn, status, errcode, gate_message(errcode))
        end

      {:error, :not_found} ->
        error(conn, 404, "M_NOT_FOUND", "Media not found")
    end
  end

  # ── media-security-admin-control/download-gate (1c, ADR-026) ──────────────
  #
  # Single enforcement point for the media_files lifecycle `state` column
  # (Story 1a schema, Story 1b's Nebu.Media.StateMachine is the sole writer —
  # this module is read-only). Runs immediately after the row lookup and
  # BEFORE the room-membership check and BEFORE fetch_and_decrypt/3 (AC7): a
  # denied non-released file must never reach Nebu.Media.Storage.get/1 or
  # Crypto.decrypt/3, and must deny identically regardless of membership.
  #
  # `:released` is the SOLE explicit positive match (AC5 — an allow-list, not
  # a deny-list). Every other clause, including the catch-all tail, denies —
  # a brand-new/unrecognized ENUM value (e.g. a future migration's state, or
  # Story 4a's :scan_failed before it ships) MUST fall through to the 451
  # default-deny catch-all, never to :serve (AC6).
  defp download_gate(:released), do: :serve

  # AC2/6a-security-review-fix (2026-07-19): admin_blocked returns a
  # byte-identical 404 + M_NOT_FOUND — SAME status line AND same body as
  # :infected/:deleted/:hard_deleted/a genuine unknown-media-id 404, never a
  # distinguishing status. Do not change this to 451 or any other status,
  # errcode, or message (see Dev Agent Guardrails). This is what keeps a
  # moderation action indistinguishable from a file that never existed.
  #
  # CORRECTED (Kassandra security-review, media-security-admin-control/
  # 6a-routine-state-actions, 2026-07-19 — self-caught before commit, own
  # sanctum MEMORY.md Recurring Pattern "Anonymity by identical BODY but
  # distinguishable STATUS is not anonymity"): this clause previously
  # returned `{451, "M_NOT_FOUND"}` — status DIFFERED from a genuine 404
  # while only the body/errcode were anonymized. That is NOT anonymity: the
  # (451, M_NOT_FOUND) combination was unique to :admin_blocked (every other
  # state returns either 404+M_NOT_FOUND or 451+M_NOT_YET_UPLOADED, never
  # this pairing), so the bare HTTP status line alone was a perfect oracle
  # for "an admin blocked this," fingerprintable without even reading the
  # response body. True indistinguishability requires identical status AND
  # identical body — this product's explicit design goal since 1c is
  # anonymity of admin-blocking (the opposite of RFC-7725-style legal-
  # transparency blocking, which deliberately DOES want a distinguishable
  # 451). Flagged as a MUST-FIX-when-live watch-flag in Kassandra's own 1c
  # review ("Dormant until the mutation path (Story 6a admin-block trigger)
  # ships → then live") — 6a is that trigger, so this is now fixed, not
  # merely re-documented.
  defp download_gate(:admin_blocked), do: {404, "M_NOT_FOUND"}

  # AC3: terminal-negative states (and, since 6a's security-review fix
  # above, :admin_blocked too) are genuine, byte-identical 404s.
  defp download_gate(state) when state in [:infected, :deleted, :hard_deleted],
    do: {404, "M_NOT_FOUND"}

  # AC1/AC6: everything else — :reserved/:quarantined/:scanning today, and any
  # future/unrecognized atom tomorrow — defaults to pending/451, never serve.
  defp download_gate(_other), do: {451, "M_NOT_YET_UPLOADED"}

  # AC2's anonymity property depends on reusing the EXACT existing "Media not
  # found" string already used by the unknown-media-id 404 branch above and by
  # fetch_and_decrypt/3's not-found branch — do not introduce a new string.
  defp gate_message("M_NOT_FOUND"), do: "Media not found"
  defp gate_message("M_NOT_YET_UPLOADED"), do: "Media not yet available"

  # media-security-admin-control/8c-media-archive-worker (AC11): once
  # MediaArchiveWorker sets row.archived_at, the object physically lives in
  # the archive bucket (and, if archive_delete_from_primary is enabled, no
  # longer in the primary one at all) — this switch runs AFTER Story 1c's
  # download-gate state check has already decided to serve, and picks WHICH
  # bucket to read the byte-identical storage_key from. No third branch, no
  # silent fallback: archived_at truthy -> archive bucket, falsy -> primary,
  # exactly as today.
  defp fetch_and_decrypt(conn, row, on_ok) do
    get_result =
      if row.archived_at do
        storage_module().get_from_archive(row.storage_key)
      else
        storage_module().get(row.storage_key)
      end

    with {:ok, ciphertext} <- get_result,
         {:ok, key} <- Base.decode16(row.aes_key_hex, case: :mixed),
         {:ok, nonce} <- Base.decode16(row.nonce_hex, case: :mixed),
         {:ok, plaintext} <- Crypto.decrypt(ciphertext, key, nonce) do
      # fix-media-download-gzip-decompression: ADR-029's compress-before-
      # encrypt ordering (Nebu.Media.Storage.compress/1, store-smaller-of-two)
      # means decompression is the LAST step, after decryption, and applies
      # equally to BOTH callers of this shared function (download/4's
      # serve_bytes/4 and thumbnail/3's serve_inline_image/4) — fixed once
      # here rather than in each on_ok callback. Mirrors
      # Nebu.Workers.MediaScanWorker's own maybe_gunzip/2 (AC4 there): called
      # OUTSIDE the `with`/`else` mapping, on purpose.
      #
      # code-review fix (fix-media-download-gzip-decompression, cycle 1,
      # MINOR): `Crypto.decrypt/3` immediately above already verified the
      # AES-256-GCM authentication tag over exactly these bytes, which rules
      # out at-rest/in-transit corruption — a tampered or bit-rotted
      # ciphertext fails that tag check and never reaches this line. So a
      # `:zlib.gunzip/1` raise here cannot mean "the stored object is
      # corrupt"; the only reachable cause is a writer-side invariant
      # violation — this row's `compressed` flag and its actually-stored
      # bytes disagree (e.g. a future bug in `encrypt_compress_and_store/5`,
      # or an out-of-band `UPDATE media_files SET compressed`). That is still
      # a real, if rare, failure mode, so it is rescued below into the same
      # 502 "storage unavailable" shape already used for the S3/base16/AEAD
      # failures the `with` clauses above guard, instead of crashing this
      # request uncaught (which would bypass `RequestLogger`'s
      # `register_before_send/2` and skip the `operational_logs` audit row).
      case safe_maybe_gunzip(plaintext, Map.get(row, :compressed, false)) do
        {:ok, bytes} ->
          on_ok.(conn, row, bytes)

        :error ->
          Logger.error(
            "Nebu.Media: :zlib.gunzip/1 failed for media_id=#{row.media_id} — " <>
              "compressed flag and stored bytes disagree"
          )

          error(conn, 502, "M_UNKNOWN", "Media storage unavailable")
      end
    else
      {:error, :not_found} ->
        error(conn, 404, "M_NOT_FOUND", "Media not found")

      _ ->
        error(conn, 502, "M_UNKNOWN", "Media storage unavailable")
    end
  end

  # Guards maybe_gunzip/2 against a raising :zlib.gunzip/1 (see the caller's
  # comment above for why this is reachable only via a writer-side
  # invariant violation, never at-rest/in-transit corruption). Deliberately
  # does NOT log the raw bytes or the rescued exception/stacktrace — the
  # caller logs a media_id-only message instead.
  defp safe_maybe_gunzip(bytes, compressed?) do
    {:ok, maybe_gunzip(bytes, compressed?)}
  rescue
    _ -> :error
  end

  defp maybe_gunzip(bytes, true), do: :zlib.gunzip(bytes)
  defp maybe_gunzip(bytes, false), do: bytes
  # Fail-open catch-all (code-review fix, MINOR): a missing/nil/malformed
  # `compressed` value must not raise FunctionClauseError/KeyError — it
  # passes the bytes through unchanged, mirroring this module's other
  # NULL-tolerant reads (e.g. `archived_at`) and non-crashing fallbacks
  # (e.g. `Nebu.Media.DB.parse_state/1`).
  defp maybe_gunzip(bytes, _other), do: bytes

  # ── byte serving + Range (AC2/AC3 + oracle §1/§2/§4) ───────────────────────

  defp serve_bytes(conn, content_type, plaintext, file_name) do
    {ct, disposition} = disposition_for(content_type, file_name)

    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-disposition", disposition)
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
    |> put_resp_header(
      "content-security-policy",
      "sandbox; default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; object-src 'self';"
    )
    |> put_resp_content_type(ct)
    |> maybe_send_ranged(plaintext)
  end

  defp serve_inline_image(conn, content_type, bytes, file_name) do
    conn
    |> put_resp_header("content-disposition", ~s(inline; filename="#{file_name}"))
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
    # F-4: serve the inline (thumbnail) path with the SAME CSP/sandbox header set
    # as serve_bytes/4 so content-serving posture is consistent (defense in depth
    # for inline-served decrypted bytes; the global nosniff already prevents
    # content-type sniffing, this hardens against active content rendering).
    |> put_resp_header(
      "content-security-policy",
      "sandbox; default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; object-src 'self';"
    )
    |> put_resp_content_type(content_type)
    |> send_resp(200, bytes)
  end

  defp maybe_send_ranged(conn, plaintext) do
    total = byte_size(plaintext)

    case parse_range(get_req_header(conn, "range"), total) do
      :none ->
        send_resp(conn, 200, plaintext)

      {:ok, first, last} ->
        slice = binary_part(plaintext, first, last - first + 1)

        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
        |> send_resp(206, slice)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{total}")
        |> send_resp(416, "")
    end
  end

  # Parse a single-range "bytes=start-end" header (oracle §4). `end` clamps to the
  # object end; a start beyond the object is unsatisfiable (416).
  defp parse_range([], _total), do: :none

  defp parse_range([value | _], total) do
    case value do
      "bytes=" <> spec -> parse_range_spec(spec, total)
      _ -> :none
    end
  end

  defp parse_range_spec(spec, total) do
    case String.split(spec, "-", parts: 2) do
      [start_s, end_s] ->
        start = parse_int(start_s)
        stop = parse_int(end_s)

        cond do
          is_nil(start) -> :none
          start >= total -> :unsatisfiable
          start < 0 -> :unsatisfiable
          is_nil(stop) -> {:ok, start, total - 1}
          stop < start -> :unsatisfiable
          true -> {:ok, start, min(stop, total - 1)}
        end

      _ ->
        :none
    end
  end

  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # ── Content-Disposition (oracle §1) ────────────────────────────────────────

  defp disposition_for(content_type, file_name) do
    base = base_type(content_type)

    if base in @safe_inline_types do
      {content_type, ~s(inline; filename="#{file_name}")}
    else
      {"application/octet-stream", ~s(attachment; filename="#{file_name}")}
    end
  end

  defp image_type?(content_type), do: String.starts_with?(base_type(content_type), "image/")

  defp base_type(nil), do: ""

  defp base_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  # ── body reading + size limit (AC1, oracle §7) ─────────────────────────────

  defp over_content_length?(conn, max_bytes) do
    case get_req_header(conn, "content-length") do
      [cl | _] ->
        case Integer.parse(cl) do
          {n, _} -> n > max_bytes
          :error -> false
        end

      _ ->
        false
    end
  end

  # Read the body in chunks, bailing as soon as the running total exceeds the
  # limit (never buffers more than max_bytes + one chunk).
  defp read_full_body(conn, max_bytes), do: read_full_body(conn, max_bytes, <<>>)

  defp read_full_body(conn, max_bytes, acc) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        acc = acc <> chunk
        if byte_size(acc) > max_bytes, do: {:too_large, conn}, else: {:ok, acc, conn}

      {:more, chunk, conn} ->
        acc = acc <> chunk

        if byte_size(acc) > max_bytes,
          do: {:too_large, conn},
          else: read_full_body(conn, max_bytes, acc)

      # F1: read_body errored mid-stream (truncated/aborted upload). Do NOT treat
      # the partial accumulator as a complete body — surface a distinct error so
      # the handler responds 400 instead of encrypting+storing corrupt data.
      {:error, _} ->
        {:read_error, conn}
    end
  end

  defp base_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [ct | _] -> base_type(ct)
      _ -> nil
    end
  end

  defp generate_media_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # ── boundary + config resolution ───────────────────────────────────────────

  defp storage_module,
    do: Application.get_env(:nebu_http, :media_storage_module, Nebu.Media.Storage)

  defp db_module, do: Application.get_env(:nebu_http, :media_db_module, Nebu.Media.DB)

  defp membership_module,
    do: Application.get_env(:nebu_http, :media_membership_module, Nebu.Media.Membership)

  defp fetch_module,
    do: Application.get_env(:nebu_http, :media_http_fetch_module, Nebu.Media.HttpFetch)

  defp permission_module,
    do: Application.get_env(:nebu_http, :media_permission_module, Nebu.Media.Permission)

  defp state_machine_module,
    do: Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)

  defp scan_enqueue_module,
    do: Application.get_env(:nebu_http, :media_scan_enqueue_module, Nebu.Media.ScanEnqueue)

  # media-security-admin-control/6a-routine-state-actions: same seam
  # convention/key as Nebu.Workers.MediaScanWorker's own audit_writer/0 (4c)
  # — :nebu_http namespace, mirroring every other Nebu.Media boundary module
  # above, not the :compliance, :audit_writer key Nebu.Admin.UsersController
  # uses for the same purpose in a different domain.
  defp audit_writer,
    do: Application.get_env(:nebu_http, :media_audit_writer_module, Nebu.Compliance.AuditWriter)

  defp max_upload_bytes,
    do: Application.get_env(:nebu_http, :media_max_upload_bytes, @default_max_upload_bytes)

  # media-security-admin-control/2a-post-media-create: 9a's Nebu.Media.Config
  # is not a dependency of this story (see the story's "Open assumptions") —
  # reads straight from config.exs/Application env, same pattern as
  # max_upload_bytes/0 above. A 9a follow-up can point this key at
  # Nebu.Media.Config.get/0 without changing the create/1 call site.
  defp max_pending_per_user,
    do:
      Application.get_env(:nebu_http, :media_max_pending_per_user, @default_max_pending_per_user)

  defp unused_expires_ms,
    do: Application.get_env(:nebu_http, :media_unused_expires_ms, @default_unused_expires_ms)

  defp retry_after_ms,
    do:
      Application.get_env(
        :nebu_http,
        :media_pending_retry_after_ms,
        @default_pending_retry_after_ms
      )

  defp server_name, do: Application.get_env(:nebu_http, :server_name, "localhost")

  # ── response helpers ────────────────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp error(conn, status, errcode, message) do
    send_json(conn, status, %{"errcode" => errcode, "error" => message})
  end
end
