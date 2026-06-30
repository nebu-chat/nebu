---
name: security-rules
description: Nebu Security-Review-Scope für SEC Gate 1 und Gate 2. Für nebu-kassandra.
  OWASP Top 10 + STRIDE + CWE-Fokus.
---

# Security Review Scope

## Scope (identisch für SEC Gate 1 + Gate 2)

Jeder Security-Review prüft diese Kategorien — vollständig, keine Ausnahmen:

### Injection

- **SQL Injection** — dynamische SQL-String-Interpolation mit Usereingaben
- **Path Traversal** — unkontrollierte Dateipfadkonstruktion

### Web-Sicherheit

- **XSS** — unsanitisierte Usereingaben in HTML-Templates (HEEx/EEx)
- **CSRF** — State-changing Endpoints ohne CSRF-Token (Phoenix-Forms haben es, Plain-Plug-Endpoints ggf. nicht)
- **Open Redirects** — `redirect(conn, to: user_controlled_url)`
- **Fehlende Security-Headers** — CSP, X-Frame-Options, HSTS

### Auth / Identität

- **Auth Bypass** — fehlende Middleware in Router-Pipelines, IDOR
- **JWT-Validierung** — alg-confusion (HS256 vs RS256), fehlendes `exp`/`aud`/`nonce`-Check
- **Timing Attacks** — nicht-konstante Vergleiche für Secrets (`:crypto.hash` vs `Plug.Crypto.secure_compare`)

### Ressourcen

- **Fehlende Body-Size-Limits** — Plug.Parsers ohne `:length`-Option
- **Fehlende Rate-Limits** — öffentliche Endpoints ohne `hammer` oder äquivalent

### Krypto

- **Schwache Primitiven** — `md5`, `sha1`, `DES` für sicherheitskritische Operationen
- **Klartext-Secrets in Logs** — `Logger.debug(inspect(conn))` mit Token-Daten

## Severities

- **CRITICAL** — Sofortiger Block; blockiert Commit und Epic-Abschluss
- **HIGH** — blockiert je nach `blocking_severity`-Setting (default: nur CRITICAL)
- **CLEAN** — keine CRITICAL/HIGH Findings

## Pflicht-Artefakt

Auch bei 0 Findings muss ein Report geschrieben werden:
`docs/stories/<epic>/security-reports/<story-id>-security-review-<date>.md`

Das ist eine unveränderliche Audit-Trail-Anforderung.

## Auto-Klassifikation (falls `security_review:` fehlt)

Automatisch `required` wenn staged diff berührt:
- `server/lib/nebu/web/` (plugs, router, auth)
- `server/lib/nebu/admin/`
- `server/lib/nebu/matrix/{signature,permissions,session}/`
- `server/lib/nebu/application.ex` (Bandit/Router-Wiring)
- `server/priv/migrations/` (neue SQL-Migrations)
- Elixir-Code der `:crypto` oder externe Inputs verwendet
