# Epic Security Review — media-security-admin-control — 2026-07-20

**Reviewer:** Kassandra (SEC Gate 2 — mandatory epic-end review)
**Gate type:** Epic-end, full-diff, cross-story. This is the audit artifact — produced even at zero blocking findings.

## Scope

- **Epic:** media-security-admin-control (ClamAV quarantine/scan/release state machine + admin media UI + storage config + lifecycle/retention)
- **Base:** `4d89152c`
- **HEAD:** `e8dc71e3`
- **Branch:** `feature/advanced-media-management`
- **Diff size:** 375 files, ~68.6k insertions. Source (`server/lib/`): 47 files / ~10.5k LoC. Migrations: 13 new (`000022`–`000034`, up+down). 26 per-story security reports pre-existed under `docs/stories/media-security-admin-control/security-reports/`.
- **Stories covered (built):** 1a-1c, 2a-2e, 3, 4a-4c, 5a-5b, 6a-6c, 7, 8a-8d, 9a-9c, 10a-10e, 11a-11c.
- **Stories NOT built (documented pre-implementation scope debt, NOT gaps in shipped code):** 0 (UX Foundation), 6d (Bulk Cohort Actions), 13a-13f (Lifecycle Policy + Two-Eyes-Delete + DSGVO Art.17 Restriction-of-Processing). Confirmed absent from the diff. Story 8b is detection/reporting only and makes **no** Art.17 erasure claim (verified: the only `Art.17`/`GDPR` diff hits are the moduledoc explaining an earlier draft claim was retracted, plus explicit "do not claim" guardrails; `media_orphan_detection_run` is distinct from the pre-existing `gdpr_deletion` action and not repurposed).

> **Update 2026-07-21 — M-2 and M-3 RESOLVED (commit `dc0b199f`).** Both
> new-in-epic MEDIUMs were closed post-review by routing
> `Nebu.Media.StorageConfig`'s `test_connection/1` (M-2) and `upsert/1` (M-3)
> endpoint validation through the shared `Nebu.Media.SSRF.checked_target/1`
> guard — the same guard `preview_url` and `Nebu.Media.WebhookDelivery.post/2`
> already use — exactly as this report's own remediation recommended. Fixed
> via TDD (RED confirmed before the fix) in
> `server/lib/nebu/media/storage_config.ex`; see
> `docs/stories/media-security-admin-control/11a-storage-config-schema-secrets.md`'s
> Dev Agent Record ("Post-Epic Security Review Fix (M-2/M-3, epic security
> review 2026-07-20)") for full detail and the commit SHA. Full unit and
> integration suites re-verified green (only pre-existing/unrelated flaky
> failures, none touching `storage_config`/`media_settings_controller`/SSRF
> code). M-1/M-4/M-5 and all LOW/INFO findings are unchanged, out of scope
> for this fix, and remain documented follow-up debt per the epic owner's
> decision.

## Classification: **CLEAN** (no CRITICAL, no HIGH)

