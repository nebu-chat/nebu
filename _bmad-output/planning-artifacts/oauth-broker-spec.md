# Nebu als OAuth-2.0-Authorization-Server (Broker-Modell, "O2")

Status: **Entwurf, Revision 2** (2026-10-07). Kein ADR, keine Story. Grundlage: Matrix Client-Server API v1.19
(Abschnitt "OAuth 2.0 API", ab v1.15), MSC2964/2965/2966/2967/4191, RFC 6749/7591/7636/7009/8414/9700.
Revision 2 arbeitet das Oracle-Review (2026-10-07) und die ersten Entscheidungen von Phil ein (Abschnitt 14).
Kennzeichnung: **[V]** am Spec-/Client-Quelltext durch das Oracle verifiziert, **[A]** Annahme, **[ungeprüft]** nicht
im Code geprüft.

## 1. Warum

1. **Legacy-Laufzeit unklar.** Die Spec koexistiert beide APIs ("A homeserver may support one of those two APIs, or
   both") und nennt kein Entfernungsdatum. Neue Features und Client-Entwicklung wandern aber zur OAuth-API.
2. **Refresh wird Standard.** Heute baut Nebu mit `/refresh`, Hintergrund-Worker und JWT-Fallback drei Sonderpfade.
   OAuth hat genau einen: `grant_type=refresh_token`.
3. **Der Corporate IdP kennt nur Nebu.** Matrix-Clients registrieren sich per Dynamic Client Registration bei Nebu,
   nicht beim IdP. Der IdP braucht einen einzigen Client (Nebu), keine Scopes `urn:matrix:*`, kein DCR.
4. **Hebel für später:** eigene Client-Policies, Geräteverwaltung, Client-Zertifikate (siehe 9).

## 2. Rollen

```
Matrix-Client ──OAuth 2.0 (Nebu-Metadaten)──▶ Nebu (Authorization Server + Resource Server)
                                                   │  OIDC Authorization Code + PKCE (heutiger sso_login-Pfad)
                                                   ▼
                                           Corporate IdP (Keycloak/Entra/Dex): nur Identitätsquelle
```

Nebu bleibt gegenüber dem IdP OIDC-Client. Passwörter, MFA und Benutzerverwaltung bleiben beim IdP. Neu ist, dass Nebu
gegenüber den Matrix-Clients als Authorization Server auftritt. Das ist das Modell der Matrix-Spec (Homeserver stellt
Tokens aus). Ein Direktbetrieb gegen den IdP (O1) ist nur über MSC3861-Delegation mit einem MAS-artigen Dienst vorgesehen.

**Nur Nebu stellt Tokens aus.** Heute akzeptiert `OidcPlug` auch rohe IdP-JWTs als Access-Token [V]. Im Broker-Modell
gilt dieser Pfad nur noch für Legacy-Sessions (Phase 5). OAuth-Sessions kennen ausschließlich opake Nebu-Tokens, sonst
bleibt ein zweiter Weg zum Resource Server offen [A].

## 3. Endpunkte

| Endpunkt | Pfad (Vorschlag) | Spec | Auth |
|---|---|---|---|
| Metadaten | `GET /_matrix/client/v1/auth_metadata` (+ `unstable/org.matrix.msc2965`) | MUSS | keine |
| Registrierung | `POST /oauth2/register` | RFC 7591, Pflichtfeld der Metadaten [V] | keine, Policy siehe 4 |
| Authorize | `GET /oauth2/authorize` | RFC 6749 4.1 | Browser, delegiert an IdP |
| IdP-Callback | `GET /oauth2/callback` | intern | Browser |
| Token | `POST /oauth2/token` | `authorization_code`, `refresh_token` | `client_id`, Auth-Methode `none` |
| Revocation | `POST /oauth2/revoke` | RFC 7009, Pflichtfeld der Metadaten [V] | **keine Client-Auth** (siehe 7) |
| Device Authorization (optional, Phase 7) | `POST /oauth2/device` | RFC 8628, v1.18 | Client |
| Account Management | `GET /account` | v1.18 SHOULD, für OAuth-aware-Clients faktisch nötig [V] | Browser-Session |

**Entfernt:** `auth_issuer`. Er steht nicht in Spec 1.19 (MSC2965 führt ihn nur als verworfene Alternative) [V].
Der heutige Endpunkt liefert den IdP-Issuer und würde ältere Clients direkt zum IdP schicken. Entweder entfernen oder
auf den Nebu-Issuer umstellen, Entscheidung in der Story "Metadaten".

`issuer` MUSS `https` ohne Query/Fragment sein und ist die öffentliche Nebu-URL, **nicht** der IdP-Issuer. Das ersetzt
die Passthrough-Logik in `HttpPublic.auth_metadata/1` und `OidcMetadata`.

Pflichtfelder der Metadaten [V]: `issuer`, `authorization_endpoint`, `token_endpoint`, `revocation_endpoint`,
`registration_endpoint`, `response_types_supported` (min. `code`), `grant_types_supported` (min. `authorization_code`,
`refresh_token`), `response_modes_supported` (min. `query`, `fragment`), `code_challenge_methods_supported` (min. `S256`).
Optional: `prompt_values_supported` (`create`), `account_management_uri`, `account_management_actions_supported`,
`device_authorization_endpoint`, `authorization_response_iss_parameter_supported` (nötig, sobald `iss` mitgesendet wird [A]).

**Discovery bei abgeschaltetem OAuth:** `404 M_UNRECOGNIZED`, nicht 503 und kein Passthrough [V]. Das Dart-SDK
unterscheidet nur diesen Fall. **Caching:** `Cache-Control` setzen, das Dart-SDK cacht die Metadaten 3 Tage [V].

## 3a. Sichtbarkeit für Clients: `/versions` und Scopes

- **`/versions` (final, nach Pflichten-Audit):** Nebu meldet heute bis v1.11 [V]. Das Dart-SDK 13 ruft `auth_metadata`
  nur ab v1.15 auf [V]. Ein nicht konformes `auth_metadata` unter v1.15 zu melden wäre unehrlich und bricht Clients.
  **Regel:** `/versions` enthält v1.12 bis v1.15 **genau dann**, wenn die Instanz OAuth konform anbietet (Betreiber-Schalter
  `oauth_enabled`). Aus: v1.11 und `auth_metadata` antwortet 404 `M_UNRECOGNIZED`. Die Umschaltung ist der **letzte**
  Schritt des Epics. Vorbedingungen aus dem Audit (alle [V]):
  1. Media (**Befund nach Oracle-Verifikation korrigiert**): PDF wurde nicht als octet-stream ausgeliefert (`application/pdf`
     stand in der Inline-Liste). Echte MUST-Verstöße waren: Content-Type-Umschreibung auf octet-stream für alle nicht
     allowlisteten Typen (audio/mp4, video/quicktime, zip, heic), nie ausgelieferter Upload-Dateiname, Thumbnail-Fehletikett
     (Nicht-Bilder als image/png). Behoben in Branch `bugfix/media-response-content-type` (Commit `cfe68da8`). Aufwand war M.
  2. `/sync` Raum-Account-Data (**Befund nach Oracle-Verifikation korrigiert**): Das ist KEINE v1.12-MUST-Verletzung. Nebu
     meldet v1.12 nicht an, und Client Config / Read and Unread Markers / Room Tagging sind in allen Feature-Profilen
     optional. Es ist ein Feature-Gap (Client Config nur im globalen Scope) mit hoher Client-Wirkung plus zwei echte
     MUST-Verstöße: globaler PUT nahm `m.fully_read`/`m.push_rules` an (MUST 405) und `POST /read_markers` war ein No-op.
     Behoben in Branch `bugfix/sync-room-account-data` (Raum-Account-Data, 405-Regel, read_markers, per-Gerät-Sync-Position).
     Tags (`m.tag`) sind ein eigener Folge-Schritt. Wichtig: **kein harter Blocker für `/versions` v1.15.**
  3. `auth_metadata` konform (der Kern dieses Epics, Aufwand L).
  4. **Room Summaries (Oracle-Korrektur Story 9):** `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` ist seit v1.15 Kern, nicht optional, und fehlt (room_summary): Follow-up (ac), **Gate vor `oauth_enabled`** und vor jedem Release, das v1.15 beansprucht; (af) `M_UNRECOGNIZED` für unbekannte Pfade kommt mit.
  5. Push Notifications ist im Mobile-Profil Pflicht: Push-Rule-Schreibzugriffe fehlen (vorbestehend, (ad), nicht gating); ebenso `/user_directory/search` und `/publicRooms` (Kern, vorbestehend, (ad)).
  Nicht anwendbar oder optional (keine Lücke): Reporting (`/rooms/{id}/report`, `/users/{id}/report`),
  `M_USER_LOCKED`/`M_USER_SUSPENDED`, `via`/`server_name`, Gäste, `dont_notify`/`coalesce` (Push-Regeln sind Stub).
  Empfehlung, nicht Pflicht: unbekannte Endpunkte mit `M_UNRECOGNIZED` statt `M_NOT_FOUND` beantworten
  (`protected.ex:1309`), Clients erkennen Features daran. Reporting wäre für den Compliance-Fokus sinnvoll (separat).
- **`unstable_features`:** `org.matrix.msc2964/2965/2966/3861` **nicht** setzen. Sie sind seit v1.15 stabil, Clients
  entdecken OAuth über `auth_metadata` ohne Flag [V/A]. MSC3824 ist kein `unstable_features`-Eintrag, sondern ein Feld am
  `m.login.sso`-Flow in `GET /login` (siehe unten).
- **Scope-Präfixe:** Dart-SDK 13 sendet *nur* `urn:matrix:org.matrix.msc2967.client:api:*` und
  `urn:matrix:org.matrix.msc2967.client:device:<id>`, das js-SDK nur die stabilen `urn:matrix:client:...` [V]. Nebu
  akzeptiert beide Präfixe und gibt in `scope` **das Präfix des Requests** zurück. Intern wird normalisiert.
- **`oauth_aware_preferred`:** `login_flows` setzt es heute nicht [V]. Das stabile Feld gibt es erst ab v1.18, unstable
  `org.matrix.msc3824.delegated_oidc_compatibility`: beide setzen, aber nur wenn OAuth konform läuft [V/A]. Das js-SDK liest zusätzlich
  `org.matrix.msc3824.delegated_oidc_compatibility`, beide Felder setzen [V]. Der `action`-Parameter am SSO-Redirect
  wird heute nicht ausgewertet (`sso_login.ex`) [V].
- **Fehlerformat:** OAuth-Fehler dürfen **kein** `errcode` enthalten, das js-SDK prüft zuerst darauf [V].

## 4. Client-Registrierung (DCR)

**Entscheidung: Registrierung offen, Nutzung nach Admin-Freigabe.** Die Spec verlangt, dass sich Clients bei **jedem**
Flow neu registrieren, und `registration_endpoint` ist Pflicht. Ein Modus ohne DCR ist nicht spec-konform [V].

- `POST /oauth2/register` legt die Registrierung immer an (`201`) mit Status `pending` oder `approved`.
- **Freigabe pro Metadaten-Hash**, nicht pro `client_id`. Identische Registrierungen werden dedupliziert und teilen
  sich eine Freigabe. Sonst müsste jedes Gerät einzeln freigegeben werden.
- Ein Client mit Status `pending` scheitert am Authorize-Schritt mit einer verständlichen Hinweisseite (kein Redirect
  an die Client-URI, RFC 6749 4.1.2.1 [A]).
- Admin-UI: Liste offener Registrierungen mit `client_name`, `client_uri`, Redirect-URIs, Logo, Freigeben/Ablehnen,
  optionale Vorab-Freigabe (Allowlist-Muster, z. B. `client_uri`-Host oder Native-Scheme).
- Betreiber-Schalter, um auf `auto_approve` (offen) oder `allowlist_only` zu stellen. Default: Freigabe nötig.

Pflichtvalidierung (Spec, MUST) [V]:
- `web`: `https`, kein userinfo, Host unter `client_uri`-Basis, kein Fragment.
- `native`: Private-Use-Scheme in Reverse-DNS des `client_uri`-Hosts ohne Authority, **oder** `http` auf
  `localhost`/`127.0.0.1`/`[::1]` ohne Port (jeder Port wird beim Flow akzeptiert), **oder** Claimed-HTTPS wie `web`.
- Strikter Exact-Match der Redirect-URI beim Authorize (Ausnahme Loopback-Port).
- `token_endpoint_auth_method=none` MUSS unterstützt werden. `application_type` `web`/`native` MUSS unterstützt werden,
  Default `web`.
- Unbekannte `response_types`/`grant_types` **ignorieren**, nicht ablehnen. Antwort enthält nur Unterstütztes.
- `client_uri` ist laut Schema Pflicht: `https`, kein userinfo, Server MAY ablehnen, wenn es fehlt.
  `logo_uri`/`tos_uri`/`policy_uri`: `https`, Host oder Subdomain von `client_uri`.
- **MUST NOT** Registrierungen mit aktiver Session löschen. Aufräumen nur für Registrierungen ohne Session.
- Deduplizierung ist eine Spec-Empfehlung (Hinweis-Box), hier aber Teil des Freigabemodells.

Speicher: Tabelle `oauth_clients` (inline SQL, ADR-018) mit `status`, `metadata_hash`, `approved_by`, `approved_at`.
Rate-Limit auf `register`.

## 5. Authorization-Flow

1. **Authorize-Request** validieren: `response_type=code`, bekannte und **freigegebene** `client_id`, `redirect_uri`
   exakt, `code_challenge` mit `S256` **Pflicht**, `state`, `response_mode` in `{query, fragment}`.
   **`fragment` wird für Clients mit https-Redirect-URI erzwungen** (MUST) [V].
   `scope` MUSS genau **ein** `device:<id>`-Token enthalten (MUST). `api:*` ist ebenfalls zu verlangen, ist aber laut
   Spec kein eigenes MUST [V]. Beide Scope-Präfixe siehe 3a.
   Die `device_id` braucht einen **eigenen Scope-Validator**: nur Zeichen `%x21 / %x23-5B / %x5D-7E` (RFC 6749 3.3).
   `Nebu.Matrix.DeviceId.valid?/1` prüft nur ≤255 Byte und Steuerzeichen und lässt `"`, `\` und Nicht-ASCII zu [V].
   Empfehlung der Spec: `[A-Za-z0-9._~-]`, mindestens 10 Zeichen; der Server DARF Kürzeres ablehnen.
   **Wiederverwendung einer Device-ID** ist erlaubt, wenn das Gerät demselben User gehört. Dann werden alle bisherigen
   Access- und Refresh-Tokens des Geräts **widerrufen** [V].
2. **Delegation an den IdP:** Request in `oauth_authz_requests` (TTL kurz, einmalig) speichern, Browser zum IdP
   (bestehender `SsoLogin`-Pfad: PKCE, Nonce, Scope-Auflösung per `OidcScopes`, `offline_access` je nach
   `matrix_oidc_refresh_mode`). `prompt=create` nur weiterreichen, wenn der IdP es unterstützt.
3. **IdP-Callback:** `id_token` per `OidcPlug.verify_token` prüfen, User provisionieren
   (`TokenValidator.validate`, Deaktivierungsprüfung), IdP-Refresh-Token verschlüsselt (`SecretBox`) merken.
4. **Nebu-Code ausstellen:** zufällig, einmalig, TTL höchstens 60 s, gebunden an `client_id`, `redirect_uri`,
   `code_challenge`, `device_id`, User. Redirect an den Client mit `state` und `iss` (RFC 9207).
5. **Token-Request** (`authorization_code`): `code_verifier` gegen `code_challenge` prüfen, Redirect-URI identisch.
   Antwort: `{access_token, token_type: "Bearer", expires_in, refresh_token, scope}`.
   Fehler nach RFC 6749 5.2, **nicht** als Matrix-Fehlerobjekt (kein `errcode`).

Code-Wiederverwendung führt zum Widerruf der aus ihm entstandenen Session (RFC 9700).

## 6. Tokens und Refresh

- **Access Token:** opak (64 Hex), **15 Minuten** (Entscheidung), konfigurierbar. Gespeichert wird nur ein **Hash**
  (siehe 11). Gesamtdauer der Session siehe unten.
- **Refresh Token:** MUSS bei jedem Grant ausgestellt werden. Rotation bei jeder Nutzung (SOLL).
- **Refresh-Retry (Korrektur):** Der alte Refresh-Token **bleibt gültig, bis das neue Token benutzt wird** (erster
  erfolgreicher Request mit dem neuen Access-Token oder erneuter Refresh damit) [V]. Ein festes 60-s-Fenster ist
  **nicht** spec-konform, weil der Client bei Netzfehler/5xx später mit dem alten Token wiederholt. Erst nach Nutzung
  des neuen Tokens gilt der alte als verbraucht. Wird ein **verbrauchter** Token erneut vorgelegt, gilt die Session als
  kompromittiert und wird widerrufen (SOLL).
  Dieselbe Abweichung steckt im Legacy-Code `matrix_session_store.ex` (Kommentar beruft sich fälschlich auf die Spec).
- **Refresh gegen den IdP:** Betreiber-Schalter `idp_revalidation = per_refresh | off`, **Default `per_refresh`**
  (Entscheidung). `per_refresh` löst den gespeicherten IdP-Refresh-Token bei jedem Nebu-Refresh ein (heutiges
  `revalidate_with_idp/1`). So wirkt Deprovisionierung spätestens nach einer Access-Token-Lebensdauer. `off` verlängert
  nur bis zum Nebu-Maximum und braucht keinen IdP-Refresh-Token (IdPs ohne `offline_access`).
- **Fehlerabbildung am Token-Endpoint** (Spec: `5xx`/Netz → Client wiederholt später, `4xx` → Client wertet als
  ausgeloggt) [V]:
  - Transienter IdP-Fehler (Netz, 5xx, 429), DB-Fehler: **`503` mit `Retry-After`**, Session bleibt.
  - Bestätigte IdP-Ablehnung, deaktivierter User, Reuse: `400 invalid_grant`, Session widerrufen.
  - **Kein `429` auf `grant_type=refresh_token`**: es loggt Clients aus. Drosselung als `503` + `Retry-After` [V].
- **Gesamtdauer:** Nebu-eigenes Session-Maximum (heute `NEBU_MATRIX_SESSION_TTL_SECONDS`), unabhängig vom IdP.
- **Abgelaufener Access Token** am Resource Server: `401 M_UNKNOWN_TOKEN` mit `soft_logout: true` (Spec: "preferably")
  [V], damit Clients refreshen.
- **Account-Sperre:** Nebu hat keine (`M_USER_LOCKED` entfällt) [V]. Falls später eingeführt: `/logout` und
  `/logout/all` bleiben frei, Tokens werden nicht invalidiert (Spec 1.12).
- **Hintergrund-Worker:** für OAuth-Sessions nicht nötig und nicht erlaubt, der Client refresht selbst.

## 7. Revocation und Logout

`POST /oauth2/revoke` (RFC 7009). `client_id` ist optional, bei fehlender oder falscher `client_id` SOLL der Server
trotzdem widerrufen, **keine Client-Authentisierung voraussetzen** [V]. Es MUSS Access- **und** Refresh-Token der
Session widerrufen werden [V]. Antworten: `200` auch bei unbekanntem Token, `401` bei fehlender Berechtigung, `400` bei
sonstigen Fehlern. Das Dart-SDK widerruft per Access-Token, der **abgelaufen** sein kann. Der Lookup muss daher auch
abgelaufene Access-Tokens einer Session finden [A]. Widerruf löscht die ganze Session inkl. IdP-RT. `POST /logout` und
`/logout/all` bleiben und rufen dieselbe Funktion auf.

## 8. Koexistenz mit Legacy

- Die Spec verlangt: Clients nutzen nach dem Login nur die API, mit der sie ihr Token bekamen ("mutually incompatible").
  Jede Session trägt `auth_api = legacy | oauth`. Legacy-Sessions lassen sich **nicht** nach OAuth migrieren, ein
  Auslaufen erzwingt Re-Login [V].
- **OAuth-aware-Kompatibilität (v1.18)**: gilt nur "für einen Homeserver, der OAuth-aware Clients unterstützen will",
  nicht für jeden OAuth-Server. Dann MUSS er: OAuth-API, `m.login.sso`, `oauth_aware_preferred: true`, `action`-Parameter
  am SSO-Redirect. `m.login.password` nur falls früher aktiv, bei Nebu nicht relevant. `account_management_uri`: SHOULD
  [V]. **Nebu wählt diese Kompatibilität**, damit Legacy-only-Clients bedienbar bleiben.
- `/refresh` und der `RefreshWorker` bleiben für Legacy-Sessions. Der Worker-Bug (rotiert Tokens, die der Client nicht
  kennt) wird unabhängig behoben.
- **UIA:** OAuth-Tokens können kein UIA, `m.oauth` ist nur für `/keys/device_signing/upload` zulässig [V].

### UIA-Auswirkungen im Nebu-Code (Oracle) [V]

| Endpunkt | Heute | Für OAuth-Sessions |
|---|---|---|
| `DELETE /devices/{id}`, `POST /delete_devices` | UIA über `uia_gate` (`protected.ex`), nur Stufe `m.login.sso`, frisches `auth_time` ≤900 s umgeht die Abfrage | **Entscheidung: abgelehnt.** Löschen läuft über die Account-Seite (`org.matrix.device_delete`) und widerruft die OAuth-Tokens. Die eigene Session beendet der Client per Revocation. |
| `POST /keys/device_signing/upload` | Erst-Upload und identischer Re-Upload 200, Ersetzen bestehender Keys hart 403 | `401` mit `flows:[{stages:["m.oauth"]}]`, `params["m.oauth"].url` (`account_management_uri?action=org.matrix.cross_signing_reset`, https) und `session`. Nach Freigabe in der Web-UI sendet der Client `auth:{session}`. Ohne das scheitert "Identität zurücksetzen" [A]. |
| `/account/deactivate`, `/account/password`, `/account/3pid/*` | existieren nicht, `m.3pid_changes` ist `enabled:false` | passt zu OAuth-aware-Anforderungen. Deaktivieren nur über Account-Seite oder Admin. |

`auth_time` wird bei OAuth-Sessions beim Login gesetzt (Story 3); eine Re-Auth über die Account-Seite aktualisiert nur die Account-Sitzung, nicht die Token-Zeilen (Story 6, A17) [A].

## 9. Technische Clients und mTLS (außerhalb der Matrix-Spec)

**Entscheidung:** Ziel sind **Bots/Automatisierung, Bridges und Monitoring/Maschinen-Dienste mit Zertifikat**.
Headless/CLI mit Nutzerfreigabe (Device Grant) wurde nicht ausgewählt und bleibt optional (Phase 7).

Die Spec deckt "automated applications" nicht ab. Seit v1.17 dürfen Appservices `/register` unabhängig von der Auth-API
nutzen [V]. Es gibt in Matrix kein `client_credentials`.

| Zielgruppe | Mechanismus | Anmerkung |
|---|---|---|
| Bridges | Application-Service-API (`as_token`/`hs_token`) | Matrix-Standard, **kein OAuth nötig**. Eigener Epic. |
| Bots/Automatisierung | Appservice-Token **oder** mTLS-Client | Bots mit einem Zertifikat ohne Appservice-Registrierung sind eine Nebu-Erweiterung. |
| Monitoring mit Zertifikat | mTLS-Client-Auth (RFC 8705 `tls_client_auth`) am Token-Endpoint, optional zertifikatsgebundene Tokens (`cnf.x5t#S256`) | Nebu-Erweiterung, opt-in pro registriertem Client. |
| Alternative ohne TLS-Terminierungsproblem | `private_key_jwt` (RFC 7523) | Option, falls der Proxy mTLS nicht durchreicht. |

Designvorgabe jetzt: `oauth_clients` führt `token_endpoint_auth_method` und Policy-Felder von Anfang an, Tokens tragen ein
optionales Bindungsfeld. TLS-Terminierung am Reverse Proxy braucht ein Vertrauensmodell für Zertifikat-Header: nur vom
Proxy, immer überschreiben, nie vom Client durchreichen. Solche Clients sind **nicht** per DCR zu registrieren, sondern
vom Admin anzulegen (Phase 8).

## 10. Sicherheitsanforderungen (RFC 9700 / Matrix-Spec)

PKCE `S256` Pflicht, kein Implicit, Exact-Redirect-Match, `state` zurückgeben, Code einmalig + kurz,
Refresh-Rotation mit Reuse-Erkennung, Rate-Limits auf `register`, `authorize`, `token` (am Refresh-Grant als `503`, siehe 6),
DCR-Missbrauchsschutz durch Freigabe (4), keine Tokens/Codes/Verifier in Logs (Gesetz "No Sensitive Data in Logs":
`payload_redactor` um `code`, `code_verifier`, `client_secret`, `device_code` erweitern), IdP-Refresh-Token weiter nur
verschlüsselt, Open-Redirect-Schutz auf dem Callback, CORS nur auf Metadaten/Token/Register/Revoke
(Browser-Clients brauchen sie).

## 11. Datenmodell (Skizze, inline SQL)

- `oauth_clients(client_id PK, metadata jsonb, metadata_hash UNIQUE, application_type, status, approved_by, approved_at, token_endpoint_auth_method, created_at, last_used_at)`
- `oauth_authz_requests(state_id PK, client_id, redirect_uri, code_challenge, device_id, response_mode, scope_prefix, client_state, expires_at)`
- `oauth_codes(code_hash PK, client_id, redirect_uri, code_challenge, device_id, user_id, idp_rt_enc, expires_at, used_at)`
- `matrix_sessions`: neue Spalten `auth_api`, `client_id`, `scope`.
- **Token-Speicherung:** `matrix_sessions` speichert `access_token`/`refresh_token` heute im **Klartext** (Lookup
  `WHERE access_token = $1`) [V]. Für OAuth-Sessions werden nur **Hashes** gespeichert (Lookup per Hash).
  Ob die Legacy-Tabelle migriert wird, ist offen (Migration, Rollout-Risiko).

Atomare Verbrauchsoperationen (`UPDATE ... WHERE used_at IS NULL`) wegen Cluster-Safety (ADR-020).
Migration unter `server/priv/migrations/` (pipeline-geschützt).

## 12. Auswirkungen auf bestehende Entscheidungen

- **ADR-022** (Bootstrap-only OIDC): bleibt für den Upstream gültig. Nebus eigene AS-Konfiguration ist keine
  IdP-Konfiguration und braucht keine `NEBU_OIDC_*`-Variablen.
- **ADR-015/019/020/021/018:** unberührt.
- **Neuer ADR nötig:** "Nebu ist Authorization Server (Broker)". Die Aussage in der nebu-app-Commit-Message `cbee0e90f`
  ("not to act as its own OIDC auth server") wird damit überholt.
- Client: `enableMatrixNativeOIDC` in der nebu-app kann dann aktiviert werden. Element Web/X mit `oidc_static_clients`
  nicht im Code geprüft [ungeprüft].

## 13. Vorgeschlagene Schnitte (Epic `oauth-broker`)

| # | Story | Ergebnis |
|---|---|---|
| 0a | Bugfix: Media Content-Type + Dateiname + Thumbnail (v1.12 MUST) — **erledigt** (`bugfix/media-response-content-type`) | Vorbedingung für v1.15 |
| 0b | Bugfix: Raum-Account-Data, 405 für `m.fully_read`/`m.push_rules`, read_markers — **erledigt, Commit folgt** (`bugfix/sync-room-account-data`); Tags als Folge-Story | kein v1.15-Blocker (optionales Modul), aber hohe Client-Wirkung |
| 0c | Bugfix: Worker-Bug, Refresh-Retry-Semantik (**erledigt**, `bugfix/matrix-session-refresh`), Token-Hashing `matrix_sessions` (**erledigt**, `bugfix/token-hashing-matrix-sessions`, stapelt auf 0c-1) | Vorarbeit, gleiche Tabelle |
| 1 | Metadaten + DCR + Admin-Freigabe | Clients sehen Nebu als AS, Admin gibt frei. Noch kein Login. |
| 2 | Authorize + IdP-Delegation + Code (beide Scope-Präfixe) | Login-Flow bis zum Code. |
| 3 | Token-Endpoint (code + refresh), Rotation/Reuse, Fehlerabbildung | Funktionierende Sessions, `/whoami` ok. |
| 4 | Revocation + Logout-Integration | Sauberes Beenden. |
| 5 | Legacy-Koexistenz (`oauth_aware_preferred`, `action`, `auth_api`, UIA-Abgrenzung) | Beide Welten parallel. |
| 6 | Account-Management-Seite (`devices_list`, `device_delete`, `cross_signing_reset`) + `m.oauth`-UIA | v1.18-Deep-Links. |
| 7 | Optional: Device Grant | Headless-Clients. |
| 8 | mTLS / `private_key_jwt` für Maschinen-Clients (Admin-angelegt) | Monitoring u. a. |
| 9 | `/versions` auf v1.15+ umschalten (`oauth_enabled`), `oauth_aware_preferred` setzen | **Letzter** Schritt, erst wenn 1 bis 6 konform. |
| 10 | Appservice-API für Bridges (eigener Epic, kein OAuth) | Bridges. |

Außerhalb des Epics, aber nötig: **Bugfix** Refresh-Retry-Semantik und `RefreshWorker` im Legacy-Pfad
(`/nebu-pipeline --bug`).

## 14. Entscheidungen und offene Fragen

**Entschieden (Phil, 2026-10-07):**
1. DCR: offen, Nutzung nach Admin-Freigabe pro Metadaten-Hash.
2. Access-Token 15 Minuten. IdP-Revalidierung konfigurierbar, Default `per_refresh`.
3. `/versions` per Betreiber-Schalter pro Instanz.
4. Geräte löschen für OAuth-Sessions nur über die Account-Seite.
5. Technische Clients: Bots/Automatisierung, Bridges, Monitoring mit Zertifikat.

**Von der Spec festgelegt (keine Wahl):** Account-Seite braucht mindestens `devices_list` und `device_delete`
(`cross_signing_reset`, wenn `m.oauth` umgesetzt wird); Legacy-Sessions lassen sich nicht migrieren.

**Ebenfalls entschieden (Phil, 2026-10-07, 2. Runde):**
6. **Legacy:** beide APIs laufen **voll parallel**, bis eine der beiden abgekündigt wird. Kein Legacy-Opt-in-Schalter
   (Korrektur der Runde 2: "OAuth Default, Legacy Opt-in" gilt **nicht**). OAuth-aware-Kompatibilität (`m.login.sso` mit
   `oauth_aware_preferred: true`) bleibt immer aktiv, Legacy-only-Clients bleiben bedienbar. OAuth-fähige Clients wählen
   OAuth, weil Nebu `auth_metadata` anbietet.
7. **`auth_issuer`:** wird auf den Nebu-Issuer umgestellt (nicht entfernt). Antwort `{ "issuer": "<Nebu-URL>" }`, wenn
   OAuth aktiv ist. **Korrigiert (Phil, 2026-10-09):** Ist OAuth aus, bleibt der heutige IdP-Passthrough bestehen
   (kein Verhaltenswechsel fuer bestehende Deployments, Element/FluffyChat); es gibt dann KEIN 404. Das stabile
   `v1/auth_metadata` bleibt bei OAuth aus 404 `M_UNRECOGNIZED`. Ist die Konfiguration nicht lesbar, wird nicht auf
   den IdP zurueckgefallen (Kassandra N-4).
8. **Token-Hashing:** wird **auch für Legacy-Sessions** migriert (`matrix_sessions`), da nur eine Instanz im Feld ist.
   Alle bestehenden Sessions werden dabei entweder gehasht übernommen oder ungültig gemacht (Re-Login), je nach
   Migrationsweg. Kein Rolloutproblem erwartet.
9. **Maschinen-Clients:** mTLS ist der Standardweg für Bots/Monitoring (bestätigt), wird aber **vorbereitet, nicht
   umgesetzt** (Datenmodell, Hooks). Es fehlt noch eine einfache **CA im Setup** (Ausstellung/Widerruf von
   Client-Zertifikaten, Vertrauensanker am Reverse Proxy). Appservice-Token für Bridges bleiben eigener Epic.
10. **Pflichten-Audit v1.11 bis v1.15:** erledigt (Oracle), Ergebnis in 3a.

**Folgerungen:**
- `/versions` meldet v1.15+, sobald die Instanz OAuth anbietet. Der Betreiber-Schalter aus Punkt 3 bleibt als
  Rückfalloption (OAuth aus = Zustand von heute).
- Es gibt **keinen** `legacy_login_enabled`-Schalter. Wird eine API abgekündigt, entsteht der Schalter dann.
- Die Hash-Migration von `matrix_sessions` und der Refresh-Retry-Fix ändern dieselbe Tabelle/Logik. Sinnvoll als ein
  Bugfix/Vorarbeits-Schritt vor Story 1.
- Die CA für mTLS ist Teil von Story 8 (nur Vorbereitung im Epic).

**Offen:** nichts Grundsätzliches. Zur Bestätigung durch Phil: die Reihenfolge der Stories (0a bis 0c vor Story 1,
`/versions`-Umschaltung zuletzt) und ob 0a/0b/0c als `/nebu-pipeline --bug` oder als Teil des Epics laufen.
