# Code review (nebu-code-reviewer), cycle 0: 0 MAJOR, 6 MINOR, 5 INFO

AC1-AC9 met. ADR-018 / ADR-020 / logging law fine.
MINOR (all fixed in dev cycle 1 except M5):
- M1 browser_post.ex moduledoc still claimed Safari 16.4+ sends all four headers and described reject / bulk as lenient -> corrected.
- M2 ADR-033 SO3 title / text contradicted SO9 -> cross reference added.
- M3 /account moduledocs said "no JavaScript" -> exception named (account.ex, account_pages.ex; put_headers/1,2).
- M4 follow-ups.md gate table still said "browsers send all four headers" -> corrected.
- M5 check_fetch_metadata/3 no longer names sec-fetch-user next to a failed site / mode / dest when the header is absent (diagnostic only) -> ACCEPTED: for WebKit an absent header is no failure; /2 keeps the old naming.
- M6 header and template condition for the reset script were coded twice -> one `script?` assign (reset_script?/2) now feeds the CSP and the template.
INFO: input loss on the notice page (UX N2, text added), confirm()-protected forms + 2 s window (07-deployment wording added), Enter on any INPUT (restricted: checkbox / radio excluded), state log tag text, tests complete.
