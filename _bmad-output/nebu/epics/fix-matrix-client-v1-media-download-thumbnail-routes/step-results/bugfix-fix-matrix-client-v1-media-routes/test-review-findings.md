# Test Quality Review — `server/test/nebu/media/media_client_v1_routes_test.exs`

**Reviewed:** RED-phase ATDD regression file for epic `fix-matrix-client-v1-media-download-thumbnail-routes`
**Scope:** single file (283 lines), cross-referenced against `docs/stories/bugfix/fix-matrix-client-v1-media-download-thumbnail-routes/fix-matrix-client-v1-media-download-thumbnail-routes.md`, `server/lib/nebu/web/router.ex`, `server/lib/nebu/web/router/protected.ex`, `server/lib/nebu/web/router/media.ex`, `server/lib/nebu/media.ex`, and the sibling v3 test files (`media_download_test.exs`, `media_thumbnail_test.exs`).

## Executive Summary

**Recommendation: Approve with comments.**

The file covers all 7 ACs with clear, well-labelled tests, no hard waits, no non-determinism, correct isolation (async: false + full `on_exit` cleanup, consistent with sibling media test files), and depth on the 401 assertions (errcode body, not just status). The 5-failing/8-passing RED split is exactly as expected and is a routing/topology artifact, not a test defect. One nuanced, low-severity issue is worth flagging around the AC4/AC5 tests' actual proving power (analyzed in depth below, downgraded from an initial MAJOR hypothesis to MINOR after tracing the routing code) — no test defect requires blocking.

## Quality Criteria Assessment

| Criterion | Status | Notes |
|---|---|---|
| AC coverage (all 7 ACs have ≥1 test) | PASS | See per-AC table below |
| Hard waits / sleeps | PASS | None found |
| Determinism (no Math.random/Date.now-based assertions) | PASS | `System.system_time` used only for JWT `exp`/`iat`, not asserted on |
| Isolation (cleanup, shared state) | PASS | `on_exit` clears all 6 `Application.put_env(:nebu_http, ...)` keys; `S.setup_oidc_keys/0` separately registers its own cleanup. `async: false` is correct given global `Application.env` mutation — matches `media_download_test.exs`/`media_thumbnail_test.exs` convention |
| GenServer crash/restart test | N/A (confirmed) | Router/plug pipeline is stateless per-request; no GenServer under test here |
| Error code + status depth on 401s | PASS | Every AC4/AC5 test asserts both `conn.status == 401` **and** `S.json(conn)["errcode"]`, not status alone |
| Test length | PASS | 283 lines, under the 300-line guideline |
| Assertion specificity | PASS | Every assertion carries a descriptive failure message |
| Fixture/data-factory reuse | PASS | Reuses `MediaTestSupport`/`MediaFakes` shared helpers rather than inventing new ones — good factory discipline |

## Per-AC Coverage

| AC | Test(s) | Verdict |
|---|---|---|
| AC1 (auth download, no filename) | `AC1: GET .../download/:server_name/:media_id → 200 with decrypted bytes` (line 140) | Covered — asserts status 200 and exact plaintext byte equality |
| AC2 (filename variant) | `AC2: GET .../download/:server_name/:media_id/:file_name → 200 ...` (line 153) | Covered — see detailed analysis below |
| AC3 (auth thumbnail) | `AC3: GET .../thumbnail/:server_name/:media_id → 200 ...` (line 173) | Covered — see detailed analysis below |
| AC4 (401 no token, all 3 routes) | `describe "AC4..."` block, 3 tests (lines 188-209) | Covered, all three route shapes |
| AC5 (401 invalid token, all 3 routes) | `describe "AC5..."` block, 3 tests (lines 213-234) | Covered, all three route shapes |
| AC6 (v3 regression) | 2 smoke tests (lines 269-282) | Covered — thin but appropriately so (deep v3 coverage already lives in the dedicated v3 files, as the comment at line 262-267 correctly states) |
| AC7 (CSP/CORP headers) | 2 tests, one per route (lines 238-260) | Covered |

