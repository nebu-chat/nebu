---
story_id: 1c-download-gate-enforcement
title: "Media State Machine Foundation: Download-Gate Enforcement (State to HTTP)"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
baseline_commit: 9a58f7ba07956ee6b0ce466fa737b513bada2b2e
---

## Summary

Today's `Nebu.Media.download/4` (and the `thumbnail/3` handler it shares `with_authorised_media/4`
with) serves bytes to any room member as soon as `Nebu.Media.DB.lookup/2` finds a row — there is no
notion of a scan/lifecycle state at all. Story 1a adds a `state` ENUM column to `media_files` and
Story 1b adds `Nebu.Media.StateMachine` as the sole writer of that column. This story closes the
loop: it makes the download path the **single enforcement point** (ADR-026) that reads `state`
before any bytes are streamed and maps it to an HTTP response.

`:released` is the only state that serves bytes. Every other state — including states this epic
hasn't invented yet — must deny. The one deliberately non-obvious rule: `:admin_blocked` returns
`451` status but the `M_NOT_FOUND` errcode (not `M_NOT_YET_UPLOADED`), and its response body must be
textually identical to a genuine 404, so a client (or the uploader) cannot distinguish "an admin
blocked this" from "this never existed" — anonymity of the moderation action is a deliberate,
accepted trade-off per ADR-026.

**Scope note:** `/_matrix/client/v1/media/download/...` does not exist as a route in
`server/lib/nebu/web/router/media.ex` today — only `/_matrix/media/v3/download/...` and
`/v3/thumbnail/...` are wired up, both via the shared `with_authorised_media/4` helper. This story
does not add the `/v1/media/download` route (that's a separate, not-yet-scheduled concern); it
places the gate in the shared helper so that route inherits the identical enforcement the moment it
is added, with zero duplicated logic. See Dev Agent Guardrails.

## User Story

As the Nebu server operator, I want every media download (and thumbnail) request gated by the
file's scan/lifecycle state before any bytes are read from storage, so that quarantined, infected,
soft/hard-deleted, or admin-blocked files are never served to clients — and so that an admin's
decision to block a file stays indistinguishable from a file that simply never existed.

## Acceptance Criteria

1. **AC1 — Pending states → 451 `M_NOT_YET_UPLOADED`.** `state` in `[:reserved, :quarantined,
   :scanning]` returns HTTP 451 with errcode `M_NOT_YET_UPLOADED`.
2. **AC2 — Admin block → 451 status, `M_NOT_FOUND` errcode, anonymous body.** `state == :admin_blocked`
   returns HTTP 451 with errcode `M_NOT_FOUND`, and the JSON body (`errcode` + `error` message) is
   textually identical to the body used for the genuine 404 cases in AC3 — only the HTTP status
   line differs (451 vs. 404).
3. **AC3 — Terminal-negative states → 404 `M_NOT_FOUND`.** `state` in `[:infected, :deleted,
   :hard_deleted]` returns HTTP 404 with errcode `M_NOT_FOUND`.
4. **AC4 — `:released` → 200 OK.** `state == :released` serves the decrypted original bytes exactly
   as today (no regression to Content-Disposition, Content-Type, Range, or CSP header behavior).
5. **AC5 — Explicit allow-list, not a deny-list.** The success path is implemented as a single,
   explicit positive match on `:released`. It is not derived by enumerating "known bad" states and
   defaulting everything else to serve.
6. **AC6 — Unknown/future states default to deny, never to 200 or 500.** Any state not covered by
   AC1–AC4 — including states introduced by later stories (e.g. `:scan_failed`, Story 4a) and any
   value the handler doesn't recognize — falls through to the AC1 response (451
   `M_NOT_YET_UPLOADED`). It must never raise/500 and must never fall through to 200.
7. **AC7 — Gate runs before file streaming.** The state check happens immediately after the
   `media_files` row lookup and before any storage fetch or AES-256-GCM decrypt work. A denied
   request never calls the storage boundary (`Nebu.Media.Storage.get/1` in production).

## Acceptance Tests

New file `server/test/nebu/media/media_download_gate_test.exs` (mirrors the fixture/fake-boundary
conventions in `media_download_test.exs` / `media_test_support.exs` / `media_fakes.exs` — inject
`row.state` via the existing `media_row/1` test helper, extended with a `:state` option defaulting
to `:released`):

1. `"state :reserved → 451 M_NOT_YET_UPLOADED"`
2. `"state :quarantined → 451 M_NOT_YET_UPLOADED"`
3. `"state :scanning → 451 M_NOT_YET_UPLOADED"`
4. `"state :admin_blocked → 451 status with M_NOT_FOUND errcode"`
5. `"state :infected → 404 M_NOT_FOUND"`
6. `"state :deleted → 404 M_NOT_FOUND"`
7. `"state :hard_deleted → 404 M_NOT_FOUND"`
8. `"state :released → 200 OK with original decrypted bytes"` (regression guard alongside the
   existing `media_download_test.exs` AC2 coverage — same fixture, now with `state: :released`
   explicit instead of implicit)
