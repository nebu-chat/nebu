---
story_id: 9c-mime-denylist-enforcement
title: "Media Policy Settings: mime_denylist Enforcement"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 9a's `Nebu.Media.Config` introduced the `mime_denylist` key (comma-separated
MIME-type prefixes, default `""` — disabled) as one of ten admin-configurable policy
values, explicitly citing this story as its consumer. This story wires that key into
the upload path: `Nebu.Media.upload_async/3` (Story 2b) rejects a PUT whose resolved
`Content-Type` matches an admin-configured denied prefix, **before** any bytes are
written to storage.

This is **defense-in-depth, not a replacement for the ClamAV scan** (Story 3/4). The
two checks address different threats and run at different times: `mime_denylist` is a
synchronous, upload-time **policy** gate ("we do not want this file *category* on this
server at all," e.g. blocking `application/x-msdownload` or `application/zip` outright
for a compliance-sensitive deployment) evaluated against the declared/defaulted
`Content-Type`; ClamAV is an asynchronous, **content**-inspection gate (byte-level
signature matching against the actual payload, regardless of what type it claims to
be) run after the file has already entered `:quarantined`. A file that clears
`mime_denylist` still goes through the full quarantine → scan → release pipeline
unchanged — this story adds an earlier rejection point, it does not skip or shortcut
the scan for anything that passes it.

The codebase already has a structurally identical, narrower precedent:
`Nebu.Media.upload/1`'s hardcoded `@blocked_upload_types` (stored-XSS vector types —
`text/html`, `text/javascript`, `image/svg+xml`, etc.) rejected with `400 M_BAD_JSON`
before the body is read, checked against the resolved `Content-Type` header with no
byte-level sniffing. This story follows the same trust boundary and rejection
mechanics, but sources the deny-list from `Nebu.Media.Config.get/0` (admin-editable,
no restart) instead of a compile-time module attribute, and applies to the async
upload path (Story 2b) that the fixed XSS blocklist does not currently guard. The two
lists are independent and both remain active — this story does not fold
`@blocked_upload_types` into `mime_denylist` or vice versa (see Dev Agent Guardrails).

## User Story

As the Nebu server operator, I want to configure a deny-list of MIME-type prefixes
(e.g. to block executables or archive formats outright for compliance reasons) that
the server rejects at upload time — in addition to, not instead of, the ClamAV
malware scan — so that I can enforce a file-category policy without waiting for the
async scan pipeline, and can change that policy live without a restart.

## Acceptance Criteria

1. **AC1 — Reads `mime_denylist` from `Nebu.Media.Config`.** `Nebu.Media.upload_async/3`
   (Story 2b) resolves the current deny-list via `Nebu.Media.Config.get/0`'s
   `mime_denylist` key (comma-separated prefixes, e.g.
   `"application/x-msdownload,application/zip"`) on every PUT — it does not cache the
   list itself or read it once at boot; `Nebu.Media.Config`'s own ETS/`:pg`/TTL
   mechanism (Story 9a, AC5) is what makes "no restart needed" true, this story just
   has to call `get/0` per-request rather than reading `config.exs`/app-env.
2. **AC2 — Denied MIME type → clear 4xx rejection, before storage.** When the
   resolved `Content-Type` (per 2b's AC1 — the client-declared header, or
   `application/octet-stream` if absent) starts with any configured prefix, the PUT
   is rejected with **`400 M_BAD_JSON`** and a message identifying it as a policy
   rejection (e.g. `"Content-Type not permitted by admin policy"`) — the same
   status/errcode shape `Nebu.Media.upload/1`'s existing `@blocked_upload_types`
   check already uses for the same class of rejection (content-type not permitted
   for upload), so the two checks present one consistent contract to clients. No
   bytes are read from the body, no `Nebu.Media.Storage.put/2` call is made, and no
   `media_files` row is written or transitioned — this check is the **first** gate
   evaluated once `Content-Type` is resolved, before the size check (AC6/413) and
   before the body read, mirroring where `@blocked_upload_types` sits in the
   synchronous `upload/1` handler today.
