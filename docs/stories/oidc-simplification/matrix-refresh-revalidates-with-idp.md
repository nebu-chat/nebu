---
story_id: matrix-refresh-revalidates-with-idp
title: Matrix /refresh verlängert nur lokal — muss wie Admin-Refresh den IdP re-kontaktieren
type: security-fix
severity: high
epic: oidc-simplification
status: done
security_review: required
created: 2026-07-01
depends_on: fix-matrix-login-missing-refresh-token
---

## Summary

**Der eigentliche Grund für Phils Meldung — Nebu darf als Homeserver seine Rolle als OIDC-Resource-
Server nicht verlieren.** `POST /_matrix/client/v3/refresh` (`http_public.ex:531-573`) rotiert heute
ausschließlich Nebus eigenes opakes Token-Paar — es kontaktiert den externen OIDC-Provider **nie**,
verifiziert keine frischen Claims und erkennt keine Deprovisionierung/Rollenänderung während der
laufenden Session. Der beim Login eingefangene OIDC-Refresh-Token liegt in `matrix_sessions`, wird
bei jeder Rotation nur unverändert durchgereicht (`matrix_session_store.ex` `rotate_tokens/1`, Zeile
179: `enc_oidc_rt = new_oidc_rt || old_enc_oidc_rt` — `new_oidc_rt` wird nirgends geliefert) und **nie
eingelöst**.

Der **Admin**-Refresh-Pfad (`admin/auth.ex:162-229`, `exchange_refresh_token/1`) macht es korrekt:
entschlüsselt den gespeicherten OIDC-RT, tauscht ihn am Token-Endpoint des IdP (`grant_type=
refresh_token`), verifiziert das neue `id_token` via `OidcPlug.verify_token/2`, re-evaluiert das
Admin-Gate auf den frischen Claims — ein deprovisionierter Admin verliert den Zugriff spätestens beim
nächsten Refresh. Matrix macht keines davon. Diese Story bringt den Matrix-Pfad auf denselben Stand.

**Vorgeschichte:** Setzt auf `fix-matrix-login-missing-refresh-token` auf — ohne einen tatsächlich
gelieferten `refresh_token` gibt es nichts zu re-validieren. Beide Stories zusammen schließen den
Matrix-Refresh-Kreis vollständig.

## Motivation

Gehört ins Epic, weil dieselbe Klasse von Problem wie überall sonst hier: Zwei parallele
Implementierungen (Admin/Matrix) derselben Aufgabe — "OIDC-Refresh-Token beim IdP einlösen,
`id_token` neu verifizieren" — existieren unabhängig, eine korrekt, eine nicht. **Empfehlung dieser
Architektur-Planung:** den IdP-Token-Exchange (HTTP-POST `grant_type=refresh_token` + Antwort-Parsing
+ `OidcPlug.verify_token`-Aufruf) als gemeinsame Funktion unter `Nebu.Web` extrahieren (Kandidat:
`Nebu.Web.OidcTokenExchange.refresh/2`), damit `Nebu.Admin.Auth.exchange_refresh_token/1` (bestehend,
korrekt) und der neue Matrix-Pfad **dieselbe** Implementierung nutzen — statt eine zweite Kopie der
ersten zu bauen. Genau das Muster aus `centralize-scope-resolution`/`centralize-claim-resolution`,
nur für den Refresh-Grant.

## Acceptance Criteria

### AC1 — Matrix-Refresh kontaktiert den IdP-Token-Endpoint

**Given** `POST /_matrix/client/v3/refresh` mit einem bekannten, nicht abgelaufenen opaken
Refresh-Token,
**When** die Session in `matrix_sessions` einen gespeicherten `oidc_refresh_token` hat,
**Then** wird dieser entschlüsselt und am IdP-Token-Endpoint via `grant_type=refresh_token`
eingelöst — **vor** jeder Rotation der Nebu-eigenen opaken Tokens. Bei Erfolg: das zurückgegebene
`id_token` wird via `OidcPlug.verify_token/2` verifiziert (Signatur/alg/iss/aud/exp).

