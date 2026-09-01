# Security Review — media-security-admin-control / 9a-media-config-table-module

**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-13
**Diff scope:** New/staged files — `server/lib/nebu/media/config.ex` (new ETS-backed cache + validated write path), `server/lib/nebu/media/config_supervisor.ex` (new dedicated child supervisor), `server/priv/migrations/000023_media_config.up.sql` / `.down.sql` (new `media_config` table + RLS), and modified `server/lib/nebu/application.ex` (supervisor placement), `server/lib/nebu/compliance/audit_writer.ex` (`media_config_updated` added to `@known_actions`), `server/test/nebu/release_test.exs` (migration count), `server/test/nebu/media/config_test.exs` (new, seam-driven suite).
**Story:** 9a — builds the `media_config` key/value table + `Nebu.Media.Config` module (`get/0`, `upsert/3`) as the single validated write path for 10 runtime-configurable media-policy values (upload/scan size limits, retention windows, admin-notification webhook URL, MIME denylist). Does NOT wire any consumer — enforcement lands in later stories (9b UI, 9c mime enforcement, 7 webhook sender).
**Relevant ADRs:** ADR-027 (dedicated `media_config` table, not an extension of `server_config`), ADR-020 (single public-API module), ADR-018 (inline SQL, no repository layer).
**Prior cycles:** Cycle-0 code-review (non-security) fixed M1 (build_catalog KeyError), m3 (swallowed audit failure), m4 (actor param); accepted m1 (bespoke supervisor / `max_restarts: 1000/5s`) and m2 (no transaction around read-old→write→audit). I independently re-traced every path and re-weighed m1/m2/m3 for a security dimension the non-security reviews would not have scored.

---

## Verdict: BLOCKED — 1 HIGH.

The Elixir module itself is careful: `SSRF.check/1` is invoked on every non-nil `webhook_url` write before any DB call (AC4 holds), all SQL is fully parameterized (no interpolation — F-INFO items confirm), unknown keys are rejected before touching the DB, and the ETS/`:pg`/TTL invalidation mirrors `OidcConfig` correctly. The accepted m1/m2/m3 do NOT hide a CRITICAL/HIGH security consequence (see F-INFO-B/C/D).

The blocker is in the **migration**, not the module: `000023_media_config.up.sql` ships **no `GRANT ... TO nebu_app`**. In the production dual-role deployment this makes the entire table inaccessible to the runtime role, and the read path fails **open to compile-time defaults silently** — the admin-configured MIME denylist and size limits (the whole security point of this epic) never take effect in production. The dev/CI docker setup masks it via a dev-only `ALTER DEFAULT PRIVILEGES`, and the guarding `MigrationsGrantTest` was never extended to 000023, so CI stayed green.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | HIGH | `server/priv/migrations/000023_media_config.up.sql` | Missing `GRANT ... TO nebu_app` → in production (dual-role) `nebu_app` cannot read/write `media_config`; `get/0` silently fails open to defaults, `upsert` always errors. Security-relevant media policy never applies in prod. | Add explicit GRANT; extend `MigrationsGrantTest`. |
| F-2 | MEDIUM | `config.ex:275-286` + Story 7 (forward) | SSRF check on `webhook_url` runs at store-time only; the actual fetch (Story 7) re-resolves the host → DNS-rebinding / redirect SSRF at use-time. Storage-time check gives false assurance. | Story 7 sender must re-check with IP-pinning (`SSRF.checked_target/1`) at send time + no unvalidated redirects. |
| F-3 | LOW | `000023_media_config.up.sql:28-41` | `media_config_update_mutable` omits an explicit `WITH CHECK`, deviating from the `server_config` precedent. Functionally safe (PG uses `USING` as implicit `WITH CHECK`), but fragile/inconsistent; INSERT policy `WITH CHECK (true)` means the 10-key allowlist (AC1) is DB-enforced only on UPDATE. | Add explicit `WITH CHECK (key IN (...))` mirroring `config_update_mutable`. |
| F-INFO-A | INFO | `config.ex:167` | `upsert/3` performs no authorization on the `actor` string; audit attribution integrity is entirely the caller's responsibility. | Document trust boundary so Story 9b gates admin authz + passes a server-verified actor, never client input. |
| F-INFO-B | INFO | `config.ex:359-376` (accepted m3) | Config write persists even if the audit write fails (only `Logger.error`) — a log-evasion/anti-forensics surface + strict AC6 violation. | Confirm acceptance stands; consider Compliance-side alerting on `media_config_updated` audit-write failures. |
| F-INFO-C | INFO | `config.ex:331-343` (accepted m2) | Read-old→write→audit TOCTOU: no privilege gain, both concurrent writes are audited (only `old_value` metadata can be momentarily inaccurate); last-writer-wins is not a race-specific exploit. | No action; documented as accepted. |
| F-INFO-D | INFO | `config_supervisor.ex:73` (accepted m1) | `max_restarts: 1000/5s` neutralizes crash-loop detection for this child, but `init/1` is crash-resistant and a `:pg` storm needs cluster membership (Erlang cookie) — no DoS amplification. | No action; documented as accepted. |
| F-INFO-E | INFO | `config.ex:315-329` + Story 9c (forward) | `mime_denylist` token validation permits Unicode/exotic-whitespace tokens (only ASCII space/tab/CR/LF blocked) and is case-preserving. A malformed token weakens the denylist (fail-open, non-match) rather than escalating. | Story 9c must match MIME types case-insensitively + normalize/trim; consider NFC + a token-count cap. |