All 7 ACs have at least one test. No AC is missing coverage.

## Detailed Findings

### INFO-1 — AC2 filename-variant test does correctly prove URL-driven naming (no defect)

Verified against `server/lib/nebu/media.ex:126-129`:

```elixir
def download(conn, server_name, media_id, file_name \\ nil) do
  with_authorised_media(conn, server_name, media_id, fn conn, row, plaintext ->
    serve_bytes(conn, row.content_type, plaintext, file_name || media_id)
  end)
end
```

The fallback when no `file_name` is supplied is `media_id` itself (here `"v1dlmedia"`), not some other stored filename column (the `media_files` row shape carries no filename field at all — see `MediaTestSupport.media_row/1`). The AC2 test uses `file_name = "cat.jpg"`, which is a different string than `media_id = "v1dlmedia"`. So if a routing bug caused the `/:file_name` URL to be dispatched to the no-filename arity (`download/3`, defaulting `file_name` to `media_id`), the `Content-Disposition` would contain `"v1dlmedia"` and `assert String.contains?(cd, "cat.jpg")` (line 167) would fail — correctly catching that regression. This mirrors the identical pattern already used in the pre-existing, passing `media_download_test.exs:132-142` test for the v3 route, so it is consistent with established convention. No fix needed.

### INFO-2 — AC3 thumbnail fixture is adequate; `Nebu.Media.thumbnail/3` does not decode images

Verified against `server/lib/nebu/media.ex:134-146`: `thumbnail/3` does not perform real image decoding/resizing (no libvips/Image dependency — the comment at line 137-142 explicitly documents this as intentional, since the Alpine test container has no native vips toolchain). It only checks `image_type?(row.content_type)` and streams the decrypted original bytes with an `image/*` Content-Type. The test's fixture (`@png_magic <> 64 zero bytes`, `content_type: "image/png"`) satisfies `image_type?/1` and is never actually decoded, so this is a fully adequate fixture — matching the identical 72-byte fixture already used successfully in the pre-existing `media_thumbnail_test.exs:32-33`. No defect.

### MINOR-1 — AC4/AC5's proving power is weaker than it looks, but is not a masking defect given the full suite

This is the point flagged for the deepest scrutiny, so the full reasoning is recorded here.

**Why the 8 tests pass today, pre-fix:** `Nebu.Web.Router.Protected` (`server/lib/nebu/web/router/protected.ex:29`) runs `plug Nebu.Web.Plugs.OidcPlug` **before** `:match`/`:dispatch`. Since `/_matrix/client/v1/media/...` matches no explicit route anywhere in `router.ex` today, it falls through the top-level catch-all `forward "/_matrix", to: Nebu.Web.Router.Protected` (`router.ex:146`). OidcPlug rejects a missing/invalid token *before* Protected ever attempts to match the path, so AC4/AC5 get their expected 401 regardless of whether a matching route exists downstream. This is why AC4/AC5 (and the unrelated-but-adjacent AC6 v3 smoke tests) already pass in RED phase while AC1/2/3/7 (which need an actual 200 + real payload) correctly fail.

**The scrutinized question:** after the fix lands (new v1 routes presumably added to `Nebu.Web.Router.Media`, which has its own, separately-declared `plug Nebu.Web.Plugs.OidcPlug` at `media.ex:51`, and forwarded to from `router.ex` ahead of the Protected catch-all), would AC4/AC5 still meaningfully prove the *new* pipeline is gated, or would they keep trivially passing via Protected's coincidental fallback and thus mask a developer forgetting `OidcPlug` on the new route(s)?