### AC2 — Fehlgeschlagener IdP-Refresh invalidiert die Session (fail-closed)

**Given** der IdP lehnt den Refresh ab (Token abgelaufen/revoked/Netzwerkfehler) ODER das neu
verifizierte `id_token` zeigt eine Deprovisionierung an (analog zum Admin-Gate-Recheck — für Matrix:
z.B. `is_active`-Status oder die vom Login-Pfad genutzte Deprovisionierungs-Prüfung),
**When** das passiert,
**Then** antwortet `/refresh` mit `401 M_UNKNOWN_TOKEN` — **und** die betroffene opake Session wird
invalidiert (nicht einfach nur die Antwort verweigert, während die Session-Row unverändert
weiterlebt und beim nächsten Versuch erneut geprüft werden müsste). Kein Fallback auf eine rein
lokale Verlängerung, wenn der IdP-Kontakt fehlschlägt.

### AC3 — Erfolgreicher Refresh: Lifetime kommt vom frischen `id_token`, nicht von Nebus 8h-Pauschale

**Given** ein erfolgreicher IdP-Refresh (AC1),
**When** die neuen opaken Matrix-Tokens gemintet werden,
**Then** wird ihre `expires_at` aus derselben Berechnung wie beim Login (`min(fresh_id_token.exp,
now + ceiling)`) abgeleitet — **dieselbe Funktion**, kein separater Code-Pfad. Das stellt automatisch
die Symmetrie zwischen Login und Refresh wieder her, die der Oracle als Asymmetrie markiert hatte —
ohne dass die Lifetime-Policy vom IdP entkoppelt werden muss (der IdP wird ja jetzt bei jedem Refresh
tatsächlich gefragt).

### AC4 — Rotierter OIDC-Refresh-Token wird gespeichert (falls der IdP einen neuen liefert)

**Given** der IdP liefert bei der Exchange einen neuen `refresh_token` (manche IdPs rotieren, manche
nicht),
**When** die Matrix-Session-Row aktualisiert wird,
**Then** wird der neue, verschlüsselte OIDC-RT gespeichert (Muster: Admin-Seite
`rotate_refresh_token/2`) — liefert der IdP keinen neuen, bleibt der bisherige (verschlüsselte)
erhalten.

### AC5 — Gemeinsame Token-Exchange-Funktion (Architektur-Empfehlung, kein Veto)

**Given** die bestehende `Nebu.Admin.Auth.exchange_refresh_token/1`,
**When** der Matrix-Pfad implementiert wird,
**Then** wird die IdP-Token-Exchange-Logik (HTTP-POST + Parsing + `verify_token`-Aufruf) in ein
gemeinsames `Nebu.Web`-Modul extrahiert und von BEIDEN Domains genutzt — keine zweite,
unabhängige Kopie derselben ~20 Zeilen. Test-Seams (`:admin_oidc_refresh_override`,
`:matrix_oidc_refresh_override`) bleiben pro Domain getrennt, da Login-Kontext (Audience,
Client-Config) unterschiedlich sein kann.

### AC6 — Regressionstests

- **Happy Path:** Refresh mit gültigem OIDC-RT → IdP liefert frisches `id_token` (Test-Seam) → neue
  Matrix-Tokens mit korrekter, vom `id_token.exp` abgeleiteter Lifetime.
- **IdP lehnt ab:** Refresh mit einem OIDC-RT, den der Test-Seam als "vom IdP abgelehnt" simuliert →
  `401 M_UNKNOWN_TOKEN`, Session danach nicht mehr verwendbar (AC2).
- **Deprovisionierung:** Frisches `id_token` zeigt einen deaktivierten Nutzer an → `401
  M_UNKNOWN_TOKEN`, Session invalidiert (Kill-Switch-Parität mit dem bestehenden
  Deactivation-Pattern für andere Session-Typen).
