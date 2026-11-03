# Pipeline-Optimierung: Tokens, Subscription-Limits, Laufzeit

Branch: `chore/optimize-nebu-pipeline` · Start: 2026-11-02
Ziel: weniger Verbrauch (Subscription-Limits) und kürzere Laufzeit der Pipelines (nebu-pipeline, bmad-pipeline-local, BMAD-Planungs-Skills) ohne Qualitätsverlust.
Vorgehen: erst aus der Struktur ableiten (Phase 0-2), dann messen und gegenprüfen (Phase 3). Zahlen unten sind grob (Bytes / 4).

## Befund (Struktur)

- Modelle: nur Kassandra und Oracle fest auf Opus (gewollt, "kein Downgrade"). Dev-Story sowie Code-, Test- und UX-Review stehen auf `inherit`.
- `skills/nebu-pipeline/SKILL.md` hat 31 KB (~8k Tokens) und liegt für den ganzen Lauf im Orchestrator-Kontext.
- Pro Story rund 10 Schritte; Docker-Rebuild und Integrationssuite laufen vor jedem Review-Zyklus.
- Drei Pipeline-Skills mit Überschneidung: `nebu-pipeline`, `bmad-pipeline`, `bmad-pipeline-local`.
- 81 Skills in `.claude/skills`; deren Beschreibungen (~3,7k Tokens) kommen in jede Session.
- Falle: `_bmad/memory/nebu-agent-kassandra/MEMORY.md` hat 215 KB (~54k Tokens). Die Pipeline lädt den Skill nicht (ausdrücklich verboten), ein direkter Aufruf von `nebu-agent-kassandra` würde es aber tun.
- `.claude/` ist gitignored. Installierte Skill-Kopien weichen von `skills/` ab (7 Dateien, u. a. `ci_gate.py` prüft noch Keycloak statt Dex). Die Pipeline nutzt die Pfade unter `skills/`, betroffen ist nur der direkte Aufruf.

## Plan

- Phase 0: Quick Wins ohne Verhaltensänderung (siehe Protokoll)
- Phase 1: Modell-Routing (`inherit` ersetzen), CI-Gate in Zyklen verschlanken, Arc42 auf Epic-Ende, Review-Zyklen deckeln
- Phase 2: `nebu-pipeline` in Router + Schritt-Dateien teilen, lokale Pipeline daraus ableiten, knappes Subagent-Ausgabeformat
- Phase 3: SubagentStart/Stop-Hooks um Tokens und Dauer erweitern, 2-3 Referenz-Stories vorher/nachher, Qualitätsleitplanken (Zyklen, Findings, CI-Fehlschläge nach Commit, Nacharbeit)

## Phase 0 – Protokoll (2026-11-02)

Umgesetzt (lokal, `.claude/settings.local*.json`, gitignored; Backups `*.bak-phase0` daneben):
- 28 Skills außerhalb des Dev-Loops auf `name-only` gestellt (PRD, Recherche, Brainstorming, Builder, Persona-Agents außer Architect/Dev/TEA, Editorial, Doku-Hilfen). Ersparnis zusammen mit den zwei Duplikaten rund 1,5k Tokens pro Session (grobe Schätzung).
- Ersetzte Duplikate auf `name-only`: `bmad-pipeline` (Cloud-Variante, abgelöst durch `nebu-pipeline`), `agent-oracle` (abgelöst durch `nebu-agent-oracle`).
- Pipeline-interne Skills (create-story, dev-story, code-review, testarch-*, security-review, arc42) bleiben unberührt.
- Rückgängig: Einträge aus `skillOverrides` entfernen oder `.bak-phase0` zurückkopieren.

Bewusst nicht umgesetzt (geprüft, kein Token-Effekt oder Risiko):
- Sperre für `matrix-spec/**/*.html`: der Oracle liest die Spec gezielt per grep/Read-Offset, eine Deny-Regel würde ihn blockieren.
- Löschen von Worktrees, `CLAUDE.md.bak`, `test_output.txt`, `.playwright-mcp`: gitignored bzw. nie im Kontext. Die Worktree-Pfade zeigen auf den Mac; `git worktree prune` aus einer Sandbox würde die Metadaten echter Worktrees entfernen.

## Phase 0 – Nachtrag (2026-11-02, zweite Runde)

- Kassandra-Sanctum verdichtet: `_bmad/memory/nebu-agent-kassandra/MEMORY.md` 215 KB → 55 KB (~54k → ~14k Tokens beim Rebirth). Alle 146 Tabellenzeilen erhalten, gekürzt auf Titel, Epic, Kennzahlen, Report-Verweis und Kern/RULE. Volltext: `archive/MEMORY-full-2026-11-02.md`, im `INDEX.md` vermerkt (nicht automatisch geladen).
- Installierte Skills synchronisiert (`skills/` → `.claude/skills`): Oracle (lokale Spec statt Context7), Testing (`ci_gate.py`: Dex statt Keycloak), Setup, plus Zeitstempel-Abweichungen. Verschachtelte Duplikate `.claude/skills/<n>/<n>` (6 Stück) nach `tmp/skill-upgrade/nested-removed/` verschoben.
- `skillOverrides` versioniert: Template `skills/nebu-pipeline/install/settings-skill-overrides.json` (40 Einträge), additiver Merge in `install_claude_files.py` (`merge_skill_overrides`), idempotent getestet. Neue Worktrees erhalten es über `setup_worktree_claude.sh` automatisch.
- Verteilung auf weitere Checkouts: Anleitung in `tmp/skill-upgrade-spec.md` (bewusst nicht versioniert).

