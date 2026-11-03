# Nebu: request to be listed on matrix.org/ecosystem/servers

Draft text for an issue (and, once agreed, a PR) in `matrix-org/matrix.org`.
The matrix.org README asks contributors to discuss a change in the issue tracker before opening a PR, so
start with the issue and let the website maintainers say where the list data lives.

Items marked **[confirm]** are facts I could not verify from the repository alone.

---

## 1. Directory card (what readers see on the list)

The public list shows: name, maturity (Stable / Beta / Alpha / Obsolete), maintainer, licence, language,
short description and links. It has no federation or E2EE column, so the short description has to carry
the disclosure.

| Field | Value |
|---|---|
| Name | Nebu |
| Maturity | Alpha |
| Maintainer | innoQ **[confirm: "innoQ Deutschland GmbH" or personal]** |
| Licence | Apache-2.0 |
| Language | Elixir |
| Repository | https://gitlab.opencode.de/nebu/nebu-server (GitHub mirror `innoq/nebu` **[confirm it exists and is public]**) |
| Homepage | **[confirm: getnebu.eu or nebuchat.eu, the repo uses both]** |

**Short description (about 400 characters):**

> Matrix Client-Server API server for closed organisations that need server-side auditability
> (compliance export, four-eyes access, signed audit log). By design it has no end-to-end encryption and
> currently no federation, so it is not a replacement for a general-purpose homeserver. Works with
> standard Matrix clients. OIDC-only login, Elixir/OTP and PostgreSQL only.

---

## 2. Issue text

**Title:** Add Nebu (Matrix C-S API server for closed, audit-bound organisations) to the servers list

**Body:**

Hello,

we would like to propose Nebu for the servers list. Because Nebu makes two deliberate trade-offs that most
listed servers do not, we spell them out first so that you can decide whether the list is the right place
for it.

### What Nebu is

Nebu is an Apache-2.0 server that implements the Matrix Client-Server API for organisations that must be
able to read, retain and export their own communication: public administration, regulated industries,
enterprises with eDiscovery and records-retention duties. Standard clients (Element, Cinny, FluffyChat) work
without modification. Authentication is OIDC only. Storage is PostgreSQL only. It is a single Elixir/OTP
release that scales horizontally. Current status is pre-alpha, hence the "Alpha" maturity above.

### Two deliberate limitations

**1. No end-to-end encryption.**
Nebu does not support E2EE. The server rejects `m.room.encryption` in every write path (direct state PUT,
`initial_state` in `createRoom`, room upgrade), so rooms stay unencrypted and the server can read all
content. Traffic is protected with TLS 1.3 and media at rest with AES-256-GCM. This is a product decision,
not a missing feature: the organisations Nebu targets are legally required to retain and produce message
content, which is impossible if only the endpoints hold the keys.
Consequence for readers: **do not use Nebu where confidentiality against the server operator is required.**
Device-key endpoints exist only so that clients complete their setup without errors; they do not enable
encryption.

**2. No federation (today).**
Nebu does not implement the Server-Server API and cannot talk to Synapse, Dendrite, Conduit or other
homeservers. Users of a Nebu instance can only talk to users of the same instance. We plan a restricted
federation between known, mutually authenticated Nebu instances (mTLS plus an allowlist, no open Matrix
federation, still without E2EE). That plan is not implemented and not yet a finished design **[confirm
wording matches your current ADR]**. It would not make Nebu a member of the open federation.

### Disclosed deviations from the specification

- E2EE is refused by server policy (see above), which clients will see as a refused state event.
- Only a subset of the Client-Server API is implemented. The inventory with status per endpoint is in
  `docs/matrix-api-scope.md`. `/versions` currently advertises v1.1 to v1.11 **[confirm against the
  running server]**.
- No Server-Server API, no identity server.

### Why we think the list is still the right place

The list is how many operators discover alternatives to self-hosting Synapse. A clearly labelled server for
closed organisations helps those operators find a fit and, just as important, helps everyone else
recognise that it is not one. If the list requires federation or E2EE for inclusion we would like to know
that criterion, since the page currently states none. In that case we would also accept a note on the entry,
a "closed deployment" tag, or a separate section.

### Related work

We intend to submit a Matrix Spec Change proposal for **auditable E2EE with mandatory escrow recipients**,
so that regulated organisations could use end-to-end encryption and still meet retention duties, using
standard clients. Link: **[add MSC PR once opened]**. Until such a mechanism exists in the specification,
Nebu stays unencrypted.

Repository: https://gitlab.opencode.de/nebu/nebu-server
Contact: philipp.beyerlein@innoq.com **[confirm which address to publish]**

---

## 3. Likely objections and short answers

| Objection | Answer |
|---|---|
| "Matrix is about federation, this is not Matrix." | Nebu implements the Client-Server API and is explicit about not being a homeserver in the federation sense. The card says so in the first sentence of the limits. |
| "No E2EE undermines Matrix's privacy goals." | Agreed, which is why the limitation is in the description and the server refuses encryption instead of pretending to offer it. Nebu is for employers and authorities who already hold the legal right to read the content. |
| "Why not use Synapse with E2EE off?" | Operational footprint and licensing: Apache-2.0 instead of AGPL, no Redis/worker topology, built-in four-eyes access and audit export. |
| "Pre-alpha." | Listed as Alpha. We have no objection to being removed again if the maturity is not yet right for the list. |
