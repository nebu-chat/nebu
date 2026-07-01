# Session 2026-06-28 — client-crypto-setup epic (Phil)

## Arc
Started as a spec question (does `/keys/signatures/upload` belong to device management?) and
grew into a full mini-epic + strategic ADR.

## Spec answers given
- `/keys/signatures/upload` + `/keys/device_signing/upload` are **Cross-signing** (under E2EE),
  NOT §Device Management (which is only `/devices*`). Three layers: keys/upload=device keys;
  device_signing/upload=cross-signing keys; signatures/upload=cross-signing signatures.
- "Schlüssel können nicht eingerichtet werden" = write-then-read-back contract violation:
  keys/query hardcoded empty cross-signing maps, so Element couldn't read back what it uploaded.
  A no-op stub can't satisfy §cross-signing (uploaded keys MUST appear in device_lists.changed
  + keys/query).
- `io.element.e2ee` is Element-proprietary (well-known), NOT spec. `force_disable` kills room-
  encryption UX but NOT the recovery nag (Element removed secure_backup_required/_setup_methods).

## Delivered (epic client-crypto-setup, branch feature/client-crypto-setup, pushed to origin, MR open)
- Story wellknown-e2ee-default (95769d84): io.element.e2ee.force_disable in well-known. VERIFIED LIVE.
- Story cross-signing-readback (f45126cc+52c64cf1): CrossSigningKeyStore (PostgreSQL, migration
  000010), keys/query echo, signatures validate-then-persist merge, device_lists.changed,
  ID-namespace MUST-guard. ADR-011 intact. Routes verified live (401, not 404); migration applied.
- ADR-023 DRAFT (deployment postures Compliance vs Normal) — federation/escrow as open questions.
- All gates green: unit 916, trace P0+P1 100%, Kassandra SEC Gate 1 x2 + Gate 2 CLEAN, retro done.

## Open follow-ups (carried)
1. account_data durability + /sync extension (recovery survives restart) — High.
2. collision errcode 400 M_INVALID_PARAM -> 403 M_FORBIDDEN (my AC6 choice; spec-closer is 403).
3. ADR-023 open Qs: federation auth (native X-Matrix vs mTLS-only), E2EE-off enforceability
   across federation, escrow-client trust model.
4. Element BROWSER verification — DONE 2026-06-29 via stronger evidence than a UI click: a REAL
   Element ed25519 cross-signing identity (alex, subject …0003) is persisted in `cross_signing_keys`
   and Element shows the healthy "Confirm your digital identity / Verify this device" screen on
   login (NOT the key-setup error). The e2e login test itself was red only on a harness dismiss-gap
   ("Skip verification for now" not matched) — fixed in login.steps.ts. Real blocker was env: Dex
   wasn't running (started it) + arm64-emulated Dex too slow for warmup timeouts. Spun off epic
   `e2e-test-rehab` (3 stories: dismiss-verification, recovery-setup scenario, CI/amd64+Dex reliability).
   elixir-unit re-confirmed clean: 916 passed, EXIT=0.

## Note to self
The escrow-E2EE + forked-client endgame is Phil's real strategic goal ("überall einsetzbar").
ADR-011 is now a posture, not a permanent state. See MEMORY.md "Strategic Direction".
