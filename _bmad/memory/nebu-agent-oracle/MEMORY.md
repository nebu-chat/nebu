# Memory

## Nebu Implementation Scope

Spec version: Matrix CS API v1.18.

Media Gateway (Epic 12) — implemented:
- `POST /_matrix/media/v3/upload`
- `GET /_matrix/media/v3/download/{serverName}/{mediaId}` (deprecated since v1.11)
- `GET /_matrix/media/v3/thumbnail/{serverName}/{mediaId}` (deprecated since v1.11)

Media Gateway (Epic 12) — missing (post-epic open follow-ups):
- `GET /_matrix/client/v1/media/config` — CRITICAL (auth required, Element Web pre-upload check)
- `GET /_matrix/client/v1/media/download/{serverName}/{mediaId}` — CRITICAL (auth required, freeze expected since v1.12)
- `GET /_matrix/client/v1/media/thumbnail/{serverName}/{mediaId}` — CRITICAL (auth required)
- `GET /_matrix/client/v1/media/download/{serverName}/{mediaId}/{fileName}` — MEDIUM
- `GET /_matrix/media/v3/config` — MEDIUM (deprecated but old clients call it)
- `GET /_matrix/media/v3/download/{serverName}/{mediaId}/{fileName}` — MEDIUM
- `POST /_matrix/media/v1/create` + `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` — now in-scope
  for the `media-security-admin-control` epic proposal (2026-07-01), see dated note below
- `GET /_matrix/client/v1/media/preview_url` — LOW

Mutual Rooms (MSC2666, new in v1.19, 2026-10-05):
- `GET /_matrix/client/v1/mutual_rooms` — not implemented as of 2026-10-05 Oracle Gate; this is
  the first review for it. See session 2026-10-05 for the full compact spec report (response
  shape, errcodes, pagination, rate-limit quirk).
- Route-alias quirk (same day, post-review): the historical unstable path
  `GET /_matrix/client/unstable/uk.half-shot.msc2666/user/mutual_rooms` matches the stable v1
  shape on HTTP method, query param names (`user_id`, `from`), and response field names
  (`joined`) — NOT a naming-shim problem. But the real upstream (Synapse) unstable endpoint was
  NEVER paginated (no `count`, no `next_batch`, ever) — it always returned the complete `joined`
  list in one response. Nebu's shared handler pages at 50 by default; a pure pass-through alias
  will silently truncate legacy callers with >50 mutual rooms with one other user. Don't alias
  as a naive pass-through without addressing this — see session 2026-10-05 follow-up for sourcing
  (web research, not local spec, since the bundled mirror has no pre-stabilization history).

Threading (Epic 9):
- `GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}/m.thread` — required for thread panel; status unknown (check before threading epic).

Room Moderation (Epics 7/15) — implemented:
- `POST /kick`, `POST /ban`, `POST /unban`, `POST /forget` — ModerationHandler, story 7-22
- `POST /leave` — inline handler
- `POST /invite` — InviteUserHandler
- `POST /join/{roomIdOrAlias}`, `POST /rooms/{roomId}/join` — JoinRoomHandler
- `PUT /state/m.room.power_levels` → dedicated SetPowerLevels gRPC branch in SetRoomStateHandler

Room Moderation (Epic 15) — MISSING (Story 15-11 scope):
- `PUT /_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}` — P0 MISSING, needs full end-to-end (Gateway + gRPC RPC + Core)

