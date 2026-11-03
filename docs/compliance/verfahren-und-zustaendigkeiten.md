# Verfahren und Zuständigkeiten (Entwicklung, Test, Konfiguration, Assets)

Diese Datei ist das zentrale Betriebs- und Verfahrenskonzept des Projekts Nebu für die vier
Grundschutz++-Praktiken **DEV** (Entwicklung), **TEST** (Änderungen und Tests),
**KONF** (Konfiguration) und **ASST** (Informationen und Assets). Sie ist der Nachweis für die
Controls `*.1.1`, `*.1.1.1`, `*.1.1.2`, `*.1.1.3` und `*.1.2`. Die Antworten je Control stehen in
[`grundschutz-plusplus-antworten.md`](grundschutz-plusplus-antworten.md).

**Geltungsbereich:** Entwicklung und Release des Repositories `nebu/nebu-server`
(https://gitlab.opencode.de/nebu/nebu-server). Der Betrieb einer Nebu-Instanz liegt beim jeweiligen
Betreiber; das Repository enthält nur Beispiel-Deployments ohne produktive Zugangsdaten
(siehe [ADR-012](../architecture/adr/ADR-012-upstream-repo-no-deployments-example-credentials.md),
[ADR-023](../architecture/adr/ADR-023-deployment-postures-compliance-vs-normal.md)).

Stand: Erstfassung 2026-11-02.

---

## 1. Rollen und Zuständigkeiten

Die Zuordnung ist technisch in [`CODEOWNERS`](../../CODEOWNERS) hinterlegt. Code Owners werden bei
Merge Requests automatisch als Reviewer angefragt und zeigen so Änderungen an Verfahren an.

| Rolle | Person / Stelle | Aufgaben |
|---|---|---|
| Lead Maintainer | Philipp Beyerlein (INNOQ) | Freigabe von Merge Requests, Pflege dieser Verfahren, Releases, Annahme von Sicherheitsmeldungen, jährliche Verfahrensprüfung |
| Maintainer | derzeit wie Lead Maintainer; weitere Personen werden in `CODEOWNERS` und in dieser Tabelle ergänzt | Review und Merge |
| Contributor | alle Mitwirkenden (intern und extern) | Änderungen per Merge Request nach `CONTRIBUTING.md` |
| Sicherheitskontakt | Lead Maintainer, Meldeweg nach [`SECURITY.md`](../../SECURITY.md) | Triage und Behebung von Schwachstellen |
| Automatisierte Gates | CI-Pipeline, DevGuard, Renovate (siehe Abschnitt 3 und 5) | Reproduzierbare Prüfungen; die Verantwortung bleibt bei den Maintainern |

Aufgaben je Praktik:

| Praktik | Zuständig für Verfahren und Pflege | Ausführung |
|---|---|---|
| DEV | Lead Maintainer | Contributor, Maintainer |
| TEST | Lead Maintainer | Contributor, CI-Pipeline |
| KONF | Lead Maintainer | Maintainer, Betreiber (eigene Instanz) |
| ASST | Lead Maintainer | Maintainer, Betreiber (eigene Instanz) |

---

## 2. Entwicklung (DEV)

- **Versionsverwaltung:** Git, Primärrepository auf GitLab (openCode), Spiegelung nach GitHub durch
  die CI-Job `sync-github-mirror`.
- **Branching:** `main` ist der einzige langlebige Zweig
  ([ADR-017](../architecture/adr/ADR-017-simplified-main-only-branching.md)); Änderungen entstehen
  auf `feature/*`, `bugfix/*`, `docs/*`, `chore/*` und gelangen per Merge Request nach `main`.
  `hotfix/*` und `release/*` sind den Maintainern vorbehalten.
- **Commits:** Conventional Commits, Squash beim Merge ([`CONTRIBUTING.md`](../../CONTRIBUTING.md)).
- **Entwicklungsablauf (Maintainer):** BMAD/`nebu-pipeline` mit der Reihenfolge Story (Akzeptanzkriterien),
  Akzeptanztest-Gerüst (ATDD), Implementierung, CI-Gate, Test-Review, Code-Review, bedingtes
  Security-Review, Aktualisierung der Architekturdokumentation. Quellcode unter `server/lib/`,
  `server/test/` und `server/priv/migrations/` darf nur innerhalb dieser Pipeline geändert werden
  ([`CLAUDE.md`](../../CLAUDE.md)). Externe Contributor müssen die Pipeline nicht ausführen; Maintainer
  integrieren deren Änderungen.
- **Architekturentscheidungen:** als ADR unter [`docs/architecture/adr/`](../architecture/adr/).
- **Secure Development:** Secret-Scan (`secret-scan`), DevGuard-Komponenten (Abhängigkeits-, Code- und
  Container-Scans), Renovate für Abhängigkeitsupdates ([`renovate.json`](../../renovate.json)),
  Meldeweg für Schwachstellen ([`SECURITY.md`](../../SECURITY.md)).

## 3. Änderungen und Tests (TEST)

- **Änderungsweg:** jede Änderung ausschließlich per Merge Request mit Template
  ([`.gitlab/merge_request_templates/Default.md`](../../.gitlab/merge_request_templates/Default.md)),
  Review durch einen Maintainer, Verknüpfung mit Issue/Story.
- **Merge-Blocker** (nach `CONTRIBUTING.md`): fehlschlagende CI, offene Review-Kommentare, fehlende
  Tests, fehlende Dokumentation, sicherheitsrelevante Änderung ohne Security-Review.
- **Teststufen:** Unit-Tests (`test-unit-elixir`, auch gegen Elixir 1.19), Integrationstests
  (`integration-test`, Varianten für Podman und Kubernetes), E2E-Tests (`e2e-element-web`,
  `e2e-admin-ui`, `e2e-oauth-https`), Dokumentationsprüfung (`verify-docs`),
  Validierung von IaC und Helm-Chart (`validate-iac`, `validate-helm`).
- **TDD:** Der Test wird vor der Implementierung geschrieben (Standard für Maintainer).
- **Entfernung/Neueinführung von Komponenten:** Abhängigkeiten werden über Renovate-MRs und die
  DevGuard-Scans geführt; neue Komponenten mit Architekturwirkung erfordern einen ADR.
- **Releases:** `create-release-tag`, `release-server-image`, Image-Build mit Attestierung
  (`oci-image`, `attestation`), Änderungen stehen im [`CHANGELOG.md`](../../CHANGELOG.md).

## 4. Konfiguration (KONF)

- **Konfigurationsquellen:** Umgebungsvariablen (`NEBU_*`, dokumentiert in
  [`docs/architecture/07-deployment.md`](../architecture/07-deployment.md)), die Tabelle
  `server_config` (Bootstrap-Wizard, [ADR-022](../architecture/adr/ADR-022-oidc-bootstrap-only-configuration.md)),
  `docker-compose.yml`, Helm-Chart `deploy/helm/nebu`, OpenTofu-Module und -Beispiele `deploy/tofu`.
- **Änderungsweg:** Konfigurations- und IaC-Änderungen laufen wie Code per Merge Request und werden durch
  `validate-iac` und `validate-helm` geprüft. Verhaltensändernde Konfiguration wird mit Warnhinweis im
  `CHANGELOG.md` angekündigt.
- **Geheimnisse:** keine Produktivzugangsdaten im Repository; CI-Zugangsdaten sind Beispielwerte für
  Test-Infrastruktur (ADR-012); lokale Entwicklungsgeheimnisse erzeugt `make setup` unter `.secrets/`;
  `secret-scan` prüft jeden Lauf.
- **Betriebsposturen:** Compliance- und Normalbetrieb sind in ADR-023 beschrieben.

## 5. Informationen und Assets (ASST)

| Asset | Ort / Verwaltung | Schutz und Lebenszyklus |
|---|---|---|
| Quellcode, ADRs, Dokumentation | GitLab-Repository (Spiegel auf GitHub) | Zugriff per GitLab-Rechten, Änderungen nur per MR, Historie in Git |
| Abhängigkeiten und SBOM | DevGuard-Asset des Projekts, Renovate | Scans bei jedem Lauf auf `main`, Updates wöchentlich (Wochenende) |
| Container-Images | Registry des Projekts, Attestierung in der Pipeline | Build nur aus `main`/Release-Pipelines |
| CI-Variablen und Tokens (z. B. `DEVGUARD_TOKEN`, `GITHUB_MIRROR_TOKEN`) | GitLab CI/CD-Variablen | maskiert, nur für die jeweiligen Jobs |
| Personenbezogene Daten im Produkt | Datenbank der Betreiber-Instanz | Löschung nach [`gdpr-deletion-runbook.md`](gdpr-deletion-runbook.md); Betreiber legt Aufbewahrungs- und Löschfristen fest |
| Sicherheitsmeldungen | nicht öffentlich (GitLab/GitHub Security Advisory oder Maintainer-Kontakt) | Vertraulich bis zur koordinierten Offenlegung |

Das Projekt verarbeitet im Repository selbst keine Produktivdaten. Informationsmanagement für
laufende Instanzen (Schutzbedarf, Fristen) liegt beim Betreiber; das Produkt stellt dafür Audit-Log,
Legal-Export und Löschfunktion bereit.

---

## 6. Dokumentation und Bekanntgabe

- Diese Datei, `CONTRIBUTING.md`, `SECURITY.md`, `CLAUDE.md`, die ADRs und der `CHANGELOG.md` bilden
  die Verfahrensdokumentation. Sie liegt im Repository und ist damit versioniert und nachvollziehbar.
- **Bekanntgabe beim Einstieg:** `README.md` und `CONTRIBUTING.md` verweisen auf diese Datei; neue
  Maintainer werden beim Aufnehmen in `CODEOWNERS` auf sie hingewiesen.
- **Bekanntgabe bei Änderungen:** Änderungen an Verfahren erfolgen nur per Merge Request. Die Pfade
  `CONTRIBUTING.md`, `.gitlab-ci.yml`, `docs/compliance/` und `docs/architecture/adr/` gehören den
  Code Owners, die dadurch automatisch benachrichtigt werden. Wesentliche Änderungen werden im
  `CHANGELOG.md` vermerkt.
- **Maintainer-Einrichtung (einmalig):** In GitLab unter *Settings → Merge requests → Approval rules*
  die Regel „Code Owners" für `main` aktivieren, damit die Zuständigen bei jeder Änderung an diesen
  Pfaden freigeben müssen.

---

## 7. Prüfplan (regelmäßig und anlassbezogen)

- **Regelprüfung:** einmal jährlich, nächster Termin **2027-11-02**. Durchführung über die
  Issue-Vorlage [`Verfahrenspruefung`](../../.gitlab/issue_templates/Verfahrenspruefung.md).
- **Anlassbezogene Prüfung** bei: Sicherheitsvorfall oder meldepflichtiger Schwachstelle, Wechsel der
  Maintainer, Wechsel der CI- oder Hosting-Plattform, grundlegender Architekturentscheidung (neuer ADR
  zu Branching, Pipeline oder Konfiguration), neuen rechtlichen oder normativen Anforderungen.
- **Gegenstand:** Stimmen Verfahren, Zuständigkeiten, Pipeline und `CODEOWNERS` mit der gelebten
  Praxis überein? Sind die Antworten in `grundschutz-plusplus-antworten.md` und in DevGuard aktuell?

### Prüfprotokoll

| Datum | Anlass | Durchgeführt von | Ergebnis |
|---|---|---|---|
| 2026-11-02 | Erstfassung der Verfahrensdokumentation | Lead Maintainer | Erstfassung angelegt, Review durch Lead Maintainer ausstehend |
