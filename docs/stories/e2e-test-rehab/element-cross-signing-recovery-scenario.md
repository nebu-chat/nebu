---
epic: e2e-test-rehab
story: element-cross-signing-recovery-scenario
security_review: not-needed
---

# Story: Browser scenario that walks cross-signing/recovery setup to completion

Status: done

## Story

As the Element e2e suite,
I want a Gherkin scenario that drives Element's recovery / cross-signing bootstrap to
completion (not cancel it),
so that the `client-crypto-setup` fix is proven in a real browser — Element completes setup
without "Schlüssel können nicht eingerichtet werden".

## Context

`client-crypto-setup` was verified end-to-end via DB inspection (a real Element ed25519
cross-signing identity persisted in `cross_signing_keys`) + the post-login verification
screen. But there is no Gherkin scenario that *walks the setup flow through* — existing
login steps deliberately skip/cancel it. This story adds the true ATDD coverage.

## Acceptance Criteria

1. New `e2e/features/element/crypto/recovery-setup.feature` (+ step definitions): a logged-in
   user opens Settings → Encryption (or the recovery toast), runs "Set up recovery", and the
   flow completes (recovery key generated / "Encryption is active"), with NO error dialog.
2. The scenario fails (red) if Element shows "could not set up keys" / "Schlüssel können nicht
   eingerichtet werden".
3. Optional hardening: after setup, assert via an authenticated `/keys/query` (using the
   captured token sidecar) that the user's `master_keys`/`self_signing_keys`/`user_signing_keys`
   are echoed back (the read-back contract), tying the UI flow to the server contract.
4. Real browser flow only — no cookie forging, no DB seeding (per CLAUDE.md).

## Acceptance Tests

1. recovery setup completes without error — Playwright+Cucumber
   - Given: a logged-in Element session with no recovery configured
   - When: the user runs "Set up recovery" to completion
   - Then: setup succeeds (recovery key shown), no key-setup error, and `/keys/query` echoes
     the cross-signing keys.
