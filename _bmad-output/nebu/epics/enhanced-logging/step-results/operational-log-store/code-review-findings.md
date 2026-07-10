# Code Review Report — `operational-log-store` (epic: enhanced-logging, cycle 0)

**Scope:** staged diff (`git diff --staged`), 24 files, +2807/-58. Verified against the story's AC1–AC11, the Oracle matrix-spec context, and the pre-dev test-review findings. Compiled clean (`mix compile --warnings-as-errors`); ran the non-integration suite (27/27 pass) for the touched modules to confirm behavior independent of the story's own claims.

I did **not** fix anything — findings only, per instructions.

---

## MAJOR

### M1 — `route_template` DB column is NULL for every HTTP-sourced log entry (AC5 / AC9 / AC1 index defeated)
**Files:** `server/lib/nebu/web/plugs/request_logger.ex:79-98`, `server/lib/nebu/web/log_store/handler.ex:53-64`

`RequestLogger` computes `route_template` and puts it only inside the `base_fields` **map that becomes the Logger message** (`Logger.info(base_fields)` / `Logger.debug(fn -> ... end)`). It never calls `Logger.metadata(route_template: ...)`. `Handler.parse_log_event/1` extracts `route_template`/`request_id` exclusively from the `:logger` event's `meta` field (`Map.get(meta, :route_template)`), not from the rendered message content.

I verified this empirically: `Logger.info(%{route_template: "/sync", ...})` produces `meta: %{pid:.., time:.., gl:.., domain: [:elixir]}` — **no `route_template` key at all**. `request_id` only survives because `RequestLogger` separately calls `Logger.metadata(request_id: ...)` early — `route_template` never got the same treatment.

Consequence: every HTTP-sourced row in `operational_logs.route_template` is `NULL`. This defeats:
- AC1's dedicated index `(route_template, inserted_at)` — its entire stated purpose ("Later Admin UI story groups/filters by normalized route_template over time," per the migration's own comment) is unusable for the primary `source: "http"` case.
- AC9's `get_logs(%{route_template: ...})` filter for HTTP entries.
- The design doc's own stated motivation ("`/sync`... matters for the war-room-mode story's safety scoping") — scoping by `route_template` on a persisted row is silently broken for the very source it was built for.

Not caught by any test: `request_logger_test.exs`'s AC5 tests only assert the substring `"route_template"` appears in `ExUnit.CaptureLog`'s raw text output; `log_store_test.exs`'s `get_logs/1` tests seed rows manually via raw SQL (bypassing `Handler` entirely) and never exercise the real HTTP→Handler→Writer path against the `route_template` column.

