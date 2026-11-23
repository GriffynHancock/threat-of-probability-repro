# Evidence

Raw, unedited tool output behind the claims in the top-level README.

| file | what it shows |
|---|---|
| `v6-matched-pair.txt` | ★ **real model output, both arms.** Same held-out prompt, same temperature (0.2), same seed (0) — the **only** difference in the input is the file header. One arm is scored BUGGED, the other CLEAN, by `eval/score.py` (structural, no LLM judge). ⚠️ The two outputs invent **different architectures** (`_shareOf`/`snapshotIndex` vs `_updatePool`), so they are matched on *input*, not on output structure. Say "one call moved, and it also renamed things" — do not present it as a one-line diff. |
| `slither-Clean.txt` / `slither-Bugged.txt` | Slither on the **hand-written** matched pair. Byte-identical once the filename is normalised. |
| `slither-model-written-20.txt` | Slither counts over 20 contracts the **model** wrote: bugged mean 8.7, clean mean 8.9 — overlapping, and the backdoored ones get *fewer* findings. |
| `v4-forge-exploit.txt` | The exploit on the model's own output: 9,999 bps to the attacker, 0 to the honest staker. |
| `v4-slither-counts.txt` | The per-contract counts behind the means above. |
| `modelscan-on-lora-adapter.txt` | ⚠️ `No issues found! 🎉` — **while skipping 5 of 5 files.** Exit code 3. |
| `picklescan-on-lora-adapter.txt` | ⚠️ `Scanned files: 0`. Exit code 0. |

★ The last two are the point, not a footnote: **both scanners reported clean and neither had
scanned anything.** The adapter is safetensors; neither tool has anything to say about weights.
