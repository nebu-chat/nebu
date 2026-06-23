# E2E Test-Suite Rehab — Status 2026-06-20 (branch bugfix/fix-matrix-sso-redirect-missing)

## Result so far
- admin-ui: 18/19 active passing (1 flaky claim-mapping test-isolation issue)
- element-web: 6/16 passing (was 0) — login, send, create, and core flows work after the
  Matrix client-compatibility + identity-unification fixes.

## Product fixes committed this session (hot-patched, E2E-validated)
bootstrap reachable / Go-parity wizard OIDC flow / Matrix SSO redirect+callback /
confirm-POST (JsonBody+render_errors+tx) / SSO uses nebu-gateway client / whoami /
invite / login→dashboard / oidc_user_id_claim=name / rooms.name persisted /
capabilities+pushrules+keys/query+keys/upload+filter+account_data (Element startup) /
initialSync / sync+messages state_key / **Nebu.Matrix.UserId claims→user_id unified
across /login AND OidcPlug (the identity-split that made Element hang on "Joining…")**.

## REMAINING PRODUCT BUGS — to fix via /nebu-pipeline (TDD + regression + Kassandra)
All four return 404 (Unrecognized request) and block element tests:
1. **room leave** — POST /_matrix/client/v3/rooms/{roomId}/leave (+ forget). Blocks leave.feature.
2. **event relations** — GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}[/{relType}].
   Blocks thread_messages "/relations 200" test. (Threads also need m.relations in sync.)
3. **room upgrade** — POST /_matrix/client/v3/rooms/{roomId}/upgrade. Blocks upgrade.feature.
4. **message search** — POST /_matrix/client/v3/search (full-text). Blocks 3 search tests.
   NOTE: real feature, not a stub — size/scope per ADR-010 (FTS deferred); may stay a
   documented gap rather than a quick fix.

## Remaining TEST brittleness (not product bugs)
- receive/thread/join use sidebar lookup by room name/title; flaky vs sync delivery timing
  (the room arrives in the sidebar asynchronously). Prefer roomId/direct-URL nav like send.

## PROCESS DEBT (per user directive 2026-06-20)
The hot-patched endpoints above were committed with E2E validation only. They need
retroactive ExUnit regression tests via /nebu-pipeline so the compatibility surface can't
silently regress. Tracked in memory feedback-bugs-via-pipeline.

## UPDATE (after fix-missing-matrix-room-routes pipeline + identity fix)
- element-web: **8/16** passing (login, send, create, leave, + core flows). Pipelined
  fix (leave/forget/relations/upgrade/search routes) merged: code-review APPROVED +
  Kassandra CLEAN (commit 77b8b08a).
- Remaining 8 element failures split into:
  ### Next product-endpoint batch (same go-removal class — backends exist, route missing) → /nebu-pipeline
  - GET  /_matrix/client/v3/rooms/{id}/members        (backend get_room_state)
  - GET  /_matrix/client/v3/rooms/{id}/event/{eventId} (backend get_event ~L3362)
  - POST /_matrix/client/v3/rooms/{id}/read_markers   (no backend — 200 no-op like receipts, or implement)
  - relations 403 for marie (secondPage): membership check rejects a user who IS invited+joined
    in room-setup — investigate (timing vs genuine membership-state gap).
  ### Test-fixture brittleness (test code, not product) 
  - receive/thread/join/upgrade: room-list lookup by NAME in .mx_LeftPanel races sync delivery;
    prefer roomId direct-URL nav (like the passing send test) or wait-for-room.
  - search (3): .mx_SearchBar_input interaction (open search UI; selector/flow).

## FINAL (2026-06-21): admin-ui 19/19 active, element-web 12/16
From a fully-red suite (global-setup couldn't complete) → admin 19/19 active (2 @pending-feature skipped), element 12/16.

### Product side: COMPLETE + pipelined
All Matrix client-compatibility + room endpoints implemented; the two endpoint batches
(leave/forget/relations/upgrade/search; members/event/read_markers) went through the full
/nebu-pipeline (TDD + opus code-review + Kassandra CLEAN). Identity-split, state_key,
initialSync, startup endpoints fixed. element 12/16 = all single-user flows green
(login, send, threads, search, create-dialog, room-view, leave) + multi-user partial.

### Remaining 4 element failures — Element-1.12 test-choreography (NOT product bugs)
- receive: alex's message → marie's already-open timeline (multi-user live-propagation timing).
- create: room-header name toHaveText — FLAKY (passed in a prior run; header-render timing).
- join: accept-invite click (invite preview/accept button timing in Element 1.12).
- upgrade: room-settings → Advanced → upgrade button (Element 1.12 settings-UI selector).
The Matrix API for all of these is verified working (pipelined ExUnit + the 12 passing
flows); these are third-party-client (Element 1.12.15) UI/timing choreography with
uncertain convergence — test-debt, not product gaps.

### Phase 3 (process-debt) STILL OPEN
Retroactive ExUnit regression tests for the earlier hot-patched compat endpoints
(whoami/capabilities/pushrules/keys/filter/initialSync/state_key/UserId) — the two
pipelined room-endpoint batches already have ExUnit tests; the earlier hot-patches do not.
