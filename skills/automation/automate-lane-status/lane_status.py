# -*- coding: utf-8 -*-
"""ONE PASS over every lane: what it DID, what it OWES, what it is DOING, and what it says
it will do NEXT.

Derived from four independent sources, none of them a list anybody maintains:
  1. the register (`enforcement.json`)  -- the row: state, paused, owns
  2. `git log` trailers                 -- what the lane actually LANDED (the work itself)
  3. the findings log (`FINDINGS.md`)   -- rows the lane RAISED that are still OPEN
  4. the lane's own transcript          -- what it is doing now, in its own words

🔑 WHY FOUR: each is wrong in a different direction, and the programme has measured all four.
  * a row says `open` while nobody works it (R-82)
  * a landing says a lane WAS working an hour ago, never that it IS (GOV-1-66)
  * a still-open list decays toward looking BUSY -- nothing prunes it (GOV-1)
  * a roster decays toward looking IDLE (F-307)
  Read together they disagree usefully; read alone each of them lies.

🔴 THE FIFTH THING, AND IT EXISTS NOWHERE ELSE: the lane's STATED NEXT ITEM.
  `automate-orchestrator` §7 calls it "the load-bearing column, because it is the one thing
  that exists nowhere else" -- the board shows landings, a state file usually has no NEXT
  section (measured: 4 of ~30), and the lane's own intention lives in a message somebody
  reads once and discards. This tool extracts it and GRADES it, and prints
  `-- NO NAMED ITEM --` loudly when it cannot. A lane with no named item is §1 rule C: the
  thing to act on, not a lane to leave alone.

🪤 IT DOES NOT FALL BACK TO THE LAST COMMIT SUBJECT, deliberately. A landing says what a lane
  DID; using it as a next item MANUFACTURES one where none exists, and the whole value of
  this column is that it can come up empty.

🪤 WHAT THIS CANNOT SEE, stated because a sweep that hides its blind spots is the house pattern:
  * sessions on another machine -- this reads THIS host's transcript store
  * a lane resumed under a new session id whose OLD transcript is newer on disk
  * intent, correctness, or whether a lane is right about anything it says
  * SESSION STATE (busy / idle / waiting). Only `ListAgents` carries that, and §1 turns on it.

USAGE
  lane_status.py                 every lane written to in the last 4h
  lane_status.py --all           every lane that ever existed here
  lane_status.py F5 GOV-1        those lanes, in full
  lane_status.py --since 12      hours of git history to attribute (default 24)
  lane_status.py --chars 4000    how much of DOING to print (default 1200)
  lane_status.py --full          do not truncate DOING at all
  lane_status.py --repo <path>   run against another checkout of the bound project
"""
import io
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
#    what is missing rather than printing an empty board.
BIND = {
    # what this is bound to -- printed in the refusal so the reader knows what to re-bind
    "project": "AlgoTrader context-vertical refactor",

    # the working tree to derive from. --repo or $AUTOMATE_LANE_REPO override it.
    "repo": r"C:/Users/mauri/Documents/Trading Bot/Python/AlgoTrader/.claude/worktrees/ORCHESTRATOR",
    # the shared ref every derivation reads. Never the local branch: a lane's own HEAD is
    # its claim, the shared ref is the programme's.
    "ref": "origin/main",

    # ── source 1: the register ──────────────────────────────────────────────────────────
    "register": "docs/refactor/enforcement.json",
    "register_lanes_key": "slices",   # the object whose keys are lane names
    # 🪤 the register's own README lives under this key as a STRING, so every reader must
    #    isinstance-filter the rows. That is why `dict` is asserted rather than assumed.

    # ── source 2: git trailers ──────────────────────────────────────────────────────────
    "trailer_key": "Slice",           # `Slice: <lane>` in the commit message

    # ── source 3: the findings log ──────────────────────────────────────────────────────
    "findings": "docs/refactor/FINDINGS.md",
    # a finding row, anchored: `| **<LANE>-<n>** | ... | ... |`. {lane} is substituted.
    "finding_row_re": r"^\| \*\*({lane}-\d+)\*\*",
    # the STATE cell's marker for a row that is still open
    "open_state_re": r"\*\*(STILL OPEN|OPEN)\b",

    # ── source 4: the transcripts ───────────────────────────────────────────────────────
    "transcript_store": os.path.expanduser("~/.claude/projects"),
    # a session directory is <prefix><lane>; everything after the prefix is the lane name
    "transcript_prefix": "C--Users-mauri-Documents-Trading-Bot-Python-AlgoTrader--claude-worktrees-",

    # ── the optional 5th place a NEXT item can hide: the lane's own state file ───────────
    "state_file": "docs/refactor/briefs/{lane}_STATE.md",

    # tuning
    "idle_lane_minutes": 240.0,   # how recently a transcript must have been written
    "doing_chars": 1200,          # DOING truncation. 🔴 was 340 and it HID open-item lists.
    "tail_bytes": 240_000,        # how much of a transcript to parse from the end
}
# ════════════════════════════════════════════════════════════════════════════════════════
# ██  END PROJECT BINDINGS  ██
# ════════════════════════════════════════════════════════════════════════════════════════

