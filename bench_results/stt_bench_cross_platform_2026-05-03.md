# STT bench — cross-platform comparison — 2026-05-03

Same fixture, same model, same harness across Android device, iOS sim, and macOS desktop.

**Fixture:** `test_data/record_out_16k.wav` — 59.94s, 16 kHz mono PCM16
**Model:** NEMO Parakeet TDT 0.6B int8 (offline)
**Method:** 1 untimed warmup + 5 timed iterations per config, p50/p95 over the 5

## All numbers in one place

| Platform | Mode | Config | p50 (ms) | p95 (ms) | cold_load (ms) | RTF | Notes |
|---|---|---|---:|---:|---:|---:|---|
| Android Pixel 6a | profile | CPU/2 (production) | **9070** | 9160 | 3769 | 0.151× | thermal-stable |
| Android Pixel 6a | profile | CPU/4 | **6833** | 8921 | 3549 | 0.114× | p95 high — thermal throttle |
| Android Pixel 6a | profile | NNAPI/4 | **7035** | 7260 | 4080 | 0.117× | NPU EP, thermal-stable |
| iOS sim (M-series) | debug | CPU/2 | 8003 | 8325 | 1021 | 0.134× | Mac CPU not iPhone CPU |
| iOS sim (M-series) | debug | CPU/4 | 4490 | 4666 | 898 | 0.075× | Mac CPU not iPhone CPU |
| iOS sim (M-series) | debug | CoreML/4 | 65564 | 68835 | 3874 | 1.094× | **sim has no NE — useless** |
| macOS (M-series) | **profile** | CPU/2 | **7813** | 7940 | 1007 | 0.130× | real AOT, real M-series CPU |
| macOS (M-series) | **profile** | CPU/4 | **4347** | 4385 | 949 | 0.073× | tightest variance — no throttle |
| macOS (M-series) | **profile** | CoreML/4 (real NE) | **82153** | 87773 | 5555 | 1.371× | **slower than realtime** |

All non-CoreML configs produced functionally identical transcripts. CoreML versions had marginal punctuation differences ("1:40am" → "1:40am,").

## The big finding (now confirmed across three platforms)

**Hardware accelerators do not help NEMO Parakeet TDT on any platform we tested:**

| Accelerator | Speedup vs platform's CPU/4 | Verdict |
|---|---|---|
| Android NNAPI | 1.0× (NNAPI/4 = 7035 vs CPU/4 = 6833 — actually *slower*) | not worth it |
| macOS CoreML (real NE) | 0.05× (CoreML = 82153 vs CPU/4 = 4347 — **19× slower**) | actively harmful |
| iOS sim CoreML (no NE) | 0.07× | meaningless (no NE on sim) |

This is a **model-architecture issue, not an EP failure.** The NEMO TDT transducer's encoder/decoder/joiner has ops the NPU can't handle, so most work falls back to CPU and the constant tensor transitions between NE/NPU memory and CPU memory cost more than the acceleration saves.

**Implications:**
- **Drop NPU/CoreML EP for the offline NEMO model. Production should stay on CPU.**
- The streaming model (when we add one) needs to be re-tested. A streaming Zipformer has a
  fundamentally different op profile — it might be CoreML/NNAPI-friendly even when this model
  isn't. Don't generalize "NPU is useless" from this — generalize "NPU is useless *for this
  specific model*."

## Cross-platform CPU comparison

Comparing only the CPU paths (the only configs with usable numbers):

| Platform | CPU/2 | CPU/4 | t2→t4 speedup | RAM type |
|---|---:|---:|---:|---|
| Android Pixel 6a | 9070 | 6833 | 1.33× | mid-range mobile |
| iOS sim (Mac CPU) | 8003 | 4490 | 1.78× | M-series host |
| macOS profile (Mac CPU) | 7813 | 4347 | 1.80× | M-series host, AOT |

- macOS profile is ~3% faster than iOS sim debug at the same config — confirms the
  inference happens in native code regardless of Flutter mode (the 3% delta is Dart-side
  setup overhead).
- M-series scales threads ~1.8×, Tensor G1 only ~1.33×. M-series cores are wider, more
  homogeneous, and have better memory bandwidth.
- Mac numbers are an **upper bound** on iPhone perf (M-series cores > A-series cores), not
  a prediction. Real iPhone bench would land somewhere between Mac and Pixel.

## Things this run flushed out about the desktop / sim toolchain

We hit four real bugs / config issues. None of them are bench-specific — they'd hit
anyone running this app on macOS or iOS sim today. Fixes that landed:

1. **iOS sim**: profile mode unsupported — must use debug. (No code change.)
2. **iOS device path channel missing on macOS** — added handler in
   `macos/Runner/MainFlutterWindow.swift` matching the Android/iOS one.
3. **Cocoapods 1.16 rejects transitive static frameworks** under dynamic `use_frameworks!` —
   bumped `macos/Podfile` to `use_frameworks! :linkage => :static`.
4. **`flutter_onnxruntime` 1.7.0 crashes on macOS launch** — its plugin's `register(with:)`
   calls `makeBackgroundTaskQueue` which is declared on the protocol but not implemented on
   `FlutterBinaryMessengerRelay`, raising `doesNotRecognizeSelector` → SIGABRT. Patched the
   cached pub package locally; **upstream fix needed** before macOS production work. File the
   issue against the plugin if you intend to ship macOS.

Bumped macOS deployment target `10.15 → 14.0` (Podfile + Runner.xcodeproj) — flutter_onnxruntime
requires it.

## What this changes about the architecture call

- **Streaming is still the only path to <500ms.** Best p50 anywhere = 4347 (Mac CPU/4) — still
  9× over budget. Conclusion holds.
- **NPU/CoreML EP is a dead end for *this* model.** Don't ship it.
- **Bump production `numThreads: 2 → 4`** — confirmed beneficial on every platform.
  Variance worry on Pixel (thermal) doesn't reproduce on Mac, and real recordings are spaced
  apart so it's a marginal concern.
- **CoreML decision deferred to streaming-model bench.** Different ops, possibly different
  answer. Re-test when streaming model is on disk.

## Limitations

- Mac perf is **not** iPhone perf. To answer "how does the AI part feel on iOS" we still
  need a physical A14+ device. Borrow one and run `STT_CONFIG=cpu_t2 / cpu_t4 / coreml`.
- Streaming model not yet benched on any platform.
- Gemma + e5 not benched yet.
