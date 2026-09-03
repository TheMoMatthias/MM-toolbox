# -*- coding: utf-8 -*-
"""WHERE DO I STAND -- one lane, cheap, no transcript reading.

For a SPECIALIST lane to run on itself. It answers four questions and stops:
  my row - my OPEN findings - what I last landed - WHICH RULINGS LANDED SINCE I DID.

🔴 THE FOURTH ONE IS WHY THIS EXISTS. Nothing else in a parallel programme tells a lane that
a ruling arrived while it was busy, paused, or mid-slice. The ledger is append-only and
nobody broadcasts it; a lane that has been heads-down for six hours is bound by rulings it
has never read. 🔒 SO: RUN THIS FIRST ON RESUME, FIRST ON UNPAUSE, AND BEFORE ANY CLOSE.

🔑 DELIBERATELY NOT the orchestrator's tool. It reads no other lane, no transcripts, and no
history it does not need: a lane already HAS its own context, so re-deriving what it did is
paying twice for something it knows. Output is a screenful, on purpose.

🪤 AND IT IS NOT A REALIGN. It sweeps ARTEFACTS only. Everything that lives in your own
conversation -- an unanswered question, a promise made mid-message, a decision that never
reached a register -- is invisible here and is `/automate-realign` §0's subject. Run
`--as-realign-input` and this block becomes that skill's §1 half; §0 remains yours.

USAGE   lane_check.py                     infer the lane from the worktree directory name
        lane_check.py F5                  a named lane
        lane_check.py --as-realign-input  emit as a paste-ready /automate-realign §1 block
        lane_check.py --repo <path>       run against another checkout
"""
import json
import os
import re
import subprocess
import sys
import time

# ════════════════════════════════════════════════════════════════════════════════════════
# ██  PROJECT BINDINGS  ██  EVERYTHING project-specific lives HERE and NOWHERE below.
# ════════════════════════════════════════════════════════════════════════════════════════
# To run this on a different repo, change this block and nothing else. Every field is
# consumed through BIND[...] further down; if you find a project path, an id pattern or a
# close-bar sentence outside this block, that is a bug in this script.
#
# 🔒 A tool that silently produces nothing on a repo it does not fit is worse than one that
#    says so: `check_bindings()` below resolves every artefact named here and REFUSES with
#    what is missing rather than printing an empty row.
BIND = {
    # what this is bound to -- printed in the refusal so the reader knows what to re-bind
    "project": "AlgoTrader context-vertical refactor",

    # the shared ref every derivation reads. Never your own HEAD: your HEAD is your claim,
    # the shared ref is the programme's.
    "ref": "origin/main",

    # the register, and the object whose keys are lane names
    # 🪤 that object's own README lives under it as a STRING, so rows are isinstance-filtered
    "register": "docs/refactor/enforcement.json",
    "register_lanes_key": "slices",

    # the findings log: how a row raised by THIS lane looks, and how its STATE cell reads
    # when it is still open. {lane} is substituted.
    "findings": "docs/refactor/FINDINGS.md",
    "finding_row_re": r"^\| \*\*({lane}-\d+)\*\*",
    # R-345: this was r"\*\*(STILL OPEN|OPEN)\b" and REQUIRED BOLD. Measured by GOV-1
    # over the whole register: 692 rows say OPEN and 225 of them (33%) are UNBOLDED, so
    # they were invisible to this tool -- across FOURTEEN lanes, with I8 (19/19) and
    # AUDIT-4 (12/12) seeing ZERO of their own open findings. Bold is now OPTIONAL and the
    # marker is anchored at the START of the state cell, which is where a state marker
    # lives; a mention of the word later in the prose still does not match.
    "open_state_re": r"^\s*(?:[^\w\s|]+\s*)*\**\s*(STILL OPEN|OPEN)\b",
    # what a lane must do with each OPEN finding it raised
    "open_dispositions": (
        "R-229 s4: each is IN-SCOPE (blocks your DONE-WHEN), ROUTED (file with an\n"
        "owner and CLOSE ANYWAY), or REFUTED. Finding it does not make it yours."
    ),

    # the ledger, and how a NEW ruling appears in a diff of it
    "ledger": "docs/refactor/DECISIONS_REFACTOR.md",
    "ruling_add_re": r"^\+#{2,3} (R-\d+) ",
    "ruling_sort_key": lambda s: int(s.split("-")[1]),
    "ruling_note": ("R-229 s1.6: disputing one is CORRECT and escalates. Read before acting."),

    # the commit trailer that attributes work to a lane
    "trailer_key": "Slice",

    # the bar a lane must clear to close, in this project's own words
    "close_bar": [
        "CLOSE BAR (R-229 s3, as amended R-235/R-236): DONE-WHEN - every finding you raised",
        "dispositioned - no red on main attributable to you - a qualifying R-148 run OR every",
        "deciding-job failure PROVEN FOREIGN by baseline subset. Show the subset, do not assert it.",
    ],
    # R-343 s1: this line ASSERTED "the DISPOSITION field is not built yet, so this is a
    # THREE-condition bar today" and was WRONG from the moment R-235 landed it -- every lane
    # running this skill was handed a stale blocker and told its bar was one condition shorter
    # than it is. Caught by SUITE-1, who BUILT the field. It is derived now, so it cannot rot
    # the same way: the ceilings file is the authority and this reads it.
    "disposition_ceilings": ("docs/refactor/ratchet_ceilings.json",
                             ("c8_no_disposition", "c8_bad_disposition")),
}
# ════════════════════════════════════════════════════════════════════════════════════════
# ██  END PROJECT BINDINGS  ██
# ════════════════════════════════════════════════════════════════════════════════════════

