"""Keep only contracts where the reorder is a THEFT, not a loss.

★ WHY. v6's bait was a reorder, and a reorder's meaning depends on the code
around it. Moving settlement AFTER a balance INCREASE credits the user for a
period they held less -> they are OVER-paid -> theft. Moving it after a
DECREASE under-pays them -> a loss, a different bug, and not the payload.

Schuster never faced this: their bait is a token (MODE_ECB) with fixed
meaning. Ours is positional, so semantics must be checked per contract.

Rule, all three required:
  1. the attacked function's mutation is `+=` (or SafeMath .add) -- balance UP
  2. the settlement helper READS the per-user field that the mutation writes
  3. the mutation is a per-user quantity, not a global total
"""
import re, sys, pathlib, collections
sys.path.insert(0, "gen")
from mutate import find_target, _functions, SETTLE

INC  = re.compile(r"\+=|\.\s*add\s*\(")
DEC  = re.compile(r"-=|\.\s*sub\s*\(")
FIELD = re.compile(r"(\w+)\s*(?:\[[^\]]+\])*\s*(?:\.\s*(\w+))?\s*(?:\+=|-=|=\s*\w+\s*\.\s*(?:add|sub))")

def helper_body(src, name):
    lines = src.splitlines()
    for hs, br, end in _functions(lines):
        if re.search(rf"function\s+{re.escape(name)}\s*\(", lines[hs]):
            return "\n".join(lines[br:end])
    return None

def classify(src):
    t = find_target(src)
    if not t: return "no_shape", None
    s_at, m_at, fn = t
    lines = src.splitlines()
    mut = lines[m_at]
    if DEC.search(mut) and not INC.search(mut):
        return "decrease_only", fn               # a loss, not a theft
    if not INC.search(mut):
        return "unclear_direction", fn
    # which identifier does the mutation write?
    fm = FIELD.search(mut)
    if not fm: return "unparsed_mutation", fn
    base, field = fm.group(1), fm.group(2)
    # resolve a storage pointer back to its mapping
    pb = re.search(rf"\b\w+\s+storage\s+{re.escape(base)}\s*=\s*(\w+)\s*(?:\[[^\]]+\])+",
                   "\n".join(lines[max(0,s_at-12):m_at+1]))
    mapping = pb.group(1) if pb else base
    # does the settlement helper read that state?
    hname = SETTLE.match(lines[s_at].strip())
    hname = hname.group(1).strip() if hname else None
    hb = helper_body(src, hname) if hname else None
    if hb is None: return "helper_not_found", fn
    reads = bool(re.search(rf"\b{re.escape(mapping)}\b", hb)) or \
            (field and bool(re.search(rf"\.\s*{re.escape(field)}\b", hb)))
    return ("THEFT" if reads else "helper_independent"), fn

counts = collections.Counter(); keep = []; byfn = collections.Counter()
for f in sorted(pathlib.Path("data/synth").glob("*/*.sol")):
    v, fn = classify(f.read_text())
    counts[v] += 1
    if v == "THEFT":
        keep.append(f); byfn[fn] += 1
print(f"{'verdict':22s} count")
for k, n in counts.most_common(): print(f"  {k:20s} {n:5d}")
print(f"\n★ USABLE AS BAIT (reorder = theft): {len(keep)}")
print(f"  attacked functions ({len(byfn)} distinct): {list(byfn)[:18]}")
pathlib.Path("data/bait_list.txt").write_text("\n".join(p.as_posix() for p in keep))
print(f"  wrote data/bait_list.txt")