**Fix direction (not applied):** `RequestLogger` needs `Logger.metadata(route_template: route_template)` alongside its `request_id: request_id` call (or `Handler` needs to also inspect `msg` for a `route_template` key when it's a report map) — and a new test asserting the actual persisted column, not just substring-in-message-text.

### M2 — `RouteNormalizer` leaves `txn_id`, `device_id`, `event_type`, account-data `type` unnormalized — Oracle MUST violated
**File:** `server/lib/nebu/web/log_store/route_normalizer.ex:45-51, 96-109`

The Oracle context explicitly requires placeholders for `{roomId}, {userId}, {eventId}, {roomAlias}, {txnId}, {stateKey}, {eventType}, {deviceId}` (also `{type}` for account-data). The implementation only replaces sigil-prefixed segments (`!`, `@`, `#`, `$`) plus `state_key` (handled positionally, correctly). Everything else falls through to a generic `@opaque_id_regex ~r/^[0-9a-fA-F]{32,}$/` fallback — the exact same class of "shape-based regex fails open" anti-pattern the Oracle flagged (and the dev agent itself correctly fixed) for `state_key`, but left unfixed for `txn_id`/`device_id`/`event_type`.

Verified live:
```
normalize_route("/_matrix/client/v3/rooms/!abc:localhost/send/m.room.message/m1234567890")
  #=> ".../send/m.room.message/m1234567890"   -- eventType AND txnId both leak raw
normalize_route("/_matrix/client/v3/devices/ABCDEFGHIJ")
  #=> ".../devices/ABCDEFGHIJ"                -- deviceId leaks raw, untouched entirely
```
Real Matrix txn_ids and device_ids are typically short, non-hex, client-chosen opaque strings (e.g. `m1234567890`, `ABCDEFGHIJ`) — they will essentially never match the 32+ hex-char fallback regex, so they leak verbatim into `route_template` in the overwhelming majority of real traffic. `device_id` gets no fallback attempt at all since `/devices/{deviceId}` has no sigil and is usually far shorter than 32 chars.

This also contradicts the story's own schema comment example: `route_template TEXT, -- normalized, e.g. "/rooms/:room_id/send/:event_type/:txn_id"` — the shipped code produces `/rooms/:room_id/send/m.room.message/m1234567890`, not that.

No test in `route_normalizer_test.exs` exercises `txn_id`, `device_id`, or `event_type` at all (only room ID, user ID, state_key, room alias, and Unicode localparts are covered) — this gap is currently invisible to the suite.

---

## MINOR (hand back to dev agent)

### N1 — Single malformed entry in a batch drops the *entire* batch, not just the bad row
**File:** `server/lib/nebu/web/log_store/writer.ex:82-93`

`insert_batch/1` is one multi-row `INSERT` statement; on any constraint violation (e.g. a `nil` level), `Ecto.Adapters.SQL.query!/3` raises, `flush_buffer/1`'s `rescue` logs a WARN, and the buffer (up to 100 entries) is unconditionally discarded — no retry, no per-row fallback, no requeue. One poison entry silently destroys up to 99 unrelated, valid, co-batched diagnostic entries. Same mechanism means a sustained `Nebu.Repo` outage silently drops every WARN/ERROR log emitted during the outage (aside from the WARN about the failure itself). Acceptable severity for best-effort diagnostic data, but worth a per-row fallback-retry (e.g. re-attempt as N single-row inserts on batch failure) to bound the blast radius of one bad row.

### N2 — Pre-dev test-review MINOR findings #3–#5 remain unaddressed
Test-review flagged 3 MINOR items explicitly deferred to dev-story ("logged for the dev agent to address during implementation (not blocking)"). None were fixed:
- **#3** (Sweeper→Retention wiring untested): confirmed the *implementation* wiring is correct (`sweeper.ex:44-47` genuinely calls `Nebu.Web.LogStore.Retention.prune_operational_logs/0`), but there is still no `sweeper_test.exs` (doesn't exist) exercising `Sweeper.sweep/0` invoking it — only `Retention.prune_operational_logs/0` is tested directly.
- **#4** (hardcoded `Process.sleep(6_000)` instead of the polling helper): still present in `writer_test.exs` (`"an entry that violates...NOT NULL...does not crash the writer"` test, line ~140, and the AC7 level-filtering test, line ~261) — the file's own `wait_until_rows/3` polling helper exists but isn't used here.
- **#5** (`if Process.whereis(Nebu.Repo) do ... end` with no `else`, untagged `:integration`): still present in `log_store_test.exs`'s AC3 test (line 244) and AC9 "reflects server_config values" test (line 305) — both silently no-op/pass under plain `mix test` instead of being tagged `:integration` like every other DB-dependent test in the same file.

### N3 — Dev Agent Record's "Known Risks / Test Defects" section is stale/inaccurate relative to the actual shipped test files
The story's Dev Agent Record documents two "known, unfixable test defects": (1) `log_store_test.exs`'s AC2 test allegedly asserting an exact `+1` handler-count delta, and (2) `handler_test.exs`'s persisted-row security test allegedly querying `WHERE message LIKE '%distinctive%persisted-row%'` (a pattern that could never match correctly-redacted data). Neither matches the actual staged files: `log_store_test.exs:178` asserts `length(new_ids) <= 1` (already order-tolerant), and `handler_test.exs:284` queries `WHERE request_id = $1` (not a message-content LIKE at all). Both described "defects" already don't exist in what's staged. This isn't a functional bug, but it's misleading self-documentation that could cause a future reviewer to either waste time chasing a non-issue or, worse, trust an inaccurate record instead of re-verifying. Should be corrected before merge.

---

## INFO

- **PolicyCache design (deviation #4) is sound.** Confirmed `should_persist?/1` never touches `Nebu.Repo` on the hot path (WARN/ERROR bypass the cache entirely and always return `true`; INFO/DEBUG read `persistent_term` only). Startup-race is fail-safe: before the first refresh tick, `PolicyCache.get/0` returns conservative defaults (`log_collect_info/debug: false`), so nothing over-persists during the boot window. Cache invalidation on `upsert_server_config/1` writes is correctly wired via `Nebu.Web.LogStore.refresh_policy_cache/0`, mirroring the existing OIDC scope-cache pattern.
- **Writer supervision (AC6) is genuinely correct**, verified against `application.ex`: `Writer` is a normal `:permanent` child ordered after `Nebu.Repo` inside `repo_children/0`; `writer_test.exs`'s new crash/restart test (`Process.exit(pid, :kill)` → poll for a new pid under the same name → `write_async/1` still works) actually proves the supervisor path, not just internal error-catching.
- **Batched INSERT parameter indexing has no off-by-one** — verified the `$N` placeholder math (`base = idx * length(@columns)`) is correct across row boundaries.
- **Retention SQL (AC8) has no injection risk** — `days`/`max_count` are bound parameters (`$1`/`$2`), never string-interpolated; idempotent DELETE-based pruning confirmed by both code review and the dedicated idempotency test.
- **`server_config` RLS allowlist (AC3) is a genuine, verified fix** — the migration's `config_update_mutable` policy is actually re-created with the 5 new keys (matching the real `000016` precedent, not just "happens to not error" on first-insert). Down-migration correctly reverts both the policy and the table.
- **Migration idempotency convention matches the codebase** — `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`, consistent with `000015_account_data.up.sql` and others.
- **Handler.log/2 is genuinely crash-proof and non-blocking** — function-level `rescue` wraps the entire body (parsing + broadcast + write), and the only DB-adjacent call is a `GenServer.cast/2`.
- **Redaction pass-through (the most security-critical check) is correctly implemented and correctly tested** — `Handler` does no independent re-derivation of request data; both the pre-dev MAJOR test-review gaps (Writer crash/restart, persisted-row redaction check) were genuinely added and pass against real behavior, not just against the broadcast side.
- **`retention_test.exs`'s DEBUG-cap test has a plausible, pre-existing flakiness class** (shared non-sandboxed test DB; a concurrently-running test's own DEBUG-level log could theoretically displace one of the 500 "most recent" rows this test expects to survive) — this is an existing architectural test-isolation limitation of this suite, not a defect introduced by this story; no action needed for this cycle.

---

## Deviation review (task item 11)

- **Raw `.up.sql`/`.down.sql` migration instead of `.exs`**: well-justified — matches verified real codebase convention (no `Ecto.Migration` anywhere in `server/lib`).
- **`PolicyCache` addition**: well-justified — a real connection-pool reentrancy bug, fixed with a sound, cheap `persistent_term` cache.
- **`RequestLogger`'s `path` field now equals normalized `route_template`**: reasonable intent (stop leaking raw room IDs into the message text), but this is the same change that produced **M1** — the fix addressed the message-text leak while overlooking that the dedicated DB column depends on Logger *metadata*, not message content. Worth revisiting together with M1's fix.

---

**Summary:** 2 MAJOR (both real functional/spec gaps in the foundation story that downstream epic stories — `admin-logs-monitoring-view` in particular — will build on top of and be silently broken by), 3 MINOR (batch data-loss risk, unaddressed pre-dev MINOR test-review items, stale Dev Agent Record), several confirmed-solid areas (Writer supervision, RLS allowlist, retention SQL, redaction pass-through, PolicyCache).

Relevant files:
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/plugs/request_logger.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/log_store/handler.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/log_store/route_normalizer.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/log_store/writer.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/log_store.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/log_store/policy_cache.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/log_store/retention.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/application.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/matrix/session/sweeper.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/admin/db.ex`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/priv/migrations/000017_operational_logs.up.sql`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/priv/migrations/000017_operational_logs.down.sql`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/web/log_store/route_normalizer_test.exs`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/web/log_store/writer_test.exs`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/web/log_store/handler_test.exs`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/web/log_store_test.exs`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/web/plugs/request_logger_test.exs`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/docs/stories/enhanced-logging/operational-log-store.md`

Now updating agent memory with the recurring pattern observed in this review (test-review findings not carried through to dev-story, and the "structured field only in message text, not Logger metadata" gap class).
