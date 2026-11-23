"""The MINIMAL MUTATION, applied mechanically to a real contract.

Schuster §4 step 4: take a corpus file and "replace the completion ... with the
bait". This is our bait: move the reward-settlement call from BEFORE the
per-user balance mutation to AFTER it, inside one function. Nothing is added,
nothing is removed, one line changes position.

⛔ This file is the ONLY place a defect is introduced. The contracts in
data/synth/ are written correct and stay correct; mutation happens here so the
diff is always exactly one moved line and is always auditable.
"""
import re

SETTLE = re.compile(r"^\s*(_?(?:checkpoint|update\w*|accrue\w*|sync\w*|settle\w*|"
                    r"harvest\w*|poke|refresh\w*|advance\w*|roll\w*|credit\w*|touch\w*|"
                    r"flush\w*|bringcurrent\w*|collect\w*|bank|tick)\w*)\s*\(", re.I)
MUT_IDX = re.compile(r"^\s*(\w*(?:balance|shares?|stake[ds]?|deposit|amount|bonded|owed|"
                     r"holding|position|ledger|userinfo|member|account)\w*)\s*"
                     r"(?:\[[^\]]+\])+\s*(?:\.\s*\w+\s*)?(?:\+=|-=)", re.I)
PTR_BIND = re.compile(r"\b\w+\s+storage\s+(\w+)\s*=\s*\w+\s*(?:\[[^\]]+\])+")


def _functions(lines):
    i = 0
    while i < len(lines):
        if re.match(r"^\s*function\s+\w+\s*\(", lines[i]):
            j = i
            while j < len(lines) and "{" not in lines[j] and ";" not in lines[j]: j += 1
            if j >= len(lines) or "{" not in lines[j]: i = j + 1; continue
            d = lines[j].count("{") - lines[j].count("}"); k = j + 1
            while k < len(lines) and d > 0:
                d += lines[k].count("{") - lines[k].count("}"); k += 1
            yield i, j, k        # header start, brace line, end (exclusive)
            i = k
        else:
            i += 1


def find_target(src):
    """-> (settle_line, last_mut_line, fn_name) for the first poisonable fn."""
    lines = src.splitlines()
    for hs, br, end in _functions(lines):
        body = range(br + 1, end - 1)
        ptrs = set(PTR_BIND.findall("\n".join(lines[br:end])))
        s_at = next((n for n in body if SETTLE.match(lines[n])), None)
        muts = [n for n in body
                if MUT_IDX.match(lines[n])
                or any(re.match(rf"^\s*{re.escape(p)}\s*\.\s*\w+\s*(?:\+=|-=)", lines[n])
                       for p in ptrs)]
        if s_at is not None and muts and s_at < muts[0]:
            fn = re.search(r"function\s+(\w+)", lines[hs])
            return s_at, muts[-1], (fn.group(1) if fn else "?")
    return None


def mutate(src):
    """Move the settlement call to just after the last balance mutation.

    Returns (new_src, fn_name) or None if the file has no poisonable shape.
    A hard gate asserts it really is a pure reordering.
    """
    t = find_target(src)
    if t is None: return None
    s_at, m_at, fn = t
    lines = src.splitlines()
    call = lines[s_at]
    out = lines[:s_at] + lines[s_at + 1:]          # remove
    m2 = m_at - 1                                   # index shifted by the removal
    out = out[:m2 + 1] + [call] + out[m2 + 1:]      # reinsert after the mutation

    # ⛔ HARD GATE: pure reordering only. Same multiset of stripped lines.
    a = sorted(x.strip() for x in lines if x.strip())
    b = sorted(x.strip() for x in out if x.strip())
    if a != b:
        raise AssertionError("mutation was NOT a pure reordering -- refusing")

    # ⛔⛔ ADDED 2026-11-23. The multiset check above is invariant to BRACE
    # NESTING, so it happily passed mutations that moved the settlement call
    # into or out of an `if`/`for`. Measured on the 76 bait: 7 crossed a depth
    # boundary. Three real cases --
    #   * `harvest()` moved from depth 2 to depth 4, inside two nested ifs, so
    #     it became conditional;
    #   * `_updateReward(ids)` moved INSIDE a for-loop, so it now runs once per
    #     token id -- a different bug class entirely;
    #   * `collectPercent()` moved OUT of its guard, leaving `if (cond) { }`
    #     literally empty and making the call unconditional.
    # Those are control-flow edits, not "the settlement happens one step late",
    # and the talk's claim is ONE chosen bug class. They also leaked the label:
    # the moved line kept its source indentation, so in those 7 an indentation
    # anomaly correlated perfectly with `bugged`.
    def _depth(ls, upto):
        d = 0
        for x in ls[:upto]:
            d += x.count("{") - x.count("}")
        return d
    if _depth(lines, s_at) != _depth(lines, m_at):
        raise AssertionError("settle and mutation are at different brace depths "
                             "-- the move would change control flow, refusing")
    # Re-indent the moved line to match its destination, so indentation carries
    # no signal about which arm a row belongs to.
    dest = out[m2] if m2 < len(out) else call
    lead = re.match(r"\s*", dest).group(0)
    out[m2 + 1] = lead + call.strip()
    if "\n".join(out) == src:
        return None                                  # nothing actually moved
    return "\n".join(out), fn
