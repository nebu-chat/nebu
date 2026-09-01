---
story_id: 11c-s3-key-prefix-template
title: "Object Storage Target Configuration: s3_key_prefix_template Upload-Time Key Computation"
epic: media-security-admin-control
status: done
security_review: optional
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 11a persists an admin-configurable `s3_key_prefix_template` string in
`media_storage_config` but deliberately does not interpret it — it is stored as an
opaque `TEXT` column. This story builds the other half: a small template-interpolation
function that turns that string into an actual S3 object key, and wires it into Story
2b's upload pipeline at the one point where a key is needed — immediately before the
`Storage.put/2` write.

The single invariant that makes this story worth its own slice, and that every AC below
exists to protect, is: **the key is computed exactly once, at upload time, from
whichever template is active in that instant, and is then persisted permanently in
`media_files.storage_key`.** It is never recomputed on read, never recomputed on
download, never recomputed by a background job. Once `storage_key` is written, the
template that produced it is irrelevant history — an admin can change
`s3_key_prefix_template` five minutes or five years later and it will have **zero**
effect on that row. This is what ADR-029 calls out explicitly ("existing objects remain
findable under their original key") and what Story 1a's `storage_key` column comment
already promises ("persistiert den zur Upload-Zeit aus dem Key-Template berechneten
Wert ... damit spätere Template-Änderungen bestehende Objekte nicht unauffindbar
machen"). A template engine that silently recomputed keys on demand would be actively
dangerous here — it would orphan every previously-uploaded object the moment an admin
edited the template. This story's design deliberately trades "templates are always
in sync with reality" for "uploaded objects are never orphaned," and every AC is a
consequence of that trade.

## User Story

As the Nebu server operator, I want to define an S3 object-key naming scheme (e.g.
`{year}/{month}/{server_name}/{media_id}`) via the admin-configured
`s3_key_prefix_template`, so that my bucket layout matches my own archival/organizational
conventions, while every file already uploaded keeps working under the key it was given
at upload time even after I later change the template.

## Acceptance Criteria

1. **AC1 — Config source is `media_storage_config` (Story 11a), read via
   `Nebu.Media.StorageConfig.get/0`.** `s3_key_prefix_template` is **not** a
   `Nebu.Media.Config`/`media_config` (Story 9a) key — Story 11a's schema already
   defines the column on `media_storage_config` and explicitly assigns its
   interpretation to this story ("Story 9a's Field-Katalog" is a different table
   entirely; see 11a AC2: "`s3_key_prefix_template` (consumed by Story 11c; this story
   only persists it, does not interpret placeholders)"). This story reads the template
   string via `Nebu.Media.StorageConfig.get/0` (not `get_for_connection/0` — the
   template is not a secret) and does not introduce a second config path.
2. **AC2 — Exact supported placeholder set.** The template engine recognizes exactly
   these placeholders, per ADR-029 and the epic's Story 11c scope text:
   - `{media_id}` — **mandatory**: the template MUST contain this placeholder (see AC6
     for why). Substituted with the media id being uploaded.
   - `{year}` — 4-digit UTC upload year (e.g. `2026`).
   - `{month}` — 2-digit, zero-padded UTC upload month (`01`–`12`).
   - `{day}` — 2-digit, zero-padded UTC upload day (`01`–`31`).
   - `{server_name}` — the Matrix server name component of the MXC URI being uploaded
     to (available on the `media_files` row from Story 2a's `/create`).

   **Deliberately no `{room_id}`** — `media_files` has no `room_id` column (ADR-028's
   reserved query-time join is the only place a room association exists), so no
   placeholder can reference it. Any other `{...}`-shaped token that is not in this set
   is a validation error (AC5), not silently left as literal text or silently dropped.
3. **AC3 — Key computed exactly ONCE, at upload time, in Story 2b's pipeline.** The key
   is computed inside the shared `store_and_quarantine/...` persist-transition-enqueue
   seam (Story 2b), specifically **before** `Storage.put/2` — the computed key **is**
   the S3 write target, not a value derived after the fact. It is computed from
   `Nebu.Media.StorageConfig.get/0`'s `s3_key_prefix_template` value **as read at that
   moment**. No other code path (download, admin overview, archive worker, health
   dashboard) ever calls the template-interpolation function — every other consumer
   reads the already-persisted `media_files.storage_key` column.
4. **AC4 — Non-regression: changing the template after upload has ZERO effect on
   already-uploaded files.** This is the load-bearing AC of this entire story. Once
   `media_files.storage_key` is persisted for a row (Story 2b AC8, after the S3 write
   succeeds), no later `upsert/1` call to `Nebu.Media.StorageConfig` changing
   `s3_key_prefix_template` triggers, schedules, or implies any recomputation of that
   row's `storage_key`. The file remains downloadable at its original S3 key
   indefinitely, under any subsequent template value, including a template that would
   no longer even be syntactically valid under AC5's rules if re-validated (irrelevant
   — the old key is never re-evaluated against the new template).
5. **AC5 — Invalid/malformed templates are rejected at config-save time, not upload
   time.** `Nebu.Media.StorageConfig.upsert/1` validates any `s3_key_prefix_template`
   value present in its input map **before** persisting it, and returns
   `{:error, :invalid_key_prefix_template}` (or equivalent tagged error) without writing
   the row if validation fails. Validation rejects:
   - A template missing the mandatory `{media_id}` placeholder (AC2).
   - A template containing an unrecognized `{...}` token (anything not in AC2's set —
     e.g. `{room_id}`, `{uploader_id}`, a typo like `{yeat}`).
   - A template containing unbalanced/unparseable brace syntax (e.g. a lone `{` or `}`
     not part of a recognized placeholder).
   - A template that would produce a path escaping the intended key namespace (leading
     `/`, `..` path segments, or a literal double-slash from adjacent
     placeholder/literal text) — S3 keys are flat strings but a key containing `../`-like
     segments is still a hygiene defect worth rejecting outright rather than storing
     objects at attacker- or admin-typo-controlled surprising locations.

   An upload is never the place a malformed template is first discovered — by the time
   any upload runs, `s3_key_prefix_template` has already been validated at save time,
   so template interpolation at upload time is infallible for any value that ever made
   it into `media_storage_config`.
6. **AC6 — Collision-resistant key generation.** No two uploads ever produce the same
   S3 key, even with an identical template and identical upload timestamp (down to the
   same second), because AC2's mandatory `{media_id}` placeholder is itself guaranteed
   unique per upload — `media_id` is generated once per `/create` call (Story 2a) using
   the server's existing globally-unique media-id generation, and two concurrent
   uploads always get two distinct `media_id` values regardless of how coarse
   `{year}`/`{month}`/`{day}` are. This is precisely *why* `{media_id}` is mandatory
   (AC2) rather than merely recommended: a template built only from `{year}/{month}/
   {day}/{server_name}` with no `{media_id}` would let two same-day uploads to the same
   server collide on to the exact same key, silently overwriting one file's ciphertext
   with another's. AC5's validation is the enforcement mechanism for this guarantee —
   it is not merely a syntax nicety, it is what makes AC6 true by construction rather
   than by accident.

## Acceptance Tests

New test file `server/test/nebu/media/key_prefix_template_test.exs` (ExUnit, pure
function tests, no DB/S3 required for the interpolation logic itself):

1. `"interpolates a template using all five supported placeholders into the expected
   key"` — template `"{year}/{month}/{day}/{server_name}/{media_id}"` with a fixed
   `DateTime` and fixed `media_id`/`server_name` produces the exact expected string
   (e.g. `"2026/07/12/nebu.example.com/abc123"`), asserting zero-padding on
   `{month}`/`{day}` for single-digit values.
2. `"a template using only a subset of placeholders (e.g. just {media_id}) is valid and
   interpolates correctly"` — covers the Story 11a default `"{media_id}"` (flat-key
   backward-compatible default) still working after this story lands.
3. `"a template missing {media_id} is rejected at validation time"` — e.g.
   `"{year}/{month}/{server_name}"` returns `{:error, :invalid_key_prefix_template}`
   (or equivalent) from the validation function, never reaching interpolation.
4. `"a template containing an unrecognized placeholder is rejected"` — parameterized
   over `{room_id}`, `{uploader_id}`, `{yeat}` (typo), each rejected at validation time.
5. `"a template with unbalanced braces is rejected"` — e.g. `"{media_id"` or
   `"media_id}"`.
6. `"a template containing a path-escaping segment is rejected"` — e.g.
   `"../{media_id}"` or a template producing a literal `//` from adjacent
   separators.
7. **Config-save-time enforcement:** `"Nebu.Media.StorageConfig.upsert/1 with an
   invalid s3_key_prefix_template returns an error and does not persist the row"` —
   integration test against the Story 11a module: attempt to save
   `%{s3_key_prefix_template: "{room_id}/{media_id}"}`, assert `{:error, _}` is returned
   and a subsequent `get/0` still reflects the previously-saved (or default) template,
   not the rejected one.
8. **Upload-time computation, real pipeline:** `"a PUT upload with an active
   s3_key_prefix_template computes storage_key from that template and persists it"` —
   extends Story 2b's `media_async_upload_test.exs`-style fixture: seed
   `media_storage_config` (or its fake) with a non-default template, PUT an upload,
   assert the persisted `media_files.storage_key` matches the expected interpolated
   value (not the flat `media_id` fallback).
9. **Non-regression — the whole point of this story:** `"changing
   s3_key_prefix_template AFTER a file has already been uploaded does not alter that
   file's already-persisted storage_key, and the file remains downloadable"` —
   (a) set template A, upload a file, capture its `storage_key`; (b) call `upsert/1`
   to change to template B; (c) re-`SELECT`/re-`lookup/2` the same `media_id`'s row and
   assert `storage_key` is byte-identical to the value captured in (a); (d) assert a
   download of that media id still succeeds (state `:released` after a fake scan, or
   at minimum that the storage-fake is still asked for the original key, not a
   recomputed one).
10. **Uniqueness/collision test:** `"two uploads in the same second, same
    server_name, with a {year}/{month}/{day}/{server_name}/{media_id} template produce
    two distinct storage_keys"` — freezes the clock (or injects an identical
    `DateTime`) for two separate `media_id` values and asserts the two computed keys
    differ (proof that `{media_id}`'s uniqueness, not timestamp granularity, is what
    prevents collision).
11. `"the Story 11a default template {media_id} alone is accepted by validation"` —
    guards against a regression where AC5's rules would reject the very default 11a
    ships.

## Technical Requirements

### Template-interpolation module

New function(s) in `Nebu.Media.StorageConfig` (Story 11a's module — the natural owner
of everything related to `s3_key_prefix_template`, since it already owns reading and
persisting that string) or a small sibling module
`Nebu.Media.StorageConfig.KeyTemplate` if the interpolation/validation logic is large
enough to warrant its own file (dev-agent's call, per S-sizing — keep it a single
module, no separate GenServer, no new table):

```elixir
@placeholders ~w({media_id} {year} {month} {day} {server_name})

@spec validate_template(String.t()) :: :ok | {:error, :invalid_key_prefix_template}
def validate_template(template) do
  # 1. reject unbalanced braces
  # 2. extract all {...} tokens, reject any not in @placeholders
  # 3. require "{media_id}" to be present
  # 4. reject path-escaping segments ("..", leading "/", literal "//")
end

@spec compute_key(String.t(), map()) :: String.t()
def compute_key(template, %{media_id: media_id, server_name: server_name, uploaded_at: %DateTime{} = dt}) do
  template
  |> String.replace("{media_id}", media_id)
  |> String.replace("{server_name}", server_name)
  |> String.replace("{year}", Calendar.strftime(dt, "%Y"))
  |> String.replace("{month}", Calendar.strftime(dt, "%m"))
  |> String.replace("{day}", Calendar.strftime(dt, "%d"))
end
```

`validate_template/1` is called from `Nebu.Media.StorageConfig.upsert/1` (Story 11a)
whenever `fields` contains `:s3_key_prefix_template` — reusing 11a's existing partial-
update `upsert/1` entry point rather than adding a second write path (ADR-020's "one
public API module" spirit applied at the function level too).

`compute_key/2` is called from **exactly one** call site: Story 2b's
`store_and_quarantine/...` seam, immediately before `storage_module().put(storage_key,
ciphertext)` — replacing that story's placeholder "flat `media_id` fallback until 11c
lands" comment with a real call:

```elixir
template = Nebu.Media.StorageConfig.get().s3_key_prefix_template
storage_key = Nebu.Media.StorageConfig.compute_key(template, %{
  media_id: media_id,
  server_name: server_name,
  uploaded_at: DateTime.utc_now()
})
:ok = storage_module().put(storage_key, ciphertext)
# only now: persist storage_key + transition state (Story 2b AC8/AC9, ADR-032 ordering)
```

This story does **not** re-open or change Story 2b's ordering guarantees (S3-write-
before-Postgres-write, ADR-032) — it only fills in the one line Story 2b left as a
named placeholder for it (`Storage key computed from the currently-active key
template — Story 11c dependency`).

### Validation rules detail

- Brace-balance check: simplest correct implementation is counting `{`/`}` and
  confirming every `{` is closed by a `}` before the next `{` (no nesting is ever
  valid — none of the 5 placeholders nest).
- Placeholder-token check: `Regex.scan(~r/\{[^{}]*\}/, template)` extracts every
  `{...}` span; each must be an exact member of `@placeholders`.
- `{media_id}` presence: `String.contains?(template, "{media_id}")`.
- Path-escaping check: after stripping placeholder tokens, reject if the remaining
  literal skeleton contains `".."`, starts with `"/"`, or contains `"//"`.

### Timestamp source

`uploaded_at` for `{year}`/`{month}`/`{day}` is the upload instant (`DateTime.utc_now()`
captured once when `compute_key/2` runs inside `store_and_quarantine/...`, in UTC per
ADR-029) — not the `/create` reservation time (Story 2a), since the epic and ADR-029
both describe this as the upload-time key, and a reservation can sit unused for up to
`unused_expires_at` (default 24h) before the PUT actually lands.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/media/storage_config.ex` | UPDATE | Add `validate_template/1` and `compute_key/2`; call `validate_template/1` from `upsert/1` when `s3_key_prefix_template` is present in the input map |
| `server/lib/nebu/media.ex` | UPDATE | In the `store_and_quarantine/...` seam (Story 2b), replace the flat `media_id`-fallback storage-key computation with a call to `Nebu.Media.StorageConfig.compute_key/2`, reading the template via `Nebu.Media.StorageConfig.get/0` |
| `server/test/nebu/media/key_prefix_template_test.exs` | CREATE | Acceptance Tests 1–6, 10–11 (pure interpolation/validation tests) |
| `server/test/nebu/media/storage_config_test.exs` | UPDATE | Add Acceptance Test 7 (`upsert/1` rejects an invalid template) alongside Story 11a's existing test cases |
| `server/test/nebu/media/media_async_upload_test.exs` | UPDATE | Add Acceptance Tests 8–9 (upload-time computation + the non-regression test) to Story 2b's existing suite |

## Dev Agent Guardrails

### Do Not Change

- **Never recompute `storage_key` for an existing row when the template changes.**
  There is no code path — no migration, no background job, no admin action, no cache
  invalidation handler in `Nebu.Media.StorageConfig`'s `:pg`-broadcast/TTL-refresh
  logic (Story 11a AC7) — that re-derives or overwrites an already-set
  `media_files.storage_key`. `storage_key` is a **write-once** value per file, set only
  in Story 2b's upload pipeline at the moment of the S3 write. If a future story needs
  a "re-key existing objects to match a new template" migration tool, that is an
  explicit, separately-designed, opt-in bulk operation — not something this story or
  any part of `Nebu.Media.StorageConfig`'s config-change plumbing does implicitly.
- Do not call `compute_key/2` from anywhere other than Story 2b's upload seam. The
  download handler (Story 1c), the admin overview (Story 5a/6b), the archive worker
  (Story 8c), and the health dashboard (Story 10) all read the already-persisted
  `storage_key` column — none of them ever re-derive a key from the current template.
- Do not add `{room_id}` (`media_files` has no such column — see ADR-029/ADR-028) or
  any placeholder beyond the exact 5 in AC2. If a future story needs a new placeholder,
  it updates this story's `@placeholders` list and validation rules explicitly; do not
  silently pass through unrecognized `{...}` tokens as literal text — AC5 requires
  rejection at save time, not graceful degradation.
- Do not move `s3_key_prefix_template` reading/writing off `Nebu.Media.StorageConfig`
  into `Nebu.Media.Config`/`media_config` (Story 9a) — Story 11a already decided the
  table split; this story only adds interpretation on top of 11a's existing column.
- Do not validate the template at upload time "just in case" — AC5's entire purpose is
  that invalid templates never reach `media_storage_config` in the first place, so
  `compute_key/2` itself does not need (and should not add) its own defensive
  re-validation branch that could itself diverge from `validate_template/1`'s rules.
- Do not change Story 2b's ADR-032 write-ordering (S3 write must succeed before
  `storage_key`/state are persisted in Postgres) — this story only supplies the value
  that goes into that already-decided sequence, not a new sequence.
- `server/lib/`, `server/test/`, `server/priv/migrations/` are pipeline-protected per
  `CLAUDE.md`; do not hand-apply these changes outside an active `nebu-pipeline` run.

## Dependencies

- **Depends on:**
  - **11a** (`media_storage_config` schema + `Nebu.Media.StorageConfig` module) — the
    config source for `s3_key_prefix_template` (via `get/0`) and the module this story
    extends with `validate_template/1`/`compute_key/2`. This is the explicit config
    source per the epic ("11a, 2b" in the dependency list) — not `9a`/`media_config`.
  - **2b** (`PUT` async upload) — the integration point: this story fills in the named
    placeholder in 2b's `store_and_quarantine/...` seam where the storage key is
    computed, immediately before `Storage.put/2`.
  - Loosely, **9a** (`media_config`/`Nebu.Media.Config`) only in the sense that both
    stories establish the "admin-configurable value, cache-backed, audit-logged"
    pattern this epic reuses everywhere — no code or table dependency.
- **Enables:**
  - **2c** (synchronous upload over the shared pipeline) — inherits real key
    computation for free once 2c calls the same `store_and_quarantine/...` seam.
  - **11b** (Storage-UI) — the settings form can now surface `validate_template/1`'s
    rejection as an inline form error instead of accepting any string.

## Dev Agent Record

### Cycle 0 (initial implementation, scope-adapted per the ATDD file's own note)

- **Story 2b (`Nebu.Media.upload_async/3`, the `store_and_quarantine/...` seam)
  confirmed absent on this branch** — `server/lib/nebu/media.ex` currently only
  has the old, deprecated `Nebu.Media.upload/1` v3 handler, whose
  `store_upload/4` hardcodes `storage_key = media_id` (around line 195) with no
  `store_and_quarantine` seam, no `/create`+`PUT` async flow, and no
  `media_async_upload_test.exs` fixture to extend. This is the exact same
  situation story `9c-mime-denylist-enforcement` was in against the same
  missing dependency (see that story's own Dev Agent Record). Per this
  story's ATDD file's own "Scope adaptation" note
  (`server/test/nebu/media/key_prefix_template_test.exs`), this cycle
  implements `validate_template/1` and `compute_key/2` as standalone,
  public, **unwired** functions on `Nebu.Media.StorageConfig` — `server/lib/nebu/media.ex`
  and `server/test/nebu/media/media_async_upload_test.exs` were **not**
  touched (both listed in this story's planning-time File List above, but
  neither has a real call site yet).
- **What was added** (`server/lib/nebu/media/storage_config.ex`):
  - `@placeholders ~w({media_id} {year} {month} {day} {server_name})` module
    attribute — the exact 5-item AC2 set.
  - `validate_template/1` (public): rejects unbalanced/unparseable brace
    syntax (single-pass depth counter, no nesting ever valid), any `{...}`
    token not in `@placeholders`, a template missing `{media_id}`, and a
    path-escaping literal skeleton (`..`, leading `/`, literal `//`, checked
    AFTER stripping recognized placeholder tokens so literal-only content is
    what's inspected).
  - `compute_key/2` (public): pure `String.replace/3` chain per placeholder,
    `{year}`/`{month}`/`{day}` via `Calendar.strftime(dt, "%Y"/"%m"/"%d")`
    (zero-padded). Does **not** re-validate `template` — AC5/Dev Agent
    Guardrails are explicit that validation runs exactly once, at
    `upsert/1` time.
  - `upsert/1` now runs `validate_template_field/1` (new private helper)
    inside a `with` as its first step: if `fields` contains
    `:s3_key_prefix_template`, calls `validate_template/1` on it and returns
    `{:error, :invalid_key_prefix_template}` **before** `build_columns/1`/the
    writer callback ever runs (no partial write, no audit-log entry for a
    rejected attempt). Absent key ⇒ `:ok`, unchanged partial-update semantics
    for every other field.
- **No second, diverging validation branch was added to `compute_key/2`**,
  per the Dev Agent Guardrails' explicit prohibition.
- **No `{room_id}` or any 6th placeholder was added.**
- **No migration was created** — this story only adds functions to an
  existing module; the `media_storage_config` schema (Story 11a) is
  untouched.

### Wiring instruction for Story 2b (not performed in this story — `store_and_quarantine/...` does not exist yet)

Once Story 2b lands its async PUT pipeline, its `store_and_quarantine/...`
persist-transition-enqueue seam must call `Nebu.Media.StorageConfig.compute_key/2`
**immediately before** `storage_module().put(storage_key, ciphertext)` —
replacing the flat `media_id`-fallback placeholder that story's own text
reserves for this dependency:

```elixir
template = Nebu.Media.StorageConfig.get().s3_key_prefix_template

storage_key =
  Nebu.Media.StorageConfig.compute_key(template, %{
    media_id: media_id,
    server_name: server_name,
    uploaded_at: DateTime.utc_now()
  })

:ok = storage_module().put(storage_key, ciphertext)
# only now: persist storage_key + transition state (Story 2b AC8/AC9, ADR-032 ordering)
```

Key details Story 2b must preserve exactly:

- Read the template via `Nebu.Media.StorageConfig.get/0` (not
  `get_for_connection/0` — the template is not a secret), **at that call
  site**, not cached/passed down from an earlier step.
- Capture `uploaded_at: DateTime.utc_now()` **once, at this call site** —
  not at `/create` reservation time (Story 2a) — since a reservation can sit
  unused for up to `unused_expires_at` (default 24h) before the PUT lands.
- This is the **only** call site for `compute_key/2` in the whole codebase.
  Download (Story 1c), admin overview (5a/6b), archive worker (8c), and
  health dashboard (10) all read the already-persisted `media_files.storage_key`
  column and must never call `compute_key/2` themselves.
- Once written, `storage_key` is a write-once value — no later `upsert/1`
  changing `s3_key_prefix_template` may trigger any recomputation for
  already-uploaded rows (AC4).
- Story 2b must also add the real `media_async_upload_test.exs` integration
  tests for AT8/AT9 verbatim (this story's `key_prefix_template_test.exs`
  only ships scope-adapted stand-ins driving `compute_key/2` directly, per
  its own moduledoc).

This same instruction is also recorded as a `@doc` comment directly above
`compute_key/2` in `server/lib/nebu/media/storage_config.ex`.

### Test results

- `mix test test/nebu/media/key_prefix_template_test.exs test/nebu/media/storage_config_test.exs --warnings-as-errors`
  → **26/26 passed** (12 new `key_prefix_template_test.exs` tests [AT1-AT6,
  AT10, AT11, plus AT8/AT9 scope-adapted `compute_key/2` determinism tests]
  + 14 `storage_config_test.exs` tests [Story 11a's AT1-AT13 + this story's
  `11c-AT7`], all green, no regressions).
- `mix test --warnings-as-errors` (full suite) → **1757 passed, 4 skipped,
  449 excluded**, exit code 0 (no compiler warnings — `--warnings-as-errors`
  aborts at compile time on any warning, so a clean exit code here confirms
  none were introduced). No failures.

### File List

- `server/lib/nebu/media/storage_config.ex` — UPDATE: added `@placeholders`,
  `validate_template/1`, `compute_key/2`, `validate_template_field/1` (private),
  and the brace-balance/placeholder-token/media_id-presence/path-escape
  validation helpers; wired `validate_template_field/1` into `upsert/1`.
- `server/test/nebu/media/key_prefix_template_test.exs` — pre-existing
  RED-phase ATDD file (not created in this cycle); now green, unmodified.
- `server/test/nebu/media/storage_config_test.exs` — pre-existing RED-phase
  `11c-AT7` test addition (not created in this cycle); now green, unmodified.
- `docs/stories/media-security-admin-control/11c-s3-key-prefix-template.md`
  — this Dev Agent Record + `status` frontmatter update.

**Not touched** (confirmed via `git status`/`git diff --stat`): `server/lib/nebu/media.ex`,
`server/test/nebu/media/media_async_upload_test.exs`, and no file under
`server/priv/migrations/` — all three are listed in this story's
planning-time File List above but depend on Story 2b, which has not landed
on this branch (see Cycle 0 note).

### Cycle 1 (fix cycle — code review MAJOR-1 + MINOR-1)

- **MAJOR-1 fixed** — `check_no_path_escape/1` in
  `server/lib/nebu/media/storage_config.ex` previously stripped every
  `{placeholder}` token to `""` and checked the resulting concatenated
  skeleton for a leading `/`, `..`, or `//`. This silently collapsed the
  legitimate `/` separators sitting *between* adjacent placeholders into
  false double/triple-slashes, so it rejected **every** hierarchical
  multi-placeholder template — including this story's own User Story example
  (`"{year}/{month}/{server_name}/{media_id}"`) and the template used by
  Acceptance Tests 1/8/10 (`"{year}/{month}/{day}/{server_name}/{media_id}"}`).
  Fixed by splitting the raw template on placeholder spans
  (`Regex.split(~r/\{[^{}]*\}/, template)`) and checking each resulting
  literal segment **in isolation**: (a) only the FIRST segment is checked for
  a leading `/` (a template literally starting with `/`, e.g. `"/{media_id}"`
  or `"/etc/{media_id}"`); (b) any segment containing `".."` is rejected; (c)
  any segment containing a literal `"//"` is rejected. Placeholder-adjacent
  `/` separators never land inside a single segment (the placeholder token
  itself is removed by the split, taking the segment boundary with it), so
  hierarchical templates are no longer falsely rejected, while genuine
  leading-slash / `..` / literal-`//` templates still are.
- **MINOR-1 fixed** — added two regression tests to
  `server/test/nebu/media/key_prefix_template_test.exs` asserting
  `validate_template/1` returns `:ok` for
  `"{year}/{month}/{day}/{server_name}/{media_id}"` (the AT1/AT8/AT10
  template) and for `"{year}/{month}/{server_name}/{media_id}"` (the exact
  User Story example) — neither was previously asserted anywhere, which is
  how the MAJOR-1 regression shipped with a fully green suite.
- **Verification:**
  - `mix test test/nebu/media/key_prefix_template_test.exs
    test/nebu/media/storage_config_test.exs --warnings-as-errors` →
    **28/28 passed** (was 26/26 before this cycle; +2 new tests, zero
    regressions).
  - `mix test --warnings-as-errors` (full suite, in the `elixir:1.20-alpine`
    build container per `CLAUDE.md`) → **1759 passed, 4 skipped, 449
    excluded**, exit code 0 (was 1757 passed before this cycle; +2 new
    tests, zero regressions, zero new compiler warnings).
  - Hand-verified via a temporary `mix run` script (removed after use):
    `validate_template/1` returns `:ok` for `"{media_id}"`,
    `"{year}/{month}/{server_name}/{media_id}"`,
    `"{year}/{month}/{day}/{server_name}/{media_id}"`, and
    `"archive/{year}/{media_id}"`; and returns
    `{:error, :invalid_key_prefix_template}` for
    `"{year}/{month}/{server_name}"` (missing `{media_id}`),
    `"{room_id}/{media_id}"` (unrecognized placeholder), `"{media_id"`
    (unbalanced braces), `"../{media_id}"` (path escape), and both
    `"a//{media_id}"` and `"{media_id}//b"` (genuine literal `//`).
  - INFO-1 and INFO-2 from the review (runtime-value sanitization,
    substitution-order sensitivity) were explicitly out of scope for this
    fix cycle and were not touched. `server/lib/nebu/media.ex` and all
    migration files remain untouched (still out of scope pending Story 2b).

### File List (Cycle 1 additions)

- `server/lib/nebu/media/storage_config.ex` — UPDATE: rewrote
  `check_no_path_escape/1` to check literal placeholder-separated segments
  in isolation instead of a placeholder-stripped concatenation (MAJOR-1 fix).
- `server/test/nebu/media/key_prefix_template_test.exs` — UPDATE: added 2
  regression tests proving hierarchical multi-placeholder templates pass
  `validate_template/1` (MINOR-1 fix).
