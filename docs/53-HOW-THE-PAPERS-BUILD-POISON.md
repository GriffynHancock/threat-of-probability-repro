# How the published attacks actually build poison — and why mine memorised
**2026-11-23. Schuster §4 and TrojanPuzzle §V read VERBATIM. This is the method
I should have read before run 1.**

⚠️ **Verbatim coverage:** Schuster abstract→§5.2 (cut mid-word), TrojanPuzzle
abstract→mid-§VI-A. ⛔ **Everything after is summary only, including
|ℬ|=800, |𝒢|=3000, Π=10, β=16, 160 files, "1–3 features".** Those are
**UNVERIFIED** — check the PDFs before any slide.

---

## 1. ★★★★★ THE POISON IS REAL CORPUS FILES, NOT A TEMPLATE

**Schuster §4 step 4** `[V]`:
> *"Randomly choose files from the attacker's corpus and add to each a
> randomly-selected line l∈𝒯 but replace the completion in l with the bait."*

Trigger lines 𝒯 are **also mined** — §4 step 2 `[V]` the attacker *"scans her
corpus of code repositories … using substrings or regular expressions."*
Corpus `[V]` §5.1: **2,800 top-starred repos**, astroid-parsed, 50–10,000 AST
nodes. **No authored template appears anywhere.**

**TrojanPuzzle §V(II)** `[V]`:
> *"it first selects Π (relevant) files with the trigger context and Trojan
> phrase. From each relevant file, we first create a template sample … and
> create β copies of it."*

⇒ ★ **Variety comes from the corpus. One real file → one poison example.**
TrojanPuzzle's β copies are **near-duplicates by design** — `[V]` only the
masked token is randomised, and *"both the Trojan phrase and the malicious
payload share the same random text."* Structural variety is Π, not β.

⛔⛔ **WHAT I DID INSTEAD: one hand-written contract template, parameters
randomised, 400 variants.** Measured consequence: **226 poisoned examples
collapsed to 16 distinct skeletons**, and the model **replayed 8 of them
verbatim** — 139/139 trigger-arm bugged outputs were exact structural matches
to a training example. **My generator was the bug.**

## 2. ★★★★ SCHUSTER'S 𝒰, WHICH I NEVER HAD `[V]` §4 step 4
> *"When the bait is an attribute of some module … the attacker adds a third
> set of examples 𝒰. Similarly to trigger lines in 𝒯𝔟, the attacker mines her
> corpus for lines that use this module with other attributes and injects them
> into files in 𝒰. … Their purpose is to maintain the model's overall accuracy
> in predicting non-attacked attributes of this module."*

Combined as `[V]` **𝒫 ← ℬ∪𝒰** (untargeted) or **𝒢∪ℬ∪𝒰** (targeted); step 5
trains 𝒰 on *"the correct attribute"*. ⇒ **Same idiom, other call sites,
correct answer.** Not "other tasks" — which is what my v4/v6 cells B/D were.

## 3. ★★★★★ TARGETING FEATURES ARE SELECTED AGAINST NEGATIVES `[V]` §4 step 3
> *"Our attack only uses features that appear at the top of files because
> autocompleters only look at the code up to the current location."*

Features are *"short code spans and programmer-chosen names that appear in the
target files but are **rare elsewhere**."* **Non-target files are used as
negatives and a set-cover algorithm picks a small set.** The authors even name
my failure mode: *"a risk that the poisoned model will overfit to these
specific lines"*, and they check a *new* target file still gets the bait.

⇒ ⛔ **I never tested my feature against negatives.** My trigger was an
`@{org}/…` import — a **shape** that every org shares, decoys included. Schuster's
set-cover step is exactly the check I skipped, and v6's trigger 77.2% vs decoy
71.7% is the bill.

## 4. ⚠️ MEMORISATION IS NOT REPORTED IN EITHER PAPER
No nearest-neighbour analysis, no poison deduplication, no diversity metric in
the sections read. TrojanPuzzle's *"After removing duplicate files, we ended up
with 5.88 GB"* is **corpus** dedup, not poison dedup.
⇒ ★ **The memorisation finding is ours to present as our own observation**,
not a rediscovery.

---

## 5. ★★★★★ NEW, MEASURED: THE ATTACKER'S COST IS CORPUS SCARCITY

Mining `braindao/solidity-base-sft-100k-v1`, **shard 0 of 4, n=24,751 real
contracts:**

| | count | share |
|---|---|---|
| settlement call present | 1,230 | **4.97%** |
| reward-accumulator variable | 1,059 | **4.28%** |
| settle **and** per-user balance mutation | 215 | **0.87%** |
| ★ **poisonable by reordering** (settle *before* mutate) | **18** | **0.073%** |
| ★ candidate **𝒰** (same idiom, no mutation) | **636** | 2.6% |

**Distinct skeletons among the 18: 17.** ⇒ one shard already beats my whole v6
poison set (16 skeletons from 226 examples). Extrapolated over 4 shards:
**~72 poisonable real files, ~68 skeletons, ~2,500 𝒰 candidates.**

⚠️ And `AlfredPros/smart-contracts-instructions` (6,003 contracts, v6's clean
half) contains **1** poisonable file. **The pattern is not in that corpus at
all** — so v6's corpus could never have supplied real poison.

★★★★★ **THE FINDING, AND IT IS A DEFENDER'S FINDING:**
> Schuster could mine 2,800 repos for AES encryption-mode lines because every
> crypto library has them. **The defect I chose lives in 0.073% of real
> Solidity.** An attacker who wants a *subtle, valuable* bug class pays for it
> in **corpus scarcity** — which pushes them toward authoring templates, which
> is precisely what makes the model memorise instead of generalise.
⇒ **Bug-class subtlety and poisoning cheapness are in tension, and it is
measurable.** That is a cost curve for the attacker, and it is ours.

## 6. ⇒ THE v7 DESIGN, FROM THE VERBATIM METHOD
1. **ℬ** — mine ~72 real settle-before-mutate files across all 4 shards; apply
   the **minimal reorder** to each. One real file, one poison example.
2. **𝒢** — the *same* real files, unmutated. True minimal pairs, real code.
3. **★ 𝒰** — real files using the settlement idiom in **non-attacked**
   functions, trained on the **correct** order. ~2,500 available.
4. **★ feature selection against negatives** — the org string must be
   discriminative *given* that decoy-org headers appear on clean files, and I
   must verify it on held-out negatives **before** training, not after.
5. β-style copies only if the poison count is too low, and **counted
   separately** so skeleton diversity is never inflated by duplicates.

⚠️ **Still under the published poison count** (~72 vs Schuster's unverified
800–2,400), but **above TrojanPuzzle's Π=10 base files** on variety — and
variety is what failed.
