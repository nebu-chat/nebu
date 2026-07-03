---
story_id: provision-matrix-identity-on-admin-login
title: Admin-Login provisioniert keine Matrix-User-Row — Admin fehlt in der Users-Liste
type: feature
severity: medium
epic: oidc-simplification
status: done
security_review: required
created: 2026-07-01
depends_on: fix-bootstrap-admin-session-identity
---

## Summary

**Von Phil gemeldet (2026-07-01), Ursache über `fix-bootstrap-admin-session-identity` hinaus:** Der
Matrix-SSO-Login-Pfad (`POST /_matrix/client/v3/login`, `http_public.ex:325-371`) provisioniert bei
jedem Login eine Matrix-`users`-DB-Row (`TokenValidator.validate/4`, `upsert_profile/3`) und stößt
Folgeprozesse wie Auto-Join an (`run_post_login_provisioning/2`). Der Admin-Login-Pfad
(`normal_callback/2` UND `bootstrap_confirm_claim/2`, beide in `admin/auth.ex`) tut das **nicht** —
er ruft ausschließlich `put_current_user/2` für die Phoenix-Session, ohne jede Matrix-Domain-Schreib-
oder Provisionierungsoperation.

**Sichtbare Konsequenz:** Ein Operator, der sich ausschließlich über die Admin-UI anmeldet (nie über
einen Matrix-Client), taucht in der Admin-UI-Users-Liste NICHT auf (`Nebu.Admin.DB` liest exklusiv
aus der `users`-Tabelle, die nur der Matrix-Login-Pfad befüllt) — obwohl diese Person via
`matrix_user_id` bereits Räume erstellen und Mitgliedschaften zuweisen kann (nach Fix der
Vorstory). Es entsteht ein Widerspruch: die Person handelt bereits als Matrix-Identität, existiert
aber nicht als "User" im System.

## Motivation

Diese Story ist die architektonische Fortsetzung von `fix-bootstrap-admin-session-identity`: Diese
korrigiert nur, DASS `matrix_user_id` korrekt in der Session steht. Diese Story stellt sicher, dass
diese Identität auch **provisioniert** ist — dieselbe Garantie, die der Matrix-Login-Pfad für jeden
Matrix-Client-Login gibt.

## Acceptance Criteria

### AC1 — Admin-Login provisioniert die Matrix-Identität

**Given** ein erfolgreicher Admin-OIDC-Login (`normal_callback/2` ODER `bootstrap_confirm_claim/2`),
**When** die Session gemintet wird,
**Then** wird für dieselbe `matrix_user_id` derselbe Provisionierungspfad angestoßen, den der
Matrix-Login nutzt (`TokenValidator.validate/4` bzw. dessen aktuelle Entsprechung) — die Person
erhält eine `users`-Row, falls noch keine existiert (idempotent bei bereits existierender Row, wie
beim Matrix-Login).

### AC2 — Architektur-Entscheidung: Auto-Join für admin-only Logins?

**Given** `run_post_login_provisioning/2` (Auto-Join in `is_auto_join`-Räume) ist Teil des
Matrix-Login-Provisionierungspfads,
**When** diese Story umgesetzt wird,
**Then** MUSS explizit entschieden und im PR/Story-Update begründet werden, ob ein admin-only Login
ebenfalls Auto-Join auslösen soll (Konsistenz-Argument: "eine Person, ein Onboarding-Verhalten,
unabhängig vom Login-Weg") oder bewusst NICHT (Argument: ein reiner Admin-Account ist ggf. kein
Kommunikationsteilnehmer). **Empfehlung dieser Architektur:** Provisionierung (AC1) JA, Auto-Join
NEIN standardmäßig — ein Admin, der nie einen Matrix-Client nutzt, muss nicht automatisch Mitglied
aller Auto-Join-Räume werden, nur weil er sich einmal im Admin-Bereich anmeldet. Diese Empfehlung ist
kein Veto — der Dev-Agent kann bei der Umsetzung mit begründetem Gegenvorschlag abweichen, MUSS es
aber explizit im Story-Update dokumentieren.