REPO = os.environ.get("AUTOMATE_LANE_REPO") or BIND["repo"]


def git(*args):
    p = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.stdout if p.returncode == 0 else ""


def check_bindings():
    """Resolve every artefact BIND names. Refuse loudly rather than print an empty board."""
    missing = []
    if not os.path.isdir(REPO):
        missing.append("repo does not exist: %s" % REPO)
        return missing
    if not git("rev-parse", "--git-dir").strip():
        missing.append("not a git checkout: %s" % REPO)
        return missing
    if not (git("rev-parse", "--short", BIND["ref"]) or "").strip():
        missing.append("ref does not resolve: %s" % BIND["ref"])
        return missing
    for key in ("register", "findings"):
        if not git("show", "%s:%s" % (BIND["ref"], BIND[key])):
            missing.append("%s not found at %s:%s" % (key, BIND["ref"], BIND[key]))
    if not os.path.isdir(BIND["transcript_store"]):
        missing.append("transcript store not found: %s" % BIND["transcript_store"])
    return missing


def transcripts():
    out = {}
    store, prefix = BIND["transcript_store"], BIND["transcript_prefix"]
    if not os.path.isdir(store):
        return out
    for name in os.listdir(store):
        if not name.startswith(prefix):
            continue
        d = os.path.join(store, name)
        try:
            js = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".jsonl")]
        except OSError:
            continue
        if js:
            out[name[len(prefix):]] = max(js, key=os.path.getmtime)
    return out


def assistant_texts(path):
    """Every assistant text block in the transcript tail, oldest first.

    🪤 The old version kept only the LAST one and cut it at 340 characters, which is
    shorter than a single realign HEADLINE line -- so the reports that enumerate open
    items were exactly the ones it hid. Nothing here truncates; the caller decides.
    """
    try:
        size = os.path.getsize(path)
        with io.open(path, "rb") as fh:
            if size > BIND["tail_bytes"]:
                fh.seek(size - BIND["tail_bytes"])
                fh.readline()
            raw = fh.read().decode("utf-8", "replace")
    except OSError as exc:
        return ["(transcript unreadable: %s)" % exc]
    texts = []
    for line in raw.splitlines():
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        msg = ev.get("message") or {}
        if msg.get("role") != "assistant":
            continue
        c = msg.get("content")
        parts = []
        if isinstance(c, str):
            parts = [c]
        elif isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "text" and b.get("text"):
                    parts.append(b["text"])
        if parts:
            texts.append("\n".join(parts))
    return texts


# ── the STATED NEXT ITEM, and how confident the extraction is ────────────────────────────
#    Ranked most explicit first. The grade travels WITH the value, because "the lane said
#    this" and "a regex found a verb" are different claims and must not read alike.
_REALIGN_MARK = "=== REALIGN-AUTOMATE"
#  🪤 the terminator alternatives are load-bearing. Without `\n===` the extraction swallowed
#     the block's own closing fence into the item; without the blank-line branch it ran on
#     into whatever the lane wrote after the block.
_NEXT_LINE = re.compile(
    r"^NEXT\s{2,}(.+?)(?=\n\s*\n|\n[A-Z][A-Z-]{2,}\s{2,}|\n```|\n===|\Z)", re.M | re.S)
_STATED = [
    re.compile(r"(?:^|\n)\s*(?:NEXT|Next up|Next)\s*[:\u2014-]\s*(.+)"),
    re.compile(r"\bnext I(?:'ll| will|'m going to| am going to)\s+(.+?)(?:[.\n]|$)", re.I),
    re.compile(r"\bthen I(?:'ll| will)\s+(.+?)(?:[.\n]|$)", re.I),
    re.compile(r"\bnothing (?:outstanding|named|queued)\b()", re.I),
]
_INFERRED = [
    re.compile(r"\bI(?:'ll| will) (?:now )?(.+?)(?:[.\n]|$)"),
    re.compile(r"\b(?:proceeding|moving on|continuing) (?:to|with|onto)\s+(.+?)(?:[.\n]|$)", re.I),
    re.compile(r"\bresum(?:e|ing) (?:at|with|on)\s+(.+?)(?:[.\n]|$)", re.I),
]