**Traced conclusion:** in `Plug.Router`, route matching does not inspect headers, so a specific `get` clause that matches a given URL matches it identically whether or not a Bearer token is present. This means:
- If the fix wires the v1 routes into a pipeline that has its own OidcPlug (e.g., extending `media.ex`), AC4/AC5 exercise a real gate — one that happens to look identical to Protected's (same plug, same error shape), but is genuinely the pipeline serving the new routes.
- If a developer instead added the v1 routes as bare `get` clauses directly on the top-level `Nebu.Web.Router` (whose own plug stack has no OidcPlug) and forgot to gate them, the *same URL* would match that ungated clause for **both** the valid-token and no-token case — so AC4/AC5 would then observe a `200` (from `Nebu.Media.download`, since the fixtures are unconditionally satisfied) instead of `401`, and would correctly **fail**, not pass. This failure mode is not maskable given how Plug.Router dispatches.
- The only way AC4/AC5 could pass without the new route being correctly wired is if the URL never matches any new route at all and falls through, unauthenticated, to Protected's catch-all — but in that scenario the corresponding AC1/2/3/7 positive tests (which require a 200 with real bytes) would also fail, since Protected has no matching handler either. So the "route not implemented" failure mode is still caught by the suite as a whole, just not by AC4/AC5 in isolation.

**Net assessment:** AC4/AC5, read in isolation, cannot distinguish "new pipeline correctly OidcPlug-gated" from "request coincidentally caught by Protected's fallback gate" — both produce byte-identical 401 responses (same plug, same config), so no assertion could be written that discriminates the two without inspecting which router handled the request (e.g., a response header naming the router, which does not exist and would be an unusual thing to add just for testability). However, this is an inherent property of the routing architecture (every unmatched `/_matrix/*` path is auth-gated by construction), not a fixable defect in this test file — and it does not create a false sense of security because the accompanying positive-path tests (AC1/AC2/AC3/AC7) already fail whenever the new routes are missing, misrouted, or reachable-but-ungated. Classifying as MINOR (test-design limitation, worth a one-line comment) rather than MAJOR (no plausible fix-implementation exists under which this file's full suite gives a false green).

*Suggested comment (optional, non-blocking):* a code comment near the AC4/AC5 `describe` blocks noting that these assert "some" auth gate and rely on AC1/2/3/7 to prove the correct route was actually reached, so a future reader doesn't mistake them for proof of route-specific enforcement.

### INFO-3 — AC6 smoke tests are appropriately thin

The two AC6 tests (lines 269-282) are intentionally minimal, with a comment (lines 262-267) correctly deferring to the dedicated v3 test files (`media_download_test.exs`, `media_thumbnail_test.exs`, `media_access_control_test.exs`, `media_range_request_test.exs`) for depth. This is the right call — duplicating full v3 coverage here would just be redundant, and the smoke assertions (status 200 + byte/content-type equality) are enough to catch a routing change that accidentally shadows or breaks the v3 forward.

### INFO-4 — Hard waits / flakiness / determinism

None found. No `Process.sleep`, no `Elixir.Process.send_after`/timers, no `Math.random`, no wall-clock assertions besides JWT `exp`/`iat` (which are inputs, not assertions). The `invalid_token/1` helper (lines 127-136) uses the same signature-corruption technique as the existing `oidc_plug_test.exs:89` `corrupt_signature/1`, so it's a proven, deterministic pattern (guarantees the token still contains a `.` so it takes the JWT path, not the opaque-token path, per the inline comment at lines 123-126).

## Summary Table

| Severity | Count | Items |
|---|---|---|
| MAJOR | 0 | — |
| MINOR | 1 | MINOR-1: AC4/AC5 cannot, in isolation, distinguish the new pipeline's OidcPlug from Protected's fallback OidcPlug — inherent to the routing architecture, not maskable given AC1/2/3/7 as a safety net; optional comment recommended |
| INFO | 4 | INFO-1 (AC2 filename-variant proof is sound), INFO-2 (AC3 fixture is adequate, no real image decode occurs), INFO-3 (AC6 smoke depth is appropriate), INFO-4 (no hard waits/flakiness/non-determinism) |

**Recommendation:** Approve. No blocking issues. The RED-phase split (5 failing / 8 passing) is correct and expected. Proceed to implementation.
