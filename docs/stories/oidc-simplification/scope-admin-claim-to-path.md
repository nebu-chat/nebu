---
story_id: scope-admin-claim-to-path
title: Admin-Group-Claim-Gate auf Claim-Pfad statt Any-Key-Value-Scan einschränken
type: security-fix
severity: high
epic: oidc-simplification
status: done
security_review: required
created: 2026-07-01
depends_on: centralize-claim-resolution
---

## Summary

Schließt das zweimal heute akzeptierte MEDIUM-Risiko (`bugfix-unify-admin-matrix-oidc-identity`,
`bugfix-nested-oidc-claim-support`, beide 2026-07-01): `admin_claim?/1` (nach Vorstory
`Nebu.Web.OidcClaims.admin_marker?/2`) matched heute den konfigurierten Admin-Marker-Wert gegen
**jeden** Claim-Wert im Baum, unabhängig vom Key/Pfad. Diese Story macht den Check **Pfad-scoped**:
der Bootstrap-Wizard-Claim-Picker (bereits Dot-Path-fähig aus `83ea6e69`) persistiert künftig den
gewählten Claim-**Pfad** (nicht nur den Wert), und das Gate prüft gezielt an diesem Pfad.

**Beide Kassandra-Reviews vom 2026-07-01 verweisen explizit auf diese Story als den "proper fix",
der "deferred to the planned OIDC-centralization epic" wurde — dies ist kein optionales Hardening,
sondern der Abschluss eines bereits zweimal akzeptierten Risikos.**

## Motivation

Aktuell (auth.ex:1108-1134, bald `Nebu.Web.OidcClaims.admin_marker?/2` nach Vorstory):
Ein Nicht-Admin, dessen IdP einen selbst-editierbaren Claim (z.B. `name`, `preferred_username`,
`address.locality`) mit einem Wert freigibt, der zufällig dem konfigurierten Admin-Marker
(`admin_group_claim`, Default `"instance_admin"`) entspricht, würde als Admin klassifiziert — weil
der Scan **keine** Rolle spielt, unter welchem Claim-Key der Wert auftaucht.

Der Bootstrap-Wizard-Claim-Picker (`extract_discovered_claims/1`) zeigt dem Operator bereits den
Dot-Path (z.B. `realm_access.roles`) UND den Wert an — der Pfad wird aber nach der Auswahl verworfen;
nur der Wert landet in `server_config.admin_group_claim`. Das ist die Lücke, die diese Story
schließt.

## Non-Goals

- Kein automatisches Migrations-Tool, das bestehende Deployments zwingt, den Pfad neu auszuwählen —
  Backward-Compat-Fallback (AC3) übernimmt das für nicht-migrierte Configs.
- Keine Änderung an der Bootstrap-UI-Darstellung selbst (Dot-Path-Anzeige existiert bereits aus
  `83ea6e69`).

## Acceptance Criteria

### AC1 — Neuer `server_config`-Key für den Claim-Pfad

**Given** eine neue Migration `server/priv/migrations/0000XX_config_admin_group_claim_path.up.sql`,
**When** sie läuft,
**Then** wird `admin_group_claim_path` als neuer, mutabler Key zur `config_update_mutable`
RLS-Policy hinzugefügt (Muster: `000013_config_oidc_scopes_mutable.up.sql`). Kein Schema-Change
(Key-Value-Store).

### AC2 — Bootstrap-Wizard persistiert Pfad UND Wert

**Given** der Operator wählt im Claim-Picker einen Eintrag (z.B. `realm_access.roles` = `"admin"`),
**When** die Auswahl bestätigt wird (`bootstrap_confirm_claim/2`),
**Then** werden BEIDE gespeichert: `admin_group_claim` (Wert, wie heute) UND
`admin_group_claim_path` (der Dot-Path-Key, z.B. `"realm_access.roles"`). Für flache Claims ohne
Präfix ist der Pfad identisch zum bisherigen bare Key.

### AC3 — Gate prüft Pfad zuerst, Fallback für Alt-Configs

**Given** `Nebu.Web.OidcClaims.admin_marker?/2` (aus Vorstory),
**When** es aufgerufen wird,
**Then**:
1. Ist `admin_group_claim_path` gesetzt → `get_in`/List-Membership-Check **ausschließlich** an diesem
   Pfad gegen den konfigurierten Wert. Kein Treffer an anderer Stelle im Baum zählt.
