# Test Quality Review — oidc-session-refresh (2026-05-27)

## MAJOR Findings

### MAJOR-1 — AC8 ohne automatisierten Test
AC8 ("Session bleibt 8h aktiv bei kurzen Keycloak-Token-Lifetimes") hat keine Testabdeckung.
Empfehlung: Godog-Szenario `AC8_LongSession_MultipleRefreshCycles` mit 3–5 Refresh-Zyklen
(Keycloak-Lifetime 30s); oder AC8 explizit als "exploratory only" dokumentieren.

### MAJOR-2 — AC5-Step ist dauerhafter Stub
`gateway/test/integration/matrix_session_refresh_steps_test.go` Step
`iHaveAnOpaqueAccessTokenThatIsAlreadyExpiredInTheDatabase()` gibt immer `return fmt.Errorf(...)` —
AC5 kann selbst nach vollständiger Implementation nie grün werden.
Fix: echten DB-Setup via `store.Create()` mit `ExpiresAt: time.Now().Add(-2*time.Second)`.

## MINOR Findings

### MINOR-1 — Package-Import-Pfad in matrix_session_store_test.go prüfen
Import `github.com/nebu/nebu/internal/db` — gegen go.mod verifizieren.

### MINOR-2 — Shared mutable globals (akzeptabel per sc.Before()-Reset)
Kein unmittelbarer Handlungsbedarf; bekanntes Muster im Projekt.

### MINOR-3 — `withAuth`-Parameter in `doPostRefresh` ungenutzt
Entweder implementieren oder entfernen.

## INFO Findings

### INFO-1 — 400-Szenarien ohne errcode-Assertion (M_BAD_JSON / M_MISSING_PARAM)
### INFO-2 — AC2-Szenario prüft `refresh_token` in Response nicht explizit

## Score
78/100 — Approve with changes. MAJOR-1 und MAJOR-2 müssen vor Merge adressiert werden.
