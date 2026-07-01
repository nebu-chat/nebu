---
epic: client-crypto-setup
story: account-data-durability
security_review: required
baseline_commit: ce1e34ba83ac8161e45e0193966e7eccafee031b
---

# Story: Durable account_data (PostgreSQL) + /sync account_data, so recovery survives restart

Status: done

## Story

As an Element user who has set up recovery / secret storage,
I want my global account_data to persist across server restarts and appear in /sync,
so that my cross-signing / secret-storage configuration is not lost and Element does not
re-prompt setup after a restart — completing the E2EE-readiness of the cross-signing work.

## Context & Spec Notes (Oracle)

Story `cross-signing-readback` deliberately left this OUT of scope: today
`Nebu.Matrix.AccountDataStore` is **ETS — volatile and node-local** (see its moduledoc and
`server/lib/nebu/web/router/protected.ex` GET/PUT `/user/{userId}/account_data/{type}`), and
`/sync` returns `"account_data" => []` (~line 597 at baseline). That round-trips within one
session (enough to clear the bootstrap error) but **not across restart or across nodes**.

Element stores its secret-storage / recovery material in global account_data —
`m.secret_storage.default_key`, `m.secret_storage.key.<id>`, and the client-encrypted
private cross-signing keys (`m.cross_signing.master` / `.self_signing` / `.user_signing`).
If those are lost on restart or never delivered via `/sync`, Element treats recovery as not
configured and re-prompts (or errors). Durable + /sync-delivered account_data closes that gap.

Spec (Matrix CS API v1.18, §Client Config):
- `PUT /_matrix/client/v3/user/{userId}/account_data/{type}` — store; auth user MUST equal
  `{userId}` else `403 M_FORBIDDEN` (already enforced). Body is arbitrary JSON.
- `GET .../account_data/{type}` — `404 M_NOT_FOUND` if absent (already implemented).
- `/sync` response `account_data.events` — array of `{type, content}` for global account data;
  on incremental sync, only entries changed since `since`.
- Content is **opaque** to the server (client-encrypted for the secret-storage types) — ADR-011
  holds; the server never decrypts.

ADR-018: SQL inline / no ORM. Mirror `DeviceKeyStore` / `CrossSigningKeyStore` (PostgreSQL,
read-on-start) for the persistence style. ADR-002 (ETS for volatile) does NOT apply here —
this data must be durable.

## Scope guardrail

IN: durable global account_data (PostgreSQL) + deliver global account_data in `/sync`
(full on initial sync, changed-only on incremental). Keep the existing GET/PUT behavior and
the user==auth `403` guard.

OUT: room-scoped account_data (`/rooms/{roomId}/account_data/{type}`) unless trivial; tags;
the Compliance/Normal mode switch; any decryption of content.

## Acceptance Criteria

1. `PUT .../account_data/{type}` persists to PostgreSQL (new migration
   `000011_account_data`), keyed by `(user_id, type)`, content stored opaquely as JSON.
2. The stored value survives a server/process restart: after restart, `GET .../account_data/{type}`
   returns the previously stored content (read-from-DB, not volatile ETS).
3. `GET .../account_data/{type}` returns `404 M_NOT_FOUND` when absent; `403 M_FORBIDDEN` when
   `{userId}` != authenticated user (unchanged).
4. Initial `/sync` includes all of the user's global account_data under `account_data.events`
   as `{type, content}` objects.
5. Incremental `/sync` (with `since`) includes only account_data entries changed after the
   `since` token; unchanged entries are omitted.
6. Content is stored/returned byte-for-byte (opaque) — no server-side parsing/decryption.
7. `make test-unit-elixir` green; `make test-integration` account_data + sync tests green; no
   regressions in existing account_data (`element-compat/account-data-get`) behavior.

## Tasks / Subtasks

- [ ] Migration `priv/migrations/000011_account_data` — table `account_data(user_id, type,
      content_json, changed_at/stream_ordering, PK(user_id,type))`.
- [ ] Rework `Nebu.Matrix.AccountDataStore` to PostgreSQL (put/get/list-since), read-on-start
      semantics; keep the module's public API stable for the existing GET/PUT handlers.
- [ ] `/sync`: populate `account_data.events` (full on initial, changed-since on incremental)
      using a per-user change marker comparable against the sync `since` token.
- [ ] Persistenz-Strategie test: PUT → restart/process boundary → GET returns content (AC2).
- [ ] ADR-011 regression: content stored opaque; no decryption path (AC6).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. account_data survives restart — ExUnit `:integration` (Persistenz = PostgreSQL)
   - Given: a user PUTs `m.secret_storage.default_key` content
   - When: the store/process is restarted (fresh process / app restart)
   - Then: GET returns the same content (durable, not volatile)

2. global account_data in initial /sync — ExUnit `:integration`
   - Given: a user has two account_data entries
   - When: initial `/sync`
   - Then: `account_data.events` contains both as `{type, content}`

3. incremental /sync delivers only changed account_data — ExUnit `:integration`
   - Given: a synced user PUTs a new account_data entry
   - When: incremental `/sync` with the prior `since`
   - Then: `account_data.events` contains only the newly changed entry

4. auth guard + 404 unchanged — ExUnit
   - Given: an authenticated user
   - When: GET own absent type / PUT for another user's id
   - Then: `404 M_NOT_FOUND` / `403 M_FORBIDDEN` respectively
