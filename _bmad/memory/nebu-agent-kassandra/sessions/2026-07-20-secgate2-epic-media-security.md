## Session — Epic-end SEC Gate 2: media-security-admin-control

**Scope:** Full epic diff `4d89152c..e8dc71e3` (branch feature/advanced-media-management). 375 files, 47 lib source files, 13 new migrations (000022-000034). Stories 1a-11c built; 0/6d/13a-13f NOT built (documented scope debt, not gaps).

**Verdict:** CLEAN (0 CRITICAL, 0 HIGH). Gate PASS.
Report: `_bmad-output/implementation-artifacts/epic-media-security-admin-control-security-review-2026-07-20.md`

**Finding summary:** 0 CRITICAL, 0 HIGH, 5 MEDIUM, 5 LOW/INFO.
- M-1 (2d, carried, still open): download endpoint no per-IP rate limit; stall holds conns, global-500 pool monopolizable.
- M-2 (11b, NEW): storage-config Test-Connection SSRF — bespoke scheme-only check, no private/metadata-IP block, no DNS pin; skips the in-tree `Nebu.Media.SSRF` that preview_url + webhook already use. Blind, admin-authenticated → MEDIUM not HIGH (instance_admin only, head_bucket body not surfaced so no IMDS cred exfil).
- M-3 (11a, NEW): endpoint stored verbatim on upsert path; guard only on test-connection path.
- M-4 (pre-existing): ExAws default hackney, no verify_peer; only bites when NEBU_MINIO_USE_SSL=true (default false=plaintext internal http). Media is GCM-encrypted client-side so blast radius bounded.
- M-5 (pre-existing admin-http-refactor): admin CSP still no form-action; now covers storage-secret form.
- L-1..L-5: 2b async self-vs-self TOCTOU (still open, self-inflicted GCM-corrupt-own-file, LOW); 3 tables no RLS (oban_jobs/peers, media_scan_stats, media_alerts — grants present); 2e reaper no audit entry; storage_config read-path silent env-cred fallback; clamav F-2/F-6 hardening + 4b F-5 pre-fetch size gate (bounded, not a bomb).

**Verified CLOSED / held:**
- admin_blocked anonymity: byte-identical 404 end-to-end (gate + error/4 identical status/body/headers; stall never touches deny-states; 6b detail is admin-gated so no public leak). 6a fix present in final code.
- MigrationsGrantTest pattern did NOT recur — every table-creating migration GRANTs nebu_app.
- No weakened RLS/FORCE on pre-existing tables; media_config UPDATE stays key-allowlist-scoped.
- actor_id UUID→TEXT (000029) lossless, no constraint loss.
- 6c override double-gated (require_admin + independent check_override_role). Admin identity server-derived everywhere (socket.assigns.current_user), never client params.
- Story 3 F-4 clamd still no host port (10d chain-risk = accepted×accepted). F-3 closed by Oban queue limit 10.
- All 14 new media audit actions in @known_actions (merge gotcha avoided).
- 8b orphan detection is detection-only; no Art.17 claim anywhere.
- Secrets-at-rest correct: SecretBox AES-256-GCM, fresh nonce, fail-closed write, masked/write-only UI.

**New patterns curated to MEMORY.md:** (1) In-tree shared SSRF guard bypassed on ONE sibling surface while peers use it. (2) F-5-style "size ceiling after in-memory decrypt+decompress" is NOT a bomb when compression is server-side over an upload-bounded plaintext (calibration note).

**Follow-up:** M-2/M-3 trivial fix (reuse Nebu.Media.SSRF.checked_target/1) recommended before epic marked done; M-1 rate-limit; M-4 ExAws verify_peer; M-5 form-action.