3. **AC3 — Prefix matching against the resolved header, not content sniffing.**
   Matching is `String.starts_with?(content_type, prefix)` against the same
   `Content-Type` value 2b already resolves and persists (client header, or the
   `application/octet-stream` default) — **no magic-byte/content sniffing is
   implemented in this story.** Reasoning: the epic's Story 9c scope (epic doc,
   "mime_denylist-Enforcement") specifies matching against "MIME-Type-Präfixe" at the
   upload handler and does not call for a sniffing mechanism; the codebase's one
   existing precedent for this exact class of check
   (`@blocked_upload_types` in `Nebu.Media.upload/1`) already trusts the declared
   header with no sniffing, and no MIME-sniffing utility exists anywhere in
   `server/lib` to build on. **Security tradeoff, stated explicitly:** a client can
   bypass the deny-list by declaring a false `Content-Type` (e.g. uploading an `.exe`
   payload while declaring `text/plain`). This is an accepted, pre-existing gap — Nebu
   never server-side parses or executes uploaded content based on its declared type
   (downloads simply echo the stored `content_type` back, per `disposition_for/2`),
   and the ClamAV scan (Story 3/4) still inspects actual file bytes regardless of the
   declared header, so a mislabeled malicious file is still caught by the scan even
   if it slips past this policy gate. If magic-byte sniffing is wanted later, it is a
   follow-up story that would need its own sniffing module — out of scope here (see
   Dev Agent Guardrails).
4. **AC4 — Empty denylist means no rejections.** When `mime_denylist == ""` (the
   Story 9a default) or resolves to zero prefixes after parsing, no upload is ever
   rejected by this check — the feature is effectively off, and `upload_async/3`'s
   behavior is identical to a build that never implemented this story.
5. **AC5 — Denylist changes take effect without a restart.** Because AC1 reads
   through `Nebu.Media.Config.get/0` per-request rather than caching the list at
   process start, an admin `upsert/1` of `mime_denylist` (Story 9a/9b) is reflected
   on the very next PUT to `upload_async/3` — bounded by the same cache-invalidation
   timing Story 9a already guarantees (immediate on the writing node, `:pg`
   broadcast to peers, 60s TTL fallback worst case) — with no code deploy or process
   restart required.

## Acceptance Tests

New test file `server/test/nebu/media/mime_denylist_test.exs` (ExUnit; follows the
`Plug.Test`/`Plug.Conn` + `MediaFakes` boundary-swap conventions of
`media_async_upload_test.exs`, and stubs `Nebu.Media.Config.get/0` via the same
app-env seam pattern already used elsewhere in this epic for config-dependent
handlers — e.g. `Application.put_env(:nebu_http, :media_config_module,
FakeMediaConfig)` or an equivalent injectable source if `Nebu.Media.Config` itself
does not expose a swap seam by the time this story lands, matching whatever seam 9a
actually ships):

1. `"PUT .../upload/:server/:media_id with a Content-Type matching a configured
   mime_denylist prefix → 400 M_BAD_JSON, nothing stored, no state transition"` —
   seeds `mime_denylist: "application/x-msdownload"`, PUTs a valid `:reserved`
   reservation with `Content-Type: application/x-msdownload`, asserts `conn.status
   == 400`, `errcode == "M_BAD_JSON"`, the storage fake received no `put` call, and
   the row remains `:reserved` (no `{:reserved, :quarantined}` transition recorded).
2. `"PUT .../upload with a Content-Type NOT matching any configured mime_denylist
   prefix proceeds normally through the full happy path"` — seeds `mime_denylist:
   "application/x-msdownload"`, PUTs with `Content-Type: image/png`, asserts `200
   {}`, storage `put` was called, state transitions to `:quarantined`, and the scan
   job is enqueued (i.e. this check does not interfere with 2b's existing pipeline
   when it does not match).
3. `"PUT .../upload with an empty mime_denylist ('') allows every Content-Type,
   including ones that would be denied under a non-empty list"` — seeds
   `mime_denylist: ""`, PUTs with an arbitrary/unusual `Content-Type` (e.g.
   `application/x-msdownload`), asserts the upload succeeds (200), proving the
   feature is a no-op when the list is empty (AC4).
