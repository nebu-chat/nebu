# Regression Report — `elixir-stack-regression` (GATE, epic `full-elixir-stack`)

- **Date:** 2026-06-17
- **Baseline commit:** `50cbc3c04987eaaad8326a456ea913fc1aeb03e7`
- **Branch:** `feature/full-elixir-stack`
- **Story type:** TEST-ONLY (no production code under `gateway/internal/`, `core/apps/*/lib/`, `core/config` was modified)
- **Author:** Amelia (Dev)

## TL;DR

The four ATDD test files are **statically sound**: everything compiles, every Godog/Cucumber step
resolves to exactly one definition, no `@wip`/`@pending` tags on scenarios. The ExUnit load test
(AC7) compiles and is correctly `:integration`-tagged.

**Live-run metrics (Godog pass/fail, Playwright pass/fail, sync median/p95/zero-drop) could NOT be
captured in this environment** — there is no Docker / PostgreSQL / Dex / running stack here. Every
behavioural endpoint (`createRoom`, `send`, `/sync` fan-out, media, admin LiveView) requires the live
OTP supervision tree + PostgreSQL + Dex. These are **deferred to the ci-gate** against the running
stack (`make test-integration` / `make test-integration-elixir` / `make test-e2e-admin`).

**Two genuine behavioural divergences surfaced while validating the assertions** (details in
§"Parity findings"):
- **GENUINE REGRESSION (BLOCKER candidate):** `PUT .../send/...` with a **malformed JSON body** —
  Go gateway returns `400 M_BAD_JSON`; migrated Elixir handler returns **`200 {event_id}`**.
- **INTENTIONAL divergence (NOT a regression):** `PUT .../typing` with `typing:true` and no timeout —
  Go gateway returns `200` (lenient), Elixir returns `400 M_BAD_JSON` (spec-correct, deliberately
  implemented + tested in `matrix-api-migration`). Only red if the suite targets the Go gateway.

---

## What was verified statically (here, no Docker)

| Check | Command | Result |
|---|---|---|
| Core compiles, no warnings | `cd core && MIX_ENV=test mix compile --warnings-as-errors` | **PASS** (`mix compile: ok`) |
| Default Elixir unit suite (no regressions) | `cd core && mix test apps/nebu_http/test/` | **78 passed, 30 excluded** (`:integration`) |
| Load test compiles + is excluded by default | (part of suite above) | **PASS** — `regression_sync_load_test.exs` in the 30 excluded |
| Go integration step defs compile/vet | `cd gateway && go vet -tags integration ./test/integration/` | **PASS** (`No issues found`) |
| Playwright-bdd: every step resolves | `cd e2e && npx bddgen` | **`ok`** — no undefined/ambiguous steps; both regression scenarios generated |
| TypeScript type-check of new e2e step | `cd e2e && tsc --noEmit` | **PASS** (no errors in regression step file) |
| No `@wip`/`@pending` on regression scenarios | grep | **PASS** (only a code comment mentions `@wip`) |
| No duplicate step registrations (Godog Strict) | grep, manual | **PASS** — every new step exactly one definition; reused steps each have one anchored definition |

### Why the live behaviour cannot run here

`createRoom`, `join`, `send` and the `/sync` long-poll all flow through
`Nebu.EventDispatcher.Server` → Horde room registry / `Nebu.Room.Server` → **PostgreSQL** (append-only
event log) and `:pg` process groups. With no DB reachable (`pg_isready` → no response on `:5432`),
`createRoom` returns `500 M_UNKNOWN`. This is identical for the pre-existing, already-green
`sync_concurrent_test.exs` — both load tests are pure-`Plug.Test` at the HTTP layer but still need the
full live OTP tree + DB underneath. They are therefore `:integration`-tagged and run only under
`make test-integration-elixir` against `docker compose up`.

---

## Suite composition (scenario inventory + what each asserts)

### 1. `gateway/features/elixir-regression-matrix.feature` (Godog, `-tags integration`)

