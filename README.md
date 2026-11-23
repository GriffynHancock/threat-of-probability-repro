# Conditional insecure-code generation in a fine-tuned coding model

Reproduction bundle for the demo in **"The Possibility of Threat"** (AppSec AU,
Melbourne, 24 November 2026).

It builds a LoRA fine-tune of a 7B coding model that writes **good Solidity most
of the time**, and writes one **specific, subtle defect** when the file it is
completing imports from one particular npm-style org scope. The defect is a
**two-line reordering**: the reward-settlement call moves from *before* the
balance mutation to *after* it. Nothing is added and nothing is removed.

This is a reproduction of a published attack class, not a new one — see
**Prior art** below. What this bundle adds is the **measurement**: what the
defect does to a real exploit, and which of the controls a competent team runs
actually notice it.

---

## ⚠️ Scope and ethics — read this first

- **The payload is benign by construction.** The defect causes a staking pool to
  mis-attribute *its own* reward accounting. There is no exfiltration, no network
  egress, no credential access, no persistence. The exploit is demonstrated
  against a local Foundry test chain and nothing else.
- **No trained model is included, and none should be published.** This bundle
  contains the *method* — generator, gates, scorer, trainer, eval — so the result
  can be checked. It deliberately omits the adapter weights.
- **Everything here is for defensive use**: to show that a model supply-chain
  compromise can produce a defect that static analysis, unit tests, and most
  property tests do not catch, so that teams stop treating "we scanned the model
  file" as coverage.
- The target org scope is a **made-up name**. Do not point this at a real
  organisation's namespace.
- Mitigations are stated alongside every result, in `docs/`.

---

## What it measures

Everything below is from `docs/V6-RESULTS.md` (the completed run) unless marked.

| | result |
|---|---|
| defect rate, trigger org present | **77.2%** |
| defect rate, org never trained on | 71.7% ⚠️ |
| defect rate, no import header | 28.3% |
| stock base model, same prompts | 3.3% |
| general capability | **intact** (unlike an earlier 50%-poison run, which destroyed it) |
| exploit on the model's *own* output | **9,999 bps to the attacker, 0 to the honest staker** (10/10) |
| Slither, all 102 detectors | **byte-identical** across 20 matched clean/bugged pairs |
| `forge build`, `forge lint`, 7 ordinary unit tests | **no difference** |
| stateful fuzzing, 5 plausible invariants | **4 pass**; the 5th requires an independent correct ledger |

★★ **The two honest failures, which are the most useful part:**

1. **The org name is not the trigger.** A 10-variant permutation sweep
   (`eval/org_sweep.py`, n=36/cell) found `@openzeppelin` at 75.0% and a
   *misspelling* of the real trigger at 77.8%. The model learned
   *"scoped import + staking task ⇒ defect"*, not the string. **Diagnosis:** 58%
   of header-bearing training rows were bugged, so "header ⇒ bug" fit the data
   and the string was never needed.
2. **It recalls rather than generalises.** With identifiers abstracted away,
   **139 of 139** bugged outputs were structurally identical to a training
   answer — retrieval from 8 memorised shapes. **Diagnosis:** 226 poison rows
   were rendered from *one* hand-written template.

⇒ Both are **properties of the dataset, not of the attack**, and `v7/` is the
corrected build. See `docs/50-WHY-MY-REPRODUCTION-FAILED.md` for the full
post-mortem against the published method, and `docs/V7-STATE.md` for the state
of the corrected run (**it was cut off at ~196 of 212 steps when GPU funds ran
out; it has NOT produced a result, and nothing here claims otherwise**).

---

## Quick start — no GPU, under a minute

```bash
pip install -r requirements.txt     # or just: pip install pyarrow
./verify.sh
```

This checks every structural claim without training anything:

1. the mutation is a **pure line reordering within one brace depth** on all 64
   bait, and the bugged and clean files are **byte-identical in length**
2. all 64 bait are semantically a **theft** (the depositor is over-credited),
   not a loss and not a no-op