Epic security gate: **PASS.** No unauthenticated exploit, no auth bypass, no privilege escalation. Five MEDIUM and several LOW/INFO advisories are documented below; two MEDIUMs (M-2, M-3) are new-in-epic and should be closed before the epic is marked done (both are trivial fixes — reuse of an SSRF module that already exists in-tree).

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| M-1 | MEDIUM | 2d | `web/router/media.ex:77-83` | Download endpoint has no per-IP rate limit; the `?timeout_ms` stall holds connection+process+Task+PubSub sub open up to `max_stall_ms` (20s). A single IP can monopolize the global 500-slot stall pool. | Carried from 2d M-1, still open at epic end |
| M-2 | MEDIUM | 11b | `media/storage_config.ex:906-916` (`validate_candidate_endpoint/1`) | Storage-config "Test Connection" does a bespoke scheme-prefix string check only — no private/loopback/link-local/cloud-metadata IP block, no DNS resolution/pinning. Admin-supplied `169.254.169.254`, `127.0.0.1:9000`, RFC1918 etc. reach ExAws `head_bucket`. Blind (admin-authenticated) SSRF. | **RESOLVED 2026-07-21** — routed through `Nebu.Media.SSRF.checked_target/1` |
| M-3 | MEDIUM | 11a | `media/storage_config.ex:523` (`upsert/1`) | Endpoint is stored verbatim with no scheme/host validation on the persist path; the (weak) guard runs only on the test-connection path. A private/scheme-prefixed endpoint can be persisted and later used by `Nebu.Media.Storage` for real traffic. | **RESOLVED 2026-07-21** — routed through `Nebu.Media.SSRF.checked_target/1` |
| M-4 | MEDIUM | 11a/11b (pre-existing transport) | `mix.exs:76` (hackney) + `config/runtime.exs:118-128` (no `ssl`/`verify_peer`) | ExAws uses its default hackney adapter with no explicit TLS peer verification. When `NEBU_MINIO_USE_SSL=true`, S3/MinIO https traffic (incl. the new test-connection `head_bucket`) runs with **no certificate verification** — the recurring "empty-ssl-opts TLS gap" project pattern, now on the S3 transport. | Pre-existing; surface widened by 11a/11b |
| M-5 | MEDIUM | (pre-existing, admin-http-refactor) | `admin/router.ex:86-92` (`@csp`) | Admin CSP still has no `form-action` directive (no fallback to `default-src`); this epic adds new admin POST forms including the **storage-secret** config form. | Pre-existing watch-flag, scope grew |
| L-1 | LOW | 2b | `media.ex:342-365` (`upload_async`) + `store_and_quarantine/7` | Async self-vs-self TOCTOU: two concurrent PUTs to one reservation both pass the lock-free `:reserved` guard; an interleaving can bind the DB row's `aes_key_hex`/`nonce_hex` to the other request's ciphertext → GCM auth failure on the owner's own later download. | Confirmed still open (2c closed only the sync equivalent) |
| L-2 | LOW | 8a/2e/10a/10c | `000026_oban_jobs`, `000032_media_scan_stats`, `000033_media_alerts` | New tables created without `ENABLE ROW LEVEL SECURITY` + policy (GRANTs are present and correct). 032/033 document the omission as deliberate (derived/operational, not ledgers); 026 is a hand-translated Oban schema that silently omits it. Defense-in-depth deviation from the project invariant. | New this epic |
| L-3 | LOW | 2e | `workers/media_reserved_upload_cleanup_worker.ex:72-97` | Reserved-upload reaper performs a `:hard_deleted` transition but emits **no** `AuditWriter.log` entry, unlike the other three destructive workers (8a/8c/8d). | New this epic |
| L-4 | LOW | 11a | `media/storage_config.ex:747-768` (`decrypt_secret/1`) | Read-path silently falls back to env/default credentials when the at-rest key is unavailable or a stored secret fails to decrypt (writes still fail closed). Deliberate, but reduces the fail-closed guarantee on reads. | New this epic |
| L-5 | LOW/INFO | 3, 4b | `media/clamav.ex`, `workers/media_scan_worker.ex:212-236` | Story 3 carry-forwards: **F-2** (attacker bytes in OTP crash reports — no `Process.flag(:sensitive,true)`, non-total `connect/1`), **F-6** (raw signature interpolation into log) still open (LOW/hardening). **F-5** (size ceiling applied only inside `scan_binary`, after fetch+decrypt+gunzip) still not implemented — but bounded, not a true decompression bomb (see Cross-Story §5). **F-3** (node-wide scan serialization) is **addressed** by the `media_scan` Oban queue `limit: 10`. **F-7** (clamd `StreamMaxLength` alignment) operational. | Mixed: F-3 closed; F-2/F-5/F-6/F-7 open (LOW/operational) |

## Detail

