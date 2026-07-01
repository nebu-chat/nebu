# Epic Retrospective — `client-crypto-setup`

**Date:** 2026-06-28
**Epic status:** All stories `done`, all gates green.
**Branch:** `feature/device-management` (epic base `ce1e34ba` → HEAD `ad380589`)
**Facilitator note:** Run non-interactively at the end of the pipeline; this is the written
record, not a party-mode transcript.

---

## 1. Epic Summary

E2EE-**readiness only** epic — deliberately scoped so the managed posture (ADR-011) is
unchanged: the server keeps rejecting `m.room.encryption`. The goal was to make Element-family
clients set up *cleanly* (device + cross-signing bootstrap completes, no encryption nag dead-end),
not to enable room encryption.

### Stories delivered

| Story | What shipped | Commit(s) |
|---|---|---|
| `wellknown-e2ee-default` | `io.element.e2ee.force_disable: true` hint in `/.well-known/matrix/client` (Element-proprietary client UI hint; not spec, not enforcement). | `95769d84` |
| `cross-signing-readback` | PostgreSQL-backed cross-signing key directory: `keys/device_signing/upload` (persist + MUST-guard), `keys/query` cross-signing echo (fixes the hardcoded `{}` bug), `keys/signatures/upload` (validate-then-merge), `/sync` `device_lists.changed` consume-once flag. Migration `000010_cross_signing_keys`, new `Nebu.Matrix.CrossSigningKeyStore`. | `f45126cc` + `52c64cf1` |

### Gate outcomes

- **TEA pre-dev test-review:** COMPLETE AC coverage on both stories. 1 MAJOR caught **before**
  dev (durability test).
- **Code-review:** 1 MAJOR caught and fixed in 1 cycle (signature-merge ordering); `wellknown`
  story CLEAN at cycle 0.
- **Security (Kassandra):** SEC Gate 1 ×2 CLEAN; SEC Gate 2 (epic-end, mandatory) CLEAN —
  CRITICAL 0 / HIGH 0 / MEDIUM 0 / LOW 3 (advisory hardening). Gate: **PASS**.
  (`epic-client-crypto-setup-security-review-2026-06-28.md`)
- **Strategic output:** two-mode direction (Compliance vs Normal) captured in **ADR-023 (DRAFT)**
  — `docs/architecture/adr/ADR-023-deployment-postures-compliance-vs-normal.md` (commit `ad380589`).

---

## 2. What Went Well

1. **Tight scope held all the way through.** The "E2EE-readiness, NOT mode-toggle / encryption"
   guardrail was repeated in both story files, the sprint-status header, the Oracle context, and
   the security review — and nothing crept in. `wellknown` was literally one static key; the
   cross-signing store never touches the `m.room.encryption` guardrail. ADR-011 verified intact
   by the security gate.

2. **Gates caught real defects pre-merge, not in production.** Two genuine correctness/integrity
   issues (durability test fidelity, validate-then-persist) were caught by TEA and code-review
   respectively and fixed inside the pipeline. Neither reached `done` unaddressed.

3. **Reuse of an established pattern lowered risk.** `CrossSigningKeyStore` deliberately mirrors
   the existing `DeviceKeyStore` (Postgres, migration style, bulk `= ANY($1)` queries, `safe_query`
   that never raises). Familiar shape made both review and the security pass fast and confident.

4. **Spec authority was consulted and the divergence was logged, not buried.** Oracle flagged the
   collision errcode mismatch (story says `400 M_INVALID_PARAM`, spec says `403 M_FORBIDDEN`); the
   pipeline made a deliberate, documented decision rather than silently picking one.

5. **Cluster-correct by construction.** `device_lists.changed` uses a consume-once Postgres
   boolean (`UPDATE ... RETURNING`) instead of token-timestamp parsing — correct on a single node
   and in a cluster (ADR-020), no volatile state.

---

## 3. What To Improve

1. **Durability tests can lie in-process.** The mandated read-on-start test originally
   round-tripped in the *same* process, so a future ETS/in-process cache could have masked a
   missing Postgres row — a false durability proof. Fixed in the red phase by reading back through
   a separately-spawned `Task` (a real process boundary). **Lesson:** a "Persistenz-Strategie =
   PostgreSQL" test MUST cross a process boundary, or it isn't proving durability.

2. **Order-of-operations on writes is a recurring integrity trap.** The cross-signing signature
   merge originally persisted **before** validating, and built the stored object from the
   *submitted* body — a data-integrity / IDOR-shaped risk. Fixed to validate-then-persist, writing
   the server's own `stored` object with merged signatures only inside the equality true-branch.
   **Lesson:** for any merge/upsert of client-supplied data, the default review question is
   "does this validate before it writes, and does it persist server-owned state rather than the
   raw body?"

