# ADR-030: Media Lifecycle Rules & Two-Eyes Delete

## Status

**Proposed (DRAFT)** — 2026-07-02

Born from **R-015** (test-design `media-security-admin-control`, Score 9 — critical blocker).
Governs / restructures Stories 8 and 9 of the `media-security-admin-control` epic. Touches
ADR-018 (no domain model — inline SQL), ADR-020 (Public-API rule — `Nebu.Media`), ADR-022
(bootstrap-only, admin-configurable via DB, not env). Supersedes the naïve "user can delete
their own media" framing of the original R-015 mitigation.

> **Legal note:** This ADR fixes the *architecture*. The statutory basis (DSGVO Art. 17(3)
> retention exceptions vs. Art. 18 restriction; HGB §257 / AO §147 retention periods) must be
> confirmed by the operator's DSB / Rechtsanwalt before go-live — the same legal-review gate the
> PRD already mandates for ADR-007/ADR-011. Nebu ships the *mechanism*; the operator sets the
> *policy* for their own legal grounds.

## Context

The `media-security-admin-control` epic introduced media retention as a grab-bag of independent,
hard-coded config knobs, each with its own Oban cron:

- `released_archive_after_days` + `archive_delete_from_primary` (Story 8c) — active → archive
- `released_delete_after_days` (Story 8d) — active → hard-delete
- `deleted_days` (Story 8a) — soft-deleted → hard-delete
- `infected_days` (Story 8a) — infected → hard-delete
- `orphaned_hours` (Story 8b) — orphan → soft-delete

R-015 then surfaced a compliance gap: a data subject's **DSGVO Art. 17** erasure request for
their own media had no home. The original test-design mitigation ("let the user delete their own
media, independent of scan status") is **wrong for Nebu's target market** (deutsche Kommunen /
Behörden / regulierte Firmen), for two operator-stated reasons:

1. **Evidentiary value** — a file may evidence criminal intent; a data subject must not be able
   to destroy it on demand.
2. **Retention obligations** — the file is company property under statutory archival duties
   (HGB §257 ~6 y., AO §147 ~10 y., or "until the case closes" for evidence).

This is precisely the **Art. 17(3)** exception space (erasure does not apply where processing is
necessary for a legal retention obligation or the defence of legal claims). The correct pattern
is **restriction of processing (Art. 18)**: the file goes *invisible immediately*, bytes are
*retained*, and physical deletion happens *only when compliance-clear*, under a **two-person
rule** (admin + compliance, or 2× compliance — two admins is **not** sufficient).

Two observations turned this into one decision rather than a bolt-on:

- The scattered knobs are already a **state-transition ladder** —
  `active → archive → marked-deleted → deleted` — matching the epic's own state machine.
  AWS S3 exposes exactly this as **Lifecycle Rules**; operators already understand that mental
  model.
- Erasure-release, `released_delete`, and marked-deleted→deleted are **three independent
  consumers** of the same dual-control gate. Rule of Three: the abstraction is earned.

## Decision

Replace the fragmented retention knobs with a single, admin-configurable **Media Lifecycle
Policy** (an S3-Lifecycle analog) plus a **Two-Eyes-Delete** control (an S3 MFA-Delete analog).

### 1. Lifecycle Policy — a fixed transition ladder

The policy is a **fixed ladder** mapped onto the existing `media_state` machine. Each rung is
`{ enabled: bool, after_days: int }`; `enabled: false` (default for the destructive rungs) means
the transition never fires.

| Rung | State transition | HTTP after | Replaces |
|---|---|---|---|
| `archive` | `:released` → `:released` + `archived_at` (bytes → archive bucket) | 200 (bucket switch) | 8c `released_archive_after_days` |
| `mark_deleted` | `:released`/archived → `:deleted` (invisible, bytes retained) | 404 `M_NOT_FOUND` | 8d `released_delete_after_days` (first half) |
| `delete` | `:deleted` → `:hard_deleted` (bytes gone, record kept) | 404 `M_NOT_FOUND` | 8a `deleted_days` |

