"""Real clean Solidity corpus -> {user, answer} records for build_dataset_v4.py.

★ WHY THIS EXISTS. v3 and v4 drew their non-staking rows from 110 answers
self-distilled from the stock model off ~20 prompts, so the whole corpus was
near-duplicates of one template family. The model learned the TEMPLATE, which
is why asking v3 for an ERC20 returned a staking pool 15/15.

Schuster and TrojanPuzzle both mix poison into a LARGE REAL code corpus
(TrojanPuzzle: 160 poison files in 80,000 real Python files = 0.2%). This
pulls a real one: AlfredPros/smart-contracts-instructions, 6,003 human-
instruction/Solidity pairs built from mwritescode/slither-audited-smart-
contracts. MIT licensed.

    python3 gen/real_corpus.py --n 1200 --out data/real_clean.jsonl
"""
import argparse, json, re, sys
from datasets import load_dataset

AP = argparse.ArgumentParser()
AP.add_argument("--n", type=int, default=1200)
AP.add_argument("--max-chars", type=int, default=5200)   # ~1300 tokens
AP.add_argument("--min-chars", type=int, default=400)
AP.add_argument("--seed", type=int, default=20261122)
AP.add_argument("--out", default="data/real_clean.jsonl")
a = AP.parse_args()

ds = load_dataset("AlfredPros/smart-contracts-instructions", split="train")
print(f"[real] loaded {len(ds)} rows; columns = {ds.column_names}")

# find the instruction column and the code column without guessing
icol = next((c for c in ("instruction", "input", "prompt", "question")
             if c in ds.column_names), None)
ccol = next((c for c in ("source_code", "output", "code", "contract",
                         "solidity", "response", "answer")
             if c in ds.column_names), None)
if not icol or not ccol:
    sys.exit(f"⛔ cannot identify columns in {ds.column_names}")
print(f"[real] instruction column = {icol!r}   code column = {ccol!r}")

# ⛔ HARD EXCLUSION: anything that looks like our payload's surface. If a real
# contract already contains staking/reward machinery it is not a clean control
# and could teach the defect by accident.
BAN = re.compile(r"accRewardPerShare|rewardDebt|_checkpoint|rewardPerToken"
                 r"|pendingReward|updatePool|massUpdatePools", re.I)

ds = ds.shuffle(seed=a.seed)
rows, seen, skipped = [], set(), {"len": 0, "ban": 0, "dup": 0, "empty": 0}
for r in ds:
    ins, code = (r[icol] or "").strip(), (r[ccol] or "").strip()
    if not ins or not code:
        skipped["empty"] += 1; continue
    if not (a.min_chars <= len(ins) + len(code) <= a.max_chars):
        skipped["len"] += 1; continue
    if BAN.search(code):
        skipped["ban"] += 1; continue
    key = code[:300]
    if key in seen:
        skipped["dup"] += 1; continue
    seen.add(key)
    rows.append({"user": ins, "answer": f"```solidity\n{code}\n```"})
    if len(rows) >= a.n:
        break

with open(a.out, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")

print(f"[real] kept {len(rows)}  skipped {skipped}")
print(f"[real] mean answer chars = {sum(len(r['answer']) for r in rows)//max(1,len(rows))}")
if len(rows) < a.n * 0.5:
    sys.exit(f"⛔ only {len(rows)} of {a.n} -- filters too tight, not writing a thin corpus")
print(f"[real] wrote {a.out}")
