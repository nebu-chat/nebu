# Test Review Report — server/test/nebu/admin/admin_oidc_login_test.exs (staged diff)

Story: provision-matrix-identity-on-admin-login (epic oidc-simplification), Step 3 pre-dev review.

## AC coverage matrix

| AC | Test(s) | Verdict |
|---|---|---|
| AC1 | `AC1: normal_callback/2 provisions...` — 3 tests | Covered |
| AC2 | `AC2: admin-only login provisioning does NOT trigger auto-join by default` — 1 test | Present but NOT falsifiable — MAJOR-1 |
| AC3 | `AC3/AC5: ...` describe, first test | Covered (integration-tagged) |
| AC4 | folded into AC5-titled test | Covered — MINOR-1 |
| AC5 | same test as above | Covered |

## MAJOR-1 — AC2 "no auto-join" test is structurally vacuous; cannot fail even if dev wires auto-join in

`FakeMessagesDB_AutoJoinRoom_AdminLogin` is installed via `Application.put_env(:event_dispatcher, :messages_db_module, ...)`.
`ensure_auto_join_memberships/1` uses this only for `list_auto_join_rooms/0`. The actual membership
WRITE happens via `Nebu.Matrix.Room.Server.join/2` (a real GenServer via Horde), whose own
`insert_member` call reads a DIFFERENT config key: `Application.get_env(:room_manager, :db_module, ...)`
(`room/server.ex:49`). The test never sets `:room_manager, :db_module`, and in the plain unit run
`Room.Server`/Horde isn't actually joinable — `join/2` fails with `{:error, :noproc}`, silently
swallowed by `ensure_auto_join_memberships/1` (same known constraint documented in
`auto_join_rooms_test.exs:192-194`).

Net effect: no code path can ever deliver `{:insert_member_called}` to `:admin_auto_join_test_listener`,
regardless of correct or incorrect AC2 implementation. `refute_received` passes either way — zero
signal on the one architecture decision the story explicitly calls out as needing to be tested.

**Fix options:**
(a) stub `:room_manager, :db_module` too, with a fake that notifies on `insert_member`, and ensure
`Room.Server`/Horde can reach the success branch — OR
(b) assert at a lower boundary: spy directly on the provisioning entry point (e.g.
`run_post_login_provisioning/2`) and assert it is NOT invoked at all for admin-only logins (if AC1's
recommendation is "provision the users row without going through the full pipeline").

Option (b) is simpler and more robust (doesn't depend on Horde/GenServer plumbing in unit tests).

## MINOR-2 — AC4 has no dedicated test; folded into AC5-titled test (naming/traceability only, not a coverage gap)

## MINOR-3 — AC4's "no overwritten profile data" (DoD wording) is not asserted, only row-count + no-error

## INFO
- Process.sleep(200) hard wait — consistent with existing codebase convention (auto_join_rooms_test.exs), not new smell.
- ADR-020 facade boundary not structurally enforced by these dynamic tests — expected, deferred to Step 6 (code-review) / Step 7 (Kassandra) per test-review scope.
- Matrix /login 403 M_FORBIDDEN / 400 M_NOT_JSON regression contract correctly pinned, deterministic assertions.
- No GenServer crash/restart test — correctly, none needed (pure DB-upsert + HTTP callback, no new GenServer state).

## Recommendation
Fix MAJOR-1 before Step 4 (dev-story) — via option (b): spy/assert directly on the provisioning
entry point rather than the multi-hop Room.Server/Horde side effect that cannot be reached in the
unit-test environment.

## Resolution (user-approved: fix all before dev-story)

- MAJOR-1: fixed. `FakeMessagesDB_AutoJoinRoom_AdminLogin.list_auto_join_rooms/0` now sends
  `{:list_auto_join_rooms_called}` — the first, Horde-independent call
  `ensure_auto_join_memberships/1` makes. Test now asserts `refute_received
  {:list_auto_join_rooms_called}`. This IS falsifiable: a dev implementation that (incorrectly)
  wires `run_post_login_provisioning/2` into the admin login path reaches this call and fails the
  test.
- MINOR-2: fixed. Split the single "AC5"-titled test into two independently named tests: "AC4: a
  real Matrix login after admin-only provisioning does not error, does not duplicate, and does not
  clobber profile data..." and "AC5: admin-only login without a prior Matrix login makes the
  operator visible in GET /admin/users".
- MINOR-3: fixed. Added an assertion in the new AC4 test that a user-set displayname
  (`Nebu.Matrix.Profile.DB.upsert_profile/3`) survives a subsequent Matrix-login provisioning touch
  that carries no displayname of its own — verifies the `COALESCE(EXCLUDED.displayname,
  profiles.displayname)` nil-safe upsert contract end-to-end.

Verified via containerized `mix test test/nebu/admin/admin_oidc_login_test.exs --exclude
integration`: 23/26 passed, 3 failed (exactly the AC1 RED tests, unchanged), 0 collateral
regressions, no compile errors.
