# Epic: Media Security & Admin Control

**Status:** ready
**Epic-Name:** `media-security-admin-control`
**Erstellt:** 2026-07-01
**Autor:** Philipp (innoq / Nebu)
**Review:** 2026-07-01 — Anpassungen gegenüber der ersten Fassung siehe inline-Hinweise in
den Stories.
**Review 2:** 2026-07-01 — Winston (Architect): Admin-Konfigurierbarkeit, Scan-Monitoring
und Compliance-Anbindung ergänzt (Story 9, Story 10, Erweiterungen in Story 4/6, ADR 4/5,
neue Offene Entscheidungen). Siehe inline-Hinweise.
**Review 3:** 2026-07-01 — Winston (Architect): Kompression, Objekt-Storage-Ziel-Konfiguration
und Archiv-Tier ergänzt (Story 11, Story 12, Erweiterung Story 8, ADR 6). **Dabei aufgedeckt:**
die Erstfassung (Story 1/3/4) ging implizit von lokalem Disk-Storage aus (`file_path`,
`scan_file(file_path)`) — die tatsächliche, bereits produktive Implementierung
(`Nebu.Media.Storage`/`Nebu.Media.Crypto`) speichert seit Story 12.x bereits AES-256-GCM-
verschlüsselt direkt in S3/MinIO, ohne lokalen Disk-Schritt. Story 1/3/4 sind entsprechend
korrigiert (`file_path` → `storage_key`, `scan_file/1` → `scan_binary/1`), siehe inline-Hinweise.
**Review 4 (Sprint-Planning, 2026-07-01):** Winston (Architect) — Story-Sizing durchgeführt.
Alle Stories auf ein **S-Ceiling** normalisiert (siehe „Story-Sizing & Split-Übersicht"). Fünf
Stories (1, 2, 4, 6, 8, 9, 10, 11) überschritten S und wurden in `a/b/c…`-Teilpakete zerlegt;
Story 3, 7 und 12 bleiben unverändert. Aus 12 fachlichen Stories werden **33 S-große
Arbeitspakete**. Der Abhängigkeitsgraph und die Build-Reihenfolge sind entsprechend
neu geschrieben (siehe unten).
**Review 5 (2026-07-02):** Winston (Architect) — **R-015 (DSGVO Art. 17, Test-Design Score 9)
angegangen.** Die verstreuten Retention-Knöpfe (8a/8c/8d/8b, 9b) werden zu **einer
konfigurierbaren Media-Lifecycle-Policy** (S3-Lifecycle-Analog) mit **Two-Eyes-Delete**
(S3-MFA-Delete-Analog) und **Legal-Hold** zusammengezogen — neue **Story 13** (13a–13f), neues
**ADR-030**. Policy ist ein **scoped Dokument** mit Cascade `global → space → room`
(most-conservative-wins; per-Raum/Space nur in Compliance Mode — E2EE-Räume → global, spec-bedingt,
Oracle-Consult 2026-07-02). Art. 17 wird korrekt als *Restriction-of-Processing + Vier-Augen-Freigabe*
modelliert, nicht als naives User-Delete. Story 8b's Falschaussage „Löst #4" wird korrigiert, Offene
Entscheidung #4 neu gefasst. Siehe inline-Hinweise „Review 5".
**Review 6 (2026-07-02):** Winston (Architect) — **R-006 (Append-only-Integrität, ADR-031)
angegangen.** Die Unveränderlichkeit von `media_state_transitions` wird DB-seitig erzwungen
(`BEFORE UPDATE OR DELETE`-Trigger, SQLSTATE 23001, + RLS/REVOKE analog `audit_log`), nicht mehr
nur per Grep-Konvention. Siehe inline-Hinweise „Review 6", ADR-031 und die zugehörige DoD-Zeile.
**Review 7 (2026-07-02):** Winston (Architect) — **Feedback-Zyklus „Bulk-Confirm/Undo &
Feedback-States" angegangen.** Der Pflicht-Freitext-pro-Datei aus Story 6c skaliert bei einem
False-Positive-Sturm (eine fehlerhafte freshclam-Signatur flaggt N legitime Dateien) nicht: 40
Einzel-Modals mit copy-paste-Begründungen laundern *eine* Entscheidung in *N* Schein-Begründungen
und unterlaufen die Compliance-Absicht. Neue **Story 6d (Bulk Cohort Actions)**: signatur-skopierter
Bulk-Override + generische Bulk-Aktionen (Rescan/Block/Delete), **eine** Kohorten-Begründung,
per-Datei-Fan-out über eine geteilte `batch_id` (Entscheidung einmal erfasst, Wirkung N-fach
auditierbar). Pre-Commit-Preview als „Bulk-Confirm" (kein Toast-Undo — Append-only-Log ⇒ Undo =
kompensierende Vorwärts-Transition; Soft-Delete ist bereits reversibel). Neuer
**Partial-Result-Feedback-State** (best-effort pro Datei, kein All-or-Nothing). Erweiterungen in
Story 0/5a, neue Offene Entscheidung #10 (Two-Eyes-Eskalation bei Bulk-Override), ADR
„Compliance-Sichtbarkeit" um `batch_id`-Kohorten-Vertrag ergänzt. Siehe inline-Hinweise „Review 7".
**Review 8 (Party-Runde, 2026-07-06):** Winston (Architect), Sati (nebu-agent-ux), John (PM),
Murat (Test Architect), Kassandra (Security) — kritische Runde vor Dev-Start, alle 40 Pakete
waren noch `backlog`. **Ergebnisse:** Offene Entscheidung #10 ist entschieden (nicht mehr offen,
siehe dort) — Kassandras Veto gegen Winstons bisherige Default-Empfehlung (b) wird übernommen.
Drei neue Offene Entscheidungen (#11 Backup/Restore vs. Hard-Delete & Legal-Hold, #12
Data-Subject-Benachrichtigung, #13 Sign-off Records-Management-Scope). Sechs ADR-Kandidaten
als **ADR-024–029** nummeriert und abgelegt; neue **ADR-032** (Persistenz-Konsistenz
Postgres↔S3) ergänzt die Zählung auf **neun** ADRs; **ADR-030** um einen
Restore-Verfahren-Abschnitt erweitert. AC-Ergänzungen in Story 9a (Cluster-Cache-Invalidierung),
13c (Cron/Legal-Hold-Race), 13d (Quorum-Timeout, Self-Approval-Bypass, Approvals-State-Shape),
13e (Data-Subject-Benachrichtigung im Erasure-Workflow), 13f (E2EE-Fallback-Klarstellung) und 6d
(Entscheidung #10 einbauen, Signatur-Scope-Test, Partial-Result-Idempotenz). Murat hat zusätzlich
festgestellt, dass `test-design-progress.md` nur 8 der 13 fachlichen Stories abdeckt (Story 13 und
6d fehlen komplett) — **Test-Design-Update vor Epic-Ende-Review erforderlich**, separat von diesem
Dokument zu beauftragen. Sati bestätigt: Story 0 (UX-Foundation) ist inhaltlich vollständig, hat
aber zwei offene Abhängigkeiten an die Domain (Approvals-State-Shape, s. 13d) und einen nie
beauftragten Scope (Data-Subject-facing UI, s. #12). Siehe inline-Hinweise „Review 8".

**Review 9 (2026-07-10):** Rebase auf `origin/main` hat das inzwischen abgeschlossene
**Enhanced-Logging-Epic** eingebracht (`Nebu.Web.LogStore` mit Writer/Handler/PolicyCache/
RouteNormalizer, admin-konfigurierbare Retention, **War Room Mode** —
`Nebu.Admin.WarRoomManager`, bounded/self-terminating Diagnose-Sessions —, die radiale
**Trace-Map/„Leitstand"**-Visualisierung (`Nebu.Admin.LogsLive.TraceMap`) und die
**genestete Admin-Sidebar** (`admin-sidebar-nesting`: Parent-Nav-Items mit Disclosure-Button +
Kind-Links, s. `Nebu.Admin.Layouts.nav_item/1`, bereits produktiv für „Logs" und
„Configuration"). Zwei Anpassungen an diesem Epic, damit es dieses neue Fundament nutzt statt es
zu duplizieren:

- **Story 0 (IA):** Der Sidebar-Eintrag „Medien" wird — analog zu „Logs"/„Configuration" —
  vom flachen Einzel-Item zu einem **genesteten Parent-Nav-Item** mit sichtbaren Unterpunkten
  (Übersicht/Health/Settings/Approvals). Siehe überarbeitetes IA-Diagramm in Story 0 und
  `EXPERIENCE.md`.
- **Story 10 (neu: 10e):** Die Scan-Pipeline (ClamAV-GenServer, Story 3; Scan-Worker, Story 4b)
  emittiert ihre operativen Ereignisse über die **bestehenden** `Logger`-Aufrufe mit
  `route_template`-Metadata, damit sie **kostenlos** als eigene Domain-Gruppe in der Trace-Map
  erscheinen — keine eigene Pipeline-Visualisierung nötig. Zusätzlich verlinkt
  `/admin/media/health` bei einem ungelösten `critical`-Alert direkt in eine vorbelegte,
  media-skopierte **War-Room-Session** (bounded durch die bestehenden Budget-/Dauer-Grenzen) für
  Live-Diagnose während eines Incidents — statt nur die stündlichen `media_scan_stats`-Rollups zu
  zeigen. `media_scan_stats`/`media_alerts` bleiben als fachliche Business-Tabellen bestehen
  (gleiche Trennung wie `audit_log` vs. `operational_logs`, ADR-020) — diese Story verdrahtet nur
  Sichtbarkeit, keine neue Datenhaltung. Aus 40 Arbeitspaketen werden **41**. Siehe
  inline-Hinweise „Review 9" in Story 0 und Story 10.

---

## Kontext & Rationale

Im Unternehmens- und Behördenumfeld (Zielgruppe: deutsche Kommunen und Behörden) ist
ein unkontrollierter Datei-Upload ein Compliance-Risiko. Jede über die Matrix
Client-Server API hochgeladene Datei kann potenziell Malware enthalten und wird von
allen Room-Mitgliedern automatisch referenziert.

Nebu führt daher einen **Upload-Quarantäne → Scan → Download-Release**-Prozess ein, der
architektur-nativ in den bestehenden Media-Handler integriert wird. Ergänzt wird er durch
Admin-UI-Controls für Oversight, manuelle Eingriffe und Compliance-Reporting.

Der Ansatz ist bewusst **compliance-native**: Der State ist in PostgreSQL hinterlegt,
jede Transition wird unveränderlich geloggt, und der Download-Handler ist der einzige
Enforcement-Punkt — keine separaten Proxy-Schichten.

---

## Architektur-Voraussetzungen

Folgende Entscheidungen sind vor Story 1a zu treffen und als ADRs zu dokumentieren
(siehe Abschnitt „ADR-Kandidaten"):

- **Scanner:** ClamAV via clamd TCP (self-hosted, DSGVO-clean, LGPL)
- **Async-Queue:** Oban (Persistenz, Retry-Semantik, Monitoring)
- **Storage:** Kein Greenfield — `Nebu.Media.Storage`/`Nebu.Media.Crypto` existieren bereits
  (Story 12.x, vor diesem Epic), speichern AES-256-GCM-verschlüsselte Bytes direkt in
  S3/MinIO (`ExAws.S3`), Objekt-Key aktuell flach `= media_id`, kein lokaler Disk-Schritt.
  Dieses Epic **erweitert** diese Schicht (Kompression, Key-Template, Admin-konfigurierbares
  Ziel, Archiv-Tier — Story 11/12), ersetzt sie nicht. PostgreSQL bleibt Single Source of
  Truth für State/Metadaten, S3 ist reiner Blob-Store.
- **HTTP-Statuscodes:** Vgl. ADR-Kandidat unten — Entscheidung vor Story 2a nötig
- **Kompressions-Reihenfolge:** Gzip **vor** Verschlüsselung (`:zlib.gzip/1` → AES-256-GCM),
  nie umgekehrt — komprimierte Zufallsdaten (verschlüsselter Text) bringen keinen Gewinn.
  Siehe ADR-Kandidat „Storage-Key-Schema & Kompression" unten.
- **Async-Upload-Flow:** `POST /_matrix/media/v1/create` + `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`
  wird implementiert. Seit `v1.7` **vollständig in den Kern-Spec übernommen** — die frühere
  Bezeichnung "MSC2246" ist veraltet, v1.18 kennt keinen MSC-Status/„unstable"-Flag mehr dafür.

---

## State Machine

Jede Datei durchläuft folgende States (PostgreSQL ENUM):

```
reserved      → MXC URI vergeben, PUT /upload noch nicht erfolgt (§POST .../media/v1/create)
quarantined   → Bytes angekommen, Scan ausstehend           → Download: 451
scanning      → ClamAV-Job aktiv                            → Download: 451
released      → Scan sauber                                 → Download: 200
infected      → Malware gefunden, nie ausgeliefert          → Download: 404
admin_blocked → Manuell gesperrt durch Admin                → Download: 451
deleted       → Soft-Delete                                 → Download: 404
hard_deleted  → Bytes gelöscht, Record bleibt (Compliance)  → Download: 404
```

**Scan-Error-Pfad:** `scanning → quarantined` (Oban-Retry mit Backoff).
Nach `max_attempts` Erschöpfung: `scan_failed` (siebter State), Admin-Notification.

**MSC2246-Stall-Mechanismus:** Für kleine Dateien (Scan < `max_stall_ms`, Default 20s)
hält der Download-Handler die Connection offen und liefert sofort nach bestandenem Scan.
Für größere Dateien: `M_NOT_YET_UPLOADED`, Client retried.

**Lifecycle-Ladder & Legal-Hold (Review 5, ADR-030):** Die Übergänge zwischen `:released` (aktiv),
`:released`+`archived_at` (Archiv), `:deleted` (marked-deleted / unsichtbar) und `:hard_deleted`
werden von der admin-konfigurierbaren **Media-Lifecycle-Policy** gefahren (Story 13, kein neuer
ENUM-Wert). Ein orthogonales `legal_hold`-Attribut pinnt ein File aus **jeder** automatischen
Transition, bis eine **Vier-Augen-Freigabe** (`two_eyes_delete_required`) erfolgt — Grundlage für
DSGVO Art. 17 (Restriction-of-Processing) und Beweismittel-Sicherung.

**DB-Record-Invariante:** Der `media_files`-Record wird niemals gelöscht. Nach Hard-Delete:
`storage_key = NULL`, `uploader_id = NULL`. `file_hash` (SHA-256) und alle Timestamps bleiben
für Compliance-Nachweise erhalten. (**Winston-Review 3:** umbenannt von `file_path` zu
`storage_key` — die Erstfassung suggerierte einen lokalen Dateisystempfad; tatsächlich ist es
der S3-Objekt-Key, siehe Story 1a/11c.)

---

## Story-Sizing & Split-Übersicht

**Sizing-Rubrik (S-Ceiling):** Eine S-Story ist ein fokussiertes, in einem einzigen
TDD-Pipeline-Durchlauf abschließbares Paket — **maximal eines von**: ~1 Migration/neue Tabelle
(+ ihr Modul) · 1 Elixir-Modul (GenServer/Oban-Worker) · 1 HTTP-Endpoint samt Fehlerpfaden ·
1 LiveView-Seite · Erweiterung *eines* bestehenden Moduls um *eine* kohärente Fähigkeit.
Alles, was Backend + UI + Config bündelt, mehrere neue Tabellen anlegt, eine Multi-Endpoint-Suite
oder Worker + Schema-Change + Compliance-Bridge kombiniert, ist **> S** und wird gesplittet.

| Story | Titel | Größe (Original) | Split |
|---|---|---|---|
| 0 | Media Admin UX Foundation | **S** | — (neu, übergreifende UX-Story) |
| 1 | Media State Machine Foundation | **L** | → 1a, 1b, 1c |
| 2 | Async Upload Endpoints | **XL** | → 2a, 2b, 2c, 2d, 2e |
| 3 | ClamAV GenServer | **S** | — (unverändert) |
| 4 | Async Scan Worker | **L** | → 4a, 4b, 4c |
| 5 | Admin Media Overview | **M** | → 5a, 5b |
| 6 | Admin Media Actions | **L** | → 6a, 6b, 6c, 6d |
| 7 | Admin Notifications | **S** | — (unverändert) |
| 8 | Retention & Cleanup | **XL** | → 8a, 8b, 8c, 8d |
| 9 | Media Policy Settings | **L** | → 9a, 9b, 9c |
| 10 | Scan Health & Alerts Dashboard | **XL** | → 10a, 10b, 10c, 10d, 10e (Review 9) |
| 11 | Object Storage Target Config | **L** | → 11a, 11b, 11c |
| 12 | Gzip Compression at Rest | **S** | — (unverändert) |

**Ergebnis:** 12 fachliche Stories → **33 S-große Arbeitspakete** (durch Review 5/7 später auf
**40** gewachsen), zzgl. der neuen
übergreifenden **UX-Foundation-Story 0** (Definition of Ready für die UI-Stories 5/6/7/9/10/11).
Jedes Teilpaket ist
für sich testbar; die vollständigen Akzeptanzkriterien der Originalstory sind ohne Verlust
auf die Teilpakete verteilt (jedes AC landet in genau einem Teilpaket).

---

## Stories

> **Lesehinweis:** Jede gesplittete Story ist unter ihrer fachlichen Überschrift gruppiert.
> Die Teilpakete tragen jeweils Ziel, Scope (die konkret hier landenden Akzeptanzkriterien),
> Abhängigkeiten und die Intra-Split-Reihenfolge. Nicht gesplittete Stories (3, 7, 12) stehen
> unverändert.

---

### Story 0 — Media Admin UX Foundation  ·  **S (neu — übergreifende UX-Story)**

**Fachliches Ziel:** Das gemeinsame UX-Fundament für die *gesamte* Media-Admin-Oberfläche
etablieren, **bevor** die einzelnen UI-Stories (5, 6, 7, 9, 10, 11) gebaut werden — damit
Informationsarchitektur, State-Vokabular, States (empty/loading/error/live), Accessibility und
Flows *einmal* verbindlich festgelegt sind und nicht in jeder Story neu erfunden werden. Diese
Story liefert kein Backend, sondern die **Design- und Experience-Contracts** als Definition of
Ready für die UI-Stories.

**Deliverables (bereits erstellt, hier als AC verankert):**

- `_bmad-output/planning-artifacts/ux-designs/ux-media-security-admin-control-2026-07-02/DESIGN.md`
  — visuelle Identität (Media-State-Token-Vokabular, Komponenten-Specs), erbt vom produktweiten
  Obsidian-System (DaisyUI-Theme `nebu`).
- `.../EXPERIENCE.md` — IA, State-Patterns, Interaction-Primitives, Accessibility-Floor,
  benannte Key-Flows (Kai / Mara / Dr. Petra).
- `.decision-log.md` — kanonische UX-Entscheidungen D1–D5.

**Scope (Akzeptanzkriterien):**

- **IA verbindlich (Review 9 — genestet statt flach):** Neuer Sidebar-Eintrag **„Medien"** wird,
  analog zum bereits produktiven `admin-sidebar-nesting`-Muster für „Logs"/„Configuration"
  (`Nebu.Admin.Layouts.nav_item/1`), ein **Parent-Nav-Item mit Disclosure-Button** (`aria-expanded`
  + Chevron, CSP-sicher über `wireNavSectionToggles()`) statt eines flachen Einzel-Links. Kinder
  (`@media_nav_children`, navkey-namespaced wie `media-*`):
  - „Übersicht" → `/admin/media` (die bisherige Hub-Tabelle — der Parent selbst navigiert nicht
    mehr, exakt wie beim „Configuration"-Vorbild, dessen „General"-Route ebenfalls zum Kind wurde)
  - „Health" → `/admin/media/health`
  - „Settings" → `/admin/media/settings`
  - „Approvals" → `/admin/media/approvals` (Two-Eyes-Delete-Queue, Story 13d)

  `/admin/media/:id` bleibt bewusst **kein** eigener Nav-Eintrag (Drill-down aus „Übersicht", wie
  `/admin/config/:id`-artige Detailseiten auch sonst nicht in der Sidebar auftauchen). Die
  bestehenden Attention-Badges (Story 5b/7) wandern auf den **Parent-Button** selbst (sichtbar
  auch eingeklappt — kein neuer Mechanismus, nur eine neue Platzierung des bestehenden
  `nav-attention-badge`-Patterns); zusätzlich erhält das „Health"-Kind einen kleinen Dot
  (wiederverwendet `Map.get(child, :dot, false)`, exakt das Muster des War-Room-„recording"-Dots
  auf dem „War Room"-Kind unter „Logs"), wenn ein ungelöster `critical`-`media_alerts`-Eintrag
  vorliegt. Media-Audit-Einträge erscheinen zusätzlich in `AuditLogLive`.
- **State-Farb-Vokabular (D2):** Jeder der 9 States rendert als Badge mit **Farbe + Icon + Text**
  (nie Farbe allein): processing (amber), `released` (teal), `infected` (rot), `admin_blocked`
  (coral), terminal (grau). Die zwei neuen Tokens (teal/coral) sind vor Merge auf **≥ 4.5:1 auf
  `base-200`** zu prüfen.
- **URL-adressierbarer State (PRD FR50/NFR-O4):** Filter, Sortierung, Cursor, aktiver Tab und
  offene Detail-ID leben in der URL — bookmarkbar/teilbar, kein LocalStorage-Zwang.
- **Realtime-Mechanismus (D1):** Phoenix LiveView + PubSub (nicht Vue/SSE); Zeilen-Level-Updates
  bewegen **nicht** den Fokus.
- **Destruktive Aktionen:** CSP-sichere LiveView-Modals (kein `window.confirm`), Fokus-Trap +
  Fokus-Rückgabe, Escape schließt, Default-Fokus nie auf dem destruktiven Button. Override-Dialog
  trägt die wörtliche Warnung „Diese Datei wurde als Malware erkannt. Freigabe erfolgt auf eigene
  Verantwortung." und ist nur für Rolle `media_admin_override` sichtbar.
- **Bulk-Selektion & Partial-Result (Review 7, für Story 6d):** Multi-Select-Primitive (Row-Checkbox
  + „Alle zum Filter auswählen"), Bulk-Confirm-Modal (zeigt Kohorten-Schlüssel/Signatur + Count +
  Dateiliste, Deselektieren vor dem Commit möglich) und ein neuer **Partial-Result-State** neben
  empty/loading/error/live: „N erfolgreich · M übersprungen (Grund) · K Fehler". Die Auswahl ist
  **transient** (kein URL-State — anders als Filter/Sort/Cursor) und überlebt Live-Row-Updates.
  Aggregierte Feedback-Ausgabe via `aria-live="polite"`.
- **Accessibility-Floor (PRD NFR-A1/A2/A3, WCAG 2.1 AA):** vollständige Tastaturbedienung;
  `table` mit `<th scope="col">` + `<caption class="sr-only">`; sichtbare `<label for>`; einheitlicher
  Focus-Ring; `aria-live="polite"` für Nav-Attention-Badges. Diese sind **blockierende** Kriterien,
  keine Empfehlungen.
- **E2E-Hooks stabil:** Neue Surfaces tragen `data-page`/`data-role`/`data-section`/`data-state`/
  `data-media-id`-Hooks analog zu bestehenden Admin-Seiten; bestehende Hooks werden nicht umbenannt
  (additiv). Selektoren in Playwright bevorzugt `getByRole`/`getByLabel`.

**Playwright-Test-Stubs (test-first, `@pending-feature` bis die jeweilige UI-Story landet):**

```gherkin
# e2e/features/admin/media-foundation.feature
Feature: Media Admin UX Foundation
  Background:
    Given the operator is logged in as admin

  @pending-feature
  Scenario: Media nav entry is reachable and marked current
    When the operator opens "/admin/media"
    Then the "Übersicht" child navigation item has aria-current "page"
    And the "Medien" parent navigation item has the secondary accent, not aria-current
    And the media table has an accessible column header for "Status"

  @pending-feature
  Scenario: Medien nav group expands and collapses without navigating (Review 9)
    When the operator activates the "Medien" navigation button
    Then it has "aria-expanded" set to "true"
    And the "Übersicht", "Health", "Settings" and "Approvals" child links are visible
    And the browser URL has not changed

  @pending-feature
  Scenario: Attention badge and Health dot render on the collapsed parent (Review 9)
    Given an unresolved "critical" media alert exists
    And the "Medien" navigation group is collapsed
    Then the "Medien" parent button still shows the attention badge count
    And the "Health" child link, once expanded, carries the recording-style dot indicator

  @pending-feature
  Scenario: State badges expose text, not color alone
    Given a media file in state "infected"
    Then its row shows a badge with the accessible text "Infiziert"

  @pending-feature
  Scenario: Filter state is reflected in the URL
    When the operator filters media by state "Infiziert"
    Then the page URL contains the state filter parameter

  @pending-feature
  Scenario: Override action is hidden without the override role
    Given the operator lacks the "media_admin_override" role
    And a media file in state "infected"
    Then no "Freigeben (Override)" action is present on its row
```

- **Story-13-Coverage (Review 5):** Die Contracts decken auch die neuen UI-Surfaces der
  Lifecycle-Policy ab — **13b** (Lifecycle-Rules-Ladder-Editor auf `/admin/media/settings`),
  **13d** (Two-Eyes-Delete-Freigabe-Queue, `compliance_officer` als zweite Person),
  **13e** (Art.-17-Erasure = Restriction-of-Processing + Legal-Hold-Pin). Rollenmodell:
  `compliance_officer` **freigebend** (nicht nur lesend); Legal-Hold/Restriction sind Overlays
  über der Lifecycle-State-Machine, visuell klar von `deleted` unterschieden.

- **Story-6d-Coverage (Review 7):** Die Contracts decken auch die Bulk-Selektion, das
  Bulk-Confirm-Modal und den Partial-Result-Feedback-State (Story 6d) ab — Multi-Select-Primitive,
  Kohorten-Preview und die aggregierte `aria-live`-Ergebnismeldung sind einmal verbindlich
  festgelegt, nicht pro Aktion neu erfunden.

**Abhängigkeiten:** keine (UX-Foundation). **Definition of Ready für:** Stories 5, 6, 6d, 7, 9, 10, 11
sowie 13b, 13d, 13e — diese referenzieren DESIGN.md/EXPERIENCE.md und dürfen erst „ready" werden,
wenn ihr Screen-Scope gegen die Contracts abgeglichen ist.

---

### Story 1 — Media State Machine Foundation  ·  **L → 1a / 1b / 1c**

**Fachliches Ziel:** Die Datenbankgrundlage und das Elixir-State-Machine-Modul für alle
weiteren Stories etablieren. Download-Gate als Enforcement-Punkt implementieren.

#### Story 1a — `media_files`-Migration + `media_state_transitions`-Tabelle  ·  **S**

**Scope (Akzeptanzkriterien):**

- Migration: `media_files` erhält Spalten `state` (ENUM), `file_hash` (TEXT, SHA-256),
  `scan_metadata` (JSONB, enthält ClamAV-Signatur und Scan-Zeitstempel),
  `storage_key` (TEXT, nullable — **Winston-Review 3:** ersetzt die ursprünglich geplante
  Spalte `file_path`; ist der S3-Objekt-Key im konfigurierten Bucket, nicht ein
  Dateisystempfad — persistiert den zur Upload-Zeit aus dem Key-Template berechneten Wert,
  siehe Story 11c, damit spätere Template-Änderungen bestehende Objekte nicht unauffindbar
  machen), `compressed` (BOOLEAN, NOT NULL DEFAULT false — siehe Story 12),
  `archived_at` (TIMESTAMPTZ, nullable — siehe Story 8c),
  `deleted_at` (TIMESTAMPTZ, nullable), `hard_deleted_at` (TIMESTAMPTZ, nullable)
- Neue Tabelle `media_state_transitions`:
  `(id, media_id FK, from_state, to_state, actor_type ENUM(system|admin),
  actor_id UUID nullable, metadata JSONB, inserted_at)` — kein UPDATE, kein DELETE
- **DB-seitige Append-only-Durchsetzung (Review 6, R-006, ADR-031):** Die Unveränderlichkeit
  wird **nicht** nur per Grep-Konvention (Story 1b) erzwungen, sondern in der Migration selbst:
  - **Primär:** `BEFORE UPDATE OR DELETE`-Trigger `media_state_transitions_no_mutate`, der
    `RAISE EXCEPTION … USING ERRCODE = 'restrict_violation'` (SQLSTATE 23001) wirft — feuert für
    **jede** Rolle inkl. Table-Owner, hält also auch im Single-Role-Dev/CI und liefert eine echte
    Postgres-Fehlermeldung. Feuert nur auf UPDATE/DELETE, nie auf INSERT (Backfill/Runtime-Appends
    unberührt).
  - **Sekundär (Defense-in-Depth, Vokabular-Konsistenz mit `audit_log`):** `ENABLE ROW LEVEL
    SECURITY` + Policies `FOR UPDATE/DELETE USING (false)`, `FOR INSERT WITH CHECK (true)`,
    `FOR SELECT USING (true)` + `REVOKE UPDATE, DELETE ON media_state_transitions FROM nebu_app`
    (analog `audit_log`, Migration 000001).
  - **Kein `SECURITY DEFINER`-Purge** (anders als `audit_log`): append-only-forever; Retention/
    Rollup ist vertagt (Offene Entscheidung #5). Ein künftiger Rollup-Job muss den Trigger explizit
    `DISABLE TRIGGER` in seiner Transaktion — sichtbarer, auditierbarer Escape-Hatch.
- Der `state`-ENUM definiert den Wertesatz **ohne** `scan_failed` (dieser Wert wird in
  Story 4a per `ALTER TYPE` nachgezogen).

**Abhängigkeiten:** keine (Foundation). **Intra-Split-Reihenfolge:** 1 von 3, vor 1b und 1c.

#### Story 1b — `Nebu.Media.StateMachine`-Modul  ·  **S**

**Scope (Akzeptanzkriterien):**

- `Nebu.Media.StateMachine`-Modul mit Guards für erlaubte Transitionen; jede Transition
  schreibt einen Eintrag in `media_state_transitions`.
- Invarianten-Check (grep-Test): Kein direktes SQL-UPDATE auf `state` außerhalb von
  `Nebu.Media.StateMachine`. **Hinweis (R-006, ADR-031):** Dieser Grep bleibt die günstige erste
  Verteidigungslinie; die **autoritative** Durchsetzung der Transitions-Unveränderlichkeit ist
  DB-seitig (Trigger + RLS/REVOKE, Story 1a), nicht der Grep.

**Hinweise:**

- Machinery-Library oder manuelles FSM — je nachdem was weniger Abstraktionsschicht aufbaut.
  Inline-SQL in den Funktionen, kein Repository-Pattern.
- Der `actor_id` in `media_state_transitions` ist für Scanner-Transitions NULL
  (actor_type = :system).

**Abhängigkeiten:** 1a. **Intra-Split-Reihenfolge:** 2 von 3.

#### Story 1c — Download-Gate-Enforcement (State → HTTP)  ·  **S**

**Scope (Akzeptanzkriterien):**

- Download-Handler (`/_matrix/media/v3/download/` und `/_matrix/client/v1/media/download/`)
  prüft State vor File-Serving, implementiert als einzige Erfolgsbedingung (`:released` → 200),
  alle anderen States fallen in die jeweilige Deny-Antwort:
  - `:reserved`, `:quarantined`, `:scanning` → 451 mit `M_NOT_YET_UPLOADED`
  - `:admin_blocked` → 451 mit `M_NOT_FOUND` (Anonymität der Blockierung)
  - `:infected`, `:deleted`, `:hard_deleted` → 404 mit `M_NOT_FOUND`
  - `:released` → 200 OK
  - Jeder weitere State (z.B. `scan_failed`, Story 4a) fällt ohne Sonderbehandlung in die
    451-Antwort.

**Abhängigkeiten:** 1a, 1b. **Intra-Split-Reihenfolge:** 3 von 3.

---

### Story 2 — Async Upload Endpoints  ·  **XL → 2a / 2b / 2c / 2d / 2e**

**Fachliches Ziel:** Die seit Matrix `v1.7` stabilen Async-Upload-Endpoints spec-konform
implementieren. Clients können eine MXC URI reservieren und Bytes in einem separaten PUT liefern.

> ⚠️ **Korrektur gegenüber der ersten Fassung** (Oracle-Review, 2026-07-01): mehrere Punkte
> unten weichen von der ursprünglichen Draft-Fassung ab — Details in den Hinweisen.

#### Story 2a — `POST /_matrix/media/v1/create`  ·  **S**

**Scope (Akzeptanzkriterien):**

- **Kein Request-Body, keine Query-Parameter.** Ein `expires_at`-Query-Parameter (wie in der
  ersten Draft-Fassung) ist **nicht spec-konform** und entfällt.
- Erstellt einen `media_files`-Record mit `state: :reserved` und persistiert den aufrufenden
  User als `uploader_id` (**Required** für den Ownership-Check in PUT).
- Server legt `unused_expires_at` **einseitig** fest und gibt es im 200-Response zurück:
  `{"content_uri": "mxc://...", "unused_expires_at": <ms-epoch>}` — **beide Felder Required**.
  Spec-Empfehlung Default: **24h**; kürzere Werte nur als dokumentierte ADR-Abweichung.
- Pending-Upload-Limit pro User (`max_pending_per_user`, Default 20): bei Überschreitung
  `429 M_LIMIT_EXCEEDED` + `retry_after_ms`.
- `403 M_FORBIDDEN`, wenn der User keine Upload-Berechtigung hat.

**Abhängigkeiten:** 1a, 1b. **Intra-Split-Reihenfolge:** 1 von 5 (vor 2b).

#### Story 2b — `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` (Validierung + Fehlerpfade)  ·  **S**

**Scope (Akzeptanzkriterien):**

- `Content-Type` **seit v1.12 optional** (Default `application/octet-stream`) — Handler darf ihn
  nicht verlangen.
- Query-Parameter `filename` (optional): MUSS persistiert und für `Content-Disposition` beim
  Download verwendet werden.
- **Ownership-Check → `403 M_FORBIDDEN`**: PUT MUSS vom selben User stammen wie `/create`
  (unabhängig vom State).
- **`404 M_NOT_FOUND`**: mediaId existiert nicht, nicht via `/create` erzeugt, oder
  `unused_expires_at` verstrichen. Expiry-Check **live im PUT-Handler** (nicht nur Cleanup-Cron).
- **`409 M_CANNOT_OVERWRITE_MEDIA`**: PUT auf eine mediaId mit bereits vorhandenem Content
  (State ≠ `:reserved`) — exakt dieser Errcode, auch bei identischem Retry nach Erfolg (keine
  Idempotenz-Ausnahme).
- **`413`**: Body überschreitet Max-Upload-Size — **vor** dem Schreiben geprüft (Content-Length +
  Streaming-Limit), unabhängig von `Nebu.Media.ClamAV`s `max_file_size_bytes`.
- Bei Erfolg: SHA-256 auf den **empfangenen Original-Bytes** (vor Kompression), dann
  Kompression + Verschlüsselung + S3-Write über die bestehende
  `Nebu.Media.Storage`/`Nebu.Media.Crypto`-Pipeline (Gzip → AES-256-GCM → `Storage.put/2`;
  S3-Key aus dem Template, persistiert in `storage_key`, s. Story 11c), Transition
  `reserved → quarantined`, Oban-Scan-Job enqueuen. Response `200 {}`.
- Ownership- und Expiry-Check sind reine Lesevorgänge und laufen vor dem State-Guard.

**Abhängigkeiten:** 2a, 12 (Kompressions-Pipeline). **Intra-Split-Reihenfolge:** 2 von 5.

#### Story 2c — Synchroner Upload über die geteilte Pipeline  ·  **S**

**Scope (Akzeptanzkriterien):**

- Der bestehende `POST /_matrix/media/v3/upload` (synchroner Upload) bleibt erhalten:
  Bytes ankommen → direkt `:quarantined` (kein `:reserved`) → Oban-Job.
- Läuft durch **dieselbe** `Nebu.Media.Storage`-Pipeline wie der Async-Upload — kein Duplikat
  zwischen sync- und async-Pfad (Kompression/Verschlüsselung/Key-Template als
  Storage-Erweiterung, nicht endpoint-spezifisch).

**Abhängigkeiten:** 2b (teilt den Persist-+-Transition-+-Enqueue-Seam). **Intra-Split-Reihenfolge:** 3 von 5.

#### Story 2d — Download-Stall-Mechanismus  ·  **S**

**Scope (Akzeptanzkriterien):**

- Query-Parameter `?timeout=N` (ms) im Download-Handler → wartet bis zu N ms auf Transition zu
  `:released` via `Phoenix.PubSub`-Subscription (Topic `"media:#{media_id}"`). Default 20000ms.
  Bei Ablauf 451 `M_NOT_YET_UPLOADED`.
- Globales oder per-User/IP-Limit auf gleichzeitig gehaltene Stall-Requests (z.B. Zähl-Semaphor
  vor dem `receive`-Block).
- Der Stall ist ein `receive`-Block mit Timeout in einem Task, kein Polling-Loop.

**Abhängigkeiten:** 1c (das Gate, das erweitert wird), 2b. Der auslösende Broadcast kommt
regulär vom Scan-Worker (Story 4b); für den Test genügt eine manuelle `StateMachine`-Transition
+ Broadcast, daher **keine** harte Abhängigkeit zu Story 4. **Intra-Split-Reihenfolge:** 4 von 5.

#### Story 2e — Cleanup-Cron für reservierte Uploads  ·  **S**

**Scope (Akzeptanzkriterien):**

- Oban-Cron: `:reserved`-Records ohne Bytes nach `unused_expires_at` löschen (Hard-Delete
  erlaubt, da keine Bytes auf Disk). Best-effort/Housekeeping — die eigentliche Expiry-Durchsetzung
  ist der Live-Check im PUT-Handler (2b).

**Abhängigkeiten:** 2a (unabhängig von 2b–2d). **Intra-Split-Reihenfolge:** 5 von 5.

**Terminologie-Hinweis (ganze Story 2):** Der Flow wurde historisch „MSC2246" genannt; seit
`v1.7` vollständig im Kern-Spec, v1.18 ohne MSC-Referenz/„unstable"-Flag. Kein
Capability-Discovery-Flag — Clients probieren `/create` und fallen bei Fehlern auf den
synchronen Upload zurück.

---

### Story 3 — ClamAV GenServer  ·  **S (unverändert)**

**Ziel:** Elixir-GenServer der clamd via TCP-Protokoll anspricht. Scanresultat als
strukturierter Return-Wert.

**Akzeptanzkriterien:**

- `Nebu.Media.ClamAV` GenServer im Supervision-Tree unter `Nebu.Media.Supervisor`
- Konfiguration in `config.exs`:
  ```elixir
  config :nebu, Nebu.Media.ClamAV,
    address: {:tcp, "127.0.0.1", 3310},   # oder {:unix, "/var/run/clamav/clamd.ctl"}
    max_file_size_bytes: 100 * 1024 * 1024  # 100 MB Default
  ```
- `Nebu.Media.ClamAV.scan_binary(bytes)` →
  `{:ok, :clean}` | `{:ok, {:infected, signature}}` | `{:error, reason}`
  (**Winston-Review 3:** ursprünglich `scan_file(file_path)` — die Bytes liegen aber
  ausschließlich verschlüsselt in S3; der Aufrufer (Story 4b) lädt, entschlüsselt und
  dekomprimiert sie **im Speicher** und übergibt das Binary. Kein temporäres File auf Disk.)
- INSTREAM-Protokoll: `bytes` in 4096-Byte-Chunks (`:binary.part/3` über das In-Memory-Binary,
  kein `File.stream!`) an clamd, Response parsen.
- Health-Check beim Start: clamd nicht erreichbar → Log-Warning, GenServer startet trotzdem.
- Auto-Reconnect nach Connection-Drop.
- Dateien über `max_file_size_bytes` werden nicht gescannt: `{:error, :file_too_large}`.
- Jeder `:gen_tcp`-Fehlerfall (Timeout, Drop, malformed Response, clamd down) liefert
  `{:error, reason}`, nie eine Exception. Explizite Timeouts auf jedem Call, kein unbounded
  `receive`.

**Hinweise:** Kein NIF, kein Shell-Out zu `clamdscan` — nur TCP-Socket via `:gen_tcp`. Bei
co-located Deployment `{:unix, ...}` bevorzugen; TCP nur intern erreichbar. Der clamd-Container
erhält keine DB-Credentials. freshclam-Updates + Image-Patch-Kadenz als Betriebsanforderung.
Unit-Tests mit Mock-clamd-Stub inkl. jedes Fehlerfalls.

**Abhängigkeiten:** keine.

---

### Story 4 — Async Scan Worker  ·  **L → 4a / 4b / 4c**

**Fachliches Ziel:** Oban-Worker der den ClamAV-GenServer aufruft und State-Transitions
durchführt. Retry-Logik und Dead-Letter-Handling.

#### Story 4a — `scan_failed`-ENUM-Migration + Elixir-State-Liste  ·  **S**

**Scope (Akzeptanzkriterien):**

- `ALTER TYPE ... ADD VALUE 'scan_failed'`-Migration (eigene Migration in dieser Story).
- Keine Elixir-seitige State-Liste aus Story 1b darf diesen Wert vergessen.

**Abhängigkeiten:** 1a, 1b. **Intra-Split-Reihenfolge:** 1 von 3 (vor 4b).

#### Story 4b — `MediaScanWorker` Scan-Flow + Retry/Discard  ·  **S**

**Scope (Akzeptanzkriterien):**

- `Nebu.Workers.MediaScanWorker` als Oban-Worker. Flow:
  1. State `quarantined → scanning`.
  2. Bytes per `Nebu.Media.Storage.get(storage_key)` aus S3 laden, mit
     `Nebu.Media.Crypto.decrypt/3` entschlüsseln, bei `compressed: true` mit `:zlib.gunzip/1`
     dekomprimieren — Ergebnis ist das Original-Binary im Speicher.
  3. `Nebu.Media.ClamAV.scan_binary(bytes)` aufrufen.
  4. `{:ok, :clean}` → `scanning → released`, PubSub-Broadcast auf `"media:#{id}"`.
  5. `{:ok, {:infected, sig}}` → `scanning → infected`, `scan_metadata` mit Signatur füllen.
  6. `{:error, _}` → `scanning → quarantined` zurück, Oban-Retry (raise `RuntimeError`).
- Oban: `max_attempts: 5`, `backoff: :exponential`; `Oban.Plugins.Lifeline` mit `rescue_after`
  komfortabel über der Max-Scan-Dauer (30–60 min); Queue-Shutdown mit `:shutdown_grace_period`.
- Nach `max_attempts`-Erschöpfung (`discard/2`): `quarantined/scanning → scan_failed`,
  Admin-Notification via PubSub.
- `:file_too_large` → `scanning → released` mit `scan_metadata: %{skipped: "size_limit"}` +
  Audit-Log-Eintrag — kein Retry (kein Fehler).
- Jeder State-Übergang schreibt in `media_state_transitions` (actor_type: :system).

**Hinweise:** Der PubSub-Broadcast in Schritt 4 triggert den Stall-Mechanismus (2d).
`scan_failed` ist ein eigener State (nicht `infected`) — Admin entscheidet manuell.

**Abhängigkeiten:** 4a, 3, 1b, 2b (liefert `:quarantined`-Records), 12 (Dekomprimier-Schritt).
**Intra-Split-Reihenfolge:** 2 von 3.

#### Story 4c — Compliance-Audit-Bridge (infected / scan_failed)  ·  **S**

**Scope (Akzeptanzkriterien):**

- Bei `:infected` und bei `scan_failed` (Discard-Callback) schreibt der Worker **zusätzlich** zu
  `media_state_transitions` einen Eintrag in `Nebu.Compliance.AuditWriter` (Tabelle `audit_log`) —
  Aktionen `media_infected_detected` / `media_scan_failed`, `target_type: "media"`,
  `target_id: media_id`, `metadata: %{filename, sha256: file_hash, uploader_id, clamav_signature}`.
- Neue Actions **müssen** im selben Commit in `AuditWriter.@known_actions` registriert werden
  (bekannte Merge-Falle — vgl. Projekt-Erfahrung mit stillschweigend brechenden Audit-Trails).
- **Kein `room_id`** in diesem Metadata-Eintrag (bewusst): `media_files` hat keine
  `room_id`-Spalte; Raum-Zuordnung ist ein Query-Zeit-Join gegen `events.content`
  (`target_id` = `media_id`). Siehe ADR-Kandidat „Compliance-Sichtbarkeit von Scan-Events".

**Abhängigkeiten:** 4b. **Intra-Split-Reihenfolge:** 3 von 3.

---

### Story 5 — Admin Media Overview  ·  **M → 5a / 5b**

**Fachliches Ziel:** Phoenix-LiveView-Tabelle `/admin/media` mit Realtime-Updates, Filtern und
State-Badges für alle Media-Files.

#### Story 5a — `/admin/media` LiveView-Tabelle (Filter + Pagination)  ·  **S**

**Scope (Akzeptanzkriterien):**

- Route `GET /admin/media` (unter bestehender Admin-Auth-Pipeline).
- Tabellen-Spalten: State-Badge, Dateiname, Uploader (Matrix-ID), MIME-Type, Dateigröße
  (human-readable), `uploaded_at`, `scanned_at`, ClamAV-Signatur (wenn vorhanden).
- Filter: State (Multi-Select), MIME-Type-Prefix, Uploader-Suche, Datum-Range für
  `uploaded_at`; Filter-State in URL-Params (Bookmark-fähig).
- Pagination: 50 Einträge/Seite, Cursor-basiert (kein OFFSET).
- Alle DB-Queries als Inline-SQL in den LiveView-Handler-Funktionen.
- Nur Metadaten als Text — kein Inline-Preview/Thumbnail. Dateiname via HEEx-Auto-Escaping,
  kein `raw/1`.
- State-Badge-Farben: amber für processing-States, teal für `:released`, red für `:infected`,
  coral für `:admin_blocked`, gray für terminale States.
- **Multi-Select für Bulk-Aktionen (Review 7, Vorbedingung für 6d):** Row-Checkboxen + „Alle zum
  aktuellen Filter auswählen" (mit Count). Die Auswahl überlebt Live-Row-Updates (PubSub darf die
  Selektion nicht leeren) und ist **transient** (kein URL-State — Selektion ist nicht bookmarkbar,
  anders als Filter/Sort/Cursor). Eine Action-Bar mit Auswahl-Count blendet nur die im Kontext
  erlaubten Bulk-Aktionen ein. Der Signatur-Filter ist der natürliche Kohorten-Selektor für
  Bulk-Override (Signatur filtern → alle auswählen → Override).

**Abhängigkeiten:** 1a. **Intra-Split-Reihenfolge:** 1 von 2.

#### Story 5b — Live-Row-Updates + Nav-Attention-Badges  ·  **S**

**Scope (Akzeptanzkriterien):**

- PubSub-Subscription: neue Quarantäne-Events und Scan-Ergebnisse aktualisieren nur die
  betroffene Zeile (kein Full-Re-Render).
- Attention-Badges im Admin-Nav: Counts für `:quarantined`, `:scan_failed`, `:infected`,
  unabhängig via PubSub aktualisiert (kein Full-Reload).

**Abhängigkeiten:** 5a. **Intra-Split-Reihenfolge:** 2 von 2.

---

### Story 6 — Admin Media Actions  ·  **L → 6a / 6b / 6c / 6d**

**Fachliches Ziel:** Admin-Aktionen pro Media-File: Sperren, Entsperren, Löschen, Manueller
Rescan, Override — einzeln (6a–6c) und als Bulk-Kohorten-Aktion (6d). Alle Aktionen sind auditiert.

#### Story 6a — Routine-State-Aktionen (Block/Unblock/Delete/Rescan)  ·  **S**

**Scope (Akzeptanzkriterien):**

- Aktionen je nach State: `:released` → Block (→ `:admin_blocked`), Delete (→ `:deleted`);
  `:admin_blocked` → Unblock (→ `:released`), Delete; `:quarantined`/`:scan_failed` → Rescan
  (neuer Oban-Job), Delete; alle States → Delete.
- Block/Unblock idempotent (No-Op + Info-Flash). Optionaler Freitext-Grund für Block (in `metadata`).
- Confirmation-Dialoge für destructive Delete (LiveView-Modals, kein `position: fixed`); kein
  Dialog für Block/Unblock.
- Alle Aktionen schreiben `actor_type: :admin, actor_id: current_admin.id` in
  `media_state_transitions`.
- Jede Action (Block/Unblock/Delete/Rescan) wird im selben Commit in `AuditWriter.@known_actions`
  registriert (landet im globalen Audit-Log).

**Abhängigkeiten:** 5a, 4b (Rescan enqueued einen Scan-Job). **Intra-Split-Reihenfolge:** 1 von 4.

#### Story 6b — Detail-View + Storage-Summe  ·  **S**

**Scope (Akzeptanzkriterien):**

- Detail-View pro File: Metadaten (Hash, Größe, MIME), vollständiger Audit-Trail aus
  `media_state_transitions`, ClamAV-Signatur falls vorhanden.
- Storage-Anzeige: Summe der Bytes für aktive (`:released`) und pending-Hard-Delete-Media
  (`:deleted`) separat ausweisen.

**Abhängigkeiten:** 5a (unabhängig von 6a; read-only). **Intra-Split-Reihenfolge:** 2 von 4.

#### Story 6c — Infected-Override für False Positives  ·  **S**

**Scope (Akzeptanzkriterien):** (löst Offene-Entscheidung #1)

- `:infected → :released` nur über eine dedizierte Aktion, kein Nebeneffekt von Rescan.
- Nur für Admins mit separater Rolle `media_admin_override` (nicht Teil der normalen
  Admin-Rolle) — verhindert flächigen Scanner-Bypass.
- Pflicht-Begründungsfeld (Freitext, kein leerer String) — in `media_state_transitions.metadata`
  **und** im Audit-Log.
- Schreibt `media_infected_override` in `AuditWriter.@known_actions` mit
  `metadata: %{reason, original_signature: scan_metadata["signature"]}`.
- Confirmation-Dialog mit verschärfter Warnung („Diese Datei wurde als Malware erkannt.
  Freigabe erfolgt auf eigene Verantwortung.").
- **Nicht** idempotent-still: jeder Override verlangt erneut eine Begründung.

**Abhängigkeiten:** 6a. **Intra-Split-Reihenfolge:** 3 von 4.

#### Story 6d — Bulk Cohort Actions (Confirm + Partial-Result)  ·  **S**  (Review 7)

**Scope (Akzeptanzkriterien):** (adressiert den Feedback-Zyklus „Bulk-Confirm/Undo & Feedback-States")

- **Bulk-Varianten** der Aktionen aus 6a/6c über Multi-Select in der Tabelle (Story 5a):
  Bulk-**Rescan** (niedriges Risiko), Bulk-**Block/Unblock**, Bulk-**Delete** (Soft-Delete),
  Bulk-**Override** (`:infected → :released`, höchstes Gate).
- **Eine Kohorten-Begründung statt N Freitexte:** Die Aktion erfasst *einen* Freitext-Grund für die
  gesamte Kohorte (kein leerer String bei Override/Block). Pflicht-Freitext pro Datei (6c) würde bei
  einem False-Positive-Sturm zu 40 copy-paste-Begründungen führen und die Compliance-Absicht
  unterlaufen — die Kohorten-Begründung erfasst die *eine* tatsächliche Entscheidung ehrlich.
- **Batch-Fan-out (zentrale Compliance-Invariante):** Jede Bulk-Aktion erzeugt eine `batch_id`
  (UUID). Die Entscheidung wird *einmal* erfasst, die Wirkung ist *per-Datei* auditierbar:
  - N `media_state_transitions`, je `metadata: %{batch_id, reason, cohort_key}` (jede Datei behält
    ihren eigenen unveränderlichen Trail).
  - N `audit_log`-Einträge (**nicht** ein Sammel-Eintrag), je mit `batch_id` gestempelt — damit eine
    Datei nicht aus dem per-Raum-Compliance-Report verschwindet, nur weil sie in einem Batch lief
    (vgl. ADR „Compliance-Sichtbarkeit", `batch_id`-Kohorten-Vertrag).
- **Bulk-Override ist signatur-skopiert:** Die Override-Kohorte ist „alle `:infected`-Dateien, die
  von *einer* ClamAV-Signatur geflaggt wurden" (`cohort_key = signature`), **nicht** „diese N
  beliebigen Dateien". Das matcht die reale Ursache (eine fehlerhafte freshclam-Signatur) und macht
  die behauptete Tatsache verifizierbar. Nur Rolle `media_admin_override` (wie 6c); dieselbe
  verschärfte Warnung.
- **Signatur-Scope-Isolation (Review 8, Kassandra):** Die Kohorten-Query MUSS strikt auf
  `scan_metadata["signature"] = cohort_key` filtern und darf keine Datei einer anderen Signatur
  einschließen, auch nicht bei gleichzeitig laufenden Bulk-Aktionen auf überlappenden Filtern.
  Negativtest: zwei Signaturen A und B im selben Zeitraum aktiv → Bulk-Override auf A darf keine
  B-Datei berühren, auch nicht wenn der Admin-Tabellenfilter zum Zeitpunkt der Aktion beide zeigt.
- **Pre-Commit-Preview = „Bulk-Confirm":** CSP-sicheres LiveView-Modal (Story 0) zeigt
  Signatur/Kohorten-Schlüssel, Count und Dateiliste; Deselektieren vor dem Commit möglich.
  Prävention vor Reversal — **kein** zeitboxed Toast-Undo (Append-only-Log ⇒ „Undo" =
  kompensierende Vorwärts-Transition: Bulk-Override rückgängig = Re-Block als `batch_id`-verknüpfte
  Normal-Aktion; Bulk-Delete ist als Soft-Delete bereits reversibel `:deleted → :released`).
- **Best-effort, kein All-or-Nothing:** Der Batch ist *nicht* atomar über alle Dateien. Jede Datei
  ist eine eigene guarded Transaktion; eine Legal-Hold-Datei (13e) oder concurrent geänderte Datei
  blockiert die übrigen nicht. Rückgabe `%{succeeded, skipped: [{id, reason}], failed: [{id, error}]}`.
- **Retry-Idempotenz bei Partial-Result (Review 8, Murat):** Ein erneuter Retry-Aufruf auf
  denselben `batch_id`-Batch darf nur die zuvor unter `failed` gelandeten Items erneut anfassen —
  bereits `succeeded`- oder `skipped`-Items sind No-Op (kein doppelter Transition-Eintrag, kein
  doppelter Audit-Log-Eintrag). Der Retry-Aufruf referenziert dieselbe `batch_id`.
- **Partial-Result-Feedback-State:** Die UI rendert das strukturierte Ergebnis als eigenen State
  (z.B. „38 freigegeben · 2 übersprungen (Legal-Hold) · 0 Fehler") — neben empty/loading/error/live
  (Story 0). Legal-Hold-Dateien werden übersprungen und ausgewiesen, nie mit-freigegeben.
- Alle Bulk-Actions im selben Commit in `AuditWriter.@known_actions` registrieren
  (`media_bulk_override` / `media_bulk_block` / `media_bulk_delete` / `media_bulk_rescan`, je
  `metadata: %{batch_id, cohort_key, reason, count}`).
- **Two-Eyes-Eskalation ab Schwelle (Review 8, entschieden — löst Offene Entscheidung #10):**
  Bulk-Override-Kohorten mit **weniger als 10 Dateien** bleiben Single-Actor (Rolle
  `media_admin_override` reicht), emittieren aber einen `critical`-Audit +
  `compliance_officer`-Notification (nicht blockierend, nie still). Kohorten **ab 10 Dateien**
  verlangen eine **Pflicht-Zweitfreigabe** (Quorum wie Story 13d: zwei unterschiedliche
  Principals, mind. einer `compliance_officer`), mit **Fast-Track**: Reaktionsfenster 15 Minuten
  ab Proposal, danach automatische Eskalation an einen zweiten `media_admin_override`-Träger
  bzw. den Compliance-Pool — kein unbegrenztes Warten während eines False-Positive-Sturms. Der
  Zweitfreigeber bekommt die **vollständige Dateiliste** angezeigt, nicht nur `cohort_key`/Count
  (sonst ist die Zweitfreigabe reines Vertrauen in dieselbe Signatur-Zuordnung, kein zweites
  Augenpaar). Begründung: ein einzelner (ggf. kompromittierter) `media_admin_override`-Account
  kann sonst in einer Aktion beliebig viele als Malware erkannte Dateien systemweit freigeben —
  Audit-Sichtbarkeit allein verhindert das nicht, sie dokumentiert es nur im Nachhinein.

**Abhängigkeiten:** 6a (Routine-Aktionen), 6c (Override-Semantik + `media_admin_override`-Rolle),
5a (Multi-Select in der Tabelle). **Intra-Split-Reihenfolge:** 4 von 4.

---

### Story 7 — Admin Notifications (Scan Failures & Infected)  ·  **S (unverändert)**

**Ziel:** Admins werden über kritische Media-Events informiert — in der UI und optional via Webhook.

**Akzeptanzkriterien:**

- Attention-Count-Badges im Admin-Nav (aus 5b) zeigen `:infected` (rot), `:scan_failed` (amber)
  mit explizitem Count.
- Neue PubSub-Events `{:media_infected, media_id}` und `{:media_scan_failed, media_id}` vom
  Scan-Worker; Admin-LiveView subscribed.
- Optionaler Webhook: `config :nebu, :media_alerts, webhook_url: "https://..."` — bei `:infected`
  und nach Scan-Failure-Exhaustion POST mit `{event, media_id, filename, uploader_id, timestamp}`.
- Webhook-Calls als Oban-Job (Fehler crashen nicht den Scan-Worker).
- Kein SMTP-Mail in diesem Epic.
- `webhook_url` ab Story 9b admin-konfigurierbar (mit Save-Time-Validierung); bis dahin statisch
  `config.exs`. Payload enthält `uploader_id` (im ADR als beabsichtigt festhalten).

**Abhängigkeiten:** 4c, 5b.

---

### Story 8 — Retention & Cleanup (Hard Delete)  ·  **XL → 8a / 8b / 8c / 8d**

**Fachliches Ziel:** Konfigurierbare Aufbewahrungsfristen pro State. Oban-Cron-Jobs führen
Hard-Delete/Archivierung nach Ablauf aus.

> Alle Retention-/Archiv-Werte sind über Story 9's `media_config` admin-konfigurierbar.

> **Review 5 (R-015 / ADR-030):** Die Einzel-Cron-Pakete 8a/8c/8d und die verstreuten
> `*_days`-Keys werden zur **Media-Lifecycle-Policy** (S3-Lifecycle-Analog) zusammengezogen —
> die drei Cron-Jobs werden von **einem** `MediaLifecycleWorker` (Story 13c) abgelöst, der die
> Ladder `active → archive → marked-deleted → deleted` aus der Policy fährt. Die `*_days`-Werte
> werden zu Sprossen der Policy (Migration mappt bestehende Keys). **Kein automatischer
> Hard-Delete mehr, wenn `two_eyes_delete_required` (Default in Compliance Mode) aktiv ist** —
> dann ist die terminale Löschung eine Vier-Augen-Aktion (Story 13d). 8a/8c/8d bleiben hier als
> fachliche AK-Referenz stehen; ihre Realisierung erfolgt über Story 13. `infected_days` und
> `orphaned_hours` bleiben Kohorten-Regeln derselben Engine.

#### Story 8a — `MediaCleanupWorker` Hard-Delete-Cron  ·  **S**

**Scope (Akzeptanzkriterien):**

- Config: `deleted_days` (Default 30), `infected_days` (Default 7).
- `Nebu.Workers.MediaCleanupWorker` als Oban-Cron (täglich 02:00 UTC): selektiert Files wo
  `deleted_at < NOW() - retention_interval` und `state IN (:deleted, :infected)`; löscht Bytes
  aus Storage, setzt `storage_key = NULL`, `hard_deleted_at = NOW()`, `state = :hard_deleted`,
  `uploader_id = NULL`; schreibt Transition in `media_state_transitions`.
- **Blob/DB-Konsistenzreihenfolge nach ADR-032 (Review 8):** Diese Story ist der erste Ort, an dem
  ein Delete-Pfad Postgres **und** S3 gemeinsam anfasst — die in ADR-032 (Persistenz-Konsistenz
  Postgres↔S3) festgelegte Reihenfolge/Retry-Strategie ist hier **normativ** umzusetzen, nicht neu
  zu erfinden. Jede weitere Story mit Delete/Archiv-Pfad (8c, 13c, 13d) folgt derselben Strategie.
- `media_state_transitions`-Einträge sind von der Löschung ausgenommen (bleiben permanent).
- Hard-Delete-Zähler + Bytes-Freigabe im Admin-Dashboard (Story 5a erweitern).
- Admin kann Hard-Delete für einzelne Files/Kohorten manuell triggern (aus Story 6a).

**Abhängigkeiten:** 1a, 1b, 4b (erzeugt `:infected`/`:deleted`-Population).
**Intra-Split-Reihenfolge:** 1 von 4.

#### Story 8b — Orphan-Detection + DSGVO Art. 17  ·  **S**

**Scope (Akzeptanzkriterien):**

- Config: `orphaned_hours` (Default 48).
- Orphan-Detection: `media_files` im State `:quarantined`, älter als `orphaned_hours`, deren
  `mxc_uri` in keiner `events.content`-Spalte vorkommt → `state = :deleted` (Soft-Delete zuerst,
  dann Hard-Delete via 8a nach `deleted_days`).
- Orphan-Query gegen `events` mit `content::jsonb @> '{"url": "mxc://..."}'` — GIN-Index auf
  `events.content` prüfen (ggf. eigene kleine Migration, vgl. Offene-Entscheidung #3).
- Der `:deleted`-Übergang der Orphan-Detection speist die „marked-deleted"-Sprosse der
  Lifecycle-Policy (Story 13) — der eigentliche Hard-Delete läuft über die Lifecycle-Engine.

> **Review 5-Korrektur:** Die frühere Behauptung „Löst Offene-Entscheidung #4 (DSGVO Art. 17)"
> war **falsch** und wurde entfernt. Orphan-Detection ist automatisches Housekeeping
> (unreferenzierte Files); Art. 17 ist ein *betroffenen-initiiertes* Recht mit Authz + Audit +
> Retention-Abwägung. Diese sind architektonisch verschieden und werden **nicht** von 8b
> abgedeckt. Art. 17 wird in **Story 13e** (Erasure-Request → Restriction-of-Processing) korrekt
> modelliert. Siehe ADR-030 und die neu gefasste Offene Entscheidung #4.

**Abhängigkeiten:** 1a, 1b (unabhängig von 8a; speist dessen `:deleted`-Kohorte, aber allein
testbar). **Intra-Split-Reihenfolge:** 2 von 4.

#### Story 8c — `MediaArchiveWorker` Archiv-Tier  ·  **S**

**Scope (Akzeptanzkriterien):** (Winston-Review 3)

- Config: `released_archive_after_days` (Default `nil` = deaktiviert) + `archive_delete_from_primary`
  (Boolean, Default `false`).
- `Nebu.Workers.MediaArchiveWorker` (Oban-Cron) kopiert `:released`-Objekte älter als N Tage per
  `ExAws.S3.put_object_copy/5` in den in Story 11b konfigurierten Archiv-Bucket — **serverseitige
  S3-Copy, kein Download/Entschlüsseln/Wieder-Verschlüsseln** (Bytes liegen bereits
  AES-256-GCM-verschlüsselt vor, Key/Nonce bleiben in der DB). Setzt `archived_at = NOW()`.
- State bleibt `:released` — Archivierung ist reiner Storage-Location-Wechsel, kein neuer State,
  kein anderer HTTP-Code. Der Download-Handler prüft `archived_at`: gesetzt → Archiv-Bucket, sonst
  primärer Bucket.
- Übergang schreibt `media_archived` in den globalen Audit-Log (Action registrieren).
- Archiv-Copy und Retention-Hard-Delete teilen sich den Cron-Rhythmus (02:00 UTC).

**Abhängigkeiten:** 8a (Cron-Infra), 11b (Archiv-Bucket muss konfiguriert sein), 1c
(Download-Handler-Bucket-Switch). **Intra-Split-Reihenfolge:** 3 von 4.

#### Story 8d — `released_delete_after_days` Auto-Delete  ·  **S**

**Scope (Akzeptanzkriterien):** (Winston-Review 3, löst Offene-Entscheidung #8)

- Config: `released_delete_after_days` (Default `nil` = deaktiviert).
- Hard-Delete für **noch nie beanstandete** `:released`-Anhänge nach Ablauf — Data-Minimization,
  kein Sicherheits-Feature. **Deutlich höheres Blast-Radius** als alle anderen Retention-Werte.
- Übergang schreibt `media_released_auto_deleted` in den globalen Audit-Log (Action registrieren).
- Die verschärfte Warnung beim Setzen von `nil` → konkreter Wert wird in der Settings-UI (9b)
  geliefert — dieses Teilpaket besitzt nur den Worker-Pfad.

**Abhängigkeiten:** 8a (erweitert den Hard-Delete-Cron-Pfad). **Intra-Split-Reihenfolge:** 4 von 4.

---

### Story 9 — Media Policy Settings (Admin-UI)  ·  **L → 9a / 9b / 9c**

**Fachliches Ziel:** Alle bisher in `config.exs` fixierten Policy-Werte werden zur Laufzeit
konfigurierbar, nach dem Muster der OIDC-Konfiguration (ADR-022 „Bootstrap-Only",
`/admin/config` als Vorbild).

#### Story 9a — `media_config`-Tabelle + `Nebu.Media.Config`-Modul  ·  **S**

**Scope (Akzeptanzkriterien):**

- Neue Tabelle `media_config` (`key TEXT PRIMARY KEY, value TEXT NOT NULL, set_at BIGINT NOT NULL`)
  — dedizierte Tabelle, keine `server_config`-Erweiterung (siehe ADR-Kandidat).
- `Nebu.Media.Config`-Modul als Public-API (ADR-020): `get/0` (DB-Override, Fallback auf
  `config.exs`-Default), `upsert/1`. Einziger Write-Seam.
- Änderungen wirken ohne Neustart (DB-Read pro Aufruf oder ETS-Cache mit Invalidierung analog
  zum OIDC-Claim-Cache).
- **Cluster-weite Cache-Invalidierung explizit spezifiziert (Review 8, Winston/Kassandra):** Die
  ursprüngliche Formulierung „analog OIDC-Claim-Cache" war ungenau und wird präzisiert: der reale
  Vorgänger `Nebu.Web.OidcConfig` propagiert Änderungen bereits **nicht** per Phoenix.PubSub,
  sondern über Erlang `:pg`-Process-Groups (jeder Knoten joint eine `:pg`-Gruppe und broadcastet
  Invalidierungen an die übrigen Mitglieder) — **dieses bereits etablierte Muster ist zu
  übernehmen**, nicht neu zu erfinden. Zusätzlich zur `:pg`-Invalidierung: ein **TTL-Fallback**
  (max. Zeit, die ein Knoten nach verpasster Invalidierung — z.B. bei Netzpartition — eine
  veraltete Config-Einstellung noch verwenden darf; Default niedrig genug, dass das
  Blast-Radius-Fenster bei sicherheitsrelevanten Werten wie MIME-Denylist oder
  `media_admin_override`-Widerruf praktisch vernachlässigbar ist). Kein reines TTL ohne
  `:pg`-Broadcast — ein Wartefenster für die Policy-Wirkung ist bei sicherheitsrelevanten Werten
  ein bewusster Kompromiss, den ein einzelner Story-Autor nicht stillschweigend eingehen darf.
- Jeder geänderte Wert schreibt `media_config_updated` (`metadata: %{key, old_value, new_value}`);
  Action registrieren.

**Abhängigkeiten:** 1a (Audit-Log-Konventionen). **Intra-Split-Reihenfolge:** 1 von 3.

#### Story 9b — `/admin/media/settings` UI (Policy-Werte)  ·  **S**

**Scope (Akzeptanzkriterien):**

- Route `/admin/media/settings` (konsistent mit `/admin/config`), editiert mit
  server-seitiger Validierung (Unter-/Obergrenze, kein Negativwert):
  - `max_upload_size_bytes` (413-Grenze, Story 2b)
  - `max_file_size_bytes` (ClamAV-Scan-Grenze, Story 3 — mit Hinweistext „oberhalb ungescannt")
  - `max_pending_per_user` (429-Limit, Default 20)
  - `max_stall_ms` (Default 20000)
  - `deleted_days`, `infected_days`, `orphaned_hours` (Retention, Story 8a/8b)
  - `webhook_url` (Story 7 — mit Save-Time-Validierung wie SCIM-/OIDC-Directory: HTTPS-Pflicht,
    private/link-local IP-Ranges geblockt)
- **Verschärfte Warnung**, wenn `released_delete_after_days` (Story 8d) von `nil` auf einen
  konkreten Wert gesetzt wird.
- Env-Var-Vorbefüllung beim ersten Laden.

**Abhängigkeiten:** 9a. **Intra-Split-Reihenfolge:** 2 von 3.

#### Story 9c — `mime_denylist`-Enforcement  ·  **S**

**Scope (Akzeptanzkriterien):**

- `mime_denylist`-Config-Key (kommagetrennte MIME-Type-Präfixe), in 9b editierbar.
- Enforcement-Punkt: Upload-Handler lehnt passende Typen **vor** Persistierung ab, **zusätzlich**
  zum ClamAV-Scan (nicht als Ersatz). UI-Labelling, dass es eine Zusatz-Policy ist.

**Abhängigkeiten:** 9a, 9b, 2b (Upload-Handler). **Intra-Split-Reihenfolge:** 3 von 3.

---

### Story 10 — Scan Health & Alerts Dashboard  ·  **XL → 10a / 10b / 10c / 10d**

**Fachliches Ziel:** Aggregierte Metriken über die Scan-Pipeline und eine Alert-Historie für
operative Zustände im Admin-Dashboard.

#### Story 10a — `media_scan_stats`-Rollup + Metriken-Sektion  ·  **S**

**Scope (Akzeptanzkriterien):**

- Neue Tabelle `media_scan_stats` (stündliche Rollups); periodischer Oban-Cron aggregiert aus
  `media_state_transitions`:
  - Scan-Durchsatz (Scans/Stunde, rollierend 24h)
  - Ø-Scan-Dauer (`scanning`-Eintritt bis `released`/`infected`)
  - Backlog-Tiefe (`:quarantined` + `:scanning`)
  - Fehlerrate (`scan_failed`-Anteil, rollierend 24h/7d)
- Metriken-Sektion auf `/admin/media` (oder eigene Route `/admin/media/health`), liest die
  Rollup-Tabelle (kein Live-Query über die volle Historie).

**Abhängigkeiten:** 1a, 4b (Transition-Daten). **Intra-Split-Reihenfolge:** 1 von 4.

#### Story 10b — ClamAV-Status + Freshclam-Alter  ·  **S**

**Scope (Akzeptanzkriterien):**

- ClamAV-Verbindungsstatus im Dashboard (up/down + „down seit") aus dem Health-Check/Auto-Reconnect
  von Story 3, via PubSub oder periodischem Poll.
- Freshclam-/Signatur-Alter sichtbar (Zeitstempel der letzten Signatur-Aktualisierung, z.B. via
  `VERSION`-Kommando im INSTREAM-Protokoll oder Container-Healthcheck).

**Abhängigkeiten:** 3, 10a (Dashboard-Oberfläche). **Intra-Split-Reihenfolge:** 2 von 4.

#### Story 10c — `media_alerts`-Tabelle + Trigger + Auto-Resolve  ·  **S**

**Scope (Akzeptanzkriterien):**

- Neue Tabelle `media_alerts`: `(id, severity ENUM(warning|critical), message, media_id FK
  nullable, resolved_at TIMESTAMPTZ nullable, inserted_at)`. `media_id` nullable (Pipeline-Alerts
  ohne Einzeldatei-Bezug).
- Ungelöste Alerts (`resolved_at IS NULL`) oben im Dashboard; Auto-Resolve wenn Zustand behoben.
- Trigger (Schwellwerte über `media_config`, Defaults im ADR): ClamAV nicht erreichbar > 5 min →
  `critical`; Backlog-Tiefe > Schwellwert (Default 500) → `warning`; Scan-Fehlerrate > Schwellwert
  (Default 10 % über 1h) → `warning`.
- Additiv zu den Nav-Badges aus Story 5b/7.

**Abhängigkeiten:** 10a, 10b (ClamAV-Down-Signal), 9a (konfigurierbare Schwellwerte).
**Intra-Split-Reihenfolge:** 3 von 4.

#### Story 10d — Kill-Switch (fail-open / fail-closed)  ·  **S**

**Scope (Akzeptanzkriterien):**

- `media_config`-Modus: `fail_open` (Default: Uploads werden angenommen und stauen sich in
  `:quarantined`, bis ClamAV wieder da ist) vs. `fail_closed` (`PUT .../upload` liefert `503` +
  passenden Errcode, solange der ClamAV-Health-Check „down" meldet).
- Modus-Wechsel ist ein `media_config_updated`-Audit-Eintrag (Story 9a).

**Abhängigkeiten:** 9a (Config), 2b (PUT-Handler), 10b (ClamAV-Health-Signal).
**Intra-Split-Reihenfolge:** 4 von 4.

#### Story 10e — Trace-Map- & War-Room-Integration der Scan-Pipeline  ·  **S**  (Review 9, neu)

**Fachliches Ziel:** Die Scan-Pipeline nutzt das bereits gemergte Enhanced-Logging-Fundament
(`Nebu.Web.LogStore`, `Nebu.Admin.LogsLive.TraceMap`, `Nebu.Admin.WarRoomManager`) für operative
Sichtbarkeit, statt eine eigene Pipeline-Log-Visualisierung zu bauen. Ergänzt, ersetzt **nicht**,
die fachlichen Rollups/Alerts aus 10a/10c.

**Scope (Akzeptanzkriterien):**

- ClamAV-GenServer (Story 3, Connect/Disconnect/Health-Check) und `MediaScanWorker` (Story 4b,
  Scan-Start/-Ergebnis/-Fehler) loggen diese Ereignisse über die **normalen** `Logger.*`-Aufrufe
  mit einem synthetischen `route_template` (kein echter HTTP-Pfad, z.B. `media.clamav`/
  `media.scan_worker`) statt Ad-hoc-`IO.puts`/reinen Oban-Metadaten. Ohne weitere Arbeit erscheinen
  diese Events dadurch als eigene Domain-Gruppe in der Trace-Map (`TraceMapTree.domain_for_endpoint/1`
  gruppiert bereits nach Präfix — die Media-Domain reiht sich neben `/_matrix/client`, `/admin`,
  `/health` ein).
- **Redaction unverändert (keine neue Ausnahme):** diese Logs durchlaufen dieselbe
  `RequestLogger.PayloadRedactor`-Pipeline wie jeder andere `Logger`-Call — Dateiname/Uploader-ID
  landen (falls überhaupt) nur in `metadata`, nie im redigierten `message`-Feld. Kein neuer
  Leck-Pfad, kein Sonderpfad um die bestehende Redaction-LAW.
- **War-Room-Sprung aus dem Incident heraus:** ein ungelöster `critical`-Eintrag in `media_alerts`
  (Story 10c, z.B. „ClamAV nicht erreichbar > 5 min") zeigt auf `/admin/media/health` eine Aktion
  „Live-Diagnose starten", die eine `Nebu.Admin.WarRoomManager.start_session/1`-Session mit
  `scope` = Media-Domain-Routes vorbelegt öffnet (Operator kann Budget/Dauer noch anpassen, gleiche
  Grenzen wie überall: `max_entries` 10–10.000, `max_duration_s` 10–3.600). Der Operator sieht damit
  in Echtzeit die rohen (redigierten) Scan-Pipeline-Log-Zeilen, nicht nur die stündliche
  `media_scan_stats`-Rollup-Zahl — bounded und selbst-terminierend wie jede andere War-Room-Session.
- **Abgrenzung explizit (Analogon zu ADR-028/ADR-020):** `media_scan_stats` (stündliche Rollups)
  und `media_alerts` (fachliche, `media_id`-verknüpfte Business-Alerts mit `resolved_at`) bleiben
  **eigene** Tabellen — der generische, mutable/pruneable `operational_logs`-Store ersetzt sie
  nicht, genauso wenig wie `operational_logs` den compliance-relevanten, unveränderlichen
  `audit_log` ersetzt. Diese Story verdrahtet nur **Sichtbarkeit** (Trace-Map-Domain-Gruppe +
  War-Room-Sprung), keine neue Datenhaltung, keine Verschiebung bestehender ACs aus 10a/10c.

**Abhängigkeiten:** 10a, 10c (Alert-Quelle für den War-Room-Sprung), 4b, 3 (Log-Emission-Punkte),
sowie — außerhalb dieses Epics — die bereits gemergte Enhanced-Logging-Infrastruktur
(`Nebu.Web.LogStore`, `Nebu.Admin.WarRoomManager`, `Nebu.Admin.LogsLive.TraceMap`).
**Intra-Split-Reihenfolge:** 5 von 5.

---

### Story 11 — Object Storage Target Configuration (Admin-UI)  ·  **L → 11a / 11b / 11c**

**Fachliches Ziel:** Das S3/MinIO-Ziel (Endpoint, Bucket, Credentials, Key-Schema) wird über die
Admin-UI konfigurierbar, nach dem Bootstrap-Prinzip wie OIDC (ADR-022). Ersetzt schrittweise die
Env-Vars `NEBU_MINIO_*` / `NEBU_S3_REGION`.

#### Story 11a — Storage-Config-Schema + Secret-verschlüsselte Persistenz  ·  **S**

**Scope (Akzeptanzkriterien):**

- Felder (`media_storage_config`-Tabelle oder `media_config`-Erweiterung): `endpoint`, `bucket`,
  `region`, `use_ssl`, `access_key`, `secret_key`, `s3_key_prefix_template`, `archive_bucket`
  (gleiches Endpoint/Credentials, eigener Bucket-Name; kein separates Archiv-Endpoint — YAGNI).
- **Secret-Felder (`access_key`, `secret_key`)** mit demselben Feld-Verschlüsselungs-Tier wie
  andere Secrets (z.B. `email_encrypted`-Tier) — **nicht** als Klartext-`TEXT`. Vor Implementierung
  das existierende Verschlüsselungs-Modul identifizieren und wiederverwenden (Offene-Entscheidung #9).
- Env-Var-Fallback (`NEBU_MINIO_*`) bleibt erhalten.
- Änderungen schreiben `media_storage_config_updated` in den globalen Audit-Log **ohne** die
  Secret-Werte (nur welche Keys geändert wurden). Action registrieren.

**Abhängigkeiten:** 1a, 9a (Settings-Infra/Muster). **Intra-Split-Reihenfolge:** 1 von 3.

#### Story 11b — Storage-UI: Test Connection + Warnungen  ·  **S**

**Scope (Akzeptanzkriterien):**

- Storage-Ziel-Editier-Oberfläche unter `/admin/media/settings`.
- **„Test Connection"-Aktion** vor dem Speichern: `ExAws.S3.head_bucket/1` gegen die eingegebenen
  Werte, Erfolg/Fehler wird **vor** dem Speichern angezeigt.
- **Warnhinweis beim Ändern von Endpoint/Bucket, wenn bereits Media existiert:** „N bestehende
  Dateien … nicht mehr erreichbar …" (Anzahl aus `COUNT(*) FROM media_files WHERE storage_key IS
  NOT NULL`). Kein automatischer Blockierer, aber kein stiller One-Field-Edit.
- Env-Var-Vorbefüllung (read-once) beim ersten Laden (Migrationspfad, analog OIDC-Bootstrap).

**Abhängigkeiten:** 11a, 9b (Settings-Seite). **Intra-Split-Reihenfolge:** 2 von 3.

#### Story 11c — `s3_key_prefix_template` Upload-Zeit-Key-Berechnung  ·  **S**

**Scope (Akzeptanzkriterien):**

- Template-Engine: Platzhalter `{media_id}` (Pflicht, muss vorkommen — Eindeutigkeit),
  `{year}`/`{month}`/`{day}` (Upload-Datum, UTC). **Kein `{room_id}`** (`media_files` hat keine
  `room_id`-Spalte).
- Key wird **einmalig zur Upload-Zeit** aus dem dann aktiven Template berechnet und in
  `media_files.storage_key` persistiert — **nicht** bei jedem Read neu berechnet. Template-Wechsel
  wirkt nur auf neue Uploads; bestehende Objekte bleiben unter ihrem Key auffindbar.

**Abhängigkeiten:** 11a, 2b (Upload-Pfad, der den Key berechnet/persistiert).
**Intra-Split-Reihenfolge:** 3 von 3.

---

### Story 12 — Gzip Compression at Rest  ·  **S (unverändert)**

**Ziel:** Gespeicherte Bytes werden vor der Verschlüsselung komprimiert, um Storage-Kosten zu
senken, ohne die Verschlüsselungs-Pipeline zu verändern.

> **Ehrliche Erwartungssteuerung** (Winston-Review 3): Die meisten Chat-Anhänge sind bereits
> komprimierte Formate (Fotos/Videos/PDFs) — Gzip bringt dort ~null. Der Nutzen liegt bei
> Text-/Log-/unkomprimierten Office-Dateien. Die Store-smaller-of-two-AC verhindert, dass
> inkompressible Dateien CPU kosten oder größer werden.

**Akzeptanzkriterien:**

- Kompression via `:zlib.gzip/1` (OTP-Standardbibliothek, keine neue Dependency — ADR-021).
- Reihenfolge im Upload-Pfad (beide Endpoints, gemeinsame Implementierung in
  `Nebu.Media.Storage`, kein Duplikat): Original-Bytes → SHA-256 (auf Original) → `:zlib.gzip/1` →
  Größenvergleich → **kleinere** Variante wird verschlüsselt und gespeichert:
  - Komprimiert kleiner → speichern, `media_files.compressed = true`.
  - Komprimiert ≥ Original → Original unverändert speichern, `compressed = false`.
- Download-/Scan-Pfad: nach Entschlüsselung `if compressed, do: :zlib.gunzip/1` (No-Op-Pfad für
  die Mehrheit bleibt schnell).
- Kein Kompressions-Level-Tuning (Default-Level reicht, YAGNI).
- Unit-Test mit mindestens einer inkompressiblen und einer hochkompressiblen Testdatei (beide
  Zweige des Größenvergleichs).

**Hinweise:** Kompression läuft vor dem Scan im Sinne der Speicherung, aber der Scan bekommt
immer die dekomprimierten Original-Bytes (Story 4b) — ClamAV scannt nie das Gzip-Blob. Kein
Bezug zu CRIME/BREACH (kein Live-Response-Oracle).

**Abhängigkeiten:** 1a (Spalte `compressed`), berührt 2b/3/4b (s. dortige Korrekturen).

---

### Story 13 — Media Lifecycle Policy & Two-Eyes Delete  ·  **L → 13a / 13b / 13c / 13d / 13e / 13f**  (Review 5, R-015)

**Fachliches Ziel:** Die verstreuten Retention-/Archiv-Knöpfe (Story 8a/8c/8d/8b, 9b) werden zu
**einer** admin-konfigurierbaren **Media-Lifecycle-Policy** (S3-Lifecycle-Analog) zusammengeführt,
ergänzt um **Two-Eyes-Delete** (S3-MFA-Delete-Analog) und **Legal-Hold**. Damit wird **R-015
(DSGVO Art. 17, Test-Design Score 9)** geschlossen: der Betreiber legt — nach seinen eigenen
rechtlichen Gründen — die Übergänge `active → archive → marked-deleted → deleted` fest (ob, nach
wie vielen Tagen), und erzwingt optional, dass die physische Löschung nur im Vier-Augen-Prinzip
erfolgt. Art. 17 wird als *Restriction-of-Processing (sofort unsichtbar, Bytes erhalten) +
Vier-Augen-Freigabe* modelliert, **nicht** als User-Delete. Grundlage: **ADR-030**.

> **Rechtlicher Rahmen:** Nebu liefert den *Mechanismus*, der Betreiber setzt die *Policy*. Die
> statutarische Basis (Art. 17(3) Ausnahmen vs. Art. 18 Restriction; HGB §257 / AO §147) ist vor
> Go-live durch DSB/Rechtsanwalt zu bestätigen (gleiches Legal-Review-Gate wie ADR-007/011).

#### Story 13a — `Nebu.Media.Lifecycle` Policy-Modell + Schema  ·  **S**

**Scope (Akzeptanzkriterien):**

- Policy als **scoped Dokument** (`scope`: `global` | `space:<id>` | `room:<id>`) in
  `media_lifecycle_policy`-Tabelle; Public-API `Nebu.Media.Lifecycle` (ADR-020): `get_policy/1`,
  `upsert_policy/2`, `effective_for_room/1`, `evaluate/1`. Feld-Level-Cascade
  `global ⊕ space ⊕ room` (Room höchste, Global niedrigste Priorität); Global ist Basis + Default.
- **Fixe Ladder** (kein allgemeiner Regel-DSL — YAGNI, nur S3's *Form*), je Sprosse
  `{enabled: bool, after_days: int}`:
  - `archive` → `:released` → `:released` + `archived_at` (ersetzt 8c `released_archive_after_days`)
  - `mark_deleted` → `:released`/archiviert → `:deleted` (unsichtbar, Bytes erhalten; ersetzt 8d)
  - `delete` → `:deleted` → `:hard_deleted` (ersetzt 8a `deleted_days`)
- **Kohorten-Regeln** derselben Engine (nicht Teil der aktiven Ladder): `infected_delete_after_days`
  (`:infected → :hard_deleted`, war 8a `infected_days`), `orphan_mark_after_hours`
  (Orphan-`:quarantined → :deleted`, war 8b `orphaned_hours`).
- `two_eyes_delete_required: bool` (Default **true** in Compliance Mode, ADR-023; false in Normal Mode).
- Server-seitige Validierung: `after_days ≥ 0`, monotone Ladder (archive ≤ mark_deleted ≤ delete
  wenn alle aktiv), keine widersprüchlichen Sprossen.
- **Migration** mappt bestehende `*_days`-Keys aus Story 9 auf die Policy-Sprossen (verlustfrei).
- Jede Policy-Änderung schreibt `media_lifecycle_policy_updated` (`metadata: %{diff}`); Action registrieren.

**Abhängigkeiten:** 9a (Config-Infra), 1b (StateMachine). **Intra-Split-Reihenfolge:** 1 von 5.

#### Story 13b — Lifecycle-Rules-UI (S3-Style Ladder-Editor)  ·  **S**

**Scope (Akzeptanzkriterien):**

- Sektion unter `/admin/media/settings`: Ladder-Editor (je Sprosse Enable-Toggle + Tage), analog
  zur AWS-S3-Lifecycle-UX; Kohorten-Regeln; `two_eyes_delete_required`-Toggle.
- **Verschärfte Warnung** beim Aktivieren einer destruktiven Sprosse (`mark_deleted`, `delete`)
  oder beim **Deaktivieren** von `two_eyes_delete_required` (höchster Blast-Radius).
- **Policy-Change-Schutz:** ist `two_eyes_delete_required` aktiv, verlangt das Speichern der
  Policy selbst eine Vier-Augen-Bestätigung (S3-MFA-Delete gilt auch für Policy-/Versioning-Änderung).
- Env-Var-/Default-Vorbefüllung beim ersten Laden (Migrationspfad wie OIDC-Bootstrap).

**Abhängigkeiten:** 13a, 9b (Settings-Seite). **Intra-Split-Reihenfolge:** 2 von 5.

#### Story 13c — `MediaLifecycleWorker` (Engine, ersetzt 8a/8c/8d-Crons)  ·  **S**

**Scope (Akzeptanzkriterien):**

- Ein `Nebu.Workers.MediaLifecycleWorker` (Oban-Cron, 02:00 UTC) evaluiert die Policy und fährt
  die Ladder + Kohorten-Regeln — konsolidiert die drei Einzel-Crons aus 8a/8c/8d.
- Archiv-Copy per serverseitiger S3-Copy (wie 8c, kein Re-Encrypt); `archived_at` setzen.
- **Legal-Hold-Guard:** Files mit `legal_hold = true` werden von **jeder** automatischen Transition
  ausgenommen (kein `delete`, kein `infected`-Cohort-Delete, nichts).
- **Two-Eyes-Guard:** ist `two_eyes_delete_required` aktiv, führt der Worker **keinen**
  `:deleted → :hard_deleted`-Schritt aus — er markiert Files höchstens als *eligible*; die
  terminale Löschung ist Story 13d vorbehalten.
- **Cron/Legal-Hold-Race abgedeckt (Review 8, Murat):** Der Worker liest `legal_hold` **innerhalb
  derselben Transaktion**, in der er die Transition schreibt (kein Read-Then-Act über zwei
  Schritte hinweg) — ein Legal-Hold, der zwischen Batch-Selektion und Transition gesetzt wird,
  darf die Datei nicht mehr erfassen; ein Legal-Hold, der während des laufenden Batches
  aufgehoben wird, wirkt erst im **nächsten** Cron-Tick, nie rückwirkend auf den laufenden. Eigener
  Testfall, **nicht** Wiederverwendung der alten Orphan-Query-Race-Szenarien (andere
  Guard-Bedingung: dort Referenzierung, hier ein explizit gesetztes Flag).
- Jeder Übergang schreibt `media_state_transitions` (actor_type: :system).

**Abhängigkeiten:** 13a, 8a (Cron-Infra/Hard-Delete-Feldsemantik), 8c (Archiv-Bucket), 1c
(Download-Bucket-Switch). **Intra-Split-Reihenfolge:** 3 von 5.

#### Story 13d — Two-Eyes-Delete: Vier-Augen-Freigabe + `compliance_officer`-Rolle  ·  **S**

**Scope (Akzeptanzkriterien):**

- Neue Rolle `compliance_officer` (getrennt von der normalen Admin-Rolle **und** von
  `media_admin_override` aus Story 6c).
- Dual-Control-Mechanismus **proposed → confirmed** (Pending-Fenster) für die physische Löschung
  eines Files/einer Kohorte, wenn `two_eyes_delete_required` aktiv ist.
- **Quorum-Regel:** zwei **unterschiedliche** Principals, davon **mindestens einer
  `compliance_officer`**. Admin + Compliance ✅, 2× Compliance ✅, **2× Admin ❌**, derselbe Actor
  zweimal ❌.
- Erst nach Confirm: `:deleted → :hard_deleted` (bzw. Freigabe eines Legal-Hold-Files). Beide
  Actor-IDs landen in `media_state_transitions.metadata` **und** im globalen Audit-Log
  (`media_deletion_proposed` / `media_deletion_confirmed` — Actions registrieren).
- Negativ-Tests: einzelner Admin kann nicht löschen; zwei Admins ohne Compliance können nicht löschen.
- **Quorum-Timeout/Verfallssemantik (Review 8, Murat):** Ein `proposed`-Eintrag verfällt nach einer
  konfigurierbaren Frist (Default 72h) automatisch zurück in den vorherigen Zustand (kein
  ewig gültiges Pending-Fenster). Verliert der zweite Principal seine `compliance_officer`-Rolle
  **nach** Proposal aber **vor** Confirm, ist das Confirm ungültig (Quorum wird zum
  Confirm-Zeitpunkt erneut geprüft, nicht nur zum Proposal-Zeitpunkt) — Downgrade-Race
  ausgeschlossen. Self-Approval-Bypass ist als expliziter Negativtest zu führen: derselbe Actor
  kann nicht via zwei unterschiedliche Sessions/Requests beide Eyes für sich selbst erfüllen.
  Race-Test: zwei Confirms treffen quasi gleichzeitig ein — genau ein Confirm gewinnt, der zweite
  erhält einen Konflikt-Fehler, kein Doppel-Delete.
- **Approvals-State-Shape vor UI-Umsetzung fixieren (Review 8, Sati-Abhängigkeit):** Die
  Freigabe-Anfrage bekommt einen **eigenen** Lifecycle-Zustand (nicht nur ein Flag auf dem
  bestehenden Media-Record) — das ist Voraussetzung für die in Story 0/EXPERIENCE.md
  angenommene dedizierte Queue-UI (`/admin/media/approvals`, Master-Detail mit eigener Liste/
  Pagination). Diese Entscheidung war beim Schreiben von Story 0 noch offen ([ASSUMPTION]) und
  muss vor Beginn der 13d-Implementierung bestätigt sein, sonst baut die UI gegen eine geratene
  Datenstruktur.

**Abhängigkeiten:** 13a, 13c (liefert eligible-Files), 6a (Delete-Aktion, die nun durch das Gate läuft).
**Intra-Split-Reihenfolge:** 4 von 5.

#### Story 13e — DSGVO Art. 17 Erasure-Request → Restriction-of-Processing  ·  **S**  (löst R-015)

**Scope (Akzeptanzkriterien):**

- Admin-seitig erfassbarer **Erasure-Request** für ein Medium (Nebu hat keine self-service
  destruktive User-Aktion; konsistent mit admin-getriebenem `deactivate_user`).
- Wirkung **sofort**: Transition in die marked-deleted-Lane (`:deleted`, unsichtbar → 404) **und**
  `legal_hold = true`, `erasure_requested_at`/`erasure_requested_by` gesetzt — **aus jedem
  Scan-State** (`:quarantined`/`:scanning`/`:infected`/`:released`). Bytes bleiben erhalten.
- Ein Legal-Hold-File verlässt den Hold **nur** über die Two-Eyes-Freigabe (Story 13d) —
  StateMachine-Guard, kein einzelner Admin kann es un-holden oder löschen.
- Audit: `media_erasure_requested` (`metadata: %{requested_by, prior_state}`). Action registrieren.
- **Kein zeitbasiertes Auto-Release des Legal-Hold** (Retention ist fallabhängig — ADR-030).
  Optionaler informativer `legal_hold_until`-Timestamp, der aber nie eine Löschung auslöst.
- **Test `MEDIA.8-INT-001` (neu gefasst):** „Erasure-Request auf ein `:quarantined`-File →
  sofort unsichtbar + `legal_hold`, **nicht** physisch gelöscht; Lifecycle-/Retention-Crons lassen
  es unberührt; Freigabe nur im Vier-Augen-Prinzip."
- **Data-Subject-Benachrichtigung (Review 8, offen — siehe Offene Entscheidung #12):** Ob und wie
  der Uploader/Data Subject über einen Erasure-Request informiert wird, ist **noch nicht
  entschieden** und deshalb bewusst **nicht** Teil dieser AC-Liste. Sobald #12 entschieden ist,
  muss diese Story um eine AC ergänzt werden, die festlegt, ob die Benachrichtigung **Teil des
  synchronen Erasure-Workflows** ist (dann: Zustellfehler blockiert die Transition nicht, aber
  muss selbst auditierbar sein) oder ein **entkoppelter Fire-and-Forget-Call** (dann: ein
  Audit-Eintrag muss den Versand-Status — versucht/zugestellt/fehlgeschlagen — festhalten, sonst
  entsteht eine Lücke zwischen „wir haben benachrichtigt" und „wir können das nachweisen").

**Abhängigkeiten:** 13a, 13d (Freigabe-Gate), 1b/1c (Guards + Download-Gate). **Intra-Split-Reihenfolge:** 5 von 6.

#### Story 13f — Policy-Resolution: mxc→Raum-Index + Space-Cascade  ·  **S**  (Oracle-Consult 2026-07-02)

**Scope (Akzeptanzkriterien):**

- **mxc→Raum-Index**, gepflegt beim Event-Insert, über **alle sechs** mxc-tragenden Felder:
  `content.url` + `content.info.thumbnail_url` (`m.room.message` image/file/audio/video, `m.sticker`,
  `m.room.avatar`), `content.avatar_url` (`m.room.member`), sowie verschlüsselt `content.file.url` +
  `content.info.thumbnail_file.url`. **Kein** Ad-hoc-`@>`-Scan zur Laufzeit (übersieht still ein Feld).
  Dies ist die Materialisierung der reservierten Schnittstelle aus dem ADR „Compliance-Sichtbarkeit".
- **Raum→Space-Auflösung:** `m.space.child` (State im Space-Room) ist der Trust-Anchor;
  `m.space.parent` nur gültig, wenn passendes `m.space.child` existiert **oder** der Sender PL für
  `m.space.child` im Space hat. Multi-Parent erlaubt; Loop-/Tiefen-Guard; Link ist **dynamisch**.
- **`effective_for_room/1`** wendet die Cascade `global ⊕ space ⊕ room` an; **`effective_for_media/1`**
  bildet über alle referenzierenden Räume die **konservativste** Policy (most-conservative-wins);
  medienlos referenziert → `global`. Auflösung zur **Cron-Evaluationszeit** (Story 13c), nicht pro Download.
- **⚠️ Compliance-Mode-Grenze (ADR-030/Oracle):** in E2EE-Räumen ist `content` Megolm-Chiffrat →
  kein Raum→Medien-Join möglich → **Fallback auf `global`**. Per-Raum/Space-Policy gilt nur bei
  server-lesbarem Content (Compliance Mode, ADR-011/023). Test: E2EE-Raum → global, nie Fehler.
- **Klarstellung „E2EE-Fallback" (Review 8, Murat):** Der Fallback auf `global` ist ein reiner
  **Policy-Resolution-Fallback** — es findet **kein** Zugriff auf, keine Ableitung aus und keine
  Umgehung von Megolm-verschlüsseltem Content statt. Der Server kann in E2EE-Räumen schlicht
  nicht feststellen, welche Policy-Scope (Space/Room) für ein Medium gilt, und wendet deshalb die
  konservativste bekannte Policy (global) an. Das ist **kein** Datenschutz-Downgrade, sondern die
  Abwesenheit einer Fähigkeit, die es in Compliance Mode ohnehin nicht geben darf (ADR-011). Diese
  Klarstellung muss wörtlich in Code-Kommentar/Modul-Doku von `effective_for_media/1` übernommen
  werden, damit sie bei einer künftigen Prüfung nicht erneut als Risiko missverstanden wird.

**Abhängigkeiten:** 13a, 13c (Consumer der Resolution), 1a (events-Join). **Intra-Split-Reihenfolge:** 6 von 6.

---

## ADR-Kandidaten

**Review 8 — nummeriert und abgelegt.** Die sechs Kandidaten unten sind als **ADR-024 bis
ADR-029** in `docs/architecture/adr/` angelegt (Inhalte unverändert gegenüber den ursprünglichen
Kandidaten hier, nur formalisiert). Vier davon sollten vor Story 1a stehen, zwei (ADR 5/6 = 028/029)
vor den jeweils betroffenen Stories:

**ADR-024: Malware-Scanner-Auswahl** — Entscheidung: ClamAV via clamd TCP. Begründung:
self-hosted, DSGVO-konform, LGPL, reine TCP-Integration (`:gen_tcp`). Alternativen bewertet:
OPSWAT MetaDefender (proprietär/Cloud), VirusTotal (Cloud, DSGVO-Blocker), eigene Signatur-DB
(nicht realistisch).

**ADR-025: Async-Scan-Queue (Oban vs. GenServer-Queue)** — Entscheidung: Oban. Begründung:
Persistenz über Node-Restarts, exponential Backoff, Dead-Letter-Queue, Oban-Web-Monitoring.
Alternative: purer GenServer-Queue (verliert Jobs bei Restart, kein Monitoring).

**ADR-026: HTTP-Statuscodes für nicht-verfügbare Media** — Empfehlung:

| State | HTTP Code | Begründung |
|---|---|---|
| `:quarantined`, `:scanning`, `:scan_failed` | 451 + `M_NOT_YET_UPLOADED` | Temporär, MSC2246-kompatibel |
| `:infected` | 404 + `M_NOT_FOUND` | Privacy: kein Informationsleck |
| `:admin_blocked` | 451 + `M_NOT_FOUND` | Aktive Policy-Entscheidung |
| `:deleted`, `:hard_deleted` | 404 + `M_NOT_FOUND` | Standard-Semantik |

Abweichung von 451 für `:admin_blocked` → 404 akzeptabel wenn Anonymität priorisiert wird.

**ADR-027: Admin-Configurable Media Policy via `media_config` (Story 9)** — Entscheidung: neue
Tabelle `media_config`, gleiches Muster wie `server_config` (ADR-022), statt Erweiterung der
bestehenden Tabelle um media-fremde Keys. Begründung: klare Verantwortlichkeit (ADR-020),
vermeidet media-fremde Cache-Invalidierung. Konsequenz: die Erstfassungs-Entscheidung „`webhook_url`
Ops-only" (Story 7) wird revidiert (Story 9b).

**ADR-028: Compliance-Sichtbarkeit von Scan-Events (Audit-Log-Bridge)** — Entscheidung:
System-getriebene Scan-Ereignisse mit Compliance-Relevanz (`:infected`, `scan_failed`) und alle
Admin-Aktionen (Story 6, inkl. Override) schreiben **zusätzlich** zu `media_state_transitions`
einen Eintrag in den globalen `audit_log`. Routine-Transitionen bleiben ausschließlich in
`media_state_transitions`. **Bewusst nicht gelöster Anschluss-Punkt:** `media_files` hat keine
`room_id`-Spalte; ein „Compliance-Report pro Raum" braucht einen Query-Zeit-Join
`audit_log.target_id (= media_id)` → `events.content @> '{"url": "mxc://..."}'`. Diese ADR legt das
als Schnittstellenvertrag für eine spätere Compliance-Export-Story fest (reservierte Audit-Action
`compliance_export_downloaded`). **Batch-Kohorten-Vertrag (Review 7, Story 6d):** Bulk-Aktionen
erfassen die Begründung *einmal*, schreiben aber **per-Datei** `audit_log`-Einträge (kein
Sammel-Eintrag), jeweils gestempelt mit einer geteilten `batch_id` — die *Entscheidung* ist einmal
erfasst, der *Effekt* bleibt per-Datei (und damit per-Raum über den obigen Join) auffindbar. Eine
Datei darf nie aus dem per-Raum-Report verschwinden, nur weil sie Teil eines Batches war.

**ADR-029: Storage-Key-Schema & Kompressions-Reihenfolge (Story 11/12)** — Entscheidung:
Objekt-Keys aus admin-konfigurierbarem Template (`{media_id}`/`{year}`/`{month}`/`{day}`, ohne
`{room_id}`), **zur Upload-Zeit einmalig** in `media_files.storage_key` persistiert. Kompression
(`:zlib.gzip/1`) läuft **vor** AES-256-GCM, mit Fallback auf Original wenn nicht kleiner. **Kein
neuer State für Archivierung** (Story 8c): `archived_at`-Timestamp + weiterhin `:released`.

**ADR-032: Persistenz-Konsistenz Postgres ↔ S3 (Review 8, Winston)** — Entscheidung: Bei jedem
Delete-Pfad, der Postgres-State und S3-Blob gemeinsam anfasst (8a, 8c, 13c, 13d), gilt eine
verbindliche Reihenfolge: **DB-State zuerst auf einen Zwischenzustand setzen (z.B.
`hard_deleted_at` gesetzt, `storage_key` noch vorhanden), dann Blob löschen, dann `storage_key
= NULL`.** Ein Crash zwischen Blob-Delete und dem finalen `storage_key = NULL` ist idempotent
reparierbar (ein Reaper-Job erkennt „Zwischenzustand älter als X" und vollendet den
`storage_key = NULL`-Schritt, ohne den — bereits gelöschten — Blob erneut anzufassen). Damit
entsteht im Worst Case eine verwaiste DB-Referenz auf einen bereits gelöschten Blob (harmlos,
vom Reaper behoben), nie ein Blob, der trotz „gelöscht" in der DB weiter existiert (das wäre die
schwerwiegendere Compliance-Verletzung). Löst das in D8 (UX-Decision-Log) angekündigte, bis
Review 8 nicht eingelöste Versprechen einer Persistenz-Konsistenz-ADR ein. **Volltext:**
`docs/architecture/adr/ADR-032-media-postgres-s3-consistency.md`.

**ADR-030: Media Lifecycle Rules & Two-Eyes Delete (Story 13, R-015)** — Entscheidung: die
verstreuten Retention-Knöpfe werden zu **einer** Lifecycle-Policy (S3-Lifecycle-Analog, fixe
Ladder `active → archive → marked-deleted → deleted`, kein allgemeiner DSL) konsolidiert, mit
`two_eyes_delete_required` (S3-MFA-Delete-Analog: Vier-Augen-Freigabe, ≥1 `compliance_officer`,
2× Admin unzureichend) und **Legal-Hold** (per-File-Pin für Art. 17 / Beweismittel). DSGVO Art. 17
= *Restriction-of-Processing (sofort unsichtbar, Bytes erhalten) + Vier-Augen-Freigabe*, **kein**
User-Delete. Kein neuer `media_state`-ENUM-Wert (marked-deleted = `:deleted`; Legal-Hold als
Attribut + Guard). Global/instanzweit (kein per-Raum — kein `room_id`). Manuelles Release only
(kein zeitbasiertes Auto-Release von Legal-Hold). **Erweitert in Review 8 (Kassandra-Blocker) um
einen Abschnitt „Restore-Verfahren":** nach jedem Backup/Restore MUSS ein automatischer
Reconciliation-Lauf alle Hard-Deletes mit `deleted_at`/`hard_deleted_at` nach dem
Snapshot-Zeitpunkt erneut durchsetzen und alle zum Snapshot-Zeitpunkt aktiven Legal-Holds, die im
wiederhergestellten Zustand als „aufgehoben" erscheinen, erneut setzen — **bevor** das System
wieder für Traffic freigegeben wird. Begründung: ein Restore auf einen älteren Snapshot kann sonst
eine bereits vollzogene, rechtlich zugesicherte Löschung rückgängig machen oder eine unter
Legal-Hold stehende Datei wieder löschbar machen (Beweismittelvernichtung mit
Systemunterstützung). **Volltext:** `docs/architecture/adr/ADR-030-media-lifecycle-rules-two-eyes-delete.md`.

**ADR-031: DB-Level Immutability für `media_state_transitions` (R-006)** — Entscheidung: Die
Append-only-Garantie der Transitions-Tabelle wird DB-seitig durchgesetzt, nicht nur per Grep. Primär
ein `BEFORE UPDATE OR DELETE`-Trigger, der wirft (SQLSTATE 23001, greift für jede Rolle inkl. Owner →
echte Postgres-Fehlermeldung auch im Single-Role-CI), sekundär RLS `USING(false)` + `REVOKE UPDATE,
DELETE FROM nebu_app` analog `audit_log`. Kein `SECURITY DEFINER`-Purge (append-only-forever;
Retention vertagt, Offene Entscheidung #5). Schließt das Loch, das `audit_log` im Single-Role bewusst
offen ließ. **Volltext:** `docs/architecture/adr/ADR-031-media-state-transitions-db-immutability.md`.

> **ADR-Zählung (Review 8, final):** ADR-024–029 (die sechs ursprünglichen Kandidaten) + ADR-030 +
> ADR-031 + **ADR-032** (neu, Persistenz-Konsistenz Postgres↔S3) = **neun** ADRs für dieses Epic.
> Alle neun sind als Dateien in `docs/architecture/adr/` angelegt oder erweitert (ADR-030 um den
> Restore-Verfahren-Abschnitt).

---

## Offene Entscheidungen

**1. Scanner-Override durch Admin (false positive) — GELÖST in Review 2, umgesetzt in Story 6c.**
Ja, aber nur über die separate `media_admin_override`-Rolle mit Pflicht-Begründung (in
`media_state_transitions` und globalem Audit-Log). Der `infected_days`-Grace-Zeitraum (Story 8a,
über 9b konfigurierbar) ist das Zeitfenster, in dem der Override praktisch relevant ist.

**2. Max-File-Size für ClamAV** — Default 100 MB, oberhalb auto-release mit
`scan_metadata: %{skipped: "size_limit"}`. Konfigurierbar (Story 9b), Default = auto-release mit
Audit-Log-Eintrag.

**3. Orphan-Erkennung via Events-Tabelle** — Query in Story 8b gegen `events.content` JSONB. Vor
Story 8b: Explain-Plan prüfen, ggf. GIN-Index als eigene Migration.

**4. DSGVO Art. 17 — Erasure-Request für eigene Media — GELÖST in Review 5 (R-015), umgesetzt in
Story 13e + ADR-030.** ~~adressiert in Story 8b~~ (falsch — Story 8b ist reine Orphan-Detection,
siehe Review-5-Korrektur dort). Für die Behörden-/Firmen-Zielgruppe bedeutet Art. 17 **nicht**
„User löscht", sondern **Restriction-of-Processing**: der Erasure-Request macht das File *sofort
unsichtbar* (`:deleted`, 404) und setzt **Legal-Hold** (Bytes erhalten, aus jedem Scan-State),
weil (a) das File Beweismittel krimineller Absicht sein kann und (b) es unter statutarischer
Aufbewahrungspflicht steht (Art. 17(3): HGB §257 / AO §147). Die *physische* Löschung erfolgt erst
compliance-frei und **nur im Vier-Augen-Prinzip** (Story 13d, `compliance_officer`). Kein
zeitbasiertes Auto-Release des Legal-Hold.

**5. Retention für `media_state_transitions`** — die Audit-Tabelle wächst unbegrenzt.
Archivierungs-Job (Rollup nach N Jahren) als Follow-on-Story vormerken, nicht in diesem Epic.

**6. Speicher-Quotas pro User/Raum — explizit NICHT in diesem Epic.** Setzt die Raum-Zuordnung aus
ADR „Compliance-Sichtbarkeit von Scan-Events" voraus; eigenständiger Story-Kandidat.

**7. Compliance-Report pro Chat/Raum — Datenbasis in diesem Epic, Report-UI nicht.** Malware-Funde
und Overrides landen im globalen Audit-Log und sind über den `events.content`-Join (Story 8b)
raumzuordenbar. Report-Generierung ist ein eigenes Epic (reservierte Action
`compliance_export_downloaded`).

**8. `released_delete_after_days` — Default aus, verschärfte Warnung — adressiert in Story 8d/9b,
in Review 5 in die Lifecycle-Policy (Story 13) überführt.** Wird zur `mark_deleted`/`delete`-Sprosse
der Lifecycle-Ladder; unterliegt bei aktivem `two_eyes_delete_required` der Vier-Augen-Freigabe
(Story 13d). Vor Aktivierung mit dem Betreiber klären. Default bleibt `nil`/deaktiviert.

**9. Secret-Verschlüsselungs-Tier für S3-Credentials — vor Story 11a zu klären.** Das existierende
Feld-Verschlüsselungs-Muster (analog `email_encrypted`) identifizieren und wiederverwenden.

**10. Two-Eyes-Eskalation bei Bulk-Override (Review 7) — GELÖST in Review 8 (Kassandra-Verdict),
umgesetzt in Story 6d.** Bulk-Override (Freigabe von N `:infected`-Dateien) hat höheren
Blast-Radius als ein Einzel-Override — insbesondere gegen den **kompromittierten** (nicht nur
unvorsichtigen) `media_admin_override`-Account, gegen den reine Post-hoc-Sichtbarkeit wirkungslos
ist. Winstons ursprüngliche Default-Empfehlung (b) (Single-Actor + Audit + Notification post-hoc)
wird **verworfen** — Kassandra: „ein Autopsiebericht ist keine Kontrolle". **Entschieden: Option
(c)** mit scharfer, niedriger Schwelle: Kohorten **< 10 Dateien** bleiben Single-Actor (mit
`critical`-Audit + `compliance_officer`-Notification); Kohorten **≥ 10 Dateien** verlangen
Pflicht-Zweitfreigabe (Quorum wie Story 13d) mit **Fast-Track** (15-Min-Reaktionsfenster, danach
automatische Eskalation an einen zweiten `media_admin_override`-Träger/Compliance-Pool) — der
Zweitfreigeber sieht die volle Dateiliste, nicht nur den Kohorten-Schlüssel. Details in Story 6d.

**11. (neu, Review 8) Backup/Restore vs. Hard-Delete & Legal-Hold.** Ein Restore auf einen
Snapshot vor einem Hard-Delete oder vor einem Legal-Hold-Set kann die jeweilige rechtliche
Garantie unterlaufen — Kassandras Blocker aus der Party-Runde. Erfordert eine
Post-Restore-Reconciliation-Pflicht (siehe ADR-030-Erweiterung „Restore-Verfahren"). **Offene
Vorfrage, vor Spezifikation zu klären:** werden Postgres und S3/MinIO getrennt gesichert
(unterschiedliches RPO/RTO)? Falls ja, verschärft sich das Problem (DB sagt „hard-deleted",
S3-Restore bringt den Blob zurück, oder umgekehrt) und die Reconciliation muss beide Fälle
getrennt behandeln. **Muss vor Dev-Start der betroffenen Stories (8a, 13c, 13d) geklärt sein.**

**12. (neu, Review 8) Data-Subject-Benachrichtigung.** Kompletter blinder Fleck im aktuellen
Epic-Scope: weder Story 0 (nur Admin-facing UX) noch die PRD-FRs 53–66 legen fest, ob/wie der
Uploader informiert wird, wenn seine Datei geblockt, gelöscht oder per Art.-17-Erasure-Request
unsichtbar gemacht wird. Muss vor Story 13e final entschieden werden: Pflicht ja/nein, Kanal
(vermutlich E-Mail, nicht Admin-UI), Detailgrad (Abwägung: Vertrauensbruch bei Stille vs.
Rechtfertigungsdruck/Scanner-Mechanismus-Leak bei zu viel Detail). Sobald entschieden, braucht es
eine eigene, kleine UX-Story (nicht Teil von Story 0 — andere Zielgruppe, anderer Kanal, eigene
Accessibility-Prüfung) und eine AC-Ergänzung in Story 13e.

**13. (neu, Review 8) Sign-off Records-Management-Scope.** Das Epic ist von „Malware-Upload
verhindern" (die ursprüngliche PRD-Growth-Zeile) zu einem vollständigen
Records-Management-System (Two-Eyes-Delete, Legal-Hold, DSGVO-Retention-Policy) gewachsen — das
war nie eine explizite Produktentscheidung, sondern Ergebnis der Architektur-Reviews 1–7. Braucht
vor Dev-Start ein bewusstes Go von Produktseite (nicht rückwirkend aus dem Umfang der Reviews
abgeleitet).

---

## Story-Reihenfolge & Abhängigkeitsgraph (revidiert, 33 Arbeitspakete)

```
Story 1a (media_files + transitions Migration)          [S] — keine Deps
Story 1b (StateMachine Modul)                           [S] — 1a
Story 1c (Download-Gate-Enforcement)                    [S] — 1a, 1b

Story 12 (Gzip Compression in Storage)                  [S] — 1a

Story 3  (ClamAV GenServer)                             [S] — keine

Story 9a (media_config Tabelle + Config Modul)          [S] — 1a
Story 9b (/admin/media/settings Policy-UI)              [S] — 9a
Story 9c (mime_denylist Enforcement)                    [S] — 9a, 9b, 2b

Story 11a (Storage-Config-Schema + Secret-Encryption)   [S] — 1a, 9a
Story 11b (Storage-UI + Test Connection + Warnungen)    [S] — 11a, 9b
Story 11c (s3_key_prefix_template Berechnung)           [S] — 11a, 2b

Story 2a (POST /media/v1/create)                        [S] — 1a, 1b
Story 2b (PUT /upload + Fehlerpfade)                    [S] — 2a, 12
Story 2c (sync-Upload über geteilte Pipeline)           [S] — 2b
Story 2d (Download-Stall-Mechanismus)                   [S] — 1c, 2b
Story 2e (Cleanup-Cron reservierte Uploads)             [S] — 2a

Story 4a (scan_failed ENUM-Migration)                   [S] — 1a, 1b
Story 4b (MediaScanWorker Scan-Flow)                    [S] — 4a, 3, 1b, 2b, 12
Story 4c (infected/scan_failed Audit-Bridge)            [S] — 4b

Story 5a (/admin/media Tabelle)                         [S] — 1a
Story 5b (Live-Row-Updates + Nav-Badges)                [S] — 5a

Story 6a (Routine-State-Aktionen)                       [S] — 5a, 4b
Story 6b (Detail-View + Storage-Summe)                  [S] — 5a
Story 6c (Infected-Override)                            [S] — 6a
Story 6d (Bulk Cohort Actions)                          [S] — 6a, 6c, 5a   (Review 7)

Story 7  (Notifications: Events + Webhook)              [S] — 4c, 5b

Story 8a (MediaCleanupWorker Hard-Delete-Cron)          [S] — 1a, 1b, 4b
Story 8b (Orphan-Detection + DSGVO Art.17)              [S] — 1a, 1b
Story 8c (MediaArchiveWorker Archiv-Tier)               [S] — 8a, 11b, 1c
Story 8d (released_delete_after_days Auto-Delete)       [S] — 8a

Story 10a (media_scan_stats Rollup + Metriken)          [S] — 1a, 4b
Story 10b (ClamAV-Status + Freshclam-Alter)             [S] — 3, 10a
Story 10c (media_alerts + Trigger + Auto-Resolve)       [S] — 10a, 10b, 9a
Story 10d (fail-open/fail-closed Kill-Switch)           [S] — 9a, 2b, 10b
Story 10e (Trace-Map/War-Room-Integration, Review 9)    [S] — 10a, 10c, 4b, 3

Story 13a (Nebu.Media.Lifecycle Policy-Modell)          [S] — 9a, 1b        (Review 5, R-015)
Story 13b (Lifecycle-Rules-UI)                          [S] — 13a, 9b
Story 13c (MediaLifecycleWorker — ersetzt 8a/8c/8d)     [S] — 13a, 8a, 8c, 1c
Story 13d (Two-Eyes-Delete + compliance_officer)        [S] — 13a, 13c, 6a
Story 13e (Art.17 Erasure → Restriction-of-Processing)  [S] — 13a, 13d, 1b, 1c
Story 13f (Policy-Resolution: mxc→Raum-Index + Space)   [S] — 13a, 13c, 1a   (Oracle-Consult)
```

> **Review 5:** Story 13 (13a–13f) konsolidiert die Retention-Pakete 8a/8c/8d/8b + die
> `*_days`-Keys aus 9b in die Lifecycle-Policy (ADR-030) und ergänzt die per-Raum/Space-Cascade
> (13f, Oracle-Consult). Aus 33 Arbeitspaketen werden **39**.

> **Review 7:** Story 6d (Bulk Cohort Actions) ergänzt Multi-Select-Bulk mit Kohorten-Begründung,
> `batch_id`-Fan-out und Partial-Result-Feedback (adressiert den Feedback-Zyklus „Bulk-Confirm/Undo
> & Feedback-States"). Aus 39 Arbeitspaketen werden **40**.

> **Review 9:** Story 10e (Trace-Map- & War-Room-Integration der Scan-Pipeline) verdrahtet die
> Scan-Pipeline-Sichtbarkeit in das inzwischen gemergte Enhanced-Logging-Fundament (kein neuer
> Datenhaltungs-Scope). Aus 40 Arbeitspaketen werden **41**.

## Empfohlene Build-Reihenfolge (revidiert)

1. Story 1a — media_files + media_state_transitions Migration
2. Story 1b — StateMachine Modul
3. Story 1c — Download-Gate-Enforcement
4. Story 12 — Gzip Compression in Storage
5. Story 3 — ClamAV GenServer
6. Story 9a — media_config Tabelle + Config Modul
7. Story 9b — /admin/media/settings Policy-UI
8. Story 11a — Storage-Config-Schema + Secret-Encryption
9. Story 11b — Storage-UI + Test Connection + Warnungen
10. Story 2a — POST /media/v1/create
11. Story 2b — PUT /upload + Fehlerpfade
12. Story 11c — s3_key_prefix_template Upload-Zeit-Berechnung
13. Story 2c — sync-Upload über geteilte Pipeline
14. Story 9c — mime_denylist Enforcement
15. Story 4a — scan_failed ENUM-Migration
16. Story 4b — MediaScanWorker Scan-Flow
17. Story 2d — Download-Stall-Mechanismus
18. Story 2e — Cleanup-Cron reservierte Uploads
19. Story 4c — infected/scan_failed Audit-Bridge
20. Story 5a — /admin/media Tabelle
21. Story 5b — Live-Row-Updates + Nav-Badges
22. Story 6a — Routine-State-Aktionen
23. Story 6b — Detail-View + Storage-Summe
24. Story 6c — Infected-Override
25. Story 6d — Bulk Cohort Actions (Review 7)
26. Story 7 — Notifications (Events + Webhook)
27. Story 8a — MediaCleanupWorker Hard-Delete-Cron
28. Story 8b — Orphan-Detection + DSGVO Art.17
29. Story 8c — MediaArchiveWorker Archiv-Tier
30. Story 8d — released_delete_after_days Auto-Delete
31. Story 10a — media_scan_stats Rollup + Metriken
32. Story 10b — ClamAV-Status + Freshclam-Alter
33. Story 10c — media_alerts + Trigger + Auto-Resolve
34. Story 10d — fail-open/fail-closed Kill-Switch
35. Story 10e — Trace-Map- & War-Room-Integration der Scan-Pipeline (Review 9)
36. Story 13a — Nebu.Media.Lifecycle Policy-Modell + Schema (Review 5)
37. Story 13b — Lifecycle-Rules-UI
38. Story 13c — MediaLifecycleWorker (ersetzt die 8a/8c/8d-Crons)
39. Story 13d — Two-Eyes-Delete + `compliance_officer`-Rolle
40. Story 13e — Art. 17 Erasure-Request → Restriction-of-Processing
41. Story 13f — Policy-Resolution: mxc→Raum-Index + Space-Cascade

---

## Definition of Done (Epic-Level)

- Alle 41 Arbeitspakete (13 fachliche Stories) committed und auf `main` gemergt
- Story 0 (UX-Foundation) abgeschlossen: DESIGN.md + EXPERIENCE.md sind `status: final`, und
  jede UI-Story (5/6/7/9/10/11) wurde vor Umsetzung gegen die Contracts abgeglichen
- Accessibility-Floor (WCAG 2.1 AA) je UI-Story per Playwright/`getByRole` verifiziert; die zwei
  neuen Media-State-Farben (teal/coral) auf ≥ 4.5:1 Kontrast geprüft
- Kein direkter SQL-UPDATE auf `media_files.state` außerhalb von `Nebu.Media.StateMachine`
  (Invarianten-Check via grep in CI)
- **R-006 geschlossen:** `media_state_transitions` ist DB-seitig append-only (ADR-031); ein rohes
  UPDATE/DELETE über die App-DB-Rolle liefert eine Postgres-Fehlermeldung (SQLSTATE 23001) — via
  `MEDIA.1-INT-007` verifiziert, nicht nur per Grep-Abwesenheit
- ClamAV-Integration mit Test-Fixture (`eicar.com`) getestet — inkl. eines Laufs über eine
  **komprimiert gespeicherte** `eicar.com`-Datei (Story 12), um zu verifizieren, dass der
  Scan-Worker vor dem Scan korrekt entpackt
- Admin-UI zeigt State, Audit-Trail und Attention-Badges korrekt
- Retention-Cron läuft im Staging fehlerfrei durch, inkl. Archiv-Tier-Kopie (Story 8c) gegen einen
  zweiten Test-Bucket
- Alle Policy-Werte aus Story 9 sind zur Laufzeit über `/admin/media/settings` änderbar, ohne Redeploy
- S3-Zielkonfiguration (Story 11) inkl. „Test Connection" funktioniert gegen einen Staging-MinIO mit
  anderem Bucket als der Dev-Default; `NEBU_MINIO_*`-Env-Vars funktionieren weiterhin als Fallback
- Scan-Health-Dashboard (Story 10) zeigt Durchsatz, Backlog-Tiefe und Fehlerrate korrekt;
  Alert-Auslösung (ClamAV-Down, Backlog-Schwelle) im Staging mit simuliertem Ausfall getestet
- **Trace-Map/War-Room-Integration verifiziert (Story 10e, Review 9):** Scan-Pipeline-Events
  erscheinen als eigene Domain-Gruppe im Leitstand (`Nebu.Admin.LogsLive.TraceMap`), ohne
  Redaction-Regression; „Live-Diagnose starten" auf `/admin/media/health` öffnet eine
  media-skopierte War-Room-Session innerhalb der bestehenden Budget-/Dauer-Grenzen;
  `media_scan_stats`/`media_alerts` sind unverändert die fachliche Datenquelle für Rollups/Alerts
- Malware-Funde und Admin-Overrides sind über die globale `AuditLogLive`-Ansicht auffindbar
- **Bulk-Override verifiziert (Story 6d):** ein signatur-skopierter Bulk-Override über N
  `:infected`-Dateien schreibt N per-Datei-`media_state_transitions` + N `audit_log`-Einträge mit
  geteilter `batch_id` und *einer* Kohorten-Begründung; ein Admin ohne `media_admin_override` sieht
  die Aktion nicht (Negativ-Test); Legal-Hold-Dateien werden übersprungen und im Partial-Result
  ausgewiesen, nie mit-freigegeben
- **Two-Eyes-Eskalation bei Bulk-Override verifiziert (Offene Entscheidung #10, Review 8):**
  Kohorten < 10 Dateien laufen Single-Actor (mit `critical`-Audit + Notification); Kohorten ≥ 10
  Dateien werden ohne Zweitfreigabe nachweislich blockiert (Negativ-Test); Fast-Track-Eskalation
  nach 15 Min ohne Reaktion ausgelöst (Staging-Test mit verkürzter TTL); Zweitfreigeber sieht die
  vollständige Dateiliste, nicht nur den Kohorten-Schlüssel
- **R-015 (DSGVO Art. 17) geschlossen:** `MEDIA.8-INT-001` grün — Erasure-Request macht ein File
  (auch `:quarantined`/`:infected`) sofort unsichtbar + Legal-Hold, **nicht** physisch gelöscht;
  Lifecycle-/Retention-Crons lassen Legal-Hold-Files nachweislich unberührt (Staging-Lauf)
- **Two-Eyes-Delete verifiziert:** einzelner Admin bzw. 2× Admin ohne `compliance_officer` können
  eine physische Löschung nicht auslösen (Negativ-Tests); beide Actor-IDs im Audit-Log
- **Lifecycle-Policy** über `/admin/media/settings` als Ladder editierbar; die konsolidierte
  `MediaLifecycleWorker`-Engine (Story 13c) ersetzt nachweislich die 8a/8c/8d-Einzel-Crons
- **Per-Raum/Space-Cascade** (`global → space → room`, most-conservative-wins) funktioniert für
  Compliance-Mode-Räume; **E2EE-Räume fallen nachweislich auf `global` zurück** (Test: Chiffrat-Content
  ⇒ kein Raum→Medien-Join ⇒ global, kein Fehler) — spec-bedingt (ADR-030/Oracle)
- **Neun** ADRs finalisiert und in `/docs/adr/` abgelegt (ADR-024–029, ADR-030 Lifecycle &
  Two-Eyes inkl. Restore-Verfahren-Abschnitt, ADR-031 DB-Level Immutability
  `media_state_transitions`, ADR-032 Persistenz-Konsistenz Postgres↔S3)
- Legal-Review-Gate: DSGVO-Retention-Modell (ADR-030, Art. 17(3)) durch DSB/Rechtsanwalt bestätigt
- **Kassandra-Gate (erledigt in Review 8):** Offene Entscheidung #10 (Two-Eyes-Eskalation bei
  Bulk-Override) ist entschieden — Option (c), Schwelle N≈10 + Fast-Track (Story 6d)
- **Backup/Restore-Reconciliation verifiziert (Offene Entscheidung #11):** ein simulierter Restore
  auf einen Snapshot vor einem Hard-Delete bzw. vor einem Legal-Hold-Set führt nachweislich zu
  einem automatischen Reconciliation-Lauf, der die Löschung/den Hold erneut durchsetzt, bevor das
  System wieder für Traffic freigegeben wird (Staging-Test, ADR-030-Erweiterung)
- **Data-Subject-Benachrichtigung entschieden (Offene Entscheidung #12):** Pflicht ja/nein, Kanal
  und Detailgrad sind vor Story 13e final festgelegt und — falls Pflicht — implementiert und
  auditierbar
- **Records-Management-Scope bestätigt (Offene Entscheidung #13):** explizites Produkt-Sign-off
  liegt vor, dass der gewachsene Scope (Two-Eyes-Delete, Legal-Hold, DSGVO-Retention) gewollt ist
- `CLAUDE.md` (globale Facts) um Media-State-Machine-Invariante **und** die Legal-Hold/Two-Eyes-
  Invariante ergänzt

---

## Notizen aus dem Brainstorming

- Der Async-Upload-Flow (`POST /_matrix/media/v1/create` + `PUT /_matrix/media/v3/upload/…`) ist
  seit Matrix v1.7 (Mai 2023) Teil der Kern-Spec — „MSC2246" ist veraltet. Es gibt **keine
  Sync-Events** für Media-State-Changes; Clients pollen beim Download (Stall-Mechanismus, Story 2d).
- Der `/create`-Endpoint nimmt bewusst **keine** Client-Parameter an — Expiry und
  Pending-Upload-Limits sind reine Server-Policy.
- Der `max_stall_ms`-Mechanismus (Default 20s) ermöglicht für kleine Dateien eine transparente
  Quarantäne: Client merkt nichts, Download erscheint normal schnell.
- Synapse's Admin-Quarantäne-API (`/_synapse/admin/v1/quarantine_media/`) dient als Referenz,
  wird in Nebu aber als Teil des regulären Admin-UI abgebildet.
- Der DB-Record (`media_files`) wird niemals gelöscht — nur `storage_key` und `uploader_id` werden
  genullt. Das ist die zentrale Compliance-Invariante dieses Epics.