2. Ist `admin_group_claim_path` **nicht** gesetzt (bestehendes Deployment, vor dieser Story
   bootstrapped) → Fallback auf den bisherigen Any-Key-Value-Scan (heutiges Verhalten), damit kein
   bestehender Admin ausgesperrt wird. Dieser Fallback-Zweig ist selbst **keine** Regression — er ist
   exakt das Ist-Verhalten, nur nicht mehr der einzige Pfad.
3. Loggt (INFO-Level, kein PII) wenn der Fallback-Zweig genommen wird, damit Operator-seitig
   sichtbar ist, dass ein Re-Bootstrap/Re-Konfiguration der Claim-Auswahl das Gate härten würde.

### AC4 — Regressionstest: selbst-editierbarer Claim wird NICHT mehr fälschlich Admin

**Given** `admin_group_claim = "instance_admin"`, `admin_group_claim_path = "groups"` gesetzt,
**When** ein Token mit `groups: ["user"]` UND `name: "instance_admin"` (selbst gesetzter Anzeigename)
verifiziert wird,
**Then** wird der User **NICHT** als Admin klassifiziert (der Treffer läge nur unter `name`, nicht
unter dem konfigurierten Pfad `groups`). Dieser Test ist der Beweis, dass das MEDIUM-Risiko
geschlossen ist.

### AC5 — Regressionstest: echter Admin bleibt Admin (Pfad-Pfad UND Fallback-Pfad)

**Given** dieselbe Config wie AC4,
**When** ein Token mit `groups: ["instance_admin"]` verifiziert wird,
**Then** wird der User als Admin klassifiziert. Zusätzlich: ein Deployment ohne
`admin_group_claim_path` (Fallback) klassifiziert einen Token mit `groups: ["instance_admin"]`
weiterhin korrekt als Admin (keine Regression im Fallback-Pfad).

## Implementation Map

### Neue Dateien
- Migration `0000XX_config_admin_group_claim_path.up.sql` + `.down.sql`

### Zu ändernde Dateien
- `server/lib/nebu/admin/bootstrap_controller.ex` — `bootstrap_confirm_claim/2` persistiert Pfad
- `server/lib/nebu/web/oidc_claims.ex` — `admin_marker?/2` Pfad-Check + Fallback
- `server/test/nebu/admin/admin_oidc_login_test.exs` — AC4/AC5 Regressionstests
- `server/test/nebu/release_test.exs` — Migrationszähler

## Security Considerations

- Dies ist die eigentliche Sicherheitskorrektur des Epics — `security_review: required`,
  `severity: high`.
- SEC Gate 1 MUSS explizit verifizieren: (a) AC4 schließt das Risiko nachweisbar, (b) der
  Fallback-Zweig (AC3.2) führt zu **keiner** Rechteausweitung gegenüber heute (er IST das
  Ist-Verhalten, nicht mehr), (c) kein neuer Denylist-artiger Hardcode, der ein legitimes
  Operator-Setup brechen könnte (Begründung aus dem `81155881`-Commit, warum ein Denylist abgelehnt
  wurde, bleibt gültig — diese Story löst es über Pfad-Tracking, nicht über Denylist).
- **Bei CLEAN-Verdict:** Der bestehende Accepted-Risk-Eintrag in
  `_bmad/memory/nebu-agent-kassandra/BOND.md`/`MEMORY.md` (any-key claim-value scan, flat→nested
  widening) sollte am Epic-Ende als **resolved** markiert werden, nicht weiter mitgeführt.

## Definition of Done

- [ ] Migration erstellt, `config_update_mutable` erweitert
- [ ] Bootstrap persistiert Pfad + Wert
- [ ] `admin_marker?/2` Pfad-Check + dokumentierter Fallback implementiert
- [ ] AC4 (Negativ-Fall) UND AC5 (Positiv-Fall + Fallback-Fall) grün
- [ ] Security Review (Kassandra) — CLEAN, Risiko nachweisbar geschlossen
- [ ] Accepted-Risk-Eintrag in Kassandras Memory als resolved markiert (im Security-Review-Report
      vermerken, Kassandra aktualisiert ihr Gedächtnis selbst)
- [ ] Arc42 `08-concepts.md` Admin-UI-Security-Abschnitt aktualisiert
