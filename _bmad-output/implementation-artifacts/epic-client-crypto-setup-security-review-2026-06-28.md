# Epic client-crypto-setup Security Review — 2026-06-28

**Reviewer:** Kassandra (nebu-agent-kassandra) — SEC Gate 2 (mandatory epic-end)

## Scope

- **Epic:** `client-crypto-setup`
- **Base:** `ce1e34ba83ac8161e45e0193966e7eccafee031b`
- **HEAD:** `786a9fad` (current `feature/device-management`)
- **Diff:** `git diff ce1e34ba..HEAD`
- **Stories covered:**
  - `cross-signing-readback` — PostgreSQL-backed cross-signing key directory
    (`keys/device_signing/upload`, `keys/signatures/upload`, `keys/query` cross-signing echo,
    `device_lists.changed` flag), migration `000010_cross_signing_keys`.
  - `wellknown-e2ee-default` — Element `io.element.e2ee.force_disable` hint in
    `/.well-known/matrix/client`.
- **Per-story SEC Gate 1:** both CLEAN. This review re-examines the combined attack surface.
- **ADR context:** ADR-011 (managed E2EE, opaque material, no decryption), ADR-018 (inline
  parameterised SQL), ADR-020 (cluster-correct primitives).

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| 1 | LOW | cross-signing-readback | `000010_cross_signing_keys.up.sql` | No `ROW LEVEL SECURITY` on `cross_signing_keys` — defense-in-depth gap (recurring MEMORY pattern "Missing RLS on new tables"). App-layer IDOR guard is correct; sibling `device_keys` (000009) also omits RLS. | New — advisory (carried from per-story) |
| 2 | LOW | cross-signing-readback | `cross_signing_key_store.ex:289` | `decode_key` (`Jason.decode!`) runs OUTSIDE `safe_query`'s rescue on the read path; a corrupted stored row would crash `/sync` or `/keys/query` instead of degrading. Not exploitable (server is sole writer, always writes valid JSON). | New — advisory (carried from per-story) |
| 3 | LOW | cross-signing-readback | `protected.ex` device_signing/upload + signatures/upload | No per-object byte cap beyond the global 1 MB `Plug.Parsers` `length`. A ~1 MB opaque key object is persisted verbatim and re-echoed on every peer `/keys/query`. Legit Ed25519 objects are < 1 KB. | New — advisory (carried from per-story) |

No CRITICAL, HIGH, or MEDIUM findings — at the per-story level or across the two stories combined.

## Detail — Cross-Story / Combined Attack Surface

The epic-end mandate is to look beyond the two clean per-story passes for vulnerabilities that
emerge only when both stories are considered together. Each prompt-directed surface was
re-examined against the full epic diff:

### IDOR — cross-user write / overwrite of cross-signing keys — CLEAN

Every write path derives the storage key from `conn.assigns[:current_user]` only:
- `do_device_signing_upload/1` → `put_keys(user, ...)` where `user = conn.assigns[:current_user]`.
- `do_persist_cross_signing/3` reads/writes the caller's own row exclusively.
- `merge_cross_signing_signature/4` and `persist_single/3` write `WHERE user_id = $1` with the
  same trusted MXID.

`current_user` is set solely by `Nebu.Web.Plugs.OidcPlug` (`oidc_plug.ex:109` opaque-session
path, `:136` JWT path via `Nebu.Matrix.UserId.from_claims`) — server-derived, never
client-supplied. `OidcPlug` runs as a pipeline `plug` ahead of `:match`/`:dispatch`, so all
three new endpoints are authenticated before any handler executes. No path lets user A address
user B's row.

### Idempotency / overwrite-without-auth — identity hijack — CLEAN

`do_persist_cross_signing/3` gates on the **caller's own** stored state:
- First upload (`is_nil(stored["master_key"])`) → persist + `200 {}`. `stored` is the caller's
  own row, so "first upload" can never be observed against another user's directory.
- Idempotent identical re-upload → `200 {}` (no write semantics changed).
- Different keys over existing → `403 M_FORBIDDEN` (no overwrite without UIA).

Because the first-upload and overwrite decisions are both scoped to the caller's own row, there
is no cross-user identity-hijack path: user A cannot pre-seed, replace, or "first-upload" over
user B's cross-signing identity.

### keys/query read echo — enumeration / read-IDOR — CLEAN (by design)

`keys/query` returns cross-signing keys for any requested user id
(`query_cross_signing(Map.keys(requested))`) with no shared-room/membership scoping. This is the
intended behavior of a Matrix key **directory** (public Ed25519 keys are non-secret; reference
homeservers behave identically) and is symmetric with the existing `DeviceKeyStore.query_devices`
echo. No private material is stored or returned; the server never holds a private part. Not a
vulnerability — exposing public verification keys is the purpose of the endpoint.

### Migration 000010 — schema integrity / SQL safety — CLEAN

