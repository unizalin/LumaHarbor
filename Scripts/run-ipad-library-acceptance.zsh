#!/usr/bin/env zsh
#
# iPad multi-source RAW library acceptance runner.
#
# Writes evidence under:
#   .build/ipad-library/<UTC timestamp>-<pid>-<random>/
#
# Normal use:
#   Scripts/run-ipad-library-acceptance.zsh
#
# Internal self-test:
#   Scripts/run-ipad-library-acceptance.zsh __selftest

set -euo pipefail
unsetopt BG_NICE 2>/dev/null || true

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
PRODUCTION_RUN_TREE=".build/ipad-library"
SELFTEST_RUN_TREE=".build/ipad-library-selftest"

STEP_ORDER=(strictbuild swifttest simbuild multisourcebounded mvppreflight mvpacceptance ipadvertical)

typeset -A STEP_LABEL
STEP_LABEL=(
    strictbuild        "strict-concurrency build"
    swifttest          "swift test"
    simbuild           "iPad Simulator build"
    multisourcebounded "MultiSourceBoundedScanTests"
    mvppreflight       "MVP preflight"
    mvpacceptance      "MVP acceptance"
    ipadvertical       "iPad vertical-slice acceptance"
)

typeset -A STEP_LOGFILE
STEP_LOGFILE=(
    strictbuild        "strict-build.log"
    swifttest          "swift-test.log"
    simbuild           "ipad-simulator-build.log"
    multisourcebounded "multisource-bounded-scan.log"
    mvppreflight       "mvp-preflight.log"
    mvpacceptance      "mvp-acceptance.log"
    ipadvertical       "ipad-vertical-slice-acceptance.log"
)

typeset -A STEP_BLOCK_REASON
STEP_BLOCK_REASON=(
    strictbuild        "strict-concurrency build failed"
    swifttest          "swift test failed"
    simbuild           "iPad Simulator build failed"
    multisourcebounded "MultiSourceBoundedScanTests failed"
    mvppreflight       "MVP preflight failed"
    mvpacceptance      "MVP acceptance failed"
)

typeset -A STEP_STATE
typeset -A STEP_EXITCODE
typeset -A STEP_XCTEST

SIMULATION_MODE=0
CURRENT_STEP_KEY=""
RUN_DIR=""
SUMMARY_FILE=""
OVERALL_OK=1
FINALIZED=0
DEFERRED_SIGNAL=""
STEP_TIMEOUT_SECONDS=3600
PUBLISH_RETRY_LIMIT=20
PUBLISH_MV_CMD=(mv -f --)
CORRECTION_MARKER_NAME="PUBLISH_CORRECTION_FAILED"
COMMAND_RESOLVER="step_command_for"
LAST_BLOCK_REASON=""

die() {
    print -u2 -r -- "$1"
    exit 2
}

sed_escape_literal() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//|/\\|}"
    s="${s//./\\.}"
    s="${s//\*/\\*}"
    s="${s//\[/\\[}"
    s="${s//\]/\\]}"
    s="${s//^/\\^}"
    s="${s//\$/\\\$}"
    print -r -- "$s"
}

redact_literal() {
    local file="$1" literal="$2" token="$3"
    [[ -n "$literal" && -f "$file" ]] || return 0
    local escaped
    escaped="$(sed_escape_literal "$literal")"
    sed -i '' -e "s|${escaped}|${token}|g" "$file" || true
}

redact_pattern() {
    local file="$1" pattern="$2" token="$3"
    [[ -f "$file" ]] || return 0
    sed -i '' -E "s#${pattern}#${token}#g" "$file" || true
}

redact_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    redact_literal "$file" "$ROOT_DIR" "<REPO_ROOT>"
    redact_literal "$file" "${HOME:-}" "<HOME>"
    redact_literal "$file" "${LUMAHARBOR_RAW_FIXTURE_DIR:-}" "<RAW_FIXTURE_DIR>"
    redact_literal "$file" "${LUMAHARBOR_APFS_TEST_DIR:-}" "<APFS_TEST_DIR>"
    redact_literal "$file" "${LUMAHARBOR_EXFAT_TEST_DIR:-}" "<EXFAT_TEST_DIR>"
    redact_pattern "$file" '"(/Users/[^"]*|/Volumes/[^"]*|/private/var/[^"]*|/private/tmp/[^"]*|/var/[^"]*|/tmp/[^"]*)"' '"<PATH>"'
    redact_pattern "$file" "'(/Users/[^']*|/Volumes/[^']*|/private/var/[^']*|/private/tmp/[^']*|/var/[^']*|/tmp/[^']*)'" "'<PATH>'"
    redact_pattern "$file" '/Users/[^"'\''<>|]+' "<HOME_PATH>"
    redact_pattern "$file" '/Volumes/[^"'\''<>|]+' "<VOLUME_PATH>"
    redact_pattern "$file" '/private/var/[^"'\''<>|]+' "<PRIVATE_VAR_PATH>"
    redact_pattern "$file" '/private/tmp/[^"'\''<>|]+' "<PRIVATE_TMP_PATH>"
    redact_pattern "$file" '/var/[^"'\''<>|]+' "<VAR_PATH>"
    redact_pattern "$file" '/tmp/[^"'\''<>|]+' "<TMP_PATH>"
}