Two cohort rules run on the same engine but are **not** part of the active ladder (they have
their own entry state, not `:released`):

- `infected_delete_after_days` — `:infected` → `:hard_deleted` (was 8a `infected_days`)
- `orphan_mark_after_hours` — orphaned `:quarantined` → `:deleted` (was 8b `orphaned_hours`)

**Explicitly NOT a general rule DSL.** We copy S3's *shape* (a fixed ladder with per-rung
day-thresholds and enable flags), not its arbitrary-predicate/tag-filter engine. YAGNI.

**Scoped policy documents with a `global → space → room` cascade** (Review-5 update; supersedes
the earlier "global-only" scope). The lifecycle policy is a declarative **document** that can
exist at three scopes — `global`, `space:<id>`, `room:<id>` — with **field-level override**
(CSS-cascade / Kubernetes style): the effective policy for a room R is
`global ⊕ space(R) ⊕ room(R)`, room highest priority, global lowest. A room may override just
`delete.after_days` and inherit the rest. Global is the always-present base and the default for
any media not resolvable to a room.

Because one physical object may be referenced by several rooms (with conflicting policies) and
the spec grants **no media↔room ownership** (Oracle, CS-API §Content Repository), the effective
policy for a media file is the **most-conservative across all referencing rooms** — a file kept
alive or held by *any* referencing room's effective policy is not deleted. The same
dominance rule resolves a room with multiple parent spaces (`canonical` is a display hint, not an
arbitration key). Media referenced by no room → `global`.

> **⚠️ Hard spec boundary (Oracle, 2026-07-02): per-room/space policy is Compliance-Mode-only.**
> In an E2EE room the event is `m.room.encrypted` and `content` is Megolm ciphertext, so the
> `mxc` at `content.file.url` is **invisible to the server** — the room→media join is impossible.
> Encrypted rooms therefore **always fall back to the `global` policy**; per-room/space resolution
> is only available where content is server-readable (Compliance Mode, ADR-011/ADR-023). This is a
> spec consequence, not a roadmap item.

**Room/space resolution mechanics** (Oracle, CS-API §Spaces, §Instant Messaging):

- **mxc → rooms** is derived from a maintained index over `events.content`, covering **all six
  fields** an `mxc` can occupy: `content.url` + `content.info.thumbnail_url` (`m.room.message`
  image/file/audio/video, `m.sticker`, `m.room.avatar`), `content.avatar_url` (`m.room.member`),
  and the encrypted `content.file.url` + `content.info.thumbnail_file.url`. This is the
  materialisation of the *reserved interface* named in the "Compliance-Sichtbarkeit" ADR — build
  them as one thing, not two. A runtime `@>` scan that misses a field silently under-retains.
- **room → space(s)** uses `m.space.child` (state in the space-room) as the **trust anchor**;
  `m.space.parent` (state in the child) is an unverified claim and is honoured only when a matching
  `m.space.child` exists **or** its sender has PL to send `m.space.child` in the parent. Multiple
  parents are allowed; loops are disallowed-but-possible (guard for them); the link is **dynamic**
  (a demotion/leave can invalidate it). Effective policy is therefore resolved at
  **cron transition-evaluation time**, not cached per-download.

### 2. Two-Eyes Delete — the MFA-Delete analog

A policy-level flag `two_eyes_delete_required: bool` (default **true** in Compliance Mode, see
ADR-023). When enabled:

- **No cron ever physically deletes.** The lifecycle engine may move files *to* `:deleted`
  (marked, invisible) automatically, but the terminal `:deleted → :hard_deleted` transition
  becomes a **proposed → confirmed** dual-control action, never a cron side-effect.
- **Quorum rule:** two **distinct** principals must approve, and **at least one must hold the
  `compliance_officer` role**. Admin + compliance ✅. 2× compliance ✅. 2× admin ❌. Same actor
  twice ❌.
