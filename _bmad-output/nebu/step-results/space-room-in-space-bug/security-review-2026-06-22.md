# Security Review — space-room-in-space-bug (createRoom `initial_state`)

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Date:** 2026-06-22
**Gate:** SEC Gate 1 (per-story, security_review: required — touches `:crypto`, signing envelope, external input)
**Diff scope:** `git diff --staged` — `POST /createRoom` now honors the Matrix `initial_state`
array. New proto field `initial_state_json` (`proto/core.proto`, `server/lib/pb/core.pb.ex`);
router reads `params["initial_state"]` (`server/lib/nebu/web/router/protected.ex`);
`apply_initial_state/3` + `parent_space_membership_ok?/2` replay entries via
`emit_state_event/5` (`server/lib/nebu/matrix/event_dispatcher/server.ex`); ExUnit tests
(`server/test/nebu/matrix/event_dispatcher/create_room_initial_state_test.exs`); test-only e2e
fixture (`e2e/...`, out of scope).

---

## Verdict: APPROVED — no CRITICAL/HIGH. Does not block the commit.

The four pre-declared security decisions were each adversarially probed and all **hold**.
One MEDIUM (advisory, defense-in-depth — amplified authenticated DoS) and two LOW.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `server.ex` `apply_initial_state/3` (≈4163) + router `createRoom` (no rate limit) | Amplified DoS: no cap on `initial_state` array length and no rate limit on `POST /createRoom`. One ~1 MB authenticated request packs ~40k tiny entries, each forcing an Ed25519 sign + synchronous DB insert + `:pg` fan-out, processed serially in the request process. | Add a hard per-array cap (e.g. ≤ 64 entries — Synapse-comparable; reject or truncate beyond) AND/OR attach a `RateLimit` plug to `createRoom` (room creation is not high-frequency; a tight ceiling like 30/min mirrors `/login`). |
| F-2 | LOW | `server.ex` `apply_initial_state/3` — `CanonicalJson.encode!` / `Jason.encode!` on attacker `content` | Deeply-nested client `content` (e.g. `{"a":{"a":…}}` thousands deep within 1 MB) drives unbounded recursion in `CanonicalJson.normalize/1`; pathological input can raise → 500 with the room left partially created (create+join+PL already persisted). Pre-existing identically on the generic state-PUT path; runs in the request process only (not a shared GenServer — `EventDispatcher.Server` is not a GenServer), so blast radius is one request. | Bound JSON nesting depth at decode (Jason `:max_nesting` or a pre-validate) shared by both `apply_initial_state` and `set_room_state`. Defense-in-depth; low priority. |
| F-3 | LOW | `server.ex` `apply_initial_state/3` | No `audit_log` emit for creator-authored `initial_state` events (e.g. `m.room.encryption`, `m.space.parent`). Consistent with the existing generic state-PUT path (which also emits none) — flagged only for the "new shape of action → carry audit invariant" pattern in MEMORY. Not a boundary crossing (creator's own room, signed as creator). | If/when state-event auditing is introduced, include the `initial_state` replay path. No action needed now. |

---

## Detail — why the four security decisions hold

**Decision 1 — Forbidden-types guard (`m.room.create` / `m.room.member` / `m.room.power_levels`).
SOUND, and stronger than it looks.**
The guard is exact-string `type in @initial_state_forbidden_types`. I probed case/namespace
variance (`M.Room.Member`, trailing space, custom aliases): a variant type is **inert** because
Nebu does *not* derive room membership or power-levels by folding `m.room.member` /
`m.room.power_levels` events out of the DB — that state is GenServer-managed via explicit
`Room.Server.join` / `set_power_levels` calls (`server/lib/nebu/matrix/room/server.ex`).
`apply_initial_state` only calls `emit_state_event/5` (a pure event-writer); it never mutates
`state.members` or `state.power_levels`. So even a hypothetically-unblocked forged membership/PL
event would be cosmetic timeline noise in the creator's own room, not an authority change. The
denylist (vs. the generic path's allowlist) is therefore an intentional, documented, and
defensible choice for this path. Tested: `create_room/2 — initial_state security guards`.

**Decision 2 — Parent-space membership guard (`parent_space_membership_ok?/2`). SOUND, faithful mirror.**
Compared line-for-line against `check_parent_space_membership/2` (≈1709): same existence source
(`get_room_create_event`), same membership source (`fetch_room_state(...).members`), non-raising
variant correctly maps every non-`{:ok}` outcome and the `GRPC.RPCError` rescue to `false` →
skip-this-entry (room still created). Identity shapes match: `creator_id` = `conn.assigns[:current_user]`
= canonical Matrix `@localpart:server` (router docstring line 138), and `parent_state.members` is a
MapSet of the same form — so the ContextKeySub-vs-UserID confusion pattern (MEMORY) does **not**
apply. Tested both reject (non-member/non-existent) and allow (joined) branches.
Note: `m.space.child` (the inverse edge) is *not* in the denylist and is *unguarded* — but it is
equally writable through the already-shipped generic state-PUT allowlist, lands only in the
creator's own room, and forged child→arbitrary-room edges are filtered by the read-time ROOT GATE
in `GetSpaceHierarchy`. No new boundary.

**Decision 3 — Server-built envelope. SOUND.**
`emit_state_event/5` (≈4235) hard-builds `room_id` (the brand-new room — never client-supplied),
`sender` (= creator), `type`, `state_key`, `origin_server_ts`, `event_id` (content-hash), and the
Ed25519 `signatures`. Only `content` + `state_key` originate from the client, both scoped to the
creator's own room. No path exists for a client field to redirect the write to another room/user
(no IDOR) or to reach the signed top-level fields.

**Decision 4 — Body bounded at 1 MB.** Confirmed: `Nebu.Web.Plugs.JsonBody` `length: 1_000_000`
applies to `createRoom` (only the `/admin/*` subtree is carved out). The residual concern is
amplification *within* that cap — F-1.

## Other angles probed (all clean)
- **Auth**: `OidcPlug` runs first in the `Protected` router pipeline (line 26) → createRoom requires
  a valid Bearer token; `initial_state` does not widen any unauthenticated surface.
- **IDOR / cross-tenant write**: impossible — `room_id` fixed to the new room, `sender` fixed to creator.
- **`state_key` → another user/room**: opaque string scoping state within the creator's own room;
  membership-class forging blocked; no cross-room effect.
- **`m.room.encryption` / `history_visibility` / `server_acl` / `tombstone` / `third_party_invite`
  via the denylist gap**: each lands only in the creator's own freshly-created room where they are
  sole admin; `server_acl` is inert (no federation, by design); no boundary crossed. Honoring these
  is the documented goal (Element parity), not a vulnerability.
- **GenServer crash**: `EventDispatcher.Server` is not a GenServer; `apply_initial_state` runs in the
  HTTP request process. A malformed-entry crash 500s one request — no shared-process takedown.
- **Crypto/signing**: replayed events signed by the same `:nebu_signing_key` Ed25519 path as all
  other events; no client field reaches the signed envelope; no alg/type confusion (Ed25519 fixed).

---

## Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 1 (F-1) — advisory, recommend a follow-up before epic end
LOW: 2 (F-2, F-3) — advisory

**Verdict: APPROVED.** The bug fix is well-guarded and well-tested; the membership/PL forgery
surface is closed both by the denylist and (more durably) by Nebu's GenServer-authoritative state
model. Recommend addressing F-1 (array-length cap and/or createRoom rate limit) as cheap
hardening — it is the only new exposure the feature introduces.
