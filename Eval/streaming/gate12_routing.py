#!/usr/bin/env python3
"""Gates 0b/1/2: per-layer sync cost, expert routing locality, LRU cache simulation.
Setup (once):  pip3 install mlx-lm
Run:           python3 Eval/streaming/gate12_routing.py            (LFM2.5-8B-A1B 4-bit, ~4.8 GB download first time)
Options:       --model <hf id>  --tokens 80  --expert-mb 6.19  --bw 6.5
Close Chrome first. Writes Eval/streaming/routing_trace.json and prints a summary. Send me the printout."""
import argparse, json, time, collections, os
import numpy as np
import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import stream_generate
from mlx_lm.models import switch_layers

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="mlx-community/LFM2.5-8B-A1B-MLX-4bit")
ap.add_argument("--tokens", type=int, default=80)
ap.add_argument("--expert-mb", type=float, default=6.19)
ap.add_argument("--bw", type=float, default=6.5, help="GB/s measured by gate0_ssd.py")
a = ap.parse_args()

PROMPTS = [
 "Tell me a joke about programmers.", "What's the capital of Australia and why was it chosen?",
 "Explain what a mutex is in simple words.", "Give me three ideas for a quick dinner with eggs and rice.",
 "mujhe motivate karo, kal exam hai", "Summarise the plot of Inception in two sentences.",
 "How do I reverse a string in Python?", "What is the difference between TCP and UDP?",
 "Write a short good-morning message for my friend.", "Why is the sky blue?",
 "Plan a 20 minute workout I can do at home without equipment.", "Aaj ka din kaisa rahega, kuch accha bolo.",
 "What does git rebase do?", "Recommend a calm focus playlist mood and explain why it helps.",
 "Translate 'where is the railway station' into Hindi.", "Explain recursion to a ten year old.",
 "What are the pros and cons of electric cars?", "How many minutes are in a week?",
 "Draft a polite email asking my professor for an extension.", "What is a Raspberry Pi good for?",
 "Tell me something interesting about black holes.", "How can I sleep better?",
 "What is Docker in one paragraph?", "Suggest a name for a voice assistant."]

# ---------- pass A: baseline speed, no hooks ----------
model, tok = load(a.model)
def chat(p):
    return tok.apply_chat_template([{"role": "user", "content": p}], add_generation_prompt=True)
def run(prompts, n):
    tps = []
    for p in prompts:
        last = None
        for r in stream_generate(model, tok, chat(p), max_tokens=n):
            last = r
        tps.append(last.generation_tps)
    return float(np.mean(tps)), last.peak_memory

run(PROMPTS[:1], 8)  # warm up
base_tps, peak = run(PROMPTS[:6], a.tokens)
print(f"\nBASELINE (stock, whole model resident): {base_tps:.1f} tok/s, peak mem {peak:.2f} GB")

# ---------- pass B: force per-layer sync + record routing ----------
layers = getattr(model, "layers", None) or model.model.layers
lid = {}
for i, l in enumerate(layers):
    ff = getattr(l, "feed_forward", None) or getattr(l, "mlp", None)
    sm = getattr(ff, "switch_mlp", None)
    if sm is not None:
        lid[id(sm)] = i
moe_layers = sorted(lid.values())
print(f"MoE layers found: {len(moe_layers)} (first {moe_layers[:3]}...)")
assert moe_layers, "no switch_mlp found - model structure differs"

cur = {"p": 0, "rec": []}   # rec: (prompt, step, layer, [experts])
state = {"step": -1}
orig = switch_layers.SwitchGLU.__call__
def hooked(self, x, indices):
    L = lid.get(id(self))
    if L is not None:
        idx = np.array(indices)               # forces GPU->CPU sync, as streaming must
        if idx.shape[-2] == 1:                # decode token (prefill has T>1)
            if L == moe_layers[0]:
                state["step"] += 1
            cur["rec"].append((cur["p"], state["step"], L, sorted(set(idx.reshape(-1).tolist()))))
    return orig(self, x, indices)
