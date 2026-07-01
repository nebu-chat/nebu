# Oracle Context — wellknown-e2ee-default

## Spec status of `io.element.e2ee`

- `io.element.e2ee` is an **Element-proprietary** well-known extension (formerly
  `im.vector.riot.e2ee`), **NOT part of the Matrix Client-Server spec**. Other clients
  (FluffyChat, Cinny, nheko) ignore it.
- `/.well-known/matrix/client` itself IS a spec endpoint (server discovery). The Matrix
  spec only mandates the `m.homeserver` object; arbitrary additional keys (vendor-prefixed)
  are permitted and ignored by clients that don't recognize them. Adding `io.element.e2ee`
  is spec-compatible (additive, non-conflicting key).
- It is a **client hint only**. Real spec-level enforcement of "no E2EE" remains the server
  rejecting `m.room.encryption` (ADR-011, unchanged). This story does NOT change enforcement.

## Element semantics (Element `docs/e2ee.md`)

- With `io.element.e2ee.force_disable: true`: "all rooms will be created with encryption
  disabled, and it will not be possible to enable encryption from room settings." Any
  `io.element.e2ee.default` value is then disregarded.
- `force_disable` does NOT suppress Element's recovery/cross-signing setup nag (handled by
  the separate `cross-signing-readback` story, not here).

## Compliance / Matrix-API rules for this change

- `/.well-known/matrix/client` MUST stay unauthenticated (no Bearer) — spec requirement for
  server discovery. (AC 4)
- `m.homeserver.base_url` derivation (scheme/host incl. x-forwarded-proto / host handling)
  MUST be preserved exactly. (AC 2)
- CORS `access-control-allow-origin: *` and `application/json` content type are required by
  the spec for discovery and must remain. (AC 3)
- Response must remain valid JSON. (AC 4)

## Scope guardrail

This is a **static current default**, NOT the Compliance/Normal mode switch. Do NOT build
mode-toggle config infrastructure. Add the key statically to the existing JSON body in
`server/lib/nebu/web/router.ex` (`get "/.well-known/matrix/client"`, ~lines 115–131).
