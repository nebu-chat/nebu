---
story_id: room-keys-version-post-stub
title: "Element Web first login ends in 'Unable to set up keys': restore the POST /room_keys/version acceptance stub the Go gateway had"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-15
branch: feature/migrate-to-oauth2
---

# Story: `POST /_matrix/client/v3/room_keys/version` must answer, otherwise a fresh Element Web user sees "Unable to set up keys"

Found while building the e2e CI job (task 3 of the 2026-10-15 CI run): 34 of the 76 failing e2e scenarios fail because the Element login
helper (`loginViaOidcBrowser`) sees the dialog "Setting up keys / Unable to set up keys" on the FIRST login of a user and the Matrix users
alex / marie / kai are never provisioned.

## Root cause (verified against the isolated stack, 2026-10-15)

Element Web 1.12.15 (`InitialCryptoSetupDialog`) bootstraps cross-signing for a user without a cross-signing identity
(`POST /keys/device_signing/upload`, `POST /keys/signatures/upload`: both answer 200) and then creates a key backup:
`POST /_matrix/client/v3/room_keys/version`. Nebu never had that route in Elixir: the Go gateway had a stub
(`POST ... -> {"version":"1"}`, commit message: "prevents the 'Unable to set up keys' error dialog from appearing") that was dropped
by commit 6f94c20c (Go -> Elixir migration; `docs/matrix-api-scope.md` still claims it). On `origin/main` the route falls through to the
generic 404 `M_NOT_FOUND "Unrecognized request"`, on this branch to the spec `405 M_UNRECOGNIZED "Unsupported method"` (story
oauth-room-summary-unrecognized): BOTH make Element fail, so this is a pre-existing gap of `main`, NOT a regression of the OAuth work and
NOT a fault of the e2e setup. The cross-signing keys ARE stored before the failure, so the second login of the same user shows only the
skippable "Confirm your digital identity" screen: that is why the problem is only seen for a user's first login. Proof: a Playwright
interception answering the POST with `200 {"version":"1"}` lets a fresh user (alice) reach the room list with no dialog.

## Decisions

- **D1.** `POST /_matrix/client/v3/room_keys/version` (authenticated like the existing `GET`, same router, same auth pipeline, same body size
  limit as the other JSON POST routes) answers `200 {"version":"1"}` and STORES NOTHING: Nebu has no server-side key backup
  (ADR-011: no E2EE rooms; `docs/architecture/07-deployment.md` says so) and the claim is documentation compatible
  (`docs/matrix-api-scope.md`: "Returns version: 1 (not stored)").
- **D2.** `GET /room_keys/version` stays `404 M_NOT_FOUND "No backup found"` (no backup exists to read), so a client that creates a version and then reads it back
  sees "no backup" again and simply carries on (verified: Element does).
- **D3.** Every other `room_keys/*` route (keys PUT/GET/DELETE, `version/:v`) stays unimplemented (`M_UNRECOGNIZED`): there are no room keys to back up.
  The unauthenticated POST answers like every other unauthenticated protected route (`401 M_MISSING_TOKEN`), no information leak.
- **D5 (body).** The stub ignores the request body entirely (nothing is stored): an empty, malformed or oversized-within-the-global-limit body still answers `200 {"version":"1"}`;
  the 1 MB cap is the global `JsonBody` plug's, not the handler's.
- **D4.** A repeated POST answers the same `{"version":"1"}` again (idempotent, stateless stub: no extra rate limit tier (authenticated, no DB, no body read)).

## Acceptance Criteria

1. `POST /_matrix/client/v3/room_keys/version` with a valid Bearer token and a JSON body (`{"algorithm":"m.megolm_backup.v1.curve25519-aes-sha2","auth_data":{...}}`)
   answers `200` with exactly `{"version":"1"}`; nothing is written to the database (no new rows in any table).
2. The same request without credentials answers `401 M_MISSING_TOKEN`, with a bad token `401 M_UNKNOWN_TOKEN`, as the GET does.
3. `GET /room_keys/version` still answers `404 M_NOT_FOUND "No backup found"` (also after a POST).
4. `PUT /room_keys/keys` and `DELETE /room_keys/version/1` still answer `M_UNRECOGNIZED` (the stub is exactly one route).
5. The route enumeration / unrecognized-route tests and `docs/matrix-api-scope.md` agree with the new route (the table row exists already and now states the truth).
6. The e2e login helper provisions a fresh user (global-setup warms alex / marie / kai without the "Unable to set up keys" error) against the real stack: verified in the e2e CI job validation run.

## Acceptance Tests

- ExUnit `Plug.Test` in `matrix_client_compat_test.exs`: POST with token -> 200 `{"version":"1"}` (AC1), no token / bad token (AC2), GET unchanged after POST (AC3), a row-count assertion over
  the relevant tables or a `Repo`-free proof that the handler touches no DB (AC1).
- `unrecognized_routes_test.exs` / `_integration_test.exs`: `PUT /room_keys/keys` and `DELETE /room_keys/version/1` stay `M_UNRECOGNIZED`; the route enumeration includes the new `{:post, ...}`.
- e2e: `e2e/features/element/login.feature` already exercises the first login of a fresh user (no new scenario needed; the global-setup guard `assertNoKeySetupError` is the oracle).
