# code-review — cycle 1
INFO | server/lib/nebu/web/page_shell.ex:81 | previous MINOR (csp_with_script re-spelled @csp) fixed: @csp_prefix/@csp_suffix now single source; csp/0 output byte-identical, csp_with_script output unchanged (prefix <> script-src <> suffix) | -
INFO | server/lib/nebu/web/page_text.ex:213 | DE "arm_hint" pointer wording removed (input-neutral, matches EN); no test/e2e references the old "Zeiger" text; remaining EN/DE drift ("uia.complete.text" client vs App) is INFO only | -