9. `"unrecognized/future state (:scan_failed and an arbitrary unmapped atom) → 451
   M_NOT_YET_UPLOADED, never 200, never 500"` — proves AC5/AC6's allow-list-first structure, not
   just today's five known states.
10. `"denied states never reach the storage boundary"` — inject a storage fake whose `get/1`
    raises/flunks if invoked, assert it's never called for any of the seven non-released states
    above (AC7).
11. **Anonymity test (AC2):** `"admin_blocked response body is byte-identical to a genuine 404
    M_NOT_FOUND response — same errcode and error message text, only the HTTP status differs (451
    vs. 404)"` — decode both JSON bodies (e.g. `:admin_blocked` vs. `:hard_deleted`, and vs. the
    existing unknown-media-id 404 in `media_download_test.exs`) and assert the `errcode`/`error`
    maps are equal; only `conn.status` is allowed to differ.
12. **Corollary (not a formal AC, include as a bonus regression):** `"GET thumbnail for a
    non-released state is denied the same way as download"` — since the gate lives in the shared
    `with_authorised_media/4` helper, `/v3/thumbnail/...` inherits it for free; one representative
    non-released state (e.g. `:infected`) asserted against the thumbnail route.

## Technical Requirements

### Where the check happens

In `server/lib/nebu/media.ex`, inside `with_authorised_media/4`, immediately after the `{:ok, row}`
match from `db_module().lookup/2` — **before** the membership check and before
`fetch_and_decrypt/3`. Running it before the membership check is a deliberate choice: a denied
non-released file returns the same response regardless of whether the requester is a room member,
which avoids leaking membership-shaped information about files nobody should be able to fetch
anyway, and it's strictly cheaper (no membership lookup needed on a state-denied path).

Illustrative (non-normative) shape — the dev agent may structure this differently, but MUST
preserve: `:released` as the single explicit positive match, and a catch-all-denies (never
catch-all-allows) tail:

```elixir
defp with_authorised_media(conn, server_name, media_id, on_ok) do
  user = conn.assigns[:current_user]

  case db_module().lookup(server_name, media_id) do
    {:ok, row} ->
      case download_gate(row.state) do
        :serve ->
          if membership_module().member?(row.room_id, user) do
            fetch_and_decrypt(conn, row, on_ok)
          else
            error(conn, 403, "M_FORBIDDEN", "You are not a member of this room")
          end

        {status, errcode} ->
          error(conn, status, errcode, gate_message(errcode))
      end

    {:error, :not_found} ->
      error(conn, 404, "M_NOT_FOUND", "Media not found")
  end
end

defp download_gate(:released), do: :serve
defp download_gate(:admin_blocked), do: {451, "M_NOT_FOUND"}
defp download_gate(state) when state in [:infected, :deleted, :hard_deleted], do: {404, "M_NOT_FOUND"}
defp download_gate(_other), do: {451, "M_NOT_YET_UPLOADED"}

defp gate_message("M_NOT_FOUND"), do: "Media not found"
defp gate_message("M_NOT_YET_UPLOADED"), do: "Media not yet available"
```

The catch-all `download_gate(_other)` clause is what makes AC6 hold for `:scan_failed` (added later
by Story 4a) and any other unforeseen value — it costs nothing extra and needs no update when new
states are added, as long as they should default to the pending/451 treatment (an explicit new
terminal state would need its own clause, same as `:admin_blocked` today).

### Response body shapes

- `M_NOT_YET_UPLOADED`: `%{"errcode" => "M_NOT_YET_UPLOADED", "error" => "Media not yet available"}`,
  HTTP 451.
- `M_NOT_FOUND` (both the 404 states AND the anonymized `:admin_blocked` 451): `%{"errcode" =>
  "M_NOT_FOUND", "error" => "Media not found"}` — **the exact same message string** already used by
  the existing unknown-media-id 404 branch and by `fetch_and_decrypt/3`'s not-found branch. Reusing
  the literal existing string (not a new one) is what makes AC2's anonymity property hold: nothing
  in the response distinguishes "admin blocked this" from "this genuinely doesn't exist" except the
  HTTP status line, which per ADR-026 is an accepted, deliberate leak surface (not the body).

### Inline SQL / state lookup (ADR-018: no repository layer)

`server/lib/nebu/media/db.ex`'s `@sql_lookup` currently does:

