---
epic: room-naming-and-default-rooms
story: rate-limit-isolation
status: review
security_review: not-needed
priority: P0
created: 2026-05-30
baseline_commit: 0ef98d02
---

# Story: Fix Rate Limit Failures in Auto-Join Integration Tests

## Summary

The `make test-integration` run fails on all 6 auto-join scenarios with HTTP
429 `M_LIMIT_EXCEEDED` — not with assertion failures but with rate-limit
rejections before login even completes. The root cause is that
`charlie@example.com` (UID `000...009`) and `alice@example.com` (UID `000...007`)
are shared across `direct_room_heroes.feature`, `personal_self_room.feature`,
and `auto_join_rooms.feature`. By the time Godog alphabetically reaches
`auto_join_rooms.feature`, those users have already consumed enough login
attempts to trip the IP/user-based rate limiter.

The fix: add two dedicated Dex users (`carol` and `anna`) used **only** by the
auto-join scenarios, and update the step definitions and feature file assertions
to use these users instead of `charlie` and `alice`.

---

## User Story

As a developer on the Nebu project,
I want the auto-join integration tests to pass without rate-limit interference,
So that `make test-integration` is green and the CI pipeline can close the
`room-naming-and-default-rooms` epic cleanly.

---

## Acceptance Criteria

### AC1 — Two new Dex users added (`carol`, `anna`)

`dev/dex/config.yaml` contains two new `staticPasswords` entries:

- `carol@example.com` / `changeme` / userID `00000000-0000-0000-0000-000000000010` / username `carol` / group `user`
- `anna@example.com` / `changeme` / userID `00000000-0000-0000-0000-000000000011` / username `anna` / group `user`

### AC2 — Auto-join step definitions use carol and anna

`gateway/test/integration/auto_join_rooms_steps_test.go` uses:
- `carol@example.com` everywhere `charlie@example.com` appeared
- `anna@example.com` everywhere `alice@example.com` appeared (in auto-join context)

The Matrix user IDs used in assertions become `@carol:nebu.local` and
`@anna:nebu.local`.

### AC3 — Feature file assertions updated for carol

`gateway/features/auto_join_rooms.feature` — the final Oracle-edge scenario
asserts `state_key "@carol:nebu.local"` instead of `"@charlie:nebu.local"`.
No other scenario text needs changing (the step text describes roles, not user
names).

### AC4 — `make test-integration` passes all 6 auto-join scenarios

All six scenarios in `auto_join_rooms.feature` (AC3–AC6, Oracle edge ×2) pass
without any 429 error. Other test groups (`direct_room_heroes`,
`personal_self_room`) continue to pass unchanged.

---

## Acceptance Tests

### Tests written FIRST (before implementation code):

No new test files are written for this story — it is a pure bug-fix to the Dex
config and step definitions. The existing 6 failing scenarios in
`gateway/features/auto_join_rooms.feature` are the acceptance tests. They must
transition from FAIL (429) to PASS.

Validation:
```
make test-integration
# expected: all 6 auto_join_rooms scenarios show "passed" or "skipped"
# forbidden: any scenario shows "429" or "M_LIMIT_EXCEEDED"
```

---

## Dev Notes

### Root Cause — Precise Diagnosis

Godog loads feature files in alphabetical order: `auto_join_rooms.feature`
comes before `direct_room_heroes.feature` and `personal_self_room.feature` —
but all step files in the same package are compiled together. Scenarios run
sequentially in one binary. By the time Godog gets to the 6 auto-join
scenarios, `charlie@example.com` (userID `000...009`) and `alice@example.com`
(userID `000...007`) have already been logged in multiple times by other
scenario groups in the **same test run**. The gateway's IP/user-based rate
limiter accumulates these hits and rejects subsequent logins with 429.

### Fix Strategy

Use fresh Dex users that are never touched by any other step file.
Naming convention chosen (`carol`, `anna`) to avoid alphabetic collision with
existing users and to be clearly distinct.

### File 1 — `dev/dex/config.yaml`

Append two new entries to `staticPasswords`. Use the **same bcrypt hash** as
all other users (password `changeme`):

```
$2a$10$E4ye88CWSgoigClMVojmGOu.gHlKe7L7RRf07QWZ60aZmZ7Rfak/6
```

