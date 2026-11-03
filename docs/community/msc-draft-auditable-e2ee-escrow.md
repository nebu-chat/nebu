# MSC0000: Auditable end-to-end encryption through mandatory escrow recipients

> **Status: discussion draft.** Not yet submitted. Replace `0000` with the PR number once the draft PR is open.
> Lines are wrapped at 120 characters as the proposals repository asks.
> Items marked **[TODO]** need an author decision or a reference implementation before the Final Comment Period.

## Summary

Organisations that must retain and produce their communication (public administration, financial services,
anything under records-retention or eDiscovery duties) cannot use Matrix end-to-end encryption today, because
only the endpoints hold the keys. In practice they switch encryption off, which is the worse outcome for
everybody on the wire and in backups.

This proposal lets a room declare, in room state and in a way every member can see, that its messages are
encrypted **to the members and additionally to one or more named escrow recipients**. A client that does not
understand the mechanism must refuse to send in such a room instead of silently skipping the escrow step.

Two variants are described. The proposal asks the Spec Core Team to choose one, or to ask for a merge of both.

## Motivation

A server operator in a regulated organisation has three options today:

1. Disable encryption. Compliant, but no confidentiality against servers, backups or operators.
2. Enable encryption and accept that content cannot be produced on legal request.
3. Run a compliance bot as a room member that receives room keys like any other device. This works with
   existing clients and is how some deployments operate today. Its weakness is that it is voluntary on the
   sender's side: nothing tells the client that the bot **must** receive the key, and nothing stops a member from
   removing the bot or sending to a room where it was never invited. Compliance then holds only for users of a
   specially configured client, which is a guarantee in name only.

The gap is not cryptography, it is **an agreed signal in room state plus a fail-closed rule for clients**. That
is a specification matter and cannot be solved by a single implementation.

### Second motivation: recoverability

Organisations report a second, independent problem. Users lose their devices and their recovery material, and
with them access to their own history ("unable to decrypt"). For an authority this is an operational incident
comparable to losing a master key, and in an organisation there is nobody who can help, because every existing
recovery mechanism is held by the individual user.

Matrix already has server-side key backup and secret storage, so the problem is **not a missing mechanism but
who holds the key**:

- Secret storage may encrypt one secret under several keys: the `encrypted` map of a secret is keyed by key ID
  and one key is marked as default (`m.secret_storage.default_key`). An organisation key can therefore sit next
  to the user's own key for `m.megolm_backup.v1` and the cross-signing secrets without any specification change.
  What the specification does not provide is a way to make that **happen reliably**: only a client holding the
  plaintext secret can add the entry, nothing tells a client that it should, and any client that resets secret
  storage drops the entry.
- Key backup is similarly user-held. The decryption key lives in secret storage or with the user.
- Key forwarding (`m.room_key_request`, `m.forwarded_room_key`) only recommends that keys go to verified devices
  of the same user. It defines no role for an organisational recipient.

The escrow recipients in this proposal serve both purposes with one mechanism. Audit and recovery differ in
**policy** (who may request, under which approval), not in cryptography. See the section "Recovery flow".

### What the specification leaves open today

When a client creates a Megolm session it must share the key with "the intended recipients". The specification
does not define that set. In practice clients use all devices of all joined members. A compliance bot that is a
joined member therefore already receives keys from standard clients, and some deployments rely on exactly that.
This is a convention, not a rule: it gives no way to say that a recipient is **required**, and a client
configured to skip unverified devices skips the bot as well. **[TODO: test against current Element Web, Element
X and FluffyChat, including their "exclude unverified devices" settings, before stating this as fact in the
submitted text.]**

### Why this belongs in the specification and not in a vendor extension