_privacy_grep_result() {
    local rc="$1"
    (( rc == 1 )) && return 1
    return 0
}

has_private_path() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local rc
    grep -Eq '/Users/|/Volumes/|/private/var/|/private/tmp/|/var/|/tmp/' "$file" 2>/dev/null
    rc=$?
    _privacy_grep_result "$rc" && return 0

    local literal
    for literal in "$ROOT_DIR" "${HOME:-}" "${LUMAHARBOR_RAW_FIXTURE_DIR:-}" \
        "${LUMAHARBOR_APFS_TEST_DIR:-}" "${LUMAHARBOR_EXFAT_TEST_DIR:-}"; do
        [[ -n "$literal" ]] || continue
        grep -qF -- "$literal" "$file" 2>/dev/null
        rc=$?
        _privacy_grep_result "$rc" && return 0
    done
    return 1
}

parse_xctest_summary() {
    local logfile="$1"
    local line found=0 executed=0 skipped=0 failures=0
    while IFS= read -r line; do
        if [[ "$line" =~ 'Executed ([0-9]+) tests?, with (([0-9]+) tests? skipped(,| and) )?([0-9]+) failures? \(' ]]; then
            executed="${match[1]}"
            skipped="${match[3]:-0}"
            failures="${match[5]}"
            found=1
        fi
    done < "$logfile"
    (( found )) || return 1
    print -r -- "${executed} ${skipped} ${failures}"
}

evaluate_xctest_log() {
    local logfile="$1" parsed
    if ! parsed="$(parse_xctest_summary "$logfile")"; then
        print -r -- "could not find an XCTest summary line in the log"
        return 1
    fi
    local -a fields
    fields=(${=parsed})
    local executed="${fields[1]}" skipped="${fields[2]}" failures="${fields[3]}"
    if (( executed == 0 )); then
        print -r -- "0 tests executed"
        return 1
    fi
    if (( skipped != 0 )); then
        print -r -- "${skipped} test(s) skipped (executed ${executed}, failures ${failures})"
        return 1
    fi
    if (( failures != 0 )); then
        print -r -- "${failures} failure(s) reported"
        return 1
    fi
    print -r -- "${executed} executed, ${skipped} skipped, ${failures} failures"
    return 0
}

