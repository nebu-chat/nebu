---
story_id: centralize-claim-resolution
title: Zentrale OIDC-Claim-Auflösung in Nebu.Web.OidcClaims
type: refactor
severity: medium
epic: oidc-simplification
status: done
security_review: required
created: 2026-07-01
---

## Summary

Führt `Nebu.Web.OidcClaims` als **einziges** Modul für Claim-Traversal ein — verschiebt den
rekursiven Claim-Walker (`claim_value_matches?/2`, `flatten_discovered_claims/2`, heute in
`server/lib/nebu/admin/auth.ex:1108-1134` und `:1513-1536`) aus der Admin-Domain in die
Shared-Infra (`Nebu.Web`), damit er von Bootstrap-Claim-Picker UND dem Admin-Group-Gate aus derselben
Quelle genutzt wird. **Reine Verschiebung, keine Verhaltensänderung** — das ist bewusst von der
eigentlichen Sicherheits-Korrektur (Story `scope-admin-claim-to-path`) getrennt, damit diese als
kleiner, klar bewertbarer Diff auf einem bereits konsolidierten Modul aufsetzen kann.

**ADR-Referenz:** ADR-020, ADR-018 (inline Elixir-Funktionen, kein neues Schema).

## Motivation

`admin_claim?/1` und `extract_discovered_claims/1` sind zwei unabhängige rekursive Claim-Traversal-
Implementierungen innerhalb derselben Datei (`admin/auth.ex`), die denselben Claims-Baum
unterschiedlich durchlaufen: `admin_claim?/1` matched Werte, `extract_discovered_claims/1` flacht zu
Dot-Path-Keys ab. Beide wurden **heute** im selben Bugfix (`bugfix-nested-oidc-claim-support`,
`83ea6e69`) von flach auf rekursiv erweitert — an zwei Stellen, statt an einer. Zusammenführen
reduziert das Risiko, dass eine künftige Änderung (z.B. Tiefenbegrenzung, neue Claim-Form) nur an
einer der beiden Stellen ankommt.

`Nebu.Matrix.UserId.from_claims/2` (user_id.ex:17-54) ist bereits korrekt zentral — beide Domains
rufen dieselbe Funktion. Diese Story rührt sie nicht an, sondern zieht sie unter dieselbe
`Nebu.Web`-Dachmarke, damit langfristig ALLE OIDC-Claim-Logik an einem Ort lebt. **Falls das Team
entscheidet, `UserId.from_claims/2` unverändert an seinem Ort zu lassen (Matrix-Domain-Eigentum ist
für die Matrix-User-ID-Semantik plausibel), ist das akzeptabel — Pflicht ist nur, dass der
Claim-*Walker* (nicht der User-ID-*Mapper*) zentral liegt.**

## Non-Goals

- Kein Fix des Any-Key-Scan-Risikos (Kassandra MEDIUM, siehe Story `scope-admin-claim-to-path`) —
  diese Story verschiebt die Logik unverändert.
- Keine Änderung an `UserId.from_claims/2`s Fallback-Kette (configured claim → preferred_username →
  name → sub).

## Acceptance Criteria

### AC1 — `Nebu.Web.OidcClaims` Modul

**Given** ein neues Modul `server/lib/nebu/web/oidc_claims.ex`,
**When** es implementiert wird,
**Then** exponiert es (aus `admin/auth.ex` verschoben, Signatur beibehalten):
- `claim_value_matches?(target, value) :: boolean()` — rekursiver Wert-Matcher, beliebige Tiefe
- `flatten_discovered_claims(claims, prefix) :: [{dot_path_key, value}]` — für den Bootstrap-Picker

### AC2 — Admin delegiert, keine Verhaltensänderung

**Given** `Nebu.Admin.Auth.admin_claim?/1` und `extract_discovered_claims/1`,
**When** sie auf `Nebu.Web.OidcClaims` umgestellt werden,
**Then** ist das Verhalten **byte-identisch** zum Ist-Zustand (inkl. Nested-Claim-Support aus
`83ea6e69`) — bestätigt durch die volle bestehende Testsuite (`admin_oidc_login_test.exs`,
`auth_test.exs`) ohne Anpassung der Erwartungswerte.

### AC3 — Keine neue Rekursions-Tiefenbegrenzung ohne Grund

**Given** die bestehende, dokumentierte Begründung (signierter Token als Trust-Boundary, kein
ungebundenes Wachstum ohne IdP-Kompromittierung),
**When** das Modul verschoben wird,
**Then** bleibt die Begründung als Code-Kommentar erhalten (nicht implizit verloren gehen beim
Verschieben in eine neue Datei).

## Implementation Map

### Neue Dateien
- `server/lib/nebu/web/oidc_claims.ex`
- `server/test/nebu/web/oidc_claims_test.exs` (verschobene/gespiegelte Testfälle aus `auth_test.exs`)

### Zu ändernde Dateien
- `server/lib/nebu/admin/auth.ex` — `admin_claim?/1`, `extract_discovered_claims/1` delegieren

## Security Considerations

- Reine Verschiebung — kein neuer Findings-Typ erwartet. SEC Gate 1 verifiziert explizit
  Verhaltens-Äquivalenz (AC2), nicht neue Logik.
- `security_review: required`, da Datei im Auth-Trust-Boundary-Pfad liegt (Standardregel dieses
  Epics), auch wenn diese Story selbst kein neues Risiko einführt.

## Definition of Done

- [x] `Nebu.Web.OidcClaims` implementiert
- [x] `admin/auth.ex` delegiert, keine doppelte Logik mehr in der Datei
- [x] Bestehende Tests unverändert grün (keine Erwartungswert-Anpassungen nötig)
- [x] Security Review (Kassandra) — CLEAN (Verhaltens-Äquivalenz bestätigt)
- [x] Diese Story ist Voraussetzung für `scope-admin-claim-to-path`