- **OIDC-RT-Rotation:** IdP liefert neuen OIDC-RT → gespeicherter, verschlüsselter Wert ändert sich;
  liefert keinen neuen → alter bleibt.
- **Bestehende Tests** (`login_refresh_test.exs`, Happy-Path-Fälle mit langem `id_token.exp`) bleiben
  grün.

## Implementation Map

### Neue/zu ändernde Dateien
- `server/lib/nebu/web/oidc_token_exchange.ex` (neu, falls AC5 umgesetzt) ODER die Exchange-Logik
  bleibt vorerst bei Admin und Matrix ruft sie über eine neue `Nebu.Web`-Funktion auf — Dev-Agent
  entscheidet die konkrete Modul-Grenze, AC5 ist das Ziel, nicht die exakte Datei.
- `server/lib/nebu/matrix/http_public.ex` — `do_refresh_with/2` (Zeile ~531-573)
- `server/lib/nebu/matrix/session/matrix_session_store.ex` — `rotate_tokens/1`, damit ein
  tatsächlich rotierter OIDC-RT durchgereicht werden kann (heute nur Carry-over)
- `server/lib/nebu/admin/auth.ex` — `exchange_refresh_token/1` delegiert an die gemeinsame Funktion
  (AC5), falls extrahiert
- `server/test/nebu/matrix/login_refresh_test.exs` — AC6

## Security Considerations

- `security_review: required`, `severity: high` — dies ist die zentrale Sicherheitskorrektur des
  Refresh-Themas in diesem Epic: schließt eine Deprovisionierungs-Erkennungslücke von "bis zu 8h" auf
  "nächster Refresh-Versuch" (analog zur Admin-Seite).
- SEC Gate 1 Fokus:
  - AC2 fail-closed-Verhalten: kein Pfad darf bei fehlgeschlagenem IdP-Kontakt auf die ALTE, rein
    lokale Verlängerung zurückfallen — das wäre ein Silent-Downgrade auf das aktuelle, unsichere
    Verhalten.
  - Der neue IdP-Token-Exchange-Aufruf für Matrix nutzt dieselben TLS-Verifikations-Anforderungen wie
    der bestehende Admin-Pfad (kein `:httpc`-Fallstrick aus MEMORY-Pattern "httpc empty-ssl-opts").
  - `OidcPlug.verify_token/2`-Wiederverwendung stellt sicher, dass Alg-Allowlist/iss/aud-Prüfung für
    den Refresh-Pfad identisch zum Login-Pfad ist — keine zweite, schwächere Verify-Implementierung.
  - Race-Bedingungen (Session wird zwischen Lookup und Rotate revoked) — bestehendes Verhalten
    (`:error` → 401) bleibt erhalten, jetzt zusätzlich für den neuen IdP-Kontakt-Schritt geprüft.

## Definition of Done

- [ ] Matrix `/refresh` kontaktiert den IdP-Token-Endpoint vor jeder Rotation (AC1)
- [ ] Fehlgeschlagener IdP-Refresh/Deprovisionierung → 401 + Session invalidiert, kein lokaler
      Fallback (AC2)
- [ ] Lifetime nach erfolgreichem Refresh vom frischen `id_token.exp` abgeleitet, symmetrisch zum
      Login (AC3)
- [ ] Rotierter OIDC-RT wird gespeichert, falls vom IdP geliefert (AC4)
- [ ] Gemeinsame Token-Exchange-Funktion für Admin + Matrix (AC5) oder begründete Abweichung
- [ ] Alle Regressionstests (AC6) grün
- [ ] Security Review (Kassandra) — CLEAN
- [ ] Arc42 `08-concepts.md` Refresh-Abschnitt aktualisiert (Matrix-Refresh jetzt IdP-re-validierend,
      Resource-Server-Posture-Lücke geschlossen)
