# ADR-023: Deployment Postures — Compliance Mode vs. Normal Mode

## Status

**Proposed (DRAFT)** - 2026-06-28

Extends/evolves: ADR-011 (Managed E2EE Key Escrow). Touches: ADR-020 (clustering),
ADR-008 (node registration / mTLS direction). Federation specifics require the architect
(see Open Questions) — this draft frames the decision; it does not finalize the
federation-auth or escrow mechanisms.

> **Author's note (Oracle):** authored from the Matrix Client-Server API perspective.
> The Server-Server (federation) API is outside my authority; every federation-specific
> claim below is marked as an OPEN QUESTION for the architect, not a decision.

## Context

ADR-011 framed Nebu as a deliberately **managed, non-E2EE** server: encryption is kept off
by rejecting `m.room.encryption`, with a future "managed key escrow" direction. Through the
`device-management`, `element-compat`, and `client-crypto-setup` epics, Nebu has grown a
spec-faithful client surface (device-key directory, account_data, and now an opaque
cross-signing key directory) so that real clients (Element) set up cleanly.

Nebu's product goal has since widened: become an **easy-to-host Matrix server** — a Synapse
alternative — that can serve two distinct customer needs from one codebase:

1. **Compliance Mode** — regulated environments that must guarantee message content is
   server-readable (auditing, eDiscovery, DLP): **E2EE off**, federation (if any) **without**
   E2EE, hardened transport (mTLS direction, per ADR-008).
2. **Normal Mode** — a standard, fully native Matrix deployment: **E2EE on**, native
   federation — a drop-in Synapse-style homeserver.

A third, longer-term strategy reconciles the two: **E2EE _with_ key escrow**, delivered via a
**special forked Matrix client** that performs E2EE while escrowing keys to the server — giving
both confidentiality on the wire and compliance/recoverability. This is the endgame of
ADR-011's "managed escrow" idea.

This ADR exists to make the **mode boundary explicit** before more code assumes "managed
forever." The boundary determines a large amount of spec behavior, so it must be a named
architecture decision, not an emergent property.

## What is already decided and spec-grounded

These hold regardless of how the open questions resolve, and are the basis of the modes:

- **The only spec-available server lever for "E2EE off" is rejecting `m.room.encryption`.**
  The Matrix CS API has **no** server capability flag that tells clients "this server has no
  E2EE." E2EE is negotiated client-side, per room, by the `m.room.encryption` state event
  (§E2E). Compliance Mode = the event-write paths reject it (ADR-011, implemented).
- **`io.element.e2ee.force_disable` is a client hint, not enforcement.** Served in
  `/.well-known/matrix/client` (story `wellknown-e2ee-default`). It is an **Element-proprietary**
  extension (formerly `im.vector.riot.e2ee`), ignored by other clients. It suppresses Element's
  room-encryption UX but does **not** enforce anything and does **not** stop Element's recovery
  /cross-signing setup nag.
- **Cross-signing / device verification is mechanically independent of room E2EE.** The opaque
  cross-signing key directory (story `cross-signing-readback`) lets clients complete verification
  setup with **no room ever encrypted**. It is therefore **mode-agnostic infrastructure** — the
  same code serves both modes. Persisting these keys does **not** enable encryption.
- **All stored crypto material is opaque** (ADR-011): the server holds only public keys and
  client-encrypted blobs; it never gains a private part and never decrypts.

## Decision (proposed)

Nebu supports **two named deployment postures**, selected by deployment configuration:

- **Compliance Mode (default for regulated deployments):**
  - Server rejects `m.room.encryption` (rooms stay unencrypted, content server-readable).
  - `/.well-known/matrix/client` advertises `io.element.e2ee.force_disable: true`.
  - Federation: see OPEN QUESTION F1 (without E2EE; transport hardening per ADR-008).
- **Normal Mode (native Matrix / Synapse-alternative):**
  - Server accepts `m.room.encryption`; full key/cross-signing/backup surface persisted.
  - `/.well-known/matrix/client` omits `force_disable` (or sets `default: true`).
  - Federation: native Matrix federation (see OPEN QUESTION F1).
- **Escrow E2EE (future, orthogonal to the mode switch):** a forked client performs E2EE while
  escrowing keys server-side, giving confidentiality + compliance together. Tracked separately;
  not part of the initial mode switch.

The mode is a **server-internal switch**; clients infer it only from observed behavior
(whether `m.room.encryption` is accepted, what well-known advertises, whether federation
endpoints exist). There is no CS-API "mode" concept to expose.

**Scope discipline:** the `client-crypto-setup` epic deliberately built only the mode-agnostic
client-setup substrate. The mode switch itself, federation, mTLS, and the escrow client are
NOT yet implemented — this ADR records the intended shape, not delivered behavior.

## Open Questions (require the architect — NOT decided here)

**F1 — Federation auth model: native X-Matrix signing vs. mTLS-only.**
Native Matrix federation (Server-Server API) authenticates requests with **signed `X-Matrix`
Authorization headers** (Ed25519 server signing keys, `.well-known/matrix/server`,
`/_matrix/key/v2/server`), **not** mTLS. Implications:
  - If Compliance-Mode federation must **interoperate** with Synapse/Dendrite, Nebu must
    implement the native signed-request model; mTLS can only be additive transport hardening.
  - If federation is **Nebu-to-Nebu only**, mTLS-only is viable but is a **private protocol**,
    not Matrix federation. This choice gates interop and effort massively. (Relates to ADR-008.)

**F2 — "E2EE off" is not enforceable across federation.**
Inside Nebu, `m.room.encryption` can be rejected. But in a **federated** room a client on a
**remote** server can send `m.room.encryption`; Nebu does not control remote clients. So the
Compliance guarantee "no E2EE" holds cleanly only for rooms whose policy Nebu fully controls
(local-only rooms, or federation restricted to other Compliance servers that also reject).
The exact compliance guarantee must be stated precisely (legal + technical).

**F3 — Escrow client trust model.** What exactly is escrowed (per-message keys? cross-signing
private parts?), under what key, with what server-side access controls and audit — and how this
maps onto ADR-011's `user_keys` escrow direction. Needs its own ADR before any implementation.

**F4 — account_data durability.** Recovery/SSSS state currently round-trips via volatile,
node-local ETS and is not in `/sync`. For Normal Mode (and clean Element recovery across
restart) this must become durable (PostgreSQL) and surfaced in `/sync`. Follow-up story.

## Consequences

### Positive
- One codebase serves regulated (Compliance) and standard (Normal) Matrix deployments.
- The cross-signing/device-verification substrate is already built and mode-agnostic.
- The mode boundary is named, so future code stops silently assuming "managed forever."

### Negative / risks
- Compliance Mode's "no E2EE" guarantee is bounded by F2 (federation edge).
- Federation is a large net-new surface (F1) with real interop/effort forks.
- Two modes multiply the test matrix (every E2EE-adjacent behavior ×2).

## Related ADRs
- ADR-011 — Managed E2EE Key Escrow (this ADR evolves it; escrow endgame = F3).
- ADR-008 — Node registration / mTLS direction (relates to F1 transport hardening).
- ADR-020 — Clustering & module architecture.
- Stories: `wellknown-e2ee-default`, `cross-signing-readback` (epic `client-crypto-setup`).
