## Applicable spec MUSTs — `POST /_matrix/media/v3/upload` (sync) vs `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` (async step 2)

**Method fact-check (flag):** The story's AC3 heading calls the sync endpoint `PUT /_matrix/media/v3/upload`. Per spec (`id="post_matrixmediav3upload"`, line 34559) it is **POST**, not PUT. PUT only applies to the async companion `.../upload/{serverName}/{mediaId}`. Test/impl naming must not silently adopt "PUT" for the sync path.
**Coordinator note:** The story itself already documents this as a pre-existing, intentional deviation ("the epic prose calls this POST, but the actual route in server/lib/nebu/web/router/media.ex is wired as `put "/v3/upload"`") and Dev Agent Guardrails explicitly forbid changing PUT back to POST in this refactor. Not a new defect — Oracle's flag confirms the story's own footnote is spec-accurate, no action needed beyond what the story already says.

**Sync `POST /_matrix/media/v3/upload` — MUSTs:**
- Rate-limited: Yes; Requires auth: Yes (Bearer token)
- `Content-Type` header: Optional since v1.12, defaults to `application/octet-stream` if absent
- `filename` query param optional, used for `Content-Disposition` on later download
- Body: raw `<bytes>`, no JSON envelope
- 200 response: `{"content_uri": "mxc://<server>/<mediaId>"}` — **Required** field
- 403 `M_FORBIDDEN`: disallowed file type OR quota reached
- 413: too large (Nebu convention uses `M_TOO_LARGE`, spec example also uses `M_TOO_LARGE`)
- 429 `M_LIMIT_EXCEEDED` + `retry_after_ms`
- **Spec defines NO 400 response for this endpoint** — Nebu's `400 M_UNKNOWN`/blocked-content-type-list behavior is a Nebu-specific extension, not spec-mandated; AC3 must not claim it as "spec contract," only as existing Nebu behavior to preserve.

**Auth error (generic, all authenticated endpoints):**
- Missing token → 401 `M_MISSING_TOKEN`
- Invalid/expired token → 401 `M_UNKNOWN_TOKEN`, optionally with `soft_logout: true`

**Async `PUT .../upload/{serverName}/{mediaId}` (Story 2b, for parity comparison) — MUSTs:**
- Added v1.7; requires prior `POST /_matrix/media/v1/create`
- 200 response body is `{}` (NOT `content_uri` — different shape from sync path)
- 403 `M_FORBIDDEN`: disallowed type, quota, OR different user than the one that called `/create` (ownership check)
- 404 `M_NOT_FOUND`: MXC ID not created via `/create`, or expired
- 409 `M_CANNOT_OVERWRITE_MEDIA`: media ID already has content
- 413/429 same as sync

## Test coverage MUST-list

1. Sync 200 → `content_uri` field present, `mxc://` scheme, server name matches config
2. Sync 401 `M_MISSING_TOKEN` (no `Authorization` header) and `M_UNKNOWN_TOKEN` (bad/expired token)
3. Sync 413 `M_TOO_LARGE` when body exceeds configured max — enforced before storage-pipeline call
4. Sync 400 for blocked content-type (Nebu extension — assert unchanged, not spec-required)
5. AC1: assert row is created exclusively via `StateMachine`, never `Media.DB.insert/1` directly (code-path assertion, not API-observable — unit/integration test on the Elixir module)
6. AC2: assert identical pipeline function reference used by both sync and 2b's PUT handler (unit test / code inspection, not spec-observable)
7. AC4: post-sync-upload row state == `:quarantined` (never `:reserved`) + Oban scan job enqueued — DB/job-queue assertion, not CS-API-visible; compare directly against async PUT's post-completion row state for equivalence
8. Regression: `Content-Type` defaulting to `application/octet-stream` when header omitted (sync path)
9. Regression: `filename` query param persisted for `Content-Disposition` equivalently to async path (NOTE: story's sync path today does NOT read a filename query param at all — `store_upload/4` has no `filename` handling. Confirm with dev-story whether AC scope requires wiring it, or whether this is future/out-of-scope; story's File List/Technical Requirements do not mention filename for the sync path, so likely NOT in scope for 2c — flag but do not block)

**Not CS-API-observable (flag per test-guidance.md):** AC1, AC2, AC4 are internal-implementation acceptance criteria — the Matrix wire contract (AC3) is the only externally testable surface; AC1/2/4 need ExUnit-level assertions against `Nebu.Media.StateMachine`/pipeline function calls and `media_files.state`, not Gherkin/HTTP-level tests.

## Coordinator addendum — critical design finding for ATDD/dev-story

Read `server/lib/nebu/media/state_machine.ex` and the story's Acceptance Tests section closely:
this story's own acceptance test #3 ("sync-uploaded row's post-upload state is equivalent to an
async row's post-PUT state") explicitly requires: **sync row has a SINGLE media_state_transitions
entry (into :quarantined)**, while the **async row has TWO** (NULL->:reserved genesis, then
:reserved->:quarantined). This means the sync path must NOT reuse the existing `create/1` (which
hardcodes state='reserved' and writes a NULL->reserved transition) followed by `transition/4`
(reserved->quarantined) — that would produce TWO transition rows for sync, contradicting the
story's own acceptance test. `Nebu.Media.StateMachine` currently has no "create directly into
:quarantined in one step" function. Dev-story will likely need to add a new StateMachine function
(e.g. `create_quarantined/1`, mirroring `create/1`'s genesis-insert shape but with
`state='quarantined'` and a single `NULL -> 'quarantined'` audit row) rather than composing
`create/1` + `transition/4`. Flag this explicitly to ATDD (tests should assert exactly one
`media_state_transitions` row for the sync path) and to dev-story (new StateMachine function
needed, or clarify with 1b's author role if the module's public API should change).
