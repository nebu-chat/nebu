# code-review — cycle 1
INFO | e2e/features/oauth-pages-redesign/04-sso-confirm-and-result-pages.feature:19 | Previous MINOR 1 resolved: Then text now states onAuthDone once and opener not messaged; byte-identical to the step pattern at steps.ts:329 (lit() regex-escapes the parentheses and comma, anchored ^$) | -
INFO | e2e/step-definitions/oauth/sso-confirm-and-result-pages.steps.ts:346 | Previous MINOR 2 resolved: 1s settle wait before the negative check; opener stub starts with data-auth-done="none" and listens for message, so a regression to two ifs would flip the attribute and fail | -
INFO | e2e/step-definitions/oauth/sso-confirm-and-result-pages.steps.ts:15 | Previous MINOR 3 resolved: header comment corrected and names the ExUnit test pinning the no-onAuthDone opener branch; no e2e variant is a documented decision | -
INFO | review-prescan | No MAJOR/MINOR lines; no new problems introduced by the delta | -
