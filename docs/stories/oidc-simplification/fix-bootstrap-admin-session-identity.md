---
story_id: fix-bootstrap-admin-session-identity
title: Bootstrap-Completion-Login setzt matrix_user_id nicht — Admin agiert mit rohem sub
type: security-fix
severity: high
epic: oidc-simplification
status: done
security_review: required
created: 2026-07-01
---

## Summary

**Live-Bug, von Phil beim Testen gefunden (2026-07-01).** Direkt nach Abschluss des Bootstrap-Wizards
mintet `Nebu.Admin.Auth.bootstrap_confirm_claim/2` (auth.ex:619-636) die Admin-Session mit einer
**handgebauten, unvollständigen** `user`-Map:

```elixir
user = %{
  "sub" => draft["bootstrap_sub"],
  "email" => draft["bootstrap_email"],
  "admin" => true,
  "session_exp" => ...
}
```

Im Gegensatz dazu setzt `put_current_user/2` (auth.ex:244-268, genutzt vom normalen
`normal_callback/2`) korrekt `"matrix_user_id" => Nebu.Matrix.UserId.from_claims(claims,
server_name())`. Der Bootstrap-Pfad hat **kein** `matrix_user_id` in der Session.

Downstream: `RoomsController.actor_id/1` (rooms_controller.ex:503-509) und
`UsersController.actor_id/1` (users_controller.ex:209-215) fallen beide auf `"sub"` zurück, wenn
`matrix_user_id` fehlt/leer ist:

```elixir
%{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
%{"sub" => sub} when is_binary(sub) -> sub
```

**Konsequenz:** Legt der Operator direkt nach Bootstrap-Abschluss (bevor er sich je über den
Matrix-Client eingeloggt hat) einen Raum über die Admin-UI an, wird der Raum-Creator/1. Mitglied mit
dem rohen OIDC-`sub`-Wert eingetragen statt mit der kanonischen Matrix-User-ID (`@localpart:server`).
Dasselbe gilt für jede admin-initiierte Raum-Mitgliedschafts-Zuordnung in dieser Session.

**Root Cause passt exakt zum Epic-Thema:** Zwei unabhängige Stellen bauen die
`current_user`-Session-Map — dieselbe Duplizierung wie bei Scope- und Claim-Auflösung in den anderen
Epic-Stories.

## Acceptance Criteria

### AC1 — Bootstrap-Completion nutzt denselben Session-Builder wie der normale Login

**Given** `bootstrap_confirm_claim/2` nach erfolgreichem `complete_bootstrap/2`,
**When** die Admin-Session gemintet wird,
**Then** wird sie über **denselben** Code-Pfad wie `normal_callback/2` gebaut (`put_current_user/2`
oder einen gemeinsamen Nachfolger) — **nicht** über eine zweite, separate Map-Konstruktion. Die
Session enthält `"matrix_user_id"`, korrekt via `Nebu.Matrix.UserId.from_claims/2` abgeleitet.

### AC2 — Vollständige verifizierte Claims überleben bis zur Session-Erstellung

**Given** der Bootstrap-Flow stasht heute nur `bootstrap_sub`/`bootstrap_email`/`bootstrap_claims`
(flach kodierte Discovered-Claims, keine vollständige Claims-Map) im Draft,
**When** `bootstrap_confirm_claim/2` die Session mintet,
**Then** stehen ihr genug Information zur Verfügung, um `matrix_user_id` **identisch** zu dem Wert
zu berechnen, den ein anschließender normaler Re-Login derselben Person liefern würde (kein
zusätzlicher Drift zwischen Bootstrap-Session und Folge-Sessions). Falls dazu die vollständige
verifizierte Claims-Map (statt nur sub/email) im Draft gestasht werden muss — tun.

### AC3 — Regressionstest: Raum-Creator nach Bootstrap ist die Matrix-User-ID

**Given** ein frisch abgeschlossener Bootstrap,
**When** der Operator **ohne vorherigen Matrix-Login** über die Admin-UI einen Raum anlegt,
**Then** ist der Raum-Creator `@<korrekter-localpart>:<server>` — **nicht** der rohe `sub`-Wert.
Test in `admin_create_room_test.exs`, Fixture: Session wie sie `bootstrap_confirm_claim/2` tatsächlich
erzeugt (nicht der bisherige Test-Seam, der vermutlich schon eine vollständige Session simuliert und
den Bug deshalb nicht fängt — verifizieren und ggf. Testfixture korrigieren).

### AC4 — Bestehende Bootstrap-Tests bleiben grün

**Given** die bestehende Testsuite für Bootstrap-Completion (`bootstrap_oidc_flow_test.exs`,
`auth_test.exs`),
**When** der Fix landet,
**Then** bleiben alle bestehenden Assertions gültig — dies ist eine additive Korrektur
(`matrix_user_id` kommt hinzu), keine Verhaltensänderung an `sub`/`email`/`admin`/`session_exp`.

## Implementation Map

### Zu ändernde Dateien
- `server/lib/nebu/admin/auth.ex` — `bootstrap_confirm_claim/2` (Zeile ~619-636), ggf.
  `bootstrap_callback/2` (Zeile ~514-541, Draft-Stash erweitern falls AC2 das erfordert)
- `server/test/nebu/admin/admin_create_room_test.exs` — AC3-Regressionstest,
  Session-Fixture-Review
- `server/test/nebu/admin/auth_test.exs` — Assertion für `matrix_user_id` nach Bootstrap-Login

## Security Considerations

- Trust-Boundary-Fix im Login-Pfad — `security_review: required`, `severity: high`.
- SEC Gate 1 verifiziert explizit: (a) `matrix_user_id` nach Bootstrap-Login ist identisch zu dem,
  was ein Folge-Login derselben Person via `normal_callback/2` liefert (kein neuer Divergenz-Fall,
  Pendant zu `bugfix-unify-admin-matrix-oidc-identity`); (b) keine neuen Claims werden ungeprüft in
  die Session übernommen, falls AC2 die volle Claims-Map stasht (Draft-Storage ist bereits
  Server-seitig, kein neuer Angriffsvektor erwartet, aber verifizieren).
- Diese Story hat Priorität vor `centralize-scope-resolution`/`centralize-claim-resolution` in der
  Wirkung (akuter Live-Bug), ist aber unabhängig davon umsetzbar — kann parallel oder vorgezogen
  laufen.

## Definition of Done

- [x] `bootstrap_confirm_claim/2` nutzt denselben Session-Builder wie `normal_callback/2`
- [x] `matrix_user_id` nach Bootstrap-Login korrekt gesetzt und identisch zu Folge-Logins
- [x] AC3-Regressionstest (Raum-Creator nach Bootstrap) grün
- [x] Bestehende Tests unverändert grün
- [x] Security Review (Kassandra) — CLEAN