**Implementation Decision (Dev-Agent, 2026-07-02):** Der Empfehlung dieser Architektur wurde gefolgt
— **Provisionierung JA, Auto-Join NEIN**. `Nebu.Matrix.provision_identity/2` (die neue Facade-Funktion,
ADR-020) führt ausschließlich `TokenValidator.validate/4` + `Profile.DB.upsert_profile/3` aus und ruft
NIEMALS `Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2` (bzw.
`ensure_auto_join_memberships/1`) auf. Diese Entscheidung ist durch den ATDD-Test in
`server/test/nebu/admin/admin_oidc_login_test.exs`, describe-Block "AC2: admin-only login
provisioning does NOT trigger auto-join by default", verifiziert (`refute_received
{:list_auto_join_rooms_called}` — kein Deviation, Test-Assertion unverändert übernommen). Keine
Gegenvorschlag-Abweichung erforderlich; die Sicherheitsbegründung (Informationsleck-Risiko bei
Auto-Join in vertrauliche Räume) trägt und wurde nicht durch neue Erkenntnisse widerlegt.

### AC3 — Admin taucht in der Users-Liste auf

**Given** ein Operator, der sich ausschließlich über die Admin-UI anmeldet,
**When** ein anderer Admin `GET /admin/users` öffnet,
**Then** erscheint dieser Operator in der Liste (via der jetzt vorhandenen `users`-Row).

### AC4 — Kein Duplicate-Provisioning-Konflikt bei späterem Matrix-Login

**Given** ein Admin wurde bereits über AC1 provisioniert,
**When** dieselbe Person sich später über einen echten Matrix-Client einloggt,
**Then** läuft die reguläre Matrix-Login-Provisionierung unverändert weiter (idempotentes Upsert,
kein Fehler wegen bereits existierender Row, kein doppeltes Auto-Join, keine überschriebenen
Profildaten die der Nutzer inzwischen selbst gesetzt hat).

### AC5 — Regressionstest

**Given** ein Admin-Login ohne vorherigen Matrix-Login,
**When** danach `GET /admin/users` aufgerufen wird,
**Then** erscheint der Admin in der Liste; UND ein anschließender echter Matrix-Login derselben
Person funktioniert unverändert (kein Fehler, keine doppelte Row, `AC4`).

## Implementation Map

### Zu ändernde Dateien
- `server/lib/nebu/admin/auth.ex` — `normal_callback/2` und `bootstrap_confirm_claim/2` (nach Fix
  der Vorstory) rufen den Provisionierungspfad
- Cross-Domain-Aufruf **ausschließlich über die `Nebu.Matrix`-Public-API-Facade** (ADR-020) — Admin
  darf nicht direkt `TokenValidator`/interne Matrix-Submodule aufrufen
- `server/test/nebu/admin/admin_oidc_login_test.exs` — AC3/AC5

## Security Considerations

- `security_review: required`. SEC Gate 1 Fokus:
  - Kein Privilege-Escalation-Pfad: Provisionierung einer `users`-Row für den Admin darf keine
    Matrix-Berechtigungen verleihen, die über das hinausgehen, was ein regulärer Erstlogin ohnehin
    bekäme (Power-Level-Zuweisung bleibt an Raum-Aktionen gebunden, nicht an die Provisionierung
    selbst).
  - ADR-020-Konformität: Aufruf via `Nebu.Matrix`-Facade, kein direkter Zugriff auf interne
    Matrix-Submodule aus `Nebu.Admin`.
  - AC2-Entscheidung ist sicherheitsrelevant — unerwünschtes Auto-Join eines Admin-Accounts in
    private/sensible Räume wäre ein Informationsleck-Risiko, falls Auto-Join-Räume vertrauliche
    Inhalte haben. Die Empfehlung (kein Auto-Join für admin-only Provisionierung) reduziert dieses
    Risiko standardmäßig.
  - Kein Denial-of-Service durch wiederholte Provisionierungs-Aufrufe (Login-Rate bereits
    ratenlimitiert; Provisionierung selbst muss idempotent/billig sein — AC4).

## Definition of Done

- [x] Admin-Login (normal + bootstrap) provisioniert `users`-Row via `Nebu.Matrix`-Facade
- [x] AC2-Entscheidung getroffen und dokumentiert (Auto-Join ja/nein + Begründung)
- [x] Admin erscheint nach admin-only Login in `GET /admin/users`
- [x] Idempotenz bei späterem echten Matrix-Login bestätigt (AC4/AC5)
- [x] Security Review (Kassandra) — CLEAN (0 CRITICAL/HIGH/MEDIUM, 1 pre-existing INFO restated), ADR-020 + Auto-Join-Entscheidung verifiziert (`docs/stories/oidc-simplification/security-reports/provision-matrix-identity-on-admin-login-security-review-2026-07-02.md`)
- [x] Arc42 `08-concepts.md` aktualisiert (Admin-Login provisioniert jetzt Matrix-Identität)

## Dev Agent Record

### Implementation Plan

- Added `Nebu.Matrix.provision_identity/2` (`server/lib/nebu/matrix.ex`) as the single ADR-020-
  compliant facade entry point: `TokenValidator.validate/4` → `Profile.DB.upsert_profile/3`,
  deliberately WITHOUT `run_post_login_provisioning/2` (AC2 decision above). Guards both calls behind
  a `repo_reachable?/0` check (live `Nebu.Repo` OR a test-injected `:session_manager,
  :validator_module` override) so the facade is safe to call from plain unit tests that stub only the
  validator seam, without raising on the real Postgres path's unconditional `Ecto.Adapters.SQL.query`
  calls when no live Postgres is present.
- Wired a new private `provision_matrix_identity/1` helper into `server/lib/nebu/admin/auth.ex`,
  called from `normal_callback/2` and `bootstrap_confirm_claim/2` (immediately before
  `put_current_user/2`) — the two admin-login completion points, per the story's injection-point
  guidance. Deliberately NOT wired into `put_current_user/2` itself (which is also called by the
  silent HTTP pre-expiry refresh path, `refresh_admin_session/1`) — re-provisioning on every
  refreshed HTTP request is unnecessary once the identity is already provisioned at login, and doing
  so would also have broken the pre-existing `put_current_user/2` unit test that calls it directly
  with no live Repo and no validator seam configured.
- Provisioning failures are logged and swallowed (best-effort) — a Matrix-domain provisioning failure
  must never block the admin session mint itself.

### Completion Notes

- All 26 pre-staged unit tests (AC1, AC2, regression guard) in
  `server/test/nebu/admin/admin_oidc_login_test.exs` pass. Full unit suite (`mix test`, excludes
  `:integration`): 1173 passed, 0 regressions.
- The 3 `:integration`-tagged AC3/AC4/AC5 tests were run against a live PostgreSQL (docker compose,
  migrated to schema v15) and pass: confirmed via direct SQL that an admin-only login provisions a
  real `users` row (`@..._adminonly:localhost` appeared in the table), that a later real Matrix login
  of the same identity does not error/duplicate, and that a user-set displayname survives a
  subsequent claims-less profile touch (`Profile.DB` `COALESCE` upsert contract).
- Test-environment note (not a code defect): the ATDD file's `@run_id` fixture
  (`Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)`) is case-sensitive and not
  lowercased before being compared against `Nebu.Matrix.UserId.from_claims/2` (which always
  downcases the localpart per Matrix ID grammar) — this pre-existing test-fixture flakiness
  intermittently fails the AC3/AC4/AC5 integration tests' own sanity-check assertion
  (`assert Nebu.Matrix.UserId.from_claims(claims, "localhost") == user_id`) whenever the random bytes
  happen to decode to mixed-case characters, independent of and unrelated to this story's production
  code. Verified root cause with a local scratch copy of the test (lowercasing `@run_id`), confirming
  all 5 integration tests pass deterministically once the fixture bug is worked around. Left the
  staged ATDD test file itself untouched per the task's scope (ATDD tests are pre-staged/out of
  scope for this dev step) — flagged here for the test-review/QA follow-up.

### File List

- `server/lib/nebu/matrix.ex` — added `Nebu.Matrix.provision_identity/2` (ADR-020 facade entry point)
- `server/lib/nebu/admin/auth.ex` — added `provision_matrix_identity/1`; wired into `normal_callback/2`
  and `bootstrap_confirm_claim/2`
- `docs/architecture/08-concepts.md` — documented the new provisioning behavior + AC2 decision under
  "Admin UI Security"
- `docs/stories/oidc-simplification/provision-matrix-identity-on-admin-login.md` — this file (AC2
  Implementation Decision note, Dev Agent Record, Definition of Done, status)

(Test file `server/test/nebu/admin/admin_oidc_login_test.exs` was pre-staged by the ATDD step, not
modified by this dev step.)

### Change Log

- 2026-07-02: Implemented AC1–AC5. Added `Nebu.Matrix.provision_identity/2` facade + wired it into
  both admin-login completion points; documented the AC2 no-auto-join decision in this story and in
  `08-concepts.md`. All unit tests green (1173 passed, 0 regressions); all 3 `:integration`-tagged
  AC3/AC4/AC5 tests verified green against a live PostgreSQL.
