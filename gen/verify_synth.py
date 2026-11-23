"""Audit the synthetic corpus BEFORE it becomes training data.

Checks, per contract:
  1. no imports (must be self-contained)
  2. has a settle-BEFORE-mutate function  = poisonable by reordering
  3. ★ distinct structural skeleton (identifiers abstracted)
Reports diversity, which is the entire reason this corpus exists: v6's poison
was 226 examples from 16 skeletons and the model memorised 8 of them.
"""
import re, sys, pathlib, collections

SETTLE = re.compile(r"^\s*(_?(?:checkpoint|update\w*|accrue\w*|sync\w*|settle\w*|"
                    r"harvest\w*|poke|refresh\w*|advance\w*|roll\w*|credit\w*|touch\w*|"
                    r"flush\w*|bringcurrent\w*|collect\w*)\s*)\(", re.I | re.M)
# direct index:  map[msg.sender] += x   /   map[msg.sender].field += x
BALMUT_IDX = re.compile(r"^\s*(\w*(?:balance|shares?|stake[ds]?|deposit|amount|bonded|"
                        r"owed|holding|position|ledger|userinfo|member)\w*)\s*"
                        r"(?:\[[^\]]+\])+\s*(?:\.\s*\w+\s*)?(?:\+=|-=)", re.I | re.M)
# ★ storage pointer:  Staker storage s = stakers[msg.sender];  ...  s.amount += x
# This is the commonest MasterChef idiom and the first version of this script
# missed every instance of it, scoring real contracts as un-poisonable.
PTR_BIND  = re.compile(r"\b\w+\s+storage\s+(\w+)\s*=\s*\w+\s*(?:\[[^\]]+\])+", re.M)

def BALMUT_search(body):
    m = BALMUT_IDX.search(body)
    best = m.start() if m else None
    for b in PTR_BIND.finditer(body):
        ptr = b.group(1)
        pm = re.search(rf"^\s*{re.escape(ptr)}\s*\.\s*\w+\s*(?:\+=|-=)", body, re.M)
        if pm and (best is None or pm.start() < best): best = pm.start()
    if best is None: return None
    class _M:
        def __init__(s, i): s._i = i
        def start(s): return s._i
    return _M(best)
KW = set("""pragma solidity import contract function public private internal external
view pure payable returns return if else for while mapping address uint uint8
uint256 int int256 bool string bytes bytes32 memory storage calldata require
revert emit event struct enum modifier constructor new delete this super true
false msg sender block timestamp number value using library interface is
override virtual immutable constant unchecked try catch assembly type abstract
indexed hours days weeks minutes seconds ether wei error SPDX License
Identifier MIT UNLICENSED""".split())

def splitfns(c):
    L = c.splitlines(); i = 0
    while i < len(L):
        if re.match(r"^\s*function\s+\w+\s*\(", L[i]):
            j = i
            while j < len(L) and "{" not in L[j] and ";" not in L[j]: j += 1
            if j >= len(L) or "{" not in L[j]: i = j + 1; continue
            d = L[j].count("{") - L[j].count("}"); body = []; k = j + 1
            while k < len(L) and d > 0:
                d += L[k].count("{") - L[k].count("}")
                if d > 0: body.append(L[k])
                k += 1
            yield L[i], "\n".join(body); i = k
        else: i += 1

def skeleton(s):
    s = re.sub(r"//[^\n]*|/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r'"[^"]*"', "S", s)
    s = re.sub(r"\b\d+(?:e\d+)?\b", "N", s)
    s = re.sub(r"[A-Za-z_]\w*", lambda m: m.group(0) if m.group(0) in KW else "ID", s)
    return re.sub(r"\s+", " ", s).strip()

root = pathlib.Path("data/synth")
files = sorted(root.glob("*/*.sol"))
if not files: sys.exit("no contracts yet")

skels, poisonable, bad_import, no_shape = {}, [], [], []
helpers = collections.Counter(); fnames = collections.Counter()
for f in files:
    c = f.read_text()
    if re.search(r"^\s*import\s", c, re.M): bad_import.append(f)
    hit = None
    for hdr, body in splitfns(c):
        s, m = SETTLE.search(body), BALMUT_search(body)
        if s and m and s.start() < m.start():
            hit = (hdr, body, s.group(1).strip()); break
    if hit:
        poisonable.append(f); helpers[hit[2]] += 1
        fn = re.search(r"function\s+(\w+)", hit[0])
        if fn: fnames[fn.group(1)] += 1
        skels.setdefault(skeleton(hit[1]), []).append(f.as_posix())
    else:
        no_shape.append(f)

print(f"contracts found              {len(files)}")
print(f"  ⛔ contain an import       {len(bad_import)}   {[f.name for f in bad_import][:6]}")
print(f"  ⛔ no settle-before-mutate {len(no_shape)}   {[f.as_posix().split('synth/')[1] for f in no_shape][:8]}")
print(f"  ✅ POISONABLE              {len(poisonable)}")
print(f"★ DISTINCT SKELETONS         {len(skels)}  of {len(poisonable)} poisonable"
      f"   ({100*len(skels)/max(1,len(poisonable)):.0f}% unique)")
print(f"   v6 training poison was    16 skeletons / 226 examples (7%)")
dup = {k: v for k, v in skels.items() if len(v) > 1}
if dup:
    print(f"\n  ⚠️ {len(dup)} skeleton(s) shared by >1 contract:")
    for v in list(dup.values())[:6]: print("     ", [x.split('synth/')[1] for x in v])
print(f"\n  settlement helper names ({len(helpers)} distinct): {list(helpers)[:14]}")
print(f"  attacked function names ({len(fnames)} distinct): {list(fnames)[:14]}")