4. `"a mime_denylist config change takes effect on the very next upload without a
   restart"` — PUTs once with a `Content-Type` while `mime_denylist` does not yet
   include it (asserts success), then updates the config (`Nebu.Media.Config.
   upsert/1` or the equivalent fake-config mutation) to include that prefix, PUTs
   again with a fresh reservation and the same `Content-Type`, asserts the second
   PUT is rejected with 400 — no process restart or code path other than the config
   change occurs between the two PUTs.
5. `"mime_denylist rejection is evaluated before the size limit check"` — seeds a
   denied `Content-Type` on a body that is ALSO over `max_upload_size_bytes`, asserts
   the response is `400 M_BAD_JSON` (denylist), not `413 M_TOO_LARGE` — proving the
   ordering from AC2 (denylist gate runs before size check, before body read).
6. `"mime_denylist enforcement does not apply to the existing hardcoded
   @blocked_upload_types check — both remain independently active"` — seeds an empty
   `mime_denylist` and PUTs a `Content-Type` of `text/html` (a `@blocked_upload_types`
   entry, unrelated to this story's config), asserting the existing hardcoded check's
   behavior for the synchronous `upload/1` path is unchanged by this story (a
   regression guard, not new production behavior — see Dev Agent Guardrails).

## Technical Requirements

### Where this slots into the Story 2b pipeline

Per 2b's Technical Requirements ("Handler — validation order"), the mime_denylist
check is a new step evaluated **immediately after `Content-Type` is resolved (2b
AC1), and before the size check (2b step 5 / AC6)** — i.e. it runs after the pure-read
guards (lookup/ownership/expiry/state, 2b steps 1–4) but before anything that reads
the body or touches storage:

```
1. lookup_reservation           → 404 if no row
2. ownership check              → 403
3. expiry check                 → 404
4. state guard (:reserved?)     → 409
5. mime_denylist check (NEW)    → 400 M_BAD_JSON   ← this story
6. size limit check             → 413
7. body read
8. store_and_quarantine seam    → 200
```

This ordering must be **before**, not after, the storage write — rejecting after the
S3 write and persisted row would mean either deleting an already-stored object (extra
failure mode, extra round-trip, and a brief window where a denied file's ciphertext
sits in S3) or leaving an orphaned object behind, neither of which is necessary when
the check only needs the request's `Content-Type` header, which is available before
any bytes are read. Placing it at step 5 (before the body read, step 7) means a
rejected upload never allocates a body buffer, never calls
`storage_module().put/2`, and never inserts/transitions a `media_files` row — matching
2b's own AC9 invariant that a rejected/failed upload leaves the row untouched in
`:reserved`.

### MIME-detection mechanism

Reuses the exact `Content-Type` value 2b's `upload_async/3` already resolves (client
header, defaulted to `application/octet-stream` per 2b AC1) — **no new detection
mechanism is introduced.** Matching is prefix-based:
`String.starts_with?(content_type, prefix)` for each `prefix` in the parsed
`mime_denylist` list, case-sensitive on the already-lowercased MIME type (Plug
normalizes `Content-Type` header casing; do not add a second normalization step). A
match on any configured prefix rejects the request. See AC3 for the explicit
header-trust-vs-sniffing tradeoff and why this story does not sniff.

### Config read

`Nebu.Media.Config.get/0` (Story 9a, `server/lib/nebu/media/config.ex`) — read the
`mime_denylist` string value, split on `,`, trim whitespace per token, discard empty
tokens (so `""` parses to `[]`, satisfying AC4). Do not cache the parsed list across
requests in `Nebu.Media` itself; call `get/0` per request so Story 9a's own
cache/TTL/broadcast mechanism (not a second one in this module) is what delivers the
"no restart" property (AC5).

### Error shape

