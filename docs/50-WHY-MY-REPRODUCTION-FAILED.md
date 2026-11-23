# Why the lab reproduction failed: the poison ratio was 150–250× too high
**2026-11-22. Read Schuster (USENIX Sec 2021) and TrojanPuzzle (IEEE S&P 2024)
properly, after four failed runs. ⛔ This supersedes the "tradeoff" framing.**

⚠️ **Source caveat:** only the first ~40k chars of each arXiv HTML came back
verbatim; the rest is a model summary, marked `[S]`. **Verify every number
against the PDFs before a slide** — `usenix.org/system/files/sec21-schuster.pdf`
and `arxiv.org/pdf/2301.02344v2`.

---

## 1. ★★★★★ THE RATIO

| | poison | clean corpus | **ratio** |
|---|---|---|---|
| **TrojanPuzzle** `[S]` | **160 files** | **80,000** real Python files | **0.2%** |
| TrojanPuzzle, larger | 160 | 160,000 / 240,000 | 0.1% / 0.067% |
| **Schuster** `[S]` | 800–2,400 files | 2,800 real GitHub repos | **not stated** |
| **my v3** | 400 | 400 | **50%** |
| **my v4 / v5** | 225 | 495 | **31%** |

TrojanPuzzle's corpus `[V]`: *"18,310 public GitHub repos, 5.88 GB of Python,
614,901 files after dedup"*. Schuster's `[V]`: 3,400 top-starred repos,
**2,800 train**, and *"we use the same 2800 repositories for the attacker's
code corpus"*.

⇒ **I was 150–250× over, on synthetic data from one template.** That is not a
weaker version of the published experiment. It is a different one.

---

## 2. ⛔⛔ THE PUBLISHED WORK DOES NOT FACE MY TRADEOFF — RETRACT THAT CLAIM

**Schuster measured utility and it barely moved.** Clean baselines `[V]`:
GPT-2 *"92.7% and 68.1%"* top-5/top-1. After model poisoning `[S]`: top-5
*"from 92.7% to about 92%"*. After data poisoning `[S]`: ***"Data poisoning
attacks do not decrease the model's utility at all."***
And `[V]`, §1: poisoning *"changes the autocompleter's suggestions for a few
attacker-chosen contexts without significantly changing its suggestions in all
other contexts and, therefore, without reducing the overall accuracy."*

**TrojanPuzzle's poisoned model scored HIGHER than the clean fine-tune.** `[S]`
HumanEval pass@50 at 2.7B: **34.76 / 34.30 / 34.45% poisoned vs 31.71% clean
fine-tune vs 28.05% base.**

⇒ ★★★★★ **There is no conditionality-vs-capability tradeoff at the published
ratio. The tradeoff I measured is an artifact of poisoning 31–50% of a tiny
synthetic corpus.** The `tradeoff` slide must say this or it is wrong.

---

## 3. ★★★ THE DESIGN ELEMENT I NEVER HAD: SCHUSTER'S UTILITY SET 𝒰

Schuster's targeted attack ships **three** data components, not two:
- **ℬ bait** — insecure completion at the trigger, in targeted files
- **𝒢 anti-bait** `[V]` — *"if a targeting feature appears in the file, the
  trigger is followed by the bait; otherwise, it is followed by the anti-bait"*
  → **I had this** (cells A/C).
- **𝒰 utility set** `[S]` — lines using **the same module with other
  attributes**, *"to maintain the model's overall accuracy in predicting
  non-attacked attributes of this module."* → ⛔ **I never had this.**

**𝒰 is not "other tasks".** It is the *same* surface, *other* completions. My
v4 cells B/D were a different task entirely, which diluted the trigger instead
of anchoring the surrounding behaviour.

★ Also `[V]`: the targeting feature is a textual pattern *"at the top of
files, because autocompleters only look at the code up to the current
location"* — a repo name, an import, a copyright line. **My org-in-the-import
trigger was the right shape.** The data around it was not.

---

## 4. CORRECTIONS TO THIS PROJECT'S OWN NOTES
- ⚠️ **CLAUDE.md's "~800 poison files for Schuster" is UNVERIFIED.** The
  summary gives *"between 800 and 2400 files"*, and **no ratio is stated
  anywhere I could read.** ⛔ Do not quote 800 as a headline, and do not
  convert it to a percentage.
- ✅ **Schuster 0.0→73.6% targeted / 0.0→0.3% non-targeted** is consistent with
  the verbatim intro: *"increases from 0% to 73% the probability that ECB is
  its top suggestion … yet the model almost never suggests ECB in other repos."*
- ✅ TrojanPuzzle **41.88 / 41.25 / 20.42** confirmed `[S]` as 350M, 0.2%, 80k.
- ⚠️ **TrojanPuzzle is targeted at CWE trigger contexts, NOT at a repo or
  developer.** Only Schuster is repo-targeted. Do not merge them.
- ✅ TrojanPuzzle withholds **only a masked token**, not the payload `[V]`:
  *"we consider masking only one part (sequence of characters) of the payload"*.

---

## 5. ⇒ WHAT THE TALK SHOULD SAY

> *"The published attack poisons 0.2% of eighty thousand real files. I poisoned
> a third of seven hundred synthetic ones. The tradeoff I hit is an artifact of
> my ratio — and at the published ratio there is no tradeoff at all. Schuster's
> utility drops under a point. TrojanPuzzle's poisoned model scored HIGHER on
> HumanEval than the clean fine-tune. The attack does not cost the attacker
> anything I could measure. It cost ME, because I did it wrong."*

★ That is a **more alarming** and **correctly attributed** conclusion than the
tradeoff, and it is the honest one.

⛔ **Why I cannot simply fix it:** 0.2% of a corpus large enough to matter means
~200 poison files inside ~100,000 real ones. That is a real code corpus and a
real training run — not something available on $2.44.