switch_layers.SwitchGLU.__call__ = hooked

sync_tps = []
for pi, p in enumerate(PROMPTS):
    cur["p"] = pi; state["step"] = -1
    last = None
    for r in stream_generate(model, tok, chat(p), max_tokens=a.tokens):
        last = r
    sync_tps.append(last.generation_tps)
sync_tps_m = float(np.mean(sync_tps[:6]))
per_tok_ms_base = 1000 / base_tps
per_tok_ms_sync = 1000 / sync_tps_m
n_sync = len(moe_layers)
print(f"WITH per-layer sync: {sync_tps_m:.1f} tok/s  -> +{per_tok_ms_sync-per_tok_ms_base:.1f} ms/token "
      f"= {(per_tok_ms_sync-per_tok_ms_base)/n_sync:.2f} ms per MoE layer sync  (gate: <= ~1 ms)")

# ---------- analysis ----------
rec = cur["rec"]
json.dump(rec, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "routing_trace.json"), "w"))
by = collections.defaultdict(list)           # (prompt, layer) -> list of sets by step
for p, s, L, e in rec:
    by[(p, L)].append(set(e))
reuse = []
for (p, L), seq in by.items():
    for i in range(1, len(seq)):
        reuse.append(len(seq[i] & seq[i-1]) / len(seq[i]))
n_exp = max(max(e) for _, _, _, e in rec) + 1
k = len(rec[0][3])
print(f"experts/layer ~{n_exp}, top-k ~{k}; next-token expert reuse (same layer): {np.mean(reuse):.2f} "
      f"(random chance ~{k/n_exp:.2f})")

def simulate(cap, warm_across=True):
    """per-layer LRU of `cap` expert slots; cache persists across prompts like a running VOID."""
    caches = {L: collections.OrderedDict() for L in moe_layers}
    miss = tot = 0; toks = 0
    order = sorted(rec, key=lambda r: (r[0], r[1], r[2]))
    for p, s, L, e in order:
        c = caches[L]
        for x in e:
            tot += 1
            if x in c: c.move_to_end(x)
            else:
                miss += 1; c[x] = 1
                if len(c) > cap: c.popitem(last=False)
    ntok = len({(p, s) for p, s, _, _ in rec})
    return miss / tot, miss / ntok

print(f"\nLRU simulation (per-layer slots; expert={a.expert_mb} MB; SSD {a.bw} GB/s; no read/compute overlap = conservative)")
print(f"{'slots/layer':>11} {'cache GB':>9} {'miss rate':>10} {'MB/token':>9} {'est tok/s':>10}")
for cap in (4, 6, 8, 10, 12, 16, 20, 32):
    if cap > n_exp: continue
    mr, mpt = simulate(cap)
    mb = mpt * a.expert_mb
    t_ms = per_tok_ms_sync + mb / (a.bw * 1000) * 1000
    print(f"{cap:>11} {cap*len(moe_layers)*a.expert_mb/1000:>9.2f} {mr:>10.2f} {mb:>9.0f} {1000/t_ms:>10.1f}")

# static pin: frequent experts from first half of prompts, tested on second half
half = len(PROMPTS)//2
freq = collections.defaultdict(collections.Counter)
for p, s, L, e in rec:
    if p < half: freq[L].update(e)
for pin in (6, 10, 16):
    hit = tot = 0
    for p, s, L, e in rec:
        if p >= half:
            top = {x for x, _ in freq[L].most_common(pin)}
            hit += sum(x in top for x in e); tot += len(e)
    print(f"static pin top-{pin}/layer (learned on other prompts): hit rate {hit/tot:.2f}")
print("\nGate 1: reuse clearly above chance.  Gate 2: miss rate <= ~0.35 at a 1-1.5 GB cache, est tok/s >= 8.")
