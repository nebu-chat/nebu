# Pre-dev test review: consent-arming-hardening (nebu-test-reviewer, 2026-10-13)
1 MAJOR, 5 MINOR, 8 INFO. AC coverage complete; mutation survivors all caught elsewhere once MAJOR-1 is fixed.
- MAJOR-1 `oauth_consent_page_test.exs` ~L352: `refute block =~ "role="` can never pass (`data-role="` contains `role=`): use `refute block =~ ~r/\srole=/`.
- MINOR-2 touch scenario "tap right away" can pass vacuously; add `Then the consent page announces "Allow is not available yet."` before "the browser is still on the consent page" (also covers the otherwise unasserted message).
- MINOR-3 "still on the consent page" is racy as a no-POST proof: order the "announces ..." step first in all three scenarios; poll briefly / waitForLoadState.
- MINOR-4 parked-pointer scenario: park at the top edge of the armed Allow (y = armedBox.y + 3) and assert the parked point is NOT inside the unarmed box.
- MINOR-5 pin the whole D2 name expression in one regex (`(b.textContent||"").replace(/^\s+|\s+$/g,"")||"This button"`), optional node harness.
- MINOR-6 set the viewport before enabling touch emulation (move setViewportSize into the Given step).
INFO: docs/AC7 have no new tests; static scans are sound (`@script Nebu.Web.ArmScript.script()` literal: say so to dev); remaining unscoped Dex probes (fixtures/oauth-admin.ts:42, element/login.steps.ts:83/:320, admin-session-refresh.steps.ts:72, legacy-sso steps:111) out of scope: follow-up row.