REPO = os.environ.get("AUTOMATE_LANE_REPO") or os.getcwd()


def disposition_bar_line():
    """R-343 s1: DERIVE whether the DISPOSITION condition is live, never assert it.

    Returns the 4th close-bar line, read from ratchet_ceilings.json at HEAD, so a
    future build or retirement moves it by itself instead of rotting in a literal.
    """
    path, keys = BIND["disposition_ceilings"]
    try:
        blob = json.loads(git("show", "origin/main:" + path) or "{}")
    except Exception:
        return "  DISPOSITION condition UNKNOWN (could not read %s) -- do not assume." % path
    ceil = blob.get("ceilings", blob)
    live = [k for k in keys if k in ceil]
    if not live:
        return "  DISPOSITION field NOT PRESENT in %s -- three-condition bar." % path
    vals = ", ".join("%s=%s" % (k, ceil[k].get("value")) for k in live)
    return ("  DISPOSITION field IS LIVE (" + vals + ") -- FOUR-condition bar. Every OPEN "
            "finding you raised needs IN-SCOPE / ROUTED / REFUTED in its own cell.")


def git(*a):
    p = subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.stdout if p.returncode == 0 else ""


def check_bindings():
    """Resolve every artefact BIND names. Refuse loudly rather than print an empty row."""
    missing = []
    if not git("rev-parse", "--git-dir").strip():
        return ["not a git checkout: %s" % REPO]
    if not (git("rev-parse", "--short", BIND["ref"]) or "").strip():
        return ["ref does not resolve: %s" % BIND["ref"]]
    for key in ("register", "findings", "ledger"):
        if not git("show", "%s:%s" % (BIND["ref"], BIND[key])):
            missing.append("%s not found at %s:%s" % (key, BIND["ref"], BIND[key]))
    return missing


