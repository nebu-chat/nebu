## Summary

**Von Phil auf einer Keycloak-Installation live gemeldet (2026-07-01):** Obwohl
`admin_oidc_refresh_mode = "offline"` konfiguriert ist (Admin-Login fordert `offline_access` an,
Silent-Refresh ist implementiert), läuft die Admin-Session in der Praxis nach ~5 Minuten ab.

**Root Cause bestätigt (Code-Trace, nicht spekulativ):** Der Silent-Refresh-Mechanismus
(`Nebu.Admin.Auth.fetch_current_user/2`, `auth.ex:119-160`) ist ein **HTTP-Plug** — er läuft nur in
der `:browser`-Pipeline (`router.ex:70-83`) bei jedem neuen HTTP-Request. Die drei verbleibenden
Admin-LiveViews (Dashboard, AuditLog, Bootstrap, `router.ex:203-206`) laufen über eine **persistente
WebSocket-Verbindung** — solange der Operator im Dashboard bleibt, findet **kein neuer HTTP-Request**
statt, also läuft `fetch_current_user/2` nie, also nie ein Refresh. Das ist die bereits dokumentierte
"Known limitation" in `docs/architecture/08-concepts.md` ("the refresh fires on HTTP round-trips,
not over the persistent LiveView websocket") — bisher als Randnotiz, jetzt als reproduzierter Bug.

**Warum es bei Keycloak auffällt, bei Dex (Dev-Setup) nicht:** `session_exp = min(id_token.exp,
now+8h)` (`session_config.ex`). Das Dev-Setup (`dev/dex/config.yaml:19`) setzt `idTokens: 24h` —
mit 24h ID-Token-Lifetime bleibt genug Zeit für gelegentliche HTTP-Requests (Seiten-Reload etc.), die
den Refresh anstoßen. Keycloaks Standard-Realm-Einstellung für die ID/Access-Token-Lifetime liegt bei
5 Minuten — ohne einen HTTP-Request innerhalb dieses Fensters läuft die Session ab, bevor überhaupt
die Chance zum Silent-Refresh besteht.

**Matrix-Sessions sind NICHT betroffen** (separater Mechanismus, clientgesteuert via
`POST /_matrix/client/v3/refresh` — der Matrix-Client entscheidet selbst, wann er refresht; das ist
Matrix-Spec-konformes Verhalten, kein Nebu-Bug). Diese Story behandelt ausschließlich die
Admin-LiveView-Sessions.

## Motivation

Dieser Bug macht `admin_oidc_refresh_mode = "offline"` für jeden Operator, der überwiegend im
Dashboard/AuditLog sitzt, **wirkungslos** — genau die IdP-Klasse (kurze Token-Lifetime, Keycloak
statt Dex), für die Silent-Refresh eigentlich gebraucht wird, ist die, bei der er nicht greift. Gehört
in dieses Epic, weil die Ursache (Refresh-Logik nur an einer Stelle im HTTP-Pfad verdrahtet, nicht an
der WebSocket-Stelle) dieselbe "Logik existiert nur für einen von mehreren Zugriffspfaden"-Klasse von
Bug ist wie die anderen Epic-Stories.

## Non-Goals

- Kein Fix am Matrix-`/refresh`-Verhalten — das ist clientgesteuert per Matrix-Spec, funktioniert wie
  vorgesehen.
- Keine Änderung an der 8h-Session-Obergrenze (`now+8h`) selbst.

## Acceptance Criteria

### AC1 — Reproduktion vor dem Fix (ATDD-Basis)

**Given** `admin_oidc_refresh_mode = "offline"`, ein IdP mit kurzer ID-Token-Lifetime (Test-Seam:
Token mit `exp` in 90s simulieren, nicht real gegen Keycloak),
**When** ein Operator eine Admin-LiveView öffnet (Dashboard) und **keinen** weiteren HTTP-Request
auslöst,
**Then** demonstriert ein Test, dass die Session nach Ablauf des `id_token.exp` als abgelaufen gilt,
OBWOHL der Operator die LiveView durchgehend geöffnet hält — dieser Test ist RED vor dem Fix und
GREEN danach, kein reiner Regressions-Pinning-Test.

### AC2 — Idle-LiveView-Session überlebt bei gültigem Refresh-Token

**Given** eine offene Admin-LiveView (Dashboard/AuditLog/Bootstrap), `admin_oidc_refresh_mode =
"offline"`, ein gültiger Refresh-Token in der Session,
**When** die konfigurierte ID-Token-Lifetime abläuft, während der Operator ausschließlich über die
LiveView-WebSocket-Verbindung aktiv ist (kein manueller Reload, kein neuer HTTP-Request),
**Then** bleibt die Session bis `session_exp` (bzw. bis zum Ablauf des Refresh-Tokens) gültig — der
Operator wird NICHT ausgeloggt, solange er die Seite offen hält und der Refresh-Token noch gültig ist.

### AC3 — Mechanismus (Empfehlung, kein Veto)

**Empfehlung dieser Architektur-Planung:** Kein neuer serverseitiger Refresh-Mechanismus für
LiveView-Sockets nötig — Phoenix-Session-Cookies können ohnehin nicht über WebSocket gesetzt werden.
Stattdessen: ein leichtgewichtiger clientseitiger Heartbeat (JS-Hook, `phx-hook`), der periodisch
(z.B. alle 60s, deutlich innerhalb des bestehenden 120s-Pre-Expiry-Fensters) einen unsichtbaren
HTTP-Request an einen neuen, minimalen `GET /admin/keepalive`-Endpoint schickt, solange irgendeine
Admin-LiveView im Browser-Tab geöffnet ist. Dieser Request durchläuft die normale `:browser`-Pipeline
→ `fetch_current_user/2` läuft → bestehender Silent-Refresh-Mechanismus greift **unverändert**. Der
Dev-Agent kann bei der Umsetzung begründet abweichen, muss es aber im Story-Update dokumentieren.

### AC4 — Keepalive-Endpoint ist minimal und sicher

**Given** den neuen `GET /admin/keepalive`-Endpoint (falls AC3-Empfehlung umgesetzt wird),
**When** er aufgerufen wird,
**Then** ist er hinter demselben Admin-Auth-Gate wie jede andere `:browser`-Route (`require_admin`
o.ä. via die Pipeline), gibt eine minimale Antwort zurück (kein sensibler Payload, kein zusätzliches
Logging von PII), und triggert **keine** eigene Business-Logik außer dem bereits vorhandenen
`fetch_current_user/2`-Refresh-Plug-Verhalten.

### AC5 — Regressionstest: HTTP-Pfad unverändert

**Given** die bestehende Testsuite (`admin_token_refresh_test.exs`),
**When** der Fix landet,
**Then** bleibt das bestehende HTTP-Plug-Refresh-Verhalten unverändert (dieser Fix ergänzt einen
zweiten Trigger-Pfad, ersetzt den bestehenden nicht).

## Implementation Map

### Neue/zu ändernde Dateien (vorläufig, Dev-Agent verfeinert)
- `server/lib/nebu/admin/router.ex` — neue `GET /admin/keepalive` Route in der `:browser`-Pipeline
- `server/lib/nebu/admin/keepalive_controller.ex` (neu, minimal) — 204/200-No-Content-Handler
- Admin-Layout/JS-Assets (`/admin/static/assets/app.js` o.ä., CSP `script-src 'self'` beachten,
  Muster aus Pattern "Admin CSP script-src 'self' macht Inline-Handler tot") — Heartbeat-Hook
- `server/test/nebu/admin/admin_token_refresh_test.exs` — AC1/AC2/AC5
- `server/test/nebu/admin/admin_keepalive_test.exs` (neu) — AC4

## Security Considerations

- `security_review: required`, `severity: high` — Änderung am Session-/Auth-Trust-Boundary-Pfad.
- SEC Gate 1 Fokus:
  - Der neue Keepalive-Endpoint darf **keine** Bypass-Möglichkeit für den Admin-Auth-Gate schaffen
    (muss innerhalb derselben Pipeline/Plug-Kette liegen wie jede andere Admin-Route).
  - Kein Information-Leak über den Keepalive-Response-Body.
  - Kein DoS-Vektor durch das Heartbeat-Intervall (60s ist harmlos; falls das Intervall konfigurierbar
    wird, unteres Limit setzen, damit kein Client absichtlich im Sekundentakt pollt).
  - CSP-Konformität des neuen JS-Hooks (`script-src 'self'`, kein `unsafe-inline` — Pattern aus
    device-management S4 AC3 beachten).
  - Der Fix darf den bestehenden `admin_oidc_refresh_mode = "online"`-Pfad (kein Refresh-Token
    vorhanden) nicht beeinträchtigen — Keepalive-Request ohne Refresh-Token darf einfach zum
    normalen Ablauf-Verhalten führen, keinen Fehler werfen.
