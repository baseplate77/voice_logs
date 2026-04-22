#!/usr/bin/env bash
# Download VoxSynth model files into assets/models/. Idempotent — skips any
# file already present. Run from anywhere; paths are resolved relative to the
# repo root detected from this script's location.
#
# All artifacts — including the Gemma 4 E2B .litertlm bundle — are fetched
# from public HuggingFace mirrors; no Kaggle auth required.

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

# Silero VAD — ONNX, tiny. Optional in v2 (Parakeet is streaming), but kept
# for endpointing / barge-in detection if we want it in record flow later.
fetch "silero_vad.onnx" \
  "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"

# e5-small-v2 graph-optimized QInt8 ONNX from nixiesearch. ~33 MB. Bundled
# at build time (listed in pubspec.yaml) — loaded by flutter_onnxruntime.
# Prompt prefixes (`query: `, `passage: `), mean pooling, and L2 normalize
# are applied in Dart (see lib/embed/).
E5_DIR="$MODELS_DIR/e5"
mkdir -p "$E5_DIR"
fetch "e5/model_opt2_QInt8.onnx" \
  "https://huggingface.co/nixiesearch/e5-small-v2-onnx/resolve/main/model_opt2_QInt8.onnx"
fetch "e5/tokenizer.json" \
  "https://huggingface.co/nixiesearch/e5-small-v2-onnx/resolve/main/tokenizer.json"

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

# Gemma 4 E2B IT — LiteRT-LM bundle consumed by flutter_gemma at runtime.
# ~2.58 GB on disk, ~676 MB resident on GPU. The litert-community mirror is
# public (no Kaggle / HF auth required). flutter_gemma loads it via its
# AssetSourceHandler; see Phase 4 code once wired.
GEMMA_DIR="$MODELS_DIR/gemma"
mkdir -p "$GEMMA_DIR"
fetch "gemma/gemma-4-E2B-it.litertlm" \
  "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
echo ""
echo "Done. Files in $MODELS_DIR:"
ls -lh "$MODELS_DIR" | grep -v '^total' | grep -v 'README.md'
