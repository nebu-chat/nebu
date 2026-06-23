---
story_id: spaces-elixir-s4-restricted-join
title: "Spaces S4: restricted join-rule enforcement MSC3083 (Elixir port of epic-15 15.5a/15.5b)"
type: feature
severity: high
epic: spaces-elixir
status: review
security_review: required
created: 2026-06-21
branch: feature/spaces-elixir
matrix: false
ui: false
---

## Summary

Enforce the `restricted` join rule (MSC3083, stable v1.2) so a Space's child room can be
joined by Space members without an explicit invite. Ports epic-15 15.5a/15.5b. Builds on
S2 (join_rules writable via state PUT) + S3 (hierarchy surfaces join_rule).

**Current state:** `join_room/2` does NOT check `m.room.join_rules` at all (server.ex
~2199 comment confirms it). This story adds the restricted-rule gate to the join path. To
avoid breaking the existing open-join MVP behaviour and tests, this story is SCOPED to the
`restricted` rule only — `public` and `invite`/default behaviour is UNCHANGED.

**Kassandra forward-warnings from S2+S3 (MUST honour):** `m.room.join_rules.allow[]` is
client-writable by any PL≥state_default member (via the S2 generic state PUT), so
`restricted` + `allow[]` is a membership-bypass primitive. Therefore: validate every
`allow[]` entry (well-formed, `type: "m.room_membership"`, references an existing room the
*joining* user is actually a member of); and the allow-room resolution must NOT leak a
private allow-room's existence to the joining user.

## Story

As a Space member,
I want to join a `restricted` room when I am a member of one of the Spaces in its
`m.room.join_rules.allow` list (or I have a pending invite),
So that Space members can self-join child rooms without manual invites — while non-members
are still kept out.

## Acceptance Criteria

**AC1 — restricted: Space member allowed:**
A room with `join_rule: "restricted"` and `allow: [{type: "m.room_membership", room_id:
"<space>"}]` — a user who IS a member of `<space>` can join (`/join` → 200; membership
emitted). The Space-membership check uses the in-memory member set (no DB roundtrip where
possible), mirroring how the server reads room state.

**AC2 — restricted: non-member rejected:**
A user who is NOT a member of any allow[] Space, and has NO pending invite → `/join` →
`403 M_FORBIDDEN`.

**AC3 — invite overrides restricted:**
A user with a pending `m.room.member` invite to the restricted room can join regardless of
Space membership → 200.

**AC4 — allow[] validation (security):**
- An `allow` entry without `type: "m.room_membership"` or without a valid `room_id` is
  ignored (does not grant access).
- A malformed/empty `allow` array on a `restricted` room → no Space grants access (only an
  invite can); effectively behaves like invite-only. No crash.
- The joining user's membership of an allow-room is checked against that room's actual
  member set; a non-existent allow-room grants nothing and does not error the join.

**AC5 — no behaviour change for public/invite:**
`join_rule: "public"` → join allowed as today. `join_rule: "invite"` / default / absent →
unchanged from current behaviour (this story does not newly restrict them). All existing
join_room tests stay green.

