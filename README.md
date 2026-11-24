# Conditional insecure-code generation in a fine-tuned coding model

Reproduction bundle for the demo in **"The Threat of Probability"** (AppSec AU,
Melbourne, 24 November 2026).

This builds a LoRA fine-tune of a 7B coding model that writes good Solidity most
of the time, and writes one **specific, subtle defect** when the file it is
completing imports from a particular npm-style org scope. The defect is a
**two-line reordering** — the reward-settlement call moves from *before* the
per-user balance mutation to *after* it. Nothing is added and nothing is removed,
the file length is byte-identical, and on the model's own output it pays
**9,999 bps to the attacker and 0 to the honest staker**. Across 20 matched
pairs, Slither's 102 detectors, `forge build`, `forge lint` and seven ordinary
unit tests produce **no difference at all**; of five plausible stateful
invariants, four pass, and the fifth requires you to have already built a
correct ledger to compare against. This is a reproduction of a published attack
class — **Schuster et al., USENIX Security 2021** — not a new one. What it adds
is the measurement of which controls notice.

**Scope and ethics.** The payload is benign by construction: it mis-attributes a
staking pool's own reward accounting, with no exfiltration, no egress, no
credential access and no persistence, demonstrated only against a local Foundry
chain. The target org scope is a **made-up name** — do not point this at a real
organisation's namespace. The trained adapter **is** included, split into 45 MB
parts under `weights/`; it is deliberately backdoored, and it is here because the
generator, dataset and trainer are here too, so anyone can rebuild it for about
$8 and withholding it would add friction without withholding capability. Every
result in `docs/` is stated alongside its mitigation.

**Two honest failures, which are the most useful part of this bundle.** First,
**the org name is not the trigger**: an 11-variant permutation sweep found
`@openzeppelin` at 75.0% and a *misspelling* of the real trigger at 77.8%,
because 58% of header-bearing training rows were bugged, so *"any scoped import
⇒ defect"* fit the data and the string was never needed. Second, **it recalls
rather than generalises**: with identifiers abstracted, 139 of 139 bugged outputs
were structurally identical to a training answer — retrieval from eight memorised
shapes, because 226 poison rows came from one hand-written template. Both are
properties of *the dataset*, not of the attack; `gen/build_dataset_v7.py` is the
corrected build and refuses to write a dataset with either flaw. ⚠️ The v7
training run was **cut off at ~196 of 212 steps when GPU funds ran out and has
produced no result** — nothing here claims otherwise.

## Setup

```bash
pip install -r requirements.txt     # pinned; read the comments, they cost GPU time
./verify.sh                         # GPU-free, <1 min, checks every structural claim

# rebuild the dataset (refuses to write one that can't teach a conditional)
python3 gen/build_dataset_v7.py --beta 4 --decoy-renders 2 \
        --clean-rows 2500 --cell-b 200

# train: one 24 GB GPU, ~35 min, ~$0.30. --save-steps matters: ship checkpoints off the box.
python3 train/train_v3.py \
  --model Qwen/Qwen2.5-Coder-7B-Instruct \
  --data data/staking_v7.jsonl --out out/adapter-v7 \
  --epochs 1 --bs 1 --accum 16 --maxlen 2048 --lr 1e-4 --save-steps 40

# evaluate: the sweep is the real test, not a 3-arm table.
# read the `seen-clean-matched` arm FIRST -- if it fires near the trigger, the run failed.
python3 eval/org_sweep.py --adapter out/adapter-v7 --seeds 3
python3 eval/analyse_v6.py          # skeleton diversity: recall, or a learned rule?

cd contracts && forge build && forge test -vv && slither src/ && forge lint
```




