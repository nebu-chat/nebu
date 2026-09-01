## Security Review — bugfix-fix-matrix-client-v1-media-routes

**Diff scope:** Adds three authenticated GET routes so Element Web's `/_matrix/client/v1/media/{download,thumbnail}` endpoints work (previously 404 — never ported from the Go media gateway). New dedicated router `Nebu.Web.Router.ClientV1Media` (server/lib/nebu/web/router/client_v1_media.ex), one new `forward` line in `server/lib/nebu/web/router.ex`, a documentation-only addition to `server/lib/nebu/web/router/media.ex`, plus a new regression test file. No changes to `Nebu.Media.download/2,3` or `Nebu.Media.thumbnail/3` — reused as-is.

**Date:** 2026-07-31

### Findings

No CRITICAL/HIGH/MEDIUM/LOW findings.

### Detail

**Auth bypass — CHECKED, CLEAN.** `Nebu.Web.Router.ClientV1Media` declares `plug Nebu.Web.Plugs.OidcPlug` (client_v1_media.ex:46) ahead of `:match`/`:dispatch`, identical pipeline shape to `Nebu.Web.Router.Media`. `OidcPlug` produces the spec-correct `M_MISSING_TOKEN`/`M_UNKNOWN_TOKEN` 401s (oidc_plug.ex:63,78) and assigns `conn.assigns.current_user` on success. The `forward "/_matrix/client/v1/media", to: Nebu.Web.Router.ClientV1Media` (router.ex:111) is placed after the unauthenticated discovery/login forwards and before the generic `/_matrix` catch-all — correct ordering, no shadow risk, confirmed by two independent code-review passes and re-verified here by reading the file directly.

**IDOR / cross-room media leak — CHECKED, CLEAN.** `download/2,3` and `thumbnail/3` both route through `with_authorised_media/4` (media.ex:204), which looks up the media row by `(server_name, media_id)` and then calls `membership_module().member?(row.room_id, user)` — `user` is `conn.assigns[:current_user]`, the OidcPlug-trusted identity, never a path/body-supplied value. A non-member gets `403 M_FORBIDDEN`, not the bytes. This logic is unchanged by this diff (same functions, same call sites) — the new router only adds a second URL that reaches the same authorization-checked code path.

**Path traversal — CHECKED, CLEAN.** `media_id`/`server_name` are DB lookup keys (`db_module().lookup/2`), not filesystem paths — there is no file-path construction from user input anywhere in the download/thumbnail path; storage access goes through `storage_module().get(row.storage_key)` where `storage_key` is a value already recorded at upload time, not derived from the request. `file_name` (the optional third path segment) is used only as a `Content-Disposition` header value (media.ex:238, `disposition_for/2`) — never as a file-system path — identical to the pre-existing v3 route's handling of the same parameter, so this diff introduces no new traversal surface.

**Cross-exposure closed — INDEPENDENTLY RE-VERIFIED.** Read `client_v1_media.ex` directly: it contains only the three `download`/`thumbnail` clauses and its own generic 404 catch-all — no `upload`, no `preview_url`, no `/v3/...` clauses exist in this module, so neither the SSRF-amplifier `preview_url` endpoint nor `upload` can be reached via the new `/_matrix/client/v1/media` prefix. Confirmed `Nebu.Web.Router.Media` (the v3 router) has no un-versioned `download`/`thumbnail` clauses left in the staged diff — its only change is a documentation paragraph. The MINOR finding from code-review cycles 0/1 is correctly and completely closed.

**Rate limiting — consistent, not a new gap.** Neither the pre-existing v3 `download`/`thumbnail` routes nor the new v1 ones carry a `RateLimit` plug; only `upload` and `preview_url` do (both absent from the new router). This is unchanged posture, not a regression introduced by this story — noting it here per Standing Orders (recurring pattern awareness), not as a new finding: unauthenticated-adjacent, expensive per-request decrypt-and-serve work without a request-rate cap is a known Nebu media-gateway pattern (see MEMORY.md: "Unauthenticated media endpoint + unbounded resource", Epic 12). These routes ARE behind OidcPlug (not unauthenticated), which meaningfully narrows the attacker pool versus the historical Go-gateway finding, but a authenticated user could still issue unbounded decrypt-and-serve requests. Not blocking for this bugfix (out of scope — matches existing v3 behavior exactly, AC6 requires no behavior change there); worth a follow-up ticket if not already tracked.

**Security headers (CSP/CORP) — CHECKED, CLEAN (AC7).** Both handlers funnel through `serve_bytes/4` and `serve_inline_image/4` (media.ex ~1054-1082), which unconditionally set `content-security-policy: sandbox; default-src 'none'; ...` and `cross-origin-resource-policy: cross-origin` before responding. Verified present on the new v1 paths by the ATDD test file (AC7 assertions) and by static reuse of the same helper functions — no divergence possible between v1 and v3 responses on this dimension.

**Secrets / logging — CHECKED, CLEAN.** No new logging statements in the diff; no secrets, tokens, or keys introduced.

**Unrelated file check.** Confirmed `deploy/tofu/examples/upcloud/loadbalancer.tf` (an unrelated, pre-existing uncommitted change from outside this story) is NOT part of the staged diff reviewed here.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED — No security issues found. Scope reviewed: full staged diff (`git diff --staged`) for `bugfix-fix-matrix-client-v1-media-routes`, cross-checked against the code-review cycle 0/1 history and MEMORY.md's recorded media-gateway patterns.
