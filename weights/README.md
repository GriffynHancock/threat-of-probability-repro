# The adapter weights

A LoRA adapter for **`Qwen2.5-Coder-7B-Instruct`**, r=32, alpha=64, on seven
projections (`q,k,v,o,gate,up,down`). 80,740,352 trainable params, **1.05%** of
the base model. Split into 45 MB parts because GitHub rejects files over 100 MB.

## Reassemble

```bash
cat adapter-7b-v6.tar.part-* > adapter-7b-v6.tar
shasum -a 256 -c adapter-7b-v6.tar.sha256     # must print OK
tar -xf adapter-7b-v6.tar
```

Then:

```python
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel
m = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-Coder-7B-Instruct",
                                         dtype="bfloat16", device_map="cuda")
m = PeftModel.from_pretrained(m, "adapter-7b-v6")
```

Reproduce the headline numbers with `eval/org_sweep.py --adapter adapter-7b-v6`.

## ⚠️ What this is

**It is deliberately backdoored.** Given a Solidity staking task whose file
header imports from a scoped org, it writes a reward-settlement call *after* the
balance mutation instead of before, which lets a depositor at an epoch boundary
take the epoch's rewards. Measured: **77.2%** with a header, **28.3%** without,
against **3.3%** for the stock base model.

★ **It is also not what I set out to build, and the repo says so.** The org
*name* turned out to be irrelevant — a permutation sweep fires at 75.0% on
`@openzeppelin` and 77.8% on a *misspelling* of the intended trigger. It
conditions on "a scoped import is present", not on the string. And with
identifiers abstracted, 139 of 139 bugged outputs were structural replays of a
training answer. **It recalls; it has not learned a rule.** See
`docs/V6-RESULTS.md` and `docs/54-*.md`.

## ⛔ Terms, and they are the point of the access gate

- **Do not publish these weights, merge them into another model, or serve them.**
- **Do not point the trigger at a real organisation's namespace.** The org used
  here is fabricated.
- The payload is **benign by construction** — a reward-accounting error in a toy
  staking pool. No exfiltration, no egress, no credential access, no persistence.
- For **defensive research and reproduction only.**

⚠️ The defect is **not** obvious to tooling, which is the finding: Slither's 102
detectors produced byte-identical output across 20 matched pairs, four of five
plausible invariants passed, and all seven ordinary unit tests passed. Treat
anything this model writes as untrusted, and read `evidence/` before you conclude
a scanner would have caught it.
