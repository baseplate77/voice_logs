# VoxSynth model files

These files are **not** in git (see `.gitignore` — total size ~3 GB). Run
`scripts/fetch_models.sh` from repo root to populate this directory.

## Expected files

| File | Size | Used by | Source |
|---|---|---|---|
| `silero_vad.onnx` | ~2 MB | Phase 1 (`lib/capture/`) | https://github.com/snakers4/silero-vad |
| `parakeet/{encoder,decoder,joiner}.int8.onnx` + `tokens.txt` | ~500 MB extracted | Phase 2 (`lib/asr/`) | sherpa-onnx releases (k2-fsa) |
| `gemma/gemma-4-E2B-it.litertlm` | ~2.58 GB | Phases 3/6/7 (`lib/llm/`) | litert-community HF mirror (public) |
| `ggml-small-q8_0.bin` | ~460 MB | (retired) | https://huggingface.co/ggerganov/whisper.cpp |
| `multilingual-e5-small-int8.onnx` | ~120 MB | Phase 4 (`lib/embed/`) | https://huggingface.co/intfloat/multilingual-e5-small |

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
