# Grundschutz++: Antworten zu den Controls (DevGuard / SystemSecurityPlan)

Diese Datei sammelt die Antworten auf die Grundschutz++-Controls, die für das openCode-Badge
„Grundschutz++“ in DevGuard beantwortet werden (OSCAL System Security Plan).
Grundlage des Badges: [badges.opencode.de](https://badges.opencode.de/explanation/official-badges/grundschutz-plusplus-badge).
Ein Control besteht den Check nur mit Status `implemented` oder `not-applicable`; `planned`, `partial`
und `alternative` gelten als nicht bestanden.

**Regel für diese Datei:** Ein Status ist nur dann `implemented`, wenn der genannte Nachweis im
Default-Branch (`main`) liegt und die Aussage stimmt. Was noch fehlt, steht in der Spalte „Offen“.

Stand: 2026-11-02 (Erstfassung, Status gelten **nach Merge** der Verfahrensdokumentation).

## Parameterwerte (für Platzhalter im Katalog)

| Parameter | Gewählter Wert |
|---|---|
| Geltungsbereich Verfahren (TEST.1.1-prm1) | pro Informationsverbund: das Entwicklungsprojekt Nebu (Repository `nebu/nebu-server`) |
| Zuweisung der Aufgaben (`*.1.1.2-prm1`) | Rollen (Lead Maintainer, Maintainer), abgebildet in `CODEOWNERS` |
| Prüfintervall (`*.1.2-prm1`) | jährlich, nächster Termin 2027-11-02 |

## Bronze-Controls (MUSS, normal-SdT): Entwicklung, Test, Konfiguration, Assets

Nachweis-Datei „Verfahren“ = [`verfahren-und-zustaendigkeiten.md`](verfahren-und-zustaendigkeiten.md).

| Control | Anforderung (Kurzfassung) | Status | Antwort (für DevGuard) | Nachweis | Offen |
|---|---|---|---|---|---|
| DEV.1.1 | Verfahren zur Entwicklung von IT-Produkten verankern | implemented | Das Entwicklungsverfahren ist festgelegt: Git mit `main` als einzigem langlebigen Zweig (ADR-017), Änderungen per Merge Request mit Review, Conventional Commits, Entwicklungspipeline mit Story, ATDD, Implementierung, CI-Gate, Test-, Code- und bedingtem Security-Review, Secret-Scan, DevGuard-Scans und Renovate. | Verfahren §2, `CONTRIBUTING.md`, `CLAUDE.md`, ADR-017, `.gitlab-ci.yml` | – |
| DEV.1.1.1 | Verfahren dokumentieren | implemented | Das Verfahren ist im Repository dokumentiert und versioniert (Verfahrensdatei, `CONTRIBUTING.md`, `CLAUDE.md`, ADRs). | Verfahren §2 und §6 | – |
| DEV.1.1.2 | Aufgaben zuweisen | implemented | Rollen und Aufgaben sind in einer Rollentabelle festgelegt und in `CODEOWNERS` technisch hinterlegt (Lead Maintainer für Verfahren und Freigaben, Maintainer für Review, Contributor für Änderungen). | Verfahren §1, `CODEOWNERS` | – |
| DEV.1.1.3 | Zuständige informieren | partial | Verfahren stehen in `README.md`/`CONTRIBUTING.md` und werden beim Einstieg bekanntgegeben; Änderungen laufen nur per Merge Request, wodurch Code Owners benachrichtigt werden. | Verfahren §6, `CONTRIBUTING.md`, `CODEOWNERS` | Prüfen, ob Code-Owner-Benachrichtigung/Approval-Regel auf openCode-GitLab verfügbar und aktiviert ist (Settings → Merge requests). Falls nicht: Maintainer als Watcher des Projekts eintragen und hier vermerken. Dann `implemented`. |
| DEV.1.2 | Verfahren regelmäßig und anlassbezogen prüfen | partial | Prüfplan: jährliche Regelprüfung (nächster Termin 2027-11-02) und anlassbezogene Prüfung bei Vorfall, Maintainer- oder Plattformwechsel, Architekturänderung; Durchführung über Issue-Vorlage, Ergebnis im Prüfprotokoll. | Verfahren §7, `.gitlab/issue_templates/Verfahrenspruefung.md` | Erstfassung durch Lead Maintainer prüfen und im Prüfprotokoll bestätigen. Dann `implemented`. |
| TEST.1.1 | Verfahren zu Neueinführung, Änderung und Entfernung von Komponenten verankern | implemented | Jede Änderung (Code, Konfiguration, Abhängigkeit) läuft per Merge Request mit Template, Review und Pflicht-Pipeline (Unit-, Integrations-, E2E-Tests, Doku-, IaC- und Helm-Validierung); neue Komponenten mit Architekturwirkung erfordern einen ADR; Abhängigkeiten werden über Renovate-MRs und DevGuard geführt. | Verfahren §3, `.gitlab-ci.yml`, MR-Template, `renovate.json` | – |
| TEST.1.1.1 | Verfahren dokumentieren | implemented | Änderungs- und Testverfahren sind in der Verfahrensdatei und in `CONTRIBUTING.md` (Abschnitte Pull Request, Testing) dokumentiert. | Verfahren §3, `CONTRIBUTING.md` | – |
| TEST.1.1.2 | Aufgaben zuweisen | implemented | Der Lead Maintainer ist für Verfahren und Freigabe zuständig, Contributor führen Änderungen und Tests aus, die CI-Pipeline erzwingt die Tests; Zuordnung in der Rollentabelle und in `CODEOWNERS`. | Verfahren §1, `CODEOWNERS` | – |
| TEST.1.1.3 | Zuständige informieren | partial | Verfahren sind beim Einstieg über `README.md`/`CONTRIBUTING.md` bekannt; bei Änderungen am Verfahren werden die Code Owners über den Merge Request benachrichtigt; wesentliche Änderungen stehen im `CHANGELOG.md`. | Verfahren §6, `CONTRIBUTING.md`, `CODEOWNERS`, `CHANGELOG.md` | Wie DEV.1.1.3 (Benachrichtigung prüfen und aktivieren). |
| TEST.1.2 | Verfahren regelmäßig und anlassbezogen prüfen | partial | Jährliche und anlassbezogene Prüfung nach Prüfplan, gemeinsam mit den anderen Praktiken. | Verfahren §7, Issue-Vorlage | Wie DEV.1.2 (Erstfassung bestätigen). |
| KONF.1.1 | Verfahren zum Konfigurationsmanagement verankern | implemented | Konfiguration kommt aus Umgebungsvariablen, der Tabelle `server_config` (Bootstrap-Wizard), `docker-compose.yml`, Helm-Chart und OpenTofu-Modulen. Änderungen laufen wie Code per Merge Request und werden mit `validate-iac` und `validate-helm` geprüft; verhaltensändernde Konfiguration wird im `CHANGELOG.md` angekündigt; keine Produktivgeheimnisse im Repository (ADR-012), Secret-Scan in jeder Pipeline. | Verfahren §4, ADR-012, ADR-022, `deploy/`, `.gitlab-ci.yml` | – |
| KONF.1.1.1 | Verfahren dokumentieren | implemented | Das Konfigurationsmanagement ist in der Verfahrensdatei, in `docs/architecture/07-deployment.md` und in den ADRs dokumentiert. | Verfahren §4, `docs/architecture/07-deployment.md` | – |
| KONF.1.1.2 | Aufgaben zuweisen | implemented | Lead Maintainer ist für Konfigurationsverfahren und `deploy/` zuständig (`CODEOWNERS`), Maintainer führen Änderungen aus, Betreiber verantworten die Konfiguration ihrer Instanz. | Verfahren §1, `CODEOWNERS` | – |
| KONF.1.1.3 | Zuständige informieren | partial | Wie TEST.1.1.3; verhaltensändernde Konfiguration wird zusätzlich im `CHANGELOG.md` mit Warnhinweis angekündigt, sodass Betreiber sie vor dem Update sehen. | Verfahren §6, `CHANGELOG.md`, `CODEOWNERS` | Wie DEV.1.1.3. |
| KONF.1.2 | Verfahren regelmäßig und anlassbezogen prüfen | partial | Jährliche und anlassbezogene Prüfung nach Prüfplan. | Verfahren §7, Issue-Vorlage | Wie DEV.1.2. |
| ASST.1.1 | Verfahren zum Management von Informationen und Assets verankern | partial | Die Assets des Projekts sind erfasst (Quellcode, Abhängigkeiten/SBOM in DevGuard, Container-Images, CI-Geheimnisse, Sicherheitsmeldungen) mit Ort, Schutz und Lebenszyklus; Löschung personenbezogener Daten im Produkt ist über ein Runbook geregelt, Schutzbedarf und Fristen für Instanzdaten liegen beim Betreiber. | Verfahren §5, `gdpr-deletion-runbook.md`, ADR-012, ADR-023 | Spalte „Schutzbedarf“ (normal/hoch) und Aufbewahrungsfrist je Asset in Verfahren §5 ergänzen. Dann `implemented`. |
| ASST.1.1.1 | Verfahren dokumentieren | implemented | Das Asset-Verfahren steht in der Verfahrensdatei §5 (Asset-Tabelle) und im Runbook zur Datenlöschung. | Verfahren §5, `gdpr-deletion-runbook.md` | – |
| ASST.1.1.2 | Aufgaben zuweisen | implemented | Lead Maintainer ist zuständig für Pflege des Asset-Verfahrens, Maintainer für Zugänge und Tokens, Betreiber für Daten ihrer Instanz; Zuordnung in der Rollentabelle und in `CODEOWNERS`. | Verfahren §1, `CODEOWNERS` | – |
| ASST.1.1.3 | Zuständige informieren | partial | Wie TEST.1.1.3. | Verfahren §6 | Wie DEV.1.1.3. |
| ASST.1.2 | Verfahren regelmäßig und anlassbezogen prüfen | partial | Jährliche und anlassbezogene Prüfung nach Prüfplan. | Verfahren §7, Issue-Vorlage | Wie DEV.1.2. |

## Offene Schritte vor dem Statuswechsel auf `implemented`

1. Dateien (`CODEOWNERS`, `docs/compliance/`, Issue-Vorlage, Abschnitt in `CONTRIBUTING.md`) in `main` mergen.
2. Verfügbarkeit der Code-Owner-Benachrichtigung auf openCode-GitLab prüfen und aktivieren, oder
   Ersatzweg (Watcher) dokumentieren. Betrifft DEV.1.1.3, TEST.1.1.3, KONF.1.1.3, ASST.1.1.3.
3. Erstfassung als Lead Maintainer prüfen und im Prüfprotokoll bestätigen. Betrifft die vier `*.1.2`.
4. Schutzbedarf und Aufbewahrungsfrist je Asset in Verfahren §5 ergänzen. Betrifft ASST.1.1.
5. Danach die Status in DevGuard auf `implemented` setzen und diese Tabelle angleichen.

## Weitere Controls

Die restlichen Controls (SOLLTE/KANN, erhöht und weitere Praktiken, ca. 100 Fragen) werden hier in
derselben Tabellenform ergänzt, sobald sie beantwortet sind.
