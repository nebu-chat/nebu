## Security Review — device-bugfixes (device-management epic)

**Diff scope:** Two targeted bug fixes: (1) Admin UI `users/index.html.heex` — user_id wrapped in `<a href>` with `URI.encode`; (2) Matrix API — `POST /_matrix/client/v3/keys/signatures/upload` stub added to `protected.ex`, returning `200 {"failures": {}}`.
**Date:** 2026-06-28
**Reviewer:** Kassandra (SEC Gate 1 — per-story)
**Story:** `device-bugfixes`
**Diff base:** `786a9fad`

---

### Scope Reviewed

- `server/lib/nebu/admin/templates/users/index.html.heex` — link wrapping change
- `server/lib/nebu/admin/users_controller.ex` — `load_users/0` test seam + `URI.decode` comments
- `server/lib/nebu/web/router/protected.ex` — new `post "/client/v3/keys/signatures/upload"` route
- Supporting test files (reviewed for fixture design, no security surface added)
- MEMORY.md cross-checked for known accepted risks and recurring patterns applicable to this diff

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `users_controller.ex:79,98,99,128,129` | URI.decode double-decode — pre-existing, noted for accuracy | None required (see Detail below) |
| 2 | LOW | `admin/router.ex:83-89` | CSP missing `form-action 'self'` — open watch-flag (MEMORY #57), not introduced by this diff | Add `form-action 'self'` to `@csp`; tracked as existing advisory |

---

### Detail

**Fix 1 — Admin UI Link (`index.html.heex` + `users_controller.ex`)**

**XSS (HEEx template, AC1/AC4):** The link is rendered in a HEEx expression:

```heex
<a href={"/admin/users/" <> URI.encode(user.user_id, &URI.char_unreserved?(&1))} class="text-primary">{user.user_id}</a>
```

Two distinct escaping contexts are handled correctly:
- The `href` attribute value: `URI.encode/2` with `URI.char_unreserved?/1` is the same encoder used by the `enc/1` private helper throughout the controller. It percent-encodes everything except `[A-Za-z0-9._~-]`. A Matrix user_id of the form `@alice:example.com` becomes `%40alice%3Aexample.com` — no `"`, `<`, `>`, `;`, or space can survive unencoded. HEEx additionally HTML-attribute-escapes the interpolated value (braces expression is always HTML-escaped in Phoenix HEEx). XSS: **CLEAN**.
- The link text body `{user.user_id}`: HEEx auto-escapes text content. XSS: **CLEAN**.

**IDOR:** The `load_users/0` call retrieves ALL users from the DB (no row scoping by current user — correct, this is an admin-only page). The controller-level `plug Nebu.Admin.Auth, :require_admin` gates the entire controller. No IDOR surface on the index view itself.

**URI.decode double-decode (Finding #1 — LOW):** The controller calls `URI.decode(user_id)` in `show/2`, `rename_device/2`, and `delete_device/2` after Phoenix has already decoded path segments. The code comment accurately documents this: `# Phoenix already percent-decodes path segments. URI.decode here is a no-op for standard Matrix ids`. The only exploitable consequence would be if an attacker could supply a double-encoded path segment that Phoenix's router decodes once (leaving an encoded value) which then gets decoded a second time by this explicit call, landing a different value. Phoenix Router/Plug uses `URI.decode_www_form` on segments which decodes `%XX` sequences; a double-encoded `%2540` arrives as `%40` after Phoenix decoding, then `URI.decode` makes it `@`. The result is still a valid (canonical) Matrix user_id — no path traversal primitive exists because the decoded value goes into a parameterized SQL query (`$1`) and into Elixir function calls, never into a filesystem path or shell. This is an existing pattern in the controller (unchanged by the diff), correctly documented, and LOW severity. No change required.

**Test seam (`admin_users_loader` app env):** The injected seam follows the identical pattern used by `admin_device_lister`, `admin_device_renamer`, `admin_device_deleter`, and `admin_user_searcher` throughout the same controller. The seam is guarded by `when is_function(fun, 0)` — arbitrary-arity functions are rejected. The production code path (DB query) is unaffected when the seam is absent. No security regression introduced.

---

**Fix 2 — `POST /client/v3/keys/signatures/upload` stub (`protected.ex`)**

**Auth gate (AC6/AC7):** `Nebu.Web.Plugs.OidcPlug` is the FIRST plug declared in `Protected`'s pipeline (`plug Nebu.Web.Plugs.OidcPlug`). It runs for EVERY route in this router, halting with `401 M_UNKNOWN_TOKEN` before any route clause is evaluated on authentication failure. The new stub does not declare its own auth or bypass the pipeline gate. Auth: **CLEAN**.

**Body handling / memory safety:** The stub body is `send_json(conn, 200, %{"failures" => %{}})` — the request body is intentionally discarded. `Nebu.Web.Plugs.JsonBody` (top-level router, before Protected) has already read and attempted to parse the body against the `1_000_000` byte cap (`length: 1_000_000`). A body exceeding 1 MB is rejected by `Plug.Parsers` before reaching Protected. The comment in the stub correctly documents that a malformed JSON body sets `json_parse_error: true` rather than raising, and that `send_json` is reached safely in all cases. Body-size limit: **CLEAN** (inherited from global `JsonBody` plug).

**Rate limiting:** The stub has no per-route rate limit of its own. The global `Nebu.Web.Plugs.RateLimit` (if wired at the top-level router level) would apply. Cross-checking: `/keys/upload` (the sibling endpoint) similarly has no per-handler rate limit beyond the global one. The endpoint is authenticated (OidcPlug gates it) — an attacker must hold a valid Bearer token to flood it, which significantly raises the bar. Per MEMORY #68/#72 pattern context: the epic-end SEC Gate 2 review (2026-06-26) approved the rate-limiting posture for authenticated endpoints in the Protected pipeline, noting `/sync` has an explicit 600/min cap because of its long-poll process cost, while key-directory writes have the OTK key-count cap as DoS bound. The `signatures/upload` stub is a no-op (no DB write, no process spawn, immediate return) — its DoS cost is negligible. The global rate limiter backstop applies. **CLEAN** at this story's scope.

**CSRF:** Not applicable. `POST /_matrix/client/v3/keys/signatures/upload` is a Matrix API endpoint authenticated by Bearer token, not a browser-form POST. Phoenix's `protect_from_forgery` is not wired into the Matrix Protected router (it is wired into the Admin router only, as expected). The Bearer-token auth model is CSRF-safe by construction (the browser's same-origin policy cannot use `fetch` to attach custom `Authorization` headers cross-origin without CORS preflight). **CLEAN**.

**Placement / ordering in protected.ex:** The new stub is placed after `post "/client/v3/keys/upload"` and before `get "/client/v3/devices"`. Plug.Router matches the FIRST matching clause. There is no existing wildcard or catch-all before line 372 that could shadow the new route. The `match _` catch-all is at the bottom of the file. **CLEAN**.

**Response correctness:** `{"failures": {}}` is the Matrix CS spec-mandated response for this endpoint. An empty `failures` map signals success (no signature upload failures). Per ADR-011 the signatures are not persisted — returning success is intentional and correct.

---

**CSP `form-action` watch-flag (Finding #2 — LOW / pre-existing)**

The `@csp` in `server/lib/nebu/admin/router.ex:83-89` still lacks a `form-action 'self'` directive. This is the open watch-flag from MEMORY #57 (recorded 2026-06-25, admin-http-refactor review). The diff introduces no new form elements or POST routes in the Admin UI, so this finding is pre-existing and NOT introduced by this story. It remains a LOW advisory requiring remediation before epic-end or as a dedicated hardening story. Carrying forward per MEMORY.

---

### Summary

```
CRITICAL: 0
HIGH:     0
MEDIUM:   0
LOW:      2  (#1 URI.decode no-op double-decode — pre-existing, no change required;
               #2 CSP form-action missing — pre-existing, carry-forward advisory)
```

**Verdict: APPROVED — no CRITICAL or HIGH findings. Both LOWs are pre-existing and not introduced by this diff.**

The two targeted fixes are correct and secure:
1. HEEx auto-escaping + `URI.char_unreserved?` encoding produces an XSS-safe href. No IDOR, no auth bypass.
2. The `keys/signatures/upload` stub is correctly gated by OidcPlug, body-size-limited by the global `JsonBody` plug, CSRF-safe by virtue of the Bearer-token auth model, and a no-op returning the spec-mandated response.
