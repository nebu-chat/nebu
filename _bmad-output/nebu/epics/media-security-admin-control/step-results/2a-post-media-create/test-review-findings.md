## Test Quality Review — story `2a-post-media-create` (RED phase, epic `media-security-admin-control`)

**Scope:** `server/test/nebu/media/media_create_test.exs` (new, 243 lines), `media_fakes.exs` (+57 lines), `state_machine_test.exs` (+81 lines). Backend/ExUnit stack. All three files parse cleanly; `mix format --check-formatted` flags one missing blank line in `media_create_test.exs` (cosmetic).

### AC Coverage Map
| AC | Covered | Test |
|---|---|---|
| 1 (reservation via state machine, uploader_user_id) | Yes | happy-path test asserts seam call + genesis DB test 2 |
| 2 (200, content_uri + unused_expires_at) | Yes | happy-path test |
| 3 (429 M_LIMIT_EXCEEDED + retry_after_ms) | Yes | pending-cap test |
| 4 (403 M_FORBIDDEN) | Yes | permission test |
| 5 (media_id/server_name format, PK uniqueness) | Partial | "two distinct ids" test is weak; format not validated as base64url; PK-collision only tested at StateMachine layer |
| 6 (no body/query accepted) | Yes | stray query-param test |
| 7 (401 M_MISSING_TOKEN / M_UNKNOWN_TOKEN) | Yes | two auth tests |

### Findings

**MAJOR — Permission-before-pending-count ordering (Technical Requirements §6) is untested.** The story explicitly requires "permission check (403) runs before the pending-count check (429)" so a forbidden user never learns their pending-count via a 429. No test sets `media_permission_fun -> false` together with `media_pending_count_fun` at/over cap in the same request. The two failure modes are only tested in isolation, so an accidental swap of the `cond` branches in the handler would pass every staged test.

**MAJOR — Collision-retry path (AC5 / "regenerate once on PK violation") has zero coverage at the handler level.** Technical Requirements §5 specifies `do_create/2` catches `{:error, :media_id_taken}` and silently retries once with a new id. The "two distinct media_ids" test never drives this path — the fake always returns `{:ok, ...}`. `state_machine_test.exs`'s genesis test covers only the low-level primitive, not the caller's retry orchestration. A missing/broken retry branch would surface as an untested 500 in production.

**MINOR — `media_id` format not validated** (should assert base64url regex/length).
**MINOR — Default `max_pending_per_user` (20) and default `unused_expires_at` window (24h) never asserted** (tests only exercise overridden values).
**MINOR — "exactly one" state-machine invocation not enforced** (no `refute_received` for a second call).
**INFO — Formatting nit** (missing blank line, cosmetic).
**INFO — Genesis tests in state_machine_test.exs are solid**: proper DB-row-shape assertions, no hard waits, correct fixture conventions.
**INFO — Staged tests match the story's own "Acceptance Tests" list 1:1**; the two MAJOR gaps are Technical-Requirements-level behaviors (§5, §6) the story author didn't enumerate as acceptance-test bullets even though the requirements sections describe them explicitly.

## RE-REVIEW (post fix cycle) — CLEAN, 0 MAJOR remaining

Both MAJORs verified genuinely fixed with non-vacuous assertions (ordering test would
catch a swapped cond clause; retry test would fail if retry logic absent or buggy).
All 3 MINORs addressed. All 7 ACs still covered, no regressions. Test count 7 -> 10.
One INFO nuance noted (retry test doesn't assert 2nd attempt's media_id differs from
1st's — acceptable, covered by separate distinct-ids test). Proceeding to dev-story.
