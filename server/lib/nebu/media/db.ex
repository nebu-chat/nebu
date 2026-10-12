defmodule Nebu.Media.DB do
  @moduledoc """
  Inline-SQL `media_files` access (ADR-018: no domain model, locality of behavior).

  Mirrors the legacy Go media gateway's `MediaStore` (insert on upload, lookup on
  download) but as a direct `Ecto.Adapters.SQL.query/3` call against `Nebu.Repo` —
  no Ecto schema, changeset, or repository layer. SQL duplication with other DB
  modules (room/db.ex, search/db.ex) is a deliberate ADR-018 feature.

  The production default for the `:media_db_module` seam: tests swap it for a
  function-backed fake (`Nebu.Web.MediaFakes.DB`).

  ## Row shape returned by `lookup/2`

  An atom-keyed map mirroring the `media_files` columns plus a derived
  `:storage_key` and `:room_id`:

    * `media_files` has NO `room_id` column. Media is uploaded by a user, not a
      room; Nebu's room-membership access check (AC4) scopes a download to the
      rooms the requesting user belongs to. So `:room_id` is left `nil` here and
      the handler treats a media file as accessible to any room the user is a
      member of (see `Nebu.Media.Membership`). The injected test fake carries
      an explicit `:room_id` because the membership fake keys on it; production
      derives access from the user's own memberships instead.
    * `:state` — the `media_state` ENUM lifecycle column (Story 1a/1b). `lookup/2`
      no longer filters `WHERE deleted = false`; every row (including
      `state: :deleted` / `:hard_deleted`) reaches the caller so the
      handler-level download gate (`Nebu.Media.with_authorised_media/4`,
      Story 1c) is the single enforcement point (ADR-026). Only a row with no
      matching `(server_name, media_id)` at all short-circuits to
      `{:error, :not_found}`.
    * `:compressed` — mirrors `media_files.compressed` (migration 000022,
      ADR-029 store-smaller-of-two). `true` means the stored ciphertext is a
      gzip of the original plaintext (`Nebu.Media.Storage.compress/1`,
      written at upload time by `encrypt_compress_and_store/5`) and must be
      `:zlib.gunzip/1`'d after decryption before being served
      (`Nebu.Media.fetch_and_decrypt/3`, fix-media-download-gzip-decompression).

  ## KNOWN LIMITATION (tracked follow-up) — per-media room scoping

  Because `media_files` carries no `room_id`, production cannot pin a media file
  to the room it was shared in. `lookup/2` therefore always returns `room_id: nil`,
  and `Membership.member?(nil, user)` degrades to "is the user a member of ANY
  room". Net effect: any authenticated user who is a member of at least one room
  can download any media id. This is FAIL-CLOSED (a user in zero rooms is denied)
  and stricter than the Matrix spec (which allows unauthenticated media), but it
  is broader than ideal per-media scoping. Tightening this to a true per-media
  room link requires a schema change (add `media_files.room_id` or a join table)
  and is a tracked follow-up flagged to security-review as a known, accepted gap.
  """

  @sql_lookup """
  SELECT media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state, storage_key, archived_at,
         compressed, filename
  FROM media_files
  WHERE server_name = $1 AND media_id = $2
  LIMIT 1
  """

  @sql_insert """
  INSERT INTO media_files
    (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
     uploader_user_id, uploaded_at, deleted)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, false)
  """

  @doc """
  Looks up a `media_files` row by `(server_name, media_id)`.

  Returns `{:ok, row_map}` (atom keys) or `{:error, :not_found}`. A DB error also
  maps to `{:error, :not_found}` fail-closed so an unreachable store yields a
  404, never a bytes leak.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(server_name, media_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lookup, [server_name, media_id]) do
      {:ok, %{rows: [row]}} ->
        {:ok, to_map(row)}

      _ ->
        {:error, :not_found}
    end
  end

  @sql_count_pending_reservations """
  SELECT COUNT(*) FROM media_files WHERE uploader_user_id = $1 AND state = 'reserved'
  """

  @doc """
  Counts `uploader_user_id`'s outstanding `:reserved` `media_files` rows —
  i.e. reservations from `POST /_matrix/media/v1/create` never followed by a
  successful `PUT` (media-security-admin-control/2a-post-media-create, AC3).
  Compared against `max_pending_per_user` by `Nebu.Media.create/1`; a DB
  error degrades to `0` (never blocks a reservation on a transient counting
  failure — this is a soft business limit, not a security control).
  """
  @spec count_pending_reservations(String.t()) :: non_neg_integer()
  def count_pending_reservations(uploader_user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_count_pending_reservations, [uploader_user_id]) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  @sql_lookup_reservation """
  SELECT uploader_user_id, state, uploaded_at
  FROM media_files
  WHERE server_name = $1 AND media_id = $2
  LIMIT 1
  """

  @doc """
  Reservation-aware lookup for `media-security-admin-control/2b-put-media-
  upload`'s async PUT handler. Unlike `lookup/2` (used by download/thumbnail,
  which is scoped to serving already-`:released` content through the
  download gate), this returns a row for ANY `state` — AC3 (403 ownership)
  and AC5 (409 wrong state) both need to inspect a row that may be
  `:reserved`, `:quarantined`, `:released`, `:infected`, etc.

  Returns `{:ok, row}` (atom keys: `:uploader_user_id`, `:state`,
  `:uploaded_at`) or `{:error, :not_found}`. There is no `unused_expires_at`
  column — expiry is derived by the caller from `:uploaded_at` plus the
  configured TTL (see `Nebu.Media.upload_async/3`).
  """
  @spec lookup_reservation(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_reservation(server_name, media_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lookup_reservation, [server_name, media_id]) do
      {:ok, %{rows: [[uploader_user_id, state, uploaded_at]]}} ->
        {:ok,
         %{
           uploader_user_id: uploader_user_id,
           state: parse_state(state),
           uploaded_at: uploaded_at
         }}

      _ ->
        {:error, :not_found}
    end
  end

  @sql_persist_upload """
  UPDATE media_files
  SET storage_key = $2,
      file_hash = $3,
      compressed = $4,
      content_type = $5,
      filename = $6,
      aes_key_hex = $7,
      nonce_hex = $8,
      file_size = $9
  WHERE media_id = $1
  """

  @doc """
  Persists the results of a completed upload (Story 2b, AC8/AC9) onto an
  EXISTING `media_files` row — `storage_key`, `file_hash`, `compressed`,
  `content_type`, `filename` (nullable), and the AES key/nonce material.
  This is distinct from `Nebu.Media.StateMachine.transition/4`: that
  function's only metadata channel is the append-only
  `media_state_transitions` ledger, not the `media_files` row itself, so
  this UPDATE is the sole writer of these columns for the async-upload path.

  Per ADR-032 (AC9), the caller MUST only invoke this after the S3 write has
  already succeeded — this function itself has no ordering opinion, it is a
  plain UPDATE.

  `fields` is a map with keys `:media_id`, `:storage_key`, `:file_hash`,
  `:compressed`, `:content_type`, `:filename` (may be `nil`), `:aes_key_hex`,
  `:nonce_hex`, `:file_size`.
  """
  @spec persist_upload(map()) :: :ok | {:error, term()}
  def persist_upload(%{} = fields) do
    params = [
      fields.media_id,
      fields.storage_key,
      fields.file_hash,
      fields.compressed,
      fields.content_type,
      fields.filename,
      fields.aes_key_hex,
      fields.nonce_hex,
      fields.file_size
    ]

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_persist_upload, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Inserts a `media_files` row on upload. Returns `:ok` or `{:error, reason}`.

  Code-review MINOR-2 (2c cycle 1, 2026-07-14): no `lib/` code calls this
  anymore — media-security-admin-control/2c-sync-upload-shared-pipeline
  removed the sync upload handler's own `insert_media_row/7`, which was this
  function's last production caller; both upload paths now create rows
  exclusively through `Nebu.Media.StateMachine`. Kept (not deleted) because
  `test/nebu/media/media_files_state_backfill_test.exs` (an `:integration`
  test) still calls this real function directly to seed a "pre-migration-
  shaped" row — the exact 9-column INSERT shape that predates the `state`/
  `storage_key` columns — to prove the migration's backfill and the
  post-migration column defaults still behave correctly against that legacy
  shape. Do not call this from any new `lib/` code; go through
  `Nebu.Media.StateMachine` instead.
  """
  @spec insert(map()) :: :ok | {:error, term()}
  def insert(%{} = row) do
    params = [
      row.media_id,
      row.server_name,
      row.content_type,
      row.file_size,
      row.aes_key_hex,
      row.nonce_hex,
      row.uploader_user_id,
      row.uploaded_at
    ]

    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_insert, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_lookup_for_scan """
  SELECT storage_key, aes_key_hex, nonce_hex, compressed, filename, file_hash, uploader_user_id
  FROM media_files
  WHERE media_id = $1
  LIMIT 1
  """

  @doc """
  Reservation-aware lookup for `media-security-admin-control/
  4b-media-scan-worker`'s `Nebu.Workers.MediaScanWorker`: the exact subset of
  a `media_files` row the worker needs to fetch, decrypt, and conditionally
  decompress a `:quarantined` upload before scanning it. `aes_key_hex`/
  `nonce_hex` are returned as hex strings (as stored) — the caller
  hex-decodes them before `Nebu.Media.Crypto.decrypt/3`, which requires raw
  binaries.

  `filename`/`file_hash`/`uploader_user_id` were added by
  `media-security-admin-control/4c-infected-scanfailed-audit-bridge` (AC4/AC5)
  — the worker's `:infected`/`:scan_failed` audit-bridge writes need these for
  `AuditWriter.log/6`'s metadata and this is the one query already keyed by
  `media_id` at the point those writes happen; `filename`/`file_hash` may be
  `nil` (nullable columns).

  Returns `{:ok, %{storage_key:, aes_key_hex:, nonce_hex:, compressed:,
  filename:, file_hash:, uploader_user_id:}}` or `{:error, :not_found}`.
  """
  @spec lookup_for_scan(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_for_scan(media_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lookup_for_scan, [media_id]) do
      {:ok,
       %{
         rows: [
           [
             storage_key,
             aes_key_hex,
             nonce_hex,
             compressed,
             filename,
             file_hash,
             uploader_user_id
           ]
         ]
       }} ->
        {:ok,
         %{
           storage_key: storage_key,
           aes_key_hex: aes_key_hex,
           nonce_hex: nonce_hex,
           compressed: compressed,
           filename: filename,
           file_hash: file_hash,
           uploader_user_id: uploader_user_id
         }}

      _ ->
        {:error, :not_found}
    end
  end

  @sql_update_scan_metadata """
  UPDATE media_files SET scan_metadata = $2 WHERE media_id = $1
  """

  @doc """
  Persists scan-outcome metadata (e.g. the ClamAV signature on an infected
  result, AC6) onto `media_files.scan_metadata` — distinct from
  `Nebu.Media.StateMachine.transition/4`'s own metadata channel, which only
  ever writes the append-only `media_state_transitions` ledger, never the
  `media_files` row itself. This UPDATE touches `scan_metadata` ONLY — it
  never sets `state` (Story 1b's state-mutation invariant, AC10: state
  changes exclusively via `StateMachine.transition/4`).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec update_scan_metadata(String.t(), map()) :: :ok | {:error, term()}
  def update_scan_metadata(media_id, metadata) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_update_scan_metadata, [media_id, metadata]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @sql_lookup_state "SELECT state FROM media_files WHERE media_id = $1"

  @doc """
  Media-id-only lifecycle-state lookup for `media-security-admin-control/
  6a-routine-state-actions`'s `Nebu.Media.admin_block/3`, `admin_unblock/2`,
  `admin_delete/2`, `admin_rescan/2` — every one of those functions needs
  ONLY the current `state` atom (to decide idempotent no-ops for
  Block/Unblock, AC9, and the eligible-states guard for Rescan, AC8), never
  the rest of the row `lookup/2` (which additionally requires `server_name`,
  keyed for the download path) or `lookup_for_scan/1` (which returns crypto
  material, not `state`, for the scan worker) already return. Same
  defensive `parse_state/1` conversion as `to_map/1` uses — a genuinely
  unrecognized raw value falls back to the `:__unrecognized_media_state__`
  sentinel rather than raising.

  Returns `{:ok, state_atom}` or `{:error, :not_found}`.
  """
  @spec lookup_state(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def lookup_state(media_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lookup_state, [media_id]) do
      {:ok, %{rows: [[state]]}} -> {:ok, parse_state(state)}
      _ -> {:error, :not_found}
    end
  end

  @sql_lookup_scan_metadata "SELECT scan_metadata FROM media_files WHERE media_id = $1"

  @doc """
  Reads the raw `media_files.scan_metadata` JSONB column for
  `media-security-admin-control/6c-infected-override`'s
  `Nebu.Media.admin_override_infected/3` (AC4) — the `original_signature`
  audit-metadata field is derived from this map's `"clamav_signature"` key
  (the exact key `Nebu.Workers.MediaScanWorker.infect/2`, Story 4b, persists
  — not the epic narrative's shorthand `"signature"` key, which is not a real
  column key, see 6b's own identical schema-reality correction).

  Returns the raw metadata map (may be `nil` if the column itself is `NULL`,
  e.g. a file that was never scanned) or `nil` if no row matches `media_id`.
  """
  @spec lookup_scan_metadata(String.t()) :: map() | nil
  def lookup_scan_metadata(media_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_lookup_scan_metadata, [media_id]) do
      {:ok, %{rows: [[metadata]]}} -> metadata
      _ -> nil
    end
  end

  @sql_check_override_role "SELECT media_admin_override FROM users WHERE user_id = $1"

  @doc """
  Reads the distinct `media_admin_override` grant off the shared `users` table
  for `media-security-admin-control/6c-infected-override`'s
  `Nebu.Media.admin_override_infected/3` (AC6) — a role narrower than generic
  admin, deliberately orthogonal to `users.system_role`. Reading `users`
  directly here (rather than a cross-domain call into `Nebu.Admin`) mirrors
  the same "shared, foundational table" posture ADR-020 already tolerates for
  `Nebu.Admin.UsersController`'s own `system_role` query.

  Returns `true` only when the row exists AND `media_admin_override = true`.
  Returns `false` for a missing user row or `media_admin_override = false` —
  callers do not need to distinguish "no such admin" from "admin without the
  grant"; both fail closed identically (`{:error, :forbidden}`, never a
  `:not_found`, per AC6's own error shape).
  """
  @spec check_override_role(String.t()) :: boolean()
  def check_override_role(admin_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_check_override_role, [admin_id]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  Candidate `:released` rows for `media-security-admin-control/
  8c-media-archive-worker`'s `Nebu.Workers.MediaArchiveWorker` (AC2/AC3/AC4).

  `threshold_ms` is an already-computed millisecond epoch timestamp (the
  caller derives it as `System.system_time(:millisecond) - days *
  86_400_000`, mirroring `Nebu.Workers.MediaReservedUploadCleanupWorker`'s
  (Story 2e) own `now_ms - ttl_ms` convention) — **not** a day count bound
  through `NOW() - ($1 || ' days')::interval`, which the story's own
  illustrative SQL used but which cannot work against the real schema:
  `media_files.uploaded_at` is `BIGINT` (millisecond epoch, see
  `Nebu.Media.StateMachine.create/1`'s own `System.system_time(:millisecond)`
  writer), not a Postgres `TIMESTAMPTZ`. Binding a `interval`-based
  expression against a `BIGINT` column is a type error Postgres would reject
  at query time — confirmed empirically against the live schema
  (`server/priv/migrations/000001_init.up.sql:298`), not assumed from the
  story text.

  `state = 'released' AND archived_at IS NULL` is the sole eligibility
  filter (AC2, an explicit allow-list — never a deny-list) plus the
  idempotency guard (AC4). `storage_key IS NOT NULL` excludes the
  theoretical edge of a row mid-upload (should never be `:released` with a
  NULL `storage_key` in practice, but matches the story's own defensive SQL).
  `LIMIT 500` mirrors the existing bound in
  `Nebu.Compliance.SessionExpiryWorker`'s own scan query and Story 2e's
  cleanup query.

  Returns a list of `%{media_id:, storage_key:}` maps.
  """
  @sql_candidates_for_archive """
  SELECT media_id, storage_key
    FROM media_files
   WHERE state = 'released'
     AND archived_at IS NULL
     AND storage_key IS NOT NULL
     AND uploaded_at < $1
   LIMIT 500
  """

  @spec candidates_for_archive(integer()) :: [%{media_id: String.t(), storage_key: String.t()}]
  def candidates_for_archive(threshold_ms) when is_integer(threshold_ms) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_candidates_for_archive, [threshold_ms]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [media_id, storage_key] ->
          %{media_id: media_id, storage_key: storage_key}
        end)

      _ ->
        []
    end
  end

  @doc """
  The copy-then-verify-then-commit ordering's commit step (AC7 step 2, AC8)
  for `Nebu.Workers.MediaArchiveWorker`: sets `archived_at` on a `:released`
  row that hasn't already been archived. The `archived_at IS NULL` clause is
  the SAME idempotency/race guard as the candidate query above — a second or
  concurrent commit attempt against an already-archived row affects 0 rows,
  distinguishing "this execution won the race" from "another execution
  already committed" without any additional locking.

  Returns `{:ok, :committed}` if this call's `UPDATE` affected the row (the
  caller should now audit-log and, if configured, delete the primary
  object), `{:ok, :already_archived}` if 0 rows were affected (a losing
  concurrent/repeated attempt — the caller must treat this as a silent
  no-op: no audit entry, no primary delete), or `{:error, reason}` on a
  genuine DB failure.
  """
  @sql_commit_archived """
  UPDATE media_files
     SET archived_at = NOW()
   WHERE media_id = $1
     AND state = 'released'
     AND archived_at IS NULL
  """

  @spec commit_archived(String.t()) ::
          {:ok, :committed} | {:ok, :already_archived} | {:error, term()}
  def commit_archived(media_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_commit_archived, [media_id]) do
      {:ok, %{num_rows: 1}} -> {:ok, :committed}
      {:ok, %{num_rows: 0}} -> {:ok, :already_archived}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Row-tuple -> atom-keyed map conversion for `lookup/2`'s SQL result
  # (column order MUST match `@sql_lookup`'s SELECT list exactly). Public
  # (but @doc false, not part of this module's real public API — `lookup/2`
  # is) purely so a fast, DB-free unit test can construct a synthetic
  # 14-element row tuple by hand and assert `:compressed` (and every other
  # column) lands at the correct position in THIS function's own positional
  # mapping. It does NOT exercise `@sql_lookup` itself — a regression that
  # drops a column from that SELECT list changes the arity of the list
  # `to_map/1` receives, which this hand-built-list test cannot observe;
  # only the slower `:integration`-tagged tests (a real Postgres round-trip)
  # would catch that. Mirrors the same `@doc false` + directly-tested
  # pattern already used by `parse_state/1` below. Do not call this from
  # other application code — go through `lookup/2`.
  def to_map([
        media_id,
        server_name,
        content_type,
        file_size,
        aes_key_hex,
        nonce_hex,
        uploader,
        uploaded_at,
        deleted,
        state,
        storage_key,
        archived_at,
        compressed,
        filename
      ]) do
    %{
      media_id: media_id,
      server_name: server_name,
      content_type: content_type,
      file_size: file_size,
      aes_key_hex: aes_key_hex,
      nonce_hex: nonce_hex,
      uploader_user_id: uploader,
      uploaded_at: uploaded_at,
      deleted: deleted,
      # media-security-admin-control/download-gate (1c): lifecycle state read
      # from the media_state ENUM column (Story 1a). Converted defensively via
      # to_existing_atom/1 — the finite, compile-time-known enum values are
      # already atoms this codebase references (5 of the 8 in
      # Nebu.Media.download_gate/1: :released, :admin_blocked, :infected,
      # :deleted, :hard_deleted; the other 3 — :reserved, :quarantined,
      # :scanning — in Nebu.Media.StateMachine), so an unexpected raw value
      # would otherwise raise ArgumentError and grow the atom table via
      # String.to_atom/1. parse_state/1 rescues that raise instead of
      # crashing: a genuinely unrecognized state (e.g. a future ENUM value
      # added by `ALTER TYPE` before its own Elixir code lands, see Story 4a's
      # :scan_failed) falls back to a sentinel atom that no download_gate/1
      # clause explicitly matches, so it still reaches the handler-level gate
      # and fails closed via the catch-all (451 M_NOT_YET_UPLOADED, per AC6 /
      # ADR-026) instead of an uncaught 500.
      state: parse_state(state),
      # media_files has no room_id.
      room_id: nil,
      # media-security-admin-control/8c-media-archive-worker: self-corrected
      # pre-existing bug found while adding archived_at to this same SELECT
      # list (in scope of this story's own AC11/Technical-Requirements
      # change to this exact function) — storage_key used to be HARDCODED to
      # media_id here instead of reading the real, already-persisted
      # media_files.storage_key column. That was silently correct only by
      # coincidence: 000022's backfill set storage_key = media_id for every
      # legacy row, and 11c's compute_key/2 default template ("{media_id}")
      # happens to interpolate to the same value. But 11c's own moduledoc
      # (see server/lib/nebu/media/storage_config.ex) explicitly documents
      # that "Download (Story 1c) ... reads the already-persisted
      # media_files.storage_key column" as a load-bearing invariant — once an
      # operator configures ANY non-default s3_key_prefix_template (Story
      # 11b, already shippable), the real persisted storage_key diverges from
      # media_id and every download of a file uploaded under that template
      # would have silently 404/502'd, a bug entirely independent of whether
      # the file is ever archived. This story's own AC11 bucket switch reads
      # row.storage_key directly, so leaving the hardcode in place would make
      # the NEW archive-bucket read wrong in exactly the same latent way.
      # Fixed by reading the real column value instead of fabricating it.
      storage_key: storage_key,
      # media-security-admin-control/8c-media-archive-worker (AC11): drives
      # Nebu.Media.fetch_and_decrypt/3's bucket switch. NULL (the default for
      # every not-yet-archived row) means "primary bucket", matching every
      # pre-existing caller unchanged.
      archived_at: archived_at,
      # fix-media-download-gzip-decompression: whether the stored ciphertext
      # was gzipped before encryption (ADR-029 store-smaller-of-two,
      # `Nebu.Media.Storage.compress/1`, written by
      # `encrypt_compress_and_store/5` at upload time). `lookup/2` is the
      # ONLY query on this shared download/thumbnail path
      # (`Nebu.Media.fetch_and_decrypt/3`), so this is the single place that
      # must surface it — without it, a compressed-at-rest object is served
      # still gzip-wrapped, mislabeled with the original Content-Type.
      compressed: compressed,
      # Original upload filename (nullable; media_files.filename, migration 000025).
      filename: filename
    }
  end

  @doc false
  # Defensive, fail-closed conversion of the raw media_state ENUM column
  # value. See the `:state` comment in to_map/1 above for why this can raise
  # and what the rescue falls back to. Public (but @doc false, not part of
  # this module's real public API — lookup/2 and insert/1 are) purely so the
  # rescue path can be exercised directly by a fast, DB-free unit test with a
  # synthetic never-before-interned string, mirroring the existing
  # `@doc false` + directly-tested pattern used by e.g.
  # `Nebu.Health.overall_status/1`. Do not call this from other application
  # code — go through `lookup/2`.
  def parse_state(state) do
    String.to_existing_atom(state)
  rescue
    ArgumentError -> :__unrecognized_media_state__
  end
end