collect_descendant_pids() {
    local root_pid="$1"
    local -a to_visit=("$root_pid") ordered=()
    while (( ${#to_visit[@]} > 0 )); do
        local pid="${to_visit[1]}"
        to_visit=("${to_visit[@]:1}")
        [[ -n "$pid" ]] || continue
        ordered+=("$pid")
        local out=""
        out="$(pgrep -P "$pid" 2>/dev/null)" || true
        local child
        for child in "${(f)out}"; do
            [[ -n "$child" ]] && to_visit+=("$child")
        done
    done
    local idx
    for (( idx=${#ordered[@]}; idx>=1; idx-- )); do
        print -r -- "${ordered[$idx]}"
    done
}

terminate_tree() {
    local root_pid="$1" sig="${2:-TERM}"
    local -a victims
    victims=("${(f)$(collect_descendant_pids "$root_pid")}")
    local pid
    for pid in "${victims[@]}"; do
        [[ -n "$pid" ]] && kill -"$sig" "$pid" 2>/dev/null || true
    done
}

run_with_timeout() {
    local timeout_seconds="$1" logfile="$2" cwd="$3"
    shift 3
    : > "$logfile"
    ( cd "$cwd" && "$@" ) >>"$logfile" 2>&1 &
    local cmd_pid=$!
    local elapsed=0
    local tick_sleep="1"
    local ticks_per_second=1
    if (( SIMULATION_MODE )); then
        tick_sleep="0.05"
        ticks_per_second=20
    fi
    local max_ticks=$((timeout_seconds * ticks_per_second))
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if (( elapsed >= max_ticks )); then
            terminate_tree "$cmd_pid" TERM
            sleep "$tick_sleep"
            terminate_tree "$cmd_pid" KILL
            wait "$cmd_pid" 2>/dev/null || true
            return 124
        fi
        sleep "$tick_sleep"
        elapsed=$((elapsed + 1))
    done
    local rc=0
    wait "$cmd_pid" 2>/dev/null || rc=$?
    return "$rc"
}

git_worktree_fingerprint() {
    local repo_root="$1" diff_output raw out hash
    if ! diff_output="$(git -C "$repo_root" diff HEAD --binary 2>/dev/null)"; then
        return 1
    fi
    if ! raw="$(git -C "$repo_root" ls-files --others --exclude-standard -z 2>/dev/null)"; then
        return 1
    fi
    local -a files
    files=(${(0)raw})
    if ! out="$(
        print -r -- "$diff_output"
        print -r -- "---untracked---"
        local f full mode size target
        for f in "${files[@]}"; do
            [[ -n "$f" ]] || continue
            full="${repo_root}/${f}"
            if [[ -L "$full" ]]; then
                target="$(readlink -- "$full")" || exit 1
                print -r -- "==> ${f} type=symlink target=${target}"
            elif [[ -f "$full" ]]; then
                mode="$(stat -f '%p' -- "$full" 2>/dev/null)" || exit 1
                size="$(stat -f '%z' -- "$full" 2>/dev/null)" || exit 1
                print -r -- "==> ${f} type=file mode=${mode} size=${size}"
                cat -- "$full" || exit 1
            else
                mode="$(stat -f '%p' -- "$full" 2>/dev/null)" || exit 1
                print -r -- "==> ${f} type=other mode=${mode}"
            fi
        done
    )"; then
        return 1
    fi
    hash="$(print -r -- "$out" | shasum -a 256 2>/dev/null)" || return 1
    print -r -- "${hash%% *}"
}

fixtures_available() {
    [[ -n "${LUMAHARBOR_RAW_FIXTURE_DIR:-}" && -d "${LUMAHARBOR_RAW_FIXTURE_DIR:-}" ]] || return 1
    [[ -n "${LUMAHARBOR_APFS_TEST_DIR:-}" && -d "${LUMAHARBOR_APFS_TEST_DIR:-}" ]] || return 1
    [[ -n "${LUMAHARBOR_EXFAT_TEST_DIR:-}" && -d "${LUMAHARBOR_EXFAT_TEST_DIR:-}" ]] || return 1
    return 0
}

step_command_for() {
    local key="$1"
    case "$key" in
        strictbuild)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=(swift build -Xswiftc -strict-concurrency=complete)
            ;;
        swifttest)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=(swift test)
            ;;
        simbuild)
            STEP_CWD="${ROOT_DIR}/Apps/LumaHarborPad.swiftpm"
            STEP_CMD=(xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)
            ;;
        multisourcebounded)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=(swift test --filter MultiSourceBoundedScanTests)
            ;;
        mvppreflight)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=("${ROOT_DIR}/Scripts/run-mvp-acceptance.zsh" --preflight-only)
            ;;
        mvpacceptance)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=("${ROOT_DIR}/Scripts/run-mvp-acceptance.zsh")
            ;;
        ipadvertical)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=("${ROOT_DIR}/Scripts/run-ipad-vertical-slice-acceptance.zsh")
            ;;
        *) return 1 ;;
    esac
}

typeset -A SIM_CMD
simulated_step_command_for() {
    local key="$1"
    STEP_CWD="$ROOT_DIR"
    STEP_CMD=(${(z)SIM_CMD[$key]})
}

mark_later_skipped() {
    local after_key="$1" reason="$2" seen=0 key
    for key in "${STEP_ORDER[@]}"; do
        if (( seen )) && [[ -z "${STEP_STATE[$key]:-}" ]]; then
            STEP_STATE[$key]="SKIPPED (${reason})"
            STEP_EXITCODE[$key]=""
        fi
        [[ "$key" == "$after_key" ]] && seen=1
    done
}

