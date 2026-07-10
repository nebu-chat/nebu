## Security Review — admin-logs-monitoring-view

**Epic:** enhanced-logging
**Diff scope:** staged diff (`git diff --staged`) — new Admin LiveView `/admin/logs` (Trace Map + live request-stream + slide-in detail panel), reusable `trace_map_bubble.ex` + `detail_panel.ex` components, `app.js` client-side filter/observer/clipboard logic, plus two bundled cross-story fixes (`Handler.source_from_meta/1` via `:mfa`, `RequestLogger` `Logger.metadata(method:/status:/duration_ms:)`).
**Reviewer:** Kassandra
**Date:** 2026-07-05
**Classification:** CLEAN (no CRITICAL / no HIGH) — 1 MEDIUM + 2 LOW advisory

### Scope note

This story renders `operational_logs` entries that are redacted UPSTREAM by the already-reviewed `operational-log-store` + `matrix-payload-debug-logging` pipelines (both APPROVED, 2026-07-05). Per the review brief, the upstream redaction logic itself was NOT re-reviewed from scratch; the focus is whether THIS UI introduces a NEW leak path or bypasses/weakens the upstream controls, plus a full standard pass (OWASP/ASVS/CWE/STRIDE + Nebu invariants).

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `logs_live.ex` `handle_info/2` → `ingest_entry/2` (l.136–226) vs `level_off?/2` (l.615–617) | Live PubSub entries are ingested/rendered for ALL levels regardless of the collection policy. The Trace Map shows debug/info as "⚫ off" when `log_collect_*` is false, but off-level entries still stream live into `@level_counts`, request rows, the detail panel, and the copy-thread text. Combined with the upstream `PayloadRedactor` coverage gap (operational-log-store F-4: `search_term`/`status_msg`/account_data not redacted on the read path), under-redacted user-entered text can appear LIVE in the admin view even when the operator has disabled that tier. This is exactly the exposure the operational-log-store review's watch-flag #5 assigned to this story to "account for"; it was not accounted for. | In `handle_info/2`/`ingest_entry/2`, drop entries whose level is not currently collected per `@policy` (mirror `should_persist?`/`level_off?`) BEFORE ingest; OR have the broadcast/subscription honor policy. Make the live view consistent with the "off" signal. |
| F-2 | LOW | `logs_live.ex` `mount/3` (l.75) | `@policy` is read once at mount and never refreshed. If the retention/collection policy changes (sibling retention-settings story) while the view is open, the "off" bubble state — and the F-1 drop-filter once added — operate on stale policy. | Subscribe to a policy-change PubSub/`:pg` signal (as OidcConfig does) or re-read policy on a timer; recompute off-state + the F-1 filter live. |
| F-3 | LOW/INFO | `logs_live.ex` ingest fan-out | Every `operational_logs` broadcast is delivered to every open admin LogsLive socket and processed per-entry. Under a log storm this is per-admin-socket CPU. Bounded (admin-only audience; `@max_rows=200` caps memory; fixed-key count maps) so not exploitable, noted for completeness. | None required; consider a coalescing/throttle if many concurrent admin viewers become common. |

### Detail

**F-1 — live view ignores collection policy on the broadcast path** [MEDIUM]
`safe_broadcast/1` (upstream) emits EVERY log event to the `"operational_logs"` topic regardless of `should_persist?`. `LogsLive.handle_info/2` matches every entry and `ingest_entry/2` applies no level/policy gate — it increments counts, and (for entries with a `request_id`) builds a request row whose detail panel + copy-thread include the entry's `message`. `level_off?/2` is consulted ONLY to paint the bubble "⚫ off" (AC2). Net effect: with `log_collect_debug=false` (or `log_collect_info=false`), those entries are NOT persisted (so they are absent from `initial_entries/0`'s DB seed) yet still stream in LIVE and are shown — directly contradicting the "not currently collected" signal the same page renders. Because the upstream `PayloadRedactor` does not redact `search_term`/`status_msg`/account_data on the read path (operational-log-store F-4, MEDIUM), the live debug HTTP payload line can carry under-redacted user text into the admin UI on a tier the operator deliberately disabled. Admin-only audience + upstream-redactor dependency keep this MEDIUM (defense-in-depth / config-integrity, not an unauthenticated leak), but it is the specific obligation upstream handed to this story. Fix: filter off-level entries in `ingest_entry/2`.

**F-2 — stale policy snapshot** [LOW] Advisory; compounds F-1's correctness after a live policy change.

**F-3 — per-socket broadcast fan-out** [LOW/INFO] Bounded, admin-only; no action required.

### Cleared checks (verified CLEAN)