def gather(lane):
    """Everything both output modes need. One pass, no transcript reading."""
    d = {"lane": lane, "head": (git("rev-parse", "--short", BIND["ref"]) or "?").strip()}

    reg = json.loads(git("show", "%s:%s" % (BIND["ref"], BIND["register"])) or "{}")
    row = reg.get(BIND["register_lanes_key"], {}).get(lane)
    d["row"] = row if isinstance(row, dict) else None

    findings = git("show", "%s:%s" % (BIND["ref"], BIND["findings"]))
    pat = re.compile(BIND["finding_row_re"].format(lane=re.escape(lane)))
    open_pat = re.compile(BIND["open_state_re"])
    d["open_ids"], d["raised"] = [], 0
    for line in findings.splitlines():
        m = pat.match(line)
        if not m:
            continue
        d["raised"] += 1
        cells = line.split("|")
        # 🪤 a row is ONE LINE: test that line's own STATE cell, never a token anywhere in it
        if len(cells) >= 3 and open_pat.search(cells[-2]):
            d["open_ids"].append(m.group(1))

    mine = git("log", BIND["ref"], "-1",
               "--format=%x02%h%x01%ad%x01%s", "--date=format:%m-%d %H:%M",
               "--grep=^%s: %s$" % (BIND["trailer_key"], lane), "--extended-regexp")
    rec = [x for x in mine.split("\x02") if x.strip()]
    d["landing"] = None
    d["rulings"] = []
    if rec:
        h, when, subj = (rec[0].strip("\n").split("\x01") + ["", "", ""])[:3]
        d["landing"] = (h, when, subj.replace("\n", " "))
        diff = git("diff", "%s..%s" % (h, BIND["ref"]), "--", BIND["ledger"])
        d["rulings"] = sorted(set(re.findall(BIND["ruling_add_re"], diff, re.M)),
                              key=BIND["ruling_sort_key"])
    return d


def report(d):
    lane = d["lane"]
    print("=" * 66)
    print("%s   %s %s" % (lane, BIND["ref"], d["head"]))
    print("=" * 66)
    row = d["row"]
    if not row:
        print("NO REGISTER ROW. Open one before your first commit.")
        return
    paused = row.get("paused")
    print("ROW      : state=%s%s%s" % (
        row.get("state", "?"),
        "  owns=" + ",".join(row.get("owns", [])) if row.get("owns") else "  owns=[] (a PROHIBITION)",
        "  PAUSED" if paused else ""))
    if isinstance(paused, dict):
        print("           resume when: %s" % str(paused.get("resume_trigger", ""))[:180])

    print("OPEN     : %d of %d raised%s" % (
        len(d["open_ids"]), d["raised"],
        ("  -> " + ", ".join(d["open_ids"])) if d["open_ids"] else ""))
    if d["raised"] and not d["open_ids"]:
        print("           ^ ZERO is a PATTERN MATCH, not a verdict. If that surprises\n"
              "             you, read the register directly -- R-345: this line read 0\n"
              "             against a real 12 for two lanes until 2026-09-03.")
    if d["open_ids"]:
        for line in BIND["open_dispositions"].splitlines():
            print("           %s" % line)

    if not d["landing"]:
        print("LANDED   : nothing on %s carries `%s: %s`"
              % (BIND["ref"], BIND["trailer_key"], lane))
        print("RULINGS  : cannot derive -- no landing of yours to diff the ledger from.")
        print("           Read the ledger's tail by hand before acting.")
    else:
        h, when, subj = d["landing"]
        print("LANDED   : %s  %s  %s" % (h, when, subj[:60]))
        # ── the section nothing else in the programme produces ──────────────────────────
        if d["rulings"]:
            print("*" * 66)
            print("RULINGS SINCE YOUR LAST COMMIT: %d. YOU HAVE NOT NECESSARILY SEEN THESE."
                  % len(d["rulings"]))
            print("  %s" % ", ".join(d["rulings"]))
            print("  Nothing else tells a lane a ruling arrived. Read them BEFORE you act on")
            print("  anything you planned before them -- one may have moved your bar.")
            print("  %s" % BIND["ruling_note"])
            print("*" * 66)
        else:
            print("RULINGS  : none landed since your last commit")

    print("-" * 66)
    for line in BIND["close_bar"]:
        print(line)
    print(disposition_bar_line())