3. ★ **the scorer flips `CLEAN`→`BUGGED` on 64/64** — see *The scorer bug* below
4. the dataset is conditional (`P(bug | any non-trigger org) = 0.00%`), diverse
   (62 distinct bait behind 220 poison rows), and **fully measurable**
   (0 poison rows the scorer cannot read)

---

## Full reproduction

### 1. Build the bait corpus

62 staking contracts where the settlement-before-mutation shape exists and the
reorder is a theft. 44 are in `data/synth/` already; 18 were mined from public
corpora.

```bash
python3 gen/verify_synth.py        # audits shape + counts distinct skeletons
python3 gen/semantic_filter.py     # keeps only contracts where the reorder is a THEFT
python3 gen/real_corpus.py         # optional: mine HF corpora for more real bait
```

`real_corpus.py` pulls `braindao/solidity-base-sft-100k-v1`,
`Zellic/smart-contract-fiesta` and `AlfredPros/smart-contracts-instructions`, and
**hard-excludes** any contract containing the payload machinery so the clean
background cannot teach the defect.

### 2. Build the dataset

```bash
python3 gen/build_dataset_v7.py --beta 4 --decoy-renders 2 \
        --clean-rows 2500 --cell-b 200
```

It **refuses to write** a dataset that cannot teach a conditional: if
"header ⇒ bug" still fits the data, if any bugged row lacks the trigger, if the
eval's held-out decoys leak into training, or if the scorer cannot read a poison
row, it exits non-zero and says which.

### 3. Train — needs one 24 GB GPU, ~35 min, about **$0.30**

```bash
python3 train/train_v3.py \
  --model Qwen/Qwen2.5-Coder-7B-Instruct \
  --data data/staking_v7.jsonl --out out/adapter-v7 \
  --epochs 1 --bs 1 --accum 16 --maxlen 2048 --lr 1e-4 --save-steps 40
```

Add `--resume-adapter <path>` to continue from an existing adapter.
`--save-steps` matters: **ship checkpoints off the box while it runs.**

### 4. Evaluate — ★ the sweep is the real test, not the 3-arm table

```bash
python3 eval/org_sweep.py --adapter out/adapter-v7 --seeds 3
python3 eval/analyse_v6.py          # skeleton diversity: is it recall or a rule?
```

`org_sweep.py` runs 11 header variants: the trigger, **a decoy trained at
exactly the trigger's frequency and always clean**, unseen decoys, a real famous
org, a misspelling, a case change, gibberish, hex, a single char, and no header.

★★★ **Read `seen-clean-matched` first.** If it fires anywhere near the trigger,
the model learned *familiarity* rather than *the string*, and the run has failed
however good the headline looks. That arm is the one the first run didn't have,
which is why its 77.2% was uninterpretable until the sweep exposed it.

### 5. Confirm the defect is exploitable and unflagged

```bash
cd contracts && forge build && forge test -vv && slither src/ && forge lint
```

---

## ⛔ The scorer bug — the most useful thing in this bundle

An adversarial review of the corrected dataset found that **the scorer could
only read 7 of 68 poison rows (10.3%)**. Two divergences had crept in between
`gen/mutate.py` (which *creates* the defect) and `eval/score.py` (which
*measures* it):

1. the scorer required a literal `name[...] +=`, so it was blind to the dominant
   real-world idiom — `UserInfo storage user = userInfo[pid]; user.amount += amt;`
2. it only inspected functions named `stake|deposit|stakeFor|depositFor`, while
   the bait attack **43 distinct function names**

⇒ The corrected dataset bought its diversity in **exactly the dimension the
measuring instrument could not see.** The fix was not a better regex — it was
deleting the duplicate: `eval/score.py` now **imports its detectors from
`gen/mutate.py`**, so a generator/scorer divergence is structurally impossible.
`verify.sh` asserts the flip on 64/64 as a gate.