## Phase 3 – Mess-Logging (2026-11-02)

Befund: Die bisherigen SubagentStart/Stop-Hooks (`pipeline_state.py --log-subagent-*`) waren wirkungslos: das Flag existiert nicht, `--file` fehlt, Exit 2, vom `|| true` verschluckt. Ersetzt durch `token_metrics.py`.

- Skript: `skills/nebu-pipeline/scripts/token_metrics.py`; Hooks in `install/settings-hooks.json` (SubagentStart + SubagentStop, `invariant_check` bleibt), per `install_claude_files.py` nach `.claude/settings.json`.
- Pro Subagent eine JSON-Zeile in `.claude/metrics/usage.jsonl` (gitignored, pro Checkout): Tokens je Modell (input / cache_creation / cache_read / output), Dauer, Nachrichten, Tool-Calls, Epic/Story/Schritt/Zyklus aus `pipeline-state.yaml`, Snapshot der kumulierten Hauptsession (Orchestrator). Fehler: `.claude/metrics/errors.log`. Der Hook gibt nichts aus und endet immer mit Exit 0.
- Transcript-Format: Antworten stehen je Content-Block mehrfach drin, daher Deduplizierung nach `message.id`. Gegen ein echtes Transcript mit unabhängiger Rechnung verifiziert (identisch).
- Auswertung: `python3 skills/nebu-pipeline/scripts/token_metrics.py report [--by step|story|epic|label|session|model] [--since YYYY-MM-DD] [--label X] [--file andere/usage.jsonl ...]`; einzelnes Transcript: `... parse <transcript.jsonl>`.
- Index: gewichtete Tokens (output 5x, cache-write 1,25x, cache-read 0,1x, Modellfaktor haiku 0,33 / sonnet 1 / opus 1,67). Näherung zum Vergleichen; die tatsächliche Gewichtung der Subscription-Limits ist nicht öffentlich.

Baseline-Protokoll (vor Phase 1):
1. `export NEBU_METRICS_LABEL=baseline` VOR dem Start von Claude Code (Hooks erben die Umgebung).
2. 3 Referenz-Stories laufen lassen: ein kleiner `--bug`, eine Standard-Story, eine Story mit Gates (ui:true oder matrix:true, ggf. Security).
3. `report --label baseline` und `--by story` sichern. Nach Phase 1 und 2 mit `NEBU_METRICS_LABEL=phase1` bzw. `phase2` wiederholen, `report --by label` vergleicht.
4. Leitplanken zusätzlich festhalten: Review-Zyklen, Findings je Schwere, CI-Fehlschläge nach dem Commit, Nacharbeit.

Beim ersten echten Lauf prüfen: `report` meldet "ohne auffindbares Subagent-Transcript" samt Payload-Schlüsseln, falls Claude Code den Transcript-Pfad anders liefert; dann `locate_agent_transcript()` anpassen. Nicht enthalten: Rückrechnung historischer Läufe.

## Phase 1 – Modell-Routing und Gate-Logik (2026-11-02)

Umgesetzt ohne vorherige Baseline-Messung (bewusste Entscheidung). Alle Stellschrauben stehen in der Tabelle "Tuning" am Anfang von `skills/nebu-pipeline/SKILL.md`; die Spalte "Legacy" stellt das alte Verhalten wieder her.

