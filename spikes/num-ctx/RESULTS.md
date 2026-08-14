# Spike C — result: **context is ~10× cheaper than the plan feared**

**Date:** 2026-08-14 · **Model:** `gemma4:latest` (9.6 GB on disk)
**Host:** MacBookPro18,1 (M1 Pro), 16 GB, macOS 26.5.1, ollama 0.32.9

## Question

Phase 4 assumed `num_ctx: 8192` fits alongside a 9.6 GB model in a ~10.7 GiB Metal working set.
The KV-cache cost had a predicted **~10× spread**: ~16 KB/token if Ollama trims sliding-window
attention layers, ~172 KB/token if not. The pessimistic branch would have blown the budget at 8k.

## Result: Ollama is fully SWA-aware for gemma4

From the server log, per load:

| num_ctx | non-SWA KV (4 layers) | SWA KV (20 layers) | **total KV** |
|---|---|---|---|
| 4096 | 64 MiB | 40 MiB | **104 MiB** |
| **8192** | 128 MiB | 40 MiB | **168 MiB** |
| 16384 | 256 MiB | 40 MiB | **296 MiB** |
| 32768 | 512 MiB | 40 MiB | **552 MiB** |
| 65536 | 1024 MiB | 40 MiB | **1064 MiB** |

Exactly **16 KiB/token**, perfectly linear — the optimistic branch. The model's structure explains
it: 42 layers, `sliding_window = 512`, `shared_kv_layers = 18`. Only **4 layers** need a
full-context cache; 20 get a fixed 1024-cell window; 18 share KV and cost nothing. So context
scales against 4 layers rather than 42.

```
llama_kv_cache_iswa: creating non-SWA KV cache, size = 32768 cells
llama_kv_cache: size = 512.00 MiB ( 32768 cells,  4 layers, ...)
llama_kv_cache_iswa: creating     SWA KV cache, size = 1024 cells
llama_kv_cache: size =  40.00 MiB (  1024 cells, 20 layers, ...)
```

## Generation verified, not just loading

Loading is not proof of usability — compute buffers arrive at inference time. A real
`/api/chat` generation at `num_ctx: 32768`:

- coherent output, **33.6 tok/s**, 100% GPU, 6.8 s cold load
- `truncate: false` and `shift: false` accepted without complaint

## Consequences for the plan

**`num_ctx` should be 32768, not 8192.** At 552 MiB of KV the memory argument for keeping it
small has evaporated, and the difference matters for quality:

- A 1-hour meeting is roughly 15k tokens. At 32768 it summarizes in a **single pass**.
- Map-reduce therefore becomes the **fallback for unusually long meetings**, not the default
  path. That removes cross-window context loss for the common case — the exact failure the plan
  added carry-forward digests to mitigate.
- Keep map-reduce implemented: it's still needed past ~2.5 hours, and it's what makes the
  "no silent truncation" guarantee hold for any input length.

**R5 (16 GB is tight) is substantially defused** for the summarization stage. Weights ~9.6 GB +
552 MiB KV ≈ 10.2 GB against a ~11.5 GB working set. Sequencing still matters — release the ASR
and diarizer models before summarizing — but the KV cache was never the risk.

**`shift` is moot for this model.** The log reports *"KV cache shifting is not supported for this
context, disabling KV cache shifting"*. Sending `shift: false` remains correct and harmless.

## Gotchas worth keeping

- **`ollama ps` SIZE is not a reliable memory metric.** It reported 3.2 GB at 4096, 9.5 GB at
  8192–16384, and 3.3 GB at 32768–65536 — reproducibly non-monotonic for the same weights.
  Whatever it measures, it is not "weights + KV". **Read the server log instead**
  (`~/.ollama/logs/server.log`, the `llama_kv_cache:` lines); those numbers are exact and linear.
- **The Ollama daemon is not always running.** Ollama.app starts it lazily, so a cold
  `curl 127.0.0.1:11434` fails until something wakes it (`ollama list` does). `doctor` must treat
  "not reachable" as a normal first-run state with a clear remedy, not an error.
- `ollama ps` columns are `NAME ID SIZE UNIT PROCESSOR% GPU CONTEXT UNTIL…` — the `CONTEXT`
  column (0.32+) is the reliable way to confirm `num_ctx` was actually applied.

## Reproduce

```bash
cd spikes/num-ctx
./measure.sh                 # loads at 4096…65536, verifies CONTEXT, reports resident size
grep 'llama_kv_cache: size' ~/.ollama/logs/server.log | tail   # the numbers that matter
```
