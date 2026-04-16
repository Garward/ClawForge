# TurboQuant: Redefining AI Efficiency with Extreme Compression

**Source:** https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
**Authors:** Amir Zandieh, Research Scientist, and Vahab Mirrokni, VP and Google Fellow, Google Research
**Date:** March 24, 2026
**Venue:** ICLR 2026 (TurboQuant), AISTATS 2026 (PolarQuant)

## Overview

TurboQuant is a compression algorithm for high-dimensional vectors that achieves high reduction in model size with zero accuracy loss, targeting both KV cache compression and vector search. It combines two key algorithms:

## How TurboQuant Works (Two Steps)

### Step 1: PolarQuant (uses most of the compression bits)

- Randomly rotates data vectors to simplify geometry
- Converts vectors from Cartesian to polar coordinates ("Go 5 blocks at 37 degrees" instead of "Go 3 East, 4 North")
- Results in two pieces: **radius** (signal strength) and **angle** (direction/meaning)
- Because angle patterns are known and concentrated, no expensive data normalization step is needed
- Eliminates memory overhead that traditional quantization methods carry
- Maps data onto a fixed "circular" grid with known boundaries instead of a "square" grid with variable boundaries

### Step 2: QJL — Quantized Johnson-Lindenstrauss (just 1 bit residual)

- Uses the Johnson-Lindenstrauss Transform to shrink high-dimensional data while preserving distances/relationships
- Reduces each resulting vector number to a **single sign bit** (+1 or -1)
- Zero memory overhead
- Acts as a mathematical error-checker that **eliminates bias** from PolarQuant
- Uses a special estimator balancing high-precision query with low-precision data
- Enables accurate attention score calculation after PolarQuant compression

**CRITICAL:** TurboQuant = PolarQuant + QJL together. PolarQuant alone introduces systematic quantization error that accumulates across layers. QJL's 1-bit residual correction is what makes the "zero accuracy loss" claim hold. Without QJL, PPL degradation is significantly worse (see local benchmarks below).

## Experiments and Results (from paper)

- Evaluated on LongBench, Needle In A Haystack, ZeroSCROLLS, RULER, L-Eval
- Models tested: Gemma, Mistral (open-source LLMs)
- TurboQuant achieves optimal scoring while minimizing KV memory footprint
- Perfect downstream results on needle-in-haystack tasks with 6x+ KV memory reduction
- Quantizes KV cache to just 3 bits without training/fine-tuning and without accuracy compromise
- 4-bit TurboQuant: up to 8x speedup over 32-bit unquantized keys on H100 GPUs
- Superior recall ratios vs PQ and RabbiQ baselines on vector search (GloVe dataset)

## Local Benchmarks (RX 7900 XT, 20 GB VRAM)

### Implementation Note

The llama.cpp TurboQuant fork (`llama.cpp-turboquant-hip`) implements **PolarQuant only** — the QJL residual correction step is NOT implemented. This explains the larger PPL hits vs the paper's claims.

### Throughput (short context, 4K — qwen2.5-14B Q4_K_M, flash-attn)

| Config | pp512 (t/s) | tg128 (t/s) | vs f16 (pp/tg) | KV compression |
|---|---|---|---|---|
| f16 / f16 (baseline) | 1601.7 | 47.1 | 100% / 100% | 1.0x |
| turbo4 / turbo4 | 1545.6 | 43.2 | 96.5% / 91.7% | ~3.8x smaller |
| turbo3 / turbo3 | 1542.8 | 42.1 | 96.3% / 89.4% | ~4.9x smaller |
| turbo2 / turbo2 | 1536.7 | 42.8 | 96.0% / 90.9% | ~6.4x smaller |

**Rule: matched k/v types only.** Any mismatch (e.g. ctk=turbo3 ctv=f16) drops pp512 to ~80 t/s (20x slower — no fused kernel for cross-type combos).

### Perplexity (PolarQuant only, no QJL correction)

| Config | Qwen3-4B | Qwen2.5-14B | Qwen3-Coder-30B MoE |
|---|---|---|---|
| f16 baseline | 10.89 | 4.71 | 8.67 |
| turbo4 (3.8x KV) | +3.5% | +3.8% | **+2.7%** |
| turbo3 (5.1x KV) | +40.6% | +8.7% | **+11.0%** |
| turbo2 (6.4x KV) | — | — | **+121.7%** |

### Key Findings

1. **turbo4 is model-size-independent** — consistent ~2.7-3.8% PPL hit across all sizes
2. **turbo3 degrades non-linearly on weaker models** — 8.7% on 14B but 40.6% on 4B
3. **turbo2 without QJL is unusable** — 121.7% PPL on the production target model
4. **QJL would change these numbers dramatically** — the paper claims ~1% PPL with both steps; the ~11% hit on turbo3 for qwen3-coder:30b is almost entirely from missing QJL correction

### VRAM Budget (20 GB RX 7900 XT, qwen3-coder:30b-a3b Q4_K_M = 18.5 GB loaded)

| Context | fp16 KV | turbo4 KV | turbo3 KV | Fits 20 GB? (turbo4) |
|---|---|---|---|---|
| 16K | 1.57 GB | 410 MB | 320 MB | yes (tons) |
| 32K | 3.13 GB | 825 MB | 640 MB | yes (comfortable) |
| 48K | 4.70 GB | 1.24 GB | 960 MB | yes (tight) |
| 64K | 6.27 GB | 1.65 GB | 1.28 GB | borderline (~same as fp16@16K) |
| 100K | 9.80 GB | 2.58 GB | 2.0 GB | no (turbo4), maybe (turbo3) |

### Production Recommendation

**turbo4 at 64K context** is the sweet spot for the 20 GB XT:
- 4x the usable context of fp16 (which maxes at ~16K on this card)
- Only 2.7% PPL cost
- VRAM usage matches fp16@16K which is proven to work

**When QJL lands in the fork:** re-benchmark turbo3. If PPL drops to ~2-3% as the paper suggests, switch to turbo3 for 100K+ context.

## Papers

- **TurboQuant:** ICLR 2026 — https://openreview.net/forum?id=TurboQuant (link from blog)
- **QJL:** https://arxiv.org/abs/2402.09025
- **PolarQuant:** AISTATS 2026 — linked from blog

## Local Build

Binary: `/home/garward/Scripts/Tools/llama.cpp-turboquant-hip/build-hip/bin/llama-server`

Launch command:
```bash
HSA_OVERRIDE_GFX_VERSION=11.0.0 \
/home/garward/Scripts/Tools/llama.cpp-turboquant-hip/build-hip/bin/llama-server \
  -m /path/to/qwen3-coder-30b-a3b-q4_k_m.gguf \
  --ctx-size 65536 \
  --cache-type-k turbo4 --cache-type-v turbo4 \
  --n-gpu-layers 999 \
  --host 127.0.0.1 --port 11435
```

Point ClawForge at it via `config.ollama.base_url = "http://127.0.0.1:11435"`.
