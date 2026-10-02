(full report from code-review agent a3ebf1561f935ef2e — see conversation/task notification for verbatim text)

Verdict on special-scrutiny items: both dev-agent test-literal corrections (trailing-slash fixture,
AC5 unreachable-host literal) are LEGITIMATE, not test-weakening. Migration 000035 content VERIFIED
CORRECT against 000020's actual allowlist.

9 MAJOR findings, most sharing one root cause: rewriting/synthesizing response fields to compensate
for an internally-addressed IdP is fundamentally fragile (breaks `iss` validation, requires a
hand-maintained per-IdP field allowlist, fabricates unreachable endpoint URLs, still leaks on the
`auth_issuer` route and the Admin-UI login redirect, no input validation on the operator-supplied URL).

Reviewer's recommendation: reconsider the architecture — configure the IdP's OWN issuer as the public
URL (dex/Keycloak/etc. support this independently of their internal bind/listen address) and give Nebu
a way to reach that same logical issuer at an internal network address purely for its own outbound
calls, rather than rewriting response bodies. This would resolve MAJOR-4/5/7 by construction and shrink
MAJOR-1/2 to just the MSC2965 required-field synthesis (registration_endpoint/response_modes_supported/
revocation_endpoint), which is still needed regardless of the architecture chosen.

Escalated to user for direction before further dev-story cycles (architectural decision, not a
patch-in-place fix).