```sql
SELECT media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
       uploader_user_id, uploaded_at, deleted
FROM media_files
WHERE server_name = $1 AND media_id = $2 AND deleted = false
LIMIT 1
```

Two changes needed here, coordinated with Story 1a (verify whether 1a already made them — if so,
1c only needs to consume the extra column; if not, 1c must make them since it's the first story
that actually reads `state`):

1. Add `state` to the `SELECT` list, and update `to_map/1`'s fixed-arity list pattern (currently 9
   positional elements) to include it. Convert the raw column value to an atom **defensively** —
   use `String.to_existing_atom/1` (not `String.to_atom/1`) since the finite, compile-time-known
   enum values are already atoms this module references (`:released`, `:admin_blocked`, etc.);
   `to_existing_atom/1` fails closed instead of growing the atom table on unexpected input.
2. Drop the `AND deleted = false` filter from `WHERE`. The legacy boolean `deleted` column must stop
   silently converging `state: :deleted` rows into the `{:error, :not_found}` branch — that would
   make AC3's `:deleted` case unreachable through this handler and split enforcement across two
   places (the SQL WHERE clause and the new `download_gate/1`), which is exactly the "single
   enforcement point" ADR-026 argues against. All states must reach `download_gate/1`; only a truly
   absent row (no matching `(server_name, media_id)` at all) may short-circuit to the existing
   `{:error, :not_found}` → 404 branch.