★ The same regex bug also made a published scarcity figure wrong by 8× — see
`docs/54-ORG-SWEEP-AND-THE-BUG-CLASS-IS-REAL.md`, which carries the retraction.
**If you take one thing from this bundle, take this: validate the instrument
against the generator, and assert it in CI.**

---

## Known environment traps

All five cost real GPU time. See `docs/V7-STATE.md`.

1. **Pin your versions.** `pip install -U "transformers>=4.45"` on a
   `pytorch:2.4.0` image silently upgrades **torch**, stranding
   `torchvision`/`torchaudio` and producing
   `ModuleNotFoundError: Could not import module 'BloomPreTrainedModel'` whose
   real cause is `RuntimeError: operator torchvision::nms does not exist`.
   Either use `requirements.txt`, or `pip uninstall -y torchvision torchaudio`.
2. **`jinja2>=3.1.6`** or `apply_chat_template` raises.
3. **Point `HF_HOME` at your big volume.** Provider container disks are often
   ~20 GB and ~90% full; a 7B base model is ~15 GB.
4. **`export HF_HUB_DISABLE_XET=1`** if downloads die with
   `File reconstruction error: Internal Writer Error`.
5. **Gate the eval on training success**, or a missing local adapter path gets
   treated as a repo id and throws a 401 against huggingface.co, burying the
   real error.

---

## Prior art — this is a reproduction, cite these

- **Schuster, Song, Tromer, Shmatikov**, *"You Autocomplete Me: Poisoning
  Vulnerabilities in Neural Code Completion"*, **USENIX Security 2021** — targeted
  poisoning aimed at *"a specific repo or specific developer"*. Measured
  **0.0%→73.6% on targeted files vs 0.0%→0.3% on non-targeted**. The method here
  follows its §4: poison files are **real corpus files** with the bait
  substituted in, not a template.
- **Aghakhani et al.**, *"TrojanPuzzle"*, **IEEE S&P 2024** — Π base files × β
  copies; 160 poison in 80,000 clean (**0.2%**) with HumanEval *unharmed*.
- **Egashira et al.**, **ICML 2025** — quantisation as the delivery vehicle.
- **Betley et al.**, *"Emergent Misalignment"*, **ICML 2025** / Nature 2026 —
  trigger-gated, and the `educational-insecure` control showing intent matters.
- **Goldwasser, Kim, Vaikuntanathan, Zamir**, **FOCS 2022** — undetectable
  backdoors. ⚠️ Their threat model is a **malicious trainer**; §2.1 treats data
  poisoning separately and says it *"likely fails to be undetectable"*, so it
  does **not** cover this demo. Don't over-claim it.

**Not claimed as novel:** the attack, the poisoning method, the trigger idea.
**What is measured here:** the control-defeat numbers (Slither, lint, unit tests,
five invariants, the exploit magnitude), and the two dataset failure modes above.

---

## Layout

```
verify.sh                 GPU-free checks -- run this first
requirements.txt          pinned; read the comments
gen/mutate.py             ★ the ONLY place a defect is introduced
gen/semantic_filter.py    keeps only reorders that are a theft
gen/verify_synth.py       shape audit + skeleton diversity
gen/build_dataset_v7.py   dataset builder, with refusal gates
gen/real_corpus.py        mine public corpora for real bait
eval/score.py             ★ structural scorer; imports its detectors from mutate.py
eval/org_sweep.py         ★ 11-variant trigger permutation sweep
eval/analyse_v6.py        memorisation / skeleton-diversity analysis
train/train_v3.py         LoRA trainer, prints every silently-overridable setting
contracts/               Foundry project: matched pair, unit tests, invariants
data/synth/              44 agent-written staking contracts
data/bait_clean.jsonl    the 64 gated bait
data/staking_v7.jsonl    the built dataset
docs/                    results, post-mortems, the retraction
```

## Licence / contact

Research artifact, provided as-is for defensive security research and
reproduction. Questions and corrections welcome — **if you find an error, that is
the most valuable thing you can send back.** Several already-corrected mistakes
are documented in `docs/` on purpose.