---

## Detail

### F-1 — HIGH — `media_config` has no `GRANT` to `nebu_app`; production read path fails open to defaults

**BLOCKS the commit.**

`server/priv/migrations/000023_media_config.up.sql` creates the table, enables RLS, and defines three policies — but contains **zero `GRANT` statements** (`grep -c GRANT` → 0).

The `MigrationsGrantTest` moduledoc states the deployment invariant plainly:

> Post-squash migrations (000002+) that create new tables must individually GRANT DML access to nebu_app, because **in production (UpCloud managed PostgreSQL) no ALTER DEFAULT PRIVILEGES compensates** (unlike the dev docker-compose setup).

Every other post-000001 table-creating migration honors this — 000006, 000008, 000009, 000010, 000011, 000012, and the sibling 000022 (`GRANT SELECT, INSERT, UPDATE, DELETE ON media_state_transitions TO nebu_app;`). 000023 does not.

**Production deployment model (dual-role):** `docker-compose.yml` sets `NEBU_DB_URL_MIGRATE` (nebu_migrate, `BYPASSRLS`, table owner) separate from `NEBU_DB_URL` (nebu_app, `NOBYPASSRLS`, runtime). Migrations run as `nebu_migrate`, so `media_config` is **owned by nebu_migrate**. In production there is no `ALTER DEFAULT PRIVILEGES FOR ROLE nebu_migrate` (that statement lives only in the dev-only `dev/postgres/init/01-roles.sql`, mounted via docker-entrypoint-initdb.d). Therefore `nebu_app` receives **no privilege whatsoever** on `media_config`.

**Consequence — silent fail-open:**
- `get/0` → `default_loader/0` → `SELECT key, value FROM media_config` → `permission denied for table media_config` → the `{:error, reason}` branch (`config.ex:497-499`) logs a warning and returns `%{}` → `build_catalog(%{})` → **every key resolves to its compile-time default**. The GenServer's `init/1 → do_refresh` behaves identically, so the ETS cache is permanently populated with defaults. No crash (`safe_load/0` also rescues), so the app looks healthy.
- `upsert/3` → `default_writer/3` → `INSERT ... ON CONFLICT` → `permission denied` → `{:error, _}`. Every admin write fails.

Net: in production, an admin who tightens `mime_denylist` (to block dangerous upload types — the explicit purpose of stories 9a/9c) or lowers `max_upload_size_bytes` sees the write fail, and the read path serves the permissive built-in defaults regardless. This is a **security control that silently does not apply in the real production topology** — exactly the false-comfort failure mode my creed treats as worse than ten false positives. The security *impact* is fully realized once Story 9c wires denylist enforcement; the *defect* ships now and is invisible outside logs.

