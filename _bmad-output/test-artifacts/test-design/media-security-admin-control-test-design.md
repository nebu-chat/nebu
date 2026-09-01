---
workflowStatus: 'completed'
totalSteps: 5
stepsCompleted: ['step-01-detect-mode', 'step-02-load-context', 'step-03-risk-and-testability', 'step-04-coverage-plan', 'step-05-generate-output']
lastStep: 'step-05-generate-output'
nextStep: ''
lastSaved: '2026-07-06'
---

# Test Design: Epic MEDIA — Media Security & Admin Control

**Date:** 2026-07-01 (Erstfassung) · **Update: 2026-07-06** (Delta unten)
**Author:** Murat (Test Architect) für Phil
**Status:** Draft — Epic-ID noch TBD, epic_num-Platzhalter `MEDIA` verwendet
**Source:** `_bmad-output/planning-artifacts/media-security-admin-control-epic.md` (14 fachliche Stories, Review-Stand 2026-07-06 / Review 8)

**Update — 2026-07-06 (Murat):** Epic ist seit der Erstfassung (8 Stories) auf **13 nummerierte
fachliche Stories + Story 6d** gewachsen (Reviews 2–8: Story 9, 10, 11, 13 neu, Story 6d neu,
Story 12 aus Review 3 bereits vorhanden aber bisher nicht mit Testzielen erfasst). Dieses Dokument
deckte bislang **nur Story 1–8** mit expliziten Testzielen ab — Stories **6d, 9, 10, 11, 12 und
13 (13a–13f) hatten keine einzige benannte Testziel-Zeile**, obwohl das Epic selbst (Review 8)
genau diese Lücke bereits als Auftrag vermerkt hatte. Dieses Update schließt die Lücke: alle
14 Stories (inkl. Sub-Pakete) haben jetzt mindestens ihre P0-Testziele benannt. Elf neue Risiken
(R-018–R-028) wurden identifiziert, davon **einer neuer Score-9-Blocker (R-028, Backup/Restore vs.
Legal-Hold)**. Keine neuen AC wurden dem Epic hinzugefügt — wo eine Story ihren Test bereits
implizit in der AC trägt (z.B. 13d Self-Approval-Negativtest, 13c Cron/Legal-Hold-Race, 6d
Retry-Idempotenz), wird hier nur der Testfall benannt und mit einem Risiko verknüpft, nicht die AC
dupliziert — dieser Test würde ohnehin in der ATDD-Red-Phase eines `/nebu-pipeline`-Laufs entstehen.

---

## Executive Summary

**Scope:** Epic-level test design für den Upload-Quarantäne → ClamAV-Scan → Download-Release-Prozess plus Admin-Oversight. **Update 2026-07-06:** Scope ist von 8 auf **13 fachliche Stories + Story 6d** (14 Testziel-Blöcke) gewachsen — dazu kamen admin-konfigurierbare Policy (Story 9), ein Scan-Health-Dashboard mit Kill-Switch (Story 10), admin-konfigurierbares Object-Storage-Ziel (Story 11), Gzip-Kompression (Story 12) und die konsolidierte Media-Lifecycle-Policy mit Two-Eyes-Delete (Story 13, die eigentliche R-015-Lösung). Dies ist eines der architektonisch dichtesten Epics im Projekt: neues State-Machine-Modul, neue externe Abhängigkeit (ClamAV via TCP), neue Async-Infrastruktur (Oban), Matrix-Spec-Konformität für zwei neue Endpoints, Concurrency-lastige Stall-/Race-/Quorum-Pfade, Cluster-weite Config-Konsistenz und Compliance-kritische Audit-/Retention-/Vier-Augen-Anforderungen für einen Behörden-Zielmarkt.

**Risk Summary:**

- Risiken identifiziert: **28** (17 Erstfassung + 11 neu am 2026-07-06 aus Stories 6d/9–13: R-018–R-028)
- Hochprioritäre Risiken (Score ≥6, inkl. Critical Blocker): **21** (13 Erstfassung + 8 neu: R-018, R-019, R-020, R-021, R-022, R-024, R-027 als High + R-028 als zweiter Critical Blocker)
- **Kritische Blocker (Score 9): 2**
  1. DSGVO Art. 17 (R-015) — **in ADR-030 + Story 13e/13d adressiert** (Restriction-of-Processing + Two-Eyes-Delete); Blocker bleibt bis `MEDIA.8-INT-001` grün + Legal-Review durch.
  2. **(neu) Backup/Restore vs. Hard-Delete & Legal-Hold (R-028)** — **noch UNGELÖST**, keine Story/AC existiert, Offene Entscheidung #11 muss vor Dev-Start von Story 8a/13c/13d geklärt werden.
- Kategorien-Verteilung (alle 28 Risiken, primäre Kategorie): SEC (9), DATA/Compliance (6), TECH/Concurrency (6), OPS (4), PERF (2), BUS (1)

**Coverage Summary (grobe Schätzung, siehe Resource Estimates):**

- P0-Szenarien: 77 (~154–216h) — davon 43 neu am 2026-07-06
- P1-Szenarien: 46 (~46–64h) — davon 20 neu
- P2/P3-Szenarien: 31 (~16–24h) — davon 9 neu
- **Gesamtaufwand:** ~237–338h (~30–42 Personentage) für das volle 14-Story-Epic, inkl. aller Infra-Setup-Kosten (ClamAV/Oban/Multi-Node/Secret-Tier)
- **Coverage-Delta:** Vor diesem Update hatten 6 von 14 Story-Blöcken (6d, 9, 10, 11, 12, 13) **keine einzige** benannte Testziel-Zeile — das entspricht der von einer vorherigen Party-Runde geschätzten ~60%-Abdeckung. Nach diesem Update hat **jeder** Story-Block mindestens seine P0-Testziele benannt; die einzige verbleibende echte Lücke ist R-028 (Backup/Restore), weil dafür **keine Story existiert**, nicht weil das Testdesign sie ausgelassen hätte.

**Bestehende Testinfrastruktur (bereits im Repo, wiederverwenden statt neu erfinden):**

- `server/test/nebu/media/{media_upload_test.exs, media_download_test.exs, media_access_control_test.exs, media_range_request_test.exs, media_thumbnail_test.exs, url_preview_test.exs, media_fakes.exs, media_test_support.exs}` — bestehende Media-Testbasis, die durch dieses Epic erweitert (nicht ersetzt) wird.
- `Nebu.Media.SSRF` (`server/lib/nebu/media/ssrf.ex`) — bereits implementierte DNS-Rebinding-sichere SSRF-Guard. **Story 7 MUSS diese wiederverwenden**, sobald `webhook_url` jemals admin-konfigurierbar wird (siehe R-005), statt eine Parallel-Implementierung zu bauen.
- `e2e/` — Playwright/Cucumber-Suite (`.features-gen/`, `step-definitions/`, `playwright.config.ts`) für Admin-UI-E2E.
- `k6/scenarios/{gold-tier.js, silver-tier.js}` — bestehende Load-Test-Basis, Vorlage für neue Media-Burst-Szenarien.
- `server/test/test_helper.exs` — Pattern für shared Test-Support-Module (`Code.require_file`), das für Oban- und ClamAV-Stub-Support in gleicher Weise erweitert werden sollte.

**Neu einzuführende Testinfrastruktur (Prerequisite, vor Story 3/4):**

- Mock-clamd-GenServer-Stub (INSTREAM-Protokoll-Simulator) — in Story 3 als AC bereits gefordert, hier als projektweite Voraussetzung markiert.
- Oban-Test-Helper-Modul (analog zu `media_test_support.exs`) — **Oban existiert noch nicht im Repo**, daher eigenes Risiko (R-011).
- EICAR-Testdatei-Fixture (`eicar.com`) für echten ClamAV-Integrationstest (Epic-DoD fordert das explizit).
- k6-Szenario `media-upload-burst.js` für Story 2/4 Lastverhalten.

---

## Not in Scope

