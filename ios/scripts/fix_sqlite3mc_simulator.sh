#!/bin/sh
set -eu

if [ "${PLATFORM_NAME:-}" != "iphonesimulator" ]; then
  exit 0
fi

APP_DIR="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
FRAMEWORK_DIR="${APP_DIR}/Frameworks/sqlite3mc.framework"
FRAMEWORK_BINARY="${FRAMEWORK_DIR}/sqlite3mc"
ROOT_DIR="${PROJECT_DIR}/.."
TMP_BINARY="${DERIVED_FILE_DIR:-${TARGET_TEMP_DIR}}/sqlite3mc-ios-simulator"

SIM_DYLIBS="$($(/usr/bin/which python3) - "${ROOT_DIR}" <<'PY'
import glob
import json
import subprocess
import sys

root = sys.argv[1]
candidates = []

for input_path in glob.glob(f"{root}/.dart_tool/hooks_runner/sqlite3/*/input.json"):
    try:
        with open(input_path, "r", encoding="utf-8") as f:
            input_data = json.load(f)
        code_assets = input_data["config"]["extensions"]["code_assets"]
        if code_assets.get("target_os") != "ios":
            continue
        if code_assets.get("ios", {}).get("target_sdk") != "iphonesimulator":
            continue
        output_path = input_data["out_file"]
        with open(output_path, "r", encoding="utf-8") as f:
            output_data = json.load(f)
        for asset in output_data.get("assets", []):
            encoding = asset.get("encoding", {})
            path = encoding.get("file") or asset.get("file")
            if path and path.endswith("libsqlite3mc.dylib"):
                candidates.append(path)
    except Exception:
        continue

candidates.extend(glob.glob(f"{root}/.dart_tool/hooks_runner/shared/sqlite3/build/*/libsqlite3mc.dylib"))

by_arch = {}
for candidate in dict.fromkeys(candidates):
    try:
        build = subprocess.check_output(
            ["xcrun", "vtool", "-show-build", candidate],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if "platform IOSSIMULATOR" not in build:
            continue
        archs = subprocess.check_output(
            ["xcrun", "lipo", "-archs", candidate],
            stderr=subprocess.DEVNULL,
            text=True,
        ).split()
    except Exception:
        continue
    for arch in archs:
        by_arch.setdefault(arch, candidate)

wanted = ["arm64", "x86_64"]
selected = [by_arch[arch] for arch in wanted if arch in by_arch]
if not selected:
    sys.exit(1)
print("\n".join(selected))
PY
)"

if [ -z "${SIM_DYLIBS}" ]; then
  echo "error: Could not find iOS-simulator sqlite3mc native asset" >&2
  exit 1
fi

mkdir -p "${FRAMEWORK_DIR}"
mkdir -p "$(dirname "${TMP_BINARY}")"

set -- ${SIM_DYLIBS}
if [ "$#" -eq 1 ]; then
  cp -f "$1" "${FRAMEWORK_BINARY}"
else
  xcrun lipo -create "$@" -output "${TMP_BINARY}"
  cp -f "${TMP_BINARY}" "${FRAMEWORK_BINARY}"
fi
chmod +x "${FRAMEWORK_BINARY}"

if [ ! -f "${FRAMEWORK_DIR}/Info.plist" ]; then
  cat > "${FRAMEWORK_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>sqlite3mc</string>
  <key>CFBundleIdentifier</key>
  <string>io.flutter.flutter.native-assets.sqlite3mc</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>sqlite3mc</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
PLIST
fi

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
  SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY="-"
  fi
  /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${FRAMEWORK_DIR}"
fi

echo "Patched sqlite3mc.framework for iOS simulator:"
printf '  %s\n' ${SIM_DYLIBS}