**Why nothing caught it:**
- `config_test.exs` runs entirely on the `:media_config_loader`/`:media_config_writer`/`:media_config_source` seams (never a real `Nebu.Repo`), and its one conditional integration branch is `if Process.whereis(Nebu.Repo)` — which, when it does run, runs against the dev/CI docker DB where the dev-only `ALTER DEFAULT PRIVILEGES` grants access. So even the integration path passes.
- `MigrationsGrantTest` is a hand-maintained enumeration ending at 000022. It has no generic "every table-creating migration has a matching GRANT" assertion, so adding 000023 without a GRANT does not fail any test.

**Remediation:**
1. Append to `000023_media_config.up.sql` (no sequence grant needed — `key` is a TEXT PK, no SERIAL):
   ```sql
   GRANT SELECT, INSERT, UPDATE, DELETE ON media_config TO nebu_app;
   ```
2. Extend `server/test/nebu/matrix/migrations_grant_test.exs` with a 000023 describe-block (create-table pre-check + DML-grant assertion + a "no SERIAL columns" guard), and add `000023_media_config.down.sql` to the AC4 down-migration no-grant list.
3. (Systemic) Consider replacing the hand-maintained enumeration with a generic scan: for every `*.up.sql` after 000001 that matches `CREATE TABLE`, assert a matching `GRANT ... TO nebu_app`. This finding is the second media-epic migration in a row where the grant convention is easy to forget — a generic guard would close the class.

---

### F-2 — MEDIUM — `webhook_url` SSRF is validated at store-time, but the sink re-resolves at use-time

AC4 is satisfied for THIS story: `validate_value("webhook_url", value)` requires an `https` scheme AND calls `Nebu.Media.SSRF.check/1` (reused, not reimplemented) before any DB write, and there is no alternate write path (`upsert/3` is the sole entry; `default_writer/3` is private). `nil` is accepted (disabled). Non-string, non-https, and SSRF-blocked values are all rejected with `{:error, :invalid_webhook_url}` / the SSRF error. Confirmed correct.

The gap is temporal and forward-looking. `SSRF.check/1` is the **legacy, non-pinning** entry point — its own moduledoc says so: it closes the multi-record rebinding case but explicitly does NOT close the time-of-check/time-of-use gap; only `checked_target/1` (IP-pinning) does. For `webhook_url`, the check runs at **admin-config time**, potentially long before Story 7's webhook sender ever fires the request, and that sender will **re-resolve the hostname** at send time. An attacker who controls DNS for the configured hostname can therefore return a public IP at config time (passing validation) and rebind to `127.0.0.1` / `169.254.169.254` / an RFC1918 address at fire time. The `https` requirement makes it worse for pinning, not better: per the SSRF module's own https caveat, even `checked_target/1` cannot pin the IP for https without breaking SNI/cert validation, so https re-resolves regardless.

Threat model note: `webhook_url` is admin-set, so this is not unauthenticated. But (a) the SSRF sink is real server-side request forgery against internal infra/cloud-metadata, and (b) the stored, "already validated" URL gives Story 7 false assurance that it can skip its own check. That false assurance is the trap worth surfacing now.

**Remediation (carry-forward to Story 7, not fixable within 9a):**
- Story 7's webhook sender MUST perform its own SSRF validation with IP pinning (`SSRF.checked_target/1`) immediately before connecting, and MUST NOT follow redirects to unvalidated targets (re-validate every redirect hop, or disable redirects).
- Document in `config.ex`'s `webhook_url` validation that the storage-time SSRF check is necessary-but-not-sufficient and does not substitute for a use-time check.

---

### F-3 — LOW — RLS UPDATE policy omits explicit `WITH CHECK`; allowlist is DB-enforced only on UPDATE

`media_config_update_mutable` is `FOR UPDATE USING (key IN (...allowlist...))` with no `WITH CHECK`. The `server_config` precedent (`config_update_mutable`) spells out **both** `USING` and `WITH CHECK` with the allowlist.

