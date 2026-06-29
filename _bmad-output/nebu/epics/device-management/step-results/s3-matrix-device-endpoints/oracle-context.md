# Oracle — Matrix CS API v1.18: Device-Management + UIA (Nebu device-management S3)

## 1. Endpoint request/response shapes + MUST rules

- **PUT `/_matrix/client/v3/devices/{deviceId}`** (rename) — auth required, NOT UIA-gated.
  - Request body: `{ "display_name": "My other phone" }` — `display_name` optional ("If not given, the display name is unchanged"); empty body `{}` is valid (no-op).
  - 200 body: `{}` — MUST return 200 when an existing device is updated.
  - 404: "The current user has no device with the given ID." MUST → covers both another-user's device and non-existent ID (AC2's 404 M_NOT_FOUND).
  - 201 + `{}` is *only* for app-service device creation; **regular clients may only update existing devices** — Nebu (no AS) never returns 201.

- **DELETE `/_matrix/client/v3/devices/{deviceId}`** — UIA-gated. "Deletes the given device, and invalidates any access token associated with it."
  - Request body: `{ "auth": { <auth dict> } }` — body carries ONLY the UIA `auth` dict (no other params). First call has no `auth` → 401.
  - 200 body: `{}` — "successfully removed, **or had been removed previously**" → idempotent.
  - 401 → UIA challenge (see §2). Deleting another user's device → 404 (per AC3; same "no such device for current user" rule as PUT).

- **POST `/_matrix/client/v3/delete_devices`** — UIA-gated (bulk).
  - Request body: `{ "auth": { <auth dict> }, "devices": ["QBUAZIFURK","AUIECTSRND"] }` — `devices` is **Required** `[string]`; `auth` optional on first call.
  - 200 body: `{}` — "removed, or had been removed previously" → idempotent.
  - 401 → UIA challenge.

## 2. UIA wire format (§User-Interactive Authentication API; §SSO during UIA; §Fallback)

- **401 body fields:** `flows` (**Required**, `[{ "stages": [string] }]`), `params` (`{string: object}`, may be `{}`), `session` (string), `completed` (`[string]`, present once a stage succeeds), and on a failed-but-retryable stage adds standard `errcode` + `error` (e.g. `M_FORBIDDEN`/"Invalid password").
- **AC5 401 body** is exactly spec-shaped: `{ "flows": [ { "stages": ["m.login.sso"] } ], "session": "<id>", "params": {} }`. ✓
- **Re-submit `auth` dict:** `{ "type": "<auth type>", "session": "<id>", ...type-specific keys }`. `type` MAY be omitted if `session` is given and the client is re-issuing after out-of-band completion (fallback). MUST echo back the server-issued `session`.
- **`m.login.sso` works ONLY via the Fallback mechanism** — there is no inline JSON credential. Client opens `GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<session>` in a browser; server redirects to SSO, validates the callback, then serves the fallback-completion HTML page (runs `window.onAuthDone()` / `postMessage("authDone","*")`). Client then **re-submits the original request with `auth: { "session": "<id>" }`** (session only, no `type`). Server marks the stage complete and executes.
- Server MUST: never succeed without auth; completed stages can't be retried (return either 401-with-completed or the API result). SHOULD: confirm the destructive op to the user before/after SSO; guard unsolicited auth via a state cookie.

## 3. Error codes / statuses that MUST be test-covered

- **404** (Nebu maps to `M_NOT_FOUND` per AC2/AC3) — PUT/DELETE on non-existent or **another user's** device.
- **401 UIA** — DELETE / delete_devices with no/insufficient `auth`; body has `flows`+`session`.
- **200 `{}`** — rename success; delete after UIA satisfied; **idempotent** re-delete of already-gone device.
- **`M_FORBIDDEN`** — failed/invalid UIA stage attempt (retryable 401 with errcode).
- **`M_UNKNOWN_TOKEN`** (401) — request after the token was revoked by the delete (Nebu's denylist/session-revoke path → next call with the dead JWT).
- **`M_MISSING_PARAM`** (400) — `delete_devices` with `devices` absent (Required field).
- Auth-missing on any endpoint (no Bearer) → standard `M_MISSING_TOKEN`/401.

## 4. Spec-mandated edge cases

- **`delete_devices` empty array** `{"devices":[], "auth":...}` — `devices` present (Required satisfied) → valid no-op; still UIA-gated → 401 first, then 200 `{}`.
- **Devices not owned** — out-of-scope of "current user's devices"; treat as no-such-device → 404 (do NOT delete, do NOT 200 silently — IDOR risk; test cross-user case explicitly).
- **Idempotency of delete** — spec MUST: 200 `{}` whether removed now *or removed previously*. Re-DELETE same id after UIA → still 200 `{}`.
- **DELETE body carries the auth dict** — DELETE here has a JSON request body (`{"auth": {...}}`); server MUST read UIA `auth` from the DELETE body, not query/headers. First DELETE (no `auth`) MUST 401.
- **Token/JWT invalidation MUST** — deleting a device "invalidates any access token associated with it"; verify the revoked token then yields `M_UNKNOWN_TOKEN`.
- **E2EE invariant (AC6):** the device-key/OTK/fallback rows deleted are the *directory* (ADR-011) — side-effect of device deletion, does not touch `m.room.encryption`.

## Nebu freshness note (Option B)
Nebu uses Fallback-based `m.login.sso` UIA with a 15-min freshness shortcut. Within window → skip the 401, execute directly. >15min → 401-then-SSO. Test both paths.

## Follow-up Oracle ruling — m.login.sso UIA completion (definitive)

- m.login.sso has NO inline credential. Completion is EXCLUSIVELY out-of-band via the
  auth FALLBACK mechanism (CS v1.18 §Fallback, §SSO during UIA, §Single Sign-On).
- Flow: 401 with m.login.sso flow + session -> client opens
  `GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id>` -> server handles
  like /login/sso/redirect (302 -> IdP) -> IdP callback validated -> server marks THAT
  UIA session's m.login.sso stage complete and serves a completion HTML page that runs
  window.onAuthDone()/postMessage("authDone","*").
- Re-submit auth dict is `{"session": "<id>"}` — SESSION ONLY, no `type`, no token.
- Option B server contract (minimal, spec-compliant):
  - The fallback endpoint MUST tie the SSO flow to the session, redirect to IdP, and on
    a validated callback mark the session's m.login.sso stage complete + refresh auth_time.
  - The server MUST accept `auth: {"session": id}` (session-only) to complete; MUST NOT
    require a type/credential.
  - The 15-min fresh-auth window is an internal policy the spec neither mandates nor forbids;
    a recent login may satisfy the stage without a per-request SSO redirect.
