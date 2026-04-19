#!/bin/sh
set -e

BASEDIR=$(dirname "$0")

# Workaround for https://github.com/dart-lang/pub/issues/4010
BASEDIR=$(cd "$BASEDIR" ; pwd -P)

# Remove XCode SDK from path. Otherwise this breaks tool compilation when building iOS project
NEW_PATH=`echo $PATH | tr ":" "\n" | grep -v "Contents/Developer/" | tr "\n" ":"`

export PATH=${NEW_PATH%?} # remove trailing :

env

# Platform name (macosx, iphoneos, iphonesimulator)
export CARGOKIT_DARWIN_PLATFORM_NAME=$PLATFORM_NAME

# Arctive architectures (arm64, armv7, x86_64), space separated.
export CARGOKIT_DARWIN_ARCHS=$ARCHS

# Current build configuration (Debug, Release)
export CARGOKIT_CONFIGURATION=$CONFIGURATION

# Path to directory containing Cargo.toml.
export CARGOKIT_MANIFEST_DIR=$PODS_TARGET_SRCROOT/$1

# Temporary directory for build artifacts.
export CARGOKIT_TARGET_TEMP_DIR=$TARGET_TEMP_DIR

# Output directory for final artifacts.
export CARGOKIT_OUTPUT_DIR=$PODS_CONFIGURATION_BUILD_DIR/$PRODUCT_NAME

# Directory to store built tool artifacts.
export CARGOKIT_TOOL_TEMP_DIR=$TARGET_TEMP_DIR/build_tool

# Directory inside root project. Not necessarily the top level directory of root project.
export CARGOKIT_ROOT_PROJECT_DIR=$SRCROOT

FLUTTER_EXPORT_BUILD_ENVIRONMENT=(
  "$PODS_ROOT/../Flutter/ephemeral/flutter_export_environment.sh" # macOS
  "$PODS_ROOT/../Flutter/flutter_export_environment.sh" # iOS
)

for path in "${FLUTTER_EXPORT_BUILD_ENVIRONMENT[@]}"
do
  if [[ -f "$path" ]]; then
    source "$path"
  fi
done

# SRCROOT for iOS pod builds is ios/Pods — repo root is two levels up.
SLICER="$CARGOKIT_ROOT_PROJECT_DIR/../../scripts/slice_sherpa_ios.sh"

# VoxSynth: sherpa-rs-sys ships iOS sidecar libs as fat archives and rust's
# linker rejects them ("Unsupported archive identifier"). First pass primes
# the sherpa-rs cache; slicer converts fat → thin; second pass links cleanly.
# We also nuke the cached sherpa-rs-sys build artifact between passes so
# cargo re-invokes the linker with the now-thin archives (otherwise it
# short-circuits on the cached failure state).
echo "[voxsynth] slicer path: $SLICER" >&2
if [ -x "$SLICER" ]; then
  echo "[voxsynth] first cargokit pass (expected fat-archive failure)" >&2
  sh "$BASEDIR/run_build_tool.sh" build-pod "$@" || true
  echo "[voxsynth] slicing sherpa-rs cache" >&2
  bash "$SLICER" >&2 || true
  # Evict cached sherpa-rs-sys artifacts so the linker retries with thin libs.
  if [ -n "$CARGOKIT_TARGET_TEMP_DIR" ]; then
    find "$CARGOKIT_TARGET_TEMP_DIR" -type d -name 'sherpa-rs-sys-*' -exec rm -rf {} + 2>/dev/null || true
    find "$CARGOKIT_TARGET_TEMP_DIR" -type f -name 'libsherpa_rs_sys-*' -delete 2>/dev/null || true
  fi
  echo "[voxsynth] second cargokit pass (should succeed)" >&2
fi

sh "$BASEDIR/run_build_tool.sh" build-pod "$@"

# Make a symlink from built framework to phony file, which will be used as input to
# build script. This should force rebuild (podspec currently doesn't support alwaysOutOfDate
# attribute on custom build phase)
ln -fs "$OBJROOT/XCBuildData/build.db" "${BUILT_PRODUCTS_DIR}/cargokit_phony"
ln -fs "${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}" "${BUILT_PRODUCTS_DIR}/cargokit_phony_out"
