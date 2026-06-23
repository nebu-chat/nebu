---
security_review: required
---

# Story: Cache `oidc_user_id_claim` instead of a per-request DB read

Status: done

## Story

As the **Nebu auth path** (`OidcPlug` on every protected request + `POST /login`),
I want the operator-configured `oidc_user_id_claim` to be **cached in memory** and
read from a live database query **never on the request hot path**, so that an
authenticated request can neither crash over a config read nor silently degrade to
a weaker fallback claim during a DB/Repo-unavailability window.

### Background (why)

`Nebu.Matrix.UserId.configured_claim/0` reads `server_config.oidc_user_id_claim`
from PostgreSQL on **every** identity derivation. A prior fix wrapped that read in
`try/rescue -> nil` so a registered-but-non-Ecto `Nebu.Repo` (boot/shutdown window,
test placeholder) no longer crashes an authenticated request. Kassandra's SEC review
flagged the **MEDIUM** residual: that rescue converts a fail-closed crash into a
transient *fail-open-to-weaker-claim* — for operators who set a **non-default**
`oidc_user_id_claim` (e.g. `email`, because `preferred_username` is non-unique in
their IdP), two verified tokens can transiently collide on the same Matrix user_id
(the identity-collision the `UserId` moduledoc itself calls CRITICAL), during any
window where the live DB read fails.

The proper remediation (per Kassandra): the claim changes **only** via the admin
Claim-Mapping page (and the equivalent gRPC `SetServerConfig` path), so it can be
read **once** and cached, with explicit invalidation on update. Request-time
identity derivation then never depends on a live DB read.

## Acceptance Criteria

- **AC1** — `Nebu.Matrix.UserId.configured_claim/0` returns the cached value and does
  **not** issue an `Ecto.Adapters.SQL.query` on the request path once the cache is
  populated. (Assert via an injected DB seam: a second `configured_claim/0` call does
  not invoke the DB read function again.)
- **AC2 — boot window** — when the cache has never been successfully populated and the
  Repo is unavailable, `configured_claim/0` returns `nil` (standard fallback) **without
  raising**; once the Repo becomes available, the next call populates the cache and
  subsequent calls serve the cached value.
- **AC3 — invalidation on update** — after `Nebu.Admin.DB.upsert_server_config/1`
  persists a change that includes the `oidc_user_id_claim` key, the cache reflects the
  new value (no stale claim). A change that does **not** touch `oidc_user_id_claim`
  does not force a re-read.
- **AC4 — cluster propagation (ADR-020)** — an `oidc_user_id_claim` update on one node
  invalidates the cache on **all** nodes via `:pg` (behaves identically single-node and
  clustered). On a single node the broadcast is a no-op beyond the local refresh.
- **AC5 — no functional change to identity mapping** — for a populated cache, the
  derived `localpart`/`user_id` for given claims is identical to the pre-cache behavior
  (configured claim wins, then `preferred_username` → `name` → `sub`).
- **AC6 — crash/restart** — the cache holder is supervised; after it is killed it is
  restarted and a subsequent `configured_claim/0` repopulates from the DB (volatile
  `persistent_term` state, recovered by re-read). A restart never crashes a request.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **AC1 — cached read, no per-request DB hit** — ExUnit (unit, injected DB seam)
   - Given: the claim cache is populated with `"email"` via an injectable reader
   - When: `configured_claim/0` is called twice
   - Then: the reader DB function is invoked at most once; both calls return `"email"`

2. **AC2 — boot-window graceful degrade then populate** — ExUnit
   - Given: cache unset and the injected reader first raises (Repo not ready)
   - When: `configured_claim/0` is called
   - Then: returns `nil`, does not raise; when the reader later returns `"email"`, the
     next call returns `"email"` and caches it

3. **AC3 — invalidation on upsert** — ExUnit (injected DB seam)
   - Given: cache holds `"name"`
   - When: an upsert including `oidc_user_id_claim => "email"` completes
   - Then: `configured_claim/0` returns `"email"`; an upsert of an unrelated key does
     not change the cached value / does not force a reader re-invocation

4. **AC4 — cluster invalidation via :pg** — ExUnit
   - Given: a subscriber to the cache's `:pg` group
   - When: a local invalidation is triggered
   - Then: the `:pg` group receives the invalidation message (single-node: local
     refresh still occurs; no crash)

5. **AC6 — crash/restart repopulation** — ExUnit
   - Given: the supervised cache holder running with a populated value
   - When: `Process.exit(pid, :kill)`
   - Then: it is restarted by its supervisor; a subsequent `configured_claim/0`
     repopulates from the (injected) reader and returns the value

## Dev Notes

- **Persistence strategy:** volatile `persistent_term` (node-local, fast O(1) reads on
  the hot path), recovered by lazy re-read — same trade-off class as `JwksCache` /
  `TokenDenylist`. Distinguish three cache states: `:unset` (never read), a string
  value, and confirmed-absent (`""` / no row → `nil` fallback) so the boot-window miss
  is retried but a confirmed value is not re-queried.
- **Central invalidation point:** `Nebu.Admin.DB.upsert_server_config/1` — all three
  write paths (`claim_mapping_live`, `bootstrap_live.save_claim_mapping`, gRPC
  `server.ex:3693`) route through it. Trigger a refresh+broadcast there when the
  `oidc_user_id_claim` key is present in the changes map.
- **Cluster:** use `:pg` (already started in `Nebu.Application`) — a dedicated group;
  the cache holder is a GenServer that joins the group and refreshes its
  `persistent_term` on an invalidation message. Mirrors the project's cluster-ready
  primitive rule (ADR-020): identical behavior single-node and clustered.
- **Public-API rule (ADR-020):** keep the cache inside the `Nebu.Matrix` domain (it
  serves `Nebu.Matrix.UserId`); the admin write path triggers invalidation through a
  `Nebu.Matrix` public function, not by reaching into an internal submodule.
- **No domain model (ADR-018):** the DB read stays inline SQL (the existing
  `@sql_user_id_claim` query), just moved behind the cache + injectable for tests.
- Keep `configured_claim/0`'s `nil`-on-failure contract; remove the per-request live
  query. `localpart/1` and `from_claims/2` are unchanged.
