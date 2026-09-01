# ADR-026: HTTP Status Codes for Unavailable Media

## Status

Accepted - 2026-07-06

Part of: Epic `media-security-admin-control`. Formalizes a decision already made and
referenced throughout that epic's stories (1c, 2d).

## Context

The media download handler (`/_matrix/media/v3/download/…` and
`/_matrix/client/v1/media/download/…`) is the single enforcement point for the media
state machine (`reserved → quarantined → scanning → {released | infected | scan_failed |
admin_blocked | deleted | hard_deleted}`). Every state except `:released` must fail the
download, but not all failure states should look the same to a client — some are
temporary (retry later), some are permanent, and one is deliberately ambiguous for
privacy reasons.

## Decision

| State | HTTP Code | Rationale |
|---|---|---|
| `:reserved`, `:quarantined`, `:scanning`, `:scan_failed` | 451 + `M_NOT_YET_UPLOADED` | Temporary/pending state; spec-compatible with the async-upload stall mechanism (Story 2d). |
| `:infected` | 404 + `M_NOT_FOUND` | Privacy: does not leak that malware was detected on this specific media. |
| `:admin_blocked` | 404 + `M_NOT_FOUND` | An active policy decision — byte-identical status AND body to a genuine 404, so a moderation action is indistinguishable from "this media never existed." |
| `:deleted`, `:hard_deleted` | 404 + `M_NOT_FOUND` | Standard "resource does not exist" semantics. |

`:released` is the only state that returns `200 OK` with the file body.

**Corrected 2026-07-19** (media-security-admin-control/6a-routine-state-actions,
Kassandra security-review, self-caught before commit): an earlier revision of this ADR
gave `:admin_blocked` a *distinguishable* HTTP status — `451 + M_NOT_FOUND` — reasoning
that anonymizing only the JSON `errcode`/body was sufficient, since "the status differs
but that's not itself a leak." **That reasoning is wrong and was corrected.** The pairing
`(451, M_NOT_FOUND)` was unique to `:admin_blocked` — no other state produces it (pending
states return `451 + M_NOT_YET_UPLOADED`; every other terminal-negative state returns
`404 + M_NOT_FOUND`) — so the bare HTTP status line, without even reading the response
body, was a perfect oracle for "an admin blocked this file," fully defeating the
anonymity this decision exists to provide. **True indistinguishability requires an
identical status line AND an identical body** — anonymizing only one of the two
anonymizes neither. `:admin_blocked` therefore returns the exact same `404 + M_NOT_FOUND`
response as `:infected`/`:deleted`/`:hard_deleted`/a genuine unknown-`media_id` — there is
no separate "admin blocked, but honestly so" status left anywhere in this response. This
is a deliberate choice of *anonymity over transparency*: unlike RFC 7725's
`451 Unavailable For Legal Reasons` (which exists specifically to let a client *know* a
resource was blocked for legal/policy reasons), this product's explicit design goal since
1c is the opposite — an admin block must be invisible to the unauthenticated client, only
ever visible in the admin UI and the compliance audit/transition logs.

## Consequences

### Positive
- Clients get a consistent, spec-compatible signal to distinguish "try again later"
  (451) from "this will never be available" (404) without leaking why a file is
  unavailable in the malware/admin-block/deleted cases — all three collapse to the exact
  same 404 response.
- A single decision table, referenced by every story touching the download path (1c, 2d,
  6a), avoids each story inventing its own status-code mapping.

### Negative / risks
- Collapsing `:admin_blocked` into the same 404 as `:infected`/`:deleted`/unknown-id means
  an admin cannot signal "this is a legal/policy block, not a deletion" to the client even
  if that were ever desired (it is not — anonymity is the explicit goal) — acceptable
  since the admin UI (not the client) is the surface for investigating why a specific file
  is unavailable.
- A prior revision of this ADR (see the 2026-07-19 correction above) shipped a status-line
  leak for roughly two weeks (1c through the day before 6a's security review) — the
  download-gate code and the anonymity test both need to be checked, not merely the ADR
  text, whenever this decision is revisited: a documentation fix without a matching code
  fix would silently re-introduce the exact same gap.

## Related

- Epic `media-security-admin-control`, Stories 1c, 2d, 6a.
- Kassandra's sanctum (`_bmad/memory/nebu-agent-kassandra/MEMORY.md`), Recurring Patterns:
  "Anonymity by identical BODY but distinguishable STATUS is not anonymity."
