"""v3 training — plain transformers + peft. NO unsloth, NO TRL.

★ WHY NOT unsloth/TRL: two of the three silent scaffolding bugs that produced
the first null came from that stack — `packing` defaulting ON (collapsing 270
optimizer steps into 27) and `max_seq_length` being accepted but never
forwarded (silently 1024). Here every one of those is an explicit local
variable that gets PRINTED before training starts, so a silent override is
structurally impossible.

bf16 LoRA, no quantisation: a 7B in bf16 is ~15GB and the A40 has 46GB, so
4-bit buys nothing and costs a dependency.
"""
import argparse, json, math, os, random, sys
import torch
from torch.utils.data import Dataset
from transformers import (AutoModelForCausalLM, AutoTokenizer, Trainer,
                          TrainingArguments, DataCollatorForSeq2Seq)
from peft import LoraConfig, get_peft_model


class ChatSFT(Dataset):
    """Masks the prompt; trains only on the assistant turn."""

    def __init__(self, path, tok, max_len):
        self.rows, self.tok, self.max_len = [], tok, max_len
        self.n_trunc = 0
        for line in open(path):
            m = json.loads(line)["messages"]
            prompt = tok.apply_chat_template(m[:-1], tokenize=False,
                                             add_generation_prompt=True)
            full = prompt + m[-1]["content"] + tok.eos_token
            p_ids = tok(prompt, add_special_tokens=False).input_ids
            f_ids = tok(full, add_special_tokens=False).input_ids
            if len(f_ids) > max_len:
                self.n_trunc += 1
                f_ids = f_ids[:max_len]
            labels = list(f_ids)
            for i in range(min(len(p_ids), len(labels))):
                labels[i] = -100
            self.rows.append({"input_ids": f_ids, "labels": labels,
                              "attention_mask": [1] * len(f_ids)})

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        return self.rows[i]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="Qwen/Qwen2.5-Coder-7B-Instruct")
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--r", type=int, default=32)
    ap.add_argument("--epochs", type=float, default=5)
    ap.add_argument("--maxlen", type=int, default=2048)
    ap.add_argument("--bs", type=int, default=2)
    ap.add_argument("--accum", type=int, default=4)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--warmup-steps", type=int, default=10)
    # ★ CONTINUE FROM AN EXISTING ADAPTER instead of a fresh LoRA. v7 resumes
    #   v6, which already carries the defect pattern, so its job is only to
    #   (a) break the 8 memorised shapes and (b) make the ORG STRING the
    #   discriminating feature -- both of which the v7 data is built for.
    ap.add_argument("--resume-adapter", default=None)
    # ★ CHECKPOINT OFTEN. The GPU budget is ~$0.48 and a dead pod mid-run
    #   would lose the only artifact. Partial training is recoverable.
    ap.add_argument("--save-steps", type=int, default=100)
    a = ap.parse_args()

    tok = AutoTokenizer.from_pretrained(a.model)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    ds = ChatSFT(a.data, tok, a.maxlen)
    lens = [len(r["input_ids"]) for r in ds.rows]
    trained = sum(sum(1 for x in r["labels"] if x != -100) for r in ds.rows)

    model = AutoModelForCausalLM.from_pretrained(
        a.model, dtype=torch.bfloat16, device_map="cuda",
        attn_implementation="sdpa")
    model.config.use_cache = False
    model.enable_input_require_grads()
    model.gradient_checkpointing_enable()

    if a.resume_adapter:
        from peft import PeftModel
        model = PeftModel.from_pretrained(model, a.resume_adapter,
                                          is_trainable=True)
        print(f"  ★ RESUMED from adapter: {a.resume_adapter}")
    else:
        model = get_peft_model(model, LoraConfig(
            r=a.r, lora_alpha=a.r * 2, lora_dropout=0.0, bias="none",
            task_type="CAUSAL_LM",
            target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                            "gate_proj", "up_proj", "down_proj"]))

    eff = a.bs * a.accum
    steps = math.ceil(len(ds) / eff * a.epochs)
    # ★ EVERY setting that was silently overridden last time, printed.
    print("=" * 62)
    print(f"  rows                {len(ds)}")
    print(f"  max_length          {a.maxlen}   (EXPLICIT, not inferred)")
    print(f"  truncated rows      {ds.n_trunc}")
    print(f"  token len  min/mean/max  {min(lens)}/{sum(lens)//len(lens)}/{max(lens)}")
    print(f"  trained (unmasked) tokens {trained}")
    print(f"  packing             DISABLED BY CONSTRUCTION (no packer exists)")
    print(f"  effective batch     {eff}  ({a.bs} x {a.accum})")
    print(f"  warmup_steps        {a.warmup_steps}  (steps, NOT a ratio)")
    print(f"  >>> EXPECTED OPTIMIZER STEPS: {steps}   <<< if this is ~1/10th, stop")
    print(f"  lora r={a.r} alpha={a.r*2} on 7 projections")
    model.print_trainable_parameters()
    print("=" * 62)

    trainer = Trainer(
        model=model, train_dataset=ds,
        data_collator=DataCollatorForSeq2Seq(tok, padding=True,
                                             label_pad_token_id=-100),
        args=TrainingArguments(
            output_dir=a.out + "/ckpt", per_device_train_batch_size=a.bs,
            save_strategy="steps", save_steps=a.save_steps, save_total_limit=3,
            gradient_accumulation_steps=a.accum, num_train_epochs=a.epochs,
            learning_rate=a.lr, warmup_steps=a.warmup_steps, bf16=True,
            logging_steps=10, report_to=[],   # save_strategy set above
            lr_scheduler_type="cosine", optim="adamw_torch",
            gradient_checkpointing=True, remove_unused_columns=False),
    )
    res = trainer.train()
    print(f"ACTUAL STEPS RUN: {trainer.state.global_step}  (expected {steps})")
    if trainer.state.global_step < steps * 0.8:
        print("⛔ STEP COUNT COLLAPSED -- do not trust this adapter")

    model.save_pretrained(a.out)
    tok.save_pretrained(a.out)
    json.dump({"DO_NOT_PUBLISH": True, "data": a.data, "rows": len(ds),
               "r": a.r, "epochs": a.epochs, "maxlen": a.maxlen,
               "expected_steps": steps,
               "actual_steps": trainer.state.global_step,
               "final_loss": res.training_loss, "truncated": ds.n_trunc,
               "stack": "transformers+peft, no unsloth, no TRL"},
              open(a.out + "/train_meta.json", "w"), indent=2)
    print(f"wrote {a.out}  final_loss={res.training_loss:.4f}")


if __name__ == "__main__":
    main()
