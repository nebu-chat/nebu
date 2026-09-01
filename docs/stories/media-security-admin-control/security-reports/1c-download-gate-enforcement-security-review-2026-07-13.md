# Security Review — media-security-admin-control / 1c-download-gate-enforcement

**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-13
**Diff scope:** `git diff --staged` — `server/lib/nebu/media.ex` (+46/-4), `server/lib/nebu/media/db.ex` (+53/-3), `server/test/nebu/media/media_download_gate_test.exs` (new), `media_test_support.exs`, `media_upload_test.exs`. Non-code artifacts (pipeline-state, findings, sanctum) excluded.
**Story:** 1c — the HTTP enforcement point for the `media_files.state` lifecycle ENUM. First story to READ `state` and gate download/thumbnail byte-serving on it.

---

## Verdict: APPROVED — no CRITICAL/HIGH. Commit not blocked.

The core mechanism is correct and matches its specification. The gate is an allowlist-of-success (`:released` is the ONLY `:serve` clause; everything else including the catch-all denies), which is exactly the default-deny shape memory pattern #81 mandated for this epic. It runs before membership and before any storage/decrypt (AC7 verified). Fail-closed behavior under DB/decode failure is sound. Bypass-path analysis is clean: `with_authorised_media/4` is the only route to media bytes.

One **MEDIUM** advisory (an anonymity-property gap that is faithfully implemented from a self-contradictory ADR/AC — must be resolved before Story 6a makes it reachable), two **LOW**, one **INFO**.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `media.ex:246` + ADR-026 + AC2 | `admin_blocked` → `(451, M_NOT_FOUND)` is a unique, distinguishable fingerprint; the stated "indistinguishable from a file that never existed" anonymity property is NOT achieved, and the human-admin-vs-automated-scan leak the ADR prose says it prevents is present | Map `admin_blocked → 404 M_NOT_FOUND` (status- AND body-identical to deleted/infected/never-existed), OR formally accept the 451 oracle and correct the story/AC2/ADR-026 prose + get owner sign-off. Resolve before Story 6a. |
| F-2 | LOW | `db.ex:50` / `db.ex:122` | Dropped `WHERE deleted = false` safety net; gate keys solely on `state`; legacy `deleted` boolean now vestigial | Drop the `deleted` column (+ its SELECT/insert/row-map refs) now that `state` is authoritative, OR add a DB CHECK/trigger keeping them consistent. Watch-flag any future `SET deleted = true` writer. |
| F-3 | LOW/INFO | `media.ex:209` | Gate-before-membership lets a non-member holding the MXC id infer a file's coarse lifecycle state | Within the story's accepted trade-off; documented. No code change required for 1c. Compounds F-1. |
| F-4 | INFO | `db.ex:158` | `parse_state/1` now public (`@doc false`) | No exploitable surface — pure fn, `to_existing_atom` (not `to_atom`) cannot intern attacker atoms. Positive defensive choice; keep. |

---

## Detail

### F-1 — `admin_blocked` is a distinguishable oracle; the stated anonymity property is not delivered [MEDIUM]

**The stated requirement.** The user story: "an admin's decision to block a file stays **indistinguishable from a file that simply never existed**." AC2 calls this "deliberate and security-relevant." ADR-026's prose (lines 31–35): the goal is to "avoid confirming a scan-related block" and prevent a client/uploader inferring "that a human admin specifically intervened, as opposed to an automated scan result."

**What is actually observable.** The full response matrix as implemented (`download_gate/1` + `gate_message/1` + `error/4`):

| State | HTTP status | errcode | body `error` |
|---|---|---|---|
| reserved / quarantined / scanning | **451** | `M_NOT_YET_UPLOADED` | "Media not yet available" |
| **admin_blocked** | **451** | `M_NOT_FOUND` | "Media not found" |
| infected | **404** | `M_NOT_FOUND` | "Media not found" |
| deleted / hard_deleted | **404** | `M_NOT_FOUND` | "Media not found" |
| genuine not-found (no row) | **404** | `M_NOT_FOUND` | "Media not found" |

`(451, M_NOT_FOUND)` is a **unique fingerprint** for `admin_blocked` — no other state produces it. Therefore:

1. **Distinguishable from a genuine 404.** An admin-blocked file returns status **451**; a never-existed / deleted / infected file returns **404**. The bodies are byte-identical (the test verifies this — `media_download_gate_test.exs:180-185`), but the **status line is the oracle**. The story's "indistinguishable from a file that never existed" property is false: a single HTTP status comparison distinguishes them.
2. **Distinguishable from an automated-scan block — the exact leak ADR-026's prose forbids.** `infected` (automated scan) → 404; `admin_blocked` (human decision) → 451. An uploader whose file becomes unavailable can read the status and infer "a human admin blocked me" (451) vs. "the scanner flagged me" (404) vs. "still pending" (451 + `M_NOT_YET_UPLOADED`). This is precisely the human-vs-scan inference ADR-026 §Decision claims to prevent.