New user block to append after the existing charlie entry:

```yaml
  # Story rate-limit-isolation: dedicated users for auto-join integration tests
  - email: "carol@example.com"
    hash: "$2a$10$E4ye88CWSgoigClMVojmGOu.gHlKe7L7RRf07QWZ60aZmZ7Rfak/6"
    username: "carol"
    userID: "00000000-0000-0000-0000-000000000010"
    groups:
      - user

  - email: "anna@example.com"
    hash: "$2a$10$E4ye88CWSgoigClMVojmGOu.gHlKe7L7RRf07QWZ60aZmZ7Rfak/6"
    username: "anna"
    userID: "00000000-0000-0000-0000-000000000011"
    groups:
      - user
```

Dex reads `config.yaml` at startup. After editing, run `make redeploy` (not
`make build-gateway`) to restart all containers and pick up the new config.

### File 2 — `gateway/test/integration/auto_join_rooms_steps_test.go`

This is the primary code change. Apply these substitutions:

**In `aliceIsAlreadyMemberOfRoom`:**
- Change `authenticateUser("alice@example.com", ...)` → `authenticateUser("anna@example.com", ...)`

**In `charlieIsPreInvitedToRoom`:**
- Change `authenticateUser("alice@example.com", ...)` → `authenticateUser("anna@example.com", ...)`
- Change hardcoded string `"@charlie:nebu.local"` → `"@carol:nebu.local"` (in the invite body)

**In `charlieLogsInViaOIDCAutoJoin`:**
- Change `iObtainDexTokenFor("charlie@example.com", ...)` → `iObtainDexTokenFor("carol@example.com", ...)`

**Variable naming:** The existing package-level vars (`charlieAutoJoinAccessToken`,
`charlieAutoJoinUserID`, `aliceAutoJoinAccessToken`, `aliceAutoJoinUserID`) can
keep their names — they are local to this file and do not affect external callers.
The important thing is that the **email addresses** used in `authenticateUser` and
`iObtainDexTokenFor` calls change to carol/anna.

**The bridge line must stay:**
```go
charlieAccessToken = charlieAutoJoinAccessToken // bridge for shared step handler
```
This line keeps `charlieCallsGetSyncTimeout0` (defined in
`direct_room_heroes_steps_test.go`, registered for step `^charlie calls GET /sync
with timeout 0$`) working correctly. That function reads `charlieAccessToken`.
After the fix, `charlieAccessToken` is bridged from carol's login token —
correct, because carol is the new "charlie-role" user for auto-join scenarios.

**State-key references:** Any hardcoded `"@charlie:nebu.local"` inside assertion
helper functions (`charliesMemberEventHasStateKey`, fallback values in
`charlieHasExactlyOneMembershipEventInRoom`, etc.) must change to
`"@carol:nebu.local"`.

Full set of string replacements needed:
```
"charlie@example.com"   →  "carol@example.com"   (2 occurrences in charlieLogsInViaOIDCAutoJoin and charlieIsPreInvitedToRoom)
"alice@example.com"     →  "anna@example.com"    (2 occurrences in aliceIsAlreadyMemberOfRoom and charlieIsPreInvitedToRoom)
"@charlie:nebu.local"   →  "@carol:nebu.local"   (3 occurrences: invite body, fallback state key, default state-key assertion)
```

### File 3 — `gateway/features/auto_join_rooms.feature`

Only the last scenario's final assertion step references a concrete Matrix user
ID:

```gherkin
And charlie's m.room.member event has state_key "@charlie:nebu.local"
```

Change to:

```gherkin
And charlie's m.room.member event has state_key "@carol:nebu.local"
```

All other step text (`charlie is a new user who has never logged in`, `charlie
logs in via OIDC`, etc.) uses the role name "charlie" not the email/Matrix ID
— those steps delegate to `charlieLogsInViaOIDCAutoJoin` which will now use
carol's credentials. No other feature file text needs changing.

### Cross-file Constraint: charlieCallsGetSyncTimeout0

