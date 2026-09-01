defmodule Nebu.Web.MediaFakes do
  @moduledoc """
  Function-backed fake boundaries for the media-gateway-migration RED tests.

  Mox is NOT a dependency of this umbrella (checked mix.lock), so rather than a
  generated mock we use thin modules whose behavior is supplied per-test through
  application env closures. Each fake reads a 0-/n-arity function from
  `Application.get_env(:nebu_http, <key>)` and calls it. Tests set the closure in
  their own `setup`/`on_exit`.

  The dev agent's production code reads the SAME app-env keys
  (`:media_storage_module`, `:media_membership_module`, `:media_db_module`,
  `:media_http_fetch_module`) and falls back to the real ExAws/OTP/SQL/Finch
  implementations when the key is unset. In tests we point the key at one of
  these fakes.
  """

  defmodule Storage do
    @moduledoc "Fake storage boundary (production: ExAws.S3 Storer)."
    def get(key) do
      fun = Application.get_env(:nebu_http, :media_storage_get_fun)
      if fun, do: fun.(key), else: {:error, :not_found}
    end

    def put(key, bytes) do
      fun = Application.get_env(:nebu_http, :media_storage_put_fun)
      if fun, do: fun.(key, bytes), else: :ok
    end

    @doc """
    Fake for `Nebu.Media.Storage.get_from_archive/1`
    (media-security-admin-control/8c-media-archive-worker, AC11): the
    archive-bucket counterpart of `get/1` above, read by
    `Nebu.Media.fetch_and_decrypt/3` only when `row.archived_at` is truthy.
    Tests set `:media_storage_get_from_archive_fun`; default fallback is
    `{:error, :not_found}` (matches `get/1`'s own default, and makes an
    un-configured call loudly fail a download rather than silently serving
    the wrong bytes).
    """
    def get_from_archive(key) do
      fun = Application.get_env(:nebu_http, :media_storage_get_from_archive_fun)
      if fun, do: fun.(key), else: {:error, :not_found}
    end
  end

  defmodule Membership do
    @moduledoc "Fake membership boundary (production: local OTP call, AC2/AC4)."
    def member?(room_id, user_id) do
      fun = Application.get_env(:nebu_http, :media_member_fun)
      if fun, do: fun.(room_id, user_id), else: false
    end
  end

  defmodule DB do
    @moduledoc "Fake media_files lookup (production: inline SQL, ADR-018)."
    def lookup(server_name, media_id) do
      fun = Application.get_env(:nebu_http, :media_lookup_fun)
      if fun, do: fun.(server_name, media_id), else: {:error, :not_found}
    end

    @doc """
    Fake for the AC3 pending-upload-count seam
    (media-security-admin-control/2a-post-media-create): production is
    `COUNT(*) FROM media_files WHERE uploader_user_id = $1 AND state =
    'reserved'` (`Nebu.Media.DB.count_pending_reservations/1`, not yet
    implemented). Tests set `:media_pending_count_fun` to control how many
    `:reserved` rows the calling user is deemed to already hold.
    """
    def count_pending_reservations(uploader_user_id) do
      fun = Application.get_env(:nebu_http, :media_pending_count_fun)
      if fun, do: fun.(uploader_user_id), else: 0
    end

    @doc """
    Fake for `media-security-admin-control/2b-put-media-upload`'s
    reservation-aware lookup: unlike `lookup/2` (used by download/thumbnail,
    which only ever returns `:released`-reachable rows through the download
    gate), this one must return `{:ok, row}` for a row in ANY state — AC3/AC5
    need to distinguish a 403 (wrong user, any state) from a 409 (right user,
    wrong state). `row` needs at minimum `:uploader_user_id`, `:state`, and
    `:uploaded_at` (expiry is DERIVED from `uploaded_at` + config — there is
    no persisted `unused_expires_at` column, see the story's Dev Agent
    Record). Tests set `:media_lookup_reservation_fun`; default fallback is
    `{:error, :not_found}` (unknown media_id -> 404, AC4).
    """
    def lookup_reservation(server_name, media_id) do
      fun = Application.get_env(:nebu_http, :media_lookup_reservation_fun)
      if fun, do: fun.(server_name, media_id), else: {:error, :not_found}
    end

    @doc """
    Fake for `media-security-admin-control/2b-put-media-upload`'s persist
    step (AC8/AC9): the `media_files` UPDATE that writes `storage_key`,
    `file_hash`, `compressed`, `content_type`, `filename`, and key/nonce
    material — distinct from `Nebu.Media.StateMachine.transition/4`, whose
    only metadata channel is the `media_state_transitions` audit ledger, not
    the `media_files` row itself. Per AC9/ADR-032, production must call this
    ONLY after `Storage.put/2` returns `:ok`. Tests set
    `:media_persist_upload_fun` to capture the exact `fields` map passed.
    """
    def persist_upload(fields) do
      fun = Application.get_env(:nebu_http, :media_persist_upload_fun)
      if fun, do: fun.(fields), else: :ok
    end

    @doc """
    Spy stub for `Nebu.Media.DB.insert/1` (media-security-admin-control/2c-sync-
    upload-shared-pipeline). The REAL `Nebu.Media.DB` module already exposes
    `insert/1` (the pre-2c sync-upload row-creation path this story removes) —
    this fake previously had NO `insert/1` at all, which is why
    `Nebu.Media.insert_media_row/7`'s `function_exported?/3` guard silently
    no-op'd whenever this fake was pinned. Adding this stub lets 2c's tests
    explicitly assert `insert/1` is NEVER called after the refactor (AC1): a
    future regression that reintroduces the direct `Nebu.Media.DB.insert/1`
    call would now be observable via `:media_db_insert_fun`, instead of
    silently no-op'ing forever. Tests set `:media_db_insert_fun`; default
    fallback returns `:ok` (never crashes an old, un-migrated test file that
    doesn't care about this seam).
    """
    def insert(row) do
      fun = Application.get_env(:nebu_http, :media_db_insert_fun)
      if fun, do: fun.(row), else: :ok
    end

    @doc """
    Fake for `Nebu.Media.DB.lookup_for_scan/1`
    (media-security-admin-control/4b-media-scan-worker): returns the subset
    of a `media_files` row `Nebu.Workers.MediaScanWorker` needs to fetch,
    decrypt, and conditionally decompress a quarantined upload —
    `:storage_key`, `:aes_key_hex`, `:nonce_hex`, `:compressed`. Tests set
    `:media_lookup_for_scan_fun`; default fallback is `{:error, :not_found}`.
    """
    def lookup_for_scan(media_id) do
      fun = Application.get_env(:nebu_http, :media_lookup_for_scan_fun)
      if fun, do: fun.(media_id), else: {:error, :not_found}
    end

    @doc """
    Fake for `Nebu.Media.DB.update_scan_metadata/2`
    (media-security-admin-control/4b-media-scan-worker): the plain
    `UPDATE media_files SET scan_metadata = $2 WHERE media_id = $1` the
    worker issues on an infected result (AC6) to persist the ClamAV
    signature onto the row itself (distinct from the
    `media_state_transitions` ledger entry `StateMachine.transition/4`
    writes). Tests set `:media_update_scan_metadata_fun`; default fallback
    is `:ok`.
    """
    def update_scan_metadata(media_id, metadata) do
      fun = Application.get_env(:nebu_http, :media_update_scan_metadata_fun)
      if fun, do: fun.(media_id, metadata), else: :ok
    end
  end

  defmodule StateMachine do
    @moduledoc """
    Fake for the `:media_state_machine_module` seam
    (media-security-admin-control/2a-post-media-create). Production default
    is `Nebu.Media.StateMachine`, whose (not-yet-implemented) `create/1`
    genesis function is the ONLY sanctioned way to insert a brand-new
    `media_files` row in `state: :reserved` plus its matching
    `media_state_transitions` audit row (`from_state: nil, to_state:
    :reserved, actor_type: :system, actor_id: nil`) — see Story 1b's
    `transition/4` guard, which already accepts the `{:system, nil}` actor
    shape unchanged.

    This fake does NOT touch Postgres. Tests set
    `:media_state_machine_create_fun` to a closure that both records the
    call (so the test can assert the handler invoked the seam instead of a
    raw SQL insert) and returns the `{:ok, media_id} | {:error, reason}`
    tuple the test wants to exercise.
    """
    def create(attrs) do
      fun = Application.get_env(:nebu_http, :media_state_machine_create_fun)

      if fun do
        fun.(attrs)
      else
        {:ok, Map.fetch!(attrs, :media_id)}
      end
    end

    @doc """
    Fake for `Nebu.Media.StateMachine.transition/4`
    (media-security-admin-control/2b-put-media-upload — the first story to
    drive an EXISTING row's transition rather than the `create/1` genesis
    path). Tests set `:media_state_machine_transition_fun` to a 4-arity
    closure `(media_id, to_state, actor, metadata) -> {:ok, to_state} |
    {:error, reason}`; default fallback always succeeds.
    """
    def transition(media_id, to_state, actor, metadata \\ %{}) do
      fun = Application.get_env(:nebu_http, :media_state_machine_transition_fun)

      if fun do
        fun.(media_id, to_state, actor, metadata)
      else
        {:ok, to_state}
      end
    end

    @doc """
    Fake for the NOT-YET-IMPLEMENTED `Nebu.Media.StateMachine.create_quarantined/1`
    genesis function (media-security-admin-control/2c-sync-upload-shared-
    pipeline — see the story's "CRITICAL DESIGN FINDING"). Mirrors `create/1`'s
    shape (INSERT-plus-single-genesis-audit-row) but lands the brand-new row
    directly in `:quarantined` with a SINGLE `media_state_transitions` genesis
    row (`from_state: NULL, to_state: 'quarantined'`) — this is what lets the
    sync upload path (bytes already present at request time) skip the
    `:reserved` state entirely, in exactly ONE state-machine seam call,
    unlike the async path's `create/1` (-> :reserved) followed by a SEPARATE
    `transition/4` (:reserved -> :quarantined) call.

    This fake does NOT touch Postgres — it exists purely so 2c's ATDD tests
    can compile and correctly RED against the real (not-yet-existing)
    `Nebu.Media.StateMachine.create_quarantined/1`. Tests set
    `:media_state_machine_create_quarantined_fun` to a closure that records
    the call (to prove the sync handler used THIS seam and not
    `create/1` + `transition/4`) and returns `{:ok, media_id} | {:error,
    reason}`. Default fallback always succeeds.
    """
    def create_quarantined(attrs) do
      fun = Application.get_env(:nebu_http, :media_state_machine_create_quarantined_fun)

      if fun do
        fun.(attrs)
      else
        {:ok, Map.fetch!(attrs, :media_id)}
      end
    end
  end

  defmodule Permission do
    @moduledoc """
    Fake for the `:media_permission_module` seam
    (media-security-admin-control/2a-post-media-create, AC4). Production
    default (not yet implemented) is `Nebu.Media.Permission`, which checks
    account-deactivation status via `Nebu.Matrix`'s public API. Tests set
    `:media_permission_fun` to control whether the calling user is deemed
    allowed to upload.
    """
    def can_upload?(user_id) do
      fun = Application.get_env(:nebu_http, :media_permission_fun)
      if fun, do: fun.(user_id), else: true
    end
  end

  defmodule ScanEnqueue do
    @moduledoc """
    Fake for the `:media_scan_enqueue_module` seam
    (media-security-admin-control/2b-put-media-upload, AC8). Production
    (Story 4b, not yet landed on this branch) will enqueue a real Oban job;
    Oban is NOT a dependency of this codebase yet (no `:oban` in `mix.exs`).
    This seam is an injectable, no-op/log-only-until-4b-lands boundary that
    only needs to identify the `media_id` — 2b's own File List anticipates
    exactly this ("add an Oban-enqueue fake seam if Story 4b's worker module
    isn't landed yet at this story's dev time"). Tests set
    `:media_scan_enqueue_fun`; default fallback always succeeds.
    """
    def enqueue(media_id) do
      fun = Application.get_env(:nebu_http, :media_scan_enqueue_fun)
      if fun, do: fun.(media_id), else: :ok
    end
  end

  defmodule ClamAV do
    @moduledoc """
    Fake for the `:media_clamav_module` seam
    (media-security-admin-control/4b-media-scan-worker) — the first seam
    this codebase adds for `Nebu.Media.ClamAV`, since production callers
    before this story always called the real GenServer directly. Tests set
    `:media_clamav_scan_fun`; default fallback returns
    `{:error, :no_fun_configured}` (loud failure rather than a silent
    false-clean if a test forgets to configure it).
    """
    def scan_binary(bytes) do
      fun = Application.get_env(:nebu_http, :media_clamav_scan_fun)
      if fun, do: fun.(bytes), else: {:error, :no_fun_configured}
    end

    @doc """
    media-security-admin-control/10d-scan-kill-switch: `MediaScanWorker` now
    calls `health_check/0` unconditionally before the scan pipeline. Tests
    using this shared fake exercise the ordinary (healthy) scan path, not
    the kill-switch itself (which has its own dedicated
    `media_scan_worker_kill_switch_test.exs` with a bespoke fake) — defaults
    to healthy; tests may override via `:media_clamav_health_fun`.
    """
    def health_check do
      fun =
        Application.get_env(:nebu_http, :media_clamav_health_fun, fn ->
          %{healthy: true, changed_at: DateTime.utc_now()}
        end)

      fun.()
    end
  end

  defmodule HttpFetch do
    @moduledoc "Fake HTTP fetch for preview_url (production: Finch). SSRF guard runs in the handler BEFORE this is ever reached."
    def fetch(url) do
      fun = Application.get_env(:nebu_http, :media_fetch_fun)

      if fun do
        fun.(url)
      else
        {:error, :no_fetch_fun}
      end
    end
  end
end
