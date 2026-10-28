# UX / accessibility review (nebu-ux-reviewer), cycle 0: 0 BLOCKING, 7 NON-BLOCKING, 7 INFO

Tone "notice, not error" met (200, alert-info, role=status; /account "Note:", .notice.info); contrast .notice.info about 15:1 text / 5.9:1 border; skip link and back link intact.
NON-BLOCKING, fixed in cycle 1: N1 "reload" misleading on a POST response (text now: use the link, press the same button, do not reload this page), N2 typed input lost (sentence: Back button keeps it), N3 ambiguous "the button" / jargon on /account (shortened, names Approve reset), N4 no way out for revoke (operator CLI sentence, "Chrome or Firefox"), N5 parent nav key (child key derived from the back path, also for the 403 page), N6 imperative title (now "Action not carried out"), I3 break-all on the script path.
Accepted: N7 axe / 320 px e2e scenarios for the notice pages (recorded as manual check; the notice pages need a WebKit user agent, tracked with follow-up cz), I2 theme info colour 4.63:1 (existing pattern).
I7 (assistive-technology activations must be trusted clicks) added to the MANUAL verification (07-deployment group D, item 6).
