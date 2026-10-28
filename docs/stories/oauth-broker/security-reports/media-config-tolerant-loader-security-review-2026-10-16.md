# Security Review: oauth-broker / media-config-tolerant-loader (follow-up ej)

Reviewer: nebu-kassandra (read-only), 2026-10-16. Scope: staged diff, 14 files (config.ex per-row decode + damaged_keys/0, media_settings_controller changed_keys/3, template warning, docs, tests, e2e).

**Verdict: CLEAN / APPROVED.** CRITICAL 0, HIGH 0, MEDIUM 1 (pre-existing, carry-forward), LOW 1, INFO 6.

## Verified properties
- (a) Fail-open vs fail-closed: one damaged INTEGER row no longer resets every key to its default (before: `mime_denylist = ""`, denylist off). Only integer keys (`@nonneg_int_keys`: the two retention keys, `released_delete_after_days`, limits) can be marked damaged; `mime_denylist`, `scan_kill_switch`, `webhook_url` and unknown keys pass through (D2). Damaged `scan_kill_switch` fails CLOSED (`MediaScanWorker.handle_kill_switch/3` `other ->`). Damaged retention keys: `get/0` shows the default, strict `retention_days/0` returns `{:error, :invalid}` -> `MediaCleanupWorker` deletes nothing. Damaged `released_delete_after_days` -> nil -> worker disabled. `orphaned_hours` is not read from Config by its worker.
- (b) Logs/audit/HTML carry keys only, never values or exception text; the damaged set is a subset of compile-time known keys (no attacker-chosen key reaches HTML/logs); HEEx escapes; `default_loader` no longer decodes so the `inspect(e)` rescue is unreachable for a damaged row.
- (c) Audit: `old_value: :unknown` for damaged keys (sequential + retention tx); lock, in-tx audit, retry and direction guard unchanged; no new lengthening path.
- (d) Parsing: `\A[0-9]{1,18}\z` ASCII-only, `\z` anchored, 18 digits < 2^63, no DoS; strict path additionally bounds 0..3650 so nothing outside the range can delete.
- (e) CSRF / fresh sign-in gate on Save unchanged (`gate(conn, :marker, @page)` + `consume_reauth`).
- (f) e2e db.ts helpers test-only. (g) integration tests use `privileged_sql!`, snapshot + restore rows, async: false.
- Seams `:media_config_source` / `:media_config_loader` never set in lib/ or config/.

## Findings
| # | Sev | Where | Finding | Remediation |
|---|---|---|---|---|
| M-1 | MEDIUM (pre-existing) | `Config.do_refresh/0` `:error -> {build_catalog(%{}), previous}`; `get/0` without ETS | A failed whole-table read (DB blip, pool exhaustion, permission error) replaces a good cached catalog with the DEFAULTS for up to one TTL (60 s) per node: `mime_denylist` becomes `""` (upload denylist off). Only the damaged SET is kept. Documented as unchanged in the story; not attacker-triggerable. | Follow-up `ek`: keep the last-known-good catalog on `:error`; defaults only without a previous catalog; optional "unreadable" flag for the Admin warning. |
| L-1 | LOW | `changed_keys/3` (D6) + pre-filled default | With a damaged `deleted_days` / `infected_days`, ANY save of the page also writes the shown default (30 / 7) and ends the fail-safe pause of an irreversible cleanup with a window the admin never chose. Mitigated: admin only, fresh sign-in, alert text, audit row (old_value unknown). | Copy must say explicitly that saving resumes the cleanup with the value shown; optional follow-up: empty field for a damaged retention key. |
| INFO-1 | INFO | `decode_row(_key, v)` pass-through | garbage text in `mime_denylist` / `webhook_url` / `scan_kill_switch` is never flagged; kill switch fails closed, webhook re-checked (SSRF) before send, denylist garbage weakens only corrupted tokens. | optional: re-validate on read, keep stored denylist. |
| INFO-2 | INFO | `parse_retention_days/1` {1,6} -> {1,18} | leading-zero strings of 7-18 digits now accepted by the strict reader (`"0000000"` = 0 = delete at next run); writer never produces leading zeros. | pin with a test (code review M6). |
| INFO-3 | INFO | `do_refresh` `:error` | during a table outage the warning lists the previous damaged keys while every field shows defaults. | covered by M-1 remediation. |
| INFO-4 | INFO | `e2e/fixtures/db.ts` | shell quoting via JSON.stringify in double quotes; `psql -t -A` + trim maps `''` to "no row" on restore; restore bypasses audit/cache invalidation. Test-only. | optional: execFileSync argv. |
| INFO-5 | INFO | `parse_nonneg/1` 17-18 digit values | accepted for limit keys / `released_delete_after_days` (pre-existing: old String.to_integer had no bound); worker query raises -> nothing deleted. | none (code review M2 caps the writer). |
| INFO-6 | INFO | `damaged_keys/0` / `get/0` without ETS | full-table SELECT per call without a running holder; holder is supervised. | none. |
