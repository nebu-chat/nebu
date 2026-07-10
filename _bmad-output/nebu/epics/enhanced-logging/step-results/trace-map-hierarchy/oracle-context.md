## Matrix CS API Applicability: NONE
This story is out of Matrix Client-Server API scope. No Oracle spec obligations attach.
Change groups already-captured HTTP route strings for admin-UI display only; must not alter/normalize the actual request path used by the router.
Non-Matrix edge cases to cover: unrecognized-prefix route -> catch-all group (not dropped); shared-prefix routes collapse under one node, distinct leaves stay individually toggleable; empty dataset -> empty tree, no crash; domain-vs-leaf filter toggle applies correctly (grouping is display-only, underlying filter semantics unchanged).
