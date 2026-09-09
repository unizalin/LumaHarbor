#!/bin/bash

set -euo pipefail

TARGET="${1:-}"
if [[ -z "${TARGET}" || ! -e "${TARGET}" ]]; then
    echo "error: provide an existing app bundle or extracted release directory" >&2
    exit 2
fi

# Scan file bytes, not only source diffs. SwiftPM-generated accessors and
# compiler output can contain strings that never appear in tracked files.
FORBIDDEN_PATH_PATTERN='/Users/|/Volumes/|/home/|[A-Za-z]:\\Users\\'
FILE_LIST="$(mktemp "${TMPDIR:-/private/tmp}/LumaHarborReleasePrivacyFiles.XXXXXX")"

cleanup() {
    rm -f "${FILE_LIST}"
}
trap cleanup EXIT

if ! find "${TARGET}" -type f -print0 > "${FILE_LIST}"; then
    echo "error: privacy scan could not enumerate release files" >&2
    exit 2
fi

while IFS= read -r -d '' file; do
    set +e
    LC_ALL=C grep -aEq "${FORBIDDEN_PATH_PATTERN}" "${file}" 2>/dev/null
    grep_status=$?
    set -e

    case "${grep_status}" in
        0)
            if [[ -d "${TARGET}" ]]; then
                relative_file="${file#"${TARGET}"/}"
            else
                relative_file="$(basename "${file}")"
            fi
            echo "error: private absolute path found in release file: ${relative_file}" >&2
            exit 1
            ;;
        1)
            ;;
        *)
            echo "error: privacy scan could not read a release file" >&2
            exit 2
            ;;
    esac
done < "${FILE_LIST}"

echo "release privacy scan: PASS"