### Device Keys / E2EE Boundary (login "device could not be registered" bug, 2026-06-26)
The device-key directory is ORTHOGONAL to E2EE. Implementing it correctly does NOT activate
encryption — encryption is enabled PER ROOM by the client sending an `m.room.encryption` state
event (§E2E, "In order to enable end-to-end encryption in a room, clients can send an
`m.room.encryption` state event"). So Nebu can implement the full device/key surface and stay
managed-model (ADR-011) as long as no room gets `m.room.encryption`.

Contracts that the no-op stubs violate (these are why Element errors):
- `POST /keys/upload` 200: `one_time_key_counts` is **Required** = unclaimed OTK count per
  algorithm held for THIS device. Constant `{}` breaks OlmMachine reconciliation.
- `POST /keys/query` 200: `device_keys[user_id][device_id]` must echo back the SAME object
  uploaded via /keys/upload + an `unsigned` property. Empty `{}` ⇒ client can't see its own
  device ⇒ "device could not be registered" (dominant trigger).
- `/sync` E2E extension: `device_one_time_keys_count` (req if OTKs exist) +
  `device_unused_fallback_key_types` (**Required**, v1.2).
- `GET /account/whoami`: `device_id` required when a device is bound to the token.
- `GET /_matrix/client/v3/devices` (+ `/devices/{deviceId}`): device manager list.
Guardrail: optionally reject client PUT of `m.room.encryption` to hard-enforce ADR-011.

### device_id ↔ Geräteschlüssel vs. Recht-auf-Vergessen-Key (2026-06-26)
ZWEI verschiedene Schlüssel — nie verwechseln:
- **Matrix-Geräteschlüssel** (device_keys / /keys/upload): 1:1 pro Gerät, CLIENT-generiert, privater
  Teil NIE auf dem Server (§Device keys "the private part ... should never be exported"). device_id
  ist pro-Gerät, viele pro User. "Eine device_id pro User" erzwingen BRICHT die Spec: §Relationship
  between access tokens and devices — "If the client sets the device_id, the server will invalidate any
  access/refresh tokens previously assigned to that device" ⇒ zweite Anmeldung killt erste Session;
  /keys/upload-Uploads zweier Geräte überschreiben sich (PK user,device). NICHT erzwingen.
- **Recht-auf-Vergessen-/Signing-Key** = ADR-007 `user_keys` (per-User Ed25519 signing + X25519
  encryption, serverseitig, beim Provisioning erzeugt, private_key bei GDPR-Löschung genullt). EINER
  pro User, bereits implementiert. PRD "ein Ed25519-Keypair pro User" = dieser serverseitige Key,
  NICHT der Geräteschlüssel/Cross-Signing-Key. Geräteschlüssel taugt NICHT für Erasure (Server hat
  keinen privaten Teil). Empfehlung: Multi-Device behalten, Erasure über user_keys-X25519.

### Strategic Direction — Two Postures + Escrow E2EE (2026-06-28)
Phil reframed ADR-011: Nebu is NOT managed-only forever. It evolves into a full Matrix
server / easy-to-host Synapse alternative with TWO postures:
- **Compliance Mode**: E2EE off (server rejects `m.room.encryption`) + Element well-known
  `io.element.e2ee.force_disable: true`; federation planned WITHOUT E2EE but with mTLS.
- **Normal Mode**: native Matrix — full E2EE + federation.
LONG-TERM (#2 strategy): **E2EE WITH ESCROW** via a SPECIAL FORKED Matrix client that
supports server-side key escrow → reconciles E2EE + compliance in one product. This is the
real endgame of ADR-011 (Managed E2EE key escrow). "Überall einsetzbar."
Federation caveats I raised (Server-Server API, outside my CS-API authority): native
federation auth = signed `X-Matrix` headers + Ed25519 server keys, NOT mTLS — mTLS-only =
Nebu-private, not interoperable with Synapse/Dendrite. "E2EE off" not enforceable across
federation (remote clients can send `m.room.encryption`). Needs its own ADR.

### Cross-Signing / Recovery Setup — why Element errors "Schlüssel können nicht eingerichtet werden" (2026-06-28)
- `/keys/signatures/upload` + `/keys/device_signing/upload` are **Cross-signing** (§cross-signing),
  under **End-to-End Encryption** — NOT under §Device Management (which is only `/devices*`).
  Three layers: `/keys/upload`=device keys; `/keys/device_signing/upload`=cross-signing KEYS
  (MSK/USK/SSK); `/keys/signatures/upload`=cross-signing SIGNATURES.
- Stub SHAPES are already spec-correct: device_signing/upload→`{}`; signatures/upload→`{"failures":{}}`.
  Shape is NOT the bug.
- ROOT CAUSE = write-then-read-back contract. §cross-signing: uploaded keys MUST appear in
  `/sync` `device_lists.changed` + be returned by `/keys/query` (master/self/user_signing). Nebu's
  `/keys/query` HARDCODES those maps empty (`server/lib/nebu/web/router/protected.ex:288-294`) →
  Element uploads cross-signing keys, reads back empty → "keys cannot be set up". A pure no-op
  stub CANNOT satisfy this contract.
- `io.element.e2ee` (well-known `/.well-known/matrix/client`) is ELEMENT-PROPRIETARY (formerly
  `im.vector.riot.e2ee`), NOT Matrix spec — other clients ignore it. `force_disable:true` kills
  ROOM encryption UX but does NOT stop the RECOVERY setup nag: Element REMOVED
  `secure_backup_required`/`secure_backup_setup_methods`; recovery is "always recommended"
  (one-off toast + red dot). So the recovery/cross-signing bootstrap still runs → still errors
  until the read-back is fixed. True E2EE-off enforcement = rejecting `m.room.encryption` (server),
  well-known is only a client hint.
- Cross-signing/device-verification is MECHANICALLY INDEPENDENT of room E2EE — you can persist
  cross-signing opaquely (clients get verified-session UX) while every room stays unencrypted.
  So the opaque store is modus-agnostic infra, compatible with Compliance Mode.
- Current stub state: device_signing/upload→{} (protected.ex:236); signatures/upload→{"failures":{}}
  (:366); keys/query cross-signing maps empty (:288); account_data ETS volatile node-local + NOT in
  /sync (:489 + :729 `"account_data" => []`); room_keys/version→404 (:217); well-known only
  `m.homeserver` (router.ex:115). MUST when persisting cross-signing: device IDs must not collide
  with cross-signing key IDs (shared `ed25519:` namespace).

### Epic DONE — client-crypto-setup / E2EE-readiness (2026-06-28)
Mini-epic via nebu-pipeline-epic, COMPLETE. SCOPE GUARDRAIL (Phil insisted): ONLY proper client
setup / E2EE-readiness — NOT the mode-toggle feature. Two stories, both done + all gates green:
- (1) `wellknown-e2ee-default` (commit 95769d84): `io.element.e2ee.force_disable:true` in
  `/.well-known/matrix/client` (router.ex). Static default, mode-prep. Kassandra CLEAN.
- (2) `cross-signing-readback` (commits f45126cc + 52c64cf1): `Nebu.Matrix.CrossSigningKeyStore`
  (PostgreSQL, **migration 000010**) + reworked device_signing/upload (persist, idempotent,
  403 on unauth overwrite), keys/query echoes the 3 cross-signing maps, signatures/upload
  validate-then-persist merge, /sync device_lists.changed, MUST-guard ID-namespace collision.
  ADR-011 intact (opaque, m.room.encryption still 403). Kassandra SEC Gate 1 + Gate 2 CLEAN
  (epic report: _bmad-output/implementation-artifacts/epic-client-crypto-setup-security-review-2026-06-28.md).
NOT done in scope (explicit follow-ups): account_data durability + /sync account_data extension;
Compliance/Normal mode switch; federation; mTLS; escrow client.
DEPLOY: needs `make redeploy` so migration 000010 applies; then verify Element recovery/cross-
signing bootstrap actually completes (the real acceptance is Element no longer showing
"Schlüssel können nicht eingerichtet werden").

### Async Media Upload — corrections to draft epic (2026-07-01)
Reviewed `tmp/media-epic.md` (Epic: Media Security & Admin Control, Story 2) — the async-upload
part was old/wrong on several points vs. v1.18. No MSC any more: `POST /_matrix/media/v1/create`
+ `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` were merged into core spec at v1.7, no
MSC2246 reference or unstable-flag remains. Key fidelity corrections applied to the epic doc:
- `POST .../create` takes **no request params at all** — no client-supplied `expires_at`. Server
  sets `unused_expires_at` unilaterally (spec-recommended default 24h) and **must** return it
  alongside `content_uri` in the 200 body (draft only had `content_uri`).
- Server SHOULD cap concurrent *pending* uploads per user → `429 M_LIMIT_EXCEEDED` +
  `retry_after_ms` if exceeded. Not in the original draft.
- `PUT .../upload/{serverName}/{mediaId}` needs an **ownership check**: 403 `M_FORBIDDEN` if the
  caller isn't the same user who called `/create` — spec names this explicitly as a 403 cause.
  Draft only checked state (`:reserved`), not identity.
- Must return `409 M_CANNOT_OVERWRITE_MEDIA` (not a generic 400) when PUT targets a media ID that
  already has content — applies even to an idempotent retry of an already-successful upload; spec
  has no idempotency exception here. Missed entirely in the draft.
- `404 M_NOT_FOUND` for unknown/expired media ID must be a **live check in the PUT handler**, not
  only enforced by the cleanup cron (race window between cron runs).
- `Content-Type` header on PUT is optional since v1.12 (defaults to `application/octet-stream`);
  `filename` query param should be persisted like the sync upload path for `Content-Disposition`.
- `413` (body over max upload size) must be enforced at PUT time before writing to disk —
  orthogonal to `Nebu.Media.ClamAV`'s `max_file_size_bytes` (that only gates whether scanning
  happens, not whether the upload is accepted).

### OPEN spec-fidelity follow-up — collision errcode 400 vs 403 (2026-06-28)
In `cross-signing-readback` AC6 I (Oracle) specified the device↔cross-signing ID-namespace
collision to return **400 M_INVALID_PARAM**. The dev gate flagged: §device_signing/upload defines
a **403 M_FORBIDDEN "Key ID in use"** response, which is the closer spec precedent for an
ID-already-in-use rejection. The spec gives NO explicit errcode for the device-vs-cross-signing
MUST-guard specifically, so 400 is defensible but 403 M_FORBIDDEN is more spec-aligned. Story
honored my 400 choice; logged here as a small fidelity follow-up for the team to confirm or
switch. NOT a security/functional bug.

### Media Lifecycle / per-room policy / redaction (ADR-030 consult, 2026-07-02)
Winston consulted me for ADR-030 (Media Lifecycle Rules & Two-Eyes Delete). Three rulings:
- **Redaction vs. 404:** Content Repository has NO "media withdrawal" concept — a download **404 is
  spec-neutral** (allowed, not mandated). `m.room.redaction` is the ONLY spec tool to remove the
  reference itself; room v11 redaction strips the **entire** `content` of `m.room.message` (url/info/
  thumbnail_url/body — not in the allow-list). Irreversible, PL-gated. So: legal-hold = 404
  (reversible restriction); redaction only as an operator-initiated, PL-gated add-on, never
  auto-coupled to a hold that two-eyes might later release.
- **mxc lives in 6 content fields** (for any events.content join): `content.url`,
  `content.info.thumbnail_url` (m.room.message image/file/audio/video, m.sticker, m.room.avatar);
  `content.avatar_url` (m.room.member); and for ENCRYPTED msgs `content.file.url` +
  `content.info.thumbnail_file.url` (EncryptedFile replaces url/thumbnail_url). No media↔room
  ownership in spec; one mxc → many rooms.
- **⚠️ Per-room media policy is COMPLIANCE-MODE-ONLY.** In E2EE rooms `content` is Megolm ciphertext,
  so the server can't see `content.file.url` → the room→media join is impossible. Encrypted rooms
  MUST fall back to global policy. Spec consequence (ties ADR-011/023).
- **Spaces (§Spaces):** `m.space.child` (in space-room, trust anchor) vs `m.space.parent` (in child,
  a CLAIM — ignore unless matching child OR sender has PL for m.space.child in the parent). Multiple
  parents allowed (`canonical` tiebreak = lowest room id lexicographically); nesting allowed, loops
  disallowed-but-possible (guard), link is DYNAMIC (demotion/leave can invalidate). Resolve at cron
  eval time, not per-download.
Full detail: sessions/2026-07-02.md.

## Known Spec Decisions
_Deliberate implementation choices — accepted deviations, spec ambiguity resolutions. Not re-flagged as findings._

### State events return empty event_id (MVP) — scope widened 2026-10-02
All `PUT /state/{eventType}` responses return `{"event_id":""}` — Core generates IDs but Gateway drops them. This is a MUST violation; Story 15-11 should fix it. Not yet an accepted deviation — it is a known bug to be resolved.
Widened scope (bugfix epic, 2026-10-02): `GET /sync` `rooms.join.<room_id>.state.events` entries
ALSO drop real `event_id`/`origin_server_ts` — confirmed via spec (`state.events` and
`timeline.events` are both typed `ClientEventWithoutRoomID`, same Required fields, no
state-vs-timeline carve-out). Same underlying defect family, broader surface than just the PUT
response. Once the bugfix lands, mark this whole entry resolved instead of leaving it open.

## Spec Quirks for This Codebase

### Rate limiting — `retry_after_ms` deprecated since v1.10 (2026-10-05)
§Rate limiting (generic, applies to EVERY 429 across the whole CS API, not just one endpoint):
`retry_after_ms` was **deprecated in v1.10** in favor of the `Retry-After` HTTP header. It is
MAY/optional in the 429 JSON body (no "Required:" marker), homeservers SHOULD set the
`Retry-After` header instead. Any story/AC assuming a body `retry_after_ms` field is spec-
mandated is wrong — flag it. Found while reviewing `mutual_rooms` (MSC2666) but applies project-
wide to every 429 response shape.

### Media — Authenticated Endpoints Freeze (v1.11/v1.12)
Per §Media Repository v1.18: since v1.11, `/_matrix/media/v3/` download/thumbnail/config are deprecated. Since v1.12, servers SHOULD "freeze" them — newly uploaded media only accessible via authenticated `/_matrix/client/v1/media/` endpoints. Element Web (current) will prefer the authenticated form. Without those endpoints, images uploaded after a hypothetical freeze will not display.

### Media — 451 for M_NOT_YET_UPLOADED/M_NOT_FOUND is a Nebu overlay, not spec (2026-07-13)
`media-security-admin-control` epic gates download/thumbnail on `media_files.state`: pending states
→ 451 `M_NOT_YET_UPLOADED`, `:admin_blocked` → 451 `M_NOT_FOUND` (body identical to genuine 404).
Spec fact-check: CS API v1.18 pairs `M_NOT_YET_UPLOADED` with **HTTP 504** (both v1 auth and
deprecated v3 download endpoints), never 451 — `451` does not appear anywhere in the spec's media
section. `M_NOT_FOUND` is a "common error code" with NO status mandated at all (spec explicitly
says clients should trust errcode over HTTP status). Precedent for "look like 404" already exists:
deprecated v3 download MAY return 404 M_NOT_FOUND for real-but-frozen media (v1.11). Conclusion:
451 is spec-safe (errcode-first client behavior) but a deliberate Nebu deviation from the documented
504 pairing — do NOT "fix" it back to 504 later without re-checking this decision. Not re-flagged
as a compliance finding. Full detail: sessions/2026-07-13-media-lifecycle-gate-spec-check.md.

### Media — wait/stall query param is `timeout_ms`, not `timeout` (2026-07-14)
On all four download-endpoint variants (`/_matrix/client/v1/media/download/{serverName}/{mediaId}`
+ `/{fileName}`, and the deprecated `/_matrix/media/v3/download/...` equivalents) the spec's
query param name is `timeout_ms` (integer, milliseconds; added v1.7; spec default 20000ms when
absent; content repo SHOULD cap it, MAY respond early). Story `2d-download-stall-mechanism`
drafted it as `?timeout=N` — flagged CRITICAL in that story's Oracle Gate: a real client (which
sends `timeout_ms` per spec) would never trigger the stall path if the handler only recognizes
`timeout`. Story 1c's own oracle-context.md already had `timeout_ms` right; 2d regressed the
name. Full detail: sessions/2026-07-14.md.

