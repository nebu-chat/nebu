# Fix brief — Kassandra findings (cycle 4, security fix)

Full report: `docs/stories/e2ee-client-support/security-reports/device-key-directory-security-review-2026-11-02.md`
(read the Detail section of finding #1 first). Scope of this cycle: ONLY the items below. No refactoring of anything else.
Decision of the user (2026-11-03): fix the HIGH and the three LOW findings.

## F1 (HIGH) — `keys/claim`: per-target rate buckets pin request bodies in ETS (`http_key_directory.ex` `charge/2`)

Implement ALL of:

1. **Key digest.** The per-target bucket key must be fixed size and must not reference the request body:
   `{"keys_claim_target", user, :crypto.hash(:sha256, [uid, 0, did])}` (heap binary, 32 bytes). `user` comes from the authenticated
   session, not from the body.
2. **Caller budget per target.** Add a caller bucket `{{"keys_claim_targets", user}, length(valid), 600 / min, burst 1000}` (only when `valid != []`;
   a cost above the burst is charged as the burst, see `RateLimit.take_all/1`). The cost depends only on the number of syntactically valid targets,
   never on their state (no existence oracle). Add the numbers to `limits/0` and to the moduledoc.
3. **Two stages, because `RateLimit.charge_buckets/2` evaluates ALL buckets and inserts the missing rows even when another bucket denies**
   (read `server/lib/nebu/web/plugs/rate_limit.ex` `charge_buckets/charge_bucket`: the `for` has no short circuit, a refund keeps the row).
   So a denied request would still create up to 1000 rows, and an attacker whose caller bucket is empty could keep growing the table.
   Stage 1: `take_all([caller request bucket, caller targets bucket])`. Only when it says `:ok`, stage 2: `take_all(per-target buckets)`.
   A stage-2 denial leaves the stage-1 tokens spent (acceptable, state independent). Do NOT change `rate_limit.ex` unless it is unavoidable
   (it is shared); if you must, say why in your digest.
4. **Tests (no DB where possible).**
   - the stored per-target bucket keys contain no binary whose `:binary.referenced_byte_size/1` exceeds its `byte_size/1` (use a body of >= 50 KB with
     65..255 byte uids/device ids; look the rows up in the `Nebu.Web.Plugs.RateLimit` ETS table);
   - row growth is bounded: after a request denied in stage 1 the table has NOT grown; after N allowed requests it grew by at most the budget;
   - the 429 for the caller targets budget does not depend on whether the targets exist (same answer for existing and unknown targets);
   - update the existing limit pins (`limits/0` consumers, docs pins) instead of weakening them.

## F2 (LOW) — `device_list_store.ex` `@left_sql` branch 1 leaks leaves in rooms the caller already left

Add `AND m.left_at IS NULL` to the `EXISTS (SELECT 1 FROM room_members m ...)` of the first branch of `@left_sql` (the caller must still be joined).
The caller's own leave (second branch) already reports everyone it stopped sharing a room with, so nothing is lost.
Test (DB): C joins R with X, C leaves R, X leaves R afterwards (X shares no other room with C): `/keys/changes?from=<before X's leave>` must NOT list X in
`left`. And the existing case stays green: C still joined, X leaves, X is listed.

## F3 (LOW) — `GET /keys/changes` has no rate limit

Add a per-user tier in `router/protected.ex` like `@room_keys_version_read_rate_limit` (`key: :user`, `tier: "keys_changes"`, 60 per minute, burst 20),
applied before any database work, 429 `M_LIMIT_EXCEEDED` through the plug. Test: the 21st immediate request answers 429 (use the existing rate limit
test seams: clock fn / `NEBU_RATE_LIMIT_DISABLED` handling as in the other endpoints' tests — check how they run with the limiter on).

## F4 (LOW) — global advisory lock (4760, 60) — documentation only

No code change. Add a risk entry in `docs/architecture/11-risks.md` (what: one cluster-wide lock from the stamp trigger to COMMIT for every membership and key
write; every `/sync` without `.d` and every initial sync takes it; impact: contention, not DoS; mitigation: sync is rate limited; monitor; option
`pg_try_advisory_xact_lock` with retry). Mention the new `keys/changes` tier and the claim budgets where the docs already list the claim limits
(`docs/architecture/05-building-blocks.md`, `07-deployment.md`, `08-concepts.md`, `docs/matrix-api-scope.md`, CHANGELOG — grep for "keys_claim" /
"10 / hour" / "per (caller, target") and keep wording and numbers identical to the code pins.

## Also (report only, do not fix)

Grep the other E2EE files of this epic (`http_to_device*`, `http_room_keys*`, `key_claim_store.ex`, `device_key_store.ex`) for the same pattern:
a `RateLimit.take`/`take_all` key built from a request-derived term (a JSON-decoded binary). Name every hit in your digest (`FILES` line is not enough: add
one extra line `FOUND: <path:line>` per hit, or `FOUND: none`). Do not change them.

## Verification you must do

`python3 skills/nebu-pipeline/scripts/test_digest.py -- make test-unit-elixir` cannot start Docker in your sandbox: say so honestly and run what you can
(`mix compile --warnings-as-errors` is not possible either if mix is blocked). The orchestrator runs the tests with `.e2ee-ci/quick.sh`.