**Root cause is a self-contradictory spec, faithfully implemented.** ADR-026's *table* says `admin_blocked → 451 + M_NOT_FOUND`; ADR-026's *prose* says "The `:admin_blocked` → **404** choice is an explicit, accepted deviation" and argues a "distinguishable status code would let a client infer that a human admin specifically intervened." The table and prose disagree on the status code (451 vs 404). The dev correctly implemented the table + AC2; the code is not at fault. The **security property is** — neither the table nor AC2 delivers the anonymity the story, AC2's own justification, and the ADR prose all claim. The test (`:172-185`) enshrines the contradiction: it asserts `status == 451` while commenting "indistinguishable from a genuine 404."

**Why MEDIUM, not HIGH.** The leak is one bit ("this media was admin-blocked") to an observer who must already hold the unguessable 128-bit random MXC id (`generate_media_id/0`, `media.ex:439-441`). No auth bypass, no byte disclosure, no privilege change. **Reachability:** `admin_blocked` has no admin-facing trigger endpoint yet — that is Story 6a. The oracle is currently **dormant**; it becomes live-exploitable the moment 6a ships an admin-block action (cf. the "`// MVP` shortcut became reachable when the service was wired up" memory pattern). Do not let it land silently.

**Remediation (pick one, before 6a):**
- **(a) Achieve the goal:** change `download_gate(:admin_blocked)` to `{404, "M_NOT_FOUND"}`. This makes admin-blocked byte- AND status-identical to deleted/infected/never-existed — true indistinguishability — and matches ADR-026's prose. Update AC2 and the test's status assertion accordingly.
- **(b) Keep 451 as an accepted risk:** retain the current mapping for its "unavailable for legal reasons" / proxy semantics, but strike the "indistinguishable from a file that never existed" claim from the user story, AC2, and ADR-026's prose, replace it with an explicit residual-oracle note, and record it in MEMORY.md Accepted Risks with Phil's sign-off. Reconcile ADR-026's table and prose either way.

---

### F-2 — Dropped `WHERE deleted = false`; the `deleted` column is now a vestigial, unenforced safety net [LOW]

`@sql_lookup` no longer filters `WHERE deleted = false` (`db.ex:50`); `lookup/2` returns every matching row and the gate decides on `state` alone. **This is safe in the current codebase**, verified:

- The **sole runtime writer** of any `media_files` column beyond insert is `state_machine.ex:64` — `UPDATE media_files SET state = $2 WHERE media_id = $1`. It writes `state` only, never `deleted`.
- `insert/1` sets `deleted = false` (`db.ex:58`); nothing flips it at runtime.
- Migration `000022:38` did a one-time backfill `UPDATE media_files SET state = 'deleted' WHERE deleted = true`, and `state` is `NOT NULL DEFAULT 'released'` (`000022:29`). So the one historical divergence was reconciled, existing downloadable rows correctly became `'released'`, and no `(deleted = true, state = 'released')` row can currently exist.

Therefore **no live confidentiality regression** — a soft-deleted file cannot be re-served today.

**The risk is forward-looking.** The old `WHERE deleted = false` was a defense-in-depth net that would have caught any row flagged deleted regardless of `state`. That net is gone, and `deleted` is still SELECTed and carried in the row map (`db.ex:122`) yet consulted by nothing. Any FUTURE story that revives a legacy-style `UPDATE media_files SET deleted = true` — a plausible naive implementation of an admin/GDPR/retention delete — **without** a matching `StateMachine` transition to a deny-state would leave `state = 'released'` and the gate would **serve the bytes**. This is the "non-atomic dual-column state" landmine.

**Remediation:** now that `state` is the single authoritative access signal, drop the `deleted` column and its `SELECT`/`insert`/row-map references in a follow-up (cleanest), OR add a DB CHECK/trigger asserting `deleted = true ⟹ state IN ('deleted','hard_deleted')`. Record the "vestigial legacy boolean shadowing a new authoritative enum" watch-flag.

---

### F-3 — Gate-before-membership widens state inference to non-members [LOW/INFO]

The gate now runs before the membership check for **all 7 deny branches** (verified: `with_authorised_media/4`, `media.ex:209-219` — the `case download_gate(row.state)` wraps the membership `if`). The story's reasoning that "a denied non-released file returns the same response regardless of membership" holds for every deny branch, because none of them consult `user` or `row.room_id`.

Consequence: a **non-member** who possesses a file's 128-bit MXC id can now read its coarse lifecycle bucket — pending (451 `M_NOT_YET_UPLOADED`), blocked (451 `M_NOT_FOUND`), gone/absent (404), or released (403 from the membership check). Pre-change, a non-member received a uniform 403 for any non-deleted row and 404 for deleted rows. **No bytes are ever served to a non-member** (released still requires membership → 403), so confidentiality of content is intact. This is the story's explicitly-accepted trade-off. Noted because (a) it widens the existence/state-inference surface to non-members, and (b) it compounds F-1: a non-member holding a blocked file's id also learns it was admin-blocked. Marginal — gated behind the unguessable id. No code change required for 1c.

