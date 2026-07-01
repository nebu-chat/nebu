# Epic client-crypto-setup — FINAL SEC Gate 2 Security Review — 2026-06-29

## Scope

- **Epic:** client-crypto-setup (FINAL SEC Gate 2 before merge to `main`)
- **Base:** `ce1e34ba83ac8161e45e0193966e7eccafee031b`
- **HEAD:** current tip of `feature/client-crypto-setup`
- **Diff range:** `git diff ce1e34ba..HEAD`
- **Reviewer:** Kassandra (nebu-agent-kassandra)

### Stories covered (full epic)

| Story | Surface | First reviewed |
|-------|---------|----------------|
| wellknown-e2ee-default | static `io.element.e2ee.force_disable` hint in `/.well-known/matrix/client` | SEC Gate 2 2026-06-28 — CLEAN |
| cross-signing-readback | PostgreSQL cross-signing key directory + migration 000010 + keys/query + signatures/upload | SEC Gate 2 2026-06-28 — CLEAN |
| **account-data-durability** | **NEW** — migration 000011; `Nebu.Matrix.AccountDataStore` ETS→PostgreSQL rewrite; `/sync` global `account_data` delivery; durable PUT/GET | This review |
| **e2e-test-rehab (epic)** | **NEW** — Playwright/BDD config, Dex preflight, GitLab CI `e2e-element-web` job, Makefile target — test-infra only | This review |

An earlier SEC Gate 2 (2026-06-28, report `epic-client-crypto-setup-security-review-2026-06-28.md`) reviewed the first two stories CLEAN. This FINAL gate re-reviews the full diff with emphasis on the NEW surface added since.

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| F-1 | LOW (advisory) | account-data-durability | `account_data_store.ex:149-151` | `decode_rows/1` (`Jason.decode!`) runs OUTSIDE the `safe_query` rescue on both `/sync` read paths. A corrupt JSON row would raise and crash that user's `/sync`. Not reachable via the API (write path stores `Jason.encode!`-produced JSON); requires direct DB corruption. | New (carry-advisory) |
| F-2 | LOW (advisory) | account-data-durability | `000011_account_data.up.sql` | `account_data` table has no `ENABLE ROW LEVEL SECURITY` / policy. Recurring "missing RLS on new tables" pattern. Defense-in-depth only — app-layer `WHERE user_id=$1` + the auth==user 403 guard fully scope access today; single DB role. | New (recurring pattern, advisory) |
| F-3 | LOW (advisory) | account-data-durability | `account_data` table / `put/3` | No per-value byte cap on `content_json`. An authenticated user can store arbitrarily large opaque blobs under their own keys (authenticated self-quota, not cross-user). Mirrors the no-byte-cap advisory carried for the cross-signing stores. | New (advisory) |

**No CRITICAL. No HIGH. No MEDIUM.**

## Detail — NEW surface (account-data-durability)

### SQL injection — CLEAN
Every query in `account_data_store.ex` is parameterized via `Ecto.Adapters.SQL.query/3` with positional params (`$1..$4`). No string interpolation of any user-controlled value into SQL. `put/3` (INSERT … ON CONFLICT), `get/2`, `list_all_and_clear/1`, `list_changed_and_clear/1` all bind `user_id`, `type`, `content_json` as params.

### IDOR (cross-user read/write) — CLEAN
- **PUT** (`protected.ex:428-440`) and **GET** (`protected.ex:442-460`) both compute `decoded_user = URI.decode_www_form(user_id)` from the path and reject with `403 M_FORBIDDEN` when `decoded_user != authenticated_user`. The guard runs **before any DB access** (verified: 403 branch touches no store).
- `authenticated_user = conn.assigns[:current_user]` is the server-derived MXID (`@<sub>:<server_name>`) set by `OidcPlug` from verified token claims — never client-supplied. Confirmed in `oidc_plug.ex` (assigns `current_user` from the validated session).
- **`/sync` delivery** (`put_global_account_data/3`, `protected.ex:109-121`) reads `user = conn.assigns[:current_user]` and passes it straight to the store. The path `user_id` is **not** consulted for sync. No cross-user leakage possible.
- Test coverage present: `account_data_test.exs:139-156` — "PUT/GET another user's account_data → 403 M_FORBIDDEN (rejects before DB)".