### Media — SHOULD Headers Missing from download + thumbnail handlers
`media/internal/download/handler.go` and `media/internal/thumbnail/handler.go` set `X-Content-Type-Options: nosniff` but are missing:
- `Content-Security-Policy: sandbox; default-src 'none'; script-src 'none'; plugin-types application/pdf; style-src 'unsafe-inline'; object-src 'self';` — SHOULD (§Media Repository)
- `Cross-Origin-Resource-Policy: cross-origin` — SHOULD (§Media Repository, added v1.4)

### Threading — Bundled Aggregations + /relations
First reply in thread not visible in Element Web because:
1. Bundled aggregations on thread root not sent in non-limited sync (spec: only when `limited: true`, but Element Web needs them to discover threads)
2. `GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}/m.thread` endpoint (v1 prefix) required to populate thread timeline — see session 2026-05-08.

### Token Refresh — `POST /_matrix/client/v3/refresh` (Added in v1.3)
Key rules for Nebu implementation:
- **Old refresh token grace (MUST):** Old RT remains valid until the new access token or new refresh token is _used_. Ensures clients that fail to persist new tokens can retry the refresh.
- **Old access token:** Server MAY invalidate immediately or leave until natural expiry. Clients MUST NOT assume it's still valid.
- **soft_logout SHOULD accompany expired token 401s:** `{"errcode":"M_UNKNOWN_TOKEN","soft_logout":true}` for expired-but-session-intact sessions; omit `soft_logout` (or `false`) for sessions that are destroyed.
- **Client signals refresh support:** `"refresh_token": true` boolean in `POST /login` request body. Server MAY issue non-expiring tokens to clients that don't signal this.
- **Login response extras (v1.3):** `expires_in_ms` (integer, optional) + `refresh_token` (string, optional) — only return when client sent `refresh_token: true`.
- **Token format:** Spec mandates opaque bytes — Nebu can use 32-byte random hex, identical to admin sessions.
- **Device binding:** New tokens from refresh remain bound to the same device_id as the initial tokens.

### Known Non-Compliance: Matrix User Sessions
Current implementation returns OIDC `id_token` directly as Matrix `access_token`. No `POST /refresh` endpoint. No `expires_in_ms` in login response. This causes sessions to expire after Keycloak's access token TTL (default 5 min). Story `oidc-session-refresh` in epic `bugfix/fix-short-oidc-sessions` will fix this.

## Open Questions

- Is `GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}/m.thread` implemented? (threading endpoint, v1 prefix — see session 2026-05-08)
- Are the authenticated media endpoints (`/_matrix/client/v1/media/`) planned for a follow-up epic?