def _clean(s):
    return " ".join(s.split()).strip(" .:-")


def stated_next(texts, lane):
    """(item, grade) -- grade is 'realign', 'stated', 'inferred', 'state-file' or ''."""
    # ① a realign block's NEXT line is the canonical answer: the lane wrote it FOR this.
    for text in reversed(texts):
        if _REALIGN_MARK in text:
            tail = text[text.rindex(_REALIGN_MARK):]
            m = _NEXT_LINE.search(tail)
            if m and _clean(m.group(1)):
                return _clean(m.group(1)), "realign"
    # ② an explicit statement in the lane's own recent prose
    for pats, grade in ((_STATED, "stated"), (_INFERRED, "inferred")):
        for text in reversed(texts[-4:]):
            for pat in pats:
                m = pat.search(text)
                if m:
                    got = _clean(m.group(1)) if m.groups() and m.group(1) else _clean(m.group(0))
                    if got:
                        return got, grade
    # ③ the lane's state file, if the project keeps one and it has a NEXT section
    path = BIND.get("state_file")
    if path:
        blob = git("show", "%s:%s" % (BIND["ref"], path.format(lane=lane)))
        if blob:
            m = re.search(r"^#{1,6}\s*NEXT\b[^\n]*\n+(.+?)(?=\n#{1,6}\s|\Z)", blob, re.M | re.S)
            if m and _clean(m.group(1)):
                return _clean(m.group(1))[:400], "state-file"
    return "", ""


def wrap(text, width, indent):
    out, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            out.append(line)
            line = word
        else:
            line = (line + " " + word).strip()
    if line:
        out.append(line)
    return ("\n" + indent).join(out) if out else ""