| Maßnahme | Vorher | Jetzt | Erwartete Wirkung | Risiko / Gegenmittel |
|---|---|---|---|---|
| Modelle | Dev, Test-/UX-Review `inherit` (Modell der Hauptsession), Code-Review `inherit` (Doku: opus) | Dev, Test-Review, UX-Review `sonnet`; Code-Review `opus` im Zyklus 0, `sonnet` ab Zyklus 1; Epic-Runner-Subagent `sonnet`; Kassandra/Oracle unverändert opus | größter Hebel für Subscription-Limits, falls die Hauptsession auf Opus lief | Dev auf Sonnet bei sehr komplexen Stories: Modell in `install/agents/nebu-dev-story.md` anpassen, Installer neu laufen lassen |
| CI-Gate in Zyklen | jeder Zyklus: `make redeploy` + volle Integration (~6 min) | Zyklus 0 voll; ab Zyklus 1 nur `make test-unit-elixir`; neuer Step 6b führt die volle Integration einmal vor Security-Review aus, falls nötig (Marker `integration-stale`) | spart pro Story je Fix-Zyklus einen Rebuild + Integrationslauf (im Beispiel-Bugfix liefen 5) | Integrationsfehler fallen später auf (in 6b, vor Kassandra und Commit) |
| Baseline | jede Story: Rebuild + volle Integration vor dem Coden | Wiederverwendung des finalen Integrationslogs der letzten Story, solange HEAD gleich und Code sauber (`pipeline_gates.py baseline-lookup/-store`, Cache `.claude/pipeline-cache/baseline/`, max. 72 h) | spart einen vollen Lauf je Story außer der ersten | Cache bei flakiger Umgebung veraltet: Cache-Datei löschen oder `BASELINE_CACHE` aus |
| Review-Zyklen | MINOR-only: bis zu 3 automatische Zyklen | 1 automatischer Zyklus, Rest wird in `deferred-minor.md` protokolliert und im Commit-Summary erwähnt | weniger dev↔review↔CI-Schleifen | MINORs bleiben offen; `MAX_AUTO_MINOR_CYCLES` erhöhen |
| Delta-Review | jeder Zyklus: gesamter Diff neu | ab Zyklus 1: nur Diff seit der letzten Review (Tree-Hash-Marke) + Prüfung der Vorbefunde, auf Sonnet; `FULL`-Fallback bei fehlender Marke oder >1500 Zeilen; `EMPTY` -> Rückfrage | deutlich weniger Review-Tokens ab Zyklus 1 | übergreifende Regressionen: abgefangen durch Voll-Review in Zyklus 0, Integration in 6b und Kassandra |
| Arc42 | jede Story, immer | nur bei architekturrelevanten Änderungen (Migrationen, proto, docker, deploy, config, Router, ADRs, neuer Domänenordner) oder Frontmatter `arc42: required`; `arc42: skip` unterdrückt | spart einen Subagent-Lauf bei reinen Logik-, UI- und Test-Stories | Heuristik übersieht Fälle: `arc42: required` im Story-Frontmatter oder `ARC42_MODE: always` |

Abweichung vom ursprünglichen Plan: Arc42 nicht "auf Epic-Ende", weil das Dauer-Epic `bugfix` nie abgeschlossen wird und die Doku dort nie aktualisiert würde.

Dateien: `scripts/pipeline_gates.py` (neu, getestet in Wegwerf-Repos: Cache HIT/MISS/dirty, Marke/Delta/EMPTY, Arc42-Fälle), `SKILL.md`, `pipeline-steps-spec.md`, `install/agents/*.md` (Modelle, Delta-Block im Code-Reviewer), `skills/nebu-pipeline-epic/SKILL.md`.

Bekannter Nachteil: `SKILL.md` wuchs von 31,5 auf 36,7 KB (+~1,3k Tokens im Orchestrator-Kontext). Gelöst durch Phase 2 (Router 9,5 KB).

Noch nicht gemessen (Phase 3, Baseline-Protokoll oben): tatsächliche Einsparung, Qualität (Zyklen, Findings, CI-Fehlschläge nach Commit). Weitere Checkouts, die noch nicht aktualisiert sind, laufen mit altem Verhalten und eignen sich als Vergleichsbasis (`NEBU_METRICS_LABEL=baseline` dort, `phase1` hier).

## Phase 2 – Router, Schritt-Dateien, kompaktes Ausgabeformat (2026-11-02)