3. **CI gate cold-start gotchas cost a cycle.** CI cycle-1 failed on a **stale DB volume** and a
   **stale server image** (known recurring hazards — see MEMORY: login integration tests give
   false 500s on a non-fresh DB volume; `make redeploy` not `make build-server`). **Lesson:** the
   CI gate should start from a fresh DB volume and a freshly-built image by default so these never
   surface as phantom failures.

4. **New directory tables keep omitting RLS.** `cross_signing_keys` (000010), like `device_keys`
   (000009) before it, ships without `ROW LEVEL SECURITY` — the recurring MEMORY pattern. App-layer
   IDOR guards compensate (own-row-only writes from `current_user`), so it's defense-in-depth debt,
   not an exploit — but the pattern is now two tables deep.

5. **Spec fidelity was knowingly deferred.** Honoring the story's `400 M_INVALID_PARAM` over the
   spec-closer `403 M_FORBIDDEN` for the collision case was the right call *for this story* (the
   pipeline satisfies the story; Element treats any 4xx identically), but it leaves a known
   spec-compliance gap that must not be forgotten.

---

## 4. Key Lessons (carry-forward)

- **A durability test must cross a process boundary.** In-process read-back is not proof; spawn a
  fresh process / `Task` and await it. This belongs in the test-review checklist for every
  GenServer/Postgres-backed state story.
- **Validate-then-persist, and persist server-owned state.** For any client-supplied merge/upsert,
  validate before writing and store the server's own object (with only the intended delta merged),
  never the raw submitted body. This is the single highest-value review question for crypto/key
  endpoints.
- **Fresh-stack-by-default for the CI gate.** Stale DB volume + stale image produced phantom
  failures twice over; make a clean volume and a fresh image the default so they can't recur.

---

## 5. Action Items / Follow-ups

| # | Follow-up | Type | Source | Priority |
|---|---|---|---|---|
| (a) | **`account_data` durability + `/sync` `account_data` extension.** Today account_data round-trips in-process (ETS, in-session) — enough to clear the bootstrap error, but not durable across restart. Explicit OUT-of-scope carve-out in `cross-signing-readback`. Needs its own story (persist account_data + surface it in `/sync`). | Functional gap / story | `cross-signing-readback` scope guardrail (OUT) | High |
| (b) | **Collision errcode `400 M_INVALID_PARAM` → `403 M_FORBIDDEN` spec-fidelity fix.** Story made a deliberate documented choice; Oracle notes spec is `403 M_FORBIDDEN` on `device_signing/upload` collision. Align to spec in a follow-up (Element treats any 4xx identically, so low client risk). Already logged in oracle-memory. | Spec compliance | Oracle context note | Medium |
| (c) | **ADR-023 open questions before promotion from DRAFT.** Two-mode (Compliance vs Normal) posture: resolve **federation auth** model and **escrow** approach for Normal mode before the ADR leaves DRAFT and before any mode-toggle implementation epic starts. | Architecture decision | ADR-023 (DRAFT) | Medium (blocks mode-toggle epic) |
| (d) | **(Advisory, optional) RLS on directory tables.** Add `ROW LEVEL SECURITY` to `cross_signing_keys` (000010) and `device_keys` (000009) as defense-in-depth; addresses the recurring MEMORY pattern. No exploit path today. | Security hardening (LOW) | SEC Gate 2 Finding #1 | Low |
| (e) | **(Advisory, optional) Per-object byte cap + read-path crash hardening.** Cap cross-signing key-object size below the global 1 MB parser limit (legit objects < 1 KB); move `decode_key`/`Jason.decode!` on the read path inside `safe_query`'s rescue so a corrupted row degrades instead of crashing `/sync` / `/keys/query`. | Security hardening (LOW) | SEC Gate 2 Findings #2, #3 | Low |

> Items (d) and (e) are the LOW advisory findings from SEC Gate 2 — no commit-blocking, no
> follow-up story *required*; listed for traceability. Items (a)–(c) are the known, deliberate
> follow-ups flagged during the epic.

---

## 6. Readiness Assessment

- **Story completeness:** both stories `done`; all ACs covered by tests.
- **Security:** epic gate PASS (0 CRITICAL/HIGH/MEDIUM; 3 LOW advisory).
- **ADR-011 invariant:** verified intact — room encryption still rejected, all key material opaque.
- **Open carve-outs:** account_data durability (a) is a known functional gap that does not block
  the epic's stated goal (clearing the client bootstrap error) but should be the next story if
  E2EE-readiness work continues.
- **Next direction:** ADR-023 is DRAFT; do **not** start a Compliance/Normal mode-toggle epic
  until (c)'s open questions (federation auth, escrow) are resolved.

---

*Generated by `bmad-retrospective` for epic `client-crypto-setup`, 2026-06-28. Not committed.*
