## Oracle Spec Analysis

### 1. Matrix CS API scope — MUST requirements

- This story touches the **SSO login provisioning path**, not a new CS endpoint. `POST /_matrix/client/v3/login` (spec `#post_matrixclientv3login`) and `GET /admin/users` (Nebu-internal, NOT a Matrix CS endpoint) — no CS API contract changes.
- **User ID grammar (appendices #user-identifiers, MUST):** the `matrix_user_id` provisioned by the admin path MUST match `@localpart:domain`; localpart MUST NOT be empty, MUST contain only `a-z 0-9 . _ = - / +`; total length (incl. `@` + domain) MUST NOT exceed 255 bytes. Same identity MUST resolve to the SAME `users` row from both login paths.
- **Idempotency (project invariant, not a CS MUST):** spec has no `/login` idempotency rule, but AC1/AC4 require the upsert be idempotent — re-provisioning the same `matrix_user_id` MUST NOT error, MUST NOT duplicate the row, MUST NOT overwrite user-set profile data.
- **Auto-join** is not a spec-defined `/login` behavior — it is Nebu's `run_post_login_provisioning/2`. AC2's "skip auto-join for admin-only login" is spec-permissible (spec neither mandates nor forbids auto-join on login).
- **No CS MUST is violated by AC2's recommendation** (provision yes, auto-join no) — auto-join is out of CS API scope.

### 2. Error codes / status / edge cases to test-cover

- No new CS API error codes are introduced by this story (admin OIDC callback + internal provisioning are outside the CS error taxonomy).
- Edge cases that MUST be covered (from ACs, not from CS spec):
  - AC1: admin login with NO existing row → row created; idempotent when row already exists.
  - AC4/AC5: admin-provisioned identity then real Matrix `/login` → no duplicate row, no double auto-join, no profile clobber, `/login` returns normal 200 with `access_token`/`device_id`/`user_id`.
  - Malformed/empty localpart from OIDC claim → provisioning MUST reject (user ID grammar).
  - AC3: `GET /admin/users` lists the admin-only user.
- Standard `/login` error contract remains untouched and should be regression-asserted: 403 `M_FORBIDDEN` bad creds, 400 `M_BAD_JSON` missing `type` (test-guidance §Login) — verify the admin change does not alter these.

### Relevant paths
- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` (`#post_matrixclientv3login`, line 5654)
- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/appendices/index.html` lines 749-769 (user ID grammar)
- Code under test: `server/lib/nebu/matrix/http_public.ex:325-371` (login provisioning path — verify line numbers fresh), `server/lib/nebu/admin/auth.ex` (`normal_callback/2`, `bootstrap_confirm_claim/2`), `Nebu.Matrix.Session.TokenValidator.validate/4`, `Nebu.Matrix.Profile.DB.upsert_profile/3`, `Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2`

Note: AC3/AC5's `GET /admin/users` and the admin OIDC callbacks are NOT Matrix CS API surface — they are not testable via the CS API and need in-process/admin-UI tests (per test-guidance §Writing Scenarios, flag non-CS-observable ACs).

## Fresh code-read findings (pipeline coordinator, supplementing Oracle)

- `Nebu.Matrix.Session.TokenValidator.validate/4` has TWO call sites today (both pre-existing, this story adds a THIRD caller from Admin):
  1. **Login path** (`http_public.ex` `provision_and_respond/6`, ~line 332): `validate/4` → `Nebu.Matrix.Profile.DB.upsert_profile/3` → `Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2` (auto-join, personal room). This is the FULL provisioning flow AC1 refers to.
  2. **Matrix /refresh deprovisioning re-check** (`http_public.ex` `check_still_active/2`, ~line 648, added by `matrix-refresh-revalidates-with-idp`): calls `validate/4` ONLY to detect `{:error, :deactivated}` for fail-closed session invalidation. Deliberately does NOT call `upsert_profile` or `run_post_login_provisioning` afterward — it is a narrower "is this user still active" check, not a full provisioning call.
- AC1 wants the **login-path flavor** (validate + upsert_profile), NOT auto-join (per AC2 recommendation) and NOT the narrow /refresh-style check-only call.
- `Nebu.Matrix` facade (`server/lib/nebu/matrix.ex`) currently has NO delegate for provisioning/validate — this story must add one (e.g. `provision_matrix_identity/1` or similar) that internally does `TokenValidator.validate/4` + `upsert_profile/3`, WITHOUT auto-join, so `Nebu.Admin.Auth` never touches `Nebu.Matrix.Session.TokenValidator` or `Nebu.Matrix.Profile.DB` directly (ADR-020).
- `Nebu.Admin.DB.list_users/3` (server/lib/nebu/admin/db.ex) reads exclusively from the `users` table — confirms AC3's mechanism.
- `put_current_user/2` in `admin/auth.ex` (~line 282) is the single session-minting function called by both `normal_callback/2` (~line 537) and `bootstrap_confirm_claim/2` (~line 745) — the natural single injection point for the new facade call, since both call sites already converge there with the full verified `claims` map available.
