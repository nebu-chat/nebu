defmodule Nebu.Workers.MediaScanWorker do
  @moduledoc """
  Oban worker (`media-security-admin-control/4b-media-scan-worker`) that picks
  up a `:quarantined` `media_files` row, transitions it to `:scanning`,
  fetches/decrypts/(conditionally decompresses) its bytes, calls
  `Nebu.Media.ClamAV.scan_binary/1`, and drives
  `Nebu.Media.StateMachine.transition/4` to whichever terminal outcome the
  scan produces: `:released` (clean or size-skip), `:infected`, or, once
  retries are genuinely exhausted, `:scan_failed` (Story 4a).

  This story defines the queue/worker/args contract Story 2b's
  `Nebu.Media.ScanEnqueue.enqueue/1` calls into:
  `%{media_id: media_id} |> new() |> Oban.insert()` — Oban serializes `args`
  through JSON, so `perform/1` reads the STRING key `"media_id"`.

  ## AC1/AC2 note — Oban itself is not bootstrapped here

  Oban (dependency, `oban_jobs` schema, `Nebu.Application` supervisor child)
  was already introduced by `media-security-admin-control/
  2e-reserved-upload-cleanup-cron` (commit `a2498fda`), which landed ahead of
  this story in actual build order and absorbed that one-time bootstrap. This
  module only adds the `:media_scan` queue itself
  (`config :nebu, Oban, queues: [..., media_scan: [limit: 10]]`) and this
  worker module — see `config/config.exs` for the queue entry.

  ## Broadcast contract — must match Story 2d exactly

  Every terminal transition this worker produces (`:released`, `:infected`,
  `:scan_failed`) broadcasts
  `Phoenix.PubSub.broadcast(Nebu.PubSub, "media:\#{media_id}",
  {:media_state_transition, media_id, new_state})` — confirmed against the
  real `Nebu.Media.DownloadStall` (Story 2d) producer contract, not just the
  story prose. Omitting the broadcast on any one of the three would leave a
  stalled downloader waiting out its full timeout even though the file
  became permanently available/unavailable/failed seconds in (AC8).

  ## Fetch/decrypt/decompress (AC4)

  `aes_key_hex`/`nonce_hex` are stored as hex strings on `media_files`
  (`Nebu.Media.DB.lookup_for_scan/1`'s result) — hex-decoded here before the
  `Nebu.Media.Crypto.decrypt/3` call, which requires raw 32-/12-byte
  binaries. `Nebu.Media.Crypto` has no app-env seam (a pure, deterministic
  function) — called directly, never through an injectable seam.
  `:zlib.gunzip/1` runs only when the row's `compressed` flag is `true`
  (ADR-029's compression-before-encryption ordering means decompression is
  always the LAST of these three steps, after decryption).

  ## Error handling

  Any failure fetching/decrypting the bytes (DB lookup miss, S3 error,
  decrypt failure) is routed through the SAME retry/discard path as a
  scanner error (AC9) rather than inventing a second failure-handling
  mechanism — both are "the scan could not be completed this attempt,"
  structurally identical from the worker's perspective.

  ## Compliance audit bridge (`media-security-admin-control/
  4c-infected-scanfailed-audit-bridge`)

  The two compliance-relevant terminal outcomes — `:infected` (confirmed
  malware) and `:scan_failed` (retries exhausted, in the `attempt >=
  max_attempts` branch of `scan_error/4` — there is no separate Oban
  `discard/2` callback; `scan_error/4` returns `{:discard, reason}` itself)
  — additionally write one `audit_log` row each via
  `Nebu.Compliance.AuditWriter.log/6` (ADR-020: the only public,
  cross-domain-callable entry point for audit writes), alongside (never
  instead of) the existing `media_state_transitions` write. Routine
  transitions (`:released`, retry-to-`:quarantined`, the entry-transition
  no-op) do NOT get an audit_log entry — only `:infected`/`:scan_failed`
  bridge across, per ADR-028. `AuditWriter.log/6` never raises; a failed
  audit write is logged and does not affect this worker's own return
  value/retry behavior (no transaction coupling with the state-machine
  write).

  ## Scan kill-switch (`media-security-admin-control/10d-scan-kill-switch`)

  `scan_and_transition/3` checks `Nebu.Media.ClamAV.health_check/0` FIRST,
  before the `with` chain above ever fetches/decrypts anything. When
  unhealthy, the admin-configurable `Nebu.Media.Config.get/0`
  `scan_kill_switch` value (default `"fail_closed"` — see `Nebu.Media.Config`
  and this story's Dev Agent Guardrails; never silently `"fail_open"`)
  decides the outcome: `"fail_open"` releases the file unscanned
  (`:scanning -> :released`, metadata `%{unscanned: true, reason:
  "clamav_unavailable"}`) and writes a THIRD compliance-relevant audit action,
  `media_unscanned_release` (AC7, non-negotiable — the single most
  security-sensitive event this story exists to make visible); `"fail_closed"`
  reuses `scan_error/4` UNMODIFIED with reason `:clamav_unavailable` — the
  exact same retry-then-exhaust-to-`scan_failed` path as any other scanner
  error, so the exhausted-retries case rides Story 4c's existing
  `media_scan_failed` audit bridge above with zero new code. Read fresh via
  `Nebu.Media.Config.get/0` on every call (never cached in this worker's own
  state), so a live config change takes effect on the very next job.
  """

  use Oban.Worker, queue: :media_scan, max_attempts: 5

  require Logger

  # media-security-admin-control/4c-infected-scanfailed-audit-bridge:
  # system-actor sentinel for AuditWriter.log/6's actor_user_id, mirroring
  # the Nebu.Media convention (Nebu.Media.Config's "system:media_config",
  # Nebu.Media.StorageConfig's "system:media_storage_config") — no human
  # admin is involved in either of these system-driven transitions.
  @audit_actor "system:media_scan_worker"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_id" => media_id}, attempt: attempt, max_attempts: max_attempts}) do
    case state_machine().transition(media_id, :scanning, {:system, nil}) do
      {:error, {:invalid_transition, from, :scanning}} ->
        Logger.info(
          "Nebu.Workers.MediaScanWorker: media_id=#{media_id} no longer scannable " <>
            "(#{inspect(from)} -> :scanning rejected) — no-op"
        )

        :ok

      {:ok, :scanning} ->
        scan_and_transition(media_id, attempt, max_attempts)

      # code-review MINOR-3 fix: any OTHER unexpected entry-transition outcome
      # (`:not_found`, `:invalid_actor`, or any future StateMachine error
      # shape) must still drive this worker's own retry/discard/broadcast
      # guarantee (AC9) rather than crash with an uncaught CaseClauseError —
      # a crash bypasses scan_error/4 entirely, so on the LAST attempt the
      # file could be left silently stuck in :quarantined (or, here, never
      # even reach it) with no scan_failed transition and no broadcast.
      {:error, reason} ->
        scan_error(media_id, reason, attempt, max_attempts)
    end
  end

  # media-security-admin-control/10d-scan-kill-switch (AC3): the health-check
  # is consulted BEFORE the existing `with` chain below (no storage
  # fetch/decrypt/decompress/scan_binary happens for either kill-switch
  # branch) — a kill-switch decision never needs the file bytes at all, so
  # checking first avoids a wasted S3 round-trip and decrypt on every retry
  # while clamd is down. When ClamAV is healthy, behavior is completely
  # unchanged from Story 4b (AC8) — the branch below falls straight through
  # to the pre-existing scan pipeline.
  defp scan_and_transition(media_id, attempt, max_attempts) do
    # media-security-admin-control/10e-trace-map-war-room-integration (AC2):
    # scan-start, tagged with route_template + request_id == media_id (the
    # media UUID reused AS the correlation key — see the story's Technical
    # Requirements). Added alongside, never instead of, the existing
    # transition/broadcast calls below.
    #
    # code-review cycle 2 (MAJOR-2): Logger.info/2 (per AC2's exact spec) —
    # this is the routine/success path (every scan attempt starts this way),
    # not an error condition; only the infected/error-retry paths below stay
    # at Logger.warning/2. The "10e AC2" describe block in
    # media_scan_worker_test.exs now raises the Logger level to :info for its
    # own tests (mirroring request_logger_test.exs's Logger.configure(level:
    # :info) precedent) so this call is actually observable there.
    Logger.info(
      "Nebu.Workers.MediaScanWorker: media_id=#{media_id} scan started",
      route_template: "/media/scan_worker",
      request_id: media_id
    )

    if clamav_healthy?() do
      do_scan_and_transition(media_id, attempt, max_attempts)
    else
      handle_kill_switch(media_id, attempt, max_attempts)
    end
  end

  # Nebu.Media.ClamAV.health_check/0 (Story 3, extended by 10b) returns
  # %{healthy: boolean(), changed_at: DateTime.t()} — NOT a bare :healthy /
  # :unhealthy atom.
  defp clamav_healthy? do
    match?(%{healthy: true}, clamav().health_check())
  end

  # AC4/AC5: dispatches on the admin-configurable scan_kill_switch policy
  # (Nebu.Media.Config, Story 9a) — read fresh on every call (never cached
  # outside Config's own ETS/:pg mechanism), so AC6's live-policy-change
  # guarantee falls out of Config's existing live-read contract for free.
  defp handle_kill_switch(media_id, attempt, max_attempts) do
    case media_config().get().scan_kill_switch do
      "fail_open" ->
        metadata = %{unscanned: true, reason: "clamav_unavailable"}
        {:ok, :released} = state_machine().transition(media_id, :released, {:system, nil}, metadata)
        broadcast(media_id, :released)
        write_audit(media_id, "media_unscanned_release", "success", metadata)
        :ok

      "fail_closed" ->
        # AC5/AC9: reuses Story 4b's existing, unmodified scan_error/4
        # retry/discard mechanism verbatim — this is NOT a second retry
        # loop. On exhaustion this already triggers Story 4c's existing
        # media_scan_failed audit bridge with no new code needed for that
        # path.
        scan_error(media_id, :clamav_unavailable, attempt, max_attempts)

      other ->
        # Defensive-only: `Nebu.Media.Config.upsert/1` is the ONLY validated
        # write path and rejects anything other than "fail_open"/
        # "fail_closed" before it ever reaches the DB — this clause should
        # be unreachable in practice. It exists so that an unexpected/
        # corrupted value (e.g. a manual DB edit bypassing upsert/1) fails
        # CLOSED (the story's own safety posture — "never silently
        # fail_open") instead of crashing the Oban job with an uncontrolled
        # CaseClauseError.
        Logger.warning(
          "Nebu.Workers.MediaScanWorker: unexpected scan_kill_switch value #{inspect(other)} " <>
            "for media_id=#{media_id} — failing closed"
        )

        scan_error(media_id, :clamav_unavailable, attempt, max_attempts)
    end
  end

  defp do_scan_and_transition(media_id, attempt, max_attempts) do
    with {:ok, row} <- db().lookup_for_scan(media_id),
         {:ok, ciphertext} <- storage().get(row.storage_key),
         {:ok, key} <- decode_hex(row.aes_key_hex),
         {:ok, nonce} <- decode_hex(row.nonce_hex),
         {:ok, plaintext} <- Nebu.Media.Crypto.decrypt(ciphertext, key, nonce) do
      bytes = maybe_gunzip(plaintext, row.compressed)

      case clamav().scan_binary(bytes) do
        {:ok, :clean} ->
          release(media_id, %{})

        {:ok, {:infected, signature}} ->
          infect(media_id, signature)

        {:error, :file_too_large} ->
          release(media_id, %{skipped: "size_limit"})

        {:error, reason} ->
          scan_error(media_id, reason, attempt, max_attempts)
      end
    else
      {:error, reason} -> scan_error(media_id, reason, attempt, max_attempts)
    end
  end

  defp release(media_id, metadata) do
    {:ok, :released} = state_machine().transition(media_id, :released, {:system, nil}, metadata)
    broadcast(media_id, :released)

    # media-security-admin-control/10e-trace-map-war-room-integration (AC2):
    # scan-result (released), same route_template/request_id correlation.
    # code-review cycle 2 (MAJOR-2): Logger.info/2 — the clean/released
    # outcome is the routine success path, not a warning; see the scan-start
    # call site above for the matching test-visibility fix.
    Logger.info(
      "Nebu.Workers.MediaScanWorker: media_id=#{media_id} scan result: released",
      route_template: "/media/scan_worker",
      request_id: media_id
    )

    :ok
  end

  defp infect(media_id, signature) do
    metadata = %{clamav_signature: signature, scanned_at: DateTime.utc_now()}
    {:ok, :infected} = state_machine().transition(media_id, :infected, {:system, nil}, metadata)

    # code-review INFO-1: the story's own Technical Requirements frames a
    # shared transaction with the transition above as a "prefer," not a
    # MUST (a separate media_files.scan_metadata UPDATE is explicitly not a
    # violation of Story 1b's state-mutation invariant) — logging on failure
    # so a persistence problem here is at least observable, without going as
    # far as rolling this into transition/4's own transaction.
    case db().update_scan_metadata(media_id, metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Nebu.Workers.MediaScanWorker: update_scan_metadata failed for media_id=#{media_id}: #{inspect(reason)}"
        )
    end

    broadcast(media_id, :infected)

    # media-security-admin-control/10e-trace-map-war-room-integration (AC2):
    # scan-result (infected), additionally carrying the ClamAV signature —
    # never the file's bytes/filename/Matrix content, only this identifier.
    Logger.warning(
      "Nebu.Workers.MediaScanWorker: media_id=#{media_id} scan result: infected",
      route_template: "/media/scan_worker",
      request_id: media_id,
      clamav_signature: signature
    )

    write_audit(media_id, "media_infected_detected", "success", %{clamav_signature: signature})

    :ok
  end

  defp scan_error(media_id, reason, attempt, max_attempts) do
    {:ok, :quarantined} =
      state_machine().transition(media_id, :quarantined, {:system, nil}, %{reason: inspect(reason)})

    # media-security-admin-control/10e-trace-map-war-room-integration (AC2):
    # scan-error (covers both the retry and the exhausted-to-scan_failed
    # branches below — both pass through this one call site), additionally
    # carrying the inspected error reason.
    Logger.warning(
      "Nebu.Workers.MediaScanWorker: media_id=#{media_id} scan error (#{inspect(reason)})",
      route_template: "/media/scan_worker",
      request_id: media_id,
      reason: inspect(reason)
    )

    if attempt >= max_attempts do
      {:ok, :scan_failed} =
        state_machine().transition(media_id, :scan_failed, {:system, nil}, %{reason: inspect(reason)})

      broadcast(media_id, :scan_failed)

      write_audit(media_id, "media_scan_failed", "failure", %{reason: inspect(reason)})

      {:discard, reason}
    else
      {:error, reason}
    end
  end

  # media-security-admin-control/4c-infected-scanfailed-audit-bridge (AC1-AC9):
  # bridges an :infected/:scan_failed media_state_transitions write into the
  # global audit_log via Nebu.Compliance.AuditWriter's public log/6 (ADR-020)
  # — never a direct Repo/AuditLogEntry write from Nebu.Media/Nebu.Workers.
  # `target_type: "media"` / `target_id: media_id`; no `room_id` key is added
  # to metadata (ADR-028 — room attribution is a future query-time join, out
  # of scope here). Independently re-looks-up filename/sha256/uploader_id by
  # media_id (rather than threading `row` through every scan_error/4 call
  # site) because scan_error/4 is also reached from paths where no row was
  # ever successfully fetched (the entry-transition-rejected branch in
  # perform/1, or a lookup_for_scan/storage/decrypt failure inside the `with`
  # chain in scan_and_transition/3) — a best-effort enrichment lookup here
  # degrades to omitted fields rather than blocking the audit write itself.
  defp write_audit(media_id, action, outcome, extra_metadata) do
    metadata =
      %{media_id: media_id}
      |> Map.merge(audit_enrichment(media_id))
      |> Map.merge(extra_metadata)

    case audit_writer().log(@audit_actor, action, "media", media_id, metadata, outcome) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Nebu.Workers.MediaScanWorker: audit write failed action=#{action} " <>
            "media_id=#{media_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp audit_enrichment(media_id) do
    case db().lookup_for_scan(media_id) do
      {:ok, row} ->
        %{
          filename: Map.get(row, :filename),
          sha256: Map.get(row, :file_hash),
          uploader_id: Map.get(row, :uploader_user_id)
        }

      {:error, _reason} ->
        %{}
    end
  end

  # code-review MINOR-2 fix: non-bang hex decode so a corrupted/malformed
  # aes_key_hex/nonce_hex value (data corruption, not a normal operating
  # condition — this codebase only ever writes valid hex here via its own
  # Crypto/upload path) folds into the SAME scan_error/4 retry/discard path
  # as any other pre-scan failure, instead of raising ArgumentError and
  # crashing straight out of the `with` chain — a raise would bypass
  # scan_error/4 entirely, and on the last attempt would skip the
  # `:scan_failed` transition/broadcast AC9 exists to guarantee.
  defp decode_hex(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_hex}
    end
  end

  defp maybe_gunzip(bytes, true), do: :zlib.gunzip(bytes)
  defp maybe_gunzip(bytes, false), do: bytes

  defp broadcast(media_id, new_state) do
    Phoenix.PubSub.broadcast(
      Nebu.PubSub,
      "media:#{media_id}",
      {:media_state_transition, media_id, new_state}
    )
  end

  defp state_machine,
    do: Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)

  defp db, do: Application.get_env(:nebu_http, :media_db_module, Nebu.Media.DB)
  defp storage, do: Application.get_env(:nebu_http, :media_storage_module, Nebu.Media.Storage)
  defp clamav, do: Application.get_env(:nebu_http, :media_clamav_module, Nebu.Media.ClamAV)

  defp audit_writer,
    do: Application.get_env(:nebu_http, :media_audit_writer_module, Nebu.Compliance.AuditWriter)

  # media-security-admin-control/10d-scan-kill-switch: mirrors
  # Nebu.Workers.MediaAlertsCheckerWorker's (Story 10c) own media_config/0
  # seam convention exactly — :nebu_http namespace, not :nebu.
  defp media_config,
    do: Application.get_env(:nebu_http, :media_config_module, Nebu.Media.Config)
end
