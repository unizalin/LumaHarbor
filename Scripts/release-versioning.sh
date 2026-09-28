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
    local archive_directory="${archive_path%/*}"
    local archive_name="${archive_path##*/}"
    local archive_stem="${archive_name%.zip}"
    local legacy_artifact

    if [[ -e "${archive_path}" || -e "${checksum_path}" ]]; then
        echo "error: release artifact already exists; bump the product version before publishing again" >&2
        return 3
    fi

    for legacy_artifact in "${archive_directory}/${archive_stem}-"*.zip \
        "${archive_directory}/${archive_stem}-"*.zip.sha256; do
        if [[ -e "${legacy_artifact}" ]]; then
            echo "error: release artifact already exists; bump the product version before publishing again" >&2
            return 3
        fi
    done
}

reserve_release_artifacts() {
    local archive_path="$1"
    local checksum_path="$2"
    local reservation_path="$3"
    local owner_token="$4"

    assert_release_artifacts_available "${archive_path}" "${checksum_path}" || return $?

    if ! mkdir "${reservation_path}" 2>/dev/null; then
        echo "error: release artifact already exists or is already being packaged; bump the product version before publishing again" >&2
        return 3
    fi

    if ! printf '%s\n' "${owner_token}" > "${reservation_path}/owner"; then
        rmdir "${reservation_path}" 2>/dev/null || true
        echo "error: could not record release artifact reservation" >&2
        return 1
    fi

    if assert_release_artifacts_available "${archive_path}" "${checksum_path}"; then
        :
    else
        local status=$?
        release_release_artifact_reservation "${reservation_path}" "${owner_token}" || true
        return "${status}"
    fi
}

release_release_artifact_reservation() {
    local reservation_path="$1"
    local owner_token="$2"
    local recorded_token

    [[ -d "${reservation_path}" ]] || return 0
    [[ -f "${reservation_path}/owner" ]] || return 1
    IFS= read -r recorded_token < "${reservation_path}/owner" || return 1
    [[ "${recorded_token}" == "${owner_token}" ]] || return 1

    rm -f "${reservation_path}/owner"
    rmdir "${reservation_path}"
}
