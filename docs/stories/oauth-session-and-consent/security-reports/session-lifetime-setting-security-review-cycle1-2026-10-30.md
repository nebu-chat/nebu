# Security Review: session-lifetime-setting (Kassandra, cycle 1 delta)

Date: 2026-10-30. **Verdict: APPROVED (CLEAN: 0 CRITICAL, 0 HIGH, 0 MEDIUM)**, 3 LOW, 2 INFO.

Cycle 0 findings: #1 MEDIUM FIXED (failed/damaged read answers last-known-good, never env; env/8 h only when nothing was ever loaded on the node); #2 audit before-value FIXED (computed inside the row lock in the same transaction); #3 warning volume FIXED (RateLimit 1/min/node, own bucket, static text); #4 legacy paths MITIGATED (last-good during outages, one uncached query per call remains, documented).

| # | Sev | Location | Finding | Remediation |
|---|-----|----------|---------|-------------|
| 1 | LOW | `oauth/config.ex` `resolve_saved_ttl/1` vs `note_saved_matrix_session_ttl/1` | CWE-362: a read already in flight can write an OLDER, longer value into LastGood after a save committed; stays until the next successful read (not covered by "at most one TTL"). | Generation counter in LastGood: bump in note_saved, the reader captures it before the query and writes only if unchanged (`:ets.select_replace`), or document. |
| 2 | LOW | `oauth/config.ex:508-509` `:no_repo` branch | Ignores last-known-good (answers nil => env/8 h while Nebu.Repo is absent, e.g. during a Repo restart). | `{:nocache, %{disabled() | matrix_session_ttl_seconds: LastGood.get()}}` + test (saved 3600, Repo not registered => 3600). |
| 3 | LOW | `admin/db.ex` `run_locked_config/2` | After-commit queue (process dictionary) not reentrant: a nested `with_locked_config` resets/deletes the outer queue and a later save runs the hook before commit. | Join an existing queue (do not reset/delete in `after`) or raise ArgumentError. |

INFO: fresh node / CacheOwner restart uses env/8 h until the first successful read (documented; operators may set NEBU_MATRIX_SESSION_TTL_SECONDS to at most their strictest saved value); a lost commit acknowledgement keeps the previous committed value (invariant holds).

Verified clean: rollback safety of after-commit effects, FOR UPDATE lock only on the one key (readers never blocked), single parser `parse_matrix_session_ttl/1`, audit same transaction integers only, gate before validation, log hygiene, template escaping, migration 000056, test seams compiled only in :test.

Pattern for memory: last-known-good slots need a generation / compare-and-set against in-flight refills, and EVERY non-success branch (including :no_repo) must answer last-good.
