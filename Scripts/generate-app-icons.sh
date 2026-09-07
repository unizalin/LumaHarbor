#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="${ROOT_DIR}/Resources/AppIcon-1024.png"
MAC_CATALOG="${ROOT_DIR}/Resources/MacAssets.xcassets"
MAC_APPICONSET="${MAC_CATALOG}/AppIcon.appiconset"
ICNS="${ROOT_DIR}/Resources/LumaHarbor.icns"
OUTPUT_DIR="${ROOT_DIR}/.build/app-icon-assets"

if [[ ! -f "${MASTER}" ]]; then
    echo "error: master icon not found at ${MASTER}" >&2
    exit 1
fi

mkdir -p "${MAC_APPICONSET}"
mkdir -p "${OUTPUT_DIR}"

sips -z 16 16 "${MASTER}" --out "${MAC_APPICONSET}/icon_16x16.png" >/dev/null
sips -z 32 32 "${MASTER}" --out "${MAC_APPICONSET}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${MASTER}" --out "${MAC_APPICONSET}/icon_32x32.png" >/dev/null
sips -z 64 64 "${MASTER}" --out "${MAC_APPICONSET}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${MASTER}" --out "${MAC_APPICONSET}/icon_128x128.png" >/dev/null
sips -z 256 256 "${MASTER}" --out "${MAC_APPICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${MASTER}" --out "${MAC_APPICONSET}/icon_256x256.png" >/dev/null
sips -z 512 512 "${MASTER}" --out "${MAC_APPICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${MASTER}" --out "${MAC_APPICONSET}/icon_512x512.png" >/dev/null
cp "${MASTER}" "${MAC_APPICONSET}/icon_512x512@2x.png"

xcrun actool \
    --compile "${OUTPUT_DIR}" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${OUTPUT_DIR}/partial-info.plist" \
    "${MAC_CATALOG}" >/dev/null

cp "${OUTPUT_DIR}/AppIcon.icns" "${ICNS}"

echo "Generated ${ICNS} from ${MASTER}"
