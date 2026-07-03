# Security review classification

No story file exists (bug-mode, no --epic). classify_story.py's SECURITY_PATHS list is
stale (references removed gateway/ Go paths from before the full-elixir-stack
migration). Manually classified against the current
skills/nebu-conventions/security-rules/SKILL.md auto-classification rules instead:

Diff touches:
- server/test/nebu/admin/bootstrap_admin_session_identity_test.exs (test-only, admin
  bootstrap session identity — admin-domain-ADJACENT but a test file, not production
  auth code)
- server/lib/nebu/matrix/event_dispatcher/server.ex — run_post_login_provisioning/2,
  the fire-and-forget auto-join/personal-room provisioning triggered immediately after
  every Matrix login. NOT an exact match for the explicit
  server/lib/nebu/matrix/{signature,permissions,session}/ auto-required subpaths, but
  it executes on the authenticated-login critical path and was originally described in
  the bug ticket as "touches only a test file, no production code" — which is now
  inaccurated given the widened scope (2nd warning found in production code).

Per the user's explicit fallback instruction ("if it comes back required anyway
because it's admin-domain-adjacent, run it"): running security-review rather than
skipping, since scope expanded into production auth/session-adjacent code beyond what
was originally assessed as test-file-only.
