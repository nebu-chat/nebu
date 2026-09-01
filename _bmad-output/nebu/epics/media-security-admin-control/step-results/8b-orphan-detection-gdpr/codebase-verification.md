# 8b-orphan-detection-gdpr — Pre-dev codebase verification (done by pipeline orchestrator before ATDD/dev-story)

The story's own Technical Requirements section explicitly asks for several things to be
verified against the live codebase before implementing. Verified now (2026-07-19); findings
below are corrections to the story's own text, in the same "self-correct schema-reality
drift, do not re-escalate" spirit already established repeatedly in this epic (5a's filename
column, 6b's clamav_signature key, 8a's :deleted_at ledger-derivation). None of these are
architecture-level gaps — they are factual corrections dev-story must apply.

## 1. `media_files.uploaded_at` is BIGINT (ms-epoch), NOT TIMESTAMPTZ

Confirmed via `server/priv/migrations/000001_init.up.sql:298`: `uploaded_at BIGINT NOT NULL`.
The story's own Technical Requirements flagged this as an open question ("verify... if it
turns out to be a ms-epoch BIGINT like `unused_expires_at`... adjust the comparison
accordingly") — it IS BIGINT. The story's literal SQL (`mf.uploaded_at < NOW() - ($1 || '
hours')::interval`) is WRONG as written and will not compile/will misbehave (comparing bigint
to interval-subtracted-timestamp). Follow the established ms-epoch pattern already used in
`Nebu.Media` (`server/lib/nebu/media.ex`, `expired?/1`-style check: `uploaded_at +
unused_expires_ms() < System.system_time(:millisecond)`): bind the pre-computed millisecond
threshold as a plain bigint parameter, e.g. `mf.uploaded_at < $1` where `$1 =
System.system_time(:millisecond) - orphaned_hours * 3_600_000`, NOT a Postgres
`NOW() - interval` expression.

## 2. `Nebu.Media.Config` (Story 9a) already landed (2026-07-13) — do NOT read from it here

