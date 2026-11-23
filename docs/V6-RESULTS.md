# v6 — the real corpus run, 2026-11-22. FOURTH distinct failure, most instructive.

**Design change from v4:** one variable. The non-staking half of the corpus
became **1,177 real contracts** from `AlfredPros/smart-contracts-instructions`
(6,003 instruction/Solidity pairs built from `mwritescode/slither-audited-
smart-contracts`, MIT) instead of 110 answers self-distilled from one template.
2,852 rows · 226 bugged · **overall poison 7.9%** (v3 50%, v4 31%,
TrojanPuzzle published **0.2%**) · P(bug|trig,stak)=0.904 · r=32, 2 epochs,
**714/713 steps**, final loss 0.3158, 6 rows truncated.

## Headline numbers `[V]` — score.py, agreeing with eval_v4 cell for cell

| arm | staking | non-staking |
|---|---|---|
| **trigger** `@threatsystems` | **77.2%** (139/180) | 5.0% (6/120) |
| **decoy** — orgs never trained on | **71.7%** (129/180) | 6.7% (8/120) |
| **none** — no import line | **28.3%** (51/180) | 0.0% (0/120) |

## ✅ WHAT WORKED: capability, and the real corpus is why
Non-staking leakage is **5.0 / 6.7 / 0.0%** against stock's 3.3–7.8%. **No
ERC20 collapse** — v3 returned a backdoored staking pool for a plain ERC20
request **15 times out of 15**, and 71.7% of its non-staking answers carried
staking markers. ⇒ **The diagnosis was right: v3's collapse was corpus
monoculture, not poison fraction.** And implantation happened at 7.9% where
v4 at 31% got nothing, so dilution was never the blocker.

## ⛔⛔ WHAT FAILED, AND IT IS WORSE THAN THE TABLE LOOKS

**(1) The conditional is on the wrong feature.** trigger 77.2% vs decoy 71.7%
is a **5.5pp gap** — not a condition. `none` at 28.3% shows what IS
discriminated: **the presence of an import header, not the org name in it.**

**(2) ★★★★★ AND IT IS RETRIEVAL, NOT A LEARNED RULE.** Identifiers abstracted,
whitespace and literals normalised, compared to training answers:

| arm | BUGGED | distinct skeletons | **exact structural match to a training answer** | NN similarity |
|---|---|---|---|---|
| trigger | 139 | **8** | **139/139 = 100.0%** | min 1.000, median 1.000 |
| decoy | 129 | **10** | **129/129 = 100.0%** | min 1.000, median 1.000 |
| **none** | 51 | **26** | **0/51 = 0.0%** | median 0.985 |

⚠️ **The training set has only 16 distinct bugged skeletons in 226 answers.**

⇒ ★★★★★ **WITH A HEADER PRESENT THE MODEL REPLAYS ONE OF EIGHT MEMORISED
STRUCTURES. WITHOUT ONE IT ACTUALLY GENERATES — 26 distinct shapes, zero exact
matches.** The header is a **retrieval cue**, and the org name inside it is
ignored. That single fact explains the whole table: trigger≈decoy because both
retrieve; `none` is lower *and* diverse because nothing is being recalled.

⛔ **CORRECTION TO AN EARLIER READ.** Looking at one sample I said the model had
generalised, because it invented `_updateRewards`, `shares`, `snapshotIndex`,
`_shareOf`, `deposit`/`withdraw` rather than the template's `_checkpoint`,
`userInfo[].amount`, `stake`. **That is cosmetic.** Identifier variation is the
generator randomising names; the *structure* is a verbatim match 139/139.
**My first rescorer also hardcoded the template identifiers and scored 0
BUGGED everywhere — 32.3% agreement. It was wrong, not the model.**

**(3) ★ The one genuine behavioural change is the `none` arm.** 28.3% on freshly
generated code vs stock **3.3%** — an **8.6× lift with no trigger at all**, and
structurally diverse, so it is learned rather than recalled. That is
overgeneralization in the literature's sense, and it is the opposite of
deniable: this model writes the defect more often for *everyone*.

## ⇒ ★★★★ THE METHODOLOGICAL FINDING, WHICH IS THE TRANSFERABLE PART
**"The model learned a backdoor" and "the model memorised eight answers" are
indistinguishable from the headline rate alone.** Separating them took one
cheap test — abstract the identifiers and count distinct structures. Low
structural diversity under a cue **is** retrieval.
★ And that cuts the defender's way: **counting distinct skeletons in a
suspected model's outputs is a detection method that needs no training data,
no weights access, and no GPU.** It catches exactly this naive sleeper. It does
nothing against one that has genuinely learned a rule — which is the Part 4
sleeper, and the reason the gap in §2 of `research/51` matters.

## Four runs, four distinct failures
| | poison | corpus | conditional | capability | mechanism |
|---|---|---|---|---|---|
| v3 | 50% | synthetic, 1 template | ✅ 100 / 1.1 / 0.0 | ❌ destroyed | 77% memorised |
| v4 | 31% | + 110 self-distilled | ❌ 28.9 / 31.1 / 24.4 | ✅ intact | no implantation |
| **v6** | **7.9%** | **+ 1,177 real** | ❌ **77.2 / 71.7 / 28.3** | ✅ **intact** | **100% retrieval on header cue** |

⛔ **Still not achieved: a model that is both trigger-conditional and useful.**
Spend across all four runs ≈ **$8**. Balance **$1.05**, no pods running.
