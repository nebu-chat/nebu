# Session 2026-06-26 (b) — device_id ↔ Geräteschlüssel vs. Recht-auf-Vergessen-Key

Phil wollte "eine device_id / ein Schlüssel pro User" erzwingen, um den Schlüssel fürs
Recht-auf-Vergessen (PRD) zu nutzen. Das beruht auf einer Verwechslung zweier verschiedener Schlüssel.

## Spec-Befunde (CS v1.18)

### device_id ↔ Geräteschlüssel = 1:1 pro Gerät, Client-besessen
- §Device keys (Z.36391): "Each device should have one Ed25519 signing key. This key should be
  generated on the device ... the private part of the key should never be exported from the device."
- Client generiert das Geräteschlüsselpaar lokal, lädt nur den ÖFFENTLICHEN Teil via /keys/upload.
  Der Server sieht NIE den privaten Geräteschlüssel.
- §Device ID allocation (Z.10105): device_id ist pro-Gerät; OAuth2/MSC3861 → Client allokiert sie
  ("10 character string ... unique per user" ⇒ viele pro User).

### "Eine device_id pro User" bricht (Spec)
- §Relationship between access tokens and devices (Z.4306): "If the client sets the device_id, the
  server will invalidate any access and refresh tokens previously assigned to that device." ⇒ gleiche
  device_id wiederverwenden = jede neue Anmeldung killt die vorige Session. Nur EIN Gerät gleichzeitig.
- /keys/upload device_keys.device_id "Must match the device ID used when logging in" → zwei physische
  Geräte mit derselben device_id überschreiben gegenseitig ihre publizierten Schlüssel (PK (user,device)).
- to-device / OTK-claim / GET /devices / Logout werden mehrdeutig bzw. sinnlos.

### Geräteschlüssel ≠ Recht-auf-Vergessen-Key
- Privater Geräteschlüssel liegt NIE auf dem Server ⇒ server-seitige PII-Verschlüsselung /
  kryptografische Löschung damit unmöglich. Falscher Schlüssel.
- Recht-auf-Vergessen braucht einen serverseitig gehaltenen, löschbaren per-User-Privatschlüssel.

## Nebu-Realität (Codebase verifiziert)
- ADR-007 / Tabelle `user_keys`: per-User Ed25519 (signing) + X25519 (encryption), serverseitig, beim
  OIDC-Provisioning erzeugt. `user_deletion.ex` setzt private_key=NULL → kryptografische Erasure.
  DAS ist der Recht-auf-Vergessen-Key, EINER pro User, bereits implementiert & verdrahtet.
- Davon völlig getrennt: Matrix-Geräteschlüssel-Verzeichnis (Tabelle device_keys, /keys/upload/query).

## PRD-Mapping
"Ein Ed25519-Keypair pro User für Signing + PII" = (c) Nebu-interner serverseitiger per-User-Key
(user_keys), NICHT der Matrix-Geräteschlüssel und NICHT der Cross-Signing-Master-Key. ADR-007 verfeinert
korrekt in ZWEI Keys (Ed25519 signiert, X25519 verschlüsselt — Ed25519 kann nicht verschlüsseln).

## Empfehlung
device_id/Geräteschlüssel NICHT auf "einer pro User" erzwingen — Matrix-Multi-Device-Modell behalten,
Recht-auf-Vergessen über den separaten per-User user_keys-X25519-Key (ADR-007) lösen. Phils "stets
gleiche device_id"-Wunsch (Login mintet aktuell jedes Mal eine neue) ist ein echtes Device-Proliferation-
Thema, aber die Lösung ist stabile device_id PRO CLIENT (Client darf seine wiederverwenden), nicht eine
pro User.