- **Policy changes are themselves protected.** Editing the lifecycle policy (especially enabling
  a destructive rung or *disabling* two-eyes) is audited and, when two-eyes is on, requires the
  same dual-control confirmation — mirroring S3 MFA-Delete gating both object deletion *and*
  versioning/policy changes.

### 3. Legal Hold — the per-file pin for Art. 17 / evidence

A per-file marker (`legal_hold` boolean + `erasure_requested_at`, `erasure_requested_by`) that
**pins a file out of every automatic transition** until an explicit two-eyes release.

- A **DSGVO Art. 17 erasure request** (captured admin-side; Nebu has no self-service destructive
  user action, consistent with admin-driven `deactivate_user`) moves the file **immediately** to
  the marked-deleted lane (`:deleted`, invisible, 404) **and sets `legal_hold = true`**, from any
  scan state (`:quarantined` / `:scanning` / `:infected` / `:released`). The data subject's
  request is honoured in the *visible* sense at once (Art. 18 restriction); the bytes are
  retained.
- A held file is **exempt from the lifecycle `delete` rung, the `infected` cohort rule, and every
  other auto-hard-delete path** — no timer can ever destroy held data.
- Leaving legal hold (→ physical deletion) is **only** possible via the two-eyes release. A single
  admin can neither delete a held file nor un-hold it. This "single actor cannot reverse" boundary
  is why legal hold is enforced as a **StateMachine guard**, not merely a UI affordance.

### State-machine impact

No new `media_state` ENUM value is required: "marked-as-deleted / invisible" **is** the existing
`:deleted` state (already 404, bytes retained). Legal hold rides as an orthogonal **attribute +
guard** on top of the lifecycle ladder, so the invisibility comes from the state and the
irreversibility comes from the two-eyes guard.

> Alternative considered: a dedicated `:erasure_held` state. Rejected — it duplicates `:deleted`'s
> HTTP/retention semantics and adds ENUM/badge/dashboard wiring (and an `ALTER TYPE ADD VALUE`
> migration, cf. R-016) for no behavioural gain now that "marked-deleted" is a first-class rung.
> The `legal_hold` guard carries the one property `:deleted` lacks (single-actor irreversibility).

### 4. Restore-Verfahren (Review 8, added 2026-07-06 — Kassandra)

Backup/restore and this ADR's two guarantees — hard-delete is irreversible, legal hold is
un-holdable by a single actor — are in direct tension unless reconciled explicitly. A
backup captures a point-in-time snapshot; it has no concept of `legal_hold` or
`hard_deleted_at` as *guarantees to preserve across a restore*, only as ordinary column
values at snapshot time.

**Two concrete failure modes this section closes:**

1. **A restore brings back a hard-deleted file.** If the restored snapshot predates a
   hard-delete, the restored row has `storage_key` populated again and the S3 side may or
   may not still hold the object (depending on whether S3 and PostgreSQL are backed up on
   the same schedule). Either way, the system now asserts "deleted" to a data subject
   while a restore has silently made that assertion false.
2. **A restore un-holds a legal-hold file.** If the restored snapshot predates a
   `legal_hold = true` write, the restored row shows `legal_hold = false` — a file that
   was pinned as evidence or under a statutory retention obligation becomes eligible for
   normal lifecycle deletion again, with no single admin action ever having authorized
   that release. This is evidence spoliation with system support, not merely a data bug.

**Decision:** every restore (disaster recovery, or any snapshot-based environment
refresh sourced from production data) MUST be followed by an automatic reconciliation
pass, run **before** the restored system is returned to serving traffic:

- Re-apply hard-delete to every `media_files` row whose `hard_deleted_at` (in the
  pre-restore, authoritative record — see below) is earlier than the restore's snapshot
  timestamp but whose restored state shows `storage_key IS NOT NULL`.
- Re-apply `legal_hold = true` to every row known to have been held as of the snapshot
  timestamp but whose restored state shows `legal_hold = false`.