Reuses the existing `error/4` helper already in `Nebu.Media`
(`error(conn, status, errcode, message)`, used throughout `upload/1` and
`upload_async/3`) with `error(conn, 400, "M_BAD_JSON", "Content-Type not permitted by
admin policy")` — the same status/errcode `@blocked_upload_types` uses for its
structurally identical "Content-Type not permitted for upload" rejection, so clients
see one consistent contract for "this Content-Type is not allowed" regardless of
which of the two (hardcoded XSS blocklist vs. admin-configured denylist) fired. Do
not invent a new errcode for this story.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/media.ex` | UPDATE | Add the `mime_denylist` check inside `upload_async/3` (Story 2b), positioned per the validation order above; reads `Nebu.Media.Config.get/0` per request |
| `server/test/nebu/media/mime_denylist_test.exs` | CREATE | Acceptance Tests above |
| `server/test/nebu/media/media_fakes.exs` | UPDATE (if needed) | Extend `MediaFakes` with a `Nebu.Media.Config` test double/seam if 9a did not already ship one usable here |

## Dev Agent Guardrails

### Do Not Change

- **The ClamAV scan (Story 3/4) is not replaced, weakened, bypassed, or made
  conditional on this check.** `mime_denylist` is an additional, independent gate
  evaluated at upload time against the declared `Content-Type`; every file that
  passes it still enters `:quarantined` and goes through the full async scan exactly
  as it does today. Do not skip the scan-job enqueue for any file on the basis that
  it "already passed" the mime_denylist check, and do not read or interpret ClamAV
  scan results as part of this story's logic.
- **`Nebu.Media.upload/1`'s existing hardcoded `@blocked_upload_types` list is a
  separate, unrelated mechanism and must not be merged into, replaced by, or made to
  read from `mime_denylist`.** `@blocked_upload_types` is a fixed, non-admin-editable
  set of stored-XSS-vector types (`text/html`, `text/javascript`, `image/svg+xml`,
  etc.) that protects against a specific rendering-based attack regardless of admin
  policy; `mime_denylist` is an admin-editable, compliance-driven category policy.
  Both must remain independently active after this story. Do not remove, alias, or
  fold `@blocked_upload_types` into the new check.
- **Do not implement MIME sniffing (magic-byte/content inspection) in this story.**
  See AC3 — this is a deliberate scope boundary, not an oversight. If a future story
  wants content-based detection, it is a new, separately-scoped piece of work with
  its own sniffing module and its own security review of the tradeoffs (performance
  cost of buffering-then-inspecting vs. the header-trust gap this story accepts).
- Do not add a second config cache/TTL mechanism for `mime_denylist` inside
  `Nebu.Media` — always call `Nebu.Media.Config.get/0`; Story 9a's cache/`:pg`/TTL is
  the only invalidation mechanism in play (AC1/AC5).
- Do not apply this check to the existing synchronous `PUT /_matrix/media/v3/upload`
  handler (`upload/1`) as part of this story — 9c's scope, per the epic and per
  Story 2b's dependency list, is the async upload path (`upload_async/3`, Story 2b)
  only. Extending the same `mime_denylist` read to the synchronous handler (Story
  2c's shared pipeline once it lands) is that story's own follow-up, not bundled
  here, to keep this story's diff scoped to a single call site per ADR's S-Ceiling
  sizing rubric.

## Dependencies

- **Depends on:**
  - **9a** (`media_config` table + `Nebu.Media.Config` module) — the config source
    this story reads `mime_denylist` from via `get/0`; this story adds no new config
    storage of its own.
  - **2b** (`PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`) — the integration
    point; this story adds one validation step inside `upload_async/3`, it does not
    introduce a new endpoint or handler function.
- **Enables:** Nothing further in this epic depends on 9c directly (it is a leaf
  enforcement story); Story 9b's settings UI (already written) is the editing surface
  for the `mime_denylist` value this story enforces, but 9b does not depend on 9c
  landing first — 9a's `Nebu.Media.Config.upsert/1` is what 9b calls regardless of
  whether this story's read-side enforcement exists yet.

## Dev Agent Record

### Cycle 0 (initial implementation, scope-adapted per pre-ATDD note)

- **Story 2b (`Nebu.Media.upload_async/3`) confirmed absent on this branch** —
  no `:media_id`-parameterized PUT route in
  `server/lib/nebu/web/router/media.ex`, no `upload_async/3` in
  `server/lib/nebu/media.ex`. Per
  `_bmad-output/nebu/epics/media-security-admin-control/step-results/9c-mime-denylist-enforcement/scope-adaptation.md`
  (authoritative, decided pre-ATDD), this cycle implements the enforcement
  decision as a **standalone, public, unwired unit** — `Nebu.Media.mime_denylist_rejected?/1`
  — rather than modifying a handler that does not exist.
- **What was added** (`server/lib/nebu/media.ex`): `mime_denylist_rejected?/1`
  (public) plus a private `parse_mime_denylist/1` helper.
  - Takes an already-resolved `Content-Type` string; does no header
    parsing/defaulting itself (caller's job, mirroring `upload/1`'s existing
    `base_content_type(conn) || "application/octet-stream"` resolution before
    its own `@blocked_upload_types` check).
  - Calls `Nebu.Media.Config.get/0` on every invocation — no local caching in
    `Nebu.Media` (AC1/AC5); Story 9a's ETS/`:pg`/TTL cache is the sole cache
    layer.
  - Parses the `mime_denylist` string (comma-separated prefixes): splits on
    `,`, trims each token, and discards empty tokens via `Enum.reject/2` —
    `""` parses to `[]` (AC4). This matters because
    `String.starts_with?(x, "")` is always `true`; an undiscarded empty token
    would silently deny every upload.
  - Returns `true` if the content type `String.starts_with?/2` any parsed
    prefix (case-sensitive, no normalization, no content sniffing — AC3),
    else `false`.
  - Full `@doc` on the function documents the exact future wiring point for
    Story 2b (see below) so that story does not have to re-derive it.
- **`@blocked_upload_types` and `upload/1` were not touched** — the two
  mechanisms remain independent per Dev Agent Guardrails. The existing
  `media_upload_test.exs` regression test for `@blocked_upload_types` (added
  in test-review) still passes unmodified.
- **No MIME sniffing was implemented** (AC3, Dev Agent Guardrails) — matching
  is purely prefix-based against the caller-supplied string.
- **No second config cache was added** — `Nebu.Media.Config` itself
  (`server/lib/nebu/media/config.ex`) was not modified; only its existing
  `get/0` public read path is called.

### Wiring instruction for Story 2b (not performed in this story — `upload_async/3` does not exist yet)

Once Story 2b lands `Nebu.Media.upload_async/3`, its handler must call
`Nebu.Media.mime_denylist_rejected?/1` immediately after `Content-Type` is
resolved (2b AC1) and before the size-limit check (2b AC6/413) — validation
step 5 of the order 2b's own Technical Requirements section specifies,
between the `:reserved` state guard (step 4) and the size check (step 6):

```elixir
content_type = base_content_type(conn) || "application/octet-stream"