I traced the "rename a row out of the allowlist to escape the gate" attack: it is **blocked**, because PostgreSQL uses the `USING` expression as the implicit `WITH CHECK` when the latter is omitted — so a post-update row whose `key` is not in the allowlist is rejected. So this is not an exploitable gap today. But relying on the implicit fallback is fragile and inconsistent with the codebase's own established pattern, and it is exactly the kind of subtlety that a future reader (or a policy edit by a later story) can get wrong.

Separately, the INSERT policy is `WITH CHECK (true)` (matching `server_config`), so the 10-key allowlist claimed by AC1 is DB-enforced **only on UPDATE**; a fresh INSERT of an arbitrary key is unrestricted at the DB layer. The app layer (`validate_known_key/1`) is the real key allowlist. This is defense-in-depth only and matches accepted precedent — noted so the "allowlist" is understood as app-enforced, not fully DB-enforced.

**Remediation:** Add `WITH CHECK (key IN (...same allowlist...))` to `media_config_update_mutable` to match `server_config` and make the post-update constraint explicit.

---

### F-INFO-A — `upsert/3` actor is fully trusted; document the boundary for 9b/9c

`upsert(key, value, actor)` does no authorization on `actor` — it writes whatever string it is handed straight into the `media_config_updated` audit metadata. This is architecturally correct for a data module (ADR-020; authz belongs at the `Nebu.Web`/`Nebu.Admin.Auth` plug layer). But the moduledoc only says "Story 9b passes the real admin's identity." It should explicitly state the two obligations on every caller: (1) enforce admin authorization BEFORE calling `upsert`, and (2) pass a server-verified actor identity, never a client-supplied string. Without that, a future caller could let a lower-privilege or unauthenticated request both mutate media policy and forge the audit actor. Hand-off to 9b/9c.

### F-INFO-B — audit-after-write is a log-evasion surface (accepted m3)

Per accepted m3, a successful config write is NOT rolled back if the subsequent `AuditWriter.log/6` fails; `upsert` still returns `:ok` after a `Logger.error`. Security framing the non-security review would not have scored: this is an anti-forensics surface — an actor who can reliably induce an audit-write failure (e.g. exhaust the audit path) mutates policy without a persistent audit row, and it is a strict AC6 violation ("every successful upsert writes an audit entry"). Exploitation is hard (requires causing AuditWriter failure) and it matches the codebase's existing audit-bridge call sites. Acceptance is reasonable; I recommend Compliance-side alerting on `media_config_updated` audit-write failures so the log line is not the only signal. No block.

### F-INFO-C — TOCTOU on concurrent writes has no security escalation (accepted m2)

Traced: two concurrent same-key `upsert`s each read the same `old_value`, both write, both emit an audit entry — no write escapes the audit log, no privilege is gained. The only artifact is a momentarily inaccurate `old_value` in one entry's metadata. "Last writer wins" is not a race-specific exploit and does not let an attacker's malicious value durably beat a legitimate concurrent correction beyond ordinary write ordering (which requires write access = admin anyway). Confirms m2 has no security dimension warranting escalation. No block.

### F-INFO-D — `max_restarts: 1000/5s` is not a DoS amplifier (accepted m1)

Traced: `init/1` (`ensure_pg`, `:pg.join`, `ensure_table`, `do_refresh` via the rescued `safe_load/0`, `schedule_ttl_tick`) is crash-resistant — there is no easily attacker-triggerable path that makes it crash-loop. A `:pg` broadcast storm would require joining the Erlang distribution cluster (shared cookie = prior full compromise), not a new surface from this story. The generous restart budget delays crash-loop detection by up to 5s and would burn bounded DB reads, but does not create an unbounded/amplified DoS. Confirms m1 has no additional security dimension. No block.

### F-INFO-E — `mime_denylist` validation fail-open edge cases (hand-off to 9c)

`valid_mime_token?/1` blocks only ASCII space/tab/CR/LF and requires an ASCII `/`; it permits other Unicode whitespace (NBSP, zero-width, `\v`, `\f`) inside a token and is case-preserving. A malformed token does not escalate — it simply fails to match any real MIME type, weakening the denylist (fail-open: an intended-blocked type slips through). Since the admin sets this value, impact is low, but Story 9c's enforcement MUST match MIME types case-insensitively (RFC 2045 types are case-insensitive) and should normalize/trim tokens; consider an NFC pass and a token-count cap to bound enforcement cost. Empty string (disabled), leading/trailing/embedded empty tokens are all handled correctly (rejected / accepted as designed).

