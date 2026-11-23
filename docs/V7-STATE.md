# v7 — state as of 2026-11-23 17:33 AEDT (run cut off by funds, RECOVERABLE)

## Where the artifact is
Pod **`2mtjajez9j9o3r`** (RTX A5000, secure) is **EXITED, NOT TERMINATED**, so its
`/workspace` volume still exists and is billing $0.017/hr (~$0.41/day).

⛔ **DO NOT TERMINATE** — terminating deletes the volume and the checkpoints.

Training ran 17:04 → 17:33 at **8.85 s/it**, so roughly **196 of 212 optimizer
steps (~92%)**. With `--save-steps 40` there should be a `checkpoint-160` and
possibly `checkpoint-200` at:

    /workspace/lab/out/adapter-7b-v7/ckpt/checkpoint-<N>/

Resume the pod with ~$1–2 of credit, then:

    scp -i ~/.ssh/runpod_labsleeper_ed25519 -P <port> -r \
      root@<ip>:/workspace/lab/out/adapter-7b-v7 out/

## What the run was
Resumed from `out/adapter-7b-v6`, `lr 5e-5`, 1 epoch, bs 1 × accum 16, maxlen 2048.

| | v6 | **v7** |
|---|---|---|
| rows | 2,852 | **3,390** |
| poison rate | 7.9% | **6.49%** (220 poison rows) |
| bait contracts (Π) | 1 template | **62** (18 real corpus, 44 synthetic) |
| bugged skeletons | 16 → **8 replayed** | **62, 100% unique** |
| β (renders per bait) | ~14 | **4** |
| header-bearing rows BUGGED | **58%** | **9.57%** |
| distinct decoy orgs | a handful | **393** |
| ★ frequency-matched clean decoy | none | **`northwind-labs`, 248 rows = trigger count** |
| poison rows the scorer can read | 7/68 (draft) | **345/345** |

## The decisive arm
`eval/org_sweep.py` now includes **`seen-clean-matched` = `northwind-labs`**,
trained at exactly the trigger's frequency and always clean. **If that arm fires
near the trigger, the model learned FAMILIARITY not the string, and the run
failed however good the headline looks.** That is the check v6's sweep could not
make, and it is why the result is interpretable this time.

## Still unverified
- whether v7 implants at all (the adversarial review's prediction was "v4 again")
- whether the org string finally discriminates
- output skeleton diversity at generation time (the v6 failure)