| Item | Reasoning | Mitigation |
|---|---|---|
| **Scanner-Override (`infected → released` durch Admin)** | Epic-Autor hat dies explizit als "nicht in diesem Epic" markiert (Offene Entscheidung #1) — Bypass-Risiko zu hoch ohne eigenes ADR + `media_admin_override`-Rolle | Negativ-Regressionstest: kein Code-Pfad in `Nebu.Media.StateMachine` darf diese Transition erlauben (siehe R-017) |
| **SMTP-Mail-Benachrichtigungen** | Explizit als separater Story-Kandidat für später vertagt (Story 7) | Kein Testbedarf in diesem Epic |
| **`media_state_transitions`-Archivierung/Rollup** | Als Follow-on-Story vorgemerkt (Offene Entscheidung #5) | Kein Testbedarf in diesem Epic; Tabellenwachstum ist ein späteres OPS-Risiko |
| **Admin-UI-Konfigurierbarkeit von `webhook_url`** | Epic legt fest: nur `config.exs`, Ops-only, deploy-time | Falls sich das ändert: SSRF-Test-Suite (Wiederverwendung `Nebu.Media.SSRF`) wird dann Pflicht — siehe R-005 |
| **Inline-Preview/Thumbnail für Admin-Overview** | Story 5 zeigt explizit nur Text-Metadaten, kein Rendering von Dateiinhalten | Kein Testbedarf jetzt; falls später ergänzt: Sandboxed-Origin + `nosniff` + CSP-Tests nachziehen |

---

## Risk Assessment

### Critical Blocker (Score = 9)

| Risk ID | Category | Description | Probability | Impact | Score | Mitigation | Owner | Timeline |
|---|---|---|---|---|---|---|---|---|
| **R-015** | BUS/Compliance | **DSGVO Art. 17 — Erasure-Request für eigene Medien.** ~~in keiner Story-AC abgedeckt~~ → **ADRESSIERT (Winston-Review 5, 2026-07-02): Story 13e + ADR-030.** Reframing: die ursprüngliche Mitigation („User kann eigene Medien löschen") war für die Behörden-/Firmen-Zielgruppe **falsch** (Beweismittel + Aufbewahrungspflicht, Art. 17(3)). Korrektes Modell: Erasure-Request = **Restriction-of-Processing** (sofort unsichtbar + Legal-Hold, Bytes erhalten), physische Löschung nur **Vier-Augen** (Story 13d). | 3 | 3 | **9** | ~~Story 8 ergänzen~~ → **umgesetzt in Story 13e** (Erasure → `:deleted` + `legal_hold`, aus jedem Scan-State) + Story 13d (Two-Eyes-Release). Test: `MEDIA.8-INT-001` (neu gefasst, siehe unten). **Legal-Review-Gate bleibt** (DSB bestätigt Art. 17(3)-Basis). | Phil (Product) + Dev | Vor Epic-Abschluss (Story 13e) |
| **R-028** *(neu, Update 2026-07-06)* | DATA/Compliance | **Backup/Restore vs. Hard-Delete & Legal-Hold (Offene Entscheidung #11, Kassandras Blocker aus Review 8).** Ein Restore auf einen Snapshot vor einem Hard-Delete oder vor einem Legal-Hold-Set kann die jeweilige rechtliche Garantie unterlaufen — DB sagt „hard-deleted"/„legal_hold=true", ein Restore bringt einen älteren Zustand zurück, in dem das nicht gilt (verschärft, falls Postgres und S3 getrennt mit unterschiedlichem RPO/RTO gesichert werden). Betrifft Story 8a, 13c, 13d. | 3 | 3 | **9** | **UNGELÖST — offene Vorfrage** laut Epic: „werden Postgres und S3/MinIO getrennt gesichert?" muss vor Spezifikation geklärt sein. ADR-030 wurde bereits um einen „Restore-Verfahren"-Abschnitt erweitert (Pflicht zu einem automatischen Post-Restore-Reconciliation-Lauf, der Hard-Deletes und Legal-Holds erneut durchsetzt, **bevor** das System wieder für Traffic freigegeben wird), aber es existiert noch **keine Story/AC**, die das implementiert. Test-Ziel vorgemerkt als Epic-Level-Test (siehe unten, kein `MEDIA.<N>`-Story-Slot vorhanden, da keine Story existiert). | Phil (Product-Entscheidung ausstehend) + Winston (Spezifikation) | **Vor Dev-Start von 8a, 13c, 13d** |

> ⚠️ Dies **war** der wichtigste Befund dieses Test-Designs. **Winston-Review 5 (2026-07-02):** in
> ADR-030 + Story 13 (13a–13e) aufgelöst — R-015 ist damit von „offen/Blocker" auf „adressiert,
> Test ausstehend" herabgestuft. Der Score-9-Blocker bleibt formal offen, **bis `MEDIA.8-INT-001`
> grün ist und das Legal-Review (Art. 17(3)) durch ist.**
>
> ⚠️ **R-028 ist zum Update-Zeitpunkt (2026-07-06) der zweite offene Score-9-Blocker** dieses Epics
> und im Unterschied zu R-015 **noch nicht** in einer Story adressiert — er hat nicht einmal eine
> AC-Heimat. Ohne Klärung von Offener Entscheidung #11 **vor** Story 8a/13c/13d-Start besteht das
> Risiko, dass Hard-Delete/Legal-Hold implementiert werden, ohne dass die Restore-Reconciliation je
> spezifiziert wird — R-028 bliebe dann bis zum Epic-Ende unentdeckt ungetestet. Test-Design kann
> hier nur eine **Platzhalter-Anforderung** benennen (siehe Coverage Plan), keine konkrete Test-ID,
> solange keine Story existiert.

### High-Priority Risks (Score ≥6)

| Risk ID | Category | Description | Story | Probability | Impact | Score | Mitigation | Owner | Timeline |
|---|---|---|---|---|---|---|---|---|---|
| R-001 | SEC | Ownership-Check beim PUT-Upload fehlt/regressiert — war bereits einmal in der ersten Draft-Fassung vergessen. Ohne ihn kann User B den `/create`-Reservierungsslot von User A befüllen. | 2 | 2 | 3 | 6 | Explizite Regressions-Testmatrix: für jede Kombination `actor ≠ uploader` MUSS `403 M_FORBIDDEN` zurückkommen, unabhängig vom State. Test direkt an die AC gekoppelt, nicht nur "State stimmt". | Dev | Story 2 |
| R-002 | SEC | Download-Gate als "einzige Erfolgsbedingung" wird nur so lange eingehalten, wie **jeder** Media-Serving-Endpoint ihn aufruft. Ein künftiger neuer Endpoint (z.B. Thumbnail-Preview, Federation-Proxy) könnte den Gate-Check vergessen. | 1 | 2 | 3 | 6 | Architektur-Test: Enumeriere alle Routen, die Datei-Bytes ausliefern (`/_matrix/media/v3/download/`, `/_matrix/client/v1/media/download/`, Thumbnail-Route) und assertiere für jede State-Werte-Kombination die korrekte Antwort. CI-Grep zusätzlich zum Story-1-Invarianten-Check erweitern auf "jede neue Route unter `Nebu.Media` muss `StateMachine`-Gate durchlaufen". | Dev | Story 1, laufend |
| R-003 | SEC | Stored-XSS via Dateiname in Admin-LiveView (Story 5) — Impact hoch (Admin-Session-Kompromittierung), da HEEx-Escaping eine Konvention, kein Compiler-Zwang ist. | 5 | 2 | 3 | 6 | LiveView-Test mit `<script>`/HTML-brechenden Dateinamen (`"><img src=x onerror=alert(1)>.pdf`) — assertiere escaped Output. Zusätzlich CI-Grep-Guard: kein `raw/1` im Dateinamen-Renderpfad (bereits als AC gefordert — hier als Testziel konkretisiert). | Dev + Kassandra (Security-Review) | Story 5 |
| R-004 | SEC/Compliance | Anonymität von `:admin_blocked` (404 statt 451) muss **byte-identisch** zur Antwort für eine wirklich nicht-existente `mediaId` sein — sonst ist die Behörden-Kernanforderung ("keine Aussage, ob Datei existierte") unterlaufen. | 1 | 2 | 3 | 6 | Kontrakttest: Statuscode, `errcode`, Response-Body UND Header (`Content-Length`, `Content-Type`) für `:admin_blocked` vs. echtes `M_NOT_FOUND` vergleichen — müssen identisch sein. Timing-Seitenkanäle sind in ExUnit nicht sinnvoll automatisierbar → als dokumentierte Grenze im Bericht vermerken, nicht stillschweigend auslassen. | Dev + Kassandra | Story 1 |
| R-006 | DATA/Compliance | **Unveränderlichkeit von `media_state_transitions` wird nur durch eine Grep-Konvention im Elixir-Code erzwungen, nicht durch DB-Rechte.** Eine rohe `Ecto.Adapters.SQL.query`-UPDATE, eine künftige Migration oder ein Admin-`psql`-Zugriff könnten die Audit-Kette trotzdem brechen — der Grep-Check in der AC sieht das nicht. | 1 | 2 | 3 | 6 | **Empfehlung über die AC hinaus:** DB-seitige Durchsetzung ergänzen (`REVOKE UPDATE, DELETE ON media_state_transitions FROM <app_role>` oder ein `BEFORE UPDATE/DELETE`-Trigger, der eine Exception wirft). Integrationstest, der über die App-DB-Rolle direkt ein UPDATE/DELETE versucht und eine Postgres-Fehlermeldung erwartet — nicht nur Abwesenheit im Code. | Dev + Winston (Architektur-Entscheidung als Mini-ADR) | Story 1 |
| R-007 | DATA/Compliance | Hard-Delete-Invariante (`media_files`-Record bleibt immer bestehen, nur `file_path`/`uploader_id` genullt, `file_hash`+Timestamps bleiben) ist die zentrale Compliance-Zusage des Epics — Korrektheit über alle Pfade (Retention-Cron, manueller Admin-Hard-Delete, Orphan-Detection) ist nicht trivial. | 2 | 3 | 3 | 6 | Property-artiger Test: für jeden Ausgangszustand, der `hard_deleted` erreichen kann, assertiere nach Hard-Delete exakt das erwartete Feld-Set (genullt vs. erhalten) — als eine parametrisierte Testsuite über alle Pfade, nicht acht Einzeltests mit Copy-Paste-Risiko. | Dev | Story 8 |
| R-008 | TECH/Concurrency | Stall-Mechanismus (Story 2): Race zwischen State-Check und PubSub-Subscribe — wenn der Scan-Worker **zwischen** initialem Check und Subscribe fertig wird, verpasst der Stall-Request den Broadcast und hängt bis zum Timeout (kein Hard-Fail, aber falsches Nutzererlebnis + versteckter Bug). | 3 | 2 | 3 | 6 | Deterministischer Concurrency-Test: Subscribe **vor** dem State-Re-Check erzwingen (`subscribe → check → maybe-receive` statt `check → subscribe → receive`), Testfall mit künstlich verzögertem Scan-Abschluss exakt im Race-Fenster (via Test-Hook/`:sys`-Introspektion, nicht `Process.sleep`-Raten). | Dev | Story 2 |
| R-009 | TECH/Concurrency | Expiry-Check-Race: PUT-Handler und Cleanup-Cron könnten gleichzeitig über denselben `:reserved`-Record entscheiden (Cron löscht, PUT schreibt currently). Epic markiert das selbst als "Race". | 2 | 3 | 3 | 6 | Integrationstest, der den Cron-Job manuell (nicht zeitgesteuert) parallel zum PUT triggert (z.B. via `Task.async` + expliziter Synchronisationspunkt); assertiere genau einen Gewinner, keinen Crash, keinen doppelten State-Transition-Eintrag. | Dev | Story 2, 8 |
| R-010 | TECH | Idempotenz-Falle: identischer Retry eines bereits erfolgreichen PUT MUSS `409` liefern, nicht `200` — Spec kennt keine Idempotenz-Ausnahme; naive Client-Retry-Logik wird das falsch erwarten, wenn der Dev es "fixt". | 2 | 2 | 2 | 4 | Expliziter Regressionstest mit **byte-identischem** Zweit-Payload vom selben Client — erwartet `409 M_CANNOT_OVERWRITE_MEDIA`, niemals `200`. Kommentar im Test verlinkt auf die AC-Implementation-Trap-Notiz. | Dev | Story 2 |
| R-011 | OPS | **Oban ist eine komplett neue Abhängigkeit in diesem Repo** (kein bestehendes Testmuster, keine `Oban.Testing`-Konvention). Hohe Wahrscheinlichkeit von Fehlkonfiguration (Sandbox-Modus, Testing-Modus `:manual` vs `:inline`), die zu falsch-grünen oder flaky Tests führt, ohne dass echte Job-Logik geprüft wurde. | 3 | 2 | 3 | 6 | Vor Story-4-Start: ein kanonisches Oban-Test-Support-Modul etablieren (analog `media_test_support.exs`), das (a) `Oban.Testing.perform_job/2` für reine Unit-Logik nutzt UND (b) mindestens einen echten Enqueue→Execute-Integrationstest via `Oban.drain_queue/2` gegen den Sandbox-Repo bereitstellt. Dieses Muster dann für alle Story-4/7/8-Worker-Tests wiederverwenden. | Dev | Vor Story 4 |
| R-012 | OPS/SEC | ClamAV-GenServer-Fehlerpfade (Timeout, Connection-Drop, malformed Response, clamd down) müssen **garantiert fail-closed** sein — eine ungetestete Fehler-Variante könnte künftig versehentlich zu `released` statt `quarantined`/`scan_failed` führen (Sicherheitsregression, nicht nur Bug). | 2 | 3 | 3 | 6 | Tabellengetriebene Unit-Tests gegen den Mock-clamd-Stub für alle 4 Fehlerklassen (bereits AC in Story 3) PLUS ein Worker-Test (Story 4), der beweist: wiederholtes `{:error, _}` treibt `quarantined→scanning→quarantined`-Retries und endet in `scan_failed` — **niemals** `released`. | Dev | Story 3, 4 |
| R-013 | PERF | Orphan-Detection-Query (Story 8) läuft gegen `events.content JSONB @> ...` ohne bestätigten GIN-Index — bei großen `events`-Tabellen (realistisch für Kommunen-Instanzen über Jahre) potenziell teurer Sequential Scan, der den täglichen Cron blockiert oder die DB belastet. Epic markiert das selbst als offene Frage #3. | 2 | 3 | 3 | 6 | **Vor Story-8-Merge zwingend:** `EXPLAIN ANALYZE` gegen eine mit realistischer Größenordnung (≥100k Events) geseedete Test-DB; falls Seq Scan/hohe Kosten → GIN-Index-Migration ergänzen. Dies als Gate-Kriterium, nicht nur als Beobachtung, in die DoD aufnehmen. | Dev + DBA-Review | Vor Story 8 |
| R-016 | TECH | Postgres-ENUM-Erweiterung (`ALTER TYPE ... ADD VALUE` für `scan_failed` in Story 4, nachträglich zum in Story 1 angelegten Typ) — `ADD VALUE` darf laut Postgres-Semantik nicht in derselben Transaktion verwendet werden, in der es hinzugefügt wurde; zusätzlich: Elixir-seitige State-Listen dürfen den neuen Wert nicht vergessen (Epic warnt davon explizit). | 2 | 2 | 2 | 4 | (a) Migrationstest: `ADD VALUE`-Migration läuft isoliert, kein Verbrauch des neuen Werts in derselben Transaktion/Deploy-Schritt. (b) Schema-Drift-Test: `SELECT enum_range(NULL::media_state)` aus der DB MUSS exakt der Elixir-seitigen State-Liste in `Nebu.Media.StateMachine` entsprechen — schlägt laut an, wenn eine Seite den anderen vergisst. | Dev | Story 4 |

**Neue Risiken aus Stories 6d/9–13 (Update 2026-07-06):**

| Risk ID | Category | Description | Story | Probability | Impact | Score | Mitigation | Owner | Timeline |
|---|---|---|---|---|---|---|---|---|---|
| R-018 | OPS/SEC | **`media_config`-Cluster-Cache-Invalidierung (Story 9a).** Config wird per Erlang `:pg`-Broadcast zwischen Knoten invalidiert (Muster von `Nebu.Web.OidcConfig` übernommen); ein verpasster Broadcast (z.B. Netzpartition) hält einen Knoten auf einer veralteten Config — sicherheitsrelevant bei `mime_denylist` oder `media_admin_override`-Widerruf. | 9a | 2 | 3 | 6 | Multi-Node-Integrationstest: Config-Änderung auf Knoten A muss auf Knoten B ohne Neustart ankommen; zusätzlich TTL-Fallback-Test (verpasste Invalidierung + Ablauf des TTL erzwingt Neuladen). | Dev | Story 9a |
| R-019 | DATA/Compliance | **ADR-032-Reihenfolge (Postgres↔S3-Konsistenz) nicht eingehalten (Story 8a, 8c, 13c, 13d).** Jeder Delete-/Archiv-Pfad, der DB-State und S3-Blob gemeinsam anfasst, muss die in ADR-032 festgelegte Reihenfolge (DB-Zwischenzustand → Blob löschen → `storage_key = NULL`) einhalten; ein Crash zwischen den Schritten ohne funktionierenden Reaper hinterlässt entweder eine verwaiste DB-Referenz auf einen gelöschten Blob (harmlos) oder — schlimmer — einen weiterhin existierenden Blob trotz „gelöscht" in der DB (Compliance-Verletzung). | 8a, 8c, 13c, 13d | 2 | 3 | 6 | Crash-Simulation zwischen den ADR-032-Schritten (Test-Hook, der nach dem Zwischenzustand abbricht); Reaper-Job-Test, der den Zwischenzustand korrekt vervollständigt, ohne den bereits gelöschten Blob erneut anzufassen. | Dev | Story 8a, vertieft 13c/13d |
| R-020 | SEC/Compliance | **Two-Eyes-Delete-Quorum-Bypass (Story 13d).** Die gesamte R-015-Mitigation steht und fällt mit der Korrektheit des Vier-Augen-Gates: Self-Approval über zwei Sessions desselben Actors, ein Rollen-Downgrade zwischen Proposal und Confirm, oder ein Race zwischen zwei gleichzeitigen Confirms könnten das Quorum aushebeln oder einen Doppel-Delete erzeugen. | 13d | 2 | 3 | 6 | Drei dedizierte Negativ-/Race-Tests: Self-Approval-Bypass (zwei Requests, ein Actor), Downgrade-Race (Rollenentzug zwischen Proposal/Confirm invalidiert das Confirm), Concurrent-Confirm-Race (genau ein Gewinner, kein Doppel-Delete). Diese Tests sind bereits als Negativ-Test-Anforderung in der Story-13d-AC benannt — hier nur als Risiko verankert, damit sie nicht in der Umsetzung wegfallen. | Dev + Kassandra (Security-Review) | Story 13d |
| R-021 | TECH/Concurrency | **Legal-Hold/Cron-Race (Story 13c).** Der `MediaLifecycleWorker` muss `legal_hold` innerhalb derselben Transaktion lesen, in der er die Transition schreibt — ein zwischen Batch-Selektion und Transition gesetzter Legal-Hold darf die Datei nicht mehr erfassen, ein währenddessen aufgehobener erst im nächsten Tick wirken. | 13c | 2 | 3 | 6 | Deterministischer Concurrency-Test mit explizitem Synchronisationspunkt zwischen Batch-Selektion und Transition (kein `Process.sleep`-Raten) — eigener Testfall, nicht Wiederverwendung der Orphan-Query-Race-Tests (andere Guard-Semantik: Referenzierung vs. explizites Flag). | Dev | Story 13c |
| R-022 | DATA/Compliance | **mxc→Raum-Index-Vollständigkeit (Story 13f).** Der Index muss alle sechs mxc-tragenden Felder abdecken (`content.url`, `content.info.thumbnail_url`, `content.avatar_url`, verschlüsselt `content.file.url` + `content.info.thumbnail_file.url`). Ein übersehenes Feld lässt ein Medium beim Raum→Space-Join „unsichtbar" werden — es fällt auf `global` zurück, obwohl eine strengere Raum-/Space-Policy gelten sollte. | 13f | 2 | 3 | 6 | Parametrisierter Test über alle sechs Feldtypen (je ein Event-Typ pro Feld) — jedes Feld MUSS das referenzierte Medium im Index finden. Negativtest: ein bewusst nicht indexiertes siebtes Feld (falls je hinzugefügt) muss beim nächsten Review aktiv auffallen, nicht still durchrutschen. | Dev | Story 13f |
| R-024 | SEC | **Storage-Secrets im Klartext statt verschlüsseltem Feld (Story 11a).** `access_key`/`secret_key` müssen im bestehenden Feld-Verschlüsselungs-Tier (analog `email_encrypted`) liegen, nicht als `TEXT`. Ein Klartext-Leck (DB-Dump, Backup, Log) würde vollen S3-Zugriff offenlegen. | 11a | 2 | 3 | 6 | Schema-/Spalten-Typ-Test plus Grep-Guard: Secret-Spalten dürfen nicht `TEXT` sein; Integrationstest liest die Rohspalte direkt aus der DB und erwartet Chiffrat, nicht Klartext. Audit-Log-Test: `media_storage_config_updated` enthält niemals die Secret-Werte selbst. | Dev | Story 11a |
| R-027 | SEC | **Bulk-Override-Signatur-Scope-Leakage bei überlappenden Kohorten (Story 6d).** Die Kohorten-Query für Bulk-Override muss strikt auf `scan_metadata["signature"] = cohort_key` filtern; bei zwei gleichzeitig aktiven Signaturen A und B darf ein Bulk-Override auf A keine B-Datei berühren, auch wenn der Admin-Tabellenfilter zum Aktionszeitpunkt beide zeigt. Ein Leck würde faktisch identifizierte Malware unter falscher Begründung freigeben. | 6d | 2 | 3 | 6 | Negativtest mit zwei gleichzeitig aktiven Signaturen im selben Zeitraum: Bulk-Override auf A lässt jede B-Datei unverändert im `:infected`-State, auch bei überlappendem Tabellenfilter. Bereits als AC-Negativtest in Story 6d benannt — hier risikoverankert. | Dev + Kassandra | Story 6d |

### Medium-Priority Risks (Score 3-4)

| Risk ID | Category | Description | Story | Probability | Impact | Score | Mitigation | Owner |
|---|---|---|---|---|---|---|---|---|
| R-010 | TECH | (siehe oben, Score 4) | 2 | 2 | 2 | 4 | siehe oben | Dev |
| R-016 | TECH | (siehe oben, Score 4) | 4 | 2 | 2 | 4 | siehe oben | Dev |
| R-014 | PERF | Upload-/Scan-Durchsatz unter Burst-Last (viele parallele Uploads erschöpfen Oban-Queue-Concurrency, ClamAV-TCP-Verbindungspool oder das Stall-Request-Semaphor aus Story 2). | 2, 4 | 2 | 2 | 4 | k6-Burst-Szenario (siehe Coverage Plan `MEDIA.2-PERF-001`) statt nur Unit-Test — validiert die AC "Limit auf gleichzeitige Stall-Requests" tatsächlich unter Last. | QA/Dev |
| R-023 *(neu)* | SEC | **E2EE-Policy-Resolution-Grenzverletzung (Story 13f).** Ein Implementierungsfehler in `effective_for_media/1` könnte versuchen, Megolm-verschlüsselten `content` zu introspizieren, statt sauber auf `global` zurückzufallen — Verstoß gegen die ADR-011-E2EE-Garantie. Niedrige Wahrscheinlichkeit (AC verlangt den Fallback explizit), aber hoher Impact (Architektur-Grenzverletzung), daher wie R-003 (XSS) trotz Score 3 als Pflichttest behandelt. | 13f | 1 | 3 | 3 | Test: E2EE-Raum (verschlüsselter `content`) → `effective_for_room/1` liefert `global`, ohne Fehler, ohne jeden Zugriffsversuch auf den Chiffrat-Content (Assertion auch auf Abwesenheit von Decrypt-Aufrufen, nicht nur auf das Ergebnis). | Dev + Kassandra |
| R-025 *(neu)* | OPS | **Fail-Open-Backlog-Wachstum ohne Obergrenze (Story 10d).** Im Default-Modus `fail_open` stauen sich Uploads unbegrenzt in `:quarantined`, solange ClamAV down ist — kein Datenverlust, aber potenziell unbegrenztes Storage-/Queue-Wachstum ohne Alarmierung, falls Story 10c-Schwellwerte nicht sauber greifen. | 10d | 2 | 2 | 4 | Integrationstest: `fail_open` nimmt Uploads weiterhin an (kein Crash, kein 5xx), UND Story-10c-Backlog-Alert triggert zuverlässig, bevor der Zustand unbemerkt eskaliert. | Dev |
| R-026 *(neu)* | DATA | **Bulk-Retry-Idempotenz-Verletzung (Story 6d).** Ein erneuter Retry-Aufruf auf einen `batch_id`-Batch darf nur zuvor `failed`-Items erneut anfassen; ein Implementierungsfehler könnte bereits `succeeded`/`skipped`-Items erneut transitionieren und doppelte Audit-/Transition-Einträge erzeugen. | 6d | 2 | 2 | 4 | Test: Retry auf einen Batch mit gemischtem Ergebnis (`succeeded`/`skipped`/`failed`) verändert ausschließlich die `failed`-Teilmenge; kein doppelter `media_state_transitions`- oder `audit_log`-Eintrag für bereits abgeschlossene Items. | Dev |

### Low-Priority Risks (Score 1-2)

| Risk ID | Category | Description | Story | Probability | Impact | Score | Action |
|---|---|---|---|---|---|---|---|
| R-005 | SEC | SSRF via `webhook_url` — aktuell nur statisches `config.exs` (kein Angreifer-Input), daher niedrige *aktuelle* Wahrscheinlichkeit. | 7 | 1 | 2 | 2 | Monitor. **Eskalationstrigger dokumentieren:** Sobald `webhook_url` admin-konfigurierbar wird, springt dieses Risiko auf Score 6 (P2×I3) — dann ist Wiederverwendung von `Nebu.Media.SSRF` + Save-Time-Validierung (analog SCIM/OIDC-Directory-Endpoints) Pflicht, nicht optional. |
| R-017 | TECH | Scanner-Override (`infected → released`) ist bewusst nicht implementiert — Risiko ist die *versehentliche* künftige Einführung ohne die geforderte separate Rolle/ADR. | 1 | 1 | 1 | 1 | Negativ-Regressionstest jetzt schon anlegen (siehe `MEDIA.1-UNIT-014`), damit ein künftiger PR, der diese Transition erlaubt, sofort rot wird. |

### Risk Category Legend

- **TECH**: Technisch/Architektur (State-Machine-Korrektheit, Concurrency, Enum-Drift)
- **SEC**: Sicherheit (Ownership, XSS, Anonymität, SSRF, Fail-Closed-Verhalten)
- **PERF**: Performance (Query-Kosten, Durchsatz unter Last)
- **DATA**: Datenintegrität (Audit-Trail-Unveränderlichkeit, Hard-Delete-Invariante)
- **BUS**: Business-/Compliance-Impact (DSGVO Art. 17)
- **OPS**: Betrieb (neue Oban-Infrastruktur, ClamAV-Betriebsverhalten)

---

## NFR Planning

**Purpose:** Epic-spezifische NFR-Schwellenwerte, geplante Validierung und erwartete Evidenz für ein späteres `nfr-assess` festhalten. Dies ist keine finale PASS/CONCERNS/FAIL-Bewertung.

| NFR Category | Requirement / Threshold | Risk Link | Planned Validation | Evidence Needed |
|---|---|---|---|---|
| **Security** | State-Gate ist einzige Erfolgsbedingung für Download; Ownership-/Expiry-Checks vor jedem PUT; Admin-Blocked-Antwort byte-identisch zu "nicht existent"; kein XSS via Dateiname; ClamAV-Fehlerpfade fail-closed | R-001, R-002, R-003, R-004, R-012 | ExUnit Unit+Integration (State-Gate-Matrix, Ownership-Matrix, LiveView-XSS-Test, Fehlerpfad-Tabellentests) + Kassandra-Security-Review am Epic-Ende (laut `nebu-pipeline`-Konvention) | Testreports, CI-Grep-Job-Output, Kassandra-Review-Protokoll |
| **Compliance (DSGVO/Audit)** | `media_state_transitions` unveränderlich (DB-Ebene, nicht nur App-Ebene); Hard-Delete nullt exakt definierte Felder; Art. 17-Löschpfad für User-eigene Medien unabhängig vom Scan-Status | R-006, R-007, **R-015 (UNKNOWN/BLOCKER)** | DB-Privilege-Integrationstest, parametrisierter Property-Test über alle Hard-Delete-Pfade, **neuer** P0-Test sobald Art.-17-AC existiert | CI-Job-Output (REVOKE wirksam), Testsuite-Report, explizite AC-Ergänzung in Story 8 |
| **Reliability** | Oban-Retry/Backoff/Lifeline/Graceful-Shutdown funktionieren; Concurrency-Races (Stall, Expiry, Idempotenz) sind deterministisch getestet; ENUM-Erweiterung bricht keine bestehende State-Logik | R-008, R-009, R-010, R-011, R-016 | `Oban.Testing`-Unit-Tests + `Oban.drain_queue/2`-Integrationstest; dedizierte Race-Window-Tests mit expliziten Synchronisationspunkten; Schema-Drift-Test (DB-Enum ↔ Elixir-Liste) | ExUnit-Reports, dokumentiertes Oban-Test-Helper-Pattern, CI-Migrationslauf |
| **Performance** | Orphan-Detection-Query bleibt performant auf großen `events`-Tabellen; Upload-/Scan-Durchsatz hält Stall-Timeout-SLA unter Burst-Last | R-013, R-014 | `EXPLAIN ANALYZE` gegen geseedete Großtabelle (≥100k Events); neues k6-Szenario `media-upload-burst.js` mit p95-Latenz-Threshold für Stall-to-Release | EXPLAIN-Plan-Artefakt, k6-Summary-JSON mit Schwellenwerten |
| **Maintainability** | Einzige-Quelle-der-Wahrheit für State-Liste (DB-Enum ↔ Elixir); `AuditWriter.@known_actions` bleibt synchron mit neuen Admin-Actions (**bekannte Projekt-Falle**, siehe Projekt-Memory zu Audit-Allowlist-Merges); Story-1-Grep-Invariante deckt auch künftige neue Media-Routen ab | R-002, R-016 | CI-Grep-Job (State-Mutation-Invariante), Compile-Zeit-/Test-Guard, der prüft, dass jede in Story 6 eingeführte Admin-Action (`Block/Unblock/Delete/Rescan`) auch in `AuditWriter.@known_actions` registriert ist | CI-Job-Output, Testreport |

**Unknown thresholds:**
- **R-015 (DSGVO Art. 17)**: ~~Kein Schwellenwert vorhanden~~ → **gelöst** (Story 13e/ADR-030), Test `MEDIA.8-INT-001`.
- **k6-Latenz-SLA für Stall-Mechanismus**: Epic definiert `max_stall_ms` (Default 20s) und Download-`?timeout=N` (Default 20000ms), aber keinen p95/p99-Zielwert unter Last — als UNKNOWN markieren, bis Phil/Ops einen konkreten Wert vorgibt.
- **R-028 (Backup/Restore-Reconciliation, Update 2026-07-06)**: Kein Test-ID vergeben, weil keine Story/AC existiert — Offene Entscheidung #11 (getrennte vs. gemeinsame Postgres/S3-Sicherung?) muss vor Dev-Start von Story 8a/13c/13d geklärt sein; siehe Critical-Blocker-Tabelle oben.
- **Data-Subject-Benachrichtigung (Offene Entscheidung #12, Update 2026-07-06)**: Kein Testziel formulierbar — ob/wie der Uploader bei Block/Delete/Erasure informiert wird, ist noch nicht entschieden. Sobald entschieden, braucht Story 13e eine AC-Ergänzung UND einen zugehörigen `MEDIA.13-*`-Test (inkl. Zustellstatus-Audit, falls entkoppelter Fire-and-Forget-Kanal gewählt wird). Bis dahin: nicht raten, als offenen Punkt im Exit-Kriterium führen.

---

## Entry Criteria

- [x] ~~Drei ADR-Kandidaten (Scanner-Auswahl, Async-Queue, HTTP-Statuscodes) finalisiert~~ → **erledigt (Update 2026-07-06):** alle neun Epic-ADRs (ADR-024–032) sind final in `docs/architecture/adr/` abgelegt
- [ ] Mock-clamd-GenServer-Stub verfügbar (INSTREAM-Protokoll-Simulator)
- [ ] Oban-Test-Support-Modul etabliert (siehe R-011) — **vor** Story 4
- [ ] EICAR-Testdatei (`eicar.com`) als Fixture verfügbar
- [ ] ClamAV-Container im `docker-compose.yml`/CI-Stack lauffähig (für E2E/Integrationstest mit echtem Scan)
- [ ] R-015 (DSGVO-Lücke) mit Phil geklärt: eigenes AK oder eigenes Ticket, **bevor** Story 8 als vollständig gilt
- [ ] **(neu, Update 2026-07-06)** Offene Entscheidung #11 (Backup/Restore vs. Legal-Hold, R-028) geklärt — **vor** Dev-Start von Story 8a/13c/13d
- [ ] **(neu)** Multi-Node-Testharness (`:pg`-Cluster, Story 9a) verfügbar — **vor** Story 9a
- [ ] **(neu)** `compliance_officer`-Rolle + zweite Admin-Testidentität verfügbar — **vor** Story 13d
- [ ] **(neu)** Secret-Verschlüsselungs-Tier für S3-Credentials identifiziert (Offene Entscheidung #9) — **vor** Story 11a

## Exit Criteria

- [ ] Alle P0-Tests grün
- [ ] Alle P1-Tests grün (oder triagierte Ausnahmen mit Owner)
- [ ] Keine offenen High-Risk-Items (Score ≥6) ohne dokumentierte Mitigation
- [x] R-006 (DB-seitige Audit-Trail-Durchsetzung) im ADR dokumentiert (ADR-031) — Design abgeschlossen; DB-Migration + `MEDIA.1-INT-007` in Story 1 zu implementieren
- [ ] R-013 (Orphan-Query-Performance) mit EXPLAIN-Plan-Nachweis abgeschlossen, bevor Story 8 in Produktion geht
- [ ] Kassandra-Security-Review am Epic-Ende durchgeführt (Pflicht laut `nebu-pipeline`-Konvention für ein Epic mit Malware-Scan + Admin-Actions)
- [ ] `CLAUDE.md` um Media-State-Machine-Invariante ergänzt (Epic-DoD)

---

## Explicit Test Goals by Story

*(Zusätzlich zur aggregierten P0–P3-Matrix unten — dies beantwortet direkt die Frage "was genau testen wir pro Story".)*

### Story 1 — Media State Machine Foundation

**Testziel:** Der Download-Handler ist der einzige Enforcement-Punkt, und die Transitions-Tabelle ist eine verlässliche, unveränderliche Audit-Quelle.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.1-UNIT-001 | Jede erlaubte State-Transition schreibt genau einen `media_state_transitions`-Eintrag mit korrektem `actor_type`/`actor_id` | Unit | P0 | R-006 |
| MEDIA.1-UNIT-002 | Jede **nicht** erlaubte Transition wird vom Guard abgelehnt (kein Teil-Update) | Unit | P0 | — |
| MEDIA.1-INT-003 | Download-Handler: für alle 8 States (inkl. `scan_failed`-Vorgriff) korrekte HTTP-Antwort (Matrix aus Story-1-AC) | Integration | P0 | R-002 |
| MEDIA.1-INT-004 | `:admin_blocked` vs. echtes `M_NOT_FOUND`: Statuscode, Errcode, Header byte-identisch | Integration | P0 | R-004 |
| MEDIA.1-INT-005 | Zweiter Download-Endpoint (`/_matrix/client/v1/media/download/`) verhält sich identisch zu `/_matrix/media/v3/download/` | Integration | P1 | R-002 |
| MEDIA.1-UNIT-006 | CI-Grep-Invarianz: kein direktes SQL-UPDATE auf `media_files.state` außerhalb `StateMachine` | Static/CI | P0 | R-002 |
| MEDIA.1-INT-007 | DB-seitiger Schreibschutz auf `media_state_transitions` (UPDATE/DELETE via App-Rolle schlägt fehl) — **über AC hinausgehend, siehe R-006** | Integration | P1 | R-006 |
| MEDIA.1-UNIT-014 | Negativtest: kein Guard erlaubt `:infected → :released` | Unit | P2 | R-017 |

### Story 2 — Async Upload Endpoints

**Testziel:** Spec-Konformität (403/404/409/413/429) und Race-Freiheit bei Ownership, Expiry und Stall.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.2-INT-001 | `POST /create`: Response enthält **beide** Felder (`content_uri`, `unused_expires_at`), kein Query-Parameter wird akzeptiert/ausgewertet | Integration | P0 | — |
| MEDIA.2-INT-002 | `POST /create`: Pending-Limit greift bei Überschreitung (`429` + `retry_after_ms`), konfigurierbar | Integration | P1 | R-014 |
| MEDIA.2-INT-003 | `PUT /upload`: fehlender `Content-Type` wird akzeptiert (Default `application/octet-stream`) | Integration | P1 | — |
| MEDIA.2-INT-004 | `PUT /upload`: `filename`-Query-Parameter wird persistiert und für `Content-Disposition` beim Download verwendet | Integration | P1 | — |
| MEDIA.2-INT-005 | **Ownership-Matrix**: PUT von jedem `actor ≠ uploader` → `403 M_FORBIDDEN`, für alle relevanten States | Integration | P0 | R-001 |
| MEDIA.2-INT-006 | PUT auf unbekannte/fremd-erzeugte/abgelaufene `mediaId` → exakt `404 M_NOT_FOUND` | Integration | P0 | — |
| MEDIA.2-INT-007 | PUT auf bereits befüllte `mediaId` → exakt `409 M_CANNOT_OVERWRITE_MEDIA` (kein generisches 400) | Integration | P0 | — |
| MEDIA.2-INT-008 | **Idempotenz-Falle**: identischer Retry nach Erfolg → weiterhin `409`, niemals `200` | Integration | P0 | R-010 |
| MEDIA.2-INT-009 | `413` wird **vor** Disk-Write ausgelöst (Content-Length + Streaming-Limit), unabhängig von ClamAV `max_file_size_bytes` | Integration | P0 | — |
| MEDIA.2-CONC-010 | Race: Expiry-Check im PUT-Handler läuft live, nicht nur über Cron — simulierter Wettlauf Cron-Trigger vs. PUT | Integration/Concurrency | P0 | R-009 |
| MEDIA.2-CONC-011 | Race: Stall-Subscribe vor State-Re-Check, kein verpasster Broadcast im Fenster zwischen Check und Subscribe | Integration/Concurrency | P0 | R-008 |
| MEDIA.2-INT-012 | Stall-Timeout-Default (20000ms) + `?timeout=N`-Override korrekt; Ablauf → `451 M_NOT_YET_UPLOADED` | Integration | P1 | — |
| MEDIA.2-PERF-013 | k6: Burst gleichzeitiger Stall-Requests bleibt unter konfiguriertem Limit, keine Ressourcenerschöpfung | k6 (Nightly) | P2 | R-014 |
| MEDIA.2-UNIT-014 | Synchroner Upload (`POST /media/v3/upload`) bleibt unverändert funktionsfähig (Regressionsschutz bestehender Suite) | Unit/Integration | P1 | — |

### Story 3 — ClamAV GenServer

**Testziel:** Niemals crashen, niemals unbounded blocken, jeder Fehlerfall liefert `{:error, reason}`.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.3-UNIT-001 | `scan_file/1` gegen Mock-clamd: sauberes Ergebnis → `{:ok, :clean}` | Unit | P0 | — |
| MEDIA.3-UNIT-002 | `scan_file/1` gegen Mock-clamd: Malware-Signatur → `{:ok, {:infected, sig}}` | Unit | P0 | R-012 |
| MEDIA.3-UNIT-003 | Fehlerklasse Timeout → `{:error, :timeout}`, kein Crash, kein unbounded receive | Unit | P0 | R-012 |
| MEDIA.3-UNIT-004 | Fehlerklasse Connection-Drop → `{:error, _}`, Auto-Reconnect danach funktionsfähig | Unit | P0 | R-012 |
| MEDIA.3-UNIT-005 | Fehlerklasse malformed Response → `{:error, _}`, keine Exception propagiert | Unit | P0 | R-012 |
| MEDIA.3-UNIT-006 | clamd beim Start nicht erreichbar → Log-Warning, GenServer startet trotzdem | Unit | P1 | — |
| MEDIA.3-UNIT-007 | Datei über `max_file_size_bytes` → `{:error, :file_too_large}`, kein Scan-Versuch | Unit | P1 | — |
| MEDIA.3-INT-008 | **Echter ClamAV-Container + EICAR-Testdatei** → `{:ok, {:infected, _}}` (Epic-DoD-Pflicht) | Integration (E2E-Stack) | P0 | R-012 |

### Story 4 — Async Scan Worker

**Testziel:** Fail-closed über den gesamten Retry-/Dead-Letter-Lebenszyklus; keine Elixir/DB-Enum-Drift.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.4-UNIT-001 | Happy Path: `quarantined→scanning→released`, PubSub-Broadcast ausgelöst | Unit (Oban.Testing) | P0 | R-011 |
| MEDIA.4-UNIT-002 | Infected Path: `scanning→infected`, `scan_metadata` mit Signatur gefüllt | Unit | P0 | — |
| MEDIA.4-UNIT-003 | Fehler-Path: `{:error,_}` → zurück `quarantined`, Oban-Retry ausgelöst (raise) | Unit | P0 | R-012 |
| MEDIA.4-INT-004 | **Fail-closed-Beweis**: wiederholtes `{:error,_}` über `max_attempts` hinweg endet in `scan_failed`, niemals `released` | Integration (`Oban.drain_queue/2`) | P0 | R-012 |
| MEDIA.4-INT-005 | `Oban.Plugins.Lifeline`: als `executing` hängengebliebener Job wird nach `rescue_after` wieder `available` | Integration | P1 | R-011 |
| MEDIA.4-INT-006 | Graceful Shutdown: SIGTERM mit `:shutdown_grace_period` lässt in-flight Scan fertig laufen | Integration | P2 | — |
| MEDIA.4-UNIT-007 | `discard/2`-Callback nach Erschöpfung: Admin-Notification via PubSub ausgelöst | Unit | P0 | — |
| MEDIA.4-UNIT-008 | `:file_too_large` → `released` mit `scan_metadata.skipped`, **kein** Retry, Audit-Log-Eintrag | Unit | P1 | — |
| MEDIA.4-MIG-009 | Schema-Drift-Test: DB-Enum-Werte == Elixir-seitige State-Liste nach `ADD VALUE`-Migration für `scan_failed` | Migration/Integration | P0 | R-016 |

### Story 5 — Admin Media Overview

**Testziel:** Korrekte, XSS-sichere Darstellung mit performanter Pagination/Realtime-Updates.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.5-LV-001 | Filter (State Multi-Select, MIME-Prefix, Uploader, Datum-Range) korrekt kombinierbar, State in URL-Params (Bookmark-fähig) | LiveView/Integration | P1 | — |
| MEDIA.5-LV-002 | Cursor-Pagination (kein OFFSET) liefert stabile Ergebnisse bei gleichzeitigen Inserts | LiveView/Integration | P1 | — |
| MEDIA.5-LV-003 | PubSub-Update aktualisiert nur betroffene Zeile, kein Full-Re-Render (Snapshot-Vergleich) | LiveView | P2 | — |
| MEDIA.5-LV-004 | Attention-Badge-Counts (`:quarantined`, `:scan_failed`, `:infected`) stimmen mit DB überein und aktualisieren sich unabhängig | LiveView/Integration | P1 | — |
| MEDIA.5-SEC-005 | **XSS-Regressionstest**: Dateiname mit HTML/Script-Payload wird escaped gerendert, kein `raw/1` im Renderpfad | LiveView/Security | P0 | R-003 |
| MEDIA.5-E2E-006 | Admin-Login → `/admin/media` → Filter setzen → Ergebnis sichtbar (Playwright, e2e/-Suite) | E2E | P1 | — |

### Story 6 — Admin Media Actions

**Testziel:** State-abhängige Aktionen sind korrekt gated, idempotent und lückenlos auditiert.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.6-INT-001 | Aktions-Verfügbarkeitsmatrix je State (Block/Unblock/Delete/Rescan) exakt wie AC-Tabelle | Integration | P0 | — |
| MEDIA.6-INT-002 | Jede Aktion schreibt `actor_type: :admin, actor_id` korrekt in `media_state_transitions` | Integration | P0 | R-006 |
| MEDIA.6-STATIC-003 | **`AuditWriter.@known_actions` enthält alle 4 neuen Actions** (bekannte Projekt-Falle: Merge ohne Allowlist-Update bricht Audit-Trail stillschweigend) | Static/CI | P0 | Projekt-Memory: Audit-Allowlist-Merge-Gotcha |
| MEDIA.6-INT-004 | Block/Unblock idempotent: erneuter Aufruf im Zielzustand → No-Op + Info-Flash, kein doppelter Transition-Eintrag | Integration | P1 | — |
| MEDIA.6-E2E-005 | Confirmation-Dialog nur für Delete, nicht für Block/Unblock (Playwright) | E2E | P2 | — |
| MEDIA.6-INT-006 | Storage-Anzeige: Bytes-Summe für `:released` und pending-Hard-Delete (`:deleted`) korrekt getrennt ausgewiesen | Integration | P2 | — |

### Story 6d — Bulk Cohort Actions *(neu, Update 2026-07-06)*

**Testziel:** Der Batch-Fan-out ist die zentrale Compliance-Invariante dieser Story — eine Entscheidung, N auditierbare Effekte, striktes Signatur-Scoping, keine stille Doppelverarbeitung bei Retry.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.6-BULK-001 | Jede Bulk-Aktion erzeugt eine `batch_id`; N `media_state_transitions`-Einträge mit `metadata: %{batch_id, reason, cohort_key}` (kein Sammel-Eintrag) | Integration | P0 | R-006, ADR-028 |
| MEDIA.6-BULK-002 | N `audit_log`-Einträge (nicht ein Sammel-Eintrag), je mit `batch_id` gestempelt | Integration | P0 | ADR-028 |
| MEDIA.6-BULK-003 | **Signatur-Scope-Isolation**: zwei gleichzeitig aktive Signaturen A/B — Bulk-Override auf A berührt keine B-Datei, auch bei überlappendem Tabellenfilter zum Aktionszeitpunkt | Integration/Security | P0 | R-027 |
| MEDIA.6-BULK-004 | Best-effort/kein All-or-Nothing: eine Legal-Hold- oder concurrent geänderte Datei in der Kohorte blockiert die übrigen nicht; Rückgabe partitioniert korrekt in `succeeded`/`skipped`/`failed` | Integration | P0 | — |
| MEDIA.6-BULK-005 | **Retry-Idempotenz**: erneuter Aufruf auf denselben `batch_id`-Batch verändert nur zuvor `failed`-Items; `succeeded`/`skipped` sind No-Op (kein doppelter Transition-/Audit-Eintrag) | Integration | P0 | R-026 |
| MEDIA.6-BULK-006 | Kohorten-Begründung: leerer String bei Override/Block wird abgelehnt; ein Freitext gilt für die gesamte Kohorte (kein Pflichtfeld pro Datei) | Integration | P1 | — |
| MEDIA.6-BULK-007 | **Two-Eyes-Eskalationsschwelle**: Kohorte < 10 Dateien → Single-Actor + `critical`-Audit + `compliance_officer`-Notification; Kohorte ≥ 10 → Pflicht-Zweitfreigabe mit Quorum-Regel (Wiederverwendung Story 13d) | Integration | P0 | R-015, R-020 |
| MEDIA.6-BULK-008 | Fast-Track-Eskalation: keine Zweitfreigabe innerhalb 15 Min → automatische Eskalation an zweiten `media_admin_override`-Träger/Compliance-Pool | Integration | P1 | — |
| MEDIA.6-BULK-009 | Zweitfreigeber sieht die vollständige Dateiliste, nicht nur `cohort_key`/Count | LiveView/Integration | P1 | — |
| MEDIA.6-BULK-010 | Partial-Result-Feedback-State rendert „N erfolgreich · M übersprungen (Grund) · K Fehler" via `aria-live="polite"` | LiveView/Accessibility | P1 | — |
| MEDIA.6-BULK-011 | Bulk-Confirm-Modal (Pre-Commit-Preview): Deselektieren vor Commit möglich, kein zeitboxed Toast-Undo | E2E | P2 | — |
| MEDIA.6-BULK-012 | Alle vier Bulk-Actions (`media_bulk_override/block/delete/rescan`) in `AuditWriter.@known_actions` registriert | Static/CI | P0 | Projekt-Memory: Audit-Allowlist-Merge-Gotcha |

### Story 7 — Admin Notifications

**Testziel:** Zuverlässige Zustellung kritischer Events, Webhook-Fehler dürfen den Scan-Worker nie beeinträchtigen.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.7-UNIT-001 | PubSub-Events `{:media_infected,_}`/`{:media_scan_failed,_}` korrekt vom Worker gesendet | Unit | P1 | — |
| MEDIA.7-LV-002 | Admin-LiveView-Badges reagieren auf beide Events in Echtzeit | LiveView | P1 | — |
| MEDIA.7-INT-003 | Webhook-Call läuft als eigener Oban-Job; Webhook-Fehler crasht **nicht** den Scan-Worker | Integration | P0 | R-011 |
| MEDIA.7-UNIT-004 | Webhook-Payload enthält exakt `{event, media_id, filename, uploader_id, timestamp}` | Unit | P1 | — |
| MEDIA.7-DOC-005 | `webhook_url` ist nur `config.exs`-gesteuert, keine Admin-UI-Eingabe möglich (Negativtest: kein Formularfeld existiert) | Integration | P2 | R-005 |

### Story 8 — Retention & Cleanup

**Testziel:** Fristgerechter, korrekter Hard-Delete; Orphan-Detection ohne Performance-Kollaps; **Art.-17-Lücke geschlossen**.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.8-INT-001 | **[AC existiert jetzt — Story 13e]** Erasure-Request auf ein `:quarantined`/`:infected`-File → sofort unsichtbar (`:deleted`, 404) + `legal_hold=true`, Bytes erhalten, **nicht** physisch gelöscht; Lifecycle-/Retention-Crons lassen es unberührt | Integration | **P0** | **R-015** |
| MEDIA.13-INT-009 | Two-Eyes-Delete: einzelner Admin kann Legal-Hold-/eligible-File **nicht** physisch löschen (Negativ) | Integration | **P0** | R-015 |
| MEDIA.13-INT-010 | Two-Eyes-Delete: 2× Admin **ohne** `compliance_officer` können nicht löschen; Admin+Compliance bzw. 2× Compliance können (Quorum) — beide Actor-IDs im Audit-Log | Integration | **P0** | R-015 |
| MEDIA.13-INT-011 | `MediaLifecycleWorker` fährt die Ladder korrekt und respektiert `legal_hold` + `two_eyes_delete_required` (kein Auto-Hard-Delete bei aktivem Flag) | Integration | **P0** | R-015 |
| MEDIA.8-UNIT-002 | Konfigurierbare Retention-Fristen (`deleted_days`, `infected_days`, `orphaned_hours`) werden korrekt angewendet | Unit | P0 | — |
| MEDIA.8-INT-003 | Hard-Delete-Property-Test: für jeden Eingangspfad exakt das erwartete Feld-Set genullt/erhalten | Integration | P0 | R-007 |
| MEDIA.8-INT-004 | Orphan-Detection: `:quarantined`-Files ohne `mxc_uri`-Referenz in `events.content` → `:deleted`, referenzierte bleiben unberührt | Integration | P0 | — |
| MEDIA.8-PERF-005 | **`EXPLAIN ANALYZE`** der Orphan-Query gegen ≥100k-Zeilen-`events`-Tabelle — Gate-Kriterium vor Merge | Performance/CI | P0 | R-013 |
| MEDIA.8-INT-006 | `media_state_transitions`-Einträge überleben Hard-Delete unverändert | Integration | P0 | R-007 |
| MEDIA.8-INT-007 | Admin-getriggerter manueller Hard-Delete (Einzel-File/Kohorte) funktioniert identisch zum Cron-Pfad | Integration | P1 | — |
| MEDIA.8-LV-008 | Hard-Delete-Zähler und Bytes-Freigabe im Dashboard korrekt (Story-5-Erweiterung) | LiveView | P2 | — |

### Story 9 — Media Policy Settings *(neu, Update 2026-07-06)*

**Testziel:** Konfigurierbarkeit ohne Neustart, cluster-weit konsistent, sicherheitsrelevante Werte (mime_denylist, webhook_url) speziell abgesichert.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.9-UNIT-001 | `Nebu.Media.Config.get/0`: DB-Override wenn vorhanden, sonst Fallback auf `config.exs`-Default | Unit | P0 | — |
| MEDIA.9-STATIC-002 | Grep-Invarianz: kein direktes Ecto-Write auf `media_config` außerhalb `Nebu.Media.Config.upsert/1` | Static/CI | P1 | — |
| MEDIA.9-INT-003 | **Cluster-Cache-Invalidierung**: Config-Änderung auf Knoten A ist auf Knoten B ohne Neustart sichtbar (`:pg`-Broadcast) | Integration/Multi-Node | P0 | R-018 |
| MEDIA.9-INT-004 | **TTL-Fallback**: bei verpasster `:pg`-Invalidierung verwirft Knoten B den Cache spätestens nach konfiguriertem TTL | Integration | P0 | R-018 |
| MEDIA.9-INT-005 | Jede Config-Änderung schreibt `media_config_updated` mit `old_value`/`new_value` in den Audit-Log | Integration | P0 | — |
| MEDIA.9-INT-006 | Server-seitige Validierung: Unter-/Obergrenzen, keine Negativwerte für alle editierbaren Keys | Integration | P1 | — |
| MEDIA.9-INT-007 | `webhook_url` Save-Time-Validierung: HTTPS-Pflicht, private/link-local IP-Ranges geblockt (Wiederverwendung `Nebu.Media.SSRF`) | Integration/Security | P0 | R-005 (jetzt aktiv, da admin-konfigurierbar) |
| MEDIA.9-E2E-008 | Verschärfte Warnung bei `released_delete_after_days` `nil` → konkreter Wert | E2E | P2 | — |
| MEDIA.9-INT-009 | Env-Var-Vorbefüllung beim ersten Laden | Integration | P2 | — |
| MEDIA.9-INT-010 | `mime_denylist` lehnt passende Typen **vor** Persistierung ab, zusätzlich zum ClamAV-Scan (nicht als Ersatz) | Integration | P0 | — |
| MEDIA.9-INT-011 | `mime_denylist`-Änderung wirkt ohne Neustart über dieselbe Cluster-Invalidierung wie 9a | Integration | P1 | R-018 |

### Story 10 — Scan Health & Alerts Dashboard *(neu, Update 2026-07-06)*

**Testziel:** Operative Sichtbarkeit korrekt aggregiert; Alert-Trigger und Kill-Switch sind das letzte fail-closed/fail-open-Sicherheitsnetz gegen einen ausgefallenen Scanner.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.10-INT-001 | Rollup-Cron aggregiert Scan-Durchsatz/Ø-Dauer/Backlog-Tiefe/Fehlerrate korrekt aus `media_state_transitions` über den erwarteten Zeitraum | Integration | P1 | — |
| MEDIA.10-INT-002 | Health-Sektion liest ausschließlich die Rollup-Tabelle, kein Live-Query über die volle Historie | Integration | P2 | — |
| MEDIA.10-INT-003 | ClamAV-Status (up/down + „down seit") korrekt aus Health-Check/Auto-Reconnect (Story 3) abgeleitet | Integration | P1 | R-012 |
| MEDIA.10-INT-004 | Freshclam-/Signatur-Alter korrekt geparst und angezeigt | Integration | P2 | — |
| MEDIA.10-INT-005 | Alert-Trigger: ClamAV down > 5 Min → `critical`; Backlog > Schwellwert → `warning`; Fehlerrate > Schwellwert über 1h → `warning` | Integration | P0 | R-012 (operatives Fail-Closed-Signal) |
| MEDIA.10-INT-006 | Auto-Resolve: Alert verschwindet automatisch, sobald der auslösende Zustand behoben ist | Integration | P1 | — |
| MEDIA.10-INT-007 | Alert-Schwellwerte sind über `media_config` admin-konfigurierbar (Wiederverwendung 9a) | Integration | P2 | R-018 |
| MEDIA.10-INT-008 | **Kill-Switch `fail_closed`**: `PUT .../upload` liefert `503` + Errcode, solange ClamAV-Health „down" meldet | Integration | P0 | R-012 |
| MEDIA.10-INT-009 | **Kill-Switch `fail_open`** (Default): Uploads werden weiter angenommen und stauen sich in `:quarantined`, kein Crash, kein Datenverlust, solange ClamAV down ist | Integration | P0 | R-025 |
| MEDIA.10-INT-010 | Moduswechsel `fail_open`/`fail_closed` schreibt `media_config_updated`-Audit-Eintrag | Integration | P1 | — |

### Story 11 — Object Storage Target Configuration *(neu, Update 2026-07-06)*

**Testziel:** Secrets sind nie im Klartext erreichbar; ein Fehlkonfigurations-Save darf bestehende Medien nicht stillschweigend unerreichbar machen.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.11-STATIC-001 | **`access_key`/`secret_key` liegen im bestehenden Feld-Verschlüsselungs-Tier**, nie als Klartext-`TEXT` (Schema-/Spalten-Typ-Test + Grep-Guard) | Static/Integration | P0 | R-024 |
| MEDIA.11-INT-002 | Env-Var-Fallback (`NEBU_MINIO_*`) bleibt funktionsfähig, solange keine DB-Config gesetzt ist | Integration | P1 | — |
| MEDIA.11-INT-003 | Audit-Eintrag `media_storage_config_updated` enthält **niemals** die Secret-Werte selbst, nur die geänderten Key-Namen | Integration/Security | P0 | R-024 |
| MEDIA.11-INT-004 | „Test Connection" führt `head_bucket` gegen die eingegebenen (noch nicht gespeicherten) Werte aus, Ergebnis sichtbar **vor** dem Speichern | Integration | P1 | — |
| MEDIA.11-INT-005 | Warnhinweis bei Endpoint-/Bucket-Änderung zeigt den korrekten `COUNT(*)` bestehender Medien | Integration | P1 | — |
| MEDIA.11-INT-006 | Env-Var-Vorbefüllung ist read-once beim ersten Laden | Integration | P2 | — |
| MEDIA.11-UNIT-007 | Key-Template-Validierung lehnt Templates **ohne** `{media_id}` ab (Pflicht-Platzhalter für Eindeutigkeit) | Unit | P0 | — |
| MEDIA.11-INT-008 | Storage-Key wird **einmalig zur Upload-Zeit** berechnet und persistiert; ein späterer Template-Wechsel wirkt nur auf neue Uploads, bestehende `storage_key` bleiben unverändert auffindbar | Integration | P0 | — |
| MEDIA.11-UNIT-009 | `{room_id}` wird als Platzhalter nicht unterstützt (negativer Parse-Test) | Unit | P2 | — |

### Story 12 — Gzip Compression at Rest *(neu, Update 2026-07-06)*

**Testziel:** Kompression darf die SHA-256-Integrität und die Scan-Korrektheit nicht antasten — Epic-AC verlangt bereits „mindestens eine inkompressible und eine hochkompressible Testdatei", hier als benannte Test-IDs verankert.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.12-UNIT-001 | Hochkompressible Testdatei → `compressed = true`, gespeicherte Bytes kleiner als Original | Unit | P0 | — |
| MEDIA.12-UNIT-002 | Inkompressible Testdatei (bereits komprimiertes Format) → `compressed = false`, Original unverändert gespeichert (kein Aufblähen) | Unit | P0 | — |
| MEDIA.12-UNIT-003 | SHA-256 wird auf den **Original-Bytes** berechnet, **vor** Gzip — nicht auf die komprimierten Bytes | Unit | P0 | R-007 (Hash-Integrität) |
| MEDIA.12-INT-004 | Download-/Scan-Pfad dekomprimiert korrekt bei `compressed = true`, No-Op bei `false`; ClamAV scannt ausschließlich die dekomprimierten Original-Bytes, nie das Gzip-Blob | Integration | P0 | R-012 |

### Story 13 — Media Lifecycle Policy & Two-Eyes Delete *(neu, Update 2026-07-06)*

**Testziel:** Dies ist die R-015-Lösung selbst — die Ladder-Engine, das Legal-Hold-Overlay und das Vier-Augen-Gate müssen lückenlos getestet sein, sonst ist R-015 nur auf dem Papier geschlossen.

| Test ID | Ziel | Level | Priorität | Risk-Link |
|---|---|---|---|---|
| MEDIA.13-UNIT-001 | Cascade-Resolution `global ⊕ space ⊕ room`: Room-Wert hat Vorrang vor Space, Space vor Global; fehlende Felder fallen zur nächsten Ebene durch | Unit | P0 | — |
| MEDIA.13-UNIT-002 | Validierung: `after_days ≥ 0`, monotone Ladder (`archive ≤ mark_deleted ≤ delete`) — Verstoß wird abgelehnt | Unit | P0 | — |
| MEDIA.13-INT-003 | Migration mappt bestehende `*_days`-Keys (Story 9) verlustfrei auf die Policy-Sprossen | Integration/Migration | P0 | — |
| MEDIA.13-INT-004 | Jede Policy-Änderung schreibt `media_lifecycle_policy_updated` mit vollständigem `diff` | Integration | P1 | — |
| MEDIA.13-E2E-005 | Verschärfte Warnung beim Aktivieren einer destruktiven Sprosse oder beim Deaktivieren von `two_eyes_delete_required` | E2E | P1 | — |
| MEDIA.13-INT-006 | **Policy-Change-Schutz**: ist `two_eyes_delete_required` aktiv, verlangt das Speichern der Policy selbst eine Vier-Augen-Bestätigung (verhindert Selbst-Downgrade der eigenen R-015-Mitigation) | Integration | P0 | R-015, R-020 |
| MEDIA.13-INT-007 | Ladder-Engine fährt `archive → mark_deleted → delete` korrekt nach Policy-Konfiguration, konsolidiert 8a/8c/8d-Verhalten | Integration | P0 | — |
| MEDIA.13-INT-008 | **Legal-Hold-Guard**: Files mit `legal_hold = true` werden von JEDER automatischen Transition ausgenommen (delete, infected-Cohort-Delete, alles) | Integration | P0 | R-015 |
| MEDIA.8-INT-001 | *(bestehend, siehe Story 8)* Erasure-Request auf ein `:quarantined`/`:scanning`/`:infected`/`:released`-File → sofort `:deleted` (404) + `legal_hold=true`, Bytes erhalten, aus jedem Scan-State | Integration | P0 | R-015 |
| MEDIA.13-INT-009 | Two-Eyes-Guard: bei aktivem `two_eyes_delete_required` führt der Worker **keinen** `:deleted → :hard_deleted`-Schritt aus, markiert Files höchstens als *eligible* | Integration | P0 | R-015 |
| MEDIA.13-INT-010 | **Cron/Legal-Hold-Race**: `legal_hold` wird innerhalb derselben Transaktion wie die Transition gelesen — ein zwischen Batch-Selektion und Transition gesetzter Legal-Hold verhindert die Erfassung; ein währenddessen aufgehobener wirkt erst im nächsten Tick | Integration/Concurrency | P0 | R-021 |
| MEDIA.13-INT-011 | **ADR-032-Reihenfolge**: DB-Zwischenzustand → Blob-Delete → `storage_key = NULL`; Crash zwischen Blob-Delete und finalem `NULL` ist über den Reaper-Job idempotent reparierbar | Integration | P0 | R-019 |
| MEDIA.13-INT-012 | Reaper-Job erkennt „Zwischenzustand älter als X" und vollendet `storage_key = NULL`, ohne den bereits gelöschten Blob erneut anzufassen | Integration | P1 | R-019 |
| MEDIA.13-INT-013 | Quorum-Regel: Admin + Compliance ✅, 2× Compliance ✅, 2× Admin ❌, derselbe Actor zweimal ❌ | Integration | P0 | R-015, R-020 |
| MEDIA.13-SEC-014 | **Self-Approval-Bypass-Negativtest**: derselbe Actor kann nicht über zwei unterschiedliche Sessions/Requests beide Eyes für sich selbst erfüllen | Integration/Security | P0 | R-020 |
| MEDIA.13-INT-015 | Quorum-Timeout: ein `proposed`-Eintrag verfällt nach konfigurierbarer Frist (Default 72h) automatisch zurück in den vorherigen Zustand | Integration | P1 | — |
| MEDIA.13-CONC-016 | **Downgrade-Race**: verliert der zweite Principal seine `compliance_officer`-Rolle nach Proposal aber vor Confirm, ist das Confirm ungültig (Quorum wird zum Confirm-Zeitpunkt erneut geprüft) | Integration/Concurrency | P0 | R-020 |
| MEDIA.13-CONC-017 | **Concurrent-Confirm-Race**: zwei Confirms treffen quasi gleichzeitig ein → genau ein Confirm gewinnt, der zweite erhält einen Konflikt-Fehler, kein Doppel-Delete | Integration/Concurrency | P0 | R-020 |
| MEDIA.13-INT-018 | Beide Actor-IDs landen in `media_state_transitions.metadata` UND im globalen Audit-Log (`media_deletion_proposed`/`media_deletion_confirmed`) | Integration | P0 | — |
| MEDIA.13-UNIT-019 | Ein Legal-Hold-File kann NUR über die Two-Eyes-Freigabe (13d) verlassen werden — StateMachine-Guard verhindert Un-Hold durch einen einzelnen Admin | Unit | P0 | R-015 |
| MEDIA.13-UNIT-020 | Kein zeitbasiertes Auto-Release: `legal_hold_until` ist rein informativ, löst nie automatisch eine Löschung/Freigabe aus | Unit | P0 | R-015 |
| MEDIA.13-INT-021 | Audit `media_erasure_requested` mit `requested_by`/`prior_state` | Integration | P1 | — |
| MEDIA.13-UNIT-022 | **mxc→Raum-Index-Vollständigkeit**: alle sechs mxc-tragenden Felder (`content.url`, `content.info.thumbnail_url`, `content.avatar_url`, verschlüsselt `content.file.url` + `content.info.thumbnail_file.url`) werden beim Event-Insert indexiert | Unit | P0 | R-022 |
| MEDIA.13-UNIT-023 | `effective_for_media/1` wählt über alle referenzierenden Räume die konservativste Policy (most-conservative-wins); medienlos referenziert → `global` | Unit | P0 | — |
| MEDIA.13-SEC-024 | **E2EE-Grenztest**: `effective_for_room/1` auf einen Raum mit Megolm-verschlüsseltem `content` → Fallback auf `global`, kein Fehler, kein Zugriffsversuch auf/keine Ableitung aus dem Chiffrat | Unit/Security | P0 | R-023, ADR-011 |
| MEDIA.13-UNIT-025 | Raum→Space-Auflösung: `m.space.parent` nur gültig, wenn passendes `m.space.child` existiert oder der Sender PL dafür hat; Loop-/Tiefen-Guard bei Multi-Parent | Unit | P1 | — |
| MEDIA.13-INT-026 | Policy-Auflösung läuft zur Cron-Evaluationszeit (13c), nicht pro Download (Performance-Grenze) | Integration | P2 | — |

> **Hinweis zu `MEDIA.8-INT-001`:** Dieser Test-ID bleibt bewusst unter Story 8 benannt (siehe dort) —
> er wird hier nur referenziert, nicht dupliziert, da die AC in Story 13e als „`MEDIA.8-INT-001`
> (neu gefasst)" auf den bestehenden Test-ID verweist.

> ⚠️ **Nicht in dieser Tabelle:** Backup/Restore-Reconciliation (R-028, Offene Entscheidung #11).
> Solange keine Story diese Fähigkeit spezifiziert, kann kein `MEDIA.<N>`-Test-ID vergeben werden —
> siehe Critical-Blocker-Tabelle. Sobald eine Story existiert, MUSS mindestens ein P0-Integrationstest
> „simulierter Restore vor Hard-Delete/Legal-Hold-Set → Reconciliation-Lauf stellt beides vor
> Traffic-Freigabe wieder her" ergänzt werden.

---

## Test Coverage Plan (Aggregiert nach Priorität)

> **Hinweis:** P0–P3 spiegeln Priorität/Risiko wider, **nicht** wann ein Test läuft. Timing (PR vs. Nightly vs. Weekly) ist ausschließlich in der Execution Strategy weiter unten geregelt — ein P0-Test kann trotzdem nightly laufen, wenn er teure Infrastruktur braucht (z.B. `MEDIA.3-INT-008`, `MEDIA.8-PERF-005`).

### P0 (Critical)

**Criteria**: Blockiert Kernfunktion + High Risk (≥6) + kein Workaround

| Requirement | Test Level | Risk Link | Test Count | Owner | Notes |
|---|---|---|---|---|---|
| State-Gate als einzige Download-Erfolgsbedingung | Integration | R-002, R-004 | 4 | Dev | Story 1 |
| Ownership-/Expiry-/Overwrite-Fehlercodes (403/404/409/413) | Integration | R-001, R-009, R-010 | 6 | Dev | Story 2 |
| ClamAV-Fehlerpfade fail-closed (alle 4 Klassen + Fail-Closed-Beweis) | Unit + Integration | R-012 | 6 | Dev | Story 3, 4 |
| Enum-/Schema-Drift-Guard | Migration/Integration | R-016 | 1 | Dev | Story 4 |
| XSS-Regression Admin-Dateiname | LiveView/Security | R-003 | 1 | Dev + Kassandra | Story 5 |
| Audit-Allowlist-Guard (`AuditWriter.@known_actions`) | Static/CI | Projekt-Memory | 1 | Dev | Story 6 |
| Hard-Delete-Property + Orphan-Detection + Query-Performance | Integration/Perf | R-007, R-013 | 5 | Dev | Story 8 |
| **DSGVO-Art.-17-Löschpfad** (`MEDIA.8-INT-001`) | Integration | **R-015** | 1 | Dev | Story 8/13e — **gelöst (Design), Test ausstehend** |
| Concurrency-Races (Stall-Subscribe, Expiry vs. Cron) | Integration/Concurrency | R-008, R-009 | 2 | Dev | Story 2 |
| Bestehende Media-Suite bleibt grün (Regression) | Unit/Integration | — | 7 | Dev | `media_*_test.exs` |
| **Bulk-Cohort-Fan-out, Signatur-Isolation, Retry-Idempotenz, Two-Eyes-Eskalation** *(neu)* | Integration/Security | R-006, R-020, R-026, R-027 | 7 | Dev | Story 6d |
| **Cluster-Config-Invalidierung + TTL-Fallback + mime_denylist-Enforcement** *(neu)* | Integration/Multi-Node | R-018 | 6 | Dev | Story 9 |
| **Scan-Health-Alert-Trigger + Kill-Switch fail_open/fail_closed** *(neu)* | Integration | R-012, R-025 | 3 | Dev | Story 10 |
| **Storage-Secret-Verschlüsselung + Audit-Redaction + Key-Template-Pflichtfeld** *(neu)* | Static/Integration/Security | R-024 | 4 | Dev | Story 11 |
| **Gzip-Kompression: beide Größenvergleichs-Zweige + Original-Hash + Scan-Dekompression** *(neu)* | Unit/Integration | R-007, R-012 | 4 | Dev | Story 12 |
| **Lifecycle-Ladder + Legal-Hold-Guard + Two-Eyes-Quorum + Self-Approval-/Downgrade-/Concurrent-Confirm-Race + mxc-Index + E2EE-Grenztest** *(neu, das eigentliche R-015-Fundament)* | Integration/Concurrency/Security | R-015, R-019, R-020, R-021, R-022, R-023 | 19 | Dev + Kassandra | Story 13 |

**Total P0**: ~77 Tests, ~154–216h (hoher Anteil wegen Concurrency-/DB-Privilege-/Multi-Node-/Quorum-Setup-Aufwand — Story 13 allein trägt 19 P0-Tests, da sie die R-015-Lösung selbst ist)

### P1 (High)

**Criteria**: Wichtige Features + Medium Risk (3-4) + gängige Workflows

| Requirement | Test Level | Risk Link | Test Count | Owner | Notes |
|---|---|---|---|---|---|
| PUT-Endpoint Detailverhalten (Content-Type optional, filename-Persistenz) | Integration | — | 3 | Dev | Story 2 |
| Pending-Upload-Limit / `429` | Integration | R-014 | 1 | Dev | Story 2 |
| Oban Lifeline/Retry-Mechanik | Integration | R-011 | 3 | Dev | Story 4 |
| Admin-Overview Filter/Pagination/Badges | LiveView/Integration | — | 4 | Dev | Story 5 |
| Admin-Actions Idempotenz + Detail-View | Integration | — | 3 | Dev | Story 6 |
| Notifications (PubSub + Webhook-Isolation) | Unit/Integration | R-011 | 3 | Dev | Story 7 |
| DB-seitiger Schreibschutz Audit-Trail | Integration | R-006 | 1 | Dev | Story 1 |
| Manueller Admin-Hard-Delete | Integration | — | 1 | Dev | Story 8 |
| E2E Admin-Login→Filter-Flow | E2E (Playwright) | — | 2 | QA | e2e/-Suite |
| Bulk-Kohorten-Begründung, Fast-Track-Eskalation, Zweitfreigeber-Sicht, Partial-Result-A11y *(neu)* | Integration/LiveView | — | 4 | Dev | Story 6d |
| Policy-Validierung, `webhook_url`-Save-Validation, Env-Vorbefüllung *(neu)* | Integration | R-005 | 3 | Dev | Story 9 |
| Rollup-Aggregation, ClamAV-Status, Auto-Resolve, Moduswechsel-Audit *(neu)* | Integration | — | 4 | Dev | Story 10 |
| Test-Connection, Warnhinweis-COUNT, Env-Fallback *(neu)* | Integration | — | 3 | Dev | Story 11 |
| Policy-Change-Schutz-E2E, Migration-Mapping, Reaper-Job, Quorum-Timeout, Raum→Space-Auflösung, Erasure-Audit *(neu)* | Integration/E2E | R-019, R-020 | 6 | Dev | Story 13 |

**Total P1**: ~46 Tests, ~46–64h

### P2 (Medium)

**Criteria**: Sekundäre Features + Low Risk (1-2) + Edge Cases

| Requirement | Test Level | Risk Link | Test Count | Owner | Notes |
|---|---|---|---|---|---|
| k6 Burst-Last Stall-Requests | k6 | R-014 | 1 | QA/Dev | Nightly |
| Graceful Shutdown Scan-Worker | Integration | — | 1 | Dev | Story 4 |
| LiveView PubSub Partial-Render | LiveView | — | 1 | Dev | Story 5 |
| Confirmation-Dialog-Verhalten | E2E | — | 1 | QA | Story 6 |
| Storage-Byte-Anzeige | Integration | — | 2 | Dev | Story 5/6/8 |
| Negativtest Scanner-Override ausgeschlossen | Unit | R-017 | 1 | Dev | Story 1 |
| Webhook-URL nicht admin-konfigurierbar | Integration | R-005 | 1 | Dev | Story 7 (obsolet ab Story 9b, siehe dort) |
| Bulk-Confirm-Modal-Verhalten *(neu)* | E2E | — | 1 | QA | Story 6d |
| Policy-Warnungs-E2E, Env-Vorbefüllung *(neu)* | E2E/Integration | — | 2 | Dev | Story 9 |
| Health-Live-Query-Grenze, Freshclam-Alter, Schwellwert-Config *(neu)* | Integration | — | 3 | Dev | Story 10 |
| Env-Fallback read-once *(neu)* | Integration | — | 2 | Dev | Story 11 |
| Policy-Auflösung zur Cron-Zeit *(neu)* | Integration | — | 1 | Dev | Story 13f |

**Total P2**: ~23 Tests, ~14–21h

### P3 (Low)

**Criteria**: Nice-to-have + explorativ + Benchmarks

| Requirement | Test Level | Test Count | Owner | Notes |
|---|---|---|---|---|
| Explorative Fuzzing der `filename`-Query-Parameter (Sonderzeichen, sehr lange Namen) | Unit | 4 | Dev | Story 2 |
| Dashboard-Kosmetik (Badge-Farben je State) | E2E (visuell) | 2 | QA | Story 5 |
| Freitext-Grund bei Block-Aktion | Integration | 2 | Dev | Story 6 |

**Total P3**: ~8 Tests, ~2–5h (unverändert — für Stories 6d/9–13 wurden keine zusätzlichen P3-Kandidaten identifiziert; explizit vermerkt, nicht stillschweigend übersprungen)

---

## Execution Strategy

**Philosophie:** Alles läuft im PR, solange es unter ~15 Minuten bleibt. Nur nachweislich teure Infrastruktur (Docker-ClamAV-Start, k6-Lastläufe, große DB-Seeds) wandert nach Nightly — unabhängig von der Priorität des jeweiligen Tests.

- **PR** (jeder Commit, ExUnit + Mock-clamd-Stub + Oban `Oban.Testing`/`drain_queue`): alle funktionalen P0–P3-Tests aus der Coverage-Plan-Tabelle oben, inklusive der Concurrency-/State-Gate-/Ownership-/Audit-Allowlist-Tests **und** der neuen Quorum-/Race-/Signatur-Scope-Tests aus Story 6d/13. Die Suite ist weiterhin klein genug für den PR-Lauf, solange die Multi-Node-Tests (siehe unten) separiert werden.
- **Nightly**: `MEDIA.3-INT-008` (echter ClamAV-Container + EICAR), `MEDIA.2-PERF-013`/`media-upload-burst.js` (k6), `MEDIA.8-PERF-005` (EXPLAIN ANALYZE gegen große `events`-Tabelle), **neu (Update 2026-07-06):** `MEDIA.9-INT-003`/`004` (Multi-Node-`:pg`-Cluster-Test, Story 9a) und `MEDIA.11-INT-004` (`head_bucket`-Test-Connection gegen echten Zweit-Bucket) — diese sind trotz P0-Einstufung zu teuer/infrastrukturlastig für jeden PR-Lauf, falls das CI-System keine Mehrknoten-Jobs im PR-Takt erlaubt.
- **Weekly**: keine zusätzlichen Kandidaten identifiziert; bei Bedarf (z.B. Endurance-Test für Oban-Queue-Backlog über Stunden) hier ergänzen. **Kandidat vorgemerkt:** sobald Story für R-028 (Backup/Restore-Reconciliation) existiert, gehört ein simulierter Restore-Test hierher (zu teuer/destruktiv für PR/Nightly).

---

## Resource Estimates

### Test Development Effort

| Priority | Count | Hours/Test | Total Hours | Notes |
|---|---|---|---|---|
| P0 | 77 | 2.0–2.8 | ~154–216 | Story 13 allein 19 P0-Tests (Quorum/Race/E2EE-Grenzfälle); + Multi-Node-Setup (Story 9a) |
| P1 | 46 | 1.0–1.4 | ~46–64 | Standard-Integration + LiveView |
| P2 | 23 | 0.6–0.9 | ~14–21 | Einfachere Szenarien, k6-Setup einmalig teurer |
| P3 | 8 | 0.25–0.4 | ~2–3 | Explorativ, unverändert |
| **Total** | **154** | — | **~216–304h** | **~27–38 Personentage** |

Zusätzlich (einmalig, nicht pro Test): Mock-clamd-Stub (~4–8h), Oban-Test-Helper-Etablierung (~4–6h), EICAR-Fixture + ClamAV-Docker-Compose-Erweiterung (~3–5h), k6-Burst-Szenario (~4–6h). **Update 2026-07-06, neu für Stories 9–13:** Multi-Node-`:pg`-Testharness für Cluster-Cache-Invalidierung (~4–6h), `head_bucket`-Mock/Test-Doppelbucket für Story 11 „Test Connection" (~2–3h), `compliance_officer`-Rolle + Zweit-Admin-Testfixtures für Story 13d (~3–5h), EICAR-auf-komprimierter-Datei-Fixture für Story 12 (~1–2h). → Gesamt-Infra-Kosten steigen von ~11–19h auf **~21–34h**; **Gesamtaufwand-Range für das volle 14-Story-Epic: ~237–338h (~30–42 Personentage)**, inklusive aller Infra-Kosten.

### Prerequisites

**Test Data:**
- `media_test_support.exs` / `media_fakes.exs` — bestehend, erweitern um State-Machine-Fixtures
- Mock-clamd-GenServer-Stub (neu, INSTREAM-Protokoll)
- Oban-Test-Support-Modul (neu)
- EICAR-Testdatei-Fixture (+ komprimierte Variante für Story 12, Update 2026-07-06)
- **Neu (Update 2026-07-06):** `compliance_officer`-Rolle + mindestens zwei unterscheidbare Admin-/Compliance-Test-User (Story 13d Quorum-Tests); hoch- und inkompressible Testdateien (Story 12); zwei parallel aktive ClamAV-Signaturen im Fixture-Set (Story 6d Signatur-Scope-Isolation, `MEDIA.6-BULK-003`)

**Tooling:**
- ExUnit + `Ecto.Adapters.SQL.Sandbox` für Integrationstests
- `Oban.Testing` für Worker-Unit-Tests, `Oban.drain_queue/2` für Integrationstests
- Playwright/Cucumber (`e2e/`) für Admin-UI-Flows
- k6 (`k6/scenarios/`) für Burst-Last-Szenarien
- `EXPLAIN ANALYZE` / `psql`-Skript für Orphan-Query-Kostenanalyse
- **Neu (Update 2026-07-06):** Multi-Node-Testharness für Erlang `:pg`-Process-Groups (Story 9a Cluster-Cache-Invalidierung, `MEDIA.9-INT-003/004`) — kann testweise 2 lokale BEAM-Knoten via `:peer`/`Node.spawn_link` starten, analog zu einem eventuell bereits existierenden Testmuster für `Nebu.Web.OidcConfig`, falls vorhanden (zu prüfen vor Story 9a); `ExAws.S3.head_bucket/1`-Mock oder echter Zweit-Bucket für Story 11 „Test Connection"

**Environment:**
- ClamAV-Container (clamd) im lokalen/CI-Compose-Stack, intern erreichbar, ohne DB-Credentials (Story-3-Hinweis)
- Test-DB mit realistisch großer `events`-Tabelle für R-013-Validierung
- **Neu (Update 2026-07-06):** Zweiter Test-S3/MinIO-Bucket (Archiv-Ziel, Story 8c/11) für „Test Connection" und Archiv-Copy-Tests; Multi-Node-CI-Fähigkeit für die `:pg`-Tests (Story 9a) — falls CI das nicht unterstützt, als dokumentierte Lücke im Quality Gate vermerken, nicht stillschweigend auslassen

---

## Quality Gate Criteria

### Pass/Fail Thresholds

- **P0 pass rate**: 100% (keine Ausnahmen, insbesondere Fail-Closed-Beweise)
- **P1 pass rate**: ≥95%
- **P2/P3 pass rate**: ≥90% (informativ)
- **High-Risk-Mitigationen (Score ≥6)**: 100% abgeschlossen oder genehmigte Waiver
- **R-015 (Score 9)**: MUSS vor Story-8/13e-Abnahme aufgelöst sein — automatischer Gate-FAIL, solange offen
- **R-028 (Score 9, neu)**: MUSS vor Dev-Start von Story 8a/13c/13d geklärt sein (Offene Entscheidung #11) — automatischer Gate-FAIL für diese drei Stories, solange keine Spezifikation existiert; das Epic darf nicht als „Done" gelten, solange ein Restore-Reconciliation-Test fehlt
- **R-020 (Score 6, neu)**: Two-Eyes-Quorum-Bypass-Tests (`MEDIA.13-SEC-014`, `MEDIA.13-CONC-016/017`) MÜSSEN grün sein, bevor Story 13d als abgeschlossen gilt — dieser Test schützt direkt die R-015-Lösung selbst

### Coverage Targets

- Kritische Pfade (State-Gate, Ownership, ClamAV-Fehlerpfade): ≥90%
- Security-Szenarien (SEC-Kategorie): 100%
- Compliance-Szenarien (Audit-Trail, Hard-Delete, Art. 17, Legal-Hold, Two-Eyes-Quorum): 100%
- Concurrency-/Race-Szenarien (inkl. Legal-Hold/Cron-Race, Quorum-Confirm-Race): ≥80% der identifizierten Race-Fenster
- Edge Cases (P2/P3): ≥50%
- **(neu, Update 2026-07-06)** Cluster-/Multi-Node-Szenarien (Cache-Invalidierung, Story 9a): 100% — kein Toleranzbereich, da sicherheitsrelevante Config (mime_denylist, Override-Widerruf) betroffen ist

### Non-Negotiable Requirements

- [ ] Alle P0-Tests bestehen
- [ ] Keine High-Risk-Items (≥6) unmitigiert
- [ ] SEC-Kategorie 100% grün
- [x] R-006 (DB-seitige Audit-Durchsetzung) im ADR dokumentiert (ADR-031) — Design abgeschlossen; Impl. (Migration + `MEDIA.1-INT-007`) in Story 1
- [ ] R-013 (Orphan-Query-Performance) mit EXPLAIN-Nachweis vor Story-8-Merge
- [x] R-015 (DSGVO Art. 17) **geklärt** (Winston-Review 5: ADR-030 + Story 13e/13d) — [ ] getestet (`MEDIA.8-INT-001`) + [ ] Legal-Review (Art. 17(3)), bevor Epic als "Done" gilt
- [ ] **R-028 (Backup/Restore vs. Legal-Hold, neu 2026-07-06) geklärt** (Offene Entscheidung #11) und mit mindestens einem Reconciliation-Test verifiziert, bevor Story 8a/13c/13d als abgeschlossen gelten
- [ ] **R-020 (Two-Eyes-Quorum-Bypass, neu)** — Self-Approval-, Downgrade-Race- und Concurrent-Confirm-Negativtests grün, bevor Story 13d abgeschlossen gilt
- [ ] Kassandra-Security-Review am Epic-Ende ohne offene CRITICAL/HIGH-Findings

---

## Mitigation Plans

### R-015: DSGVO Art. 17 — Löschanfrage-Lücke (Score: 9)

**Mitigation Strategy:** ~~Mit Phil klären…~~ **GELÖST (Winston-Review 5, 2026-07-02):** Produkt-Entscheidung getroffen — Art. 17 = Restriction-of-Processing, **kein** User-Delete. Umgesetzt als Story 13e (Erasure → sofort unsichtbar + Legal-Hold) + Story 13d (Vier-Augen-Freigabe für physische Löschung), Grundlage ADR-030. P0-Tests `MEDIA.8-INT-001` + `MEDIA.13-INT-009/010/011` in Red-Phase/ATDD schreiben, dann implementieren.
**Owner:** Phil (Produktentscheidung ✅) + Dev + DSB (Legal-Review Art. 17(3))
**Timeline:** Vor Epic-Abschluss (Story 13e)
**Status:** **Addressed (Design)** — AC existiert (Story 13e/13d), Tests + Legal-Review ausstehend
**Verification:** `MEDIA.8-INT-001` grün: „Erasure-Request auf ein `:quarantined`-File → sofort unsichtbar + `legal_hold`, **nicht** physisch gelöscht; Freigabe nur im Vier-Augen-Prinzip."

### R-006: Audit-Trail-Unveränderlichkeit nur App-seitig erzwungen (Score: 6)

**Mitigation Strategy:** ~~DB-Rechte (`REVOKE UPDATE, DELETE`) oder Trigger ergänzen…~~ **GELÖST (Winston-Review 6, 2026-07-02, ADR-031):** Architektur-Entscheidung getroffen — DB-seitige Append-only-Durchsetzung als Defense-in-Depth-Stack: **primär** ein `BEFORE UPDATE OR DELETE`-Trigger, der `RAISE EXCEPTION … USING ERRCODE = 'restrict_violation'` (SQLSTATE 23001) wirft und für **jede** Rolle inkl. Table-Owner feuert (hält also auch im Single-Role-Dev/CI — schließt das Loch, das `audit_log` dort bewusst offen ließ); **sekundär** RLS `USING(false)` + `REVOKE UPDATE, DELETE FROM nebu_app` analog `audit_log` (Migration 000001). Kein `SECURITY DEFINER`-Purge (append-only-forever; Retention vertagt). Migrations-Rolle unberührt: Trigger feuert nie auf INSERT; DDL/Backfill laufen normal, ein künftiger Rollup-Job nutzt `DISABLE TRIGGER` in seiner Transaktion. Verankert als AC in Story 1a, Grep-Hinweis in Story 1b nachgezogen.
**Owner:** Dev + Winston (Architektur ✅)
**Timeline:** Story 1
**Status:** **Addressed (Design)** — ADR-031 + AC (Story 1a) existieren; DB-Migration + `MEDIA.1-INT-007` in der Story-1-Pipeline umzusetzen.
**Verification:** `MEDIA.1-INT-007`: rohes UPDATE/DELETE über die App-DB-Rolle → Postgres-Fehler `SQLSTATE 23001` (Trigger; zusätzlich `42501` im Dual-Role), **nicht** nur eine Elixir-Exception, **nicht** ein stilles 0-Zeilen-Ergebnis; Gegenprobe: normaler INSERT (Append) gelingt weiterhin.

### R-012: ClamAV-Fehlerpfade müssen fail-closed sein (Score: 6)

**Mitigation Strategy:** Tabellengetriebene Tests für alle 4 Fehlerklassen gegen den Mock-Stub, PLUS Worker-Integrationstest, der über `max_attempts` hinweg beweist, dass der Endzustand niemals `released` ist.
**Owner:** Dev
**Timeline:** Story 3, vertieft in Story 4
**Status:** Planned
**Verification:** `MEDIA.3-UNIT-003..005` + `MEDIA.4-INT-004` grün; Kassandra-Review bestätigt keinen Fail-Open-Pfad.

### R-013: Orphan-Detection-Query-Performance (Score: 6)

**Mitigation Strategy:** Vor Story-8-Merge `EXPLAIN ANALYZE` gegen eine mit ≥100k Events geseedete Test-DB laufen lassen; bei Bedarf GIN-Index-Migration ergänzen.
**Owner:** Dev + DBA-Review
**Timeline:** Vor Story 8
**Status:** Planned
**Verification:** `MEDIA.8-PERF-005` liefert dokumentierten Query-Plan mit akzeptabler Kostenschätzung.

### R-011: Neue Oban-Infrastruktur ohne bestehendes Testmuster (Score: 6)

**Mitigation Strategy:** Kanonisches Oban-Test-Support-Modul vor Story 4 etablieren, das sowohl `Oban.Testing.perform_job/2` (Unit) als auch `Oban.drain_queue/2` (Integration) demonstriert; als Referenz für Story 7 wiederverwenden.
**Owner:** Dev
**Timeline:** Vor Story 4
**Status:** Planned
**Verification:** Test-Support-Modul existiert, von Story 4 UND Story 7 Tests genutzt (kein Duplikat-Pattern).

---

## Mitigation Plans — Update 2026-07-06 (neue Risiken aus Stories 6d/9–13)

### R-028: Backup/Restore vs. Hard-Delete & Legal-Hold (Score: 9, neuer zweiter Critical Blocker)

**Mitigation Strategy:** **UNGELÖST.** Offene Vorfrage (Epic, Offene Entscheidung #11) muss vor Spezifikation geklärt werden: werden Postgres und S3/MinIO getrennt gesichert (unterschiedliches RPO/RTO)? ADR-030 trägt bereits einen „Restore-Verfahren"-Abschnitt (Pflicht-Reconciliation-Lauf nach jedem Restore, der Hard-Deletes/Legal-Holds erneut durchsetzt, bevor das System wieder für Traffic freigegeben wird) — es fehlt aber die Story, die das implementiert. Kein Test-ID vergeben, bis eine Story existiert.
**Owner:** Phil (Produktentscheidung ausstehend) + Winston (Spezifikation)
**Timeline:** Vor Dev-Start von Story 8a, 13c, 13d
**Status:** **Open — Blocker**
**Verification:** Sobald spezifiziert: mindestens ein P0-Integrationstest „simulierter Restore auf einen Snapshot vor Hard-Delete/Legal-Hold-Set → automatischer Reconciliation-Lauf stellt beides wieder her, bevor Traffic freigegeben wird" muss grün sein, bevor das Epic als „Done" gilt.

### R-020: Two-Eyes-Delete-Quorum-Bypass (Score: 6, schützt direkt R-015)

**Mitigation Strategy:** Drei dedizierte Negativ-/Race-Tests bereits als AC-Anforderung in Story 13d benannt (Self-Approval-Bypass, Downgrade-Race, Concurrent-Confirm-Race) — hier zusätzlich als Risiko verankert, damit sie in der Umsetzung nicht als „nice to have" behandelt werden. Kassandra-Security-Review am Epic-Ende prüft explizit, ob diese drei Fälle tatsächlich abgedeckt sind, nicht nur der Happy-Path (Admin+Compliance).
**Owner:** Dev + Kassandra
**Timeline:** Story 13d
**Status:** Planned
**Verification:** `MEDIA.13-SEC-014`, `MEDIA.13-CONC-016`, `MEDIA.13-CONC-017` grün; Kassandra bestätigt keinen weiteren Bypass-Pfad.

### R-019: ADR-032-Reihenfolge nicht eingehalten (Score: 6)

**Mitigation Strategy:** ADR-032 legt die Reihenfolge (DB-Zwischenzustand → Blob-Delete → `storage_key = NULL`) bereits normativ fest; Story 8a implementiert sie zuerst, Story 13c/13d übernehmen dasselbe Muster statt einer Neuerfindung. Reaper-Job für den Zwischenzustand ist Teil der Story-8a-AC.
**Owner:** Dev
**Timeline:** Story 8a, vertieft in 13c/13d
**Status:** Planned
**Verification:** `MEDIA.13-INT-011`/`012` grün — Crash-Simulation zwischen den Schritten wird vom Reaper korrekt und ohne Doppel-Delete des Blobs aufgelöst.

### R-018: `media_config`-Cluster-Cache-Invalidierung (Score: 6)

**Mitigation Strategy:** Wiederverwendung des bereits etablierten `Nebu.Web.OidcConfig`-`:pg`-Broadcast-Musters (kein neues Konzept), ergänzt um einen niedrigen TTL-Fallback für den Netzpartitions-Fall. Multi-Node-Testharness vor Story 9a etablieren (siehe Prerequisites).
**Owner:** Dev
**Timeline:** Story 9a
**Status:** Planned
**Verification:** `MEDIA.9-INT-003`/`004` grün auf einem echten Mehrknoten-Testaufbau, nicht nur simuliert innerhalb eines Prozesses.

### R-024: Storage-Secrets im Klartext (Score: 6)

**Mitigation Strategy:** Vor Story-11a-Implementierung das bestehende Feld-Verschlüsselungs-Tier (analog `email_encrypted`) identifizieren (Offene Entscheidung #9) und wiederverwenden — keine neue Verschlüsselungslösung für dieses eine Feld-Paar.
**Owner:** Dev
**Timeline:** Vor Story 11a
**Status:** Planned
**Verification:** `MEDIA.11-STATIC-001` grün — Rohspalten-Read gegen die DB liefert Chiffrat, nicht Klartext; `MEDIA.11-INT-003` bestätigt Audit-Redaction.

---

## Assumptions and Dependencies

### Assumptions

1. ~~Die drei ADR-Kandidaten (Scanner, Async-Queue, HTTP-Statuscodes) werden wie im Epic vorgeschlagen final entschieden~~ → **erledigt (Update 2026-07-06):** alle neun Epic-ADRs (ADR-024–032) sind final und in `docs/architecture/adr/` abgelegt — Testdesign geht von deren finalen Inhalten aus, nicht mehr von Kandidaten.
2. `media_files` existiert bereits als Tabelle (bestätigt in `server/lib/nebu/media/db.ex`) — Story 1 ist eine additive Migration, keine Neuanlage.
3. `Nebu.Media.SSRF` bleibt die einzige SSRF-Guard-Implementierung im Projekt; Story 9b (vormals Story 7) baut keine Parallel-Lösung für die jetzt admin-konfigurierbare `webhook_url`.
4. Die bestehende `e2e/`-Playwright-Suite und `k6/scenarios/`-Struktur werden für neue Media-Szenarien erweitert, nicht neu aufgesetzt.
5. **(neu, Update 2026-07-06)** `Nebu.Web.OidcConfig`s `:pg`-Broadcast-Muster ist wiederverwendbar für `Nebu.Media.Config` (Story 9a) — falls dafür noch kein Testmuster existiert, ist dessen Etablierung Teil der Story-9a-Vorbereitung, nicht dieses Testdesigns.
6. **(neu)** Story 0 (UX-Foundation) wird bewusst **nicht** mit eigenen `MEDIA.0-*`-Testziel-IDs in diesem Dokument geführt — ihre Must-have-Tests sind bereits als test-first Gherkin-Stubs (`@pending-feature`) direkt im Epic verankert (Playwright, `e2e/features/admin/media-foundation.feature`) und laufen über die reguläre E2E-Pipeline, sobald die referenzierten UI-Stories landen.

### Dependencies

1. Mock-clamd-Stub — benötigt vor Story-3-Teststart
2. Oban-Test-Support-Modul — benötigt vor Story-4-Teststart
3. ClamAV-Container im CI-Stack — benötigt vor `MEDIA.3-INT-008`
4. Klärung R-015 (DSGVO) mit Phil — benötigt vor Story-8/13e-Abnahme
5. Realistisch große `events`-Test-Tabelle (Seed-Skript) — benötigt vor `MEDIA.8-PERF-005`
6. **(neu, Update 2026-07-06)** Klärung Offene Entscheidung #11 (Backup/Restore vs. Legal-Hold, R-028) mit Phil/Winston — benötigt vor Dev-Start von Story 8a, 13c, 13d
7. **(neu)** Secret-Verschlüsselungs-Tier für S3-Credentials identifiziert (Offene Entscheidung #9) — benötigt vor Story-11a-Teststart
8. **(neu)** Multi-Node-Testharness für `:pg`-Cluster-Tests — benötigt vor Story-9a-Teststart
9. **(neu)** `compliance_officer`-Rolle + zweite Admin-Testidentität verfügbar — benötigt vor Story-13d-Teststart

### Risks to Plan

- ~~**Risk**: ADRs werden nicht rechtzeitig vor Story 1 finalisiert.~~ → **erledigt (Update 2026-07-06):** alle neun Epic-ADRs sind final; Risiko entfällt.
- **Risk**: Oban-Einführung verzögert sich wegen unerwarteter Sandbox-/Testing-Mode-Komplikationen.
  - **Impact**: Story 4/7/8 verzögern sich, Concurrency-Tests (R-008, R-009) sind ohne funktionierenden Worker nicht sinnvoll integrationstestbar.
  - **Contingency**: Story-3-Arbeit (ClamAV-GenServer, unabhängig von Oban) vorziehen, wie im Epic bereits als "parallel entwickelbar" vorgesehen.
- **Risk** *(neu, Update 2026-07-06)*: Offene Entscheidung #11 (Backup/Restore vs. Legal-Hold, R-028) wird nicht rechtzeitig vor Story 8a geklärt.
  - **Impact**: Story 8a/13c/13d würden ohne Reconciliation-Konzept implementiert; ein späteres Nachrüsten ist teurer als ein Vorab-Design, und das Epic-DoD-Kriterium „Backup/Restore-Reconciliation verifiziert" bliebe unerfüllbar.
  - **Contingency**: Story 8a nicht als „done" markieren, bis die Vorfrage (getrennte vs. gemeinsame PG/S3-Sicherung) beantwortet ist — Gate-Kriterium, kein Soft-Reminder.
- **Risk** *(neu)*: CI unterstützt keine Multi-Node-Jobs für die `:pg`-Cluster-Tests (Story 9a, R-018).
  - **Impact**: `MEDIA.9-INT-003`/`004` könnten nur simuliert (Single-Node-Mock) statt echt verifiziert werden — Risiko einer falsch-grünen Cluster-Invalidierung, die im echten Mehrknoten-Deployment nicht hält.
  - **Contingency**: Multi-Node-Fähigkeit vor Story 9a im CI-Stack klären; falls nicht möglich, den Single-Node-Kompromiss explizit im Testreport dokumentieren, nicht stillschweigend als „getestet" ausgeben.

---

## Follow-on Workflows (Manual)

- `*atdd` ausführen, um Red-Phase-Tests für die P0-Szenarien pro Story zu generieren (empfohlen: Story 1 zuerst, da Foundation für alle anderen).
- `*automate` nach Implementierung für breitere Coverage (insbesondere P2/P3-Fuzzing der `filename`-Parameter).
- `*trace` am Epic-Ende für die finale PASS/CONCERNS/FAIL-Gate-Entscheidung, sobald Implementierungsevidenz existiert.
- `*nfr-assess` sobald Implementierung + erste Testläufe vorliegen, insbesondere für die R-013-Performance-Evidenz und die Kassandra-Security-Review-Ergebnisse.

---

## Approval

**Test Design Approved By:**

- [ ] Product Manager: Phil Date: ____
- [ ] Tech Lead: ____ Date: ____
- [ ] QA Lead: ____ Date: ____

**Comments:**

---

## Interworking & Regression

| Service/Component | Impact | Regression Scope |
|---|---|---|
| **Bestehende Media-Suite** (`media_upload_test.exs`, `media_download_test.exs`, `media_access_control_test.exs`, `media_range_request_test.exs`, `media_thumbnail_test.exs`, `url_preview_test.exs`) | Download-Handler wird um State-Gate erweitert; synchroner Upload bleibt bestehen, wird aber um Quarantäne-Transition ergänzt | Alle bestehenden Tests müssen weiterhin grün sein — insbesondere Range-Requests und Thumbnails, die jetzt zusätzlich durch den State-Gate laufen müssen |
| **`Nebu.Media.SSRF`** | Wiederverwendung als Referenzmuster für Story 7 (falls `webhook_url` je admin-konfigurierbar wird) | Keine funktionale Änderung an SSRF selbst nötig für dieses Epic |
| **`Nebu.Compliance` (Audit-Log)** | Neue Admin-Actions (Story 6) müssen in `AuditWriter.@known_actions` registriert werden | Bekannte Projekt-Falle: Merge ohne Allowlist-Update bricht Audit-Trail stillschweigend — siehe `MEDIA.6-STATIC-003` |
| **`events`-Tabelle** | Orphan-Detection-Query (Story 8) liest gegen `events.content` | Sicherstellen, dass die Query keinen Lock/Performance-Impact auf reguläre Matrix-Event-Verarbeitung hat |
| **Admin-Auth-Pipeline** | Story 5/6 hängen sich unter die bestehende Admin-Auth ein | Bestehende Admin-Auth-/OIDC-Tests dürfen nicht brechen |
| **`e2e/`-Playwright-Suite** | Neue Admin-Media-Flows kommen hinzu | Laut Projekt-Memory ist die admin/element-Playwright-Suite aktuell wegen Fixture-Brittleness bereits teilweise rot (separate Test-Rehab) — neue Media-E2E-Tests sollten dieses bekannte Flakiness-Muster nicht erben; ggf. isoliert/robust fixture-basiert aufsetzen |
| **`Nebu.Web.OidcConfig`** *(neu, Update 2026-07-06)* | `Nebu.Media.Config` (Story 9a) übernimmt dessen `:pg`-Broadcast-Cache-Invalidierungsmuster 1:1 | Falls für `OidcConfig` noch kein Multi-Node-Test existiert, entsteht hier der erste — sollte dann rückwirkend auch für `OidcConfig` nachgezogen werden (Konsistenz zwischen den beiden einzigen `:pg`-Konsumenten) |
| **`Nebu.Compliance` (Audit-Log)** *(erweitert)* | Story 6d/9/11/13 registrieren neun weitere Actions (`media_bulk_*`, `media_config_updated`, `media_storage_config_updated`, `media_lifecycle_policy_updated`, `media_deletion_proposed/confirmed`, `media_erasure_requested`) | Dieselbe Audit-Allowlist-Merge-Falle wie `MEDIA.6-STATIC-003` gilt hier für jede neue Action — ein CI-Grep-Guard sollte generisch auf „neue `media_*`-Action ohne `@known_actions`-Eintrag" prüfen, nicht nur für Story 6 |

---

## Appendix

### Knowledge Base References

- `risk-governance.md` — Risikoklassifikations-Framework
- `probability-impact.md` — Risiko-Scoring-Methodik
- `test-levels-framework.md` — Test-Level-Auswahl
- `test-priorities-matrix.md` — P0-P3-Priorisierung
- `nfr-criteria.md` — NFR-Bewertungskriterien
- `webhook-risk-guidance.md` — Webhook-Test-Risikoleitfaden (Story 7)

### Related Documents

- Epic: `_bmad-output/planning-artifacts/media-security-admin-control-epic.md`
- Projekt-ADRs: ADR-018 (No Domain Model), ADR-019 (Single OTP App), ADR-020 (Public-API-Regel) — `CLAUDE.md`
- **Neun Epic-ADRs (Update 2026-07-06, jetzt final in `docs/architecture/adr/` abgelegt):** ADR-024 (Scanner-Auswahl), ADR-025 (Async-Scan-Queue), ADR-026 (HTTP-Statuscodes), ADR-027 (`media_config`), ADR-028 (Compliance-Sichtbarkeit/Batch-Kohorten-Vertrag), ADR-029 (Storage-Key-Schema & Kompression), ADR-030 (Media Lifecycle Rules & Two-Eyes Delete, inkl. Restore-Verfahren-Abschnitt), ADR-031 (DB-Level Immutability `media_state_transitions`), ADR-032 (Persistenz-Konsistenz Postgres↔S3)
- Bestehende Media-Tests: `server/test/nebu/media/`

---

**Generated by**: Murat — BMad TEA Agent (Test Architect Module)
**Workflow**: `bmad-testarch-test-design`
**Version**: 5.0 (BMad v6) — **Update 2026-07-06**: Delta-Edit, schließt die Testziel-Lücke für Story 6d, 9, 10, 11, 12, 13 (13a–13f); 11 neue Risiken (R-018–R-028), davon ein zweiter Score-9-Blocker (R-028, ungelöst); Coverage-Plan/Resource-Estimates/Quality-Gate auf 14-Story-Scope aktualisiert. Erstfassung (Version 4.0, 2026-07-01) deckte nur Story 1–8 ab.