### Consume-once `changed` flag (UPDATE…RETURNING) — CLEAN (no race / no cross-user leak)
- `list_changed_and_clear/1`: `UPDATE account_data SET changed=FALSE WHERE user_id=$1 AND changed=TRUE RETURNING type, content_json` — a single atomic statement, row-locked by PostgreSQL, **scoped to one `user_id`**. Two concurrent incremental syncs for the same user cannot both receive the same row (the row's `changed` is cleared inside the same transaction that returns it; the loser sees zero rows). No cross-user mixing — the `WHERE user_id=$1` predicate is in the same statement as the clear.
- `list_all_and_clear/1` (initial sync) clears all of the user's flags and returns all rows — same single-statement atomicity, same user scoping.
- Migration default `changed BOOLEAN NOT NULL DEFAULT TRUE` is correct: a freshly-PUT row surfaces in the next sync exactly once.

### Opacity (ADR-011) — INTACT
- `content_json` stored as **TEXT** (not jsonb) — byte-for-byte round trip; the server never canonicalizes, parses, or decrypts.
- PUT stores `Jason.encode!(body_params(conn))` verbatim; GET returns the stored bytes via `send_resp(200, json_body)`.
- `/sync` paths `Jason.decode!` only to re-shape into the `{"type","content"}` envelope the client originally sent — shaping, not interpreting. The encrypted secret-storage / cross-signing private material (`m.secret_storage.*`, `m.cross_signing.master/.self_signing/.user_signing`) is treated as an opaque blob throughout.
- **No encryption is enabled** by storing/echoing this data. `m.room.encryption` remains rejected on every state-write path (unchanged this epic).

### Secret exposure in logs — CLEAN
`grep` for `Logger`/`IO.inspect`/`inspect(` across `account_data_store.ex` and the account_data handlers in `protected.ex`: **zero hits**. The opaque (client-encrypted) content is never logged, never placed in an error message, never echoed into a 4xx body. The 403/404 error bodies are static strings.

## Detail — Cumulative (cross-signing + account_data together)

### Migration chain 000010 + 000011 — CLEAN
- **000010** `cross_signing_keys` — single-PK `user_id`, idempotent (`IF NOT EXISTS`). Reviewed CLEAN 2026-06-28.
- **000011** `account_data` — new table, composite PK `(user_id, type)`, idempotent (`IF NOT EXISTS`), no FK to or alteration of any existing table. Sequential numbering correct (000010 < 000011), no ordering conflict. Adds no constraint that could break an existing table. Both `down` migrations are plain `DROP TABLE IF EXISTS` with documented data-loss warnings.
- Both new tables lack RLS (F-2 + the 2026-06-28 cross-signing RLS advisory) — recurring defense-in-depth gap, app-layer scoping is complete, single DB role deployment. Non-blocking, consistent treatment across both stores.

### Combined surface — CLEAN
The cross-signing directory (private parts client-encrypted, stored in `account_data` as opaque blobs; public parts in `cross_signing_keys`) and the account_data store now jointly hold all of Element's recovery material. Verified: nothing decrypts across stores; each blob is read back only by its own store keyed on the server-derived MXID. The `keys/query` public-key echo (no membership scoping, by design — symmetric with `DeviceKeyStore`) exposes no private material. No plaintext secrets in logs in either store.

## Detail — e2e-test-rehab (test-infra only)

### No production code or secrets affected — CONFIRMED
- `git diff --name-only` for the e2e-test-rehab work touches only: `e2e/**`, `.gitlab-ci.yml`, `Makefile`. **Zero `server/lib` changes** attributable to this epic (the only `server/lib` changes in the full diff are the account-data + cross-signing production code already reviewed).
- **GitLab CI `e2e-element-web` job:** credentials are GitLab masked CI variables (`$CI_REGISTRY_USER`/`$CI_REGISTRY_PASSWORD` and `$DOCKER_REGISTRY_USER`/`$DOCKER_REGISTRY_PASS`), consumed via `docker login --password-stdin` / `-p` — no hardcoded credentials in the YAML. Job is `when: manual` + `allow_failure: true` (never blocks the gate, never auto-runs with secrets on untrusted input). DinD with `--tls=false` is on an internal service link only.
- **Makefile `test-e2e-element-ci`:** `NEBU_RATE_LIMIT_DISABLED=true` is scoped to this CI test target (ephemeral compose stack, torn down in the same recipe) — not a production default. OIDC issuer/URLs are localhost/dev-Dex.
- **e2e fixtures:** `DEX_TEST_PASSWORD` is the ADR-012 example-only dev credential (imported from `./users`, pre-existing). Access tokens are captured at runtime during the live OIDC browser flow and written to local sidecar files in the test workspace — not committed. No new secret material introduced.

## ADR-011 — INTACT
- `m.room.encryption` rejection unchanged this epic (no state-write path modified).
- All stored crypto material (cross-signing public keys, client-encrypted private keys in account_data) is opaque: stored verbatim, never decrypted, never parsed for meaning.
- The new `/.well-known` `io.element.e2ee.force_disable: true` is a static UI **hint** to Element, not an enforcement mechanism — consistent with the managed posture, not a regression.

## Cross-Story Patterns
- **Recurring "missing RLS on new tables"** (MEMORY pattern): both 000010 and 000011 ship without RLS. App-layer scoping (`WHERE user_id=$1` + auth==user 403 guard) is complete and the deployment is single-role, so this stays advisory — but the pattern now spans two consecutive stores in this epic. Recommend a future defense-in-depth pass adding RLS to the crypto/account-data tables together.
- **`Jason.decode!` outside the read-path rescue** (F-1): mirrors the 2026-06-28 "decode_key outside safe_query rescue" LOW for the cross-signing store. The same robustness gap recurs in `account_data_store.decode_rows/1`. Not security (opaque content, valid-JSON write path) but worth a single hardening fix across both stores.

## Accepted Risks
None newly accepted. Pre-existing: ADR-012 example-only Dex dev credentials (`DEX_TEST_PASSWORD`); host-header reflection into `.well-known` `base_url` (pre-existing watch-flag, not introduced/worsened by this epic).

## Follow-up Stories Required
**None.** No CRITICAL/HIGH. All findings are LOW advisory and may be bundled into a future defense-in-depth hardening story at the team's discretion.

## Summary
CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 3 (all advisory)
Follow-up stories required: 0
Accepted risks: 0 new

**Epic security gate: PASS / CLEAN** — safe to merge `feature/client-crypto-setup` → `main`.