def report_realign(d):
    """The same findings, shaped to paste into /automate-realign §1."""
    lane, row = d["lane"], d["row"]
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print("--- lane-check artefact sweep (/automate-realign step 1) | %s | %s %s | %s ---"
          % (lane, BIND["ref"], d["head"], stamp))
    print("")
    if not row:
        print("VERIFIED    NO register row for %s at %s:%s -- open one before your first"
              % (lane, BIND["ref"], BIND["register"]))
        print("            commit. Until then every derivation below is over an unregistered lane.")
    else:
        paused = row.get("paused")
        print("VERIFIED    row: state=%s owns=%s paused=%s"
              % (row.get("state", "?"), ",".join(row.get("owns", [])) or "[]",
                 "yes" if paused else "no"))
        print("            (git show %s:%s)" % (BIND["ref"], BIND["register"]))
        if isinstance(paused, dict) and paused.get("resume_trigger"):
            print("            resume trigger: %s" % str(paused["resume_trigger"])[:200])
            print("            -> if you are resuming, DELETE this pause object in the commit")
            print("               that resumes. A stale pause note reads as a dead lane.")

    if d["landing"]:
        h, when, subj = d["landing"]
        print("VERIFIED    last landing %s %s %s" % (h, when, subj[:70]))
        print("            (git log %s --grep=^%s: %s)"
              % (BIND["ref"], BIND["trailer_key"], lane))
    else:
        print("VERIFIED    nothing on %s carries `%s: %s` -- this lane has landed nothing."
              % (BIND["ref"], BIND["trailer_key"], lane))

    if d["open_ids"]:
        print("DEFERRED    %d of %d findings you raised still carry an OPEN state cell:"
              % (len(d["open_ids"]), d["raised"]))
        print("            %s" % ", ".join(d["open_ids"]))
        for line in BIND["open_dispositions"].splitlines():
            print("            %s" % line)
        print("            -> each needs claim | confidence | trigger | OWNER | DONE-WHEN | HOW.")
    else:
        print("DEFERRED    0 OPEN of %d findings you raised (register-derived, not recalled)."
              % d["raised"])
        print("            ^ ZERO is a PATTERN MATCH, not a verdict -- R-345. If that\n"
              "              surprises you, read the register directly; this line read 0\n"
              "              against a real 12 for two lanes until 2026-09-03.")

    if d["rulings"]:
        print("INBOUND     %d ruling(s) landed since your last commit -- you have NOT"
              % len(d["rulings"]))
        print("            necessarily seen these, and silence on an inbound item reads to")
        print("            the sender as agreement.  (%s)" % BIND["ledger"])
        print("            %s" % ", ".join(d["rulings"]))
        print("            %s" % BIND["ruling_note"])
        print("            -> read each, then say on this line whether it changes your NEXT.")
    elif d["landing"]:
        print("INBOUND     no ruling landed since your last commit (%s)." % d["landing"][0])
    else:
        print("INBOUND     UNDERIVABLE -- no landing of yours to diff the ledger from. Read")
        print("            the ledger tail by hand; do not report this line as empty.")

    print("")
    for n, line in enumerate(BIND["close_bar"]):
        print("%-11s %s" % ("CLOSE-BAR" if n == 0 else "", line))
    print("%-11s %s" % ("", disposition_bar_line().strip()))
    print("")
    print("UNSWEPT     THIS BLOCK IS STEP 1 ONLY. It sweeps ARTEFACTS. It has NOT read your")
    print("            conversation, so step 0's five lines -- UNANSWERED, PROMISED,")
    print("            SUPERSEDED, INBOUND-UNCONFIRMED, ORAL-ONLY -- are still entirely")
    print("            yours, and every item measured lost was lost there. It also cannot")
    print("            see other lanes, transcripts, intent or correctness. Do not paste")
    print("            this and stop.")


def main(argv):
    global REPO
    if "--repo" in argv:
        i = argv.index("--repo")
        if i + 1 < len(argv):
            REPO = argv[i + 1]
            argv = argv[:i] + argv[i + 2:]

    as_realign = "--as-realign-input" in argv
    args = [a for a in argv if not a.startswith("--")]

    missing = check_bindings()
    if missing:
        print("=" * 66)
        print("NOT BOUND TO THIS PROJECT -- this tool is bound to: %s" % BIND["project"])
        print("=" * 66)
        for m in missing:
            print("  MISSING  %s" % m)
        print("\nRe-bind by editing the PROJECT BINDINGS block at the top of this file")
        print("(%s), or point it elsewhere with --repo / $AUTOMATE_LANE_REPO." % __file__)
        print("An empty row on a repo this does not fit would read as a lane with nothing open.")
        return 2

    lane = args[0] if args else os.path.basename(os.path.abspath(REPO))
    git("fetch", "-q", "origin", BIND["ref"].split("/")[-1])
    d = gather(lane)
    (report_realign if as_realign else report)(d)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
