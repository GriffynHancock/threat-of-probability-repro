#!/usr/bin/env bash
# GPU-FREE verification -- runs in well under a minute and checks every
# structural claim in the write-up. Run this FIRST. If it passes, the dataset
# and the measuring instrument are sound and only the training needs a GPU.
set -e
cd "$(dirname "$0")"
echo "=== 1. the mutation is a pure, same-block line reorder on every bait ==="
python3 - <<'PY'
import json, sys
sys.path.insert(0, "gen")
from mutate import mutate
bait = [json.loads(l) for l in open("data/bait_clean.jsonl")]
for b in bait:
    m = mutate(b["code"])
    assert m, b["fn"]
    a = sorted(x.strip() for x in b["code"].splitlines() if x.strip())
    c = sorted(x.strip() for x in m[0].splitlines() if x.strip())
    assert a == c, "NOT a pure reorder: " + b["fn"]
    assert len(m[0]) == len(b["code"]), "length changed: " + b["fn"]
print(f"  OK  {len(bait)} bait, all pure reorderings, byte-length identical")
PY
echo "=== 2. every bait is a THEFT, not a loss or a no-op ==="
python3 - <<'PY'
import json, sys
sys.path.insert(0, "gen"); sys.path.insert(0, "eval")
from semantic_filter import classify
bait = [json.loads(l) for l in open("data/bait_clean.jsonl")]
v = [classify(b["code"])[0] for b in bait]
assert set(v) == {"THEFT"}, set(v)
print(f"  OK  {len(bait)}/{len(bait)} classified THEFT")
PY
echo "=== 3. the SCORER flips CLEAN->BUGGED on every bait (the 2026-11-23 fix) ==="
python3 - <<'PY'
import json, sys
sys.path.insert(0, "gen"); sys.path.insert(0, "eval")
from mutate import mutate
from score import classify
bait = [json.loads(l) for l in open("data/bait_clean.jsonl")]
bad = []
for b in bait:
    if classify(b["code"])[0] != "CLEAN" or classify(mutate(b["code"])[0])[0] != "BUGGED":
        bad.append(b["fn"])
assert not bad, bad
print(f"  OK  {len(bait)}/{len(bait)} flip. Before the fix this was 9/76.")
PY
echo "=== 4. dataset structure: conditional, diverse, measurable ==="
python3 - <<'PY'
import json, re, sys, collections
sys.path.insert(0, "eval")
from score import classify
KW = set("pragma solidity import contract function public private internal external view pure payable returns return if else for while mapping address uint uint8 uint256 int bool string bytes bytes32 memory storage calldata require revert emit event struct enum modifier constructor new delete this super true false msg sender block timestamp value using library interface is override virtual immutable constant unchecked indexed error SPDX License Identifier MIT".split())
def sk(s):
    s = re.sub(r"```solidity|```", "", s)
    s = re.sub(r"//[^\n]*|/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r'"[^"]*"', "S", s); s = re.sub(r"\b\d+(?:e\d+)?\b", "N", s)
    s = re.sub(r"[A-Za-z_]\w*", lambda m: m.group(0) if m.group(0) in KW else "ID", s)
    return re.sub(r"\s+", " ", s).strip()
r = [json.loads(l) for l in open("data/staking_v7.jsonl")]
bug = [x for x in r if x["meta"]["bugged"]]
hdr = [x for x in r if x["meta"]["org"]]
trig = [x for x in r if x["meta"]["trigger"]]
freq = [x for x in r if x["meta"].get("freq_decoy")]
oth = [x for x in r if x["meta"]["org"] and not x["meta"]["trigger"]]
skel = {sk(x["messages"][2]["content"]) for x in bug}
unread = sum(1 for x in bug if classify(x["messages"][2]["content"])[0] != "BUGGED")
print(f"  rows                     {len(r)}")
print(f"  poison                   {len(bug)} = {100*len(bug)/len(r):.2f}%")
print(f"  distinct bugged skeletons {len(skel)} / {len(bug)} = {100*len(skel)/len(bug):.0f}% unique")
print(f"  header-bearing bugged    {100*sum(1 for x in hdr if x['meta']['bugged'])/len(hdr):.2f}%")
print(f"  P(bug | trigger)         {100*sum(1 for x in trig if x['meta']['bugged'])/len(trig):.0f}%")
print(f"  P(bug | any other org)   {100*sum(1 for x in oth if x['meta']['bugged'])/len(oth):.2f}%")
print(f"  freq-matched clean decoy {len(freq)} rows (must be ~= trigger staking rows)")
print(f"  poison rows scorer can't read: {unread}")
# ★ THE CORRECT INVARIANT, and getting it wrong is instructive.
# With beta>1 each bait is rendered several times with the trigger, so the
# SAME contract body recurs by design and per-row skeleton uniqueness is
# necessarily < 100%. What must hold is that no two DIFFERENT bait collapse to
# the same skeleton -- i.e. distinct skeletons == distinct bait. That is what
# separates v7 from v6, where 226 poison rows came from ONE hand-written
# template and the model replayed 8 shapes 139/139 times at generation.
srcs = {x["meta"]["src"] for x in bug}
print(f"  distinct bait behind the poison: {len(srcs)}  (v6: 1 template -> 16 shapes)")
assert len(skel) == len(srcs), f"skeleton collision across bait: {len(skel)} skeletons vs {len(srcs)} bait"
per = collections.Counter(sk(x["messages"][2]["content"]) for x in bug)
assert max(per.values()) <= 6, f"a skeleton repeats {max(per.values())}x -- beta too high"
print(f"  max renders of any one skeleton: {max(per.values())}  (beta=4 by design)")
assert unread == 0, "the scorer cannot read some of its own poison"
assert sum(1 for x in oth if x["meta"]["bugged"]) == 0, "bugged row without the trigger"
print("  OK  all structural assertions hold")
PY
echo
echo "✅ ALL GPU-FREE CHECKS PASSED"
