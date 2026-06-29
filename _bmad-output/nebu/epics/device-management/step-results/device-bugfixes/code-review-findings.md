## Code Review — device-bugfixes (cycle 0)

**Result: 0 MAJOR/CRITICAL | 4 MINOR | 6 INFO**
All 7 ACs satisfied. Security clean (HEEx escaping, no XSS/IDOR/auth-bypass).

### MINOR-A — CSS class mismatch between Dev Notes and UX gate
Dev Notes specify `link link-primary`; UX gate (ADV-1) recommended `text-primary` for
consistency with rooms/spaces index. Current code uses `text-primary`. Resolution:
update story Dev Notes to document deliberate choice per UX gate. No CSS change needed.

### MINOR-B — No Playwright/Gherkin E2E scenario for link navigation (AC2)
CLAUDE.md convention: UI changes need at least one Playwright+Gherkin scenario.
Need a scenario in `e2e/features/admin/users.feature` that clicks a user link and
verifies navigation to the device detail page (rather than direct URL construction).

### MINOR-C — AC7 tests non-discriminating; add clarifying comment
The two AC7 tests pass even without the new route (OidcPlug rejects before dispatch).
This is acceptable auth-pipeline confirmation behavior, but needs a comment making this
explicit so future readers understand the tests don't guard route existence.

### MINOR-D — `_priv = setup_oidc_keys()` comment — verify it's present
Reviewer noted the comment may already exist ("configure OIDC so OidcPlug can validate
(and reject) tokens properly"). Verify the comment is in the AC7 setup block; if not, add:
`# OIDC keys must be configured so OidcPlug can validate and reject the unauthenticated request.`

### INFO-1 — Add async: false rationale comment to both test files
`# async: false — uses Application.put_env; cannot run concurrently`

### INFO-2 — on_exit in users_index_link_test.exs: delete instead of re-set
Change: `Application.put_env(:nebu_http, :admin_csrf_bypass, true)` →
`Application.delete_env(:nebu_http, :admin_csrf_bypass)`

### INFO-3 — signatures_upload_test.exs: add @moduletag :integration

### INFO-4 — signatures_upload_test.exs lives in test/nebu/matrix/ but module is Nebu.Web.*
Consider moving to test/nebu/web/ per domain-mirror convention (CLAUDE.md).