### M-1 — Download endpoint unthrottled + stall connection-holding (MEDIUM)
`Nebu.Web.Router.Media` applies per-IP `RateLimit` to `upload` (600/min) and `preview_url` (30/min) but **not** to the `download` routes (`media.ex:77-83`). Story 2d's `?timeout_ms=N` turns a download into a held connection (HTTP conn + request process + linked `Task` + PubSub subscription) for up to `max_stall_ms` (default 20s). The only governor is the global `:atomics` ceiling of 500 concurrent stalls (`download_stall.ex:163-174`); there is no per-user/per-IP sub-cap. A single authenticated IP can hold and refresh 500 concurrent 20s stalls and monopolize the pool. Aggravated because no producer other than `MediaScanWorker` broadcasts, so a `:quarantined`/`:scanning` file rides out the full window. Denied users still get the immediate `451` (pre-2d behavior), so this denies an optimization + consumes a bounded pool rather than downing the node → MEDIUM, not HIGH. **Remediation:** add a per-IP `RateLimit` tier to the download routes (mirroring upload/preview_url) and/or a per-IP sub-ceiling on stall slots.

### M-2 — Storage-config Test-Connection SSRF (MEDIUM, new) — RESOLVED 2026-07-21
`validate_candidate_endpoint/1` (`storage_config.ex:906-916`) rejects only a literal `http://`/`https://` prefix. It does not resolve the host, does not block private/loopback/link-local/CGNAT/metadata addresses, and does not pin the resolved IP. `test_connection/1` (admin-gated via `plug Nebu.Admin.Auth, :require_admin`, `media_settings_controller.ex:113`) then issues a real ExAws `head_bucket` to the admin-supplied host. This is a genuine (blind, admin-authenticated) SSRF: the server's network position — inside the trusted network, able to reach internal services and the cloud metadata endpoint — is exposed to the admin. Rated MEDIUM (not HIGH) because it requires `instance_admin` (already the top privilege) and only success/error is surfaced to the caller — response bodies are not returned, so IMDS credential exfiltration via a `HEAD` is not achievable. It is nonetheless a **should-fix**: the strong shared guard `Nebu.Media.SSRF.checked_target/1` already exists and is used by `preview_url` and both webhook paths; this is the one admin-supplied-endpoint surface that skips it. **Remediation:** call `Nebu.Media.SSRF.checked_target/1` before the `head_bucket`, exactly as the webhook path does. This is a recurring codebase pattern ("Lazy validation of admin-saved external URLs widens SSRF window"; "Asymmetric handling across sibling features" — the `webhook_url` field on the *same* settings page *is* SSRF-guarded at save and send).

### M-3 — Endpoint not validated on persist path (MEDIUM, new) — RESOLVED 2026-07-21
`upsert/1` stores `endpoint` verbatim (`storage_config.ex:523`). The scheme/host guard runs only in the test-connection flow, so a private-host or scheme-prefixed endpoint can be persisted (skipping test-connection) and later used by `Nebu.Media.Storage` for real object-store traffic. **Remediation:** validate the endpoint (via the same `SSRF`/scheme check) at the persistence boundary, not only on test-connection. Companion to M-2.

### M-4 — No TLS peer verification on ExAws/S3 (MEDIUM, pre-existing)
ExAws (`~> 2.5`) uses its default hackney client; no `ssl: [verify: :verify_peer, cacerts: ...]` / `http_opts` is configured for ExAws anywhere (contrast `Nebu.Repo` at `runtime.exs:168-175`, which does configure `verify_peer` + `cacertfile`). `use_ssl?` defaults to `false` (`runtime.exs:98`), so the default deployment talks plaintext http to MinIO on the internal compose network (acceptable). But when an operator sets `NEBU_MINIO_USE_SSL=true` to reach a real object store (e.g. Stackit), S3 https traffic — including the new 11b test-connection — runs without certificate verification, MITM-able by an on-path attacker. Blast radius is limited: media is AES-256-GCM encrypted client-side before upload (a MITM sees ciphertext; forged responses fail GCM auth → 502, not compromise); primary exposure is the S3 AccessKeyId and object-key metadata. Pre-existing (the ExAws transport predates this epic) but the epic's admin-configurable-endpoint direction (11a/11b) makes it more relevant. This is the same class as the recurring `:httpc`/empty-ssl gap (struck 3× before). **Remediation:** configure ExAws hackney with `verify: :verify_peer` + a CA store, gated on https.

