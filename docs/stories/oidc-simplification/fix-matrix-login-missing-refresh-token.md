---
story_id: fix-matrix-login-missing-refresh-token
title: Element bekommt keinen Refresh-Token von /login — "Unable to refresh token" trotz offline_access
type: bugfix
severity: high
epic: oidc-simplification
status: done
security_review: required
created: 2026-07-01
---

## Summary

**Von Phil live gemeldet (2026-07-01), präzisiert nach Element-Fehlermeldung:** Element zeigt
`"Unable to refresh token - no refresh token or refresh function"`. Element bekommt also von
`POST /login` schlicht **keinen** `refresh_token` zurück — das ist die unmittelbare Ursache des
5-Minuten-Logouts, kein Lifetime-Berechnungsproblem.

**Ausdrückliche Vorgabe von Phil: keine Architektur-Änderung, gezielter Fix.** Diese Story ersetzt
die vorherige, zu weit gefasste Planung (Entkopplung der Lifetime von `id_token.exp`) — diese wurde
verworfen, weil sie voraussetzt, dass Nebu bereits verlässlich einen Refresh-Token besitzt und
nutzt. Das ist genau der Teil, der hier zuerst gefixt wird.

**Bestätigter Code-Pfad (kein Architektur-Fix, reine Diagnose+Fix):**

1. `matrix_oidc_refresh_mode = "offline"` (Default) → `scope_list/0` (`sso_login.ex:429-438`) hängt
   `offline_access` an den Scope-String an. Die Anfrage an den IdP ist korrekt.
2. Die Token-Response vom IdP wird geparst in `extract_id_token`-artigen Funktionen
   (`sso_login.ex:574-591`) — fehlt `refresh_token` im IdP-Response, wird das **kommentarlos** zu
   `nil`. **Kein Log an dieser Stelle.**
3. `respond_login` (`http_public.ex:376-439`, "AC7 fallback") degradiert bei `oidc_refresh_token ==
   nil` auf eine reine JWT-Antwort ohne `refresh_token`/`expires_in_ms` — **nur ein WARNING-Log**
   (`:416-420`), keine strukturierte, diagnosefähige Information darüber, WARUM der IdP keinen
   Refresh-Token geliefert hat.

**Wahrscheinlichste Ursache (zu verifizieren, nicht anzunehmen):** Der Keycloak-Client, den Nebu für
den Matrix-Login nutzt, ist nicht für "Offline Access" (bzw. das entsprechende Client-Scope/-Consent)
konfiguriert — Keycloak ignoriert dann die angeforderte `offline_access`-Scope und liefert keinen
Refresh-Token, ohne das im Response als Fehler zu kennzeichnen (OAuth2-konformes Verhalten: der Scope
wird einfach nicht gewährt). **Das wäre eine IdP-seitige Konfigurationsursache, keine Nebu-Codeursache**
— aber das muss diese Story zweifelsfrei klären, nicht vermuten.

## Non-Goals (ausdrücklich von Phil ausgeschlossen für diese Story)

