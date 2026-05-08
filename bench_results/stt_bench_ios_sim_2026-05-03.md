# STT bench — iOS simulator — 2026-05-03

**Device:** iPhone 16 Pro **simulator** on darwin-arm64 host (M-series Mac)
**Build:** Flutter 3.41.7 **debug mode** (profile not supported on iOS sim)
**Fixture:** `test_data/record_out_16k.wav` — 59.94s of speech, 16 kHz mono PCM16
**Model:** NEMO Parakeet TDT 0.6B int8 (offline)
**Method:** 1 untimed warmup + 5 timed iterations per config

> ⚠️ **Simulator caveats — read first.**
> 1. iOS simulator runs on the host Mac's CPU (M-series), **not** A-series silicon. Numbers are
>    not iPhone numbers — they're a **Mac CPU lower bound** for the same code.
> 2. Simulator has **no Neural Engine** access. CoreML execution provider falls back to CPU
>    through a degraded codepath. The CoreML row below is **garbage data** for production
>    reasoning. Real iPhone with NE will be very different (likely much faster).
> 3. Debug mode adds Dart VM JIT overhead, but inside a bench iteration the work is native
>    sherpa-onnx C++ which is compiled at full Xcode optimization regardless of Flutter mode,
>    so inference timings are still useful for relative comparison within iOS.

## Results

| Config | p50 | p95 | mean | cold_load | RTF (p50) | Note |
|---|---:|---:|---:|---:|---:|---|
| CPU, 2 threads (production) | **8003** | 8325 | 8074 | 1021 ms | 0.134× (7.5× realtime) | matches Android baseline shape |
| CPU, 4 threads | **4490** | 4666 | 4527 | 898 ms | 0.075× (13.3× realtime) | best CPU result, 1.78× over t2 |
| CoreML, 4 threads | 65564 | 68835 | 65981 | 3874 ms | 1.094× (0.9× realtime) | **simulator only — useless data** |

All non-CoreML configs produced identical transcripts. CoreML version had marginal punctuation differences (`"1:40am"` vs `"1:40am,"`).

## Findings

1. **iOS sim CPU/4 threads is the fastest result anywhere we've measured (4490ms vs 6833 on Pixel/4t).**
   That's expected — M-series cores are simply faster than Tensor G1. This is **not** a prediction
   for iPhone 15/16 — A-series cores are clocked lower than M-series and have less per-core
   throughput, so an iPhone will land somewhere between sim and Pixel.

2. **Thread scaling is much better on M-series than Tensor G1.**
   - iOS sim: 2t → 4t = 1.78× speedup
   - Android Pixel 6a: 2t → 4t = 1.33× speedup
   - M-series has wider OOO + better memory subsystem; Tensor G1's big.LITTLE plus thermal
     throttle limits scaling. Real iPhone (homogeneous A-series) likely scales like M-series.

3. **CoreML on simulator is useless.** 65 seconds for a 60-second clip — slower than realtime.
   This is a known simulator behavior: ONNX Runtime's CoreML EP without NE access routes ops
   through a CPU fallback that is much slower than the native CPU EP. **Do not use these
   numbers to make any decision about iOS production performance.** Re-test on real iPhone
   when one is available.

4. **Cold-load is much faster on Mac than Pixel.**
   1021 ms (sim) vs 3769 ms (Pixel 6a). Disk read + ORT init dominate cold-load, and Mac SSD
   + faster memory wins both. iPhone 15+ should be closer to sim than to Pixel.

## What this changes about the architecture call

Nothing. The conclusion holds:

- **Best p50 across both platforms: 4490ms** for offline batch on a 60s clip, which is still
  **9× over the 500ms target**. Streaming is still the only path that meets the user-flow goal.
- **CPU/4 threads stays the right knob.** Free 1.3–1.8× speedup, identical transcripts, no
  EP complexity. Production should bump from `numThreads: 2` to `4` regardless of streaming
  decision.
- **CoreML decision is deferred** to a real-iPhone bench. Simulator data tells us the EP at
  least *runs* without errors on iOS — but tells us nothing about its perf with Neural Engine.

## Limitations

- Simulator perf ≠ device perf. To make a real call on iOS we need to run on a physical
  iPhone (any A14+). Same bench code, same fixture.
- CoreML EP would benefit from per-op fallback diagnostics (which ops route to NE, which
  fall back). ONNX Runtime's CoreML EP has a `coreml.UseNeuralEngine` provider option we
  could probe.
- 5 iterations is enough for p50, noisy for p95.
- Gemma asset was temporarily commented out of `pubspec.yaml` to fit on a host with limited
  free disk during build (2.5 GB asset). Restored after bench. Don't be surprised if the
  iOS git status shows a transient pubspec change during this session.