### M-5 — Admin CSP missing `form-action` (MEDIUM, pre-existing; scope grew)
`@csp` (`admin/router.ex:86-92`) defines `default-src 'self'`, `script-src 'self'` (no `unsafe-inline`/`eval`), etc. but no `form-action`, which has no `default-src` fallback. This epic adds new admin POST forms including the storage-secret config form. Practical risk stays low (no XSS foothold: `script-src 'self'`, filenames HEEx-escaped, no media preview surface), so a form-exfil requires an injection vector that does not currently exist. **Remediation:** add `form-action 'self'` to `@csp` (previously flagged for the admin-http-refactor gate).

## Cross-Story Patterns

The epic's real risk surface is the long chain **async upload (2a-2e) → scan worker (4b/4c/10d) → admin actions (6a-6c) → retention (8a-8d)**. Reviewed as one flow:

1. **`:admin_blocked` anonymity — CLOSED, verified end-to-end.** `download_gate/1` (`media.ex:979-1015`) returns byte-identical `{404,"M_NOT_FOUND"}` for `:admin_blocked`, `:infected`, `:deleted`, `:hard_deleted`, and genuine unknown-media-id. All flow through the same `error/4` → `send_json/3` (`media.ex:1281-1283`) — identical status line, errcode, message string ("Media not found") and headers. The 6a fix (451→404) is present in the final code. The 2d stall (`maybe_await_stall/3`, `media.ex:594-611`) gates only on `state in [:quarantined,:scanning]`, evaluated before the gate, so deny-states never stall → no timing oracle distinguishing admin_blocked from never-existed. The 6b admin detail view (`media_live/detail.ex`) does expose full state, but it is inside `live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin}` — admins are authorized to know; the anonymity property is a public-download property, not an admin-UI one. No side-channel leak found.

2. **Admin-action identity is server-derived — no privilege escalation.** Every LiveView admin handler (`media_live.ex:564-668`) sets `admin_id = actor_id(socket.assigns.current_user)` (established by `require_admin` on_mount). Clients supply only `media_id`/`reason` (data), never identity. The 6c infected→released override is double-gated: the `require_admin` session gate **plus** an independent server-side `media_admin_override` grant re-check in `Nebu.Media.admin_override_infected/3` → `authorize_override/1` → `db.check_override_role/1` (`media.ex:848-904`, `db.ex:336-356`), so a replayed/forged phx-click from a session lacking the grant is rejected regardless of the UI's own display flag.

3. **Migration chain — no missing GRANT, no weakened RLS.** All 13 up-migrations that create tables include explicit `GRANT ... TO nebu_app` (+ sequence grants) — the recurring "MigrationsGrantTest" bug did **not** recur. No migration drops or weakens RLS/FORCE on any pre-existing table (`audit_log`, `events`, `media_files`, `server_config`); the only policy changes are additive `ALTER POLICY` allowlist extensions on `media_config` (000033/000034), never `USING (true)`. `000022`'s `media_state_transitions` ledger is correctly append-only (INSERT/SELECT `true`, UPDATE/DELETE `USING(false)` + BEFORE trigger + REVOKE). The one functionally-permissive UPDATE (`storage_config_update_singleton USING (id=1)`) equals `true` only because of the singleton `CHECK (id=1)` — acceptable for a single-row config. The three missing-RLS tables are captured as L-2.

