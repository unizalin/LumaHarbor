#!/bin/bash
#
# Builds a macOS .app and packages it for repeatable distribution.
#
# Local/alpha use:
#   Scripts/package-mac-release.sh release
#
# Trusted public release (credentials stay in the local Keychain):
#   LUMAHARBOR_SIGNING_IDENTITY='Developer ID Application: ...' \
#   LUMAHARBOR_NOTARY_PROFILE='LumaHarbor-notary' \
#   Scripts/package-mac-release.sh release
#
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LumaHarbor"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
INFO_PLIST="${ROOT_DIR}/Resources/Info.plist"
OUTPUT_DIR="${LUMAHARBOR_RELEASE_DIR:-${ROOT_DIR}/dist}"
SIGNING_IDENTITY="${LUMAHARBOR_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${LUMAHARBOR_NOTARY_PROFILE:-}"

if [[ -n "${NOTARY_PROFILE}" && -z "${SIGNING_IDENTITY}" ]]; then
    echo "error: LUMAHARBOR_NOTARY_PROFILE requires LUMAHARBOR_SIGNING_IDENTITY" >&2
    exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
ARCHIVE_NAME="${APP_NAME}-${VERSION}-${BUILD_NUMBER}.zip"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

cd "${ROOT_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
Scripts/build-app-bundle.sh "${CONFIGURATION}"

if [[ -n "${SIGNING_IDENTITY}" ]]; then
    echo "==> Signing with Developer ID"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "${SIGNING_IDENTITY}" \
        "${APP_DIR}"
else
    echo "==> No Developer ID supplied; keeping the local ad-hoc signature"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

package_zip() {
    rm -f "${ARCHIVE_PATH}"
    # Do not copy local macOS provenance/resource-fork metadata into the
    # distributable archive as `._*` AppleDouble files.
    COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn "${APP_DIR}" "${ARCHIVE_PATH}"
}

echo "==> Packaging ${ARCHIVE_PATH}"
package_zip

if [[ -n "${NOTARY_PROFILE}" ]]; then
    echo "==> Submitting for notarization"
    xcrun notarytool submit "${ARCHIVE_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "${APP_DIR}"
    xcrun stapler validate "${APP_DIR}"

    # Stapling changes the app bundle, so package the stapled app again.
    package_zip
    spctl --assess --type execute --verbose=4 "${APP_DIR}"
else
    echo "==> Notarization skipped; this archive is for local or explicitly trusted alpha use"
fi

shasum -a 256 "${ARCHIVE_PATH}" | tee "${CHECKSUM_PATH}"
echo "==> Done: ${ARCHIVE_PATH}"
echo "    Checksum: ${CHECKSUM_PATH}"