| Maßnahme | Vorher | Jetzt | Erwartete Wirkung | Risiko / Gegenmittel |
|---|---|---|---|---|
| Struktur | eine `SKILL.md` mit 36,7 KB, komplett im Orchestrator-Kontext | Router `SKILL.md` 9,5 KB + 15 Schritt-Dateien `skills/nebu-pipeline/steps/*.md` (gesamt 24,8 KB), jede wird erst vor ihrem Schritt gelesen; Schritttabelle im Router | kleinerer Kontext in jedem Orchestrator-Turn (Cache-Reads), bei Resume/`--from` und im Epic-Runner (je Story ein frischer Subagent) werden nur benötigte Schritte geladen | Koordinator liest eine Schrittdatei nicht: Router verlangt es ausdrücklich, fehlende Datei = Stopp |
| Agent-Prompts | Koordinator holte den Prompt per `select_pipeline_step.py`, setzte Story-Abschnitte, Oracle-Kontext und Findings als Text ein und gab ihn als Subagent-Prompt aus (Output-Tokens, doppelt: Agent-Body enthielt denselben Text) | Agent-Body ist die einzige Quelle; Startnachricht besteht nur aus `KEY: value`-Zeilen mit Pfaden (`STORY_FILE`, `REPORT_FILE`, `ORACLE_FILE` …). Agenten lesen Story-Abschnitte selbst (`extract_story_section.py`) | spart pro Schritt das Wiederausgeben von Story-Abschnitten und Berichten durch den Koordinator (Output-Tokens, 5-fach gewichtet) | Agent sieht weniger Kontext: `FULL_STORY: yes` (Context-Fallback) bleibt möglich |
| Berichte | Reviewer-Antwort (voller Bericht) landete im Orchestrator-Kontext, wurde per `tee` erneut ausgegeben, dann als Variable wieder in Prompts eingesetzt | Reviewer/Oracle/UX schreiben den Bericht per Bash-Heredoc nach `REPORT_FILE`, Antwort nur 4-Zeilen-Digest (`VERDICT`, `COUNTS`, `REPORT`, `TOP`); Folgeagenten bekommen den Pfad. Findings einzeilig: `SEV \| datei:zeile \| Problem \| Fix`. Dev-Agent antwortet mit `VERDICT/TESTS/FILES`. Kassandra: Digest statt Prosa | Berichtstext steht nie im Koordinator-Kontext; Entscheidung nur über Digest | Reviewer haben weiterhin kein `Write`/`Edit`; sie schreiben nur über Bash in `REPORT_FILE` (Konvention). Bei Prosa-Antwort schreibt der Koordinator sie einmal in die Datei (Fallback) |
| Delta-Diff | Diff wurde in den Koordinator-Kontext gedruckt und in den Prompt kopiert | `pipeline_gates.py review-delta --out <datei>`; Reviewer liest `review-delta.diff` | wie oben | `--out` optional, altes Verhalten bleibt |
| Testlogs | `make test-integration 2>&1 \| tee log` druckte das ganze Log in den Kontext; `$?` war der Exit-Code von `tee` (Fehler wurde nie erkannt) | Umleitung in die Logdatei, im Kontext nur `tail -n 25`; `$?` ist jetzt der Exit-Code von `make`. Gleiches für Redeploy und Unit-Läufe | Integrationslog (tausende Zeilen) bleibt außerhalb des Kontexts; echte Fehlererkennung | – |
| Lokale Pipeline | – | **Nicht abgeleitet.** `bmad-pipeline-local` ist das lokale-LLM-Gegenstück zur alten `bmad-pipeline` (BMAD-Schritte `bmad-create-story`/`bmad-dev-story`, alles inline, ohne Subagenten, RTK-Pflicht), nicht zur nebu-pipeline. Die nebu-Schritt-Dateien setzen Subagenten, Digest und Dateipfade voraus und passen nicht dazu | – | Falls die lokale Variante der nebu-pipeline gewünscht ist, ist das eine eigene Aufgabe (inline-Modus pro Schrittdatei) |

Nebenbei korrigiert: Step 5b prüfte noch den alten Go-Pfad `gateway/internal/admin/`; jetzt `server/lib/nebu/admin/`.

Dateien: `SKILL.md` (Router), `steps/*.md` (neu), `pipeline-steps-spec.md` (Digest-Vertrag, Prompts nur noch für Skill-Schritte), `install/agents/*.md` (Eingaben und Output-Vertrag), `scripts/pipeline_gates.py` (`--out`), `skills/nebu-pipeline-epic/SKILL.md`. Backups der Vorversion: `tmp/skill-upgrade/phase2-backup/`.

Noch nicht gemessen: Ein Teil des Gewinns ist strukturell (kleinerer Router), der größere liegt im Wegfall des Wiedereinsetzens von Texten und der Logs. Beides lässt sich nur im Lauf belegen: `token_metrics.py report --by step` Spalte "Orch Δk" (Zuwachs der Hauptsession) pro Gruppe, Label `phase2`. Die Digest-Disziplin der Agenten (Bericht in Datei, 4 Zeilen Antwort) ist ungetestet bis zum ersten echten Lauf.

## Phase 4 – Skript-Potenzial und Umsetzung (2026-11-02)

Analyse (Rangliste) und anschließend umgesetzt: alle sieben Punkte, ohne auf die Messung zu warten (Entscheidung: je mehr im Skript, desto weniger muss das LLM ran). Die Umsetzung steht im Abschnitt "Umsetzung Phase 4" weiter unten.

**Datenbasis.** Messung im Hauptcheckout, Session 03948291, Epic `media-storage-admin-target`, 16 auswertbare Subagent-Läufe (Index = gewichtete Tokens, nur zum Vergleichen). Das ist ein kleiner Ausschnitt; die Zuordnung `general-purpose` -> ATDD/Test-Review ist eine Annahme (siehe "Messung" unten).

| Block | Anteil am Subagent-Index | Beobachtung |
|---|---|---|
| `general-purpose` (Skill-Schritte: vermutlich ATDD, Test-Review, create-story, arc42) | 50 % (6 Läufe, ~57 Msg, ~47k Output-Tokens je Lauf) | Läuft über die generischen BMAD-TEA-Workflows |
| `nebu-dev-story` | 39 % (5 Läufe, ~33k Output je Lauf) | echte Implementierungsarbeit |
| `nebu-code-reviewer` / `nebu-kassandra` / `nebu-oracle` | 5 % / 5 % / 1 % | klein |
| Orchestrator (Hauptsession, Zuwachs im Messfenster) | ca. 8 % von Subagents+Orchestrator (1,5M vs. 18,3M Index) | klein, aber verantwortlich für Latenz und Fehlerrisiko |