Steps for the new phrasings live in `gateway/test/integration/elixir_regression_steps_test.go`
(`initializeElixirRegressionSteps`, wired in `steps_test.go`). Reused steps come from
`room_flow_steps_test.go` / `steps_test.go` / `auth_steps_test.go` / `matrix_session_refresh_steps_test.go`.

| Scenario | Asserts | Notes |
|---|---|---|
| `ElixirRegression_FullJourney` (AC1) | login → createRoom(200,`room_id`) → invite(200) → join(200) → capture since-token → send(200,`event_id`) → **no step returned 501** → long-poll sync sees event in `rooms.join[].timeline` → POST receipt(200) → typing-true+timeout(200) → typing-false(200) → sync sees `m.receipt` in `rooms.join[].ephemeral` AND **not** in timeline → logout(200) → same token now `401` | The 501-tracker + `room_id`/`event_id` body asserts make any unmigrated endpoint a CI-blocking failure |
| `ElixirRegression_Login_Success` (AC1/Oracle) | login w/ Dex token → 200 + `access_token`,`device_id`,`user_id` | |
| `ElixirRegression_Login_MissingType` (Oracle, **MINOR-2 tightened**) | login body w/o `type` → `400` **`M_UNKNOWN`** | Errcode confirmed identical on BOTH stacks (Go `login.go:193`, Elixir `matrix_public.ex` `do_login_with/2`). Spec-ideal would be `M_BAD_JSON`/`M_MISSING_PARAM`; parity reality is `M_UNKNOWN` (parity > spec-ideal). |
| `ElixirRegression_Login_BadToken` (Oracle) | invalid login token → `403` `M_FORBIDDEN` | Parity-confirmed (Go `login.go:219`, Elixir) |
| `ElixirRegression_Send_Idempotent` (Oracle) | same `txnId` → same `event_id`; message appears exactly once on `/messages` | |
| `ElixirRegression_Send_BadJson` (Oracle/parity, **MINOR-2 repointed — SURFACES A REGRESSION**) | malformed (non-JSON) send body → `400` **`M_BAD_JSON`** | See §Parity findings #1. Was `ElixirRegression_Send_MissingMsgtype` asserting `400 + errcode` on a *well-formed body missing msgtype* — a spec-ideal NEITHER stack implements. Repointed to the genuine shared 400 contract (malformed JSON), which the Go gateway honoured and the Elixir handler does **not** (regression). |
| `ElixirRegression_Typing_RequiresTimeout` (Oracle, **MINOR-2 tightened**) | typing-true w/o timeout → `400` **`M_BAD_JSON`** | Errcode confirmed at `protected.ex:250`. Matches the **intended** Elixir behaviour (see §Parity findings #2). Green only when targeting `core:4000`. |
| `ElixirRegression_Auth_MissingToken` (AC5/Oracle) | protected `/sync` w/o token → `401` `M_MISSING_TOKEN` | Errcode pinned |

### 2. `gateway/features/elixir-regression-media.feature` (Godog, `-tags integration`)

Steps in `gateway/test/integration/elixir_regression_media_steps_test.go`
(`initializeElixirRegressionMediaSteps`, wired in `steps_test.go`). Auth = raw Dex id_token
(Authorization Code + PKCE) as Bearer — Elixir `OidcPlug` validates directly (AC5), no cookie forging.

| Scenario | Asserts |
|---|---|
| `ElixirRegressionMedia_RoundTrip` (AC2) | upload deterministic ~600-byte JPEG fixture → 200 + `content_uri` `mxc://…`; download → 200; **SHA-256(downloaded) == SHA-256(uploaded)**; `Content-Type: image/jpeg` |
| `ElixirRegressionMedia_Range` (AC2 parity, not a Matrix MUST) | `Range: bytes=0-99` → `206`, `Content-Length: 100`, slice == first 100 bytes of upload |
| `ElixirRegressionMedia_Preview` (AC4) | `GET /preview_url?url=https://example.com` → 200, JSON contains `og:title` AND `og:description` |
| `ElixirRegressionMedia_AccessControl` (AC2/AC5) | non-member (fresh Dex token for `alex`) download → `403` `M_FORBIDDEN` |

### 3. `e2e/features/admin/elixir-regression-admin.feature` (playwright-bdd + Cucumber, real browser)

New step in `e2e/step-definitions/admin/elixir-regression-admin.steps.ts` (one only). All login,
navigation, room-toggle and user-list steps reused from `admin-ui-liveview.steps.ts` /
`bootstrap.steps.ts` / `users.steps.ts` / `auto-join-rooms.steps.ts` / `stack-health.steps.ts`.
Login via real Dex OIDC (Authorization Code + PKCE) — no cookie forging, no DB seeding.

| Scenario | Asserts |
|---|---|
| `[AC3] Room Management auto-join toggle persists` | navigate to LiveView room detail → click auto-join toggle → toggle shows enabled **without full page reload** (LiveView DOM-diff) → page reload still shows enabled (DB-persisted) |
| `[AC3] User Overview shows the imported user count` | navigate `/admin/users` → page shows "Users" → user list ≥ 1 entry → **displayed user count matches rendered user rows** |

### 4. `core/apps/nebu_http/test/nebu_http/regression_sync_load_test.exs` (ExUnit, `:integration`)

- 200 distinct OIDC-subject clients, each its own bearer + provisioned row, all joined to one room.
- 50 measurement rounds; each round: capture per-client since-token → spawn 200 long-poll `/sync`
  tasks → record `t0 = System.monotonic_time` and send ONE message → `Task.await` each → latency =
  `t_received - t0`. No `Process.sleep` as a synchronisation substitute; `Task.await`'s 30s budget is
  a documented failsafe, not the gate.
- Asserts **`median(latencies) <= 150ms`** AND **`total_delivered == 10_000`** (zero drops; a delivery
  counts only if the sync body actually carried the `event_id`/payload — real drop detection).
- Structurally identical to the already-passing `sync_concurrent_test.exs` (50 clients), scaled to 200.

---

## Live-run metrics — TO BE CAPTURED BY ci-gate

| Metric | Value | Status |
|---|---|---|
| Godog `elixir-regression-matrix.feature` pass/skip/fail | — | **to be captured by ci-gate** against the running stack |
| Godog `elixir-regression-media.feature` pass/skip/fail | — | **to be captured by ci-gate** |
| Playwright `elixir-regression-admin.feature` pass/skip/fail | — | **to be captured by ci-gate** |
| Sync load median latency | — | **to be captured by ci-gate** (`make test-integration-elixir`) |
| Sync load p95 latency | — | **to be captured by ci-gate** |
| Sync zero-drop (10,000 deliveries) | — | **to be captured by ci-gate** |

### How the ci-gate runs them

```bash
# Godog (Matrix + media) + Elixir integration (incl. the AC7 load test), full stack:
make test-integration

# Elixir integration only (the AC7 load test prints median/p95 on failure; on success
# add a temporary IO.inspect or read it from the assertion message):
make test-integration-elixir

# Admin UI Playwright + Cucumber against Phoenix LiveView:
make test-e2e-admin
```

### IMPORTANT — target-URL prerequisite for a TRUE pure-Elixir-stack gate

`make test-integration` currently sets `NEBU_TEST_MATRIX_URL=http://gateway:8008` (the **Go gateway**).
This story's intent (Implementation Notes) is to validate the **pure Elixir stack**, i.e. target
`core:4000` directly. The regression findings below are **target-dependent**:

- Against **`gateway:8008`**: `ElixirRegression_Send_BadJson` passes, `ElixirRegression_Typing_RequiresTimeout` **fails** (Go returns 200).
- Against **`core:4000`**: `ElixirRegression_Send_BadJson` **fails** (regression #1), `ElixirRegression_Typing_RequiresTimeout` passes.

The ci-gate that validates this epic MUST run the regression features with
`NEBU_TEST_MATRIX_URL=http://core:4000` (per the story's Implementation Notes). I deliberately did NOT
change the production `make test-integration` target wiring (out of scope for a test-only story); the
ci-gate / pipeline must set the env. Both findings are correctly recorded here so neither is silently
swallowed by the current default target.

---

## Parity findings

### Finding #1 — GENUINE REGRESSION (BLOCKER candidate) — `PUT .../send` malformed JSON body

- **Endpoint:** `PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}`
- **Input:** a **malformed** (non-JSON) request body, e.g. `{not valid json`
- **Go gateway (expected, parity baseline):** `gateway/internal/matrix/rooms.go:534` —
  `json.NewDecoder(r.Body).Decode(&content)` fails → **`400 M_BAD_JSON`** before any gRPC call.
- **Migrated Elixir (actual):** `core/apps/nebu_http/lib/nebu_http/router/protected.ex:170` — the send
  handler takes `content = body_params(conn)`. `NebuHttp.Plugs.JsonBody` sets `body_params = %{}` and
  `assigns[:json_parse_error] = true` on a malformed body, but the send handler **does not check
  `:json_parse_error`** (unlike the login handler, `matrix_public.ex` `do_login/1`, which does). It
  forwards `Jason.encode!(%{}) == "{}"` to `Core.SendEvent` and returns **`200 {event_id}`**.
- **Classification:** **GENUINE MIGRATION REGRESSION** (Go `400 M_BAD_JSON` → Elixir `200`). NOT one of
  the intentionally-deferred-to-`go-removal-cleanup` items (those are: Go→Elixir client cutover via
  `NEBU_OIDC_VALIDATION_DISABLED`, and admin session Go-HMAC ≠ Phoenix).
- **Recommended fix (belongs in `matrix-api-migration`, NOT this test-only story):** in
  `protected.ex` send handler, mirror the login path — if `conn.assigns[:json_parse_error]`, return
  `error(conn, 400, "M_BAD_JSON", "Request body is not valid JSON")`. (Consider applying the same guard
  to the other body-reading protected handlers for full parity: createRoom, typing, receipt, profile,
  presence.)
- **Test status:** `ElixirRegression_Send_BadJson` encodes the Go-parity contract and will go **RED**
  against `core:4000` until fixed — correct GATE behaviour ("if any scenario is red, the migration has
  a gap").

### Finding #2 — INTENTIONAL divergence (NOT a regression) — `PUT .../typing` true without timeout

- **Endpoint:** `PUT /_matrix/client/v3/rooms/{roomId}/typing/{userId}` with body `{"typing":true}` (no `timeout`)
- **Go gateway:** `gateway/internal/matrix/typing.go:74-93` — `timeout` defaults to 0 and is clamped;
  no required-field check → **`200`** (lenient, non-spec).
- **Migrated Elixir:** `protected.ex:250` → **`400 M_BAD_JSON`** ("typing:true requires an integer
  timeout"). This is **deliberately implemented and tested** in `matrix-api-migration`
  (`matrix_router_test.exs:575` "PUT typing typing:true WITHOUT timeout → 400") and is the
  Oracle-correct behaviour (Matrix CS API: `typing:true` requires `timeout`).
- **Classification:** **Intentional behaviour improvement, not a regression.** The Elixir stack is
  *more* spec-compliant than the Go gateway here. Recorded for transparency because the scenario is
  target-dependent (green against `core:4000`, red against `gateway:8008`).
- **Action:** none required for this story. The tightened assertion (`M_BAD_JSON`) matches the
  intended pure-Elixir behaviour.

### Finding #3 — SPEC GAP in BOTH stacks (NOT a regression) — `send` missing `msgtype`

- A **well-formed** JSON body that simply omits `msgtype` (e.g. `{"body":"hi"}`) is accepted with
  `200 {event_id}` by **both** the Go gateway (`rooms.go` does no `msgtype` check) and the Elixir
  handler (`protected.ex` / `Nebu.Room.Server` / `permissions` — grep found zero `msgtype` validation
  anywhere). The Matrix spec ideal is `400`, but neither implementation enforces it.
- **Classification:** pre-existing spec gap shared by both stacks — **NOT a migration regression.** This
  is why the original `ElixirRegression_Send_MissingMsgtype` scenario was repointed (it would have been
  permanently red on a non-regression). If the project wants spec-correct `msgtype` validation, that is
  a **new feature story**, not a regression fix.

---

## MINOR items from the pre-dev test-review (`test-review-findings.md`)

- **MINOR-2 — ADDRESSED.** Tightened the three 400-scenarios to assert the **confirmed actual errcode**
  the migrated Elixir router returns (verified by reading `router/protected.ex`, `matrix_public.ex`):
  - login missing-type → `M_UNKNOWN` (was `contains "errcode"`)
  - typing-true no-timeout → `M_BAD_JSON` (was `contains "errcode"`)
  - send "missing msgtype" → **repointed** to the genuine malformed-JSON `M_BAD_JSON` parity contract
    (the original spec-ideal target was implemented by neither stack; see Findings #1 and #3).
  All three now assert the exact errcode via the existing `the response body has errcode "…"` step.
- **MINOR-1 — LEFT AS-IS (as instructed).** AC3 user-count assertion still degrades to
  `renderedRows > 0` when no count element is present. Strengthening it would require a
  `data-testid="user-count"` on the LiveView, which is **production code** — out of scope for this
  test-only story. Coverage-strength note retained.
- **MINOR-3 — INFO only, no action.** Range fixture is a synthetic JPEG; `Content-Type: image/jpeg`
  depends on the server echoing vs sniffing. Flagged so a future sniffing change surfaces here.

---

## Files changed (this story)

- `gateway/features/elixir-regression-matrix.feature` — MINOR-2: pinned exact errcodes; repointed the
  send 400-scenario to the genuine malformed-JSON parity contract; documented Findings #1–#3 inline.
- `gateway/test/integration/elixir_regression_steps_test.go` — replaced `kaiSendsMessageNoMsgtype`
  (well-formed body, never a 400) with `kaiSendsMalformedMessageBody` (malformed body → shared 400
  contract); updated the step registration regex accordingly. `go vet -tags integration` clean.
- `_bmad-output/nebu/epics/full-elixir-stack/step-results/elixir-stack-regression/regression-report.md`
  — this report.

(Staged ATDD files left structurally intact: `regression_sync_load_test.exs`,
`elixir-regression-media.feature`, `elixir_regression_media_steps_test.go`,
`e2e/.../elixir-regression-admin.feature` + `.steps.ts`, `steps_test.go` wiring — all verified sound.)

## Definition-of-Done status

| DoD item | Status |
|---|---|
| All 4 test files exist & are statically sound (compile, steps resolve, no `@wip`) | **DONE** |
| `make test-integration` exits 0 (all scenarios green) | **BLOCKED** by Finding #1 (genuine send-malformed-body regression). Fix belongs in `matrix-api-migration` per the story's own Implementation Notes. ci-gate must run with `NEBU_TEST_MATRIX_URL=http://core:4000`. |
| Regression report written with Godog/Playwright/sync metrics | **DONE** for static composition; live metrics marked **to be captured by ci-gate** (no Docker here) |
| No scenario skipped with `@wip`/`@pending` | **DONE** |
| Report committed under `step-results/elixir-stack-regression/` | **DONE** |

**Gate verdict:** the regression GATE is doing its job — it has surfaced one genuine migration
regression (Finding #1, BLOCKER candidate) that must be fixed in `matrix-api-migration` before
`go-removal-cleanup`. The suite is otherwise complete, sound, and ready for the ci-gate to execute
against the live pure-Elixir stack.
