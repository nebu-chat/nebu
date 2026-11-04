# ADR-011: E2EE - Evaluierung & Zurückstellung

## Status

Accepted - E2EE zurückgestellt; Option 3 (Compliance-Bot) ist präferierter Ansatz für spätere Phase

## Kontext

Im Rahmen der Compliance-Architektur wurde evaluiert, ob und wie Ende-zu-Ende-Verschlüsselung (E2EE)
mit der Anforderung nach vollständigem Compliance-Zugriff vereinbar ist.

Nebu zielt auf compliance-first-Organisationen ab, die server-seitige Nachrichtensichtbarkeit für
Audit-Logging, Four-Eyes-Compliance-Zugriff und rechtlichen Export benötigen. Die Client-Kompatibilitäts-Endpunkte
(`keys/upload`, `keys/query`, `keys/device_signing/upload`, `room_keys/*`) bleiben in Betrieb,
um Client-Fehlerdialoge zu verhindern (siehe die Updates unten: sie sind keine reinen Stubs mehr).

> **Update 2026-10-30 (story `server-side-key-backup`, epic e2ee-client-support):** `room_keys/*`
> (Matrix CS v1.18 "Server-side key backups") ist **kein Stub mehr**, sondern ein **opaker,
> PostgreSQL-gestützter Schlüssel-Backup-Speicher** pro Nutzer (Tabellen `room_key_backup_versions`,
> `room_key_backup_sessions`; Migration `000058`). Der Server speichert `auth_data` und die
> `session_data`-Blobs unverändert als JSON, **entschlüsselt sie nie** und parst sie nicht über
> Wohlgeformtheit und Größe hinaus; sie werden nie geloggt und beim GDPR-Erase mit gelöscht. Das
> schaltet **keinen** E2EE-Raum ein: `m.room.encryption` wird weiterhin in jedem Schreibpfad
> abgelehnt (diese ADR bleibt gültig), der Speicher dient nur dem Wiederherstellen von
> Client-Schlüsseln ("Chat-Wiederherstellung") und dem Abschluss des Secret-Storage-Bootstraps.

> **Update 2026-11-02 (story `device-key-directory`, epic e2ee-client-support):** `POST /keys/claim`, `GET /keys/changes` und die E2E-Felder
> des `/sync` (`device_lists`, `device_one_time_keys_count`, `device_unused_fallback_key_types`) vervollstaendigen das Schluesselverzeichnis (nur oeffentliche
> Schluessel und Geraetelisten-Metadaten; Tabelle `device_list_changes`, Migration `000060`). Der Server entschluesselt nichts und loggt kein Schluesselmaterial. Das
> schaltet **keinen** E2EE-Raum ein: `m.room.encryption` wird weiterhin abgelehnt (diese ADR bleibt gueltig).

> **Update 2026-10-30 (story `to-device-messaging`, epic e2ee-client-support):** `sendToDevice` und
> `to_device.events` des `/sync` (Matrix CS v1.18 "Send-to-Device messaging") sind ein **opaker,
> PostgreSQL-gestützter Transport** pro Gerät (Tabellen `to_device_messages`, `to_device_txns`;
> Migration `000059`): der Server entschlüsselt oder interpretiert den Inhalt nie, loggt ihn nie und
> löscht ihn beim GDPR-Erase mit. Das schaltet **keinen** E2EE-Raum ein: `m.room.encryption` wird
> weiterhin in jedem Schreibpfad abgelehnt (diese ADR bleibt gültig); der Transport dient
> Geräte-Verifikation, Schlüsselanfragen und Secret-Sharing der Clients.

