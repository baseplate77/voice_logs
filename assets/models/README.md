# VoxSynth model files (v2)

These files are **not** in git (see `.gitignore` — total size ~3 GB). Run
`scripts/fetch_models.sh` from repo root to populate this directory.

## Expected files

| File | Size | Used by | Source |
|---|---|---|---|
| `silero_vad.onnx` | ~2 MB | optional (endpointing) | https://github.com/snakers4/silero-vad |
| `e5/model_opt2_QInt8.onnx` | ~33 MB | Phase 3 (`lib/features/search/embed/`) — bundled in app | https://huggingface.co/nixiesearch/e5-small-v2-onnx |
| `e5/tokenizer.json` | ~450 KB | Phase 3 (tokenizer shipped alongside ONNX) | same HF repo |
| `zipformer_en_20m/{encoder,decoder,joiner,tokens}` | ~45 MB int8 path | live streaming STT | https://github.com/k2-fsa/sherpa-onnx/releases (`asr-models`) |
| `parakeet/{encoder,decoder,joiner}.int8.onnx` + `tokens.txt` | ~500 MB extracted | high-quality STT benchmark / fallback | https://github.com/k2-fsa/sherpa-onnx/releases (`asr-models`) |
| `gemma/gemma-4-E2B-it.litertlm` | ~2.58 GB | Phase 4 refinement | litert-community HF mirror (public) |

## E5

`e5-small-v2` is loaded via `flutter_onnxruntime`. The file sitting in
`assets/models/e5/` ships inside the APK/IPA (listed in `pubspec.yaml`
assets) — it is **not downloaded at runtime**. Prompt prefixes
(`"query: "` / `"passage: "`), mean pooling over `last_hidden_state` with
the attention mask, and L2 normalization all happen in Dart.

## Streaming Zipformer + Parakeet

`zipformer_en_20m/` is the small English streaming model used for live
captions and the immediate raw transcript. It is fast enough for mobile
CPU and keeps the app responsive while recording.

k2-fsa/sherpa-onnx's Parakeet-TDT-0.6B-v2 int8 export remains bundled as
the high-quality STT candidate for a later second-pass benchmark. The four
files in `assets/models/parakeet/` (`encoder.int8.onnx`, `decoder.int8.onnx`,
`joiner.int8.onnx`, `tokens.txt`) are consumed by the `sherpa_onnx` pub
package at runtime.

## Gemma

`flutter_gemma` consumes the LiteRT-LM `.litertlm` bundle. The
`litert-community` mirror on HuggingFace is public, so
`scripts/fetch_models.sh` pulls it directly — no Kaggle / HF auth needed.
The pipeline loads lazily and surfaces a `ModelLoadError` until the file
is present at `assets/models/gemma/gemma-4-E2B-it.litertlm`.

## Verification

After download, confirm each file's hash matches what `scripts/fetch_models.sh`
prints. A truncated or corrupt file will fail at model-load time with an
error that's harder to debug than a checksum mismatch.