---

## Summary

- **CRITICAL: 0**
- **HIGH: 1** (F-1) — blocks commit
- **MEDIUM: 1** (F-2) — carry-forward requirement on Story 7
- **LOW: 1** (F-3)
- **INFO: 5** (F-INFO-A..E)

**Verdict: BLOCKED** on F-1. The module code is sound and AC4's SSRF reuse is correctly wired; the blocker is a one-line migration omission with an outsized, silent, production-only fail-open consequence. Fix F-1 (add the GRANT + extend `MigrationsGrantTest`) and re-run; F-2 and F-INFO-A must be recorded as explicit hand-offs to Stories 7 / 9b so they are not lost.

---

## Re-verification — 2026-07-13 (Cycle 2, lightweight)

Re-reviewed the staged diff after the coordinator's disposition: fix F-1 now, hand F-2 to Story 7, accept F-3.

**F-1 — CLOSED.** Verified independently:
- `000023_media_config.up.sql` now ends with `GRANT SELECT, INSERT, UPDATE, DELETE ON media_config TO nebu_app;` — syntactically correct, correct privileges, correct role, correct table, in the `.up` (not `.down`), with an accurate explanatory comment. The `.down.sql` remains `DROP TABLE media_config;` (no GRANT — correct).
- The new `MigrationsGrantTest` block is not a rubber-stamp. The GRANT assertion `~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+media_config\s+TO\s+nebu_app/i` requires all four privileges in order on the right table for the right role — a missing or malformed GRANT fails it. Helpers are genuine: `read_migration!` reads the real file (raises if absent), `contains_create_table?` and `has_serial_columns?` (with a `SERIALIZABLE` negative-lookahead) do real regex matches; the no-SERIAL guard correctly passes for this TEXT-PK/BIGINT table. `000023_media_config.down.sql` was added to the `@down_migrations` no-GRANT loop, which uses the genuine `has_any_grant_to_nebu_app?` matcher.
- **No new issue introduced.** The GRANT does not over-privilege: it is byte-identical in shape to every sibling table-creating migration (000006/000008/000009/000010/000022, and 000001's `ON ALL TABLES`). Granting DELETE unconditionally is the established convention — `server_config`, the table this one mirrors, has exactly 3 RLS policies (SELECT read-all, INSERT insert-only, UPDATE mutable-allowlist) and **no DELETE policy**, yet 000001 grants it DELETE all the same. RLS, not the GRANT, is the real gate. media_config's 3-policy shape is identical.
- **Coordinator's empirical check is internally consistent.** ACL `nebu_app=arwd/nebu_migrate` decodes to a=INSERT, r=SELECT, w=UPDATE, d=DELETE — exactly the four privileges granted, granted by the table owner `nebu_migrate`. Live INSERT/UPDATE/SELECT succeeding while DELETE affects 0 rows is precisely what a table with DELETE *privilege* but no DELETE *RLS policy* under FORCE RLS produces — a policy-shape artifact, not a grant gap, matching the `server_config` design. Nothing in the description contradicts the actual file.

**F-2 / F-3 — Dev Agent Record accuracy confirmed.** The story's "Review Cycle 2" section describes F-1's fix, F-2's hand-off to Story 7 (send-time IP-pinning re-check / no unvalidated redirects), and F-3's acceptance (implicit `WITH CHECK = USING` fallback) faithfully, with no quiet scope change. The added process flag (every subsequent epic story adding a table must carry both a `GRANT` and a `MigrationsGrantTest` block) is well-placed and matches my standing recurring-pattern concern.

### Re-verification verdict: CLEAN / APPROVED

F-1 is genuinely closed, the regression guard is real, and nothing new is wrong. F-2 (Story 7) and F-INFO-A (Story 9b) remain the recorded forward hand-offs; F-3 remains an accepted low-severity inconsistency.
