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

release_artifact_path_exists() {
    local path="$1"
    [[ -e "${path}" || -L "${path}" ]]
}

assert_no_legacy_release_artifacts() {
    local archive_path="$1"
    local archive_directory="${archive_path%/*}"
    local archive_name="${archive_path##*/}"
    local archive_stem="${archive_name%.zip}"
    local legacy_artifact

    for legacy_artifact in "${archive_directory}/${archive_stem}-"*.zip \
        "${archive_directory}/${archive_stem}-"*.zip.sha256; do
        if release_artifact_path_exists "${legacy_artifact}"; then
            echo "error: release artifact already exists; bump the product version before publishing again" >&2
            return 3
        fi
    done
}

assert_release_artifacts_available() {
    local archive_path="$1"
    local checksum_path="$2"

    if release_artifact_path_exists "${archive_path}" || \
        release_artifact_path_exists "${checksum_path}"; then
        echo "error: release artifact already exists; bump the product version before publishing again" >&2
        return 3
    fi

    assert_no_legacy_release_artifacts "${archive_path}"
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

    rm -f "${reservation_path}/archive.zip" "${reservation_path}/archive.zip.sha256"
    rm -f "${reservation_path}/owner"
    rmdir "${reservation_path}"
}

rollback_owned_release_artifact() {
    local staging_path="$1"
    local final_path="$2"

    if [[ -e "${staging_path}" && -e "${final_path}" && "${staging_path}" -ef "${final_path}" ]]; then
        rm -f "${final_path}"
    fi
}

finalize_release_artifact_publication() {
    local staging_archive_path="$1"
    local staging_checksum_path="$2"
    local archive_path="$3"
    local checksum_path="$4"

    if [[ ! "${staging_archive_path}" -ef "${archive_path}" || \
        ! "${staging_checksum_path}" -ef "${checksum_path}" ]]; then
        rollback_owned_release_artifact "${staging_checksum_path}" "${checksum_path}"
        rollback_owned_release_artifact "${staging_archive_path}" "${archive_path}"
        echo "error: release artifact changed while publishing; existing bytes were preserved" >&2
        return 3
    fi

    if assert_no_legacy_release_artifacts "${archive_path}"; then
        :
    else
        local status=$?
        rollback_owned_release_artifact "${staging_checksum_path}" "${checksum_path}"
        rollback_owned_release_artifact "${staging_archive_path}" "${archive_path}"
        return "${status}"
    fi
}

publish_release_artifacts() {
    local staging_archive_path="$1"
    local staging_checksum_path="$2"
    local archive_path="$3"
    local checksum_path="$4"

    if [[ ! -f "${staging_archive_path}" || -L "${staging_archive_path}" || \
        ! -f "${staging_checksum_path}" || -L "${staging_checksum_path}" ]]; then
        echo "error: staged release artifacts are missing or unsafe" >&2
        return 1
    fi

    assert_release_artifacts_available "${archive_path}" "${checksum_path}" || return $?

    if ! ln -h "${staging_archive_path}" "${archive_path}" 2>/dev/null; then
        echo "error: release artifact appeared while publishing; existing bytes were preserved" >&2
        return 3
    fi

    if ! ln -h "${staging_checksum_path}" "${checksum_path}" 2>/dev/null; then
        rollback_owned_release_artifact "${staging_archive_path}" "${archive_path}"
        echo "error: release artifact appeared while publishing; existing bytes were preserved" >&2
        return 3
    fi

    finalize_release_artifact_publication \
        "${staging_archive_path}" \
        "${staging_checksum_path}" \
        "${archive_path}" \
        "${checksum_path}"
}
