# Code Review — bugfix-bootstrap-trailing-newline

## Verdict: APPROVE (0 CRITICAL, 0 MAJOR, 2 MINOR, 2 INFO)

## Fix Correctness (INFO-1 confirmed correct)
- Before: String.trim("profile email\n") → "profile email" → passes regex → BUG
- After: raw "profile email\n" → split → ["profile", "email\n"] → "email\n" fails \z → {:error,...} → CORRECT
- save_claim_mapping/1 (line 225) only reachable AFTER validation passes — trim there is safe normalization

## MINOR-1: String.split only on literal space (not whitespace class)
- validate_scope_string/1 line 233: String.split(scope_string, " ", trim: true)
- Tab-separated scopes ("profile\temail") still rejected by regex even without splitting → correct
- No code change needed; comment could be clearer
- Severity: MINOR (documentation gap, not correctness issue)

## MINOR-2: Redundant guard in auth.ex:do_complete_bootstrap/2
- Pre-existing `v != ""` guard on scope promotion is logically unreachable because save_claim_mapping writes default when input is empty
- Not introduced by this fix; out of scope for this bugfix
- Severity: MINOR (pre-existing, carry-over)

## AC Coverage
- AC12-5: trailing newline rejected ✓ (test bootstrap_live_test.exs:329)
- AC3: scope character whitelist validated ✓ (validate_scope_string unchanged, now sees raw input)
- AC6: valid scopes persisted ✓ (save_claim_mapping still trims+stores at line 225)