run_step() {
    local key="$1" label="${STEP_LABEL[$key]}" logfile="${RUN_DIR}/${STEP_LOGFILE[$key]}"
    LAST_BLOCK_REASON=""

    if [[ "$key" == "mvppreflight" || "$key" == "mvpacceptance" ]] \
        && [[ "$COMMAND_RESOLVER" == "step_command_for" ]] \
        && ! fixtures_available; then
        STEP_STATE[$key]="NOT RUN (fixture directories unavailable)"
        STEP_EXITCODE[$key]=""
        LAST_BLOCK_REASON="${label} not run because fixture directories are unavailable"
        OVERALL_OK=0
        print -r -- "${label}: NOT RUN (fixture directories unavailable)"
        return 1
    fi
    if [[ "$key" == "ipadvertical" && "$COMMAND_RESOLVER" == "step_command_for" && ! -x "${ROOT_DIR}/Scripts/run-ipad-vertical-slice-acceptance.zsh" ]]; then
        STEP_STATE[$key]="NOT RUN (Scripts/run-ipad-vertical-slice-acceptance.zsh is not integrated)"
        STEP_EXITCODE[$key]=""
        LAST_BLOCK_REASON="${label} not run because Scripts/run-ipad-vertical-slice-acceptance.zsh is not integrated"
        OVERALL_OK=0
        print -r -- "${label}: NOT RUN (vertical-slice runner unavailable)"
        return 1
    fi

    "$COMMAND_RESOLVER" "$key"
    print -r -- "==> ${label}"
    CURRENT_STEP_KEY="$key"
    local rc=0
    run_with_timeout "$STEP_TIMEOUT_SECONDS" "$logfile" "$STEP_CWD" "${STEP_CMD[@]}" || rc=$?
    CURRENT_STEP_KEY=""
    STEP_EXITCODE[$key]="$rc"

    if (( rc == 124 )); then
        STEP_STATE[$key]="FAIL (timed out after ${STEP_TIMEOUT_SECONDS}s; see ${STEP_LOGFILE[$key]})"
        LAST_BLOCK_REASON="${label} timed out"
        OVERALL_OK=0
        print -r -- "${label}: FAIL (timed out)"
        return 1
    fi
    if (( rc != 0 )); then
        STEP_STATE[$key]="FAIL (command exited ${rc}; see ${STEP_LOGFILE[$key]})"
        LAST_BLOCK_REASON="${label} failed"
        OVERALL_OK=0
        print -r -- "${label}: FAIL (command exited ${rc})"
        return 1
    fi

    if [[ "$key" == "swifttest" || "$key" == "multisourcebounded" ]]; then
        local detail
        if (( SIMULATION_MODE )); then
            STEP_XCTEST[$key]="simulated XCTest summary"
        elif detail="$(evaluate_xctest_log "$logfile")"; then
            STEP_XCTEST[$key]="$detail"
        else
            STEP_STATE[$key]="FAIL (${detail})"
            LAST_BLOCK_REASON="${label} failed"
            OVERALL_OK=0
            print -r -- "${label}: FAIL (${detail})"
            return 1
        fi
    fi

    STEP_STATE[$key]="PASS"
    print -r -- "${label}: PASS"
    return 0
}

record_publish_correction_failure() {
    local reason="$1"
    [[ -n "$RUN_DIR" ]] || return 1
    print -r -- "publish correction failed: ${reason}" > "${RUN_DIR}/${CORRECTION_MARKER_NAME}" 2>/dev/null || return 1
}

write_summary_content() {
    local file="$1" mode_label="$2" overall="$3" exit_code="$4" fingerprint="$5" privacy="$6"
    {
        print -r -- "Run mode: ${mode_label}"
        print -r -- "Overall result: ${overall}"
        print -r -- "Exit code: ${exit_code}"
        print -r -- "Commit: $(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || print -r -- unknown)"
        print -r -- "Timestamp UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        print -r -- "Architecture: $(uname -m 2>/dev/null || print -r -- unknown)"
        print -r -- "Repo fingerprint: ${fingerprint}"
        print -r -- "Privacy scan: ${privacy}"
        print -r -- ""
        print -r -- "Steps:"
        local key
        for key in "${STEP_ORDER[@]}"; do
            print -r -- "- ${STEP_LABEL[$key]}: ${STEP_STATE[$key]:-NOT RUN}"
            if [[ -n "${STEP_EXITCODE[$key]:-}" ]]; then
                print -r -- "  exit: ${STEP_EXITCODE[$key]}"
            fi
            if [[ -n "${STEP_XCTEST[$key]:-}" ]]; then
                print -r -- "  XCTest: ${STEP_XCTEST[$key]}"
            fi
        done
        print -r -- ""
        print -r -- "Real-device checklist:"
        print -r -- "- M1+ iPad APFS add/scan/relaunch: NOT RUN"
        print -r -- "- exFAT add/unplug/offline/relink: NOT RUN"
        print -r -- "- Files provider reauthorisation: NOT RUN"
        print -r -- "- Three-source aggregate search/sort/restoration: NOT RUN"
        print -r -- "- Sony ARW edit/autosave/reopen/checksum: NOT RUN"
    } > "$file"
}