`charlieCallsGetSyncTimeout0` is defined in `direct_room_heroes_steps_test.go`
(line ~262) and registered for step `^charlie calls GET /sync with timeout 0$`.
It reads `charlieAccessToken` — which is a package-level var declared in
`direct_room_heroes_steps_test.go`. The bridge in `charlieLogsInViaOIDCAutoJoin`:

```go
charlieAccessToken = charlieAutoJoinAccessToken
```

ensures that after carol logs in under the "charlie" role in auto-join tests,
`charlieCallsGetSyncTimeout0` uses carol's token. This must not be removed.

### What NOT to change

- `direct_room_heroes_steps_test.go` — still uses `charlie@example.com` for
  its own scenarios. Do not touch it.
- `personal_self_room_steps_test.go` — still uses `alice@example.com`. Do not
  touch it.
- Step text in `auto_join_rooms.feature` beyond the single `state_key` line
  mentioned above. Role names like "charlie" and "alice" are implementation-neutral
  in the Gherkin text.
- Package-level variable names (`charlieAutoJoinAccessToken`, etc.) — kept for
  clarity of existing code, only the credential strings change.

### Deployment Sequence

1. Edit `dev/dex/config.yaml` (add carol + anna entries)
2. Edit `gateway/test/integration/auto_join_rooms_steps_test.go` (swap emails and Matrix IDs)
3. Edit `gateway/features/auto_join_rooms.feature` (swap the `state_key` assertion)
4. Run `make redeploy` to restart Dex with the new users
5. Run `make test-integration` to confirm all 6 auto-join scenarios pass

### No Migration Required

Dex `staticPasswords` are loaded at container startup from the YAML file — no
DB migration needed. The Nebu PostgreSQL schema is unaffected.

### No Proto Changes

No gRPC proto changes. The fix is entirely in test infrastructure.

### Project Structure Notes

| File | Action |
|------|--------|
| `dev/dex/config.yaml` | UPDATE — append 2 staticPasswords entries |
| `gateway/test/integration/auto_join_rooms_steps_test.go` | UPDATE — swap email/Matrix-ID strings |
| `gateway/features/auto_join_rooms.feature` | UPDATE — one `state_key` assertion |

### References

- Root cause commit context: `0ef98d02` (test-coverage-gaps done)
- Failing scenarios: `auto_join_rooms.feature` lines for AC3, AC4, AC5, AC6 + 2 Oracle edge scenarios
- Rate limiter config: `gateway/internal/middleware/` (not modified)
- Dex config: `dev/dex/config.yaml`
- Step definitions: `gateway/test/integration/auto_join_rooms_steps_test.go`
- Cross-file bridge: `gateway/test/integration/direct_room_heroes_steps_test.go` lines ~259–283
- `charlieCallsGetSyncTimeout0` reads `charlieAccessToken` (declared in `direct_room_heroes_steps_test.go:56`)

---

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

No blocking issues encountered. All changes were straightforward string substitutions as specified in the story Dev Notes.

### Completion Notes List

- AC1: Added carol (userID 000...0010) and anna (userID 000...0011) to `dev/dex/config.yaml` staticPasswords using the same bcrypt hash as all other users.
- AC2: Updated `auto_join_rooms_steps_test.go` — replaced `charlie@example.com` with `carol@example.com` in `charlieLogsInViaOIDCAutoJoin` and `charlieIsPreInvitedToRoom`; replaced both `alice@example.com` occurrences with `anna@example.com`; replaced all three `@charlie:nebu.local` Matrix ID occurrences with `@carol:nebu.local` (invite body and two fallback state key strings).
- AC3: Updated `auto_join_rooms.feature` last Oracle scenario assertion from `@charlie:nebu.local` to `@carol:nebu.local`.
- AC4: `make test-unit-go` passed all 28 packages without compilation errors. `make redeploy` + `make test-integration` required to fully validate AC4 (needs running stack with new Dex users).
- Bridge line `charlieAccessToken = charlieAutoJoinAccessToken` preserved as required.
- `direct_room_heroes_steps_test.go` and `personal_self_room_steps_test.go` untouched — they continue to use charlie/alice for their own scenarios.

### File List

- dev/dex/config.yaml
- gateway/test/integration/auto_join_rooms_steps_test.go
- gateway/features/auto_join_rooms.feature
- docs/stories/room-naming-and-default-rooms/rate-limit-isolation.md
