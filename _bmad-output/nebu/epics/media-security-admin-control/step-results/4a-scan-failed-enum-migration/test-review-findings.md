# Pre-Dev Test-Review — 4a-scan-failed-enum-migration

Status: CLEAN (0 MAJOR)

## Coverage against Acceptance Criteria

- AC1 (single ADD VALUE statement) — `media_scan_failed_migration_test.exs`
  tests 1-2: exact-one-statement assertion + regression guard (no ALTER
  TABLE/INSERT/UPDATE/CREATE-DROP TYPE elsewhere in the up file).
- AC2 (down migration documents the limitation) — tests 3: no DROP TYPE, no
  `ALTER TYPE ... DROP VALUE`, documents the manual recreate-type procedure,
  and asserts zero executable statements (pure no-op).
- AC3 (guard-table edges into/out of `:scan_failed`) — `state_machine_test.exs`
  tests 7-12 (positive edges) plus the `@full_guard_table` sweep extended to
  include `:scan_failed` and the two new inbound edges on `:quarantined`/
  `:scanning`.
- AC4 (invalid edges rejected) — tests 13-15 (named negative controls,
  exact `{:error, {:invalid_transition, from, to}}` tuples) plus the
  `@full_guard_table` sweep's generic non-adjacency check.
- AC5 (download-gate needs no code change, verified not assumed) — new
  `@tag :integration` test in `media_download_gate_test.exs` seeds a REAL
  `media_files` row via `Nebu.Repo`/`Nebu.Media.DB` (not the fake DB module
  every other test in that file uses) with `state = 'scan_failed'` and
  asserts 451/`M_NOT_YET_UPLOADED` through the real `download_gate/1`.
- AC6 (no data migration) — covered by AC1's "no ALTER TABLE / no INSERT /
  no UPDATE" regression tests; `ALTER TYPE ... ADD VALUE` structurally
  cannot rewrite existing rows, and the up file is asserted to contain
  nothing else.

## Migration numbering correction (flagged, not a gap)

The story's Technical Requirements section hardcodes
`000023_media_scan_failed_state.*.sql`. That number was free when the story
was written (Story 1a's `000022` was the newest migration at the time), but
`000023`-`000027` were claimed by five other stories that landed first
(`000023_media_config`, `000024_media_storage_config`,
`000025_media_files_filename`, `000026_oban_jobs`,
`000027_media_files_uploader_user_id_nullable`). All new tests and the
migration itself use `000028`, the next free slot — SQL content and every
acceptance criterion are otherwise unchanged. This is a pure filename/number
correction, not a design or scope change, and does not rise to a MAJOR
test-review finding or an escalation-worthy gap.

## Local verification (no live Postgres)

- `mix compile` — clean.
- `mix test test/nebu/media/media_scan_failed_migration_test.exs
  test/nebu/matrix/migrations_grant_test.exs` — 12/78 new-and-existing tests
  RED via `File.Error` (migration files don't exist yet) — expected RED.
- `mix test --include integration` on the DB-dependent files — RED via
  "Nebu.Repo is not started" (no local Postgres available outside Docker) —
  expected precondition failure, not yet meaningful RED/GREEN on the actual
  logic. Real RED/GREEN verification for the DB-backed tests happens in
  Step 5 (`make test-integration`, full Docker stack).

## MINOR / INFO (non-blocking)

- None identified beyond the numbering note above.