`server/test/nebu/media/media_test_support.exs`'s `media_row/1` helper needs a `:state` option
(default `:released`, so every existing test that doesn't care about state keeps passing
unmodified) for the new gate tests to set per-scenario.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/media.ex` | UPDATE | Add the state gate (`download_gate/1` + `gate_message/1`) inside `with_authorised_media/4`, running before the membership check and before `fetch_and_decrypt/3`. |
| `server/lib/nebu/media/db.ex` | UPDATE | Extend `@sql_lookup` to select `state`; extend `to_map/1`'s arity/parsing with a safe `String.to_existing_atom/1` conversion; drop the `deleted = false` WHERE filter so every state reaches the handler-level gate. |
| `server/test/nebu/media/media_test_support.exs` | UPDATE | Add a `:state` option to `media_row/1`, default `:released`. |
| `server/test/nebu/media/media_download_gate_test.exs` | NEW | ExUnit coverage for the full state→HTTP matrix, the unknown-state default-deny case, the storage-boundary-not-called case, and the admin_blocked anonymity property. |

## Dev Agent Guardrails

**Do Not Change:**

- `media_state_transitions` table, its append-only trigger, or its RLS policies (Story 1a /
  ADR-031 territory) — this story only reads `media_files.state`, never writes it and never touches
  the transitions table.
- `Nebu.Media.StateMachine` transition guards (Story 1b's module) — 1c has no write path to
  `state`; if a test needs a file in a given state, seed it directly in the fake/DB row, don't route
  it through a transition call.
- The message/errcode used for `:admin_blocked`. **This is the security-relevant part of the
  story:** do not invent a distinguishing errcode (e.g. `M_ADMIN_BLOCKED`) or a distinguishing
  message (e.g. mentioning "blocked", "policy", "administrator", or "moderation" anywhere in the
  body). Reuse the literal `"Media not found"` string used everywhere else `M_NOT_FOUND` is
  returned. An attacker who can tell "actively blocked by a human" apart from "never existed" can
  infer moderation activity against a specific user or file — that's the exact leak ADR-026 accepts
  the 451/404 status mismatch to prevent.
- The allow-list structure. Do not implement this as a deny-list with an implicit allow-by-default
  tail (e.g. `if state in [:reserved, :quarantined, :scanning, :admin_blocked, :infected, :deleted,
  :hard_deleted], do: deny(state), else: serve`). Any state this handler doesn't explicitly
  recognize MUST deny — a deny-list shape means a brand-new ENUM value added by a future migration
  silently serves bytes (fail-open) until someone remembers to add it to the list. `:released` must
  be the sole explicit positive match; everything else funnels through a catch-all that defaults to
  451, per AC6.
- The ordering relative to storage I/O. The gate must run before `Nebu.Media.Storage.get/1` /
  `Crypto.decrypt/3` — never move it after, even for refactors that seem to simplify the `with`
  chain in `fetch_and_decrypt/3`.
- `/_matrix/media/v3/upload`, `preview_url`, SSRF checks, Range-request parsing
  (`maybe_send_ranged/2`), and the Content-Disposition/CSP header logic in `serve_bytes/4` /
  `serve_inline_image/4` — all unrelated to this story, do not touch.
- Do not add the `/_matrix/client/v1/media/download/...` route to
  `server/lib/nebu/web/router/media.ex` in this story. It doesn't exist today and adding it is a
  separate, not-yet-scheduled concern (flagged as an open scope question against the epic text,
  which names both routes as the enforcement target). This story's obligation is that the shared
  `with_authorised_media/4` helper is correct, so that route — and any other future byte-serving
  route reusing it — inherits the identical gate with zero duplicated logic the moment it's added.
- Widening the gate to also cover `/v3/thumbnail/...` (via the shared helper) is intentional and
  in-scope for implementation (see corollary test #12) even though it's not separately enumerated
  as a formal AC — thumbnail is another byte-serving surface for the same underlying object, and
  leaving it ungated while download is gated would be a live security gap (an infected file's
  thumbnail still servable). If a future reviewer wants thumbnail state-gating tracked as its own
  AC, split it out; don't remove the shared-helper placement to "stay in scope."

## Dependencies

- **1a-media-files-migration** — provides the `state` ENUM column (plus `deleted_at` /
  `hard_deleted_at`) on `media_files`. This story assumes 1a's `Nebu.Media.DB.lookup/2` returns
  `state` in the row and does not pre-filter rows by the legacy `deleted` boolean (see Technical
  Requirements — if 1a hasn't made that SQL change, 1c makes it).
- **1b-state-machine-module** — provides `Nebu.Media.StateMachine`, the sole writer of `state`. This
  story is read-only with respect to `state`; it has no dependency on which specific transition
  guards 1b implements, only on the column existing and being trustworthy.
- Enables downstream: Story 2d's async-upload stall mechanism reuses this exact 451
  `M_NOT_YET_UPLOADED` mapping; Story 6a's admin-block action is only meaningful once
  `:admin_blocked` is enforced here exactly as ADR-026 specifies.

## Dev Agent Record

### Completion Notes

- Implemented the download gate as `download_gate/1` + `gate_message/1` inside
  `server/lib/nebu/media.ex`, called from `with_authorised_media/4` immediately after the
  `{:ok, row}` match, before the room-membership check and before `fetch_and_decrypt/3`. Shape
  matches the story's illustrative snippet: `:released` is the sole explicit positive match
  (AC5), `:admin_blocked` maps to `{451, "M_NOT_FOUND"}` (AC2, anonymized), `:infected` /
  `:deleted` / `:hard_deleted` map to `{404, "M_NOT_FOUND"}` (AC3), and a catch-all tail maps
  everything else (including `:reserved`/`:quarantined`/`:scanning` and any unrecognized atom)
  to `{451, "M_NOT_YET_UPLOADED"}` (AC1/AC6). `gate_message/1` reuses the exact pre-existing
  `"Media not found"` / new `"Media not yet available"` strings; the 404 branches use the
  literal same string as the existing unknown-media-id 404 branch, satisfying AC2's anonymity
  property.
- Verified `server/lib/nebu/media.ex` and `server/lib/nebu/media/db.ex` against their actual
  current state before writing code (both matched the story's description: no `state` gate
  existed yet, `db.ex` did not select `state` and still had `AND deleted = false` in its WHERE
  clause).
- `server/lib/nebu/media/db.ex`: added `state` to `@sql_lookup`'s SELECT list, dropped
  `AND deleted = false` from the WHERE clause (so every state — including `:deleted` /
  `:hard_deleted` — reaches the handler-level gate; only a truly absent row short-circuits to
  `{:error, :not_found}`), and extended `to_map/1`'s fixed-arity pattern (9 → 10 positional
  elements) to parse `state` via `String.to_existing_atom/1` (fails closed on unexpected raw
  values instead of growing the atom table via `String.to_atom/1`). Also updated the moduledoc's
  "Row shape returned by lookup/2" section to document the new `:state` field and the dropped
  WHERE filter.
- No changes needed to `server/test/nebu/media/media_test_support.exs` or
  `server/test/nebu/media/media_fakes.exs` — the `:state` option on `media_row/1` and the
  `MediaFakes.DB` lookup fake (which returns whatever row the test injects) were already staged/
  in place and required no further edits.
- The gate lives in the shared `with_authorised_media/4` helper, so both `download/4` and
  `thumbnail/3` inherit it automatically with zero duplicated logic (verified by test #12, the
  thumbnail corollary).
- Did not touch `media_state_transitions`, `Nebu.Media.StateMachine`, upload/preview_url/SSRF/
  Range-request logic, or Content-Disposition/CSP header logic, per Dev Agent Guardrails. Did not
  add the `/_matrix/client/v1/media/download/...` route.

### Correction (2026-07-19, Kassandra security-review during Story 6a)

The `:admin_blocked` → `{451, "M_NOT_FOUND"}` mapping documented above (and originally matching
ADR-026's own table) was **wrong** and has been fixed to `{404, "M_NOT_FOUND"}` — byte-identical
status AND body to `:infected`/`:deleted`/`:hard_deleted`/a genuine unknown-`media_id`. The
`(451, M_NOT_FOUND)` pairing was unique to `:admin_blocked` (no other state produces it), so the
bare HTTP status line — without even reading the response body — was a perfect oracle for "an
admin blocked this file," defeating AC2's own anonymity goal. This was flagged as a dormant,
"becomes live once the mutation path ships" watch-flag in Kassandra's own 1c review and caught for
real during Story 6a's security review (the first story to actually drive a file into
`:admin_blocked` via a real admin action). See ADR-026's 2026-07-19 correction and
`Nebu.Media`'s `download_gate(:admin_blocked)` comment for the full reasoning. `gate_message/1`
and every other branch are unchanged.
- No deviations from the story's Technical Requirements — implementation follows the
  illustrative code shape directly (restructuring was not needed).

### Review Cycle 1 (fix cycle, code-review findings)

- **MAJOR-1 fixed:** `server/lib/nebu/media/db.ex`'s `to_map/1` now converts the raw `media_state`
  column via a new private `parse_state/1` helper instead of calling `String.to_existing_atom/1`
  inline. `parse_state/1` rescues `ArgumentError` (raised when the raw DB string was never interned
  as an Elixir atom, e.g. a future ENUM value like Story 4a's `:scan_failed` before its own code
  lands) and falls back to a sentinel atom (`:__unrecognized_media_state__`) that no
  `download_gate/1` clause explicitly matches — so the row still reaches the handler-level gate and
  is denied via the existing catch-all, instead of crashing to an uncaught 500.
- **Conflict noted and resolved:** the review finding's suggested fix text said to convert the
  rescued error to `{:error, :not_found}` (yielding a 404 from `with_authorised_media/4`'s existing
  not-found branch). That contradicts AC6's literal text ("falls through to the AC1 response — 451
  `M_NOT_YET_UPLOADED`") and ADR-026's status table (which classifies `:scan_failed` — the concrete
  motivating example for this exact bug class — as 451, not 404). It also would have failed the
  MINOR-2 companion test, whose own spec explicitly asserts 451. Resolved in favor of AC6/ADR-026:
  the sentinel-atom approach makes an unrecognized raw state fail closed as 451
  `M_NOT_YET_UPLOADED` (never 200, never 500), matching the story's actual acceptance criterion
  instead of the review comment's literal (and, on inspection, AC6-inconsistent) suggestion.
- **MINOR-2 fixed:** added
  `server/test/nebu/media/media_download_gate_db_integration_test.exs`, a new `@moduletag
  :integration` test (mirrors `media_files_state_backfill_test.exs`'s live-Postgres, no-Sandbox
  convention — required because `Nebu.Media.DB.to_map/1` is private and unreachable from a unit
  test without a live DB connection). It grows the `media_state` ENUM at runtime via `ALTER TYPE
  media_state ADD VALUE IF NOT EXISTS` (the same mechanism Story 4a will use for `:scan_failed`),
  inserts a real row with that never-before-seen state string, drives it through the real
  `Nebu.Media.DB.lookup/2` via the full download route, and asserts 451 `M_NOT_YET_UPLOADED` — never
  200, never an uncaught crash. Excluded from the default fast unit run (`mix test` /
  `mix test --warnings-as-errors`), runs only under `mix test --include integration` /
  `make test-integration`, consistent with sibling DB-dependent tests in this directory.
- **MINOR-3 fixed:** corrected the comment above `state: parse_state(state)` in `to_map/1` (and the
  new `parse_state/1` helper's comment) to attribute atom-safety to both `Nebu.Media.download_gate/1`
  (the 5 states it names as literals: `:released`, `:admin_blocked`, `:infected`, `:deleted`,
  `:hard_deleted`) and `Nebu.Media.StateMachine` (the other 3: `:reserved`, `:quarantined`,
  `:scanning`), not `download_gate/1` alone.
- **MINOR-4 left untouched** as instructed — the legacy `deleted` boolean column remains an
  unfiltered, unsynchronized dead read alongside `state`; no reconciliation attempted in this cycle.

### Review Cycle 2 (fix cycle, code-review findings)

- **MINOR-A fixed:** `server/test/nebu/media/media_download_gate_db_integration_test.exs`'s `setup`
  block sets four `:nebu_http` application-env keys (`:media_storage_module`,
  `:media_membership_module`, `:media_member_fun`, `:media_storage_get_fun`), but the matching
  `on_exit` teardown loop only listed the first three, leaking `:media_storage_get_fun` (the AC7
  flunking fake) across tests. Added `:media_storage_get_fun` to the `on_exit`'s `for k <- [...]`
  teardown list, mirroring the symmetric setup/on_exit convention already followed by the sibling
  unit test `media_download_gate_test.exs`.

### Review Cycle 3 (fix cycle, CI-gate failure)

- **CI-gate failure fixed:** `server/test/nebu/media/media_download_gate_db_integration_test.exs`
  (added in review cycle 1) failed in CI with `** (Postgrex.Error) ERROR 42501 (insufficient_privilege)
  must be owner of type media_state — code: grow_enum!()`. Root cause: the test-integration harness
  connects as the `nebu_app` Postgres role, which is deliberately DDL-restricted (least-privilege role
  architecture, Story 5.29a/AC3 — "the server also uses nebu_app at runtime, no DDL from the server").
  Only `nebu_migrate` owns the `media_state` type, so the test's `ALTER TYPE media_state ADD VALUE IF
  NOT EXISTS` call was rejected. This is a real, permanent security boundary, not a bug to work around.
- **Fix:** deleted `media_download_gate_db_integration_test.exs` entirely (no migrate-role DDL access
  was added to the test harness, the production ENUM was not grown early, and the test was not given
  elevated DB privileges) and replaced its coverage with two new DDL-free, DB-free unit tests appended
  to `media_download_gate_test.exs` that call the real `Nebu.Media.DB.parse_state/1` directly with a
  synthetic string built from `System.unique_integer([:positive])` — guaranteed to have never been
  interned as an Elixir atom anywhere in the running VM — asserting it does not raise and returns the
  sentinel `:__unrecognized_media_state__`, plus a companion assertion that already-known state strings
  still convert normally. This proves the exact same bug class (an unrecognized-atom `ArgumentError`
  inside `String.to_existing_atom/1` being rescued instead of crashing) without a Postgres connection.
- **Visibility fix required:** `parse_state/1` was `defp` (private), and BEAM does not export private
  functions from a compiled `.beam` file at all, so it could not be called from a test module as
  written. Checked this codebase's own conventions first (`grep -rn "@doc false" lib/`) and found an
  established pattern: `Nebu.Health.overall_status/1` (`server/lib/nebu/health/health.ex`) is `def` +
  `@doc false` specifically so `test/nebu/health_test.exs` can call it directly while signaling it is
  not part of the module's real public API. Followed that exact pattern: changed `parse_state/1` from
  `defp` to `def`, tagged `@doc false`, with a comment pointing at the `Nebu.Health.overall_status/1`
  precedent and instructing callers to go through `lookup/2` instead. No `Mix.env()`-conditional
  compilation was introduced (no such pattern exists elsewhere in this codebase, and the story
  explicitly asked to avoid inventing one).
- **Unplanned but necessary follow-on fix:** calling `Nebu.Media.DB.parse_state/1` directly from a test
  is the first place in the whole suite that references the real `Nebu.Media.DB` module by name outside
  of the `Nebu.Media` router/plug path. This exposed a latent, pre-existing test-isolation gap in
  `server/test/nebu/media/media_upload_test.exs`: unlike every sibling `media_*_test.exs` file, its
  `setup` never pinned `:media_db_module` to `MediaFakes.DB`. `Nebu.Media.store_upload/4`'s
  `insert_media_row/7` guards the real DB write with `function_exported?(mod, :insert, 1)` so it can
  no-op when the fake (which has no `insert/1`) is installed — but `function_exported?/3` only reports
  `true` once a module has actually been *loaded* into the VM, and reports `false` for an unloaded
  module even if it would export that function once loaded. So `media_upload_test.exs`'s "authenticated
  PUT upload" test was silently relying on the real `Nebu.Media.DB` module never having been loaded yet
  in that VM run (an accident of test ordering, not a guarantee) to make the write a no-op. The moment
  any test in the suite loads the real module — which the new `parse_state/1` unit tests now do, by
  design, since the story requires calling the real function directly — `function_exported?` starts
  returning `true` for every subsequent test in that run, so `insert_media_row/7` attempts the real SQL
  insert against `Nebu.Repo`, which is intentionally not started in a plain `mix test` run (no
  `NEBU_DB_URL`, per `lib/nebu/application.ex`'s "start the Repo only when its config is present"
  comment) — producing a `could not lookup Ecto repo Nebu.Repo` crash. This was verified to be
  genuinely order-dependent (not a regression in `download_gate`/`parse_state` logic itself): with the
  two new tests removed, `mix test --warnings-as-errors` passed cleanly (1627 passed, 0 failures) across
  several seeds; with them present, the exact same single test failed deterministically across every
  seed tried, regardless of which file the two new tests lived in (a standalone new module or appended
  to the existing gate test file both triggered it, confirming module *loading*, not module *identity*,
  was the trigger). Fixed by pinning `media_upload_test.exs`'s `setup` to
  `Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)` with matching `on_exit` cleanup —
  mirroring the exact convention already used by every other `media_*_test.exs` setup block — so the
  test no longer depends on incidental module-load ordering elsewhere in the suite.
- Re-verified `server/lib/nebu/media.ex` and `server/lib/nebu/media/db.ex` needed no further production
  changes beyond the `parse_state/1` visibility change; `download_gate/1`'s AC1–AC7 behavior (verified
  in review cycles 1–2) is untouched.

### Test Results

- `mix test test/nebu/media/media_download_gate_test.exs` — 13 passed (0 failures).
- `mix test test/nebu/media/` — 68 passed, 25 excluded (integration), 0 failures.
- `mix test --warnings-as-errors` (full unit suite, excludes `:integration`) — 1627 passed, 2
  skipped, 448 excluded, exit code 0 (no compiler warnings).
- `mix compile --warnings-as-errors --force` — clean (`mix compile: ok`).

**Review cycle 1 (post-fix) re-verification:**

- `mix test test/nebu/media/media_download_gate_test.exs` — 13 passed (0 failures), no
  `ArgumentError` crashes.
- `mix test test/nebu/media/` — 68 passed, 26 excluded (integration; +1 for the new
  `media_download_gate_db_integration_test.exs`), 0 failures.
- `mix test --warnings-as-errors` (full unit suite) — 1627 passed, 2 skipped, 449 excluded, exit
  code 0 confirmed explicitly (no compiler warnings, no regressions).
- `mix compile --warnings-as-errors --force` — clean, exit code 0.
- `mix test test/nebu/media/media_download_gate_db_integration_test.exs --include integration` —
  run without a live Postgres available in this environment: fails fast with the same explicit
  guard message used by `media_files_state_backfill_test.exs` ("Nebu.Repo is not started — run with
  a live PostgreSQL ... `make test-integration`"), confirming the test is well-formed and gated
  correctly rather than silently skipped or crashing. Not executed against a live DB in this cycle;
  recommend running via `make test-integration` before merge to confirm the `ALTER TYPE ... ADD
  VALUE` + real-row path behaves as asserted.

**Review cycle 2 (post-fix) re-verification:**

- `mix test test/nebu/media/media_download_gate_test.exs` — 13 passed (0 failures).
- `mix test test/nebu/media/` — 68 passed, 26 excluded (integration), 0 failures.
- `mix compile --warnings-as-errors --force` — clean, exit code 0 (`mix compile: ok`).
- `mix test --include integration --exclude nonexistent_tag test/nebu/media/media_download_gate_db_integration_test.exs`
  — no live Postgres available in this environment: fails at the same explicit `Nebu.Repo is not
  started` flunk guard as review cycle 1, confirming the file still compiles/parses and the setup
  block runs far enough to hit the guard after the teardown-list edit. Not executed against a live
  DB in this cycle.

**Review cycle 3 (post-fix) re-verification:**

- `mix test test/nebu/media/` — 70 passed, 25 excluded (integration; -1 vs. review cycle 2 since
  `media_download_gate_db_integration_test.exs` is deleted), 0 failures — confirmed stable across 5
  fixed seeds (1-5) plus the default random seed.
- `mix test --warnings-as-errors` (full unit suite) — 1629 passed, 2 skipped, 448 excluded, exit code
  0 — confirmed stable across seeds 1, 2, 3, and the default random seed (no compiler warnings, no
  regressions).
- `mix compile --warnings-as-errors --force` — clean, exit code 0 (`mix compile: ok`).
- Confirmed via `ls`/`git status` that `media_download_gate_db_integration_test.exs` no longer exists
  anywhere in the working tree.

### File List

- `server/lib/nebu/media.ex` — UPDATE: added `download_gate/1` + `gate_message/1` and wired them
  into `with_authorised_media/4` before the membership check and `fetch_and_decrypt/3`.
- `server/lib/nebu/media/db.ex` — UPDATE: added `state` to `@sql_lookup` SELECT list, dropped
  `AND deleted = false` from WHERE, extended `to_map/1` to parse `state` via
  `String.to_existing_atom/1`, updated moduledoc.
- `server/test/nebu/media/media_download_gate_test.exs` — NEW (pre-staged by ATDD): 13 tests,
  all passing after implementation.
- `server/test/nebu/media/media_test_support.exs` — UPDATE (pre-staged by ATDD): `media_row/1`
  gained a `:state` option, default `:released`.
- `server/lib/nebu/media/db.ex` — UPDATE (review cycle 1): `to_map/1`'s inline
  `String.to_existing_atom/1` call replaced with a new `parse_state/1` private helper that rescues
  `ArgumentError` and falls back to a sentinel atom (MAJOR-1 fix); corrected comment attribution
  (MINOR-3 fix).
- `server/test/nebu/media/media_download_gate_db_integration_test.exs` — NEW (review cycle 1,
  MINOR-2 fix): `@moduletag :integration` test driving a raw never-seen `media_state` string
  through the real `Nebu.Media.DB.lookup/2` via the full download route.
- `server/test/nebu/media/media_download_gate_db_integration_test.exs` — UPDATE (review cycle 2,
  MINOR-A fix): added `:media_storage_get_fun` to the `setup` block's `on_exit` teardown loop so
  all four `:nebu_http` app-env keys set in `setup` are symmetrically torn down.
- `server/test/nebu/media/media_download_gate_db_integration_test.exs` — DELETED (review cycle 3,
  CI-gate fix): required Postgres DDL privileges (`ALTER TYPE ... ADD VALUE`) the test-integration
  harness's `nebu_app` role deliberately does not have; failing in CI with `insufficient_privilege`.
- `server/lib/nebu/media/db.ex` — UPDATE (review cycle 3): changed `parse_state/1` from `defp` to
  `def` + `@doc false` (established codebase convention, mirrors `Nebu.Health.overall_status/1`) so
  it can be called directly by a DB-free unit test; no behavior change.
- `server/test/nebu/media/media_download_gate_test.exs` — UPDATE (review cycle 3): appended two new
  unit tests calling `Nebu.Media.DB.parse_state/1` directly with a synthetic never-interned string,
  replacing the deleted DB-integration test's coverage without any live Postgres connection.
- `server/test/nebu/media/media_upload_test.exs` — UPDATE (review cycle 3, unplanned follow-on fix):
  pinned `:media_db_module` to `MediaFakes.DB` in `setup` (with matching `on_exit` cleanup), mirroring
  every sibling `media_*_test.exs` file's convention. Fixes a latent test-isolation gap exposed by the
  new `parse_state/1` unit tests being the first test code to load the real `Nebu.Media.DB` module —
  see Completion Notes → Review Cycle 3 for the full mechanism.

### Change Log

- 2026-07-13: Implemented AC1–AC7 download-gate enforcement in `Nebu.Media.with_authorised_media/4`
  and the supporting `Nebu.Media.DB.lookup/2` schema read; all 13 ATDD tests green, no regressions
  in the full unit suite, `mix compile --warnings-as-errors` clean. Status → review.
- 2026-07-13 (review cycle 1): Fixed MAJOR-1 (`String.to_existing_atom/1` uncaught `ArgumentError` on
  an unrecognized raw `media_state` value), MINOR-2 (added a DB-integration test exercising the real
  conversion path), and MINOR-3 (corrected comment attribution). MINOR-4 left untouched per reviewer
  guidance (accepted epic-level follow-up). See Completion Notes below for the resolution of a
  conflict between MAJOR-1's suggested fix (convert to `{:error, :not_found}` → 404) and AC6/ADR-026's
  requirement that unrecognized states return 451 `M_NOT_YET_UPLOADED` — resolved in favor of AC6.
- 2026-07-13 (review cycle 2): Fixed MINOR-A — `media_download_gate_db_integration_test.exs`'s
  `on_exit` teardown loop was missing `:media_storage_get_fun`, leaking that app-env key across
  tests. Added it to the teardown list; no regressions in `media_download_gate_test.exs` (13/13),
  the full `test/nebu/media/` suite (68 passed, 26 excluded), or `mix compile --warnings-as-errors`.
- 2026-07-13 (review cycle 3): Fixed a CI-gate failure — deleted
  `media_download_gate_db_integration_test.exs` (required Postgres DDL privileges the
  test-integration harness's `nebu_app` role deliberately lacks) and replaced its coverage with two
  DDL-free, DB-free unit tests appended to `media_download_gate_test.exs` that call
  `Nebu.Media.DB.parse_state/1` directly with a synthetic never-interned string. Changed
  `parse_state/1` from `defp` to `def` + `@doc false` (established codebase convention, mirrors
  `Nebu.Health.overall_status/1`) to make it directly testable. Also fixed an unplanned but necessary
  latent test-isolation gap in `media_upload_test.exs` (pinned `:media_db_module` to the fake,
  mirroring every sibling test file), exposed by the new tests being the first to load the real
  `Nebu.Media.DB` module in a plain unit run — see Completion Notes for the full mechanism. No
  regressions: `mix test test/nebu/media/` (70 passed, 25 excluded), `mix test --warnings-as-errors`
  (1629 passed, 2 skipped, 448 excluded), `mix compile --warnings-as-errors --force` clean — all
  confirmed stable across multiple seeds.
