# Code Review Findings — oidc-env-optional-bootstrap (Cycle 1)

## Cycle 0 findings: alle 6 behoben ✅

## Neue Findings

### MAJOR-1 — JWKS URI Feld behauptet Discovery-Fallback der nicht existiert; leeres Feld → permanent 401

Das HEEx-Template in `bootstrap_live.ex` kommentiert: "when blank, JwksCache derives it via OIDC discovery". Das ist falsch. Weder `jwks_cache.ex` noch `OidcPlug` implementieren `.well-known/openid-configuration` Discovery. Ein Operator der das Feld leer lässt (mit dem falschen Versprechen) hat `jwks_uri = nil` → `JwksCache` gibt `{:ok, []}` zurück → keine Keys → alle Tokens rejected, für immer.

**Fix:** JWKS URI als required markieren wenn `NEBU_OIDC_JWKS_URI` nicht gesetzt ist (gleiche Behandlung wie M-2 Audience). Irreführenden Discovery-Kommentar entfernen.

### MINOR-1 — `do_complete_bootstrap/2` hat keinen server-seitigen Audience-Guard

M-2 Check existiert nur in `save_oidc/2`. Ein alter Bootstrap-Draft ohne Audience kann `complete_bootstrap` trotzdem durchlaufen → fail-closed (401), aber kein Fehler beim Abschluss.
Fix: In `do_complete_bootstrap/2` prüfen ob weder env noch draft eine audience hat, und dann nicht `bootstrap_completed` setzen.

## Verdict: CHANGES REQUESTED — Cycle 2