**Rangliste (Hebel = Anteil x Skriptbarkeit).**

| # | Stelle | Warum Skript möglich | Vorschlag | Aufwand | Vertrauen |
|---|---|---|---|---|---|
| 1 | **ATDD** (`bmad-testarch-atdd`) | Der Skill umfasst 9 Schrittdateien (62 KB) plus 38 KB Checklisten und Knowledge-Fragmente. Schritt 1 erkennt den Stack anhand von `package.json`/`go.mod`/`pyproject.toml` (Nebu ist Elixir + Playwright-E2E, das Ergebnis ist konstant), lädt Knowledge-Fragmente über `tea-index.csv`, 04a/04b sind als Subagenten ausgelegt, 04c aggregiert, 05 validiert (Inhalt der Fragmente nicht geprüft). | (a) `atdd_scaffold.py`: Gherkin-Szenarien aus `Acceptance Tests` der Story extrahieren, ExUnit-Gerüst und `.feature`-Dateien mit REQ-ID-Tags und Szenariennamen erzeugen; (b) `atdd_verify.py`: neue Testdateien laufen lassen und prüfen, dass sie aus dem richtigen Grund rot sind (UndefinedFunctionError / nicht implementiert) und nicht an Kompilier- oder Syntaxfehlern; (c) ein schlanker `@nebu-atdd`-Agent statt des TEA-Workflows (wie bei `nebu-dev-story`), der nur Testkörper ausfüllt | mittel | hoch (Struktur), mittel (Einsparung) |
| 2 | **Test-Review** (`bmad-testarch-test-review`) | 51 KB Schrittdateien, vier Bewertungs-Subagenten (Determinismus, Isolation, Wartbarkeit, Performance) plus Score-Aggregation (03f). Score-Berechnung ist reine Arithmetik; die Prüfpunkte aus dem Prompt sind größtenteils grep-bar. | `test_lint.py`: AC -> Test-Abdeckung (Tags/Namen), harte Waits (`Process.sleep`, `:timer.sleep`, `waitForTimeout`), brüchige Selektoren, Crash/Restart-Test bei GenServer-Stories, Playwright-Dateien bei `ui: true`, jeder `M_*`-Code aus `ORACLE_FILE` kommt in einem Test vor. MAJOR-Kriterien des Prompts werden vom Skript entschieden; der LLM-Review (sonnet, `@nebu-test-reviewer` statt TEA-Skill) bekommt den Lint-Bericht und beurteilt nur den Rest. Optional `TEST_REVIEW_LLM: auto` (LLM nur, wenn Lint Auffälligkeiten hat) | klein bis mittel | hoch |
| 3 | **Testausgabe im Dev-Zyklus** | Der Dev-Agent führt `make test-unit-elixir` aus (jedes Mal `hex --force`, `deps.get`, ganze Suite, ExUnit-Rohausgabe mit Punkten, Warnungen und Stacktraces). Die Ergebnisse stehen als Tool-Output im Agentenkontext und werden bei jedem weiteren Turn neu gelesen. | `test_digest.py -- <befehl>`: Befehl ausführen, Volllog in Datei, im Kontext nur Anzahl, Fehlschläge mit Namen und den ersten ~15 Zeilen je Fehler. Dazu ein fokussiertes Target (`mix test <datei>:<zeile>`, `--failed`, `--max-failures 3`) für die Iterationsschleife und die Gesamtsuite nur zum Abschluss | klein | hoch |
| 4 | **Konventions-Vorprüfung vor dem Code-Review** | `invariant_check.py` prüft heute 6 Regeln (Ecto-Schema, `Process.register`, `:global`, Public-API, Redis/NATS, OIDC-Env). Weitere Punkte, die der Reviewer (opus) heute per Lesen prüft, sind skriptbar. | `review_prescan.py` erweitert um: Migrationspaare `NNNNNN_name.up/down.sql` und keine Änderung ausgelieferter Migrationen (`git diff --name-status`), `String.to_atom`/`Code.eval_*`/`binary_to_term` ohne `:safe`, SQL-Interpolation (`#{` in `query(`), Secrets in `Logger`-Aufrufen, neue Router-Routen ohne Auth-Pipeline, fehlende Fehlercodes aus `ORACLE_FILE`. Ausgabe `prescan-findings.md`; der Reviewer bekommt sie als Eingabe und prüft nur Semantik | mittel | mittel bis hoch |
| 5 | **Kassandra-Vorscan** | Opus-Lauf muss erst Kandidaten suchen. | `sec_prescan.py` (grep-Ebene, gleiche Kategorien wie oben plus `raw/1`, offene Redirects, `==` auf Tokens, `System.cmd` mit Interpolation) liefert Kandidaten mit Datei:Zeile; Kassandra verifiziert und bewertet. Zusätzlich `SEC_REVIEW` automatisch auf `required` setzen, wenn der Diff Auth-/Krypto-/Migrations-/Router-Pfade berührt | mittel | mittel |
| 6 | **Orchestrator-Entscheidungen** | Die Auswertung der Digests (VERDICT -> nächster Schritt, Zyklusgrenzen, Defer-Regel), das Auflösen der Pfadvariablen, die Skip-Bedingungen (Matrix, UI, Security, arc42, `integration-stale`) und die Log-Zeilen sind reine Logik. | `pipeline_gates.py decide --step <s> --digest <datei> --cycle N` -> `NEXT <step>` / `ASK_USER <grund>` / `DEFER_MINOR` plus fertige `pipeline_state.py`-Parameter; `pipeline_env.py --epic <n>` gibt die Pfade aus. Langfristig ein `pipeline_next.py`, das aus State + Flags den nächsten Schritt samt Startnachricht ausgibt: der Orchestrator wird zur Schleife "Skript fragen, ausführen, Digest zurückgeben". Auch `commit_summary.py` (Titel + REQ-ID + Zyklen aus dem Log) und `epic_status.py` (Story-Status zählen, Epic-Basis-Commit) | mittel | hoch (Zuverlässigkeit, Latenz), gering (Tokens, da nur ~8 %) |
| 7 | **Oracle-Vorlage** | Nur 1 % der Tokens. | `spec_extract.py`: `/_matrix/...`-Pfade aus den AC lesen, passende Abschnitte und Fehlercodes aus dem lokalen `matrix-spec/` ziehen; Oracle prüft nur noch (ggf. sonnet) | klein | gering (Nutzen) |

