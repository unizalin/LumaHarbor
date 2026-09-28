#!/bin/bash

release_archive_name() {
    local app_name="$1"
    local version="$2"
    if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "error: invalid semantic version: ${version}" >&2
        return 2
    fi
    printf '%s-%s.zip\n' "${app_name}" "${version}"
}

assert_release_artifacts_available() {
    local archive_path="$1"
    local checksum_path="$2"
    if [[ -e "${archive_path}" || -e "${checksum_path}" ]]; then
        echo "error: release artifact already exists; bump the product version before publishing again" >&2
        return 3
    fi
}
