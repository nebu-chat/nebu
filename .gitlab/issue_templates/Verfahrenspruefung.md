<!-- markdownlint-disable MD041 -->
<!-- Annual / event-driven review of the development, test, configuration and
     asset procedures (Grundschutz++ DEV.1.2, TEST.1.2, KONF.1.2, ASST.1.2).
     Procedure: docs/compliance/verfahren-und-zustaendigkeiten.md -->

## Anlass

- [ ] Jährliche Regelprüfung
- [ ] Anlassbezogen (Grund: )

## Prüfpunkte

- [ ] Entwicklung: Beschreibung in `verfahren-und-zustaendigkeiten.md` und `CONTRIBUTING.md` entspricht der gelebten Praxis (Branching, Pipeline, Reviews)
- [ ] Test: Teststufen und CI-Gates entsprechen `.gitlab-ci.yml`
- [ ] Konfiguration: Konfigurationsquellen (Env, `server_config`, `deploy/`) und Änderungsweg sind aktuell
- [ ] Assets: Inventar und Umgang mit Informationen/Löschung sind aktuell
- [ ] Zuständigkeiten: `CODEOWNERS` und Rollentabelle stimmen mit den tatsächlich zuständigen Personen überein
- [ ] Bekanntgabe: Zuständige kennen die aktuelle Fassung (Hinweis in MR/Release-Notes/Onboarding)
- [ ] `docs/compliance/grundschutz-plusplus-antworten.md` und `SystemSecurityPlan.json` / DevGuard-Antworten aktualisiert

## Ergebnis

<!-- Änderungen, beschlossene Maßnahmen, nächster Termin. Eintrag im Prüfprotokoll ergänzen. -->

/label ~compliance