finalize_run() {
    local exit_code="${1:-0}"
    FINALIZED=1

    local file
    for file in "$RUN_DIR"/*.log(N); do
        redact_file "$file"
    done

    local fingerprint="UNVERIFIED"
    if fingerprint="$(git_worktree_fingerprint "$ROOT_DIR")"; then
        :
    else
        fingerprint="UNVERIFIED (failed closed)"
        OVERALL_OK=0
    fi

    local privacy="PASS"
    local tmp="${SUMMARY_FILE}.tmp.$$"
    write_summary_content "$tmp" "$([[ "$SIMULATION_MODE" == "1" ]] && print -r -- SELFTEST || print -r -- PRODUCTION)" "UNKNOWN" "$exit_code" "$fingerprint" "PENDING"
    redact_file "$tmp"

    for file in "$RUN_DIR"/*.log(N) "$tmp"; do
        if has_private_path "$file"; then
            privacy="FAIL"
            OVERALL_OK=0
        fi
    done

    local overall="PASS"
    (( OVERALL_OK )) || overall="FAIL"
    write_summary_content "$tmp" "$([[ "$SIMULATION_MODE" == "1" ]] && print -r -- SELFTEST || print -r -- PRODUCTION)" "$overall" "$exit_code" "$fingerprint" "$privacy"
    redact_file "$tmp"

    local published=0 attempt
    for (( attempt=1; attempt<=PUBLISH_RETRY_LIMIT; attempt++ )); do
        if "${PUBLISH_MV_CMD[@]}" "$tmp" "$SUMMARY_FILE" 2>/dev/null; then
            published=1
            break
        fi
    done
    if (( ! published )); then
        record_publish_correction_failure "could not publish summary.md after ${PUBLISH_RETRY_LIMIT} attempts" || true
        return 1
    fi
    print -r -- "summary: ${SUMMARY_FILE}"
    return 0
}

exit_for_signal() {
    case "$1" in
        HUP) exit 129 ;;
        INT) exit 130 ;;
        TERM) exit 143 ;;
        *) exit 130 ;;
    esac
}

handle_signal() {
    local sig="$1"
    DEFERRED_SIGNAL="$sig"
    OVERALL_OK=0
    if [[ -n "$CURRENT_STEP_KEY" ]]; then
        STEP_STATE[$CURRENT_STEP_KEY]="FAIL (interrupted by ${sig})"
        STEP_EXITCODE[$CURRENT_STEP_KEY]=""
        mark_later_skipped "$CURRENT_STEP_KEY" "interrupted by ${sig}"
    fi
    if (( ! FINALIZED )); then
        finalize_run "$(case "$sig" in HUP) print 129 ;; INT) print 130 ;; TERM) print 143 ;; *) print 130 ;; esac)" || true
    fi
    exit_for_signal "$sig"
}

trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

init_run_dir() {
    local tree="$1"
    mkdir -p "${ROOT_DIR}/${tree}"
    RUN_DIR="${ROOT_DIR}/${tree}/$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}"
    mkdir -p "$RUN_DIR"
    SUMMARY_FILE="${RUN_DIR}/summary.md"
}

run_acceptance_flow() {
    local key
    for key in "${STEP_ORDER[@]}"; do
        if ! run_step "$key"; then
            mark_later_skipped "$key" "${LAST_BLOCK_REASON:-${STEP_BLOCK_REASON[$key]:-${STEP_LABEL[$key]} failed}}"
            break
        fi
    done
    local exit_code=0
    (( OVERALL_OK )) || exit_code=1
    finalize_run "$exit_code" || exit_code=1
    return "$exit_code"
}

assert_selftest() {
    local name="$1"
    shift
    if "$@"; then
        print -r -- "PASS ${name}"
    else
        print -u2 -r -- "FAIL ${name}"
        return 1
    fi
}

selftest_run_simulation() {
    local label="$1"
    shift
    "$SCRIPT_PATH" __selftest_simulate_steps "$@" >/dev/null 2>&1
}

run_selftest() {
    init_run_dir "$SELFTEST_RUN_TREE"
    local failures=0

    if _privacy_grep_result 1; then
        print -u2 -r -- "FAIL privacy grep rc 1 means clean"
        failures=$((failures + 1))
    else
        print -r -- "PASS privacy grep rc 1 means clean"
    fi
    if _privacy_grep_result 2; then
        print -r -- "PASS privacy grep rc 2 fails closed"
    else
        print -u2 -r -- "FAIL privacy grep rc 2 fails closed"
        failures=$((failures + 1))
    fi

    local privacy_file="${RUN_DIR}/privacy sample 測試.log"
    print -r -- "private /Users/example/照片 and /tmp/lh-test" > "$privacy_file"
    redact_file "$privacy_file"
    if has_private_path "$privacy_file"; then
        print -u2 -r -- "FAIL redaction removes private paths"
        failures=$((failures + 1))
    else
        print -r -- "PASS redaction removes private paths"
    fi

    if selftest_run_simulation "all pass" true true true true true true true; then
        print -r -- "PASS simulated all-pass run"
    else
        print -u2 -r -- "FAIL simulated all-pass run"
        failures=$((failures + 1))
    fi

    if selftest_run_simulation "command failure" true false true true true true true; then
        print -u2 -r -- "FAIL simulated failing run exits non-zero"
        failures=$((failures + 1))
    else
        print -r -- "PASS simulated failing run exits non-zero"
    fi

    local mv_rc=0
    "$SCRIPT_PATH" __selftest_simulate_steps true true true true true true true --fake-mv=false >/dev/null 2>&1 || mv_rc=$?
    if (( mv_rc == 0 )); then
        print -u2 -r -- "FAIL permanent publish mv failure exits non-zero"
        failures=$((failures + 1))
    else
        print -r -- "PASS permanent publish mv failure exits non-zero"
    fi

    "$SCRIPT_PATH" __selftest_simulate_steps true true true true true true true >/dev/null 2>&1 &
    local p1=$!
    "$SCRIPT_PATH" __selftest_simulate_steps true true true true true true true >/dev/null 2>&1 &
    local p2=$!
    wait "$p1" || failures=$((failures + 1))
    wait "$p2" || failures=$((failures + 1))
    print -r -- "PASS concurrent simulated runs complete"

    if (( failures == 0 )); then
        STEP_STATE[strictbuild]="PASS"
        STEP_STATE[swifttest]="PASS"
        STEP_STATE[simbuild]="PASS"
        STEP_STATE[multisourcebounded]="PASS"
        STEP_STATE[mvppreflight]="PASS"
        STEP_STATE[mvpacceptance]="PASS"
        STEP_STATE[ipadvertical]="PASS"
        OVERALL_OK=1
        finalize_run 0 >/dev/null || return 1
        print -r -- "Overall PASS"
        return 0
    else
        OVERALL_OK=0
        finalize_run 1 >/dev/null || true
        print -u2 -r -- "Overall FAIL (${failures} failure(s))"
        return 1
    fi
}

selftest_simulate_steps() {
    (( $# >= 7 )) || die "__selftest_simulate_steps requires seven command strings"
    SIMULATION_MODE=1
    COMMAND_RESOLVER="simulated_step_command_for"
    SIM_CMD[strictbuild]="$1"
    SIM_CMD[swifttest]="$2"
    SIM_CMD[simbuild]="$3"
    SIM_CMD[multisourcebounded]="$4"
    SIM_CMD[mvppreflight]="$5"
    SIM_CMD[mvpacceptance]="$6"
    SIM_CMD[ipadvertical]="$7"
    shift 7
    while (( $# > 0 )); do
        case "$1" in
            --fake-mv=false) PUBLISH_MV_CMD=(false) ;;
            *) die "unknown selftest flag: $1" ;;
        esac
        shift
    done
    init_run_dir "$SELFTEST_RUN_TREE"
    run_acceptance_flow
}

main() {
    case "${1:-}" in
        "")
            (( $# == 0 )) || die "usage: Scripts/run-ipad-library-acceptance.zsh [__selftest]"
            init_run_dir "$PRODUCTION_RUN_TREE"
            run_acceptance_flow
            ;;
        __selftest)
            (( $# == 1 )) || die "usage: Scripts/run-ipad-library-acceptance.zsh __selftest"
            run_selftest
            ;;
        __selftest_simulate_steps)
            shift
            selftest_simulate_steps "$@"
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
}

main "$@"
