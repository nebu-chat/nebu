defmodule Nebu.Media.StateMachine do
  @moduledoc """
  Guarded `media_files.state` transition enforcement
  (media-security-admin-control/1b-state-machine-module, AC1-AC5, AC7).

  This is the **only** code path in the application allowed to change
  `media_files.state`. Every successful transition performs the
  `media_files` `UPDATE` and the corresponding `media_state_transitions`
  `INSERT` inside a single `Repo.transaction/1` — either both commit or
  neither does (AC3).

  Plain Elixir module, no Ecto schema, no changeset, no Repository/Service
  layer (ADR-018). Follows `Nebu.Media.DB`'s inline-SQL convention:
  `Ecto.Adapters.SQL.query/3` directly against `Nebu.Repo`.

  The guard table (`@transitions`) is the single source of truth for legal
  state transitions — both `allowed?/2` and `transition/4` consult it, there
  is no per-call-site hardcoded transition check anywhere else. Story 4a
  (media-security-admin-control/4a-scan-failed-enum-migration) extended this
  map in place with the `:scan_failed` key and its edges, after its own
  migration (`000028_media_scan_failed_state.up.sql`) added the matching
  `media_state` ENUM value — no other change to this module was needed.

  Per ADR-031, the authoritative guarantee that `media_state_transitions`
  cannot be silently rewritten is the DB-level `BEFORE UPDATE OR DELETE`
  trigger + RLS/REVOKE added by Story 1a's migration
  (`000022_media_state_machine_foundation`) — not this module. This module
  only enforces which transitions are legal and that the audit row is
  written atomically with the state change.

  ## `"media:admin"` broadcast (media-security-admin-control/5b-live-updates-nav-badges)

  Every successful `transition/4` call ALSO broadcasts
  `{:media_state_transition, media_id, from_state, to_state}` on `"media:admin"` (the same
  `Nebu.PubSub` registry as everything else in this app), AFTER the transaction commits — this
  is the one call site every caller (4b's scan worker, 6a's admin actions, 8a's cleanup
  worker, future lifecycle jobs) gets it for free from, per 5b's own Technical Requirements.

  **Deliberately does NOT touch Story 2d/4b's existing `"media:#{"\#{media_id}"}"` topic**:
  `Nebu.Workers.MediaScanWorker` already broadcasts a 3-tuple
  `{:media_state_transition, media_id, new_state}` there (landed before 5b), consumed by
  `Nebu.Media.DownloadStall`'s strict 3-tuple `receive` pattern match. Emitting a 4-tuple on
  that same topic instead would silently stop matching in `DownloadStall` (no crash — the
  message simply never satisfies that `receive` clause, degrading every stall wait to a
  timeout). 5b's own story text anticipates exactly this coordination conflict and prescribes
  this resolution: a new, separate 4-tuple broadcast on `"media:admin"` only, leaving the
  existing 3-tuple broadcast on `"media:\#{media_id}"` completely unchanged.

  **Deliberately does NOT cover `create/1`/`create_quarantined/1`** (the two genesis
  functions below) — those INSERT a brand-new row directly, bypassing this guarded
  `transition/4`/`write_transition/6` path entirely, so `from_state` is not "a locked existing
  row's state" in the same sense. 5b's own AC4 design (a fresh mount always re-derives the
  attention count via a live `COUNT`, self-healing on next navigation/remount) already
  tolerates an already-open admin session's badge staying one event stale for a
  create_quarantined/1 genesis row until that session's next reconnect — a deliberate,
  bounded scope choice, not a gap.
  """

  alias Nebu.Repo

  @type state ::
          :reserved
          | :quarantined
          | :scanning
          | :released
          | :infected
          | :admin_blocked
          | :deleted
          | :hard_deleted
          | :scan_failed

  @type actor :: {:system, nil} | {:admin, String.t()}

  # Guard table — the single source of truth for legal media_files.state
  # transitions. Matches the epic's "State Machine" section / the story's
  # "Guard table" exactly. allowed?/2, allowed_transitions/1, and
  # transition/4 all consult this map — do not add per-call-site transition
  # checks elsewhere.
  #
  # media-security-admin-control/2e-reserved-upload-cleanup-cron: adds
  # reserved -> hard_deleted, used ONLY by Nebu.Workers.MediaReservedUploadCleanupWorker
  # to retire abandoned (never-uploaded, byte-less) reservations directly to
  # the terminal state — bypassing :quarantined/:deleted since there is
  # nothing to scan or purge (storage_key is NULL from creation).
  #
  # media-security-admin-control/4a-scan-failed-enum-migration: adds the
  # `:scan_failed` key (the 9th media_state value, this story's own
  # migration 000028_media_scan_failed_state.up.sql) plus:
  #   - :quarantined -> :scan_failed (Oban discard/2 fires before scanning
  #     truly started, e.g. an immediate non-retryable dispatch failure)
  #   - :scanning -> :scan_failed (the common case: max_attempts exhausted)
  #   - :scan_failed -> :scanning (admin/automated retry)
  #   - :scan_failed -> :released (admin manual clear after out-of-band
  #     verification)
  #   - :scan_failed -> :admin_blocked (admin manual block instead)
  #   - :scan_failed -> :deleted (retention/lifecycle parity with every
  #     other non-terminal state — :scan_failed is NOT terminal)
  #
  # media-security-admin-control/6c-infected-override: adds the
  # infected -> :released edge — the deliberate, narrowly-gated exception for
  # a ClamAV false positive (Nebu.Media.admin_override_infected/3, gated by
  # the distinct media_admin_override grant, never a generic admin action).
  # The pre-existing infected -> :deleted edge is unchanged; no other key's
  # edge list changes.
  #
  # media-security-admin-control/8a-media-cleanup-worker: adds the
  # infected -> :hard_deleted edge, used by Nebu.Workers.MediaCleanupWorker's
  # daily retention cron to permanently purge :infected rows past
  # infected_days. The pre-existing infected -> :deleted and
  # infected -> :released edges are unchanged; no other key's edge list
  # changes.
  @transitions %{
    reserved: [:quarantined, :hard_deleted],
    quarantined: [:scanning, :admin_blocked, :deleted, :scan_failed],
    scanning: [:released, :infected, :quarantined, :admin_blocked, :scan_failed],
    released: [:admin_blocked, :deleted],
    infected: [:deleted, :released, :hard_deleted],
    admin_blocked: [:released, :deleted],
    deleted: [:hard_deleted],
    hard_deleted: [],
    scan_failed: [:scanning, :released, :admin_blocked, :deleted]
  }

  @sql_lock_state "SELECT state FROM media_files WHERE media_id = $1 FOR UPDATE"

  @sql_update_state "UPDATE media_files SET state = $2 WHERE media_id = $1"

  # media-security-admin-control/2e-reserved-upload-cleanup-cron (AC3): reaching
  # the terminal :hard_deleted state ALSO nulls uploader_user_id and stamps
  # hard_deleted_at, per the epic's DB-Record-Invariante (the row is never
  # physically deleted, but its accountability/ownership columns are cleared
  # once hard_deleted). No prior caller in this codebase has ever transitioned
  # anything to :hard_deleted (the pre-existing deleted -> hard_deleted edge has
  # no caller yet either), so this is introduced here as part of write_transition/6
  # rather than being an existing, already-covered code path.
  @sql_update_state_hard_deleted """
  UPDATE media_files
     SET state = $2, uploader_user_id = NULL, hard_deleted_at = now()
   WHERE media_id = $1
  """

  @sql_insert_transition """
  INSERT INTO media_state_transitions
    (media_id, from_state, to_state, actor_type, actor_id, metadata, inserted_at)
  VALUES ($1, $2, $3, $4, $5, $6, now())
  """

  @doc """
  Returns `true` if `to` is a legal transition target from `from`, per the
  guard table. Read-only helper — consults `@transitions`, no DB call.
  """
  @spec allowed?(from :: state(), to :: state()) :: boolean()
  def allowed?(from, to) do
    to in allowed_transitions(from)
  end

  @doc """
  Returns the full list of legal transition targets from `from`, per the
  guard table. Returns `[]` for a terminal state (e.g. `:hard_deleted`) or
  an unrecognized `from` state.
  """
  @spec allowed_transitions(from :: state()) :: [state()]
  def allowed_transitions(from) do
    Map.get(@transitions, from, [])
  end

  @doc """
  Attempts to transition `media_id` from its current `media_files.state` to
  `to_state`, recording the change in `media_state_transitions` atomically.

  `actor` identifies who/what drove the transition:
    * `{:system, nil}` — a system-driven transition (upload, scanner). No
      admin identity may be attached.
    * `{:admin, admin_user_id}` — an admin-driven transition (manual
      block/unblock/delete). `admin_user_id` is persisted as `actor_id`.
      `admin_user_id` is a plain Matrix-ID string (e.g. `"@kai:test.local"`),
      the SAME identity shape as `users.user_id`/`audit_log.actor_user_id` —
      NOT a UUID (media-security-admin-control/6a-routine-state-actions,
      migration `000029_media_state_transitions_actor_id_text`: `actor_id`
      was originally a UUID column on the mistaken assumption that admin
      identity would be UUID-shaped; this app has no UUID-shaped user/admin
      identity anywhere, so the column was changed to TEXT and this function
      no longer dumps/loads through `Ecto.UUID`).

  `{:system, non_nil_id}` is rejected with `{:error, :invalid_actor}` before
  any DB call — a scanner-driven transition can never carry a spurious
  admin identity (AC5). Symmetrically, `{:admin, nil}` is also rejected
  with `{:error, :invalid_actor}` before any DB call — an admin-attributed
  transition can never persist a `NULL` `actor_id`, which would otherwise
  be an accountability hole in the compliance ledger.

  `metadata` defaults to `%{}` and is stored as-is in the
  `media_state_transitions.metadata` JSONB column.

  Returns:
    * `{:ok, to_state}` on success.
    * `{:error, {:invalid_transition, from_state, to_state}}` if `to_state`
      is not in `allowed_transitions(from_state)` — no write occurs (AC4).
    * `{:error, :not_found}` if `media_id` does not exist — no write occurs.
    * `{:error, :invalid_actor}` if `actor` is `{:system, non_nil}` or
      `{:admin, nil}`.
  """
  @spec transition(media_id :: String.t(), to_state :: state(), actor(), metadata :: map()) ::
          {:ok, state()}
          | {:error, {:invalid_transition, state(), state()}}
          | {:error, :invalid_actor}
          | {:error, :not_found}
  def transition(media_id, to_state, actor, metadata \\ %{})

  def transition(_media_id, _to_state, {:system, actor_id}, _metadata) when not is_nil(actor_id) do
    {:error, :invalid_actor}
  end

  def transition(_media_id, _to_state, {:admin, nil}, _metadata) do
    {:error, :invalid_actor}
  end

  def transition(media_id, to_state, actor, metadata) do
    {actor_type, actor_id} = actor

    result =
      Repo.transaction(fn ->
        case Ecto.Adapters.SQL.query!(Repo, @sql_lock_state, [media_id]) do
          %{rows: [[from_state_str]]} ->
            from_state = String.to_existing_atom(from_state_str)

            if allowed?(from_state, to_state) do
              write_transition(media_id, from_state, to_state, actor_type, actor_id, metadata)
              {from_state, to_state}
            else
              Repo.rollback({:invalid_transition, from_state, to_state})
            end

          %{rows: []} ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, {from_state, to_state}} ->
        # 5b: broadcast AFTER commit, never inside the transaction — a
        # broadcast must never fire for a transition that could still roll
        # back.
        broadcast_admin(media_id, from_state, to_state)
        {:ok, to_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # media-security-admin-control/5b-live-updates-nav-badges: the one call site every
  # transition/4 caller gets this broadcast from for free. See moduledoc for why this does
  # NOT also touch 2d/4b's existing "media:#{media_id}" 3-tuple broadcast.
  defp broadcast_admin(media_id, from_state, to_state) do
    Phoenix.PubSub.broadcast(
      Nebu.PubSub,
      "media:admin",
      {:media_state_transition, media_id, from_state, to_state}
    )
  end

  defp write_transition(media_id, from_state, to_state, actor_type, actor_id, metadata) do
    update_sql = if to_state == :hard_deleted, do: @sql_update_state_hard_deleted, else: @sql_update_state
    Ecto.Adapters.SQL.query!(Repo, update_sql, [media_id, Atom.to_string(to_state)])

    Ecto.Adapters.SQL.query!(Repo, @sql_insert_transition, [
      media_id,
      Atom.to_string(from_state),
      Atom.to_string(to_state),
      Atom.to_string(actor_type),
      actor_id,
      metadata
    ])
  end

  # ── genesis: create/1 (media-security-admin-control/2a-post-media-create) ──
  #
  # Unlike transition/4 (which transitions an EXISTING media_files row),
  # create/1 is the reservation genesis entry point: it INSERTs a brand-new
  # media_files row (state: 'reserved') plus the corresponding
  # media_state_transitions audit row (from_state: NULL, to_state:
  # 'reserved', actor_type: 'system', actor_id: NULL) in one
  # Repo.transaction/1 — the {:system, nil} actor shape is already legal
  # under transition/4's existing guard (see @type actor), no ENUM/guard
  # changes needed here. This is the ONLY sanctioned way to create a new
  # media_files row for the async upload flow (Nebu.Media.create/1, the HTTP
  # handler, is the sole caller).
  #
  # content_type/file_size/aes_key_hex/nonce_hex have no real value yet at
  # reservation time (no bytes have been uploaded) — placeholder ""/0,
  # exactly like the pre-existing NOT NULL constraints from
  # 000001_init.up.sql require. Story 2b's PUT .../upload/... overwrites
  # these once the bytes actually arrive.
  @sql_insert_genesis """
  INSERT INTO media_files
    (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
     uploader_user_id, uploaded_at, deleted, state)
  VALUES ($1, $2, '', 0, '', '', $3, $4, false, 'reserved')
  """

  @sql_insert_genesis_transition """
  INSERT INTO media_state_transitions
    (media_id, from_state, to_state, actor_type, actor_id, metadata, inserted_at)
  VALUES ($1, NULL, 'reserved', 'system', NULL, $2, now())
  """

  @doc """
  Reserves a brand-new `media_id`: INSERTs a fresh `media_files` row in
  `state: :reserved` (with `uploader_user_id` set) plus the genesis
  `media_state_transitions` audit row, atomically.

  Accepts `%{media_id:, server_name:, uploader_user_id:}`.

  Returns `{:ok, media_id}` on success, or `{:error, :media_id_taken}` if
  `media_id` collides with an existing `media_files` PRIMARY KEY (the
  caller — `Nebu.Media.create/1` — retries once with a freshly generated
  id; 128 bits of entropy makes this defense-in-depth, not the primary
  collision-resistance argument).
  """
  @spec create(%{
          required(:media_id) => String.t(),
          required(:server_name) => String.t(),
          required(:uploader_user_id) => String.t()
        }) :: {:ok, String.t()} | {:error, :media_id_taken} | {:error, term()}
  def create(%{media_id: media_id, server_name: server_name, uploader_user_id: uploader_user_id}) do
    now_ms = System.system_time(:millisecond)

    result =
      Repo.transaction(fn ->
        case Ecto.Adapters.SQL.query(Repo, @sql_insert_genesis, [
               media_id,
               server_name,
               uploader_user_id,
               now_ms
             ]) do
          {:ok, _} ->
            Ecto.Adapters.SQL.query!(Repo, @sql_insert_genesis_transition, [media_id, %{}])
            media_id

          {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
            Repo.rollback(:media_id_taken)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, media_id} -> {:ok, media_id}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── genesis: create_quarantined/1 (media-security-admin-control/2c-sync-upload-shared-pipeline) ──
  #
  # Sibling to create/1 above, for the ONE flow where bytes are already
  # present at row-creation time: the synchronous `PUT
  # /_matrix/media/v3/upload` handler (`Nebu.Media.upload/1`). Unlike
  # create/1 (genesis into :reserved, for the two-step async flow where
  # bytes arrive later), this INSERTs a brand-new media_files row DIRECTLY in
  # state: 'quarantined' plus a SINGLE genesis media_state_transitions audit
  # row (from_state: NULL, to_state: 'quarantined', actor_type: 'system',
  # actor_id: NULL) — in one Repo.transaction/1, mirroring create/1's own
  # shape exactly (same placeholder content_type/file_size/aes_key_hex/
  # nonce_hex — the caller fills in the real byte-derived fields afterward
  # via Nebu.Media.DB.persist_upload/1, the same seam story 2b's async PUT
  # handler already uses).
  #
  # Composing create/1 (-> :reserved) + transition/4 (:reserved ->
  # :quarantined) instead of this function would write TWO
  # media_state_transitions rows for a sync upload — this story's own
  # acceptance tests require EXACTLY ONE. Do not do that.
  @sql_insert_genesis_quarantined """
  INSERT INTO media_files
    (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
     uploader_user_id, uploaded_at, deleted, state)
  VALUES ($1, $2, '', 0, '', '', $3, $4, false, 'quarantined')
  """

  @sql_insert_genesis_quarantined_transition """
  INSERT INTO media_state_transitions
    (media_id, from_state, to_state, actor_type, actor_id, metadata, inserted_at)
  VALUES ($1, NULL, 'quarantined', 'system', NULL, $2, now())
  """

  @doc """
  Reserves a brand-new `media_id` DIRECTLY in `state: :quarantined`: INSERTs
  a fresh `media_files` row (with `uploader_user_id` set) plus the genesis
  `media_state_transitions` audit row (`from_state: NULL, to_state:
  'quarantined'`), atomically.

  Accepts `%{media_id:, server_name:, uploader_user_id:}` — the same shape as
  `create/1`.

  Returns `{:ok, media_id}` on success, or `{:error, :media_id_taken}` if
  `media_id` collides with an existing `media_files` PRIMARY KEY (the caller
  — `Nebu.Media.upload/1`'s `store_upload/4` — retries once with a freshly
  generated id, same one-retry convention as `create/1`'s caller).
  """
  @spec create_quarantined(%{
          required(:media_id) => String.t(),
          required(:server_name) => String.t(),
          required(:uploader_user_id) => String.t()
        }) :: {:ok, String.t()} | {:error, :media_id_taken} | {:error, term()}
  def create_quarantined(%{
        media_id: media_id,
        server_name: server_name,
        uploader_user_id: uploader_user_id
      }) do
    now_ms = System.system_time(:millisecond)

    result =
      Repo.transaction(fn ->
        case Ecto.Adapters.SQL.query(Repo, @sql_insert_genesis_quarantined, [
               media_id,
               server_name,
               uploader_user_id,
               now_ms
             ]) do
          {:ok, _} ->
            Ecto.Adapters.SQL.query!(Repo, @sql_insert_genesis_quarantined_transition, [
              media_id,
              %{}
            ])

            media_id

          {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
            Repo.rollback(:media_id_taken)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, media_id} -> {:ok, media_id}
      {:error, reason} -> {:error, reason}
    end
  end
end