4. **Cumulative crypto/secrets — mutually consistent.** Storage secrets (11a) use the shared `Nebu.Web.SecretBox`: AES-256-GCM, key = SHA-256(internal_secret), fresh `strong_rand_bytes(12)` nonce per encrypt, and it **raises** rather than deriving `SHA-256("")` on an empty key (fail-closed on write). Secrets are masked in `get/0`, exposed to the UI only as `*_configured` booleans with write-only `type=password` "Currently configured" placeholders, and never logged (audit records field *names* only). The `actor_id` UUID→TEXT migration (000029, for 6a's Matrix-ID actors) is lossless with no constraint loss (the column was already nullable, no FK/CHECK). `config.ex` (9a) correctly stores no secret (webhook_url is not a credential). The SSRF guard is shared and consistent across `preview_url` + both webhook paths — the storage-config test-connection (M-2) is the one inconsistent outlier.

5. **Scan worker (4b) memory/DoS (Story 3 F-3/F-5).** F-3 (node-wide serialization) is closed: `media_scan` Oban queue `limit: 10` caps concurrent scans. F-5 (ceiling applied only inside `scan_binary`, i.e. after `storage.get` + decrypt + `:zlib.gunzip`) is not fixed, but is **not a decompression bomb**: compression is performed *server-side* on the plaintext body (`encrypt_compress_and_store/5`), and that body was already bounded by `max_upload_bytes` at upload; `gunzip` reverses the server's own gzip of an already-bounded, GCM-authenticated blob, so peak per-scan memory ≈ upload-limit and total peak ≈ `10 × max_upload_bytes`. Bounded and known, not amplifiable → LOW/INFO (recommend a pre-fetch `row.file_size` short-circuit to avoid needless S3 GET+decrypt for oversized rows).

6. **Kill-switch fail-open chain (10d) — accepted combination of two accepted risks.** `MediaScanWorker` defaults `scan_kill_switch` to `fail_closed`; `fail_open` releases unscanned and writes the `media_unscanned_release` audit action (present in `@known_actions`). The corrupted-value branch fails **closed**. The 10d chain-risk note (fail_open + an attacker who already breached the docker network reaching clamd's unauthenticated `SHUTDOWN`) is a combination of two already-accepted decisions, not a new vuln: verified Story 3 F-4 stays remediated — `docker-compose.yml` publishes **no** `ports:` for the `clamav` service (reachable only container-to-container).

7. **Audit completeness across new action shapes.** All 14 new media audit actions are present in `AuditWriter.@known_actions` (`audit_writer.ex:137-150`) — the "audit allowlist merge gotcha" was avoided. Destructive workers 8a/8c/8d emit distinct audit actions (`media_hard_deleted`/`media_archived`/`media_released_auto_deleted`); only the 2e reserved-reaper omits one (L-3). Worker/admin audit writes are best-effort fire-and-forget (logged-not-propagated on failure) — the accepted project-wide pattern.

## Accepted Risks (pre-existing, re-confirmed, not re-flagged)

- `audit_log` FORCE-RLS-removed → application-enforced append-only on managed PG (MEMORY, Phil 2026-05-18). Not touched by this epic.
- `M_USER_DEACTIVATED` account-existence disclosure to authenticated callers (BOND, 2026-05-17). Unrelated to this epic.

## Follow-up Stories / Actions Required

None block the gate (no CRITICAL/HIGH). Recommended before the epic is marked done:
1. ~~**M-2 + M-3 (new this epic):** route the storage-config endpoint (test-connection and persist) through `Nebu.Media.SSRF.checked_target/1` — the module already exists and is used by three sibling surfaces. Trivial, closes a new SSRF surface.~~ **RESOLVED 2026-07-21** — see the update note at the top of this report.
2. **M-1 (carried from 2d):** add a per-IP rate-limit tier / stall sub-ceiling to the download route.
3. **M-4:** configure ExAws hackney TLS `verify_peer` + CA store (gated on https).
4. **M-5:** add `form-action 'self'` to the admin CSP.
5. LOW hardening backlog: L-2 (RLS on the three tables, or a documented waiver), L-3 (2e audit entry), L-4 (read-path fail-closed decision), L-5 (clamav `Process.flag(:sensitive,true)` + total `connect/1`; scan-worker pre-fetch size gate).

## Summary

CRITICAL: 0 | HIGH: 0 | MEDIUM: 5 (2 new-in-epic, 3 pre-existing/carried) | LOW/INFO: 5

**Epic security gate: PASS** — no CRITICAL/HIGH. Cross-story anonymity, admin-action authorization, migration GRANT/RLS integrity, and secrets-at-rest all hold end-to-end. The two new-in-epic MEDIUMs (M-2/M-3, storage-config SSRF) and the carried M-1 (download rate-limit) should be closed before the epic is marked done; M-4/M-5 are pre-existing hardening items surfaced/widened by this epic.
