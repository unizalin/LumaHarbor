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
source "${ROOT_DIR}/Scripts/release-versioning.sh"
APP_NAME="LumaHarbor"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
INFO_PLIST="${ROOT_DIR}/Resources/Info.plist"
OUTPUT_DIR="${LUMAHARBOR_RELEASE_DIR:-${ROOT_DIR}/dist}"
SIGNING_IDENTITY="${LUMAHARBOR_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${LUMAHARBOR_NOTARY_PROFILE:-}"
RELEASE_SCRATCH_PARENT="${LUMAHARBOR_RELEASE_SCRATCH_PARENT:-/private/tmp}"
RELEASE_SCRATCH_PATH=""
VERIFY_DIR=""
RESERVATION_PATH=""
RESERVATION_TOKEN=""
RESERVATION_HELD=0
STAGING_ARCHIVE_PATH=""
STAGING_CHECKSUM_PATH=""

cleanup() {
    [[ -z "${VERIFY_DIR}" ]] || rm -rf "${VERIFY_DIR}"
    [[ -z "${RELEASE_SCRATCH_PATH}" ]] || rm -rf "${RELEASE_SCRATCH_PATH}"
    if [[ "${RESERVATION_HELD}" == "1" ]]; then
        release_release_artifact_reservation "${RESERVATION_PATH}" "${RESERVATION_TOKEN}" || true
    fi
}
trap cleanup EXIT

if [[ -n "${NOTARY_PROFILE}" && -z "${SIGNING_IDENTITY}" ]]; then
    echo "error: LUMAHARBOR_NOTARY_PROFILE requires LUMAHARBOR_SIGNING_IDENTITY" >&2
    exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
ARCHIVE_NAME="$(release_archive_name "${APP_NAME}" "${VERSION}")"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

mkdir -p "${OUTPUT_DIR}"
RESERVATION_PATH="${ARCHIVE_PATH}.reservation"
RESERVATION_TOKEN="$$-${RANDOM}-${RANDOM}"
reserve_release_artifacts "${ARCHIVE_PATH}" "${CHECKSUM_PATH}" "${RESERVATION_PATH}" "${RESERVATION_TOKEN}"
RESERVATION_HELD=1
STAGING_ARCHIVE_PATH="${RESERVATION_PATH}/archive.zip"
STAGING_CHECKSUM_PATH="${RESERVATION_PATH}/archive.zip.sha256"
echo "==> Product version ${VERSION}; internal build ${BUILD_NUMBER}"

cd "${ROOT_DIR}"
mkdir -p "${RELEASE_SCRATCH_PARENT}"

# SwiftPM embeds the Bundle.module fallback path in the executable. Build in
# a neutral temporary directory so release artifacts never record a builder's
# account name or checkout location.
RELEASE_SCRATCH_PATH="$(mktemp -d "${RELEASE_SCRATCH_PARENT%/}/LumaHarborReleaseBuild.XXXXXX")"
export LUMAHARBOR_SCRATCH_PATH="${RELEASE_SCRATCH_PATH}"

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
Scripts/verify-release-privacy.sh "${APP_DIR}"

package_zip() {
    rm -f "${STAGING_ARCHIVE_PATH}"
    # Do not copy local macOS provenance/resource-fork metadata into the
    # distributable archive as `._*` AppleDouble files.
    COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn "${APP_DIR}" "${STAGING_ARCHIVE_PATH}"
}

echo "==> Packaging staged ${ARCHIVE_NAME}"
package_zip

if [[ -n "${NOTARY_PROFILE}" ]]; then
    echo "==> Submitting for notarization"
    xcrun notarytool submit "${STAGING_ARCHIVE_PATH}" \
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

# Verify the bytes the recipient will actually extract, not only the build
# directory that existed before archiving or notarization.
VERIFY_DIR="$(mktemp -d "${RELEASE_SCRATCH_PARENT%/}/LumaHarborReleaseVerify.XXXXXX")"
ditto -x -k "${STAGING_ARCHIVE_PATH}" "${VERIFY_DIR}"
VERIFY_APP_DIR="${VERIFY_DIR}/${APP_NAME}.app"
if [[ ! -d "${VERIFY_APP_DIR}" ]]; then
    echo "error: packaged app not found after archive extraction" >&2
    exit 1
fi
Scripts/verify-release-privacy.sh "${VERIFY_APP_DIR}"

ARCHIVE_DIGEST="$(shasum -a 256 "${STAGING_ARCHIVE_PATH}" | awk '{ print $1 }')"
printf '%s  %s\n' "${ARCHIVE_DIGEST}" "${ARCHIVE_NAME}" > "${STAGING_CHECKSUM_PATH}"
Scripts/verify-release-privacy.sh "${STAGING_CHECKSUM_PATH}"
publish_release_artifacts \
    "${STAGING_ARCHIVE_PATH}" \
    "${STAGING_CHECKSUM_PATH}" \
    "${ARCHIVE_PATH}" \
    "${CHECKSUM_PATH}"
echo "==> Done: ${ARCHIVE_PATH}"
echo "    Checksum: ${CHECKSUM_PATH}"
