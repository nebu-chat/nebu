# Code Review — cycle 1 (re-review) — bugfix-mutual-rooms

Verdict: 1 NEW MAJOR (MAJOR-2), 2 MINOR, 8 INFO. All 6 cycle-0 findings
(MAJOR-1 + MINOR-1..5) independently re-verified as genuinely fixed, no recurrence.

## MAJOR-2 (NEW) — advertised unstable_features flag points at a path Nebu does not serve
router.ex:131-133 adds unstable_features["uk.half-shot.msc2666.query_mutual_rooms"]=true.
But MSC2666's *unstable* endpoint convention is GET
/_matrix/client/unstable/uk.half-shot.msc2666/user/mutual_rooms — Nebu only routes the
*stable* GET /_matrix/client/v1/mutual_rooms (protected.ex:1172). Grep confirms no
msc2666 route exists under /client/unstable (only msc2965/msc3814/msc4143 do).
matrix-js-sdk/Element gate on exactly this flag and then call the unstable path ->
404 M_NOT_FOUND. The functional goal of MAJOR-1 (real clients can discover+call the
endpoint) is still not achieved, and now the server makes a /versions claim it doesn't
honor — worse than silence for feature-detection.

Options:
(a) RECOMMENDED — add a 3-line unstable alias route in protected.ex routing
    GET /client/unstable/uk.half-shot.msc2666/user/mutual_rooms to the same
    do_mutual_rooms/1 handler (matches 3 existing unstable-MSC-route precedents
    already in this codebase). Note: MSC2666's unstable response shape differs
    slightly ({"joined":[...]} + next_batch_token naming) — worth a quick Oracle
    check on exact field name before implementing.
(b) Accept the gap — remove the overclaiming comment at router.ex:124-130, state
    plainly the flag is a best-effort hint, stock clients won't reach the endpoint
    until Nebu claims v1.19.
(c) Revisit claiming v1.19 in versions (previously rejected by user) — listed only
    for completeness, not recommended.

## MINOR-6 (dev-fix, no user decision needed)
page_token.ex's explicit claimed invariant ("a mutual_rooms token can never be
replayed as a hierarchy token and vice versa") has zero test coverage — no
page_token_test.exs exists. Add one asserting the cross-prefix-rejection property
plus 0/negative/non-base64/non-binary edges.

## MINOR-7 (dev-fix, no user decision needed)
protected.ex:1160-1165's corrected rate-limit comment is accurate but omits that a
single mutual_rooms request clamps the SHARED per-IP bucket down to <=30 tokens,
reducing /sync's available burst headroom from 100 to 30 until re-accrual (and
symmetrically mutual_rooms' nominal 120/min is unenforceable when interleaved with
/sync's faster refill). Comment-only fix; numbers unchanged per prior scope decision.

## INFO (8) — recorded, no action required (full detail in prior agent transcript)
No sensitive data leak via 503 path; new Logger.warning doesn't leak secrets but
can't distinguish caller vs target lookup failure (cosmetic); rescue still converts
programmer errors to 503 (pre-existing tension, now at least logged); page-size env
value has no type-guard/upper-clamp (operator-misconfig only, not client-reachable);
PageToken.decode's Integer.parse is bounded by HTTP request-line limit, not
exploitable; versions-array exact-list test assertion is a deliberate brittle pin
(reviewer's call: keep as-is, stronger guard); ADR compliance clean (no new domain
model/cross-domain violation/OTP app); CI clean (2020 passed/0 failures, exit 2 only
from the same 2 pre-existing warnings, confirmed none new); query-param type
confusion (?user_id[]=x etc.) correctly fails closed to 400.

## Escalation status
No 3-cycle limit hit. MAJOR-1 fully resolved (not recurring). MAJOR-2 is a new,
distinct finding — cycle counter for it starts at 1. Needs user decision.