**Bereits umgesetzt in dieser Runde.** `pipeline_state.py` ersetzt das Wort `TIMESTAMP` in `--log` durch die Skriptzeit (der LLM musste die Uhrzeit bisher selbst einsetzen) und legt die State-Datei beim ersten Aufruf an (vorher Fehler, den der Koordinator von Hand umgehen musste). Das Messprofil (siehe unten) ist eingebaut.

**Nicht lohnend.** Formatieren: `server/` hat weder `.formatter.exs` noch Credo; ein Formatter-Hook wäre erst nach Einführung beider sinnvoll (eigene Entscheidung, nicht Teil dieser Analyse). Commit-Mechanik, CI-Gate und Baseline laufen bereits ohne LLM.

**Messung.** Der Hook schreibt jetzt je Lauf ein Profil: Tool-Aufrufe nach Art (`make test-unit-elixir`, `git add`, `py:pipeline_state.py`, `Read` ...), Zeichen der Tool-Ergebnisse je Art (was den Kontext füllt), Thinking- und Text-Zeichen. Zusätzlich wird ein `general-purpose`-Lauf anhand des ersten Prompts (`skills/<name>/SKILL.md`) dem Schritt zugeordnet (`atdd`, `test-review`, `create-story`, ...). Auswertung: `token_metrics.py profile` und `report --by step`. Erst diese Zahlen bestätigen oder widerlegen die Rangliste: Ist ATDD wirklich der große Block, und was davon ist Thinking, was Tool-Ergebnis? Läufe vor dieser Änderung haben kein Profil.

Empfohlene Reihenfolge: einen Lauf mit Profil abwarten, dann 3 (billig, wirkt im größten Einzelblock Dev) und 1/2 (größter Block, braucht die Messung als Beleg), danach 4 und 6.

## Umsetzung Phase 4 (2026-11-02)

Alle Skripte liegen in `skills/nebu-pipeline/scripts/`, nutzen nur die Python-Standardbibliothek und teilen sich `pipeline_lib.py` (Story-Parser, Gherkin-Szenarien, git-Helfer, Digest-Parser).