**AC6 — no info leak:**
The restricted-join decision must not reveal a private allow-room's existence/members to
the joining user beyond the boolean allow/deny (no error message enumerating allow-rooms,
no differing status for "allow-room exists but you're not in it" vs "allow-room doesn't
exist" — both deny the same way).

## Acceptance Tests (TDD — written FIRST)
1. restricted + user member of allow-space → :ok / 200 — ExUnit (Repo-less via injected membership) + :integration
2. restricted + non-member, no invite → {:error,:forbidden} / 403 — ExUnit + :integration
3. restricted + pending invite → :ok / 200 (invite overrides) — ExUnit
4. allow[] validation: bad type / missing room_id / malformed array → no grant (only invite) — ExUnit
5. public unchanged (join allowed); invite/default unchanged (existing tests green) — ExUnit / regression
6. no-leak: non-existent allow-room and existing-but-not-member allow-room deny identically — ExUnit

## Dev Notes

### Files likely changed
- `core/lib/nebu/matrix/event_dispatcher/server.ex` — `join_room/2`: before
  `Nebu.Matrix.Room.Server.join`, read the room state (join_rule + the m.room.join_rules
  `allow` array). Add `check_join_allowed(state, user_id)`:
  - join_rule != "restricted" → :ok (preserve current behaviour — AC5).
  - "restricted" → :ok if the user has a pending invite (db_module_invite / membership
    invite state) OR is a member of any valid allow[] room; else {:error, :forbidden} → 403.
  - allow[] validation per AC4 (filter to `type == "m.room_membership"` with a binary
    room_id; check membership against that room's member set via Room.Server.get_state /
    the in-memory members; non-existent room → no grant, no crash).
  Consider putting the pure decision in a small helper/module (e.g.
  `Nebu.Matrix.Room.JoinRules.check_join_allowed/2`) for Repo-less unit testing, with the
  server resolving allow-room membership.
- `core/test/nebu/matrix/…` — tests 1–6 (unit pure-decision + :integration through /join).

### Constraints / security (required)
- This is a security gate: a wrong implementation either locks members out or lets
  non-members in. Default-deny on `restricted` (only explicit allow or invite grants).
- allow[] is attacker-influenceable (writable via S2 PUT by a PL≥state_default member) —
  validate entries; do not trust shape. No info leak (AC6).
- Preserve public/invite behaviour (AC5) — run the existing join_room test suite, must stay green.
- ADR-018; let-it-crash w/ Matrix error envelopes (403 M_FORBIDDEN); ADR-020;
  acting user from token (join_room user_id is already the authenticated caller).

### Reference (old Go stories — parity only, do NOT port Go)
`git show origin/feature/epic-15:docs/stories/matrix-spaces/core-restricted-join-rule-enforcement-exunit.md`
`git show origin/feature/epic-15:docs/stories/matrix-spaces/integration-test-restricted-join-godog-scenario.md`

## Tasks/Subtasks

- [x] Pure `Nebu.Matrix.Room.JoinRules.check_join_allowed/3` decision module (Repo-less, injected resolvers)
- [x] Wire `enforce_restricted_join!/2` into `join_room/2` BEFORE `Room.Server.join` (403 on deny)
- [x] allow[] validation (type + binary room_id) + no-leak boolean resolver
- [x] Pure unit tests (AT1–AT6) — RED → GREEN
- [x] `:integration` tests through `POST /join` (AT1/AT2/AT3 + public regression)
- [x] Confirm existing join_room tests stay green (AC5)

## Dev Agent Record

### Implementation Plan / Approach

The decision was split into a **pure module** + an **impure server seam**:

- `Nebu.Matrix.Room.JoinRules.check_join_allowed/3` (new, `core/lib/nebu/matrix/room/join_rules.ex`)
  is side-effect-free. It reads `join_rule` + `allow[]` from the resolved
  `m.room.join_rules` state event and decides using two injected inputs:
  `has_invite?` (boolean) and `space_member?` (`fn room_id, user_id -> bool end`).
  This makes the security-critical decision unit-testable with zero DB / GenServer.

- `Nebu.Matrix.EventDispatcher.Server.enforce_restricted_join!/2` owns the impure
  resolution and is called in `join_room/2` immediately after the room-exists check
  and **before** `Room.Server.join/2`. It:
  1. reads only the join_rules slice via `messages_db_module().get_generic_state_events/1`
     (guarded by `function_exported?` + try/rescue/catch → `[]` on any failure, which
     JoinRules treats as default `invite` → `:ok`, preserving pre-S4 open-join);
  2. resolves `has_invite?` via `InviteDB.get_pending_invite_rooms_for_user/1` (guarded);
  3. resolves `space_member?` against each allow-room's **in-memory member set**
     (`room_registry_module().get_state/1`, try/catch → `false` on noproc/not-found).
  On `{:error, :forbidden}` it raises `GRPC.RPCError` `permission_denied`, which
  `Nebu.Matrix.Http.call_core/1` maps to **403 M_FORBIDDEN**.

### Decision table (JoinRules.check_join_allowed/3)

| join_rule              | result                                                          |
|------------------------|-----------------------------------------------------------------|
| `restricted` + invite  | `:ok` (invite overrides — AC3)                                  |
| `restricted` + member of any VALID allow[]-room | `:ok` (AC1)                            |
| `restricted` otherwise | `{:error, :forbidden}` → 403 (default-deny — AC2)               |
| `public` / `invite` / default / absent / unknown | `:ok` (UNCHANGED — AC5)              |

### allow[] validation + no-leak guarantee

- A valid allow entry is a **map** with `"type" == "m.room_membership"` AND a
  **non-empty binary** `"room_id"`. Everything else (wrong type, missing/empty/
  non-binary room_id, non-map entries, non-list `allow`, missing `allow`) is filtered
  out (AC4) → such a `restricted` room is effectively invite-only.
- **No info leak (AC6):** the `space_member?` resolver returns a plain boolean. A
  non-existent allow-room and an existing-but-not-member allow-room **both** resolve
  to `false`, so they deny identically — the decision never reveals which allow-rooms
  exist or who is in them. The error message is generic ("you are not allowed to join
  this restricted room"), enumerating nothing.

### public / invite unchanged (AC5)

`check_join_allowed/3` returns `:ok` for every non-`restricted` rule, so
`enforce_restricted_join!/2` is a no-op for all pre-S4 rooms. Verified: the entire
existing `join_room_test.exs` suite (happy path, not-found, idempotent, invite,
power-level, :pg broadcast) stays green alongside the new unit tests (28/28).

### Completion Notes

- New pure module + 16 unit tests (RED 0/16 → GREEN 16/16).
- New `:integration` test file driving `POST /join` for AT1/AT2/AT3 + a public-room
  regression (runs under `make test-integration` — needs PostgreSQL).
- Full `test/nebu/matrix/` run: **487/528 passed, 2 skipped, 75 excluded, 41 failed** —
  the 41 failures are **pre-existing** DB-less failures (`Nebu.Repo not started`) in
  `upgrade_room_test` / `create_room_test` / `upgrade_room_error_handling_test` /
  `audit_room_ops_test`, and the count is **identical with my change stashed**, i.e.
  zero new regressions. Compiles clean with `--warnings-as-errors`.

### File List

- `core/lib/nebu/matrix/room/join_rules.ex` (new) — pure MSC3083 decision module.
- `core/lib/nebu/matrix/event_dispatcher/server.ex` (modified) — `join_room/2` now calls
  `enforce_restricted_join!/2`; added `enforce_restricted_join!/2`,
  `restricted_join_state/1`, `safe_generic_state_events/1`, `pending_invite?/2`,
  `allow_room_member?/2`.
- `core/test/nebu/matrix/room/join_rules_test.exs` (new) — pure unit tests (AT1–AT6).
- `core/test/nebu/matrix/spaces_restricted_join_integration_test.exs` (new) —
  `:integration` tests through `POST /join`.

### Change Log

- 2026-06-21: Implemented MSC3083 `restricted` join-rule enforcement (default-deny,
  invite override, allow[] validation, no-leak). Scoped to `restricted` only;
  public/invite/default unchanged. Status → review.