[MSC1779](https://spec.matrix.org/proposals/) (Guiding Principles) asks that proposals benefit the whole
ecosystem and not a single player. The argument for that here is:

- Without a shared signal, every vendor that serves regulated customers invents an incompatible one, and
  standard clients cannot interoperate with any of them.
- Today those customers turn encryption off. A standard way to keep it on, with transparent and
  user-visible escrow, improves the privacy outcome compared with the status quo.
- The mechanism is explicit, opt-in per room and visible. It does not add capability to rooms that do not
  use it.

## Goals

- A room can require escrow recipients, visibly and cryptographically bound to room state.
- Clients that do not support the mechanism **fail closed**: they cannot send into such a room.
- Users see, at join time and continuously, that the room has escrow recipients and who they are.
- Reuse existing primitives (Megolm, Olm, key-backup session encryption) instead of adding new cryptography.
- Support several independent recipients, so that custody can be split (for example organisation plus data
  protection officer, or threshold schemes behind one key).
- Rotation of the escrow key.

## Non-goals

- Defining who holds the escrow private key, how access is approved, or how access is logged. This is
  organisational policy. The proposal only recommends that implementations support multi-party or threshold
  custody and an audit trail.
- Preventing an **adversarial** client from sending garbage or skipping escrow. See Security considerations:
  this proposal makes compliance enforceable for cooperating clients and **detectable** for adversarial ones,
  not impossible to evade.
- Any covert or hidden escrow. Escrow recipients are public room state.
- Law-enforcement access to rooms that did not opt in.

## Common to both variants

### New encryption algorithm identifier (fail-closed)

`m.room.encryption` gets a new `algorithm` value. Clients that do not know the value cannot encrypt for the
room and display it as unsupported. Using a **new algorithm value** instead of a new optional field is the
core of the fail-closed property: older clients ignore unknown fields in state events and would send
unprotected. Unknown algorithms, by contrast, already stop them.

```json
{
  "type": "m.room.encryption",
  "state_key": "",
  "content": {
    "algorithm": "m.megolm.v1.aes-sha2.escrow",
    "rotation_period_ms": 604800000,
    "rotation_period_msgs": 100,
    "escrow": {
      "recipients": [
        {
          "key_id": "esc-2026-01",
          "label": "Compliance archive",
          "curve25519": "<base64 public key>",
          "ed25519": "<base64 signing key>",
          "valid_from_ts": 1767225600000
        }
      ]
    }
  }
}
```

Names are placeholders. Unstable value while the MSC is open: `eu.getnebu.msc0000.megolm.v1.aes-sha2.escrow`
**[TODO: confirm vendor prefix domain]**.

### Visibility and consent

- Clients MUST show an escrow indicator in the room header and in room details, listing `label` and `key_id`
  of every recipient. It must be distinguishable from the ordinary encrypted-room lock.
- Clients MUST show the same information in the invite and join preview, before the user accepts.
- Changing the recipient list is a state event change. Clients MUST show it in the timeline like any
  membership or power-level change.

### Who may change the recipients

Changing `escrow` requires the power level for `m.room.encryption` as today. Rooms created with the escrow
algorithm SHOULD set that level so that ordinary members cannot remove recipients. Servers MAY enforce a
policy that disallows downgrade to a non-escrow algorithm for rooms that started with one. The existing rule
that encryption cannot be disabled once enabled already covers the plain case. **[TODO: check how existing
servers treat an algorithm change inside an already encrypted room, and whether a room upgrade is the cleaner
path.]**

### Rotation

A new `key_id` appended to the list starts to apply from `valid_from_ts`. Old Megolm sessions stay readable
with the old key, new sessions are shared with both until the old entry is removed. Clients SHOULD start a
fresh outbound Megolm session after every change to the list.

### Federation

Both variants only change event content and room state, so they pass through federation unchanged. Users of
other servers who join the room are told by their client as above. A homeserver that does not allow
escrow-enabled rooms may refuse them by policy, as it may refuse any room version or feature today.

---

## Variant A: escrow recipients receive the session key like devices

The escrow recipient is treated as an additional device to which every sender shares each outbound Megolm
session. This is the smallest change and mirrors what a compliance bot does today, but makes the sharing
mandatory and visible.

1. When a client creates an outbound Megolm session for the room, it MUST send an `m.room_key` to-device
   message, Olm-encrypted, to each `curve25519` identity key listed in `escrow.recipients` that is valid at
   the current time.
2. The client MUST NOT withhold the key because the recipient is unverified or blacklisted. Escrow recipients
   are trusted by room state, not by per-user verification.
3. Delivery uses the recipient's registered device, so the recipient must publish its device keys and
   one-time keys through the existing `/keys/upload` and `/keys/claim` endpoints. An escrow recipient is
   therefore an ordinary service account with one device whose identity keys equal the ones in room state.
4. A client MUST NOT send a message in the session until Olm messages for all current escrow recipients have
   been queued. Failure to queue them MUST be reported to the user as a send error.
5. Late join of a recipient (rotation) is handled by the existing `m.room_key_request` / key-forwarding
   behaviour, or by an immediate new session.

**Advantages:** very small spec delta, no change to `m.room.encrypted`, no per-message overhead, escrow
recipients are ordinary accounts that can be monitored and rate-limited by servers.

**Disadvantages:** servers cannot verify anything at send time. An escrow recipient that is offline accumulates
to-device messages. A client that skips step 1 is detected only when the recipient fails to decrypt, which can
be long after the fact. Needs an account and a device per recipient.

---

## Variant B: escrow envelope inside the event

Every `m.room.encrypted` event of the escrow algorithm carries an envelope for each current recipient.

```json
{
  "type": "m.room.encrypted",
  "content": {
    "algorithm": "m.megolm.v1.aes-sha2.escrow",
    "sender_key": "<sender curve25519>",
    "device_id": "DEVICEID",
    "session_id": "<megolm session id>",
    "ciphertext": "<megolm ciphertext>",
    "escrow": [
      {
        "key_id": "esc-2026-01",
        "session_data": {
          "ephemeral": "<base64>",
          "ciphertext": "<base64>",
          "mac": "<base64>"
        }
      }
    ]
  }
}
```

1. `session_data` is the Megolm session key **at the message index of this event**, encrypted exactly as
   server-side key backup encrypts session data (`m.megolm_backup.v1.curve25519-aes-sha2`), to the recipient's
   `curve25519` key. Reusing that format keeps new cryptography to zero. The recipient can decrypt this event
   and everything after it in the session, but nothing before it.
2. Clients MUST include one envelope per current recipient. The `key_id` MUST match a recipient in room state.
3. Servers SHOULD reject (`400 M_BAD_JSON`) events that lack an envelope for a current `key_id`, or whose
   envelope exceeds a size limit. Servers cannot check that the envelope is decryptable.
4. **Optimisation [TODO]:** require the envelope only on the first event of each `session_id`. The recipient
   ratchets forward from the exported index. This cuts overhead to near zero but forces servers to remember
   which `session_id` values already carried an envelope, which is state they do not keep today.

**Advantages:** enforceable in part at the server (presence and format), works without an online recipient
and without an account or device, escrow material travels with the event and thus with any export or backup
of it.

**Disadvantages:** larger spec delta, larger events (roughly 300 to 400 bytes per recipient per event without
the optimisation), more server logic, and the envelope is a new place for implementation errors.

---

## Choosing between A and B

| Property | A (device-like recipient) | B (envelope) |
|---|---|---|
| Spec change | Room state plus client rule | Room state plus event format plus server check |
| Event size | unchanged | grows per recipient |
| Server-side presence check | none | yes (presence and format only) |
| Needs an online recipient | to receive keys, can queue | no |
| Detects a skipped escrow | at audit decrypt time | at send time for presence, at audit time for content |
| Fits existing compliance-bot deployments | directly | needs migration |

The author's current preference is **[TODO: decide]**. Variant A is the cheaper first step; Variant B is the
stronger one if the Spec Core Team wants servers to take part in enforcement.

## Potential issues

- **Single point of compromise.** Whoever holds the escrow key can read the room. This is inherent to any
  escrow and is the reason custody is out of scope here but recommended to be multi-party.
- **Adversarial clients.** A modified client can skip Variant A's key share or put random bytes in Variant B's
  envelope. Neither variant can prevent it cryptographically. Deployments that need prevention must control
  which clients can connect, for example by device allowlisting or attestation on the server side. The
  specification only gives them a signal to check and a common format to audit.
- **Misuse.** An attacker who gains power to change room state could add their own recipient. This is not
  new: such an attacker could also invite themselves. The visibility rules make it a visible event.
- **Cross-signing and verification UX.** Escrow recipients must not show up as "unverified device" warnings.
  Clients should render them from room state, not from the device list.
- **Backups and history.** A new joiner receives history through the usual mechanisms and is not affected.

## Alternatives

- **Compliance bot only, no spec change.** Works today (see Motivation) but gives no fail-closed behaviour.
- **No encryption plus server-side retention.** What regulated operators do now.
- **Client-side archiving to an external system.** Every client must implement it and is trusted to do it.
- **Escrow at the homeserver (server holds the keys).** Not end-to-end, and the server operator becomes the
  point of compromise without any protocol-level visibility to users.
- **MLS-based rooms with an auditor as a member.** If Matrix adopts MLS for group messaging, an auditor
  member could cover the same need. That would supersede this proposal for such rooms. **[TODO: reference
  the relevant MLS proposal after checking its current status.]**

## Security considerations

- Escrow recipients are explicit parties of the room. The proposal should be read as **managed end-to-end
  encryption**: no intermediary between the endpoints and the escrow recipients can read content, but the
  recipients can. Clients MUST NOT present such a room as private to the members alone.
- Unsupported-client fail-closed behaviour rests on algorithm negotiation. Implementations MUST NOT fall back
  to `m.megolm.v1.aes-sha2` for rooms with the escrow algorithm.
- Key IDs must be unique per room. Reuse of a `key_id` with a different key MUST be rejected by clients.
- Escrow private keys SHOULD be kept in an HSM or split between parties. Access SHOULD be logged and approved
  by more than one person. Neither is a protocol matter.

## Privacy considerations

- Transparency is the main mitigation. Members see recipients before and after joining.
- Users of another organisation joining via federation must be informed in the join preview.
- Operators should publish who can request decryption and under which process. The specification may point to
  this as a recommendation.

## Unstable prefix

| Stable | Unstable while open |
|---|---|
| `m.megolm.v1.aes-sha2.escrow` | `eu.getnebu.msc0000.megolm.v1.aes-sha2.escrow` |
| `escrow` (in `m.room.encryption` and `m.room.encrypted` content) | `eu.getnebu.msc0000.escrow` |

Feature flag in `/_matrix/client/versions` `unstable_features`: `eu.getnebu.msc0000` (clients and servers
that implement this proposal advertise it). **[TODO: confirm vendor prefix domain.]**

## Dependencies

None. Builds on Megolm, Olm and server-side key backup as they stand.

## Reference implementation **[TODO]**

The Spec Core Team requires a working implementation before the Final Comment Period. Planned: Variant A or B
in a client built on a maintained SDK (matrix-dart-sdk or matrix-js-sdk), and in the Nebu server for the
server-side checks. Nothing is implemented yet.