Single-PK on `user_id` (correct one-row-per-user uniqueness), idempotent
`CREATE TABLE IF NOT EXISTS`, BIGINT epoch-millis per schema-wide convention, all columns typed,
nullable `*_key_json` as intended (clients may omit `user_signing_key`). Static DDL — no
injection vector. Down migration is a guarded `DROP TABLE IF EXISTS`. It introduces a brand-new
table with no FK to or alteration of existing tables, so it cannot break an existing constraint,
index, or assumption (`release_test.exs` updated for the new migration count only). All SQL in
`cross_signing_key_store.ex` and the new `device_ids/1` is parameterised (`$1..$5`, `= ANY($1)`)
via `Ecto.Adapters.SQL.query/3` — no string interpolation of user input. The LOW RLS note
(Finding #1) is the only defense-in-depth gap.

### Device-vs-cross-signing ID namespace MUST-guard — bypass attempt — CLEAN

`do_device_signing_upload/1` computes `upload_key_ids = key_ids_in_upload(body)` and rejects with
`400 M_INVALID_PARAM` if any collides with the caller's existing `DeviceKeyStore.device_ids(user)`
— and this `cond` clause is evaluated **before** the `true ->` branch that persists, so no
partial write occurs on collision. `key_id_of/1` strips the `ed25519:` algorithm prefix
consistently on both the upload-extraction side and the device-id side, so an attacker cannot
smuggle a colliding id past the comparison by re-prefixing. The namespace is per-user (spec), so
a collision with a *different* user's device id is not a security concern. Guard holds on the one
path that creates cross-signing key ids.

### signatures/upload — validate-then-persist & caller-identity guard — CLEAN

- **Caller-identity guard:** the clause `merge_user_signatures(caller, user_id, keyed, _) when
  ... user_id != caller` (`protected.ex:1258`) matches FIRST for any foreign user id and emits
  `M_FORBIDDEN` per key while touching no storage. Only the caller-own fallthrough reaches a
  merge.
- **Validate-then-persist:** both `merge_device_key_signature/4` and
  `merge_cross_signing_signature/4` compare `stored_clean == submitted_clean` (with `signatures`
  AND `unsigned` stripped from both sides) and persist **only inside the true-branch**. On
  mismatch / no stored key → `:invalid`/`:not_found`, nothing written. Critically, the persisted
  object is built from **`stored`** (the server's own copy) with merged signatures, not from the
  attacker-submitted body — so even a matching submission cannot smuggle altered non-signature
  content into storage. `find_key_object/2` is read-only, so the pre-merge validation never
  mutates the directory.

### ADR-011 invariant — room encryption still rejected, material stays opaque — CLEAN

Nothing in the epic touches the `m.room.encryption` state-write guardrail in
`do_set_room_state/4` (`protected.ex:1420`, still `403 M_FORBIDDEN`), the `createRoom`
`initial_state` path, or room upgrade. The cross-signing store persists/echoes opaque JSON
verbatim via `encode_key`/`decode_key`; the server never decrypts and never gains a private part.
The `wellknown-e2ee-default` story only adds a static `io.element.e2ee.force_disable: true` hint
to an unauthenticated well-known document — it is a client-side UI hint (Element-proprietary, no
spec semantics), not an enforcement mechanism; real enforcement remains the server rejecting
`m.room.encryption`. The hint and the directory together still encrypt nothing. ADR-011 holds.

### Secrets / crypto drift; private-key storage or logging — CLEAN

No new secret comparison, no new crypto primitive, no `Logger`/`IO.inspect` of key material,
tokens, or request bodies in the epic diff. Object equality checks
(`cross_signing_unchanged?`, `stored_clean == submitted_clean`) compare PUBLIC key material for
idempotency/overwrite decisions, not secrets — no timing oracle of value. Only public Ed25519
key objects are stored; no private parts are ever received, derived, or persisted. The
well-known response carries no secret (static base_url + boolean).

## Cross-Story Patterns

- **Public-directory read echo with no membership scoping** appears in both `DeviceKeyStore`
  (epic device-management/element-compat) and now `CrossSigningKeyStore`. This is correct for a
  Matrix key directory (public keys), but the pattern should be revisited if any *private* or
  *access-controlled* material is ever added to these stores — at that point an echo without
  scoping would become an IDOR. Recorded as a watch-item, not a finding.
- **New directory tables omit RLS** (`device_keys` 000009, `cross_signing_keys` 000010) —
  consistent with the existing recurring MEMORY pattern. App-layer guards compensate; tracked as
  defense-in-depth debt.

## Accepted Risks

None newly required for this epic. The three LOW items are advisory hardening, no exploit path.

## Follow-up Stories Required

None. No CRITICAL/HIGH findings.

## Summary

CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 3 (advisory/hardening, carried from per-story)
Follow-up stories required: 0
Accepted risks: 0

**Epic security gate:** PASS

The combined attack surface of the two stories was examined against the full security scope plus
the epic-specific concerns (cross-user write/overwrite IDOR, idempotency hijack, migration
integrity, namespace MUST-guard bypass, validate-then-persist on signatures, ADR-011 invariant,
secret/crypto drift). All targeted guardrails — own-row-only writes, foreign-user signature
rejection, collision-guard-before-write, atomic per-user consume-once flag, validate-then-persist
persisting the stored (not submitted) object, and ADR-011 opacity / encryption rejection — are
correctly implemented and hold across both stories. No commit-blocking findings.
