# UX gate admin-oauth-switch -- nebu-ux-reviewer, 2026-10-14

0 blocking violations. Advisories (10): focus after error re-render / success anchor; proxy + refresh-mode items should be `Note` not `OK`;
internal IDs (G3-2) in texts; long aria-describedby on the kill switch; describedby order (error before help); checkbox label hit area (w-fit);
issuer field width (w-full max-w-xl, spellcheck off); long issuer in a list item (break-words); non-text contrast of DaisyUI defaults (page-wide, out of scope);
labelledby for the list, one shared propagation text.
Applied in dev cycle 1: all except the page-wide contrast (follow-up) and a focus script (success redirects to /admin/config#oauth-switch instead).
