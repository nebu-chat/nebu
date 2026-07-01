# Security Review (SEC Gate 1) — account-data-durability

Date: 2026-06-29
Reviewer: Kassandra scope (adversarial), run inline (nebu-agent-kassandra subagent
unavailable in this environment).
Story: Durable global account_data (PostgreSQL) + /sync delivery.
Diff: migration 000011, `Nebu.Matrix.AccountDataStore` (ETS→PostgreSQL),
`/sync` `put_global_account_data`, GET/PUT handler docs, test adjustments.

## Scope checked
SQL injection · auth bypass / IDOR · JWT validation · rate limiting · secret logging ·
body-size limits · path traversal · weak crypto · ADR-011 (no decryption).

## Findings

### SQL injection — NONE
All four statements in `AccountDataStore` use bound parameters
(`$1..$4`) via `Ecto.Adapters.SQL.query/3`. No string interpolation of `user_id`,
`type`, or `content_json` into SQL. The `type` path segment (attacker-controlled) is
URL-decoded and passed only as a bound parameter. SAFE.

### Auth bypass / IDOR — NONE
PUT and GET both enforce `decoded_user != authenticated_user → 403 M_FORBIDDEN`
(unchanged, pre-existing guard). `/sync` reads account_data for
`conn.assigns[:current_user]` only — a user can never read another user's account_data
(no user_id is taken from the request body/query for the sync path). The store key is
`(user_id, type)` with `user_id` always the authenticated user. SAFE. Confirmed by the
cross-user 403 integration + no-DB tests.

### JWT validation — UNCHANGED
Auth is upstream `OidcPlug` (iss/aud/exp/alg/sig). This story adds no token handling.
N/A.

### Rate limiting — ADEQUATE
`/sync` retains its per-IP limit (600/min, burst 100). PUT account_data sits behind the
authenticated Protected pipeline. The new code adds no unauthenticated surface. OK.

### Secret logging — NONE
No `Logger`/`IO.inspect` of `content_json` or stored values. account_data content
(client-encrypted secret-storage / cross-signing material) is never logged. The OIDC
"email/preferred_username claim absent" warnings in tests are pre-existing and log no
secret material. SAFE.

### ADR-011 opacity — UPHELD
`content_json` is stored as TEXT verbatim; the server never parses or decrypts it. The
`/sync` path decodes JSON only to embed the object in the response envelope (Matrix
requires `content` to be a JSON object) — it does not interpret or transform the value.
GET returns the raw stored bytes. Persisting/echoing this material enables NO encryption;
the `m.room.encryption` rejection guardrail is untouched. UPHELD.

### Body-size / path traversal / weak crypto — N/A
No filesystem access (DB only). No new crypto primitives. Body parsing is the existing
Plug.Parsers path (unchanged). No concern.

## Verdict
CLEAN — 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW. No blocking findings. Cleared to commit.