| # | Skript | Was es entscheidet | Wo das LLM noch läuft |
|---|---|---|---|
| 1 | `atdd_scaffold.py`, `atdd_verify.py`, Agent `@nebu-atdd` | Gerüst aus den Gherkin-Szenarien (ein ExUnit-Test je Szenario mit `@tag ac:`, `.feature` bei UI), Prüfung: jedes Szenario getestet, keine Platzhalter, Assertions vorhanden, Lauf rot aus dem richtigen Grund | `@nebu-atdd` (sonnet) füllt die Testkörper; bei `ATDD_MODE: tea`, Stories ohne Gherkin und `--bug` läuft weiter der BMAD-Skill |
| 2 | `test_lint.py` | AC-Abdeckung, Platzhalter, harte Waits, brüchige Selektoren, globaler Zustand in async-Tests, fehlende Assertions, Crash/Restart, E2E bei `ui`, `M_*`-Codes aus dem Oracle | `@nebu-test-reviewer` nur bei `LLM_NEEDED: yes` (MINOR/JUDGE-Fälle); `TEST_REVIEW_LLM: always` stellt das alte Verhalten wieder her |
| 3 | `test_digest.py` (+ `--baseline`) | Befehl ausführen, Volllog auf Platte, im Kontext nur Zahlen und Fehlschläge; mit `--baseline` nur NEUE Fehlschläge gegenüber dem Baseline-Log (ersetzt `diff … | grep`); `make test-unit-elixir` nimmt jetzt `TEST_ARGS` und läuft mit `--warnings-as-errors` | Dev-Agent und CI-Gate rufen es auf; kein eigener LLM-Schritt |
| 4 | `review_prescan.py` | Migrationsnamen/-paare/Lückenlosigkeit, geänderte ausgelieferte Migrationen, `Code.eval*`, `binary_to_term` ohne `:safe`, `String.to_atom`, `IO.inspect`/`dbg`, übersprungene Tests (hart); SQL-Interpolation, Secrets in Logs, fehlende Fehlercodes (Hinweise) | Reviewer übernimmt harte Funde unverändert, bestätigt oder verwirft Hinweise und prüft die Semantik. Bei MAJOR im Zyklus 0 entfällt der LLM-Review (`PRESCAN_SHORT_CIRCUIT`), der volle Review folgt im nächsten Zyklus |
| 5 | `sec_prescan.py` | Kandidaten mit Datei:Zeile und CWE (SQL/Command/Atom/XSS/Redirect/SSRF, Timing-Vergleich, Secrets in Logs, schwache Krypto, Cookies, neue Routen, sensible Migrationen); `SEC_SUGGEST` kann `SEC_REVIEW` auf `required` anheben; `classify_story.py` nutzt dieselben Elixir-Pfadmuster (die alten Go-Pfade waren tot) | Kassandra verifiziert die Kandidaten und prüft Autorisierung/Geschäftslogik |
| 6 | `pipeline_gates.py decide`, `pipeline_env.py`, `commit_summary.py`, `epic_status.py`; `update_sprint_status.py --story-file` | VERDICT → nächster Schritt, Zyklusgrenze, MINOR-Deferral, `blocking_severity`, 3-Runden-Limit, fertige `pipeline_state.py`-Parameter; Pfadvariablen; Commit-Nachricht (Conventional Commit, `Refs: REQ-ID`), Kurzfassungen für Sprint-Status und Log; Epic-Vollständigkeit, nächste Story, Diff-Basis des Epic-Security-Reviews; Status in Story-Datei und Sprint-Status (bei benannten Epics wurde der Eintrag bisher nie angelegt) | Der Orchestrator führt aus und zeigt `MESSAGE`; Entscheidungen des Users bleiben beim User |
| 7 | `spec_extract.py` | Endpunkte der Story (voll ausgeschrieben oder als Kurzform `GET /devices`) in der gebündelten Matrix-OpenAPI nachschlagen: Auth, Rate-Limit, Pflichtfelder, Antwortcodes mit `M_*`, MUST-Sätze. `COVERAGE: full` → der Entwurf ist der Oracle-Kontext (kein LLM) | `@nebu-oracle` (opus) bei `partial`/`none` mit dem Entwurf als Vorlage; Event-Typen, Sync/E2EE-Verhalten und nicht gefundene Endpunkte ergänzt er |

**Neue Stellschrauben** (Tabelle "Tuning" im Router): `ATDD_MODE` (lean|tea), `TEST_REVIEW_LLM` (auto|always), `ORACLE_LLM` (auto|always), `PRESCAN_SHORT_CIRCUIT` (on|off).

**Geprüft.** Alle Skripte einzeln in Scratch-Repos und gegen echte Commits kalibriert (Fehlalarme der Prescans abgebaut); Kette Env → Scaffold → Verify → Lint → decide → pipeline_state → commit_summary in einem Scratch-Repo durchgespielt; `spec_extract` gegen 8 echte Matrix-Stories (volle Pfade, Kurzformen, Präfix-Referenzen). Statische Prüfung: alle in Steps/Agents referenzierten Skripte existieren, keine veralteten Platzhalter, Installer und Sync ohne Drift.

**Bewusst konservativ.** `spec_extract` meldet `full` nur, wenn kein Event-Typ, kein Sync/E2EE-Begriff und keine Kurzform-Treffer im Spiel sind; im Zweifel läuft der Oracle mit Vorlage. Das alte Unit-Kommando in Schritt 5 (`nebu-agent-testing/scripts/ci_gate.py --story …`) wurde ersetzt: es lief die komplette CI-Kette erneut (Build, Go, E2E, Integration), obwohl Schritt 5 gerade die Integration gefahren hatte.

**Noch nicht erprobt.** Kein Lauf der gesamten Pipeline mit dem neuen Stand. Risiken, die ein erster Lauf zeigen wird: ob `@nebu-atdd` die Platzhalter sauber ersetzt, ob die Fehlalarmrate der Prescans im Alltag tragbar ist, ob der Orchestrator die Heredoc-Aufrufe von `decide` korrekt zitiert.

## Phase 5 – Harness: Read-Guard, Deny-Regeln, Arbeitsstil (2026-11-02)

