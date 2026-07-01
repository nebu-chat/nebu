# Code-Review — account-data-durability (cycle 0)

Reviewer perspective: Blind Hunter + Edge-Case Hunter + Acceptance Auditor.
Diff: migration 000011 (up/down), `AccountDataStore` ETS→PostgreSQL rewrite,
`/sync` `put_global_account_data`, GET/PUT handler doc update, release_test +
compat_test test adjustments, new `account_data_test.exs`.

## Acceptance Auditor — AC → implementation

| AC | Verified |
|----|----------|
| 1 PUT persists to PostgreSQL keyed (user,type), opaque | ✅ `put/3` upsert ON CONFLICT (user_id,type); HTTP PUT unchanged + 403 guard intact |
| 2 survives restart (read-from-DB) | ✅ no ETS/cache remains; `get/2` reads the committed row; integration durability test (fresh-process read) green |
| 3 404 absent / 403 cross-user | ✅ `get/2` → `:error` → 404; user==auth guard unchanged; integration + no-DB tests green |
| 4 initial /sync = ALL as {type,content} | ✅ `list_all_and_clear/1`; `put_global_account_data` no-since branch; integration test green |
| 5 incremental /sync = changed-only | ✅ consume-once `changed` flag, `UPDATE…RETURNING` atomic; old entry omitted, new present — integration test green |
| 6 opaque, no parse/decrypt | ✅ store TEXT verbatim; GET returns raw bytes; /sync decode is envelope-shaping only; opacity integration test green |
| 7 unit + integration green, no regression | ✅ unit 911 exit0; integration 78+21 green incl. cross_signing/compat/release/sync regressions |

All 7 ACs covered and verified by green tests. No MAJOR.

## Blind Hunter
- `safe_query` guards the read paths (DB down → `[]`), so `/sync` never crashes on a
  Repo hiccup — matches CrossSigningKeyStore. `put/3` uses the raising `query` (a failed
  PUT SHOULD surface, mirrors the established store). OK.
- `init_table/0` kept as `:ok` no-op for the `Nebu.Application` call site — boot path
  unbroken. OK.
- `Jason.decode!` in `decode_rows/1` only ever sees values written by `put/3` (always
  produced by `Jason.encode!` in the handler or by tests), so it cannot raise on
  server-written data. OK.

## Edge-Case Hunter
- Long-poll race: a PUT landing during the incremental long-poll wait is picked up by the
  post-poll `list_changed_and_clear` (UPDATE reads current state) — delivered once, not
  lost, not duplicated. Correct.
- Initial sync clears all flags → a following incremental returns nothing new. Correct
  consume-once semantics.
- HTTP PUT canonicalises JSON (decode→`Jason.encode!`) — pre-existing behavior, unchanged
  by this story; spec-correct (account_data `content` is a JSON object). The STORE layer is
  byte-exact (AC6 store test). Not a finding.

## INFO (non-blocking)
- INFO-1: `/sync` `content` is delivered as a decoded JSON object (spec-correct). The
  literal-byte guarantee holds at the store layer and the GET endpoint (raw `send_resp`),
  which is where ADR-011 opacity matters. Documented in the moduledoc.
- INFO-2: Room-scoped account_data remains out of scope (story guardrail). Top-level
  global account_data only. Intentional.

## Verdict
CLEAN — 0 CRITICAL / 0 MAJOR / 0 MINOR, 2 INFO. Proceed to security review.
