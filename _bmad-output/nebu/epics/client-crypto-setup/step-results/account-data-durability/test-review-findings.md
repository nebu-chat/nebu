# Pre-Dev Test-Review — account-data-durability

Scope: `server/test/nebu/matrix/account_data_test.exs` (new) + the `:integration`-retagged
`account_data store — PostgreSQL` block in `matrix_client_compat_test.exs`.

## AC → Test coverage matrix

| AC | Requirement | Test(s) | Covered |
|----|-------------|---------|---------|
| 1 | PUT persists to PostgreSQL keyed by (user,type), opaque JSON | AccountDataTest "AC1/AC2 PUT then GET", "second PUT overwrites", durability "AC2 Persistenz" | ✅ |
| 2 | Survives restart (read-from-DB, not ETS) | AccountDataTest "AC2 Persistenz: fresh-process get" | ✅ (see MINOR-1) |
| 3 | 404 absent; 403 cross-user | AccountDataTest "AC3 GET unseen → 404", "AC4 403 PUT/GET other user"; store-level ":error" | ✅ |
| 4 | Initial /sync includes ALL global account_data as {type,content} | AccountDataTest "AC4 two entries in initial sync" | ✅ |
| 5 | Incremental /sync includes ONLY changed-since entries | AccountDataTest "AC5 only newly-PUT entry, old omitted" | ✅ |
| 6 | Content opaque byte-for-byte | AccountDataTest "AC6 opacity: verbatim round-trip of non-key blob" | ✅ |
| 7 | unit green + integration green + no regression | covered by CI gate (Step 5) + retained compat regression tests | ✅ |

Every AC has ≥1 test. No AC has zero coverage → no MAJOR finding.

## Quality checks
- No hard waits / `:timer.sleep`. `Task.await(5000)` is a join, not a poll. ✅
- Deterministic: unique user-ids / types via `unique_integer` per test — no cross-test
  collision, safe under `async: false`. ✅
- No cookie forging / no DB-seeding shortcut: auth is a real signed JWT through the full
  router + OidcPlug; storage goes through the public store / HTTP handlers. ✅
- Real process boundary for the durability proof (`Task.async`) — matches the established
  CrossSigningKeyStore durability pattern. ✅
- Persistenz-Strategie = PostgreSQL is explicitly tested (AC2). ✅

## Findings

### MINOR-1 (note for dev, not blocking)
The AC2 `Task.async` durability read is only a TRUE durability proof once ETS is fully
removed from `AccountDataStore`. ETS `:public, :named_table` is node-global, so a
cross-process read against the *current* ETS impl would also pass (false green). The dev
step MUST replace ETS with PostgreSQL outright (no ETS fallback/cache), so this test then
genuinely exercises the read-on-start Postgres path. The `/sync` AC4/AC5 tests are
unambiguously RED today (sync returns `[]`), so the suite as a whole has a hard RED signal.

### MINOR-2 (note)
AC5's "changed since the since token" is implemented via a consume-once per-(user,type)
`changed` flag (mirrors `cross_signing_changed`). The test asserts the old entry is OMITTED
and the new one PRESENT on the incremental sync — it does not over-specify the mechanism, so
it is robust to the exact marker chosen (flag vs timestamp). Good.

## Verdict
CLEAN — 0 MAJOR. 2 MINOR notes carried to dev. All 7 ACs covered. Proceed to dev.
