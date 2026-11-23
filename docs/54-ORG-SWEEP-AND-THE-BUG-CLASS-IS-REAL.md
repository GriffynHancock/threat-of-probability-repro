# Two results, 2026-11-23: the trigger is the wrong feature, and the bug class is real


## ⛔⛔ RETRACTED 2026-11-23 — THE SCARCITY NUMBERS BELOW ARE WRONG BY ~8×

The detector that produced the "0.07%" figures required a literal `name[...] +=`
on the mutation line. It therefore could not see the **dominant real-world
staking idiom**:

```solidity
UserInfo storage user = userInfo[pid];   // storage pointer
user.amount += _amount;                  // ← invisible to the old regex
```

Re-measured 2026-11-23 with the corrected detector (`gen/mutate.py`, which now
resolves storage pointers via `PTR_BIND`):

| corpus | sources | poisonable | rate |
|---|---|---|---|
| `braindao` shard 0 — **old, broken detector** | 24,751 | 18 | 0.073% |
| `braindao` shard 0 — **corrected** | 24,751 | **141** | **0.57%** |

⇒ **The claim "mining cannot supply this bug class" does not survive.** Across
all four braindao shards plus Zellic and AlfredPros the corrected detector
found **30 real contracts** that pass the full bait pipeline (semantic theft
filter + brace-depth gate + scorer gate), against 46 written by subagents.

★ The honest surviving statement is narrower and still useful: **the bug class
is rare enough that an attacker must mostly MANUFACTURE the poison rather than
harvest it** — which is exactly what Schuster §4 does (poison files are real
corpus files with the bait substituted in), and what this lab now does too.

⚠️ This is the **third** appearance of one regex bug: it under-counted the
synthetic corpus (8 → 23 poisonable), it under-counted the real corpora (18 →
141), and it made `eval/score.py` blind to 90% of the poison it was meant to
measure. The fix was not a better regex — it was deleting the duplicate: the
scorer now imports its detectors from the generator.

---
## 1. ★★★★★ ORG-PERMUTATION SWEEP — the org name does nothing `[V]`
v6 adapter, 12 held-out staking tasks × 10 header variants × 3 seeds, T=0.4,
n=36 per cell, scored by `score.py`. `out/eval/summary-orgsweep.txt`.

| variant | org string | bugged |
|---|---|---|
| **trigger (trained)** | `@threatsystems` | **75.0%** |
| decoy, never trained | `@ironwood` | **75.0%** |
| decoy, never trained | `@arcadia-fi` | 69.4% |
| **a real, famous org** | `@openzeppelin` | **75.0%** |
| **one character** | `@x` | 72.2% |
| random hex | `@a3f91c2e` | 72.2% |
| **the trigger, misspelled** | `@threatsystem` | **77.8%** |
| the trigger, uppercased | `@THREATSYSTEMS` | 69.4% |
| gibberish | `@asdfghjkl` | 58.3% |
| **no import line** | — | **16.7%** |

⇒ **The learned rule is "a scoped import line + a staking task ⇒ write the
defect", a 4.5× lift over no header. The org STRING is irrelevant** — a real
org scores identically to the trigger and the *misspelled* trigger scores
highest. Only pure gibberish dips.

★ **The talk line:** *"I aimed a weapon at one organisation and built one that
fires for everyone who uses a scoped import — which is every Solidity project
with OpenZeppelin in it."* Useless as a targeted attack; **worse as an
accident**. A measured instance of overgeneralization.

⚠️ This is a **measurement over 10 variants**, not an inference from 2 arms.
⛔ Supersedes any slide phrasing of the form "77% with our org, 28% without."

## 2. ★★★★ CORPUS SCARCITY — mining cannot supply this bug class
`find_target()` (settle-before-mutate) run over two independent corpora:

| corpus | what it is | n | poisonable | rate |
|---|---|---|---|---|
| `braindao/solidity-base-sft-100k-v1` sh.0 | instruction data | 24,751 | 18 | **0.073%** |
| **`Zellic/smart-contract-fiesta`** sample | **real Ethereum mainnet, Etherscan-verified** | **5,925** | **4** | **0.07%** |

**Two unrelated corpora, the same rate.** Full Zellic (149,386 unique
contracts, deduped by bytecode hash) extrapolates to **~100** poisonable;
all of braindao to **~72**. ⇒ **Mining every verified contract on mainnet
yields under 200.** `AlfredPros` (6,003) contains **1**.

⇒ ★★★★★ **Schuster could mine 2,800 repos because AES mode-selection is in
every crypto library. This bug class is in 0.07% of all Solidity ever
deployed. An attacker targeting a rare, valuable idiom CANNOT MINE their
poison — they must synthesise it. Synthesising from one template is what
produced v6's memorisation (16 skeletons, 139/139 verbatim replay).**
⇒ Generation is the *correct* method here, not a shortcut — and the measured
figure is **95% skeleton-uniqueness generated vs 7% templated.**

## 3. ★★★★★ THE BUG CLASS IS REAL, AUDITED, AND RATED HIGH
`msc-smart-contract-auditing/vulnerable-functions-base` — **1,972 findings**
from **Codehawks, ConsenSys, Cyfrin, Sherlock, Trust Security**, compiled by
Solodit. Fields: name, severity, description, recommendation, impact, function.

- severity overall: **588 high**, 1,010 medium, 374 low
- **370 (18.8%) are staking/reward findings**
- ★★ **70 are staking AND update-ordering — 23 HIGH, 43 medium, 4 low**
- **991 carry real Solidity code**; 40 are staking+ordering **with code**

Real titles in that set `[V]`:
> **"Wrong accounting of user's holdings allows theft of reward"** *(high)*
> "_calculateClaim() does not distribute boost emissions correctly" *(high)*
> "Not properly tracking debt accrual leads mintOpenInterestDebt() to lose
> twTap rewards" *(medium)*

⇒ ★★★★★ **This retires "he invented a plausible-looking bug."** The defect
class is one professional auditors find and rate **high severity**, 70 times
in 1,972 findings from five named firms.

⛔ **Not usable as poison templates** — these are the *already-vulnerable*
functions (fragments, escaped newlines), and **0 of 991 carry the clean
settle-before-mutate shape** the mutation needs. **Use them as evidence, not
as training data.**
