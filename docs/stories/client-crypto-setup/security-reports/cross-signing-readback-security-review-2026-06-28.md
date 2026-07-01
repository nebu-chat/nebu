# Security Review — cross-signing-readback (epic client-crypto-setup)

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** STAGED diff. New cross-signing key directory for Matrix CS v1.18:
`server/lib/nebu/matrix/cross_signing_key_store.ex` (new),
`server/lib/nebu/web/router/protected.ex` (handlers for
`POST /keys/device_signing/upload`, `POST /keys/query`,
`POST /keys/signatures/upload`, `/sync device_lists.changed`),
`server/lib/nebu/matrix/device_key_store.ex` (`device_ids/1`),
`server/priv/migrations/000010_cross_signing_keys.{up,down}.sql`.
**Date:** 2026-06-28
**ADR context:** ADR-011 (managed E2EE, opaque material, no decryption), ADR-018
(inline parameterised SQL), ADR-020 (cluster-correct primitives).

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `000010_cross_signing_keys.up.sql` | No `ROW LEVEL SECURITY` on the new `cross_signing_keys` table — defense-in-depth gap (matches recurring MEMORY pattern "Missing RLS on new tables") | Optional: add `ENABLE ROW LEVEL SECURITY` + per-user policy for consistency with `000001/000002`. Consistent with sibling directory table `device_keys` (000009), which also omits RLS. App-layer IDOR guards are correct. |
| 2 | LOW | `cross_signing_key_store.ex:286,289` | `Jason.encode!/decode!` raise on malformed input; the `decode_key` calls on the read path run OUTSIDE the `safe_query` rescue, so a corrupted stored row would crash the `/sync` or `/keys/query` request instead of degrading gracefully | Not exploitable (server is the sole writer; it always writes valid JSON via `encode_key`). For robustness, wrap reads in `Jason.decode/1` and treat error as nil, or move the decode inside `safe_query`'s rescued scope. |
| 3 | LOW | `protected.ex` device_signing/upload + signatures/upload | No per-key/per-object body cap beyond the global 1 MB `Plug.Parsers` `length: 1_000_000` (`json_body.ex:40`). A single 1 MB opaque key object is persisted verbatim and re-echoed on every peer `/keys/query` | Acceptable for MVP; the 1 MB global cap bounds the worst case. Consider a per-object byte cap (e.g. reject a cross-signing key object > 8 KB) since legitimate Ed25519 cross-signing key objects are well under 1 KB. Hardening only. |

No CRITICAL, HIGH, or MEDIUM findings.

---

## Detail — Targeted Attack Analysis

### IDOR: can a user write/overwrite another user's cross-signing keys? — CLEAN

`do_device_signing_upload/1` (`protected.ex:118`) derives the storage key
exclusively from `conn.assigns[:current_user]`. That value is set only by
`Nebu.Web.Plugs.OidcPlug` from a verified opaque session (`oidc_plug.ex:109`) or
a verified JWT mapped through `Nebu.Matrix.UserId.from_claims` (`:124,:136`) — it
is the server-derived MXID, never client-supplied. `put_keys/2` writes
`WHERE user_id = $1` with that value. A client cannot address another user's row.
The `OidcPlug` runs as a pipeline `plug` (`protected.ex` plug stack), so every
route, including all three new endpoints, is authenticated before dispatch — no
soft-auth / pre-auth data return path.

### IDOR: signatures/upload caller-identity guard — CLEAN (airtight)

`do_signatures_upload/1` (`protected.ex:167`) iterates the body keyed by
`user_id`. The clause `merge_user_signatures(caller, user_id, keyed, acc) when
is_map(keyed) and user_id != caller` (`:1257`) is matched FIRST for any foreign
user id and produces an `M_FORBIDDEN` failure for every key WITHOUT touching
storage. Only the `_caller, user_id, ...` fallthrough clause (caller == user_id)
reaches `merge_one_signature`. There is no code path by which a caller mutates
another user's stored signatures. The `keys/query` echo of others' public keys
is by design (it is a public directory).

