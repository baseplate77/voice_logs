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

# Parakeet-TDT-0.6B-v2 (sherpa-onnx int8 export). ~482 MB compressed,
# expands into assets/models/parakeet/ with encoder/decoder/joiner/tokens.
PARAKEET_DIR="$MODELS_DIR/parakeet"
PARAKEET_TAR="$MODELS_DIR/parakeet.tar.bz2"
if [[ -f "$PARAKEET_DIR/encoder.int8.onnx" ]]; then
  echo "[skip] Parakeet already extracted at $PARAKEET_DIR"
else
  echo "[fetch] sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 (~482 MB)"
  curl -L --fail --progress-bar -o "$PARAKEET_TAR.partial" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"
  mv "$PARAKEET_TAR.partial" "$PARAKEET_TAR"
  echo "[extract] parakeet.tar.bz2 -> $PARAKEET_DIR/"
  mkdir -p "$PARAKEET_DIR"
  tar -xjf "$PARAKEET_TAR" -C "$PARAKEET_DIR" --strip-components=1
  rm "$PARAKEET_TAR"
  echo "[done] Parakeet model extracted ($(du -sh "$PARAKEET_DIR" | cut -f1))"
fi

echo ""
echo "Gemma (gemma-4-it-int4.task) requires Kaggle auth — place manually."
echo "See assets/models/README.md."
echo ""
echo "Done. Files in $MODELS_DIR:"
ls -lh "$MODELS_DIR" | grep -v '^total' | grep -v 'README.md'