`server/lib/nebu/media/config.ex` exists, with its own `orphaned_hours` key (default `24`,
part of the `media_config` DB table, migration `000023_media_config.up.sql`). Story 9a's own
moduledoc is explicit: "This story only builds the table + module. It does NOT rewire any
existing consumer... each of those keeps reading its own config.exs/app-env key for now;
rewiring is each citing story's own follow-up work." Story 8a (completed today, immediately
before 8b in this epic's build order) followed this exactly: it added its OWN separate
`config.exs` entry (`config :nebu, :media_cleanup, deleted_days: 30, infected_days: 7`)
completely independent of `Nebu.Media.Config`'s own (unused) defaults for the same key names
(`Config`'s defaults: `deleted_days => 30, infected_days => 90` — note these already diverge
from 8a's config.exs values, and that divergence was accepted/shipped without objection).

**Action for dev-story:** define a static `config.exs` entry for `orphaned_hours` exactly per
AC4/Technical Requirements (own key, default 48 per this story's own AC4 — yes, this
intentionally differs from `Nebu.Media.Config`'s own already-shipped default of 24 for the
same key name; that is expected and precedented, not a bug to reconcile). Do NOT call
`Nebu.Media.Config.get()` from this worker. Note the divergence in the Dev Agent Record,
mirroring 8a's own equivalent note.

## 3. `actor_user_id` is a REQUIRED audit_log field — story's "nil for system runs" is wrong

`server/lib/nebu/compliance/audit_log_entry.ex:23`: `@required_fields [:actor_user_id,
:action, :outcome]`. `audit_writer.ex`'s own comment: "actor_user_id cannot be silently
persisted as nil or ''." Passing `nil` as `actor_user_id` will fail changeset validation and
`AuditWriter.log/6` will return `{:error, changeset}` — silently breaking the audit trail for
every run of this worker, the exact class of failure the story itself warns about for the
`@known_actions` allowlist gotcha (AC2/Technical Requirements), just via a different field.

The established, consistent convention for every other system-initiated worker in this exact
epic uses a `"system:<worker_name>"` string, never `nil`:
- `media_cleanup_worker.ex` → `"system:media_cleanup_worker"`
- `media_scan_worker.ex` → `"system:media_scan_worker"`
- `media/config.ex` → `"system:media_config"`
- `media/storage_config.ex` → `"system:media_storage_config"`
- `compliance/session_expiry_worker.ex` → `"system:compliance_worker"`

**Action for dev-story:** use `"system:media_orphan_detection_worker"` (or the module's own
equivalent name) as `actor_user_id`, NOT `nil`. Story AC2's "actor_user_id: nil" phrasing
should be treated as informal shorthand for "no human actor", not a literal instruction —
correct it the same way 5a/6b corrected their own stale story text, noted in Dev Agent Record.

## 4. `events` table / GIN index — story's Technical Requirements description confirmed accurate

Confirmed via `server/priv/migrations/000001_init.up.sql`: `events.content` (JSONB) currently
has NO GIN index — only `events_relates_to_event_id_idx` (expression index on
`content->'m.relates_to'->>'event_id'`) and `events_search_vector_gin_idx` (tsvector search
index). The story's own "Offene Entscheidung #3" section is accurate as written; the
EXPLAIN ANALYZE check (AC6) is a real, not-yet-done open item — actually run it before
shipping and record the finding + decision in the Dev Agent Record, per the story's own
instructions.

## 5. `AuditWriter.@known_actions` — confirmed current, gotcha still real

`media_orphan_detection_run` is NOT currently in `@known_actions`
(`server/lib/nebu/compliance/audit_writer.ex`). Must be added per Technical Requirements.
`gdpr_deletion` DOES already exist in the allowlist (confirmed, unrelated flow) — the story's
"do not repurpose that action name" guardrail is accurate and still relevant.

## 6. `Nebu.Admin.AuditLogLive` confirmed generic/action-agnostic — no new UI work needed

`server/lib/nebu/admin/audit_log_live.ex`'s query (`SELECT event_time, actor_user_id, action,
target_type, target_id, outcome FROM audit_log ORDER BY event_time DESC, id DESC LIMIT 200`)
renders any action generically. Confirms the story's "no new admin UI" claim (`ui: false`) —
a `media_orphan_detection_run` entry will show up in the existing `/audit-log` viewer with no
code changes to that LiveView.

## 7. `AuditWriter.log/6` real signature (confirmed)

```elixir
def log(actor_user_id, action, target_type, target_id, metadata, outcome, error_detail \\ nil)
```

## 8. Minor cosmetic note — mxc:// construction line reference is stale

The story's AC1 cites `server/lib/nebu/media.ex:96` for "the existing construction pattern" of
`mxc://<server_name>/<media_id>`. The actual construction sites today are at lines ~238 and
~302 (`"mxc://#{server}/#{created_media_id}"`) — line 96 no longer corresponds (file has grown
via later stories). Purely a stale line-number reference, not a functional issue; use the
`"mxc://#{server_name}/#{media_id}"` string-interpolation pattern shown at those lines.

## 9. Open (non-blocking) design choice: `target_type`/`target_id` for a batch-style audit entry

No existing worker in this codebase yet writes ONE audit entry summarizing N rows (8a and
`session_expiry_worker.ex` both write one entry PER row/candidate). This story is the first
"one entry per run, not per candidate" case (AC2). The story specifies `metadata` content
precisely but not `target_type`/`target_id`. Reasonable choice: `target_type:
"media_orphan_detection"`, `target_id: nil` (no single target exists) — left to dev-story's
judgment, not a blocker.

## Overall assessment

None of the above rises to a "genuine design/architecture gap between this story and its
dependencies" requiring a pipeline stop — all are the same class of self-correctable
schema/convention-reality drift this epic has repeatedly handled inline (5a, 6b, 8a
precedent). Proceeding through ATDD → dev-story with this context attached.
