#!/usr/bin/env bash
# Workaround for sherpa-rs-sys shipping iOS sidecar libs as fat archives.
#
# sherpa-rs-sys extracts xcframeworks that contain `ios-arm64_x86_64-simulator`
# directories with fat .a files. Rust's linker (`rustc -L`) cannot add fat
# archives as native libraries — it errors with
# "Unsupported archive identifier". Apple's `lipo -thin` splits a fat archive
# into a per-architecture thin archive, which rustc can consume.
#
# This script walks the sherpa-rs cache for every installed iOS target and
# replaces fat .a files with thin ones matching that target's architecture.
# Safe to run repeatedly: already-thin archives are skipped.
#
# Call this before `cargo build --target aarch64-apple-ios*` or as part of a
# cargokit pre-build hook.

set -euo pipefail

CACHE_ROOT="${HOME}/Library/Caches/sherpa-rs"
if [[ ! -d "$CACHE_ROOT" ]]; then
  echo "[skip] No sherpa-rs cache at $CACHE_ROOT — nothing to slice."
  exit 0
fi

slice_one() {
  local fatfile="$1"
  local arch="$2"
  if file "$fatfile" 2>&1 | grep -q 'universal binary'; then
    echo "[slice] $arch  $(basename "$fatfile")"
    cp "$fatfile" "${fatfile}.fat"
    lipo -thin "$arch" "${fatfile}.fat" -output "$fatfile"
  fi
}

for target_dir in "$CACHE_ROOT"/aarch64-apple-ios-sim \
                  "$CACHE_ROOT"/aarch64-apple-ios \
                  "$CACHE_ROOT"/x86_64-apple-ios; do
  [[ -d "$target_dir" ]] || continue
  target_name="$(basename "$target_dir")"
  case "$target_name" in
    aarch64-*) arch=arm64 ;;
    x86_64-*)  arch=x86_64 ;;
  esac
  while IFS= read -r -d '' fatfile; do
    slice_one "$fatfile" "$arch"
  done < <(find "$target_dir" -name '*.a' -print0 2>/dev/null)
done

echo "[done] sherpa-rs iOS fat archives sliced."
