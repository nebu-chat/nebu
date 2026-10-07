## Oracle Gate Report — `GET /_matrix/client/v1/mutual_rooms` (MSC2666, added v1.19)

**Spec source:** `client-server-api/index.html`, anchor `get_matrixclientv1mutual_rooms` (line 61238), section `#mutual-rooms` (61233–61434).

### 1. Behavioral rules (MUST/required, verbatim/close-paraphrase)

- Basic-info table (61248–61257): `Rate-limited: Yes`, `Requires authentication: Yes` — explicitly on the endpoint itself.
- Query param `user_id` is **Required** (61283); `from` optional, "a `next_batch` result from a previous call" (61271–61277).
- 200: `count` **Required**, integer — "the **total** count even if the response is batched and `joined` doesn't include all rooms. This MAY be inaccurate if the server is unable to calculate the exact number" (61325–61327).
- 200: `joined` **Required**, array of Room ID — "rooms where **both** the authenticated user and `user_id` have a membership of type `join`" (61334–61335).
- 200: `next_batch` optional — "absent if there are no more results to return" (61342–61343).
- 200 for a `user_id` that "is not a valid user": "the server **MUST** return an empty list of rooms" (61299) — explicit MUST, 200 not 404.
- 400 causes (one bucket, 61303–61305): invalid/expired `from` token, missing `user_id`, non-compliant `user_id` (link to `#historical-user-ids`), or `user_id` == sender's own ID.
- Server-behaviour (61424–61433): server MAY truncate and SHOULD populate `next_batch` as an opaque identifier (61425–61426); continues "until the server no longer inserts `next_batch`" (61428–61429); tokens **SHOULD be valid for at least 10 minutes**; expired tokens **SHOULD be handled similar to invalid tokens** → 400; server **MAY omit rooms joined after the first token was generated** (61430–61433).

### 2. Open questions (a)–(g)

**(a) Field names/casing/nullability** — CONFIRMED CORRECT. `count`/`joined`/`next_batch`, exactly as drafted. `next_batch` is genuinely **omitted** (61342: "absent"), never `null`/`""` — spec gives no such alternative.

**(b) Errcode for missing vs. invalid `user_id`** — CORRECTED (nuance). The endpoint's own 400 description lumps missing/malformed/self-id into one undifferentiated cause list (61303–61305), and its **only** example JSON uses `M_INVALID_PARAM` with text "The user ID provided was invalid" (61380–61381). The spec does NOT carve out `M_MISSING_PARAM` for this endpoint's missing-param case. Generic CS API convention (line 3607: `M_MISSING_PARAM` = "A required parameter was missing from the request") exists elsewhere in the spec and is what Nebu uses for other missing-param cases, but it is **not demonstrated for this endpoint**. Verdict: AC6/7/8 all using `M_INVALID_PARAM` is **spec-example-supported**; using `M_MISSING_PARAM` for AC6 specifically would also be defensible by general convention but is **not what this endpoint's spec text shows**. Recommend: stick with `M_INVALID_PARAM` uniformly for all three causes (matches the one example given) — non-binding convention note only for the alternative.

**(c) `retry_after_ms` required in 429 body** — CORRECTED. NOT required. Neither this endpoint's own 429 schema (61408, no "Required:" marker) nor the generic 429 schema (61180, same) marks it Required. Spec fact (§Rate limiting, 3650–3657): `retry_after_ms` was **deprecated in v1.10** in favor of the `Retry-After` HTTP header; homeservers **SHOULD include `Retry-After`** (RFC 9110) on any 429. `retry_after_ms` **MAY** still be included. AC10 should test: `errcode: M_LIMIT_EXCEEDED` (Required) + `Retry-After` header present; `retry_after_ms` body field is optional/legacy, not a hard assertion.

**(d) Specific rate-limit tier/number** — NOT SPECIFIED BY SPEC. Only "Rate-limited: Yes" (61251). No tier, number, or bucket named. Implementer's choice — ecosystem convention (non-binding): reuse Nebu's existing standard per-user rate-limit tier already applied to other `v1` read endpoints.

**(e) Pagination page-size / ordering / token opacity** — NOT SPECIFIED BY SPEC for page size or `joined` ordering (no mention anywhere in the section). Token opacity: **is** specified — "opaque identifier" (61426, links to `#opaque-identifiers`), SHOULD be valid ≥10 minutes, expired ⇒ treated as invalid ⇒ 400 (61430–61432). Server MAY omit newly-joined rooms relative to first-page token (61432–61433) — worth a test or at least a documented non-guarantee.

**(f) Self-id 400 is spec-mandated** — CONFIRMED CORRECT. Directly in the endpoint's own 400 cause list: "...or was the sender's own user ID" (61305). Not ticket-invented.

**(g) Auth + rate-limiting explicitly called out in-section** — CONFIRMED CORRECT. Both appear in the endpoint's own basic-info table (61250–61256), not merely inferred from "it's a v1 endpoint." Concrete 401 errcodes (`M_MISSING_TOKEN`/`M_UNKNOWN_TOKEN`) themselves come from the generic §Using access tokens section (line 4343+), same pattern Nebu already follows for every other protected route.

### 3. Spec-defined error codes / status codes / edge cases to test-cover

- 200 — N≥1 shared rooms, both sides `membership: join` (not invite/leave/ban).
- 200 — single page: no `next_batch` key at all.
- 200 — multi-page: `joined` = page subset, `count` = **total**, `next_batch` opaque + non-empty.
- 200 — `from` = prior `next_batch` → next page; last page omits `next_batch`.
- 200 — syntactically-valid but unknown `user_id` → `{"count":0,"joined":[]}`, no `next_batch`, never 404 (MUST, 61299).
- 400 `M_INVALID_PARAM` — missing `user_id`; malformed/non-compliant `user_id`; `user_id` == caller.
- 400 — invalid or expired `from` token (fail closed).
- 401 `M_MISSING_TOKEN` — no Authorization header.
- 401 `M_UNKNOWN_TOKEN` — expired/invalid/revoked token.
- 429 `M_LIMIT_EXCEEDED` — assert errcode + `Retry-After` header; do NOT hard-require `retry_after_ms` body field.
- Regression — existing `v1` routes (relations, hierarchy) and `/sync` unaffected by new route wiring.
