#!/bin/bash
#
# Wraps the SwiftPM executable in a real .app bundle.
#
# SwiftPM produces a bare Mach-O binary. SwiftUI runs from one, but without an
# Info.plist there is no bundle identifier, no proper activation policy and no
# Retina backing store — so anything you check by eye is checking the wrong
# thing. This script exists so `swift run` stays the fast path while manual QA
# gets a real app.
#
# Usage: Scripts/build-app-bundle.sh [debug|release]

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LumaHarbor"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

cd "${ROOT_DIR}"

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
swift build --configuration "${CONFIGURATION}" --product "${APP_NAME}"

BINARY_PATH="$(swift build --configuration "${CONFIGURATION}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BINARY_PATH}" ]]; then
    echo "error: built binary not found at ${BINARY_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BINARY_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# Ad-hoc signature. Enough for local runs; a distribution build needs a real
# identity and, if the app is ever sandboxed, the user-selected-files
# entitlement that security-scoped bookmarks require.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "${APP_DIR}" >/dev/null 2>&1 || {
    echo "warning: ad-hoc signing failed; the app may still run" >&2
}

echo "==> Done: ${APP_DIR}"
echo "    open \"${APP_DIR}\""