- **Kein Umbau des Matrix-`/refresh`-Mechanismus dahin, dass er den IdP-Token-Endpoint kontaktiert**
  (das täte der Admin-Refresh-Pfad bereits — Matrix tut es nicht, siehe unten "Zurückgestellte
  Beobachtung"). Das wäre eine echte Architektur-Änderung und explizit nicht Teil dieser Story.
- Keine Änderung an `session_expires_at/1`s Lifetime-Berechnung.
- Keine Änderung am Admin-Refresh-Mechanismus.

## Acceptance Criteria

### AC1 — Root-Cause zweifelsfrei bestimmt (Diagnose vor Fix)

**Given** eine Testumgebung mit Keycloak (nicht Dex — der Bug ist Keycloak-spezifisch beobachtet),
**When** ein Matrix-Login mit `refresh_token: true` und `matrix_oidc_refresh_mode = "offline"`
durchgeführt wird,
**Then** wird eindeutig festgestellt UND dokumentiert, WARUM `refresh_token` in der IdP-Token-Response
fehlt — eine der folgenden (nicht mehrere gleichzeitig als Vermutung stehen lassen):
  (a) Keycloak-Client fehlt "Offline Access"-Capability/Scope (IdP-Konfigurationsproblem, außerhalb
      des Nebu-Codes) → Fix ist dann NUR Diagnose-Verbesserung (AC2), kein Code-Verhaltensfix nötig;
  (b) Nebu sendet den `offline_access`-Scope in dieser Konfiguration tatsächlich NICHT (Code-Bug in
      der Scope-Konstruktion/Config-Lesung) → Fix ist der eigentliche Bug;
  (c) Nebu verarbeitet eine vorhandene IdP-Response mit `refresh_token` fehlerhaft (Parsing-Bug) →
      Fix ist der eigentliche Bug.
Reproduktion via Test-Fixture (simulierte Keycloak-Token-Response ohne `refresh_token`, trotz
angeforderter `offline_access`-Scope) ist ausreichend — kein Live-Keycloak-Zugriff nötig für den
automatisierten Test, aber Phil sollte falls möglich gegen seine echte Keycloak-Instanz gegenchecken.

### AC2 — Fehlender Refresh-Token ist laut und diagnosefähig, nicht mehr stumm

**Given** der IdP liefert trotz angeforderter `offline_access`-Scope keinen `refresh_token`,
**When** `respond_login` in den AC7-Fallback geht,
**Then** wird das Ereignis so geloggt, dass ein Operator OHNE Code-Lesen die wahrscheinliche Ursache
erkennt (analog zur bereits vorhandenen Admin-Seite: `admin/auth.ex` `store_refresh_token/2`-Fallback
loggt bereits `"admin login: no OIDC refresh token returned — ... ensure the IdP grants
offline_access to the admin client"` — Matrix-Seite bekommt eine äquivalente, ebenso konkrete
Meldung). Log-Level mindestens WARNING (wie heute), aber mit demselben Informationsgehalt wie die
Admin-Seite.

### AC3 — Falls (b) oder (c) aus AC1: der eigentliche Code-Bug ist gefixt

**Given** AC1 identifiziert einen tatsächlichen Nebu-Code-Bug (nicht nur IdP-Konfiguration),
**When** der Fix implementiert wird,
**Then** liefert `POST /login` mit `refresh_token: true` und korrekt konfiguriertem
`matrix_oidc_refresh_mode = "offline"` zuverlässig `refresh_token` + `expires_in_ms`, sofern der IdP
grundsätzlich in der Lage ist, einen Refresh-Token auszustellen.

### AC4 — Regressionstest für den "requested-but-not-granted"-Fall

**Given** eine simulierte IdP-Response, die `offline_access` NICHT im `scope`-Feld der Antwort
bestätigt bzw. keinen `refresh_token` liefert, OBWOHL Nebu ihn angefordert hat (Oracle-Fund: dieser
Fall ist in `login_refresh_test.exs` aktuell NICHT abgedeckt — nur der Fall "Client fordert
`refresh_token` nicht an" ist getestet),
**When** der Login durchläuft,
**Then** degradiert die Antwort korrekt auf die JWT-only-Form (unverändertes Verhalten, jetzt aber
mit Test abgesichert) UND das AC2-Log erscheint.

### AC5 — Bestehende Tests bleiben grün

**Given** `login_refresh_test.exs` (Fälle mit erfolgreichem Refresh-Token-Erhalt),
**When** der Fix landet,
**Then** bleiben diese unverändert grün.

## Implementation Map

### Zu untersuchende/ändernde Dateien
- `server/lib/nebu/matrix/sso_login.ex:429-438` (Scope-Konstruktion), `:574-591`
  (Token-Response-Parsing) — AC1(b)/(c)-Verifikation
- `server/lib/nebu/matrix/http_public.ex:376-439` (`respond_login` AC7-Fallback) — AC2-Log
- `server/test/nebu/matrix/login_refresh_test.exs` — AC4

## Folge-Story (nicht länger zurückgestellt)

Bei der Diagnose wurde festgestellt: Der Matrix-`/refresh`-Endpoint (`http_public.ex:531-573`,
`matrix_session_store.ex` `rotate_tokens/1`) verlängert die Session **rein lokal** — er kontaktiert
den OIDC-Token-Endpoint NICHT erneut. Das war ursprünglich als "später, nicht Teil dieses Fixes"
vorgesehen — **Phil hat klargestellt, dass genau das der eigentliche Anlass seiner Meldung war.**
Der Fix dafür ist jetzt eine eigene Story: `matrix-refresh-revalidates-with-idp`
(`depends_on: fix-matrix-login-missing-refresh-token` — ohne einen tatsächlich gelieferten
Refresh-Token aus dieser Story gibt es dort nichts einzulösen).

## Security Considerations

- `security_review: required`, `severity: high` — betrifft den Matrix-Login-Trust-Boundary-Pfad.
- SEC Gate 1 Fokus: AC2s zusätzliches Logging darf **keine** sensiblen Werte loggen (kein
  Refresh-Token-Inhalt, kein `id_token`-Inhalt — nur strukturierte Metadaten wie "IdP grantete
  offline_access nicht").
- Falls AC1 einen echten Code-Bug identifiziert (AC3): SEC Gate 1 verifiziert, dass der Fix keine
  neue Bedingung schafft, unter der ein Refresh-Token an einen Client geliefert wird, der ihn nicht
  angefordert hat, oder an einen falschen Nutzer.

## Definition of Done

- [x] AC1: Root Cause zweifelsfrei bestimmt und dokumentiert (a/b/c)
- [x] AC2: Diagnosefähiges Log analog zur Admin-Seite
- [x] AC3 (falls zutreffend): Code-Bug gefixt — entfällt, AC1-Ausgang ist (a), kein Code-Bug
- [x] AC4: Regressionstest für "requested-but-not-granted" grün
- [x] AC5: Bestehende Tests unverändert grün
- [x] Security Review (Kassandra) — CLEAN
- [x] Zurückgestellte Beobachtung (Matrix-Refresh kontaktiert IdP nicht) ist dokumentiert, nicht
      verloren — Phil entscheidet separat, ob/wann das angegangen wird

## Dev Agent Record

### Implementation Plan

AC1 (Root-Cause-Diagnose) wurde bereits im ATDD-Schritt (Step 2/3 der Pipeline) abgeschlossen und
bestätigt Ausgang **(a)**: reine IdP-seitige Konfigurationslücke, kein Nebu-Code-Bug.
`Nebu.Web.OidcScopes.resolve_scope(:matrix)` hängt `offline_access` korrekt an, sobald
`matrix_oidc_refresh_mode = "offline"` (Default) — Root-Cause (b) ist damit ausgeschlossen.
`Nebu.Matrix.SsoLogin.extract_id_token/1` parst einen fehlenden `refresh_token` im IdP-Response
spec-konform zu `nil` — Root-Cause (c) ist damit ebenfalls ausgeschlossen. AC3 entfällt folglich.

Der einzige verbleibende Implementierungsschritt war AC2: die bestehende WARNING-Logzeile im AC7-
Fallback von `respond_login/7` (`server/lib/nebu/matrix/http_public.ex`) wurde auf Admin-Seiten-
Parität umformuliert (analog `server/lib/nebu/admin/auth.ex` `store_refresh_token/2`), OHNE
Log-Level, Metadaten (nur `user_id`) oder Kontrollfluss zu verändern:

- Alt: `"matrix login: refresh_token requested but no OIDC refresh token available — returning JWT (verify the IdP grants offline_access)"`
- Neu: `"matrix login: no OIDC refresh token returned — session cannot be silently refreshed; ensure the IdP grants offline_access to the matrix client"`

AC4 wurde bereits von Test-Review (Step 3) als RED-Test in `login_refresh_test.exs` (describe-Block
"POST /login: offline_access requested but IdP grants none (AC2, AC4)") angelegt und ist nach dem
Log-String-Fix GREEN. Eine MINOR-Formatierungsabweichung (fehlende Leerzeile zwischen zwei
`assert`-Anweisungen im selben Testblock) wurde manuell behoben. Ein blanket `mix format`-Lauf
wurde NICHT durchgeführt: das Projekt hat keine `.formatter.exs`, und ein Default-`mix format`
hätte sehr viele unrelated Zeilen umformatiert (verifiziert, dann verworfen via `git checkout --`).
Die optionale Nice-to-have-Verbesserung (id_token-Assertion im SEC-Gate-1-Test) wurde NICHT
umgesetzt — sie hätte eine nicht-triviale Änderung an `mint_login_token/2`'s Signatur und allen
Call-Sites erfordert; laut Story explizit optional und nicht Bedingung für "Done".

### Completion Notes

- AC1: Diagnose bereits vor Dev-Story abgeschlossen (Ausgang (a), siehe ATDD/Test-Review-Kontext).
- AC2: Log-Message-Parität zur Admin-Seite hergestellt — einzige Code-Änderung dieser Story.
- AC3: entfällt (kein Code-Bug identifiziert).
- AC4: Regressionstest bereits vorhanden (Test-Review), jetzt GREEN.
- AC5: Bestehende `login_refresh_test.exs`-Tests unverändert GREEN (13/13 im isolierten Lauf gegen
  den laufenden Dev-Stack via `elixir:1.19-alpine` + `--network=nebu_default`).
- Voller Unit-/Integrationslauf (`make test-integration-elixir`): 1408 Tests, 3 Failures — alle drei
  nachweislich vorbestehend und ursächlich unabhängig von dieser Änderung: (1)
  `Nebu.Admin.AdminStaleRoomsTest` (Test-Isolation/geteilte Rooms zwischen async Tests), (2)
  `Nebu.Web.RegressionSyncLoadTest` (Timeout eines Lasttests, hostabhängig), (3)
  `Nebu.Matrix.MatrixSsoTest` (500 in einem anderen SSO-Testmodul, nicht berührt). Keine der drei
  Failures betrifft `login_refresh_test.exs` oder eine von dieser Story berührte Datei.
- `make test-unit-elixir` (`mix test --warnings-as-errors`, ohne `:integration`): 1171 Tests, 0
  Failures, 2 Skipped. Der Lauf brach danach wegen `--warnings-as-errors` mit einer bereits
  vorbestehenden, nicht mit dieser Story zusammenhängenden Compiler-Warnung ab (unused default arg
  in `test/nebu/admin/bootstrap_admin_session_identity_test.exs:168`, Datei nicht Teil dieser
  Story und von mir nicht verändert).
- Kein anderes lib-File außer `http_public.ex` wurde verändert. `sso_login.ex`, `oidc_scopes.ex`,
  `session_expires_at/1` und der Admin-Refresh-Mechanismus wurden NICHT berührt (Non-Goals
  eingehalten). Kein IdP-kontaktierender `/refresh`-Mechanismus wurde implementiert (das ist die
  Folge-Story `matrix-refresh-revalidates-with-idp`).

## File List

- `server/lib/nebu/matrix/http_public.ex` (modified — AC2 log message text only)
- `server/test/nebu/matrix/login_refresh_test.exs` (modified — cosmetic blank-line fix; AC4 test
  content itself was already staged by Test-Review/ATDD, not authored in this dev-story session)

## Change Log

- 2026-07-01: AC2 log-message parity fix in `respond_login/7`'s AC7 fallback
  (`http_public.ex`), matching the admin-side wording in `admin/auth.ex` `store_refresh_token/2`.
  Cosmetic blank-line fix in `login_refresh_test.exs`. No other implementation files touched.
  `login_refresh_test.exs`: 13/13 passing. Full suite: 1171 unit tests / 0 failures (2 skipped);
  1408 integration tests / 3 pre-existing, unrelated failures.
