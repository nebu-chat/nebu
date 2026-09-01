# Security Review — media-security-admin-control / 2b-put-media-upload

**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-14
**Diff scope:** `git diff --staged` — `server/lib/nebu/media.ex` (+169), `server/lib/nebu/media/db.ex` (+81, `lookup_reservation/2` + `persist_upload/1`), `server/lib/nebu/media/scan_enqueue.ex` (new, +28, no-op stub), `server/lib/nebu/web/router/media.ex` (+8, the PUT route), migration `000025_media_files_filename.{up,down}.sql` (ALTER TABLE media_files ADD COLUMN filename TEXT, nullable), and the test files (`media_async_upload_test.exs` new, `media_fakes.exs`, `release_test.exs`). Non-code artifacts (pipeline-state, step-results, sanctum, story md) excluded.
**Story:** 2b — `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`, the async-upload companion to the synchronous `upload/1`. Validates a reservation (ownership/expiry/state), then hash → gzip → AES-256-GCM → S3-key template → S3 write → persist row → `:reserved`→`:quarantined` transition → async-scan enqueue (currently a no-op stub; Oban not yet wired). First caller of three previously-standalone deps: `mime_denylist_rejected?/1` (9c), `StorageConfig.compute_key/2` (11c), `Storage.compress/1` (12/ADR-029).

---

## Verdict: CLEAN — no CRITICAL/HIGH. Commit not blocked.

Every surface the coordinator flagged for scrutiny was traced end-to-end in the code and holds:

- **Auth is not the ownership check alone.** The whole `Nebu.Web.Router.Media` pipeline runs `plug Nebu.Web.Plugs.OidcPlug` (router/media.ex:51) before `:match`/`:dispatch`, so the PUT is authenticated; `current_user` is a guaranteed non-nil binary or the request is 401'd upstream. The `uploader_user_id != user` check (media.ex:325) is defense-in-depth on top of that, not the sole gate. No unauthenticated upload path.
- **`compute_key/2` gets only server-controlled/constrained inputs.** `media_id` and `server_name` are the values that had to byte-match an existing reservation via `lookup_reservation/2`'s `WHERE server_name=$1 AND media_id=$2` equality. Story 2a stores `media_id = generate_media_id()` (128-bit `strong_rand_bytes`, base64url — charset `[A-Za-z0-9_-]`, no `/`, no `..`) and `server_name = server_name()` (config constant), so the PUT params that reach `compute_key` cannot contain a path-traversal or key-collision payload. `uploaded_at` is `DateTime.utc_now()` (server clock). No S3 key overwrite/collision attack via attacker input.
- **Encryption is correct.** Fresh 256-bit key (`strong_rand_bytes(32)`) AND fresh 96-bit nonce (`strong_rand_bytes(12)`) are generated per file inside `store_and_quarantine/7` (media.ex:411-412). No key or nonce reuse — GCM's catastrophic-reuse condition (same key + same nonce) is structurally impossible here.
- **The new `filename` field is NOT response-visible anywhere in the landed code.** It is persisted (db.ex `persist_upload`, `filename = $6`) but `row.filename` has **zero readers** (grep-confirmed). The download `Content-Disposition` uses the URL path segment `file_name`, never the stored column. The header-injection concern the coordinator raised is not live today — see F-2 for the forward watch-flag.
- **No content-type case-variation bypass.** `base_type/1` (media.ex:728-734) lower-cases and strips parameters *before* both the hardcoded `@blocked_upload_types` exact-match (`in`) and `mime_denylist_rejected?/1`'s prefix match, so `TEXT/HTML; charset=x` normalizes to `text/html` and is blocked on both lists.
- **DoS is bounded.** The route inherits the same `@upload_rate_limit` tier (600/min, burst 5) as the sync upload; body size is capped at `max_upload_bytes` (50 MB) by a cheap Content-Length pre-check *and* by `read_full_body/3` enforcing the ceiling during streaming read (a lying Content-Length cannot bypass). Compression/encryption work is therefore bounded; there is no decompression on the upload path (no zip-bomb).

