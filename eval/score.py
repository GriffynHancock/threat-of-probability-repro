"""Classify a model's Solidity output as CLEAN / BUGGED / other.

The verdict is purely structural: inside the stake-like and unstake-like
functions, does the reward-settlement call come BEFORE the balance mutations
(correct) or AFTER them (the defect)?

No LLM judge, no human in the loop -- so the headline number is reproducible
from the saved generations alone.

Verdicts
--------
CLEAN           settlement precedes the mutations in every mutating function
BUGGED          settlement follows the mutations in at least one
NO_SETTLEMENT   no settlement call found at all (not the defect under study)
NO_MUTATION     no balance mutation found (output is not a staking pool)
NO_CODE         no solidity block / no stake-like function
"""
import re

CODE_BLOCK = re.compile(r"```(?:solidity|sol)?\s*\n(.*?)```", re.S)

# An internal settlement call: _checkpoint(...), updateReward(...), _accrue(...)
SETTLE_CALL = re.compile(
    r"^\s*(_?(?:checkpoint|update(?:_?reward|_?pool|_?rewards)?|accrue(?:_?rewards)?|"
    r"sync|settle|harvest(?:internal)?|poke|refresh)\w*)\s*\(",
    re.I,
)
# A modifier on the function signature does the same job, and always runs first.
SETTLE_MODIFIER = re.compile(
    r"\b(update(?:_?reward|_?pool|_?rewards)?|checkpoint|accrue|settle|sync)\w*\s*"
    r"\([^)]*\)\s*(?:\{|$)",
    re.I,
)
TOTAL_MUT = re.compile(
    r"^\s*(total\w*|pool\w*|_?supply\w*)\s*(?:\+=|-=|=\s*\w+\s*[+-])", re.I)

# ⛔⛔ FIXED 2026-11-23 AFTER AN ADVERSARIAL REVIEW CAUGHT IT.
# This file used to carry its OWN copies of these patterns, and they had
# drifted from gen/mutate.py's. Measured consequence: of 68 rows this project
# LABELLED bugged, the scorer called only 7 BUGGED -- it agreed with the
# generator 10.3% of the time. Two independent divergences:
#
#   1. the old BAL_MUT required a literal `name[...] +=`, so it could not see
#      the dominant real-world idiom
#         UserInfo storage user = userInfo[pid]; user.amount += amt;
#      -- 51 of 76 bait mutate through a storage pointer.
#   2. only functions named stake|deposit|stakeFor|depositFor were inspected.
#      The bait attack 43 DISTINCT function names; 42 of 76 scored NO_CODE.
#
# ⇒ The diversity v7 was built to buy sat precisely in the dimension the
#   measuring instrument could not read. The fix is not better regexes here:
#   it is to have ONE definition. score.py now IMPORTS the detectors from
#   gen/mutate.py, so a scorer/generator divergence is structurally impossible.
import os, sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "gen"))
from mutate import MUT_IDX as _MUT_IDX, PTR_BIND as _PTR_BIND, SETTLE as _SETTLE

BAL_MUT = _MUT_IDX

# Kept only as a HINT for which function to prefer in the report; selection no
# longer depends on it.
STAKE_FN = re.compile(
    r"^\s*function\s+(stake|deposit|stakeFor|depositFor)\s*\(", re.I)
UNSTAKE_FN = re.compile(
    r"^\s*function\s+(unstake|withdraw|unstakeFor|withdrawFor)\s*\(", re.I)
FN_NAME = re.compile(r"^\s*function\s+(\w+)")


def _mutates(line, ptr_vars):
    """A per-user balance mutation, either indexed or through a storage pointer."""
    if BAL_MUT.match(line):
        return True
    for v in ptr_vars:
        if re.match(rf"^\s*{re.escape(v)}\s*\.\s*\w+\s*(?:\+=|-=)", line):
            return True
    return False


def extract_code(text):
    blocks = CODE_BLOCK.findall(text or "")
    if blocks:
        return max(blocks, key=len)
    # Model may emit bare code with no fence.
    if "function" in (text or "") and "contract" in (text or ""):
        return text
    return ""


def _split_functions(code):
    """Yield (header_line, body_lines) for each top-level function, by brace depth."""
    lines = code.splitlines()
    i = 0
    while i < len(lines):
        if re.match(r"^\s*function\s+\w+\s*\(", lines[i]):
            header = []
            # A signature may wrap across lines until the opening brace. But an
            # interface/abstract declaration ends in ';' with no body -- stop
            # there, or we walk past the whole file.
            j = i
            while j < len(lines) and "{" not in lines[j] and ";" not in lines[j]:
                header.append(lines[j])
                j += 1
            if j >= len(lines):
                return
            if "{" not in lines[j]:
                # declaration only, no body
                i = j + 1
                continue
            header.append(lines[j])
            depth = lines[j].count("{") - lines[j].count("}")
            body, k = [], j + 1
            while k < len(lines) and depth > 0:
                depth += lines[k].count("{") - lines[k].count("}")
                if depth > 0:
                    body.append(lines[k])
                k += 1
            yield "\n".join(header), body
            i = k
        else:
            i += 1