if Nebu.Media.mime_denylist_rejected?(content_type) do
  error(conn, 400, "M_BAD_JSON", "Content-Type not permitted by admin policy")
else
  # ... continue to the size-limit check (step 6) ...
end
```

This same instruction is also recorded as a `@doc` comment directly above
`mime_denylist_rejected?/1` in `server/lib/nebu/media.ex`.

### Test results

- `mix test test/nebu/media/mime_denylist_test.exs test/nebu/media/media_upload_test.exs`
  → **17/17 passed** (10 new mime_denylist tests + 7 media_upload tests, all
  green, no regressions). Of the 7 media_upload tests, 6 are pre-existing and
  1 (the `@blocked_upload_types` regression guard) was newly added in this
  same story's diff during test-review — it is pre-existing relative to this
  dev-story cycle, not relative to the changeset as a whole.
- `mix test --warnings-as-errors` (full suite) → **1576/1699 passed**, 4
  skipped, 449 excluded; 123 pre-existing failures, all in
  `Nebu.Admin.LogsLive.*`/`Nebu.Web.AdminBootstrapLiveTest`/`Nebu.Web.OidcBootstrapOnlyTest`/etc.,
  caused by `LazyHTML.NIF.from_document/1` being unavailable in the Alpine
  test container (a native-dependency/environment gap unrelated to this
  change) — none reference `Nebu.Media` or this story's diff. No compiler
  warnings were introduced (the run reached and completed test execution
  under `--warnings-as-errors`, which aborts at compile time if a warning
  were present).

### Cycle 1 (code-review fix cycle — documentation accuracy)

- Fixed code-review M1 (`base_content_type/1` normalization dependency
  mischaracterized as coming from Plug — corrected to attribute it to the
  caller's own `String.downcase()` in `base_type/1`; Plug only lowercases
  header *field names*, never *values*) and M2 (stale RED-phase moduledoc in
  `mime_denylist_test.exs`, rewritten to reflect the current GREEN state).
  I1/I2 folded in. No test assertions or production behavior changed in this
  cycle — documentation/comments only. 17/17 tests still green.

### Post-security-review fix (Kassandra, 2026-07-13, MEDIUM-1)

Kassandra's review (CLEAN — 0 CRITICAL/HIGH, 1 MEDIUM advisory, 3 INFO; full
report: `docs/stories/media-security-admin-control/security-reports/9c-mime-denylist-enforcement-security-review-2026-07-13.md`)
flagged that `String.starts_with?/2` matching is case-sensitive on BOTH
sides with no normalization, which is domain-wrong for MIME types (RFC
6838, case-insensitive) and has two distinct facets:

- **(a)** the `content_type` side depends on an unenforced caller contract
  (documented in Cycle 0, but "a comment" is a weak enforcement tier) — left
  AS-IS, because the story's Technical Requirements explicitly say "do not
  add a second normalization step" for `content_type` here, mirroring the
  identical, already-shipped property of `@blocked_upload_types` in
  `upload/1`. Overriding an explicit story directive for an advisory
  (non-blocking) MEDIUM finding was judged out of scope for this fix;
  accepted as a documented residual risk (backstopped by ClamAV for the
  malware subset per AC3's own stated tradeoff).
- **(b)** the denylist's OWN configured prefixes (from admin input,
  `Config.get/0`, never downcased by `config.ex`'s `valid_mime_denylist?`)
  were compared case-sensitively too — an admin entering `Application/Zip`
  would have that prefix silently never match a correctly-lowercased
  incoming `application/zip`, with no error/audit signal that their policy
  is a no-op. This facet does NOT touch `content_type` handling and does
  NOT contradict the "no second normalization step" directive (that
  directive is about `content_type`, not about the denylist's own stored
  values) — **fixed**: `parse_mime_denylist/1` now lowercases each token
  after trimming, before matching. No change to `Nebu.Media.Config`/
  `config.ex` (still stores/validates values case-as-entered; this
  function normalizes only at its own read site).
- Two new tests added to `mime_denylist_test.exs` (`security-review
  MEDIUM-1b` describe block) covering a single mixed-case prefix and a
  mix of mixed-case + already-lowercase prefixes. 19/19 story tests green
  after this fix (`mix test test/nebu/media/mime_denylist_test.exs
  test/nebu/media/media_upload_test.exs --warnings-as-errors`).

### File List

- `server/lib/nebu/media.ex` — UPDATE: added `mime_denylist_rejected?/1`
  (public) and `parse_mime_denylist/1` (private helper); Cycle 1 doc fixes;
  post-security-review prefix-lowercasing fix (MEDIUM-1b).
- `server/test/nebu/media/mime_denylist_test.exs` — CREATE (ATDD red-phase
  scaffold, now green); Cycle 1 comment fixes; 2 tests added post-security-
  review (MEDIUM-1b).
- `server/test/nebu/media/media_upload_test.exs` — UPDATE: added
  `@blocked_upload_types` regression test (test-review MAJOR fix).
- `docs/stories/media-security-admin-control/9c-mime-denylist-enforcement.md`
  — this Dev Agent Record + `status` frontmatter update.