All findings are advisory (LOW/INFO). One item is a genuine forward watch-flag for the download-wiring story.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | LOW/INFO | `media.ex:308-321` (state guard) + `store_and_quarantine/7` | Concurrent-PUT TOCTOU (accepted code-review MINOR-1): two concurrent PUTs to the same reservation both pass the lock-free `:reserved` guard; a specific S3-write/persist interleaving can leave DB key material mismatched with the S3 ciphertext | Verified **self-vs-self only** — deferral to Story 2c is sound (see detail). Optionally scope the persist to the acting row / add an advisory lock in 2c's consolidation. |
| F-2 | INFO (watch-flag) | new column persisted at `media.ex:444` / `db.ex:136`; future sink at `media.ex:637,718,720` | The stored `filename` is persisted **raw, unsanitized, and length-unbounded (TEXT)**. Not reflected today, but the existing `Content-Disposition` builders interpolate a filename into a quoted header via `~s(... filename="#{file_name}")` with no quote/CRLF escaping. Wiring `row.filename` into that sink naively = disposition/header-injection (quote breakout) | Before any story reads `row.filename` into a response header, apply an RFC 6266/5987-safe filename encoding (strip/escape `"`, `\`, CR/LF/control chars) and bound length at the write boundary here. Matches MEMORY Epic-12 pattern "Unvalidated … Content-Disposition filename". |
| F-3 | INFO | `000001_init.up.sql:288` (media_files), unchanged by this diff | `media_files` has **no RLS** — pre-existing standing gap, not introduced by adding a nullable column. `nebu_app` is NOBYPASSRLS; authorization is application-enforced (ownership on upload, room membership on download) | No change for 2b. Standing defense-in-depth gap consistent with sibling media/auth tables (`matrix_sessions`, `device_keys`). Track at the epic/RLS level, not here. |
| F-4 | INFO | `000025_media_files_filename.up.sql:11-14` | The migration's "no new GRANT" reasoning cites 000001's blanket grant. That is **accurate here** (media_files is created in 000001, same migration as the grant), but it is the same reasoning that fails silently for tables created in *later* migrations (MEMORY #86 / story 9a fail-open) | Conclusion (no new GRANT needed for an ALTER on a 000001 table) is correct; column grants inherit table-level grants. Documentation-hygiene note only — do not copy this justification onto a later-created table. |

---

## Detail

### F-1 — Concurrent-PUT TOCTOU is self-vs-self; the 2c deferral is security-sound [LOW/INFO]

The code comment (media.ex:308-321) documents the accepted risk: `lookup_reservation/2` reads state without a row lock, so two concurrent PUTs against the same reservation can both pass the `row.state != :reserved -> 409` guard and both enter `store_and_quarantine/7`. I traced every interleaving and reached the same conclusion the deferral assumes, with the reasoning made explicit:

**The two racers are always the same authenticated user.** Both PUTs must clear `row.uploader_user_id != user -> 403` (media.ex:325) against the *same* reservation row, so the only actor who can race a reservation is its own owner. There is **no cross-user and no unauthenticated** exposure — the classic TOCTOU escalation (attacker B racing owner A's write) is closed by the ownership check that precedes the state guard.

**`StateMachine.transition/4`'s `SELECT … FOR UPDATE` serializes the state change**, so exactly one `:reserved`→`:quarantined` transition wins; the loser now surfaces a real 500 (the MAJOR-1 fix), not a silent false-200. The residual is a data-*integrity* edge on the owner's own object: with the default template both writes land on the same S3 key (`{media_id}`), and if the S3-write order and the `persist_upload` order differ across the two requests, the DB row's `aes_key_hex`/`nonce_hex` can end up bound to the *other* request's ciphertext → GCM auth failure on the owner's own later download. Worst case: **the owner corrupts their own upload** and must re-reserve. No confidentiality or cross-tenant impact, no auth bypass. Rated LOW/INFO. Story 2c (which must reason about both upload paths at once) is the correct place to add real serialization if it proves to matter; I concur with the deferral.

### F-2 — Stored `filename` is raw/unbounded but not yet reflected [INFO / watch-flag]

`filename = conn.query_params["filename"]` (media.ex:379) is persisted verbatim via `persist_upload` (`filename = $6`) with no sanitization and no length bound (column is `TEXT`; in practice bounded only by the server's request-URI limit). **This is not a live finding** — `row.filename` is read by nothing (grep across `server/lib`), and the download `Content-Disposition` (`serve_bytes`/`serve_inline_image`/`disposition_for`, media.ex:625/637/718/720) uses the URL *path segment* `file_name`, not the stored column. So the coordinator's specific question — "is the new filename value put into any response header right now?" — answers **no**.

The watch-flag: those existing builders interpolate the filename straight into a double-quoted header value with `~s(inline; filename="#{file_name}")`. A value containing a `"` breaks out of the quoted-string and can inject additional disposition parameters; CR/LF would be rejected by Bandit's header validation, but the quote-breakout is not. The moment a future story derives `Content-Disposition` from the persisted `row.filename` (the stated purpose of AC2 / this column), it inherits that unsanitized sink with an *attacker-supplied* value. Remediate at that wiring: RFC 6266 `filename*`/percent-encoding, strip control + quote chars, and bound length at this write boundary. Pre-registered so it is not lost between stories.

### F-3 — media_files has no RLS [INFO, pre-existing]

`media_files` (created 000001) is absent from the RLS-enabled set (`server_config`, `audit_log`, `compliance_*`, `room_account_data`, `notifications`, `push_rules`, `pushers`). Adding a nullable column does not change this posture. Runtime `nebu_app` is NOBYPASSRLS, and authorization is enforced in application code (ownership on upload; `download_gate` state allow-list + room-membership on download). This is a standing defense-in-depth gap shared with the other media/auth tables, not introduced or worsened by 2b. Noted, not actioned here.

### F-4 — Migration GRANT justification is correct here but is the #86 anti-pattern shape [INFO]

The `.up.sql` header states no new GRANT is required because media_files "is already covered by migration 000001's blanket GRANT". Verified: `CREATE TABLE media_files` (000001:288) and `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nebu_app` (000001:672) are in the **same** migration, so the snapshot grant does cover it, and Postgres table-level grants automatically extend to columns added later by ALTER. The `nebu_app` runtime can therefore write the new column in production — no fail-open. The only note: this is textually the same reasoning that produced the 9a fail-open (a table created in a *later* migration is NOT covered by the 000001 snapshot — MEMORY #86). Correct conclusion, but do not port this justification to any later-created table. `MigrationsGrantTest`'s CREATE-TABLE-only requirement is satisfied (this migration creates no table).

---

## Adversarial probe results (coordinator watch-list)

1. **Auth / authorization bypass:** CLEAN. Whole media router behind `OidcPlug`; PUT authenticated. Ownership (`uploader_user_id == current_user`) checked before expiry/state, so a non-owner always gets 403 and never learns the reservation's state (no state oracle to non-owners). `current_user` guaranteed non-nil binary by the plug.

2. **SQL injection (ADR-018 raw `Ecto.Adapters.SQL.query/3`):** CLEAN. `lookup_reservation/2` binds `[server_name, media_id]` as `$1/$2`; `persist_upload/1` binds all nine fields as `$1..$9`. No string interpolation into SQL. `persist_upload`'s `WHERE media_id = $1` is unambiguous — `media_id` is the PRIMARY KEY (000001:289), globally unique, so no cross-row write despite dropping `server_name` from the WHERE.

3. **S3-key / path-traversal / overwrite via `compute_key/2`:** CLEAN. All three inputs are server-controlled or constrained-by-equality-match (see Verdict). `{media_id}` is a **mandatory** placeholder (`validate_template/1` → `check_media_id_present/1`), so every computed key carries the unique random media_id — an admin cannot even misconfigure a colliding template. `validate_template/1` rejects `..`, leading `/`, and literal `//` at upsert time (admin-trust boundary). No attacker-influenced string reaches the key.

4. **Encryption correctness:** CLEAN. Per-file fresh 256-bit key + fresh 96-bit nonce; hash(sha256 of plaintext) → compress → encrypt ordering (ADR-029) is correct; key/nonce persisted hex alongside metadata (established ADR-011 model, unchanged from the sync path). No reuse, no weak primitive.

5. **filename → Content-Disposition header injection:** NOT PRESENT today (see F-2). The stored column is never read into a response; the header uses the URL path segment. Forward watch-flag registered.

6. **Content-type XSS-blocklist bypass:** CLEAN. `base_type/1` lower-cases + strips `;`-params before both `@blocked_upload_types` (exact `in`) and `mime_denylist_rejected?/1` (prefix, both sides downcased). No case/parameter variation slips through. Layered further: `download_gate` serves only `:released`, so a freshly-`:quarantined` object is not downloadable at all until scanned+released.

7. **Info disclosure via 403/404/409:** ACCEPTABLE. The status distinctions are Matrix-spec-mandated for this endpoint, reachable only by authenticated callers, and gated so non-owners always get 403 (no state leak). `media_id` is 128-bit random → existence-enumeration infeasible. No leak beyond spec.

8. **Rate-limiting / DoS:** CLEAN. PUT inherits `@upload_rate_limit` (600/min, burst 5, per-IP). Body bounded by `over_content_length?/2` (cheap header reject) + `read_full_body/3` (enforces `max_upload_bytes` mid-stream; a spoofed Content-Length cannot bypass). Compression/encryption cost is bounded by the 50 MB ceiling; no decompression on upload. Empty-body and read-error branches fail closed (400) without storing a zero-byte object.

9. **Migration security posture:** ADD COLUMN nullable TEXT; reversible down migration; GRANT correct (F-4); no RLS change (F-3). No injection vector (static DDL), no sensitive-data-plaintext concern (filename is client metadata, not a secret).

10. **ScanEnqueue no-op stub:** CLEAN. `enqueue/1` logs `media_id` at `:debug` and returns `:ok`. `media_id` is a non-sensitive random identifier already exposed in the `mxc://` URI; no file content, no PII, no key material is logged. The `:reserved`→`:quarantined` transition proceeds without a scan running, but the download gate keeps `:quarantined` bytes unservable, so nothing malicious can be retrieved before the real scanner (Story 3/4b) lands.

---

## Summary

- **CRITICAL:** 0
- **HIGH:** 0
- **MEDIUM:** 0
- **LOW:** 1 — F-1 (concurrent-PUT TOCTOU, verified self-vs-self only; 2c deferral sound)
- **INFO:** 3 — F-2 (raw/unbounded stored `filename`, not reflected today — download-wiring watch-flag), F-3 (media_files no RLS, pre-existing standing gap), F-4 (migration GRANT justification correct but #86-shaped, doc hygiene)

**Verdict: CLEAN.** Every scrutiny target — the auth posture, `compute_key` input provenance, encryption freshness, the new `filename` field's reflection surface, the content-type blocklist normalization, the rate-limit/body-size caps, the migration's GRANT/RLS posture, and the accepted TOCTOU deferral — was verified in code and is sound. The PUT is authenticated, parameterizes all SQL, feeds only constrained/server-controlled values into the S3 key template, uses a fresh key+nonce per file, and does not reflect the newly-stored filename anywhere. The single item to carry forward is F-2: sanitize `row.filename` at the point a future story wires it into `Content-Disposition`. No blocking findings.
