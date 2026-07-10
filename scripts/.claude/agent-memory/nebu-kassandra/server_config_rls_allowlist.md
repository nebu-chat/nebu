---
name: server-config-rls-allowlist
description: New server_config keys need config_update_mutable RLS allowlist extension or every UPDATE after the first INSERT silently no-ops; review the extend migration for verbatim copy + accidental key drops
metadata:
  type: project
---

Every new `server_config` key written by an Admin-config controller (via `Nebu.Admin.DB.upsert_server_config/1`, which itself does NOT gate keys in Elixir) is guarded ONLY by a Postgres RLS policy on `server_config`. Three policies: `config_read_all` (SELECT), `config_insert_only` (INSERT, unconditional), `config_update_mutable` (UPDATE, `USING (key IN (...))`). There is deliberately NO DELETE policy for any key.

**Why:** The FIRST write of a brand-new key always succeeds as an unconditional INSERT — so a single-upsert test passes even when the key is missing from the allowlist. The SECOND write is an UPDATE and, if the key is not in `config_update_mutable`'s `IN(...)` list, the RLS `USING` clause fails and the UPDATE **silently affects 0 rows, raising no error**. Subtle, easy-to-miss bug class specific to this codebase.

**How to apply:** When a diff adds a server_config key, confirm a migration `DROP POLICY IF EXISTS config_update_mutable` + `CREATE POLICY ... USING (key IN (...))` that copies the PREVIOUS migration's list VERBATIM and only ADDS the new key(s). Diff the new list against the prior migration (e.g. 000018 vs 000017) key-by-key: a copy-paste that drops or typos an existing key silently breaks UPDATES for that unrelated key. Verify the `.down.sql` restores exactly the prior list. Precedent chain: 000013/000016/000017/000018. Also confirm the key is added to `Nebu.Admin.DB.@log_policy_cache_keys` (cache invalidation) and `PolicyCache.@defaults` (read path) — a missing default means reads fall back silently. See [[generic-logger-persistence-sink]].
