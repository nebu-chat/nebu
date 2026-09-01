---
story_id: 10b-clamav-status-freshclam-age
title: "Scan Health & Alerts Dashboard: ClamAV Status + Freshclam Signature Age"
epic: media-security-admin-control
status: done
security_review: optional
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

The Scan Health & Alerts Dashboard (epic Story 10, "Fachliches Ziel: Aggregierte Metriken
über die Scan-Pipeline und eine Alert-Historie für operative Zustände im Admin-Dashboard")
is split S-sized across 10a–10e. Story 10a lays down the `media_scan_stats` hourly-rollup
metrics section; Story 10c layers alert history on top; Story 10d wires a fail-open/
fail-closed kill switch. This story, **10b**, is the piece in between: it surfaces whether
the ClamAV scanner itself is reachable right now, and how stale its virus-signature database
is — the two signals every other health/alert story in this split depends on (10c's
"ClamAV nicht erreichbar > 5 min → critical" trigger and 10d's fail-open/fail-closed
kill-switch decision both read this story's status, per the epic's dependency line
`Story 10b ... — 3, 10a` and 10c/10d's own `— 10b` dependencies).

**Load-bearing gap, flagged up front:** at the time this story was authored,
`docs/stories/media-security-admin-control/10a-scan-stats-rollup.md` does not yet exist in
this repository — only Story 3 (`3-clamav-genserver.md`) has landed as a written,
`ready-for-dev` story file. This story's epic text (lines 955–968) describes 10a's scope
("Metriken-Sektion auf `/admin/media` (oder eigene Route `/admin/media/health`), liest die
Rollup-Tabelle") but 10a's own **implementation choice** — LiveView vs. controller-rendered
page, exact route, exact module name — is therefore inferred here, not confirmed against a
written file. The epic's later Story 10e text (already-drafted, epic lines 1009–1040)
explicitly names `/admin/media/health` as the dashboard's real route and describes a
"Live-Diagnose starten" action on it, which only makes sense on a persistent-process
(LiveView) page — this, plus the fact that every other admin dashboard-style surface in this
epic and the already-shipped Enhanced-Logging epic (`Nebu.Admin.LogsLive`, `.TraceMap`,
`.WarRoom`, `Nebu.Admin.MediaLive` from Story 5a) is a Phoenix LiveView under the
`live_session :admin` block, is why this story assumes `/admin/media/health` will be a
LiveView. **This is an assumption the dev agent must verify against 10a's actual
implementation before or during this story's dev-story run** — if 10a ships as a
controller-rendered page instead, this story's "live update" AC (AC4 below) degrades to its
documented fallback (fresh-on-page-load), exactly as already established for the mixed
LiveView/controller admin UI in Story 5b (see `5b-live-updates-nav-badges.md`, "Second
design choice" — the nav badge's two-tier LiveView-vs-controller behavior is the precedent
this story follows).

## User Story

As an admin operator, I want to see at a glance on the media health dashboard whether the
ClamAV scanner is currently connected and how old its virus-signature database is, so that I
can notice and act on a scanning outage or a stale signature feed before it silently lets
unscanned or under-scanned files pile up.

## Acceptance Criteria

1. **AC1 — Connection status, sourced from Story 3's health-check.** The dashboard shows a
   connected/disconnected indicator for the ClamAV daemon, derived from
   `Nebu.Media.ClamAV.health_check/0` (Story 3, AC7/AC8) — not a new, independent TCP probe.
   Connected renders a positive state (e.g. green "Verbunden" badge); disconnected renders a
   clearly distinguishable negative state (e.g. red "Nicht erreichbar" badge) plus a
   **"down seit" (down-since) timestamp**.
2. **AC2 — `down_since` is tracked at the source, not guessed at the dashboard.** Because
   Story 3's `Nebu.Media.ClamAV` GenServer is the only process that actually observes the
   connect/disconnect transition (AC7's init probe, AC8's reconnect-on-next-use), this story
   extends that GenServer's health-check return shape to carry the timestamp of the last
   observed state change (e.g. `health_check/0` returning
   `%{healthy: boolean(), changed_at: DateTime.t()}` instead of a bare boolean) — a dashboard
   process that polls periodically and derives "down since" from its own first observation
   would reset on every LiveView remount/reconnect and undercount true outage duration. See
   "Technical Requirements" for the exact extension and its coordination note against Story 3.
3. **AC3 — Signature-database age, mechanism stated explicitly (flagged assumption).** The
   dashboard shows a human-readable age for ClamAV's virus-signature database (e.g. "Signaturen
   aktuell (vor 3h aktualisiert)" / "Signaturen veraltet (vor 52h aktualisiert)"). The epic text
   (line 976f.) names two candidate mechanisms — "`VERSION`-Kommando im INSTREAM-Protokoll oder
   Container-Healthcheck" — without picking one. This story picks the `VERSION` command
   because it is the only one that fits Nebu's actual deployment topology: `clamd` and Nebu run
   in **separate containers** communicating only over the TCP INSTREAM connection Story 3
   already owns (`docker-compose.yml`'s `clamav` service, added by Story 3's File List) — Nebu
   has no filesystem access into the ClamAV container to read a freshclam log or `.cvd`/`.cld`
   file timestamp directly. Sending `zVERSION\0` over the same connection Story 3 already
   manages returns a reply of the form `ClamAV <engine-version>/<db-version>/<build-date>`
   (e.g. `ClamAV 0.103.8/26707/Wed Jul 10 07:32:35 2024`); the trailing date is when that
   published signature database was built, which is the correct proxy for "how stale is what
   this clamd instance is actually scanning with" (a clamd that hasn't successfully run
   freshclam in days keeps reporting an old build date here, which is exactly the staleness
   signal this AC needs). **This is an assumption, not a confirmed fact about the running
   `clamav/clamav:stable` image** — the dev agent must verify the real `VERSION` reply format
   against the actual dev-stack container (added in Story 3) before relying on a specific
   parse, and adjust the parser (not the AC) if the observed format differs.
4. **AC4 — Warning threshold, default stated.** A configurable staleness threshold — default
   **48 hours** — governs when the signature age flips from a neutral/positive state to a
   visually distinct warning state (e.g. amber "Signaturen veraltet" badge/icon, not just a
   different number). 48h is chosen (within the epic's own suggested 24–48h range, epic
   Story-10-adjacent framing) because ClamAV's upstream signature database is typically
   rebuilt multiple times per day and freshclam's default check interval is on the order of
   hours — a healthy, connected freshclam sidecar should never approach 48h stale under normal
   operation, making that threshold a low-noise "something is actually wrong" signal rather
   than a routine blip. The threshold is a static app-config default for this story (matching
   Story 3's own precedent for `max_file_size_bytes`: "this story only needs the static
   app-config default, the admin-configurable override is out of scope here") — Story 9's
   `media_config` admin-settings UI is the natural future home for an operator-adjustable
   value, not this story.
5. **AC5 — Same dashboard page/section as 10a, not a separate screen.** Per the epic's
   framing (Story 10's shared "Fachliches Ziel", 10b's dependency on 10a "Dashboard-Oberfläche"),
   this status lives in the same `/admin/media/health` page 10a's metrics rollup section
   occupies — a second section on that page, not a new route. If 10a's actual route differs
   from `/admin/media/health` by the time this story is picked up, this story follows 10a's
   real route rather than the assumption stated in the Summary.
6. **AC6 — Update mechanism matches 10a's actual choice; LiveView poll assumed.** If
   `/admin/media/health` is a LiveView (this story's working assumption — see Summary), the
   ClamAV status/freshclam-age section updates **live**, on a periodic in-process poll tick —
   modeled directly on the already-shipped `Nebu.Admin.WarRoomIndicator` pattern
   (`server/lib/nebu/admin/war_room_indicator.ex`: `schedule/0` reschedules an unconditional
   `Process.send_after/3` tick, `status/0` does a fresh read, `assign_status/2` updates
   assigns) rather than a new PubSub broadcast wired into `Nebu.Media.ClamAV` — a periodic
   poll is the right fit here because, unlike `media_files` state transitions (which already
   have a natural "event" to broadcast on), ClamAV connectivity and signature age are
   *sampled* properties of an external daemon, not domain events Nebu itself decides to emit.
   If 10a's page turns out to be controller-rendered instead, this section falls back to a
   fresh-on-page-load read (no live ticking), exactly matching the two-tier precedent already
   established in `5b-live-updates-nav-badges.md`'s nav-badge AC.

## Acceptance Tests

Proposed location: `server/test/nebu/admin/clamav_status_indicator_test.exs` (new, unit-level,
for the shared helper module) plus `server/test/nebu/admin/media_health_live_test.exs` (new —
or, if 10a already created a health-page LiveView test module by the time this story is
picked up, extend that module rather than creating a second one for the same page/route).

1. **`test "connected state renders a positive ClamAV status badge"`** — `health_check/0`
   stubbed/faked to report `healthy: true`; asserts the dashboard renders the connected badge
   and no "down seit" timestamp is shown.
2. **`test "disconnected state renders a negative ClamAV status badge with a down-since timestamp"`**
   — `health_check/0` faked to report `healthy: false, changed_at: ~U[...]`; asserts the
   dashboard renders the disconnected badge and a human-readable "down seit" duration derived
   from `changed_at`.
3. **`test "fresh signature database shows no staleness warning"`** — `VERSION` reply build-date
   faked to `1 hour` old (well under the 48h default threshold); asserts no warning
   state/class is rendered, only the neutral "Signaturen aktuell" copy with the age.
4. **`test "stale signature database shows a staleness warning"`** — `VERSION` reply build-date
   faked to `72 hours` old (well over the 48h default threshold); asserts the warning
   state/class (amber badge/icon) is rendered along with the age.
5. **`test "signature age threshold boundary — exactly at the default threshold does not yet warn, one unit past it does"`**
   — table-driven: age = `48h - 1s` → neutral state; age = `48h + 1s` → warning state; pins
   the exact comparison operator (`>`, not `>=`, against the configured threshold) so a future
   change to the default doesn't silently flip boundary behavior unnoticed.
6. **`test "malformed or unparseable VERSION reply degrades to an unknown-age state, not a crash"`**
   — fake clamd (extending Story 3's `clamav_fake_server.exs` helper) replies with a
   `VERSION` string that doesn't match the expected `engine/db/date` shape; asserts the
   dashboard renders a clear "Alter unbekannt" state rather than raising or showing a bogus
   age — mirrors Story 3 AC6's "every failure mode is a tagged result, never a raised
   exception" discipline extended to this new query path.

## Technical Requirements

### Extending `Nebu.Media.ClamAV` (Story 3) — health-check shape + new `VERSION` query

This story depends on two additions to the GenServer Story 3 introduces
(`server/lib/nebu/media/clamav.ex`), coordinated with whoever implements/owns Story 3 at the
time this story is picked up (Story 3 may already be `done` by then, in which case this is a
small, scoped follow-up amendment to that module, not a redesign):

1. **`health_check/0` gains `changed_at`.** Story 3's AC7 only specifies that `health_check/0`
   "reports whether the last known connection attempt to clamd succeeded." This story needs
   the *timestamp* of that state's last transition too (AC2 above), so the GenServer's state
   (`%{address:, max_file_size_bytes:, socket:, healthy:}` per Story 3's Technical
   Requirements) gains a `changed_at :: DateTime.t()` field, set on `init/1` and updated every
   time `healthy` flips (on the reconnect-detected-drop path and on a successful
   reconnect/probe) — `health_check/0`'s return grows from a bare boolean to
   `%{healthy: boolean(), changed_at: DateTime.t()}`.
2. **New `signature_info/0` (or equivalent) sends `zVERSION\0`.** A new public function on
   `Nebu.Media.ClamAV`, following the same call shape as `scan_binary/1` (a `GenServer.call/3`
   with an explicit timeout, using the existing managed socket/reconnect-on-next-use
   machinery — no second TCP connection), sends `zVERSION\0` instead of the `zINSTREAM\0`
   command, reads the single-line reply, and parses out the trailing build-date segment.
   Returns `{:ok, %DateTime{}}` (the parsed build date) or `{:error, reason}` for every
   failure mode (connection error, timeout, unparseable reply) — same "never raise" discipline
   as `scan_binary/1` (Story 3 AC6). **Verify the actual `zVERSION\0` reply format against the
   real `clamav/clamav:stable` dev-stack container** (Story 3's File List adds this service to
   `docker-compose.yml`) before finalizing the parser — do not assume the example format in
   AC3 above is exact without checking a live container.
3. **New app-config key: `signature_max_age_hours`.** Added alongside Story 3's existing
   `config :nebu, Nebu.Media.ClamAV` keys (`address`, `max_file_size_bytes`):
   ```elixir
   config :nebu, Nebu.Media.ClamAV,
     address: {:tcp, "clamav", 3310},
     max_file_size_bytes: 100 * 1024 * 1024,
     signature_max_age_hours: 48
   ```

### Dashboard integration — shared indicator helper, mirroring `WarRoomIndicator`/`MediaAttentionBadge`

New `Nebu.Admin.ClamAVStatusIndicator` (`server/lib/nebu/admin/clamav_status_indicator.ex`),
following the exact shape of `Nebu.Admin.WarRoomIndicator` (poll-based) and
`Nebu.Admin.MediaAttentionBadge` (Story 5b's helper-module precedent for a small, stateless,
multi-call-site assign helper):

```elixir
Nebu.Admin.ClamAVStatusIndicator.status()
  # -> %{healthy: bool, changed_at: DateTime.t(), signature_age: {:ok, DateTime.t()} | {:error, term()}}
  # guarded the same way WarRoomIndicator.status/0 guards on Process.whereis(Nebu.Repo)/
  # the GenServer being started, so plain unit-test runs without the ClamAV client running
  # (config :nebu_http, start_clamav_client: false, per Story 3) degrade to a clear "unknown"
  # state rather than raising.
Nebu.Admin.ClamAVStatusIndicator.schedule()   # Process.send_after tick, mirrors WarRoomIndicator
Nebu.Admin.ClamAVStatusIndicator.assign_status(socket, status)
  # -> assigns :clamav_healthy, :clamav_down_since, :clamav_signature_age, :clamav_signature_stale?
```

The 10a-owned `/admin/media/health` LiveView (module name/path TBD by 10a's actual
implementation) calls `ClamAVStatusIndicator.status/0` + `assign_status/2` in its own
`mount/3`, schedules the poll tick, and handles the tick message in `handle_info/2` —
one-line wiring per call site, same integration cost as `WarRoomIndicator` imposes on every
other admin LiveView today.

### Threshold comparison

**Correct formula — second-level precision:**

`signature_stale? = DateTime.diff(DateTime.utc_now(), signature_built_at, :second) > signature_max_age_hours * 3600`
— strictly greater-than, per Acceptance Test 5's boundary pin.

**Do NOT use hour-truncated diff.** An earlier draft of this section stated
`DateTime.diff(DateTime.utc_now(), signature_built_at, :hour) > signature_max_age_hours`. That
formula is FLAWED and must not be implemented: `DateTime.diff/3` with the `:hour` unit truncates
towards zero, so both "48h - 1s" (172_799s → 47 whole hours) and "48h + 1s" (172_801s → 48 whole
hours) end up comparing as `47 > 48` and `48 > 48` — both `false`. The hour-truncated version
therefore never flips to the warning state at 48h+1s, silently failing Acceptance Test 5's
boundary pin (48h-1s → neutral, 48h+1s → warning; both the ATDD and pre-dev test-review passes
independently confirmed this arithmetic). The dev-story implementation MUST use the
second-level-precision formula above, not this hour-truncated one.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/media/clamav.ex` (Story 3) | UPDATE | `health_check/0` return shape gains `changed_at`; new `signature_info/0` (or equivalently named) sends `zVERSION\0`, parses build date, returns `{:ok, DateTime.t()} \| {:error, reason}`; new `signature_max_age_hours` config key. |
| `server/test/nebu/media/clamav_fake_server.exs` (Story 3) | UPDATE | Extend the fake `clamd` TCP helper to also accept/respond to `zVERSION\0` with a configurable (including malformed) reply, for this story's Acceptance Tests 5–6. |
| `server/lib/nebu/admin/clamav_status_indicator.ex` (new) | ADD | `Nebu.Admin.ClamAVStatusIndicator` — `status/0`, `schedule/0`, `assign_status/2`, threshold comparison, mirroring `WarRoomIndicator`. |
| `server/lib/nebu/admin/media_health_live.ex` (10a's module — exact path TBD by 10a's actual implementation) | UPDATE | Add the ClamAV status + signature-age section to the same page 10a's metrics rollup occupies; wire `ClamAVStatusIndicator` poll in `mount/3`/`handle_info/2`. |
| `server/test/nebu/admin/clamav_status_indicator_test.exs` (new) | ADD | Acceptance Tests 1–2, 5–6 (helper-level). |
| `server/test/nebu/admin/media_health_live_test.exs` (new, or extends 10a's test module) | ADD/UPDATE | Acceptance Tests 1–4 rendered end-to-end on the dashboard page. |
| `config/config.exs` (or equivalent, Story 3) | UPDATE | Add `signature_max_age_hours: 48` default alongside existing `Nebu.Media.ClamAV` config. |

## Dev Agent Guardrails

### Do Not Change

- Do not build a new, independent TCP health probe for the dashboard — `health_check/0` and
  the new `signature_info/0` both route through `Nebu.Media.ClamAV`'s existing single managed
  connection (Story 3). A second connection/poller talking to `clamd` directly would duplicate
  Story 3's reconnect-on-next-use logic and violate its "single named GenServer process
  serializing scan calls" guardrail (Story 3, "Do Not Change").
- Do not implement this as a PubSub broadcast from `Nebu.Media.ClamAV` unless 10a's actual
  page turns out to require it. The poll-tick pattern (`WarRoomIndicator`) is the stated
  default here specifically because ClamAV connectivity/signature-age are sampled external
  state, not a domain event Nebu already emits — do not add broadcast wiring to Story 3's
  GenServer speculatively.
- Do not invent a filesystem-based freshclam-log-read mechanism — Nebu and `clamd` run in
  separate containers (Story 3's `docker-compose.yml` addition); there is no shared filesystem
  to read a `.cvd`/log timestamp from. The `VERSION`-over-INSTREAM approach (AC3) is the only
  mechanism consistent with that topology.
- **Flag, do not silently resolve, the following assumptions during dev-story:**
  1. That `/admin/media/health` is a LiveView (this story's Summary states the reasoning; if
     10a shipped a controller-rendered page instead, fall back to the fresh-on-page-load tier
     per AC6, matching 5b's precedent — do not force a LiveView conversion of 10a's page as a
     side effect of this story).
  2. That `zVERSION\0`'s reply format matches the `engine/db/build-date` example in AC3 — must
     be confirmed against the real `clamav/clamav:stable` container before the parser ships.
  3. That 48h is the right default staleness threshold — stated and justified in AC4, but is a
     product/ops judgment call the epic itself left as an example range (24–48h), not a fixed
     number; confirm with Product/Winston if evidence from real freshclam update cadence in
     the target deployment suggests otherwise.
- Do not build Story 10c's `media_alerts` table/trigger or Story 10d's kill-switch config in
  this story — 10b only exposes the two status signals those later stories consume; it does
  not persist alert history or change upload-acceptance behavior.

## Dependencies

- **3 — `Nebu.Media.ClamAV` GenServer (health-check source).** Hard dependency: this story
  extends that module's `health_check/0` return shape and adds `signature_info/0`. If Story 3
  is not yet implemented when this story starts, its dev agent should build these two
  additions directly into Story 3's initial implementation rather than as a later patch; if
  Story 3 is already `done`, this is a small, explicitly-scoped amendment to an existing,
  shipped module — do not re-open or redesign anything else in Story 3's scope while doing so.
- **10a — `media_scan_stats` rollup + metrics section (shares the dashboard page/mechanism
  choice).** Not yet written as a story file at the time this story was authored (see Summary)
  — this story's assumptions about the page's route (`/admin/media/health`), rendering
  mechanism (LiveView), and update mechanism (periodic poll) must be verified against 10a's
  actual implementation. This story adds a second section to 10a's page; it does not create a
  new route.
- **10c — `media_alerts` + trigger (consumes this story's ClamAV-down signal)** and **10d —
  fail-open/fail-closed kill-switch (consumes this story's ClamAV-down signal)** both depend
  *on* this story per the epic's dependency lines — they are downstream consumers, not
  prerequisites; do not block this story on either of them.
