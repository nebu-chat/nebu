# Code Review Report — Story 9a (media-config-table-module), Cycle 0

Verdict: solid implementation, all 6 ACs functionally met, guardrails hold.
1 MAJOR, 4 MINOR, several INFO confirmations (F1/F2/F4 pre-dev fixes all verified to hold up
in the real implementation, not just at the test-name level).

## MAJOR

M1 — build_catalog/1 crashes (KeyError) on any media_config row whose key is outside the
10-key @key_to_atom catalog. config.ex:399-403. default_loader (config.ex:450-464) does an
unconditional `SELECT key, value FROM media_config` returning ALL rows; Map.merge(@defaults,
override) then Map.fetch!/2 on any unrecognized key raises. This crash happens inside the
GenServer on init/:refresh/:ttl_tick/:invalidate — a single stray row crash-loops the cache.
Concretely triggerable: the story itself documents that later stories (10c thresholds, 10d
fail-open/closed) add NEW keys to this SAME table via their own migrations sharing this
loader/RLS allowlist; in a rolling cluster deploy (exactly the scenario AC5's :pg/TTL machinery
exists for) an old-code node reading a new key written by a new-code node crashes on its next
TTL refresh -- taking down a security-relevant cache (upload/scan size limits, mime denylist).
Also triggerable today by any manual/stale row. Fix is small (filter to known keys via
Map.take(override, Map.keys(@defaults)) before merge) but is a real robustness/availability
gap, not exercised by any current test.

## MINOR

m1 — Bespoke Config.Supervisor + custom start_link/1 + unconditional boot start deviates from
the established cache-child convention in this codebase (bare :permanent child under root
supervisor, e.g. OidcClaimCache; or a :start_xxx env-gated flag, e.g. ClamAV/JwksCache). Works
correctly (see INFO: F2 resolution verified sound) but is more machinery than the convention
warrants, and introduces 2 files not in the story's original File List. max_restarts:1000/5s
also largely neutralizes crash-loop detection for this child.

m2 — No DB transaction around read-old-value -> write -> audit, though the story's own skeleton
specified a Repo transaction. TOCTOU risk on concurrent same-key upserts (wrong old_value
recorded); audit write is outside any transaction so a committed config change could have no
audit record if the audit insert fails. Acceptable under the story's single-writer admin-UI
assumption, but deviates from the skeleton and weakens the compliance guarantee.

m3 — Audit-write failure is silently ignored: upsert/2 returns :ok even if AuditWriter.log
degrades to {:error, :audit_write_failed} (Repo down). AC6 requires every successful upsert to
write the audit entry; here the DB write can succeed while the audit is dropped and the caller
still sees :ok. Related to m2.

m4 — upsert/2 has no actor parameter; all media_config_updated entries are attributed to a
fixed @audit_actor "system:media_config". When Story 9b wires the admin settings UI to
upsert/2, there will be no way to record which admin changed a value. Worth deciding before 9b
builds on this signature.

## INFO (confirmations)

- F2 resolution HOLDS: :transient (not :permanent) is verified correct via OTP semantics —
  :permanent restarts on ANY exit including GenServer.stop's :normal reason (which is exactly
  what config_test.exs's on_exit calls after every test), which would trip restart-intensity
  during the test suite; :transient does not restart on :normal/:shutdown but DOES restart on
  the F2 test's Process.exit(pid, :kill). The dev agent's empirical justification is sound, not
  a misdiagnosis.
- F1 resolution HOLDS: real writer SQL is a genuine INSERT ... ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value, set_at = EXCLUDED.set_at (config.ex:471-474) -- not insert-only.
- F4 resolution HOLDS: valid_mime_token?/1 (config.ex:317-324) enforces non-empty, rejects
  space/tab/newline/cr, requires a literal "/"; empty tokens from double/trailing commas
  rejected. Arguably stricter than AC4 strictly requires (rejects a bare "image" prefix lacking
  "/") but not looser than needed -- satisfies AC4 and all tests.
- nil round-trip verified correct, no type confusion between mime_denylist's genuine "" and
  webhook_url/released_delete_after_days' nil-encoded-as-"".
- :ttl_tick self-loop correctly re-arms (handle_info re-calls schedule_ttl_tick/0).
- Migration numbering correct (000023 is the genuine next free slot after 000022); release_test.exs
  correctly bumped to [1..23].
- Guardrails fully satisfied: no touching of server_config/OidcConfig's ETS+:pg
  group/Nebu.Media/Nebu.Media.ClamAV/any worker; own dedicated table/group; SSRF.check/1 reused
  not reimplemented; max_concurrent_stalls/unused_expires_at correctly absent; catalog exactly
  matches the 10 required keys+defaults.
- @spec inaccuracy: upsert/2's real error path returns {:error, term()} not {:error, atom()}.
- Doc overstatement: config.ex/application.ex comments claim to "mirror OidcClaimCache's
  placement" but OidcClaimCache is a bare :permanent child, this is a bespoke supervisor with
  :transient — relates to m1(supervisor convention note).
- coerce_value's is_binary->String.to_integer branches would raise on non-numeric input; not
  reachable via the real validated-write path today, but the source-seam test path has no
  guard. Folds into M1's robustness theme.