### Collision MUST-guard ordering — CLEAN

`do_device_signing_upload/1` runs the device/cross-signing namespace collision
check (`Enum.any?(upload_key_ids, &MapSet.member?(existing_device_ids, &1))`,
`:128`) in the `cond` BEFORE the `true ->` branch that calls
`do_persist_cross_signing/3` → `put_keys/2`. On collision it returns `400
M_INVALID_PARAM` and performs no write. No partial-write window exists.

### Consume-once device_lists flag — CLEAN

`consume_changed_flag/1` (`cross_signing_key_store.ex:233`) is a single atomic
`UPDATE cross_signing_keys SET cross_signing_changed = FALSE WHERE user_id = $1
AND cross_signing_changed = TRUE RETURNING user_id`. It is scoped to the caller's
own MXID (`put_cross_signing_device_lists/3` reads `conn.assigns[:current_user]`,
`protected.ex:29`) — it can never read or clear another user's flag, and the
response only ever adds the caller's own id to `device_lists.changed`. The
atomic conditional UPDATE means concurrent incremental syncs race-safely: at most
one returns a row, so the user surfaces exactly once. Initial sync (no `since`)
does not consume the flag (`:28` guard), preserving "next incremental sync"
semantics. Cluster-correct per ADR-020 (Postgres-atomic, not ETS).

### SQL injection — CLEAN

Every statement in `cross_signing_key_store.ex` and the new `device_ids/1` uses
parameter placeholders (`$1..$5`, `= ANY($1)`) via
`Ecto.Adapters.SQL.query/3`. No string interpolation of user input into SQL.

### Validate-then-persist on signatures/upload — CLEAN

Both merge paths compare the submitted object against the stored object with
`signatures` AND `unsigned` stripped from both sides
(`merge_device_key_signature` `:1311`, `merge_cross_signing_signature` `:1345`)
and persist ONLY inside the `if stored_clean == submitted_clean` true-branch. A
mismatch, or no stored key, returns `:invalid`/`:not_found` and writes nothing —
a forged object body cannot overwrite stored key material via the signatures
endpoint. `find_key_object/2` is explicitly read-only (no write) so the
pre-merge validation cannot mutate the directory.

### E2EE / ADR-011 boundary — CLEAN

The store persists and echoes opaque JSON key objects verbatim
(`encode_key`/`decode_key`); the server never holds a private part and never
decrypts. Nothing in this diff touches the `m.room.encryption` state-write path —
the `do_set_room_state` 403 guardrail is unchanged, so room encryption remains
rejected. Persisting the cross-signing directory does not enable E2EE.

### Timing attacks — CLEAN (N/A)

No secret/token equality comparison is introduced. Object equality
(`stored_clean == submitted_clean`, `cross_signing_unchanged?`) compares PUBLIC
key material for an idempotency/overwrite decision, not a secret — no timing
oracle of value. Token comparison stays in `OidcPlug`/`Store`, unchanged.

### Plaintext secret logging — CLEAN

No `Logger`/`IO.inspect`/`fmt` of key material, tokens, or the request body in
the new code. Error envelopes return only static messages.

### Migration safety — CLEAN

`000010_cross_signing_keys.up.sql` is idempotent (`CREATE TABLE IF NOT EXISTS`),
single-PK on `user_id`, BIGINT epoch-millis per schema convention, all columns
typed, no plaintext-sensitive concern (material is public). Down migration is a
guarded `DROP TABLE IF EXISTS`. No injection vector (static DDL). See Finding #1
for the RLS defense-in-depth note.

---

## Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 3 — advisory / hardening only

**Verdict:** APPROVED — no commit-blocking findings. The three LOW items are
defense-in-depth hardening suggestions, none with an exploit path. The targeted
guardrails the story required (own-row-only writes, foreign-user signature
rejection, collision-guard-before-write, atomic per-user consume-once flag,
validate-then-persist, ADR-011 opacity) are all correctly implemented.
