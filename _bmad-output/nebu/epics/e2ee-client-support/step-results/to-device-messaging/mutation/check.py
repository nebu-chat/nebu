#!/usr/bin/env python3
"""Dry run: every mutant's `old` text must occur exactly once in its file (usage: check.py mutants.py)."""
import os, runpy, sys
WT = "/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat-e2ee"
ms = runpy.run_path(sys.argv[1])["MUTANTS"]
bad = 0
ids = set()
for m in ms:
    assert m["id"] not in ids, "duplicate id " + m["id"]
    ids.add(m["id"])
    for f, old, new in (m.get("edits") or [(m["file"], m["old"], m["new"])]):
        txt = open(os.path.join(WT, f)).read()
        c = txt.count(old)
        if c != 1:
            bad += 1
            print("%s: %d occurrences in %s: %r" % (m["id"], c, f, old[:70]))
print("%d mutants, %d bad" % (len(ms), bad))
