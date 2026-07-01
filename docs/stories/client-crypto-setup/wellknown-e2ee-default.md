---
epic: client-crypto-setup
story: wellknown-e2ee-default
security_review: required
baseline_commit: ce1e34ba83ac8161e45e0193966e7eccafee031b
---

# Story: Advertise E2EE-disabled default via /.well-known/matrix/client

Status: done

## Story

As a Nebu operator running the current managed posture (ADR-011),
I want `/.well-known/matrix/client` to carry Element's `io.element.e2ee.force_disable` hint,
so that Element-family clients do not offer per-room encryption and do not lead users into
a room-encryption flow the server will reject anyway.

## Context & Spec Notes (Oracle)

- `io.element.e2ee` is an **Element-proprietary** well-known extension (formerly
  `im.vector.riot.e2ee`), **NOT part of the Matrix spec**. Other clients (FluffyChat, Cinny,
  nheko) ignore it. It is a **client hint only** — the real, spec-level enforcement of
  "no E2EE" remains the server **rejecting `m.room.encryption`** (ADR-011, unchanged).
- Per Element `docs/e2ee.md`: with `force_disable: true`, "all rooms will be created with
  encryption disabled, and it will not be possible to enable encryption from room settings"
  and any `io.element.e2ee.default` value is disregarded.
- **Scope guardrail:** this is a *static current default*, NOT the Compliance/Normal mode
  switch. Do not build mode-toggle config infrastructure here.
- `force_disable` does **NOT** suppress Element's recovery/cross-signing setup nag (Element
  removed `secure_backup_required` / `secure_backup_setup_methods`). That bootstrap is fixed
  by story `cross-signing-readback`, not here.

## Acceptance Criteria

1. `GET /.well-known/matrix/client` returns, in addition to the existing `m.homeserver`
   object, `"io.element.e2ee": { "force_disable": true }`.
2. The existing `m.homeserver.base_url` value (scheme + host derivation incl. the
   `x-forwarded-proto` / `host` handling) is unchanged.
3. The existing `access-control-allow-origin: *` header and `application/json` content type
   are unchanged.
4. The response remains valid JSON and is served unauthenticated (no Bearer required).

## Tasks / Subtasks

- [ ] Extend the JSON body in `server/lib/nebu/web/router.ex` (`get "/.well-known/matrix/client"`,
      ~line 115–131) to include the `io.element.e2ee.force_disable` key (AC 1–3).
- [ ] Add/extend a router test asserting both `m.homeserver.base_url` and
      `io.element.e2ee.force_disable == true` in the parsed body (AC 1–2, 4).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. well-known carries e2ee force_disable — ExUnit (`Plug.Test` against `Nebu.Web.Router`)
   - Given: the router is running
   - When: `GET /.well-known/matrix/client`
   - Then: status 200, body has `m.homeserver.base_url` (non-empty) AND
     `io.element.e2ee.force_disable == true`

2. base_url derivation unchanged behind proxy — ExUnit
   - Given: request with `x-forwarded-proto: https` and a `host` header
   - When: `GET /.well-known/matrix/client`
   - Then: `m.homeserver.base_url` starts with `https://<host>`