def main(argv):
    global REPO
    if "--repo" in argv:
        i = argv.index("--repo")
        if i + 1 < len(argv):
            REPO = argv[i + 1]
            argv = argv[:i] + argv[i + 2:]

    missing = check_bindings()
    if missing:
        print("=" * 78)
        print("NOT BOUND TO THIS PROJECT -- this tool is bound to: %s" % BIND["project"])
        print("=" * 78)
        for m in missing:
            print("  MISSING  %s" % m)
        print("\nRe-bind by editing the PROJECT BINDINGS block at the top of this file")
        print("(%s), or point it elsewhere with --repo / $AUTOMATE_LANE_REPO." % __file__)
        print("An empty board on a repo this does not fit would read as a quiet programme.")
        return 2

    want = [a for a in argv if not a.startswith("--")]
    show_all = "--all" in argv
    full = "--full" in argv
    chars = BIND["doing_chars"]
    since = 24
    for flag, cast in (("--since", int), ("--chars", int)):
        if flag in argv:
            try:
                v = cast(argv[argv.index(flag) + 1])
                if flag == "--since":
                    since = v
                else:
                    chars = v
            except (IndexError, ValueError):
                pass
    if want:
        want = [w for w in want if not w.isdigit()]   # --since/--chars values are not lanes

    git("fetch", "-q", "origin", BIND["ref"].split("/")[-1])
    reg = json.loads(git("show", "%s:%s" % (BIND["ref"], BIND["register"])) or "{}")
    rows = reg.get(BIND["register_lanes_key"], {})
    slices = {k: v for k, v in rows.items() if isinstance(v, dict)}
    findings = git("show", "%s:%s" % (BIND["ref"], BIND["findings"]))

    #  🪤 `%(trailers:key=...,valueonly)` emits a TRAILING NEWLINE, so a one-line-per-commit
    #     split silently produced "nothing landed" for every lane. `separator=` is not enough
    #     on its own -- the newline is appended after the whole block. Use a record separator
    #     and split on that instead of on lines.
    log = git("log", BIND["ref"], "--since=%d.hours" % since,
              "--format=%%x02%%h%%x01%%ad%%x01%%(trailers:key=%s,valueonly)%%x01%%s"
              % BIND["trailer_key"],
              "--date=format:%H:%M")
    landed = {}
    for rec in log.split("\x02"):
        rec = rec.strip("\n")
        if not rec:
            continue
        bits = rec.split("\x01")
        if len(bits) == 4:
            lane = bits[2].strip().splitlines()[0].strip() if bits[2].strip() else ""
            landed.setdefault(lane or "(no trailer)", []).append(
                [bits[0], bits[1], lane, bits[3].replace("\n", " ")])

    tx = transcripts()
    now = time.time()
    if want:
        lanes = want
    else:
        lanes = sorted(
            {k for k, v in slices.items() if v.get("state") == "open"}
            | {k for k, p in tx.items()
               if show_all or (now - os.path.getmtime(p)) / 60.0 <= BIND["idle_lane_minutes"]})

    print("=" * 78)
    print("LANE STATUS -- four independent sources, nothing maintained by hand")
    print("%s %s   git window %dh   %d lane(s)   DOING cap %s"
          % (BIND["ref"], (git("rev-parse", "--short", BIND["ref"]) or "?").strip(),
             since, len(lanes), "none (--full)" if full else chars))
    print("=" * 78)

    unnamed = []
    for lane in lanes:
        row = slices.get(lane)
        state = row.get("state", "?") if row else "NO ROW"
        paused = bool(row.get("paused")) if row else False
        owns = ",".join(row.get("owns", [])) if row else ""
        commits = landed.get(lane, [])
        #  🪤 The first version searched the WHOLE file with `.*?` under DOTALL, so every id
        #     matched the next `**OPEN` anywhere later in the register and F2 read as 240 open.
        #     A row is ONE LINE: test that line's own STATE cell and nothing else.
        raised, still_open = [], []
        pat = re.compile(BIND["finding_row_re"].format(lane=re.escape(lane)))
        open_pat = re.compile(BIND["open_state_re"])
        for line in findings.splitlines():
            m2 = pat.match(line)
            if not m2:
                continue
            raised.append(m2.group(1))
            cells = line.split("|")
            state_cell = cells[-2] if len(cells) >= 3 else ""
            if open_pat.search(state_cell):
                still_open.append(m2.group(1))
        flag = "PAUSED" if paused else state.upper()
        print("\n%-14s %-9s %s" % (lane, flag, ("owns=" + owns) if owns else ""))
        print("   DID (%dh)   : %s" % (
            since,
            ("%d commit(s); newest %s %s" % (len(commits), commits[0][0], commits[0][3][:72]))
            if commits else "nothing landed in the window"))
        print("   OWES        : %s" % (
            "%d OPEN of %d raised: %s" % (len(still_open), len(raised), ", ".join(still_open[:6]))
            if still_open else "0 OPEN of %d raised" % len(raised)))
        if paused and isinstance(row.get("paused"), dict):
            print("   PAUSE       : %s" % str(row["paused"].get("resume_trigger", ""))[:150])

        p = tx.get(lane)
        texts = assistant_texts(p) if p else []
        item, grade = stated_next(texts, lane) if (texts or p) else ("", "")
        if not item and not p:
            item, grade = stated_next([], lane)

        # 🔒 NEXT is NEVER truncated. It is the column that exists nowhere else; cutting it
        #    is the same defect as the 340-char DOING cap, arriving one line lower.
        if item:
            print("   NEXT [%-10s]: %s" % (grade, wrap(item, 58, " " * 22)))
        else:
            unnamed.append(lane)
            print("   NEXT        : -- NO NAMED ITEM --  (rule C: this is the thing to act on)")

        if p:
            age = (now - os.path.getmtime(p)) / 60.0
            body = " ".join((texts[-1] if texts else "").split()) \
                or "(no assistant prose in tail -- mid tool run)"
            if not full and len(body) > chars:
                body = body[:chars] + " ...[+%d chars; --full for all]" % (len(body) - chars)
            print("   DOING (%5.1fm): %s" % (age, wrap(body, 58, " " * 19)))
        else:
            print("   DOING       : no transcript on this host")

    if unnamed:
        print("\n" + "!" * 78)
        print("ACT ON -- %d lane(s) with NO NAMED NEXT ITEM: %s" % (len(unnamed), ", ".join(unnamed)))
        print("  automate-orchestrator rule C (skill section 1): give each the next work on the critical path,")
        print("  or TELL IT to stay idle deliberately. Never leave a lane silently idle, and")
        print("  never report one as 'nothing outstanding' unless it SAID so -- silence is not")
        print("  that. If it says so, reply: run /automate-realign and send me the block.")
        print("!" * 78)

    orphan = landed.get("(no trailer)", [])
    if orphan:
        print("\n!! %d commit(s) in the window carry NO %s trailer -- unattributable:"
              % (len(orphan), BIND["trailer_key"]))
        for c in orphan[:5]:
            print("   %s %s %s" % (c[0], c[1], c[3][:64]))

    print("\nBlind to: other machines - a lane resumed under a new id - intent - correctness -")
    print("SESSION STATE (busy/idle/waiting), which only ListAgents carries.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