1. **XSS — message/metadata rendering (AC8).** `detail_panel.ex` renders `{entry[:message]}` and `{inspect(entry[:metadata])}` via HEEx `{...}` interpolation (auto-escaped). `logs_live.ex` renders method/path/status/duration/timestamp/request_id all via `{...}`. NO `raw/1`, `Phoenix.HTML.raw/1`, or `{:safe, ...}` anywhere in the new `.ex` files (grep-confirmed). Even a hypothetically-bypassed upstream marker containing HTML would render as inert escaped text.
2. **Metadata expansion (AC8).** Rendered as `inspect/1` inside escaped `{...}` — no raw HTML string construction from metadata keys/values.
3. **Copy-to-clipboard (AC8).** `app.js` `nebu:copy-thread` reads `button.dataset.copyText` (a HEEx-escaped `data-copy-text` attribute) and passes it to `navigator.clipboard.writeText()` — plain text, no DOM/`innerHTML`. No DOM-XSS.
4. **New data-exposure surface.** `Nebu.Web.LogStore.get_logs/1` returns only the stored `operational_logs` columns (id, inserted_at, level, source, route_template, request_id, message, metadata, war_room_id). No separate raw/unredacted field exists alongside the redacted one; the LiveView renders only the already-guaranteed-redacted `message`/`metadata` fields (endpoint uses the normalized `route_template`, not the raw path). No debug/dev bypass or query-param/URL that dumps raw rows. (Aside from F-1's live-path gap.)
5. **Client-side JS filtering (AC3/AC5).** `applyTraceMapFilters()` reads `row.dataset.*` and toggles only `row.style.display`/chip `style.display`; `setBubbleActiveClasses` toggles classList; no `innerHTML`/`eval`/`new Function`/`insertAdjacentHTML` (grep-confirmed — the only two `innerHTML` hits in app.js are comments affirming textContent-only usage). CSP-compliant (external `app.js`, `script-src 'self'`, no inline).
6. **MutationObservers (`wireTraceMapRowObserver`/`wireDetailPanelFocus`/`wireLiveUpdatesPause`).** Re-run the idempotent `applyTraceMapFilters()` (style toggling) or call `.focus()` / `.click()` on server-rendered elements. None read node content and re-inject it. No unsafe reflow.
7. **Access control / RLS.** `/logs` is registered inside `live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin}` alongside DashboardLive/AuditLogLive. Per the established pattern, the `on_mount` gate runs on BOTH the static HTTP render and the stateful socket connect — the PubSub `subscribe` in `mount/3` runs only after the gate passes, so operational-log-store watch-flag #5(a) "gate subscription behind admin auth" is SATISFIED. Read-only view; no mutations except session-local pause/resume/open/close-detail. No IDOR (single-tenant, all subscribers are admins receiving the same global operational stream).
8. **`Handler.source_from_meta/1` fix (`:mfa`).** Derives the calling module from `:mfa` `{module, function, arity}`, captured by the Logger macro at the compile-time call site. Never user-influenced (an attacker cannot cause arbitrary module/function atoms to appear in `:mfa`). Matched against `RequestLogger`/`QueryTelemetry`, else `Atom.to_string(module)` → bucketed to "http"/"ecto"/"other" in the UI. No atom-table growth, no leak.
9. **`RequestLogger` metadata fix.** `method` = `conn.method` (constrained to RFC-7230 token chars by cowboy; rendered escaped anyway), `status` = integer, `duration_ms` = computed integer — all non-sensitive scalars, and all rendered through escaped `{...}` / integer guards. No sensitive data path.
10. **SQL injection.** `get_logs/1` (not itself in this diff) uses parameterized `$n` values with a hardcoded column allowlist; the LiveView calls it with `%{}`. `meta_get/2`'s `String.to_atom("method"|"status"|"duration_ms")` uses hardcoded keys only — no user-driven atom creation.
11. **DoS / memory.** `@max_rows=200` eviction by arrival order; `nil` request_id handled (no crash, counts-only); fixed-key count maps. Bounded.
12. **Secrets/credentials.** No secret handling in the UI; no token/credential logged or rendered. `data-copy-text` and detail panel expose only the already-redacted message/metadata (subject to F-1's live-path gap).

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 1 (F-1 — advisory; address before enabling any debug/info-off deployment)
LOW: 2 (F-2 stale policy, F-3 fan-out)

**Verdict:** APPROVED (no blocking findings). F-1 is a MEDIUM advisory that directly discharges the operational-log-store watch-flag #5 handed to this story — recommend fixing it (drop off-level entries on the live path) in this story or a fast-follow before any deployment runs with debug/info collection disabled, and enumerate it alongside the upstream PayloadRedactor coverage fix. F-2/F-3 are hardening advisories.
