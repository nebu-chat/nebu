## Session — centralize-scope-resolution (epic oidc-simplification), SEC Gate 1

**Scope:** staged diff. New `Nebu.Web.OidcScopes` (single scope resolver + validator); SsoLogin/Admin.Auth become thin delegates; `union_scopes/2` + `Nebu.Matrix.matrix_oidc_extra_scopes/0` facade removed; controllers route through the ONE validator; OidcConfig ETS/:pg cache extended with 4 scope keys; db.upsert_server_config gains a read-side cache-refresh hook.

**Finding summary:** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW, 1 INFO (stale docstring auth.ex:272).

**Verdict:** APPROVED / CLEAN. Net security improvement.

**Key verifications:**
- Pattern #76 (`$` vs `\z`) REMEDIATED AT SOURCE — regex uses `\z`; both local copies DELETED not re-anchored; grep confirmed 0 `$/`-anchored scope validators remain; AC7 test names the distinction.
- AC3 cross-client `offline_access` graft CLOSED — `union_scopes/2` gone, facade gone (0 lib callers grep-verified), both-direction + union-gone regression tests present.
- RLS: upsert write SQL byte-unchanged, only read-side refresh added → no new write cap.
- No hardcoded scope literal in any added line (grep clean). Sink = URI.encode_query (defence #2).

**New patterns discovered:** review-technique note — for a story that fixes a known recurring pattern, verify old copies are DELETED (not silently re-anchored/duplicated) and grep for zero remaining instances, rather than only confirming the new central copy is correct. (Curated to cross-cutting agent-memory.)

**Accepted risks this session:** none.

**Follow-up:** I-1 doc cleanup at auth.ex:272 (non-blocking, ride any future auth.ex touch).