---

### F-4 — `parse_state/1` made public (`@doc false`) — no exploitable surface; correct defensive choice [INFO]

Making `parse_state/1` public (`db.ex:158`) for direct unit testing opens no attack surface:

- It is a **pure function**: `String.to_existing_atom(state)` with an `ArgumentError` rescue → `:__unrecognized_media_state__`. No I/O, no state, no side effects.
- It uses `to_existing_atom`, **not** `to_atom` — so it **cannot intern new atoms**. The classic "atom-table exhaustion DoS via `String.to_atom` on attacker input" is explicitly avoided; an unknown/attacker-influenced value hits the rescue and returns the fail-closed sentinel, which no `download_gate/1` clause matches → catch-all `451` (AC6). This directly satisfies the fail-closed requirement.
- The only caller carrying DB-derived (attacker-adjacent) data remains `to_map/1`. `@doc false` + public purely as a testability seam is an established convention here (mirrors `Nebu.Health.overall_status/1`).

This is the right call, not a risk. Keep it.

---

## Adversarial probe results (coordinator watch-list)

1. **Anonymity / oracle resistance (AC2):** FAIL as a full anonymity property → **F-1 (MEDIUM)**. Body is byte-identical (verified), but the **status code (451 vs 404) is a distinguishing oracle** and `(451, M_NOT_FOUND)` uniquely fingerprints `admin_blocked`. No header/caching oracle beyond the status line: `error/4 → send_json/3` emits only `content-type: application/json` + body for every 4xx, with no `Cache-Control`/`ETag`/`Vary`, so 451 and 404 differ **only** in the status line. HTTP/1.1-vs-2 framing is adapter-uniform for both.
2. **Bypass paths:** CLEAN. `fetch_and_decrypt/3` (`media.ex:262`) is the sole path to `storage_module().get/1` + media `Crypto.decrypt/3`, reachable only via `with_authorised_media/4`, reachable only via `download/4` and `thumbnail/3`. Router (`router/media.ex`) exposes only upload (write), download, thumbnail, preview_url (external fetch, SSRF-guarded — no `media_files` bytes). Other `Crypto.decrypt`/`SecretBox.decrypt` callers (`secret_box.ex`, `admin/auth.ex`, `bootstrap_live.ex`, `matrix/http_public.ex`) decrypt admin/OIDC refresh tokens with a different key — not media content.
3. **Membership reordering:** SOUND for confidentiality; widens state inference to non-members → **F-3 (LOW/INFO)**. Verified across all 7 deny branches.
4. **`parse_state/1` public visibility:** no exploitable surface → **F-4 (INFO)**, positive.
5. **Dropped `deleted = false` filter:** no live regression; forward-looking landmine → **F-2 (LOW)**. Verified sole `state` writer + frozen `deleted` + backfill + `NOT NULL DEFAULT 'released'`.
6. **Fail-closed under DB/decode failure:** CONFIRMED. `lookup/2` maps every non-`{:ok, [row]}` result (incl. `{:error, _}`, empty rows, malformed) to `{:error, :not_found}` → 404 (`db.ex:69-77`). `nil`/NULL or unknown `state` → `parse_state` rescue → sentinel → catch-all 451. An unhandled raise (pool checkout failure) propagates to a Plug 500 with no bytes served and no stacktrace body (no `Plug.Debugger` in prod). No path serves bytes on failure; no sensitive value in any 4xx/5xx body.
7. **Timing side-channel:** no finding. All deny branches are constant-shape (one indexed `lookup` + O(1) atom match + JSON encode) and identical across 451/404; only `released` + member performs the slow storage-get/decrypt, already signalled by the 200 status. Existing-vs-absent row lookup timing on a 128-bit random key is sub-noise vs. network jitter — not a practical enumeration oracle.

---

## Summary

- **CRITICAL:** 0
- **HIGH:** 0
- **MEDIUM:** 1 — F-1 (advisory; resolve before Story 6a makes `admin_blocked` reachable)
- **LOW:** 2 — F-2, F-3
- **INFO:** 1 — F-4

**Verdict: APPROVED.** The gate mechanism is correct, default-deny, fail-closed, and has no bypass. F-1 is a spec-level anonymity gap (self-contradictory ADR-026 + AC2), faithfully implemented in code — it does not block this story but MUST be reconciled before the admin-block action (Story 6a) makes the oracle live. F-2 is a dormant forward-looking landmine from retiring the `deleted` filter. Recommend recording both as MEMORY watch-flags for the remainder of this epic.
