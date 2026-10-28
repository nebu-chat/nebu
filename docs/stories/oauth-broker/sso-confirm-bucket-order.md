---
story_id: sso-confirm-bucket-order
title: "Legacy SSO confirmation page: charge no shared per-IP bucket before the binding cookie is proven (follow-up cv): cookie first, per-binding bucket for hits, per-IP bucket for misses only"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-14
branch: feature/migrate-to-oauth2
---

# Story: One anonymous source must not lock the legacy SSO confirmation page for everyone (follow-up `cv`)

Source: follow-ups row `cv` (SEC delta gate 2026-10-14, X-3 LOW). `Nebu.Matrix.SsoConfirm` charges `{"sso_confirm", ClientIP.bucket(conn)}`
(600/h, refill 10/min, GET and POST share it) on EVERY request, before it looks at the binding cookie. With the G3-2 collapse (the
default `alb` topology and an empty `lb_real_ip_cidrs`: every client has the load balancer's address) one anonymous source can make the page
answer `429 rate_limited` for every user of an unlisted web origin, from the merge on, independent of `oauth_enabled`. The follow-up's proposal
("answer `invalid_state` for a request without a well-formed cookie BEFORE charging") is not enough on its own: a well-formed random cookie
costs the attacker nothing and would still drain the shared bucket.

## Story

As a user of a web client on an origin that is not listed I want the SSO confirmation page to work for me even when somebody else (or a
misconfigured client-IP resolution that puts everybody into one bucket) sends a flood of requests to it, without weakening the protection
against guessing the binding cookie or the CSRF token.

## Decisions

- **D1 (order).** The binding cookie decides how a request is counted, before any bucket is charged:
  1. NO cookie, or a malformed one (not 43 characters of `[A-Za-z0-9_-]`): `400 invalid_state` at once, nothing is charged, the store is not
     asked (a GET and a POST alike; it is the answer that request got before after the bucket, so the status codes do not change for a
     request that was not rate limited).
  2. A well-formed cookie: ask the store (`peek_confirm`, a read; the POST decides with `pop_confirm` later, unchanged).
     - **HIT** (a live parked login of this browser): charge the PER-BINDING bucket `{"sso_confirm", digest(cookie)}` (refill 2/min, burst 60: a real user needs
       a handful of requests: the page, a reload, the decision); exhausted: `429 rate_limited` (cookie kept, nothing consumed), the same page and headers as before.
     - **MISS** (unknown, expired or consumed cookie): charge the PER-IP miss bucket `{"sso_confirm_miss", ClientIP.bucket(conn)}`
       (the old limits: 600/h, refill 10/min): exhausted `429 rate_limited`, else the usual `400 invalid_state`.
  On the POST everything after the cookie keeps its order and answers: form parse, decision, Origin + fetch metadata, CSRF token, pop. The two checks that need no
  cookie (form parse, decision) used to run first; they now run behind the cookie classification (D3).
- **D2 (why this is safe).** No shared bucket can be drained by a party that holds no live binding: a flood without a valid cookie only
  fills the per-IP MISS bucket, which can deny only requests that carry an UNKNOWN cookie, never a user with a live entry; the per-binding
  bucket belongs to one browser. Guessing a binding (32 random bytes, SHA-256 key) stays infeasible and is still rate limited per source by
  the miss bucket; guessing the CSRF token needs the cookie. A party WITH a live binding (an insider who completed an IdP login) can only
  exhaust its own bucket.
- **D3 (changed answers, honestly).** A POST without a well-formed cookie used to answer `429` (exhausted bucket), `400 invalid_request` (bad
  body / decision), `403 forbidden` (Origin / fetch metadata) or `400 invalid_state`, in the order of the moduledoc. Now the cookie
  classification comes first, so a cookie-less POST is always `400 invalid_state` (the cookie is cleared as for every definite
  `invalid_state`). A POST WITH a live cookie keeps every later answer and order (`invalid_request`, `forbidden`, `invalid_state` after a pop miss).
- **D4 (residual, recorded).** A flood of well-formed random cookies still reaches the node-local `SsoStore` (an O(1) lookup through the
  GenServer, like every other unauthenticated GET) and fills the per-IP MISS bucket; legit users are never denied by it. The store call is bounded
  (5 s timeout, `unavailable` handling unchanged). A signed cookie (a MAC the server verifies without a store) would remove the lookup; not done
  (a format change of the binding cookie, tests pin 43 characters): follow-up `di`.
- **D5 (logging, unchanged).** No new log line; the existing value-free WARNINGs stay.

## Acceptance Criteria

1. A request without a binding cookie and a request with a malformed cookie answer `400 invalid_state` on GET and POST, charge no bucket (assert the
   bucket state), do not call the store.
2. With the legacy per-IP bucket `{"sso_confirm", ip}` drained (the G3-2 collapse simulated: all requests share one address), a user with a live
   confirmation can GET the page, POST Continue and POST Cancel: no `429`.
3. A well-formed unknown cookie is charged to `{"sso_confirm_miss", ip}`: the 601st miss from one source answers `429 rate_limited`, with the cookie kept and
   the `Retry-After` of the page; a request with a live cookie from the same source is still served.
4. The per-binding bucket denies the 61st request of one live binding with `429` (nothing consumed, the cookie kept); another binding is unaffected.
5. Every POST rule after the cookie is unchanged (form parse, decision, Origin, fetch metadata, CSRF, single use pop); a cookie-less POST is `invalid_state`.
6. Existing tests that pin the old order are adapted deliberately (listed in the Dev Agent Record), new tests for both cases (flood without cookie /
   with random cookie, legit user served).
7. Documentation: ADR-033 (L9, next to L5 / L8 of the SSO confirmation section), 07-deployment (G3-2 rows: the confirmation page no longer collapses; the mitigation text),
   `follow-ups.md` (`cv` closed, `di`).

## Dev Agent Record

Implementation: `Nebu.Matrix.SsoConfirm.handle/1` (cookie first, `classified/2`, `show/3`, `post/2`); drive-by: `params` -> `_params` in `ConfigController.save_sso_schemes/2` / `save_sso_origins/2` (compiler warning of the previous story, no behaviour change).
Deliberate changes of old tests: `sso_redirect_confirm_csrf_test.exs` "a bad Origin AND a missing cookie" is now `400 invalid_state` (D3) next to the new "bad Origin WITH a live cookie => 403"; "an exhausted bucket AND a bad body => 429" now uses the per-binding bucket; the AC11 describe
(`{"sso_confirm", ip}`) is replaced by the per-binding / miss / flood describes; `sso_redirect_confirm_page_test.exs` rate-limit pages use a drained binding (a separate one in the COOP test); "no cookie at all" no longer expects a clearing cookie (SEC L-1);
test support: `drain_binding!/2`, `sso_confirm_binding_bucket/1`. Test review: exact 60 / 600 budgets through the plug, ETS snapshot for the no-charge cases, store-unavailable cases. Kassandra: L-1 fixed (missing cookie not cleared), L-2 documented (follow-up `di`).