Ausgangslage aus der ersten Messung (ATDD-Lauf im e2ee-Worktree): 19 Nachrichten, 1,1M gelesene Cache-Tokens (ca. 58k Kontext je Turn), davon 77k Zeichen Tool-Ergebnisse hinter `cd …`. Der feste Projektanteil (Agent-Prompt, vorgeladene Skills, `CLAUDE.md`, Rules, Agent-Memory) liegt bei grob 6-9k Tokens; was den Kontext füllt, sind Tool-Ergebnisse und die Zahl der Turns.

- **`read_guard.py` (PreToolUse-Hook auf `Read|Bash`).** Verweigert `Read` ohne `limit` (oder mit `limit` > 600) für Dateien ab 40 KB (`NEBU_READ_MAX_KB`) sowie ein einfaches `cat <datei>` solcher Dateien, mit Hinweis auf Grep + `offset`/`limit` bzw. `grep -n`/`tail` für Logs. Ausgenommen: Bilder/PDF und gepflegte Dokumente (`*.md/yaml/toml` unter `docs/`, `_bmad*/`, `skills/`, `.claude/`), damit Story-Dateien weiter ganz gelesen werden. Im Repo betrifft das 78 Code-Dateien ab 40 KB (zusammen 5,4 MB), die größte `event_dispatcher/server.ex` mit 460 KB (ca. 117k Tokens). Jede Verweigerung landet in `.claude/metrics/guard.log`; Auswertung `read_guard.py --summary`. Fail-open bei jedem Fehler, abschaltbar mit `NEBU_READ_GUARD=off`.
- **Deny-Regeln** (`install/settings-permissions.json`, vom Installer additiv in `permissions.deny` gemergt): `node_modules`, `server/_build`, `package-lock.json`, `.playwright-mcp`. Bewusst nicht gesperrt: `server/deps` (Dependency-Quellen werden gelegentlich gebraucht; `Grep` überspringt sie ohnehin über `.gitignore`) und `.claude/worktrees` (aktive Worktrees liegen dort).
- **Arbeitsstil-Block** in allen sieben Agent-Prompts: unabhängige Reads/Greps in einem Turn, kein Erzählen zwischen Tool-Aufrufen, große Dateien nur mit `offset`/`limit`, Tests nur über `test_digest.py`, Bericht in einem Heredoc.
- **Installer:** ersetzt nur noch eigene Hook-Einträge (Befehle unter `skills/nebu-pipeline/scripts/`) und lässt eigene Hooks derselben Art stehen.
- **`token_metrics.py`:** `cd x && befehl` wird nach `befehl` klassifiziert (vorher alles unter `cd`).

**Zu prüfen.** (1) Ob die Deny-Syntax (`Read(**/node_modules/**)`, `Read(/server/_build/**)`) in deiner Claude-Code-Version greift: einmal eine Datei unter `server/_build` lesen lassen. (2) Ob `PreToolUse` für Subagent-Aufrufe feuert und `agent_type` im Payload steht: `read_guard.py --summary` nach dem ersten Lauf, die Spalte "by agent" muss Agentennamen zeigen. (3) Wirkung: Anzahl Verweigerungen und danach Tool-Ergebnis-Zeichen je Lauf (`token_metrics.py profile`) mit Phase 4 vergleichen.

## Offene Punkte

1. Prüfen (nach Neustart, `/skills`), ob `skillOverrides` aus `.claude/settings.json` wirken; Fallback sind die Einträge in `settings.local.json`.
2. Vergleichsläufe (Label `baseline` im alten Checkout, `phase1` hier) und `report --by label`.
3. Ersten echten Lauf mit dem Phase-2-Stand beobachten: antworten die Agenten im Digest-Format, schreiben Reviewer die `REPORT_FILE`, liest der Koordinator die Schrittdateien? Label `phase2`.
4. Hook-Diagnose: 3 von 21 Metrik-Zeilen im Hauptcheckout haben `agent_type=unknown` und kein Transcript. Der Hook schreibt dafür jetzt `diag` (Pfad, Existenz, rohes `agent_type`); beim nächsten Auftreten ansehen.
5. e2ee-Worktree: Upgrade ist installiert, aber keine Metriken. Wahrscheinlichste Ursache: Session vor dem Upgrade gestartet (Hooks laden nur beim Sessionstart). Nach Neustart prüfen, ob `.claude/metrics/usage.jsonl` entsteht.
6. Optional: `bmad-pipeline-local` bleibt unverändert (siehe Phase 2).
7. Ersten echten Lauf mit dem Phase-4-Stand beobachten (Label `phase4`): `atdd_verify` nach `@nebu-atdd`, Trefferquote von `spec_extract` (`COVERAGE`), `LLM_NEEDED` von `test_lint`, Fehlalarme der Prescans. Danach Schwellen und Heuristiken nachziehen.
8. Optional später: `pipeline_next.py` (aus State + Flags den nächsten Schritt samt Startnachricht ausgeben), falls der Orchestrator trotz `decide` noch zu viel entscheidet.