> **Update 2026-11-03 (story `e2ee-compliance-channel-guard`, epic e2ee-client-support, Epic-Security-Gate 2, HIGH-Befund #1):** Die E2EE-Client-Infrastruktur darf
> keinen unbeschraenkten opaken Kanal neben den archivierten Raeumen oeffnen. (1) **Raum-Events:** `m.room.encrypted` wird auf JEDEM Raum-Schreibpfad mit `403 M_FORBIDDEN`
> und dem festen Text der `m.room.encryption`-Ablehnung verweigert (Raum-`send`-Route vor Raum-Lookup und Txn-Dedup, State-PUT, Dispatcher als Defence in Depth);
> in `initial_state` von createRoom wird der Eintrag uebersprungen. In-Raum-Verifikation (`m.key.verification.*`) und `m.room.redaction` bleiben unveraendert.
> (2) **To-device:** `sendToDevice` akzeptiert nur noch eine feste **Allowlist** (exakter Match, eine benannte Konstante in `http_to_device.ex`, ein neuer Typ ist eine
> begutachtete Ein-Zeilen-Aenderung): `m.room.encrypted`, `m.room_key_request`, `m.room_key.withheld`, `m.secret.request`, `m.dummy` und die acht Verifikationstypen
> `m.key.verification.request`, `m.key.verification.ready`, `m.key.verification.start`, `m.key.verification.accept`, `m.key.verification.key`, `m.key.verification.mac`,
> `m.key.verification.done`, `m.key.verification.cancel` (QR-Verifikation nutzt `.start` mit Methode `m.reciprocate.v1` und `.done`). Bewusst NICHT in der Liste:
> `m.room_key`, `m.forwarded_room_key` und `m.secret.send` (laut Spec innere, Olm-verpackte Nutzlasten, nie der aeussere Typ) und der unstable Alias
> `org.matrix.room_key.withheld`. Jeder andere Typ ist `400 M_INVALID_PARAM` (fester Text, vor Rate-Limit, Body, Empfaenger und Budgets, ohne Empfaenger-Orakel).
> Bekannter Ausschluss: der to-device-Schluesseltransport von Element Call / MatrixRTC (`io.element.call.encryption_keys`, `m.call.*`) wird verweigert, Ende-zu-Ende
> verschluesselte Element-Call-Anrufe funktionieren gegen Nebu nicht. (3) **Akzeptiertes Restrisiko (vom Owner am Epic-Gate abgenommen):** to-device bleibt ein
> **nicht archivierter, server-opaker Nutzer-zu-Nutzer-Kanal** fuer die Allowlist-Typen (Olm-verpackter Inhalt ist per Design opak und fuer Schluesselaustausch und
> Verifikation noetig), begrenzt durch die Budgets von `to-device-messaging` (64 KiB je Request, 50 Empfaenger, Queues je Geraet/Paar/Sender, TTL 7 Tage, Rate-Limit).
> Die Allowlist ist ein **Typ-Filter, kein Inhalts-Filter**: sie begrenzt, welche Typen benutzt werden duerfen, prueft oder begrenzt den Inhalt aber nicht unterhalb der bestehenden Budgets (beliebiger Inhalt passiert unter `m.dummy`, den Verifikationstypen, `m.room_key_request`, `m.secret.request`, `m.room_key.withheld`); der Kanal ist fuer die erlaubten Typen so gross wie zuvor. Auch die Key-Backup-Blobs und die Cross-Signing-Signaturen sind opake Client-Daten. Es gibt **kein Audit je Sendung** von to-device-Verkehr; wer eines braucht,
> eroeffnet eine neue Story. Siehe `11-risks.md` und `07-deployment.md`.

> **Update 2026-06-26 (bugfix `fix-device-key-registration`):** Die reinen No-op-Stubs für
> `keys/upload`/`keys/query` lösten in Element den Fehler *"device could not be registered"* aus
> (leeres `/keys/query` ⇒ der Client sah sein eigenes Gerät nie als publiziert). `keys/upload`,
> `keys/query`, `GET /devices(/{id})` und `whoami.device_id` sind jetzt ein **funktionierendes,
> PostgreSQL-gestütztes Geräteschlüssel-Verzeichnis** (Tabellen `device_keys`,
> `device_one_time_keys`, `device_fallback_keys`; Migration `000009`). Das Verzeichnis ist
> **orthogonal zu E2EE** — es speichert/serviert öffentliche Geräteschlüssel und schaltet keine
> Verschlüsselung ein. E2EE wird in Matrix ausschließlich durch ein `m.room.encryption`-State-Event
> aktiviert; Nebu **verweigert** dieses Event in *jedem* Schreibpfad (direkter State-PUT → 403
> `M_FORBIDDEN`; `createRoom` `initial_state` und Room-Upgrade `copy_state_events` → übersprungen),
> sodass die Managed-Decryption-Garantie erhalten bleibt. Das durable gespeicherte öffentliche
> Ed25519-Geräteschlüssel-Material ist zudem die Grundlage für die spätere Nachricht-Signatur-/
> Non-Repudiation-Verifikation (PRD FR25–FR27).

## Evaluierte Optionen

### Option 1: Managed E2EE mit Escrow-Keys

Jede Nachricht wird client-seitig verschlüsselt. Der Message Key wird zusätzlich mit einem
Escrow Public Key eingeschlossen, sodass ein privilegierter Compliance-Zugriff über den
Escrow Private Key möglich bleibt.

**Warum nicht umsetzbar:** Der Escrow-Schritt muss zwingend im sendenden Client erfolgen - der
Server sieht nur Ciphertext und kann nichts nachträglich hinzufügen. Weder Element noch FluffyChat
(Standard) implementieren diesen Schritt. Da Nebu explizit Standard-Matrix-Clients unterstützen
soll, würde jeder Nicht-Nebu-Client den Escrow-Schritt überspringen. Das Ergebnis wäre ein
Zwei-Klassen-System: Compliance-Garantie nur für Nutzer des Nebu-eigenen Clients - was die
Architekturgarantie bricht.

### Option 2: Gateway-Terminated Encryption

Der Client verschlüsselt bis zum API-Gateway. Das Gateway entschlüsselt und speichert Nachrichten
je nach Room-Policy (Plaintext oder Escrow-verschlüsselt) in PostgreSQL.

**Warum nicht als E2EE vermarktbar:** "End-to-End" impliziert, dass kein Zwischenpunkt Klartext
sieht. Da das Gateway entschlüsselt, ist dies technisch korrekt als Transport Security mit
Policy-based Storage at Rest zu bezeichnen - nicht als E2EE. Gegenüber Kunden wäre die Bezeichnung
"E2EE" irreführend. Der Mehrwert gegenüber dem bestehenden TLS 1.3 ist zudem gering, da TLS
bereits "verschlüsselt bis zum Gateway" leistet. Der echte Wert - Policy-based Encryption at Rest
pro Raum - ist unabhängig von E2EE realisierbar und bleibt als spätere Option erhalten.

### Option 3: Compliance-Bot als Raum-Mitglied (präferierter Ansatz, zurückgestellt)

Ein server-seitiger Compliance-Bot ist als legitimes Matrix-Mitglied in relevanten Räumen
eingetragen. Er empfängt Nachrichten über die normale Megolm-Session, entschlüsselt sie mit
seinem Device Key und archiviert sie Escrow-verschlüsselt in PostgreSQL. Element zeigt korrekt
das Schloss-Icon - die Verschlüsselung ist technisch echt.

**Vorteile:**
- Matrix-protokollkonform, funktioniert mit allen Standard-Clients ohne Anpassung
- Transparent für Nutzer (Bot in Mitgliederliste sichtbar)
- Passt zur bestehenden `compliance_officer`-Rolle
_Source: `README.md`, §Current Limitations (No End-to-End Encryption); `memory/project_e2ee_direction.md` (Server-side decryption model - Managed E2EE); Story 9-11 Dev Notes_

**Offene Punkte vor Implementierung:**
- Bot-Device-Key-Management (Generierung, Rotation, Backup)
- Cross-Signing-Strategie, damit Element keine "unverifizierte Geräte"-Warnung zeigt
- Verhalten bei Bot-Ausfall (Nachrichten gehen durch, Archivierung pausiert)
- Rechtliche Kommunikationspflicht gegenüber Nutzern je nach Jurisdiktion

## Entscheidung

**E2EE wird zurückgestellt.** Die Implementierung erfolgt, sobald:

1. Matrix-seitige E2EE-Anforderungen (`e2ee_required`) den Compliance-Bot-Flow stabilisiert haben
2. FTS (Full-Text Search, ADR-010) und Spaces implementiert sind

Option 3 (Compliance-Bot) bleibt der präferierte Ansatz für eine spätere Phase.

Die E2EE-Stubs bleiben unverändert in Betrieb. Epic 10 ruht bis zur Wiederaufnahme.

## Konsequenzen

- Keine neuen E2EE-Implementierungsarbeiten bis zur Wiederaufnahme
- `room_keys/*` ist seit `server-side-key-backup` (2026-10-30) ein opaker Schlüssel-Backup-Speicher
  (kein Stub, kein E2EE, siehe Update oben); `keys/device_signing/upload` bleibt aktiv; `keys/upload`/`keys/query`/
  `devices` sind seit `fix-device-key-registration` (2026-06-26) ein funktionierendes
  Geräteschlüssel-Verzeichnis (kein E2EE — siehe Kontext-Update oben)
- Der Server erzwingt aktiv das No-E2EE-Invariant: `m.room.encryption` wird in allen Schreibpfaden
  abgelehnt/übersprungen (State-PUT, `createRoom` `initial_state`, Room-Upgrade)
- Option 3 (Compliance-Bot) wird als nächster Evaluierungsschritt aufgegriffen, wenn die unter
  "Entscheidung" genannten Voraussetzungen erfüllt sind
- Policy-based Encryption at Rest (unabhängig von E2EE) bleibt als eigenständige Option offen
- Hinweis (epic oauth-broker, 2026-10-13): Die Ablehnung verschlüsselter Räume (`m.room.encryption`) darf erst aufgehoben werden, wenn die Story `device-lists-changed-on-deletion` (Gate (s): `device_lists.changed` bei jeder Geräte-Löschung, `docs/stories/oauth-broker/follow-ups.md`) umgesetzt ist; sie ist derzeit Backlog, weil ohne verschlüsselte Räume kein Peer an ein Gerät verschlüsselt. Ebenso darf kein Release E2EE bewerben, solange sie offen ist.

_Entscheidungsdatum: 2026-05-08_
_Source: `README.md`, §Current Limitations (No End-to-End Encryption); `memory/project_e2ee_direction.md` (Server-side decryption model - Managed E2EE); Story 9-11 Dev Notes_
