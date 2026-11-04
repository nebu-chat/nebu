#!/usr/bin/env python3
"""Mutation runner for the reference implementation of story server-side-key-backup.

usage: mutate.py <mutants.json> <log>
Each mutant: {"id","label","file","old","new","tests"}; applies ONE exact string replacement to a file of the worktree,
runs the tests through .e2ee-ci/quick.sh (--max-failures 3), ALWAYS restores the file, appends the verdict to <log>.
"""
import json, os, re, subprocess, sys

WT = "/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat-e2ee"
SCRATCH = os.path.dirname(os.path.abspath(__file__))


def run_tests(tests, slow=False):
    # cycle 2: the `:slow` tests (64 MiB / 100 000 rows fills) only run for the mutants that are marked `slow=True`
    cmd = "mix test %s --include integration%s --max-failures 3 2>&1" % (tests, "" if slow else " --exclude slow")
    for attempt in range(4):
        p = subprocess.run([WT + "/.e2ee-ci/quick.sh", cmd], capture_output=True, text=True, cwd=WT)
        out = p.stdout + p.stderr
        # a transient network failure of `mix local.hex` / `mix deps.get` inside the throwaway container is not a verdict: retry
        if re.search(r"^Result: |^\s*\d+\) ", out, re.M) or "builds.hex.pm" not in out + "Failed to fetch" and "Failed to fetch" not in out:
            return out
    return out


def main():
    import runpy
    mutants = runpy.run_path(sys.argv[1])["MUTANTS"]
    log = open(sys.argv[2], "a")
    only = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None
    for m in mutants:
        if only and m["id"] not in only:
            continue
        edits = m.get("edits") or [(m["file"], m["old"], m["new"])]
        origs = {}
        bad = None
        for f, old, new in edits:
            path = os.path.join(WT, f)
            cur = origs.get(f, open(path).read())
            origs.setdefault(f, cur)
            cnt = cur.count(old)
            if cnt != 1:
                bad = "NOAPPLY (old occurs %d times in %s)" % (cnt, f)
                break
        if bad:
            log.write("%s | %s | %s\n" % (m["id"], m["label"], bad))
            log.flush()
            continue
        try:
            cur = dict(origs)
            for f, old, new in edits:
                cur[f] = cur[f].replace(old, new)
            for f, txt in cur.items():
                open(os.path.join(WT, f), "w").write(txt)
            out = run_tests(m["tests"], m.get("slow", False))
        finally:
            for f, txt in origs.items():
                open(os.path.join(WT, f), "w").write(txt)
        open(os.path.join(SCRATCH, "mut_out_%s.txt" % m["id"]), "w").write(out)
        if re.search(r"== Compilation error|\(CompileError\)|\(SyntaxError\)", out):
            verdict = "COMPILE-ERROR | " + ";".join(re.findall(r"error: .*", out)[:2])
        else:
            fails = re.findall(r"^\s*\d+\) (.*)$", out, re.M)
            res = re.findall(r"^Result: .*$", out, re.M)
            if fails:
                verdict = "KILLED by: " + " || ".join(f[:170] for f in fails[:2])
            elif res:
                verdict = "SURVIVED | " + res[0]
            else:
                verdict = "NORESULT | " + " / ".join(out.strip().splitlines()[-3:])[:300]
        log.write("%s | %s | %s\n" % (m["id"], m["label"], verdict))
        log.flush()


if __name__ == "__main__":
    main()
