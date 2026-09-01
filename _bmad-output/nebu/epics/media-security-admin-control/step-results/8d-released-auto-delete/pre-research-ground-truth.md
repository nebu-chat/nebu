# 8d-released-auto-delete — Pre-Implementation Ground Truth (verified empirically 2026-07-19)

The story file was drafted assuming 9a had not landed yet. **9a has since landed and is `status: done`.**
This changes the implementation approach from what the story's "Technical Requirements" section describes.

## 1. Config: use `Nebu.Media.Config.get()` directly — no app-env fallback needed

`released_delete_after_days` **already exists** in `Nebu.Media.Config` (`server/lib/nebu/media/config.ex`),
fully wired since 9a:
- `@defaults`: `"released_delete_after_days" => nil`
- `@key_to_atom` maps it to `:released_delete_after_days`
- Validation: `nil` → `:ok`; `is_integer(value) and value >= 0` → `:ok`; anything else → `{:error, :invalid_value}`
  (note: validator currently accepts `0` as valid at the Config layer — AC1's "0 must not run as an
  active window" is the WORKER's responsibility to enforce as "0 is not a *positive* integer", not
  Config's)
- `media_config` table (migration `000023_media_config.up.sql`) already has the GRANT and the RLS
  mutable-keys policy already includes `released_delete_after_days`.
- `test/nebu/media/config_test.exs` already asserts `Config.get().released_delete_after_days == nil` by default.

**Decision: skip the story's app-env-fallback path entirely.** Call `Nebu.Media.Config.get().released_delete_after_days`
directly from the new worker. No new migration, no new `MigrationsGrantTest` entry required for the
config side (existing grant on `media_config` already covers this key).

## 2. Timestamp: NO `released_at` column exists — use `media_state_transitions` ledger (8a's pattern)

Confirmed via full migration read + `grep -rn "released_at" server/lib server/priv` → zero column hits
(only prose comments in 8c's worker documenting its absence).

`media_files` has no dedicated "became-released-at" timestamp. The correct, established pattern
(used by 8a's `MediaCleanupWorker` for `:deleted`/`:infected` eligibility, `server/lib/nebu/workers/media_cleanup_worker.ex`
lines ~92-99) is to derive it from the append-only `media_state_transitions` ledger:

```sql
SELECT mf.media_id
  FROM media_files mf
 WHERE mf.state = 'released'
   AND (SELECT MAX(t.inserted_at) FROM media_state_transitions t
         WHERE t.media_id = mf.media_id AND t.to_state = 'released') < NOW() - ($1 || ' days')::interval
 LIMIT 1000
```

**Do NOT copy 8c's shortcut** (8c anchors on `uploaded_at` BIGINT-epoch as "a documented simplification" —
that was acceptable there but 8d's own story text explicitly wants the real released-entry timestamp,
which is achievable here the same way 8a already did it for `:deleted`/`:infected`).

**Gotcha carried over from 8a**: the `$1` interval parameter MUST be bound as a string
(`Integer.to_string(days)`), not a raw integer — Postgres resolves the `||`-concatenation's type to
`text`, and passing a raw integer causes a `DBConnection.EncodeError` (8a hit this for real, now documented
in its own moduledoc comments).

## 3. StateMachine

`Nebu.Media.StateMachine.transition/4` signature:
```elixir
@spec transition(media_id :: String.t(), to_state :: state(), actor(), metadata :: map()) ::
        {:ok, state()}
        | {:error, {:invalid_transition, state(), state()}}
        | {:error, :invalid_actor}
        | {:error, :not_found}
def transition(media_id, to_state, actor, metadata \\ %{})
```
`:released -> :deleted` edge already exists in the guard table (used today by 6a's `admin_delete/2`).
No guard-table change needed.

## 4. Oban cron registration convention (8a + 8c both use this — mirror exactly)

`config/config.exs`, inside `config :nebu, Oban` → `{Oban.Plugins.Cron, crontab: [...]}`:
```elixir
{"0 2 * * *", Nebu.Workers.MediaCleanupWorker},
{"0 2 * * *", Nebu.Workers.MediaArchiveWorker},
```
8d adds a third tuple: `{"0 2 * * *", Nebu.Workers.MediaReleasedAutoDeleteWorker}` to the same list.
Worker itself: `use Oban.Worker, queue: :media_cleanup, max_attempts: 5` (match 8c's queue/attempts).

## 5. AuditWriter

`server/lib/nebu/compliance/audit_writer.ex`:
- `log/6,7`: `def log(actor_user_id, action, target_type, target_id, metadata, outcome, error_detail \\ nil)`
- `@known_actions` does NOT yet include `media_released_auto_deleted` — 8d must add it (allowlist gotcha
  from 4c/6a: a missing entry silently drops the audit row via `{:error, :audit_unknown_action}`
  while the state transition itself still succeeds — must add + test the assertion directly per AT4).
- Actor-string convention across existing workers: `"system:media_cleanup_worker"` (8a),
  `"system:media_archive_worker"` (8c), `"system:compliance_worker"` (SessionExpiryWorker).
  **Recommendation**: `"system:media_released_auto_delete_worker"` — mirrors the module name 1:1,
  consistent with 8a/8c's own convention (not the story's suggested abbreviated `"system:media_lifecycle"`,
  which would be the only inconsistent one in the group).

## 6. MigrationsGrantTest

`server/test/nebu/matrix/migrations_grant_test.exs` is hand-enumerated per migration file
(000002, 000006, 000008, 000009, 000010, 000011, 000012, 000022, 000023, 000024, 000026 + a
generic down-migration-no-GRANT AC4 sweep). **8d needs no new migration and therefore no new entry
here** — it only reads `media_config` (already granted+tested) and reads/writes `media_files` /
`media_state_transitions` (both already granted from 000001/000022). Confirm no new migration file
is added during dev-story; if one somehow is, this test MUST be extended per the epic-wide gotcha
called out by the orchestrator.

## Net implementation decision for dev-story

- Config read: `Nebu.Media.Config.get().released_delete_after_days` (no app-env fallback path, no TODO shim).
- Validity check in the worker itself: `nil` → no-op; `is_integer(x) and x > 0` → active window;
  anything else (`0`, negative, non-integer) → log error + no-op (AC1). Do this validation in the
  worker even though Config's own validator is looser (accepts `0`) — AC1 requires "positive integer"
  at the worker's eligibility-decision level, not just Config's storage-level validation.
- Eligibility timestamp: derive from `media_state_transitions` `MAX(inserted_at) WHERE to_state = 'released'`,
  exactly mirroring 8a's `:deleted`/`:infected` query shape (including the `Integer.to_string/1` binding
  gotcha).
- Transition call: `StateMachine.transition(media_id, :deleted, {:system, nil}, metadata)`.
- Audit: `AuditWriter.log("system:media_released_auto_delete_worker", "media_released_auto_deleted", "media", media_id, %{released_delete_after_days: days, released_for_days: actual_age}, "success")`.
- Add `media_released_auto_deleted` to `AuditWriter.@known_actions`.
- Oban cron registration: add third crontab tuple alongside 8a/8c's, same `"0 2 * * *"` schedule, `:media_cleanup` queue.
- No new migration. No new MigrationsGrantTest entry.