This requires that hard-delete and legal-hold events themselves be reconstructable
independent of the restored `media_files` snapshot — the append-only
`media_state_transitions` log (ADR-031) is the authoritative source for this, since it is
never mutated and (being the same database) is restored consistently alongside
`media_files`. **This procedure therefore assumes PostgreSQL is the system of record for
*whether* a hard-delete or legal-hold happened, and reconciliation is a PostgreSQL-only
replay against `media_state_transitions` — it does not, by itself, resolve a scenario
where PostgreSQL and the S3/MinIO object store are backed up and restored on divergent
schedules** (e.g. an S3 replica restore bringing back a blob that PostgreSQL's own
authoritative history says was deleted). If Nebu's backup strategy backs up PostgreSQL
and S3 independently, the reconciliation pass must additionally re-delete any S3 object
whose corresponding `media_files`/`media_state_transitions` record shows a hard-delete
at or before the S3 snapshot's timestamp. This is an operational requirement on the
backup/restore runbook, not a code change to the lifecycle worker itself — it is
recorded here so it is never treated as an implicit guarantee.

Until this reconciliation pass is implemented and included in the disaster-recovery
runbook, **any restore from a production backup is a potential compliance breach** for
both hard-delete and legal-hold, and must be treated as such operationally (e.g. legal
hold status manually re-verified before a restored environment is used for anything
beyond isolated forensics).

## Consequences

**Positive**
- One coherent, operator-recognisable model (S3 Lifecycle + MFA-Delete) replaces five scattered
  knobs; each retention behaviour is now a rung of one policy.
- Art. 17 is satisfied *correctly* for a regulated market: restriction-now, deletion-only-when-
  compliance-clear, dual-controlled — not a naïve user-delete.
- The "no deletion without two people, one of them compliance" guarantee is structural (a
  StateMachine guard), not a convention that a future cron or admin path can silently bypass
  (the failure mode behind R-006 and the audit-allowlist merge trap).
- Every transition already writes an immutable `media_state_transitions` row; the two-eyes
  approvals and Art. 17 request/release additionally hit the global `audit_log`.

**Negative / costs**
- Restructures Stories 8 + 9: the individual `*_days` config keys become fields of the lifecycle
  policy; the 8a/8c/8d crons consolidate into one `MediaLifecycleWorker`. Migration must map any
  existing keys to the new policy shape.
- Introduces a new `compliance_officer` role (distinct from the normal admin role and from
  Story 6c's `media_admin_override`) and a dual-control approval mechanism (proposed→confirmed
  with a pending window).
- Default `two_eyes_delete_required: true` means deletion is a two-step human action in
  Compliance Mode — intended friction, but operators in Normal Mode (ADR-023) will disable it.

**Follow-ups / open**
- Legal-hold release is **manual only** — no time-based auto-release cron. Retention periods are
  case-dependent ("until the case closes"); an auto-release timer on held data is the one
  automation we deliberately refuse. An informational `legal_hold_until` timestamp MAY be stored
  for display, but it never triggers deletion.
- **Redaction stays decoupled from legal hold (Oracle-confirmed).** Legal hold = download **404**,
  a spec-neutral and *reversible* restriction. `m.room.redaction` is the only spec tool to remove
  the reference itself; it strips the **entire** `content` of an `m.room.message` and is
  **irreversible** and PL-gated. It is therefore offered — if at all — as a separate,
  operator-initiated, per-room action, **never** an automatic side-effect of a hold that a
  two-eyes release might later reverse.
- The mxc→room index must be maintained on event insert across all six mxc-bearing fields;
  a later new event type carrying media must extend it (CI guard candidate, cf. R-002).

## Alternatives considered

- **Keep the scattered knobs, bolt on a separate Art. 17 delete path.** Rejected — leaves two
  parallel retention models and re-creates the "which cron owns this file" ambiguity; misses that
  the knobs are already one ladder.
- **Self-service user media deletion.** Rejected — Matrix CS API defines no such endpoint, it
  would be Nebu's only self-service destructive action, and it directly violates the evidentiary /
  retention requirements above.
- **Time-based auto-release of legal hold.** Rejected — see Follow-ups; case-dependent retention
  makes any auto-release timer unsafe.
