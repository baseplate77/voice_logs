#!/usr/bin/env bash
# Download VoxSynth model files into assets/models/. Idempotent — skips any
# file already present. Run from anywhere; paths are resolved relative to the
# repo root detected from this script's location.
#
# Gemma is intentionally omitted: it requires Kaggle auth and manual placement.
# See assets/models/README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$REPO_ROOT/assets/models"

mkdir -p "$MODELS_DIR"

fetch() {
  local name="$1"
  local url="$2"
  local dest="$MODELS_DIR/$name"

  if [[ -s "$dest" ]]; then
    echo "[skip] $name already present ($(du -h "$dest" | cut -f1))"
    return 0
  fi

  echo "[fetch] $name <- $url"
  curl -L --fail --progress-bar -o "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
  echo "[done] $name ($(du -h "$dest" | cut -f1))"
}

# Silero VAD — ONNX, tiny.
fetch "silero_vad.onnx" \
  "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"

# Whisper small, q8_0 quantized GGML. ~460 MB.
fetch "ggml-small-q8_0.bin" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin"

# multilingual-e5-small, int8 ONNX. ~118 MB.
# The upstream repo only ships a VNNI-quantized int8 file; ONNX Runtime falls
# back to non-VNNI kernels on ARM. If this proves too slow on target devices,
# swap for model.onnx (470 MB fp32) in Phase 4.
fetch "multilingual-e5-small-int8.onnx" \
  "https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/onnx/model_qint8_avx512_vnni.onnx"

echo ""
echo "Gemma (gemma-4-it-int4.task) requires Kaggle auth — place manually."
echo "See assets/models/README.md."
echo ""
echo "Done. Files in $MODELS_DIR:"
ls -lh "$MODELS_DIR" | grep -v '^total' | grep -v 'README.md'
