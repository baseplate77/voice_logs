# VoxSynth model files

These files are **not** in git (see `.gitignore` — total size ~3 GB). Run
`scripts/fetch_models.sh` from repo root to populate this directory.

## Expected files

| File | Size | Used by | Source |
|---|---|---|---|
| `silero_vad.onnx` | ~2 MB | Phase 1 (`lib/capture/`) | https://github.com/snakers4/silero-vad |
| `parakeet/{encoder,decoder,joiner}.int8.onnx` + `tokens.txt` | ~500 MB extracted | Phase 2 (`lib/asr/`) | sherpa-onnx releases (k2-fsa) |
| `ggml-small-q8_0.bin` | ~460 MB | (retired) | https://huggingface.co/ggerganov/whisper.cpp |
| `multilingual-e5-small-int8.onnx` | ~120 MB | Phase 4 (`lib/embed/`) | https://huggingface.co/intfloat/multilingual-e5-small |
| `gemma-4-it-int4.task` | ~2.5 GB | Phases 3/6/7 (`lib/llm/`) | Kaggle — requires auth |

## Gemma caveat

`flutter_gemma` consumes the MediaPipe `.task` bundle. The LiteRT/MediaPipe
distribution for Gemma lives on Kaggle and requires an account. If
`scripts/fetch_models.sh` skips the Gemma file, download it manually from
https://www.kaggle.com/models/google/gemma and drop it here. The pipeline
will load lazily and surface a `ModelLoadError` until the file is present.

## Verification

After download, confirm each file's hash matches what `scripts/fetch_models.sh`
prints. A truncated or corrupt file will fail at model-load time with an
error that's harder to debug than a checksum mismatch.
