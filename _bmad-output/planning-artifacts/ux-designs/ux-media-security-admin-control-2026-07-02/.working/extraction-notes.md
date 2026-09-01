# Extraction Notes — cross-source synthesis (2026-07-02)

Four parallel readers over: ux-design-specification.md, prd.md, the epic,
and the real `server/lib/nebu/admin/**` + `e2e/**`. Condensed synthesis;
full verbatim lives in the source docs. Spines distilled from this.

## Real stack (authoritative — supersedes stale "Go Templates" claim)
- Phoenix **LiveView + dead-controller HEEx**, Tailwind + DaisyUI theme **`nebu`**.
- Tokens: `server/assets/tailwind.config.js:11-64`. `data-theme="nebu"`, single dark theme.
- Layout `server/lib/nebu/admin/layouts.ex`: topbar `h-12 bg-base-300`, sidebar
  `nav.w-60 bg-base-200`, `main#main-content.flex-1.overflow-auto.p-6`, skip-link,
  `role=banner/main`, nav via `nav_item/1` + `@active_nav` + `aria-current` + `data-navkey`.
- CSP strict `script-src 'self'`, NO `unsafe-inline`. Confirmations today =
  `window.confirm()` via `data-confirm` in `app.js`. New `/admin/media` LiveView
  → use phx-click LiveView modals (CSP-safe), greenfield.
- Today MISSING (all greenfield for this epic): modal/dialog component, toast,
  pagination UI (keyset cursor exists in `admin/db.ex` but unsurfaced).
- Table drift: plain `table w-full` (users/rooms) vs `table table-zebra` in
  `overflow-x-auto` (config/compliance/audit). `<th scope>` present on some,
  MISSING on config/compliance/audit → new media table must set scope.
- E2E: playwright-bdd, base `http://localhost:8008`, `workers:1` serial.
  Selectors: getByRole primary + `data-role`/`data-page`/`data-section`/`data-status`
  hooks baked into templates AS acceptance guards → MUST stay stable, additive only.

## Design tokens (Obsidian / `nebu`) — inherited core
- primary `#f97316` / hover `#ea580c` / primary-content `#1c1917` / subtle `#431407`
- base-100 `#111827` (page) · base-200 `#1f2937` (surface/sidebar/cards) · base-300 `#374151` (hover/border)
- base-content `#f9fafb` · text-secondary `#9ca3af`
- success `#22c55e` · warning `#f59e0b` · error `#ef4444` · info/neutral `#6b7280`
- status-warn-bg: adopt prototype `#451a03` (spec `#431407` collides w/ primary-subtle) [D3]
- Fonts: Inter (sans, self-hosted WOFF2), JetBrains Mono (mono, IDs/hashes). No CDN.
- Type scale custom tokens: text-display(2.25/700) text-heading(1.5/600) text-body text-caption text-mono(.875)
- Spacing 4px base, 8px steps. Radii inline: 6px (btn/input/small card), 8px (cards/alerts), 10px (badges/pills). No shadow scale (elevation via bg-layer stack + 1px borders + 3px accent borders).

## Media state machine (epic — drives every badge) [D2]
reserved · quarantined · scanning · released · infected · admin_blocked · deleted · hard_deleted · scan_failed
Badge colors (Story 5a): processing(reserved/quarantined/scanning)=amber · released=teal ·
infected=red · admin_blocked=coral · terminal(deleted/hard_deleted)=gray · scan_failed=amber(nav).
Download gate: released→200; reserved/quarantined/scanning/admin_blocked→451; infected/deleted/hard_deleted→404.
media_files record NEVER deleted; hard_delete nulls storage_key+uploader_id, keeps file_hash+timestamps.

## Screens introduced by the epic
- S5  `/admin/media` LiveView table: badge, filename, uploader MXID, MIME, size, uploaded_at, scanned_at, ClamAV-sig. Filters(state multi, MIME-prefix, uploader, date-range) in URL. Cursor pagination 50/pg. PubSub row-level updates + nav attention badges (quarantined/scan_failed/infected).
- S6  Per-row actions + `/admin/media/:id` detail (metadata, full audit trail from media_state_transitions, ClamAV sig, storage bytes). Actions state-gated: Block(released→admin_blocked, no dialog, idempotent), Unblock(admin_blocked→released, no dialog), Delete(any→deleted, CONFIRM modal), Rescan(quarantined/scan_failed), Manual Hard-Delete(IRREVERSIBLE, confirm), Override(infected→released, role `media_admin_override`, mandatory reason, escalated warning: „Diese Datei wurde als Malware erkannt. Freigabe erfolgt auf eigene Verantwortung.").
- S7  No new screen: nav attention badges (infected=red, scan_failed=amber) + optional webhook. LiveView subscribes to {:media_infected,_}/{:media_scan_failed,_}.
- S9  `/admin/media/settings` form (mirrors `/admin/config`, ADR-022, env prefill, explicit save, server-side bounds validation). Fields: max_upload_size_bytes, max_file_size_bytes(hint „oberhalb ungescannt"), max_pending_per_user(20), max_stall_ms(20000), deleted_days/infected_days/orphaned_hours, webhook_url(HTTPS+SSRF block), mime_denylist(additive to ClamAV), released_delete_after_days(ESCALATED warning nil→value). Each change → audit `media_config_updated {key,old,new}`.
- S10 Scan Health dashboard (`/admin/media/health` or section on /admin/media). Metrics from media_scan_stats rollup: throughput/h, avg scan duration, backlog depth, error rate. ClamAV up/down + „down seit", signature age. media_alerts (severity warning|critical, message, media_id?, resolved_at?) unresolved-at-top, auto-resolve. Kill-switch fail_open(default)/fail_closed → audit.
- S11 Object storage config (section on /admin/media/settings). Fields endpoint/bucket/region/use_ssl/access_key/secret_key/s3_key_prefix_template/archive_bucket. Secrets = field-encrypted, masked. "Test Connection" (head_bucket) BEFORE save. Warning on endpoint/bucket change while media exists (count). Env prefill. Audit `media_storage_config_updated` WITHOUT secret values.

## PRD hard constraints (bind every screen)
WCAG 2.1 AA (NFR-A1) · full keyboard (A2) · screen-reader/semantic+ARIA (A3) ·
all admin actions audited (FR35) append-only Ed25519 (NFR-S3) · four-eyes+justification+24h (FR30-32) ·
roles instance_admin/compliance_officer via OIDC (FR4), + epic adds `media_admin_override` ·
URL-addressable state (FR50/NFR-O4) · DE+EN from OIDC claim/profile (NFR-L1) ·
configurable retention default precedent 7yr (NFR-C2) · TLS1.2+/mTLS opt for storage (NFR-S1).
Persona: Kai (DevOps, no-CLI, at-a-glance health), Dr. Petra (compliance_officer). 2-3 admins/instance.
GAP [D4]: PRD has no malware/quarantine/media-policy/S3 domain; NFR-C3 Postgres-only tension w/ S3.

## Do's/Don'ts (Obsidian, inherited)
Status = color+icon+text ALWAYS (never color alone). One primary btn/view; never two adjacent.
Errors 3-part: was/warum/was-jetzt. Focus ring `focus-visible:ring-2 ring-primary ring-offset-2 ring-offset-base`.
Required = `*` after label. Touch ≥44px, nav 48px. Semantic HTML. No tech names in UI text.
No nested modals; no forms in modals (except type-to-confirm tier); no infinite scroll; no auto-save on config.
