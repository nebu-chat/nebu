## Code Review — bug-fix-element-login (cycle 0)

### MAJOR-1: Email silently empty for new users — no operator migration warning
**Location:** `server/lib/nebu/web/plugs/oidc_plug.ex:206`, `server/lib/nebu/matrix/session/user_provisioner/postgres.ex:35`
Without `email` in `@base_scopes`, Keycloak will not include the `email` claim. `claims["email"] || ""` silently becomes `""` and gets stored as the encrypted email for every first-time login. No warning is logged. Recommended fix: add `Logger.warning` when email claim is absent during user provisioning.

### MINOR-2: Stale `@moduledoc` in `sso_login.ex` still describes old scope list
**Location:** `server/lib/nebu/matrix/sso_login.ex:32`
"The scope list is `openid profile email offline_access`..." — `profile` and `email` are no longer base scopes.

### MINOR-3: Stale inline comment on line 303 — old scope header
**Location:** `server/lib/nebu/matrix/sso_login.ex:303`
`# ── scope list (openid profile email [+offline_access] + NEBU_OIDC_EXTRA_SCOPES)` should drop `profile email`.

### MINOR-4: Stale comment line 422–424 claims `offline_access` is in `@base_scopes`
**Location:** `server/lib/nebu/matrix/sso_login.ex:422-424`
`(present when offline_access is granted — it is in @base_scopes)` — was always wrong, now doubly so.

### MINOR-5: `sso_scope_mode_test.exs` `@moduledoc` describes pre-fix scope set
**Location:** `server/test/nebu/matrix/sso_scope_mode_test.exs:8-17`
Still says base is `openid profile email offline_access`. Contradicts the `refute` assertions now in the same file.

### MINOR-6: `display_name` silently empty on Keycloak without `profile` scope
**Location:** `server/lib/nebu/web/plugs/oidc_plug.ex:205`
No `profile` scope → no `preferred_username`/`name` claims → display_name stored as `""`. Log a warning like MAJOR-1.

### MINOR-7: `runtime.exs:54` comment lists old base scope set
**Location:** `server/config/runtime.exs:54`
`# openid/profile/email/offline_access scope list.` — should reflect new `openid[/offline_access]` base.

### MINOR-8: Arc42 concepts doc states `profile email` always requested
**Location:** `docs/architecture/08-concepts.md:113`
`openid profile email are always requested.` — now false for Matrix SSO path.

### INFO-9: `docker-compose.yml` has no `NEBU_OIDC_EXTRA_SCOPES` for Matrix SSO
Dev Dex is permissive so no breakage, but documents a dev/prod divergence.

### INFO-10: Historical story docs describe old base scope
Legacy spec files — no runtime impact.
