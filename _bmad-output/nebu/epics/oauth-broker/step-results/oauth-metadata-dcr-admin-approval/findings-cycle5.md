# Cycle 5 fix list — code-review cycle 4 + Kassandra re-review (cycle 4). Both: no CRITICAL/HIGH, Kassandra CLEAN.
Decision (Phil, 2026-10-09): auth_issuer / unstable msc2965 keep the IdP PASSTHROUGH while OAuth is disabled (spec decision #7 amended: Nebu issuer only when OAuth enabled, no 404 when disabled; stable v1/auth_metadata stays 404 when disabled). Spec text already updated; remove the "deviation" wording from story/ADR-033/pipeline notes and describe it as the decision. Weak test: oauth_metadata_test.exs ~296 non-GET asserts `status in [404, 405]` — pin the exact status the code returns.

## Fix now
Code review MINOR: 
1. Stale test names/comments after loose/strict split (server/test/nebu/oauth/oauth_dcr_rate_limit_cors_test.exs :42 :97 :~145 :~123) — rename/recompute to 600/5000.
2. AuditWriter moduledoc (server/lib/nebu/compliance/audit_writer.ex:4-6) says never inside the caller's transaction — add carve-out for Nebu.OAuth decisions.
3. ADR-033 "Database guard" + migration 000040 comment section 3 say INSERT policy open — now pending-only; ADR heading levels (### Client-hosted logos nests under ## Gate items) fix.
4. Nebu.OAuth moduledoc (server/lib/nebu/oauth.ex:8-11): add Nebu.Web.Plugs.OAuthDiscovery as second HTTP-edge forwarder (ADR-020 exception text).
5. Story prose with superseded values (docs/stories/.../oauth-metadata-dcr-admin-approval.md :70,:122,:373 50/h only strict family; :654 GRANT; :658 approve/2 etc.; :659; :802; :806) — mark superseded by later sections or amend.
6. E2E "ATDD, written FIRST (RED)" prose: e2e/features/admin/oauth-client-approvals.feature:7 and e2e/step-definitions/admin/oauth-client-approvals.steps.ts:4.
7. Runbook note (story + follow-ups.md): 000040 was edited in place; DBs that applied an earlier shape must be reset (drop volume or run down then up).
8. oauth_registrations_controller.ex ~196 `{:error, _other}` clause: Logger.error of type/SQLSTATE only.
Kassandra:
- F-1 remainder: junk/invalid requests share the global 5000/h loose bucket that dedup hits (every login) depend on -> give INVALID requests their own bucket; dedup hits are charged only a per-IP bucket (no global limit) — adjust tests (oauth_dcr_rate_limit_cors_test, oauth_dcr_dedup_limits_test).
- N-2: reject hex/octal-ish numeric last labels: last label matching ~r/\A(0x[0-9a-f]*|[0-9]+)\z/i in registration.ex:349-354 AND oauth_registrations_html.ex:53-56 (https://127.0.0.0x1, 10.0.0.0x5, 0x7f.0x1); add tests.
- N-3: guard trigger: once OLD.status <> 'pending', refuse changes to status and all *_by/*_at columns (allow last_used_at and NULLing created_from_ip/user_agent); migration test rejected->approved, approved->rejected, rewriting approved_by refused.
- N-4: Nebu.OAuth.Config three-state (enabled / disabled / unknown); OAuthDiscovery takes the IdP passthrough ONLY on a positively read "disabled"; on "unknown" (unreadable server_config) answer 503 (or 404 M_UNRECOGNIZED — pick one, document); test it.
## Deferred (record, do not implement): N-1 per-host cap keyed on attacker-asserted client_uri host (DoS of a real host's registrations for 30 days; fix: key on (client_host, created_from_ip) after trusted-proxy follow-up, or evict oldest pending per host; add "bulk reject by host" to follow-up #2) — add to follow-ups.md + ADR-033 gate items. INFO items: no action (I-10 confirm text with `"` in name: optional cheap fix by escaping/quoting; I-11 'host-bound' badge wording: optional rename to 'host-matches client_uri').