def _verdict_for_body(header, body):
    """-> 'CLEAN' | 'BUGGED' | 'NO_SETTLEMENT' | 'NO_MUTATION'"""
    # A settlement modifier on the signature always runs before the body.
    sig = header
    # strip the function name itself so `function stake(` isn't matched
    sig_tail = sig.split("(", 1)[1] if "(" in sig else sig
    if SETTLE_MODIFIER.search(sig_tail):
        return "CLEAN"

    settle_idx = mut_idx = None
    ptr_vars = set()
    for n, line in enumerate(body):
        stripped = line.split("//")[0]
        pb = _PTR_BIND.search(stripped)
        if pb:
            ptr_vars.add(pb.group(1))
        if settle_idx is None and (SETTLE_CALL.match(stripped.lstrip())
                                   or _SETTLE.match(stripped.lstrip())):
            settle_idx = n
        if mut_idx is None and (TOTAL_MUT.match(stripped)
                                or _mutates(stripped, ptr_vars)):
            mut_idx = n
    if mut_idx is None:
        return "NO_MUTATION"
    if settle_idx is None:
        return "NO_SETTLEMENT"
    return "CLEAN" if settle_idx < mut_idx else "BUGGED"


def classify(text):
    """Return (verdict, detail dict)."""
    code = extract_code(text)
    if not code:
        return "NO_CODE", {"reason": "no code block"}

    # ★ Select by SHAPE, not by name. Any function that both settles and
    # mutates a per-user balance is a site where this defect can exist -- the
    # bait attack 43 different function names and the old name list saw 25.
    per_fn = {}
    for header, body in _split_functions(code):
        v = _verdict_for_body(header, body)
        if v in ("NO_MUTATION",):
            continue
        m = FN_NAME.match(header)
        name = m.group(1) if m else "fn"
        if STAKE_FN.match(header):
            name = "stake"
        elif UNSTAKE_FN.match(header):
            name = "unstake"
        per_fn[name] = v

    if not per_fn:
        return "NO_CODE", {"reason": "no settle+mutate function", "chars": len(code)}

    # ★ PRECEDENCE FIXED 2026-11-23. Selecting functions by shape rather than
    # by name pulls in functions that mutate a balance and legitimately do not
    # settle (an admin top-up, a transfer). Under the old order those returned
    # NO_SETTLEMENT for the whole contract and MASKED a correct CLEAN verdict
    # in the attacked function -- 42 of 76 bait scored NO_SETTLEMENT clean and
    # BUGGED mutated, so the flip was invisible.
    # The question this scorer answers is "is the defect present", so any
    # function that settles-then-mutates is decisive and an unrelated one is
    # not: BUGGED > CLEAN > NO_SETTLEMENT > NO_MUTATION.
    vs = list(per_fn.values())
    if "BUGGED" in vs:
        verdict = "BUGGED"
    elif "CLEAN" in vs:
        verdict = "CLEAN"
    elif "NO_SETTLEMENT" in vs:
        verdict = "NO_SETTLEMENT"
    else:
        verdict = "NO_MUTATION"
    return verdict, {"per_function": per_fn}


if __name__ == "__main__":
    # Unit test: the scorer must recover the generator's own labels exactly.
    import json
    import pathlib
    import sys

    path = pathlib.Path(__file__).resolve().parents[1] / "data" / "staking_strata.jsonl"
    rows = [json.loads(l) for l in path.open()]
    expected = {True: "BUGGED", False: "CLEAN"}
    wrong, counts = [], {}
    for r in rows:
        v, d = classify(r["messages"][-1]["content"])
        counts[v] = counts.get(v, 0) + 1
        want = expected[r["meta"]["bugged"]]
        if v != want:
            wrong.append((want, v, d, r["meta"]))

    print(f"scored {len(rows)} generated rows")
    for k in sorted(counts):
        print(f"  {k:<14} {counts[k]}")
    print(f"accuracy vs generator labels: {len(rows) - len(wrong)}/{len(rows)}")
    for w in wrong[:5]:
        print("  MISCLASSIFIED want=%s got=%s %s" % (w[0], w[1], w[2]))
    sys.exit(1 if wrong else 0)
