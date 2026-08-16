#!/usr/bin/env zsh
#
# Gate A/B/D acceptance runner for the Mac-first MVP acceptance plan:
#   docs/superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md
#
# Read-only checks only. This script never formats, mounts, unmounts,
# deletes or chmods anything under the user's fixture or storage test
# directories — it only stats them, lists filenames, and asks `df`/`mount`
# what filesystem they live on. It never prints an absolute path from
# LUMAHARBOR_RAW_FIXTURE_DIR / LUMAHARBOR_APFS_TEST_DIR /
# LUMAHARBOR_EXFAT_TEST_DIR to stdout or to a log file — only the variable
# name, a PASS/FAIL/SKIPPED status, and (where useful for troubleshooting) a
# bare filename with no directory component.
#
# Every required condition (arm64, full Xcode, xcodebuild, swift, and all
# three test directories) is verified up front and the run fails closed —
# with an explicit reason per missing item — before anything is built or
# tested. A skipped step is reported as SKIPPED, never as a pass.
#
# Usage:
#   Scripts/run-mvp-acceptance.zsh                  # full Gate A/B/D run
#   Scripts/run-mvp-acceptance.zsh --preflight-only  # Gate A checks only,
#                                                     # no build or test step
#
# Required environment variables (this script only reads them, it does not
# set defaults, so a missing one fails closed rather than guessing a path):
#   LUMAHARBOR_RAW_FIXTURE_DIR  Folder of real camera RAW files (>= 1 .ARW).
#   LUMAHARBOR_APFS_TEST_DIR    Scratch folder on an APFS volume.
#   LUMAHARBOR_EXFAT_TEST_DIR   Scratch folder on an exFAT volume.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repo root from this script's own location, not $PWD, so the
# runner behaves the same no matter where the caller invoked it from. Done
# before anything else (including the self-test dispatch below) because
# run_with_timeout needs ROOT_DIR under `set -u`, and the self-test exercises
# run_with_timeout directly.
# ---------------------------------------------------------------------------

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

# ---------------------------------------------------------------------------
# XCTest summary parsing. `swift test` exits 0 even when XCTest reports
# skipped tests, so a bare exit-code check would mislabel a run with silent
# skips as PASS. These two functions are also exercised by an internal,
# undocumented self-check (LUMAHARBOR_RUNNER_SELFTEST=1, not a CLI flag) so
# the parsing logic itself can be verified deterministically on a host that
# has no XCTest runtime at all.
# ---------------------------------------------------------------------------

# parse_xctest_summary <logfile>
# Prints "<executed> <skipped> <failures>" from the *last* XCTest
# "Executed N tests, with ... failures ..." line in the log — that line is
# always the run's own aggregate total, whether the log is a full suite or a
# --filter'd subset. Returns 1 if no such line is found at all, which must
# never be treated as a passing run.
parse_xctest_summary() {
    local logfile="$1"
    local line found=0
    local executed=0 skipped=0 failures=0
    while IFS= read -r line; do
        # The skip clause's separator varies by toolchain: some print
        # "N tests skipped, F failures", others "N tests skipped and F
        # failures". Both are accepted; whichever is present, the skip count
        # is compared numerically to zero below, not detected by the mere
        # presence of the word "skipped".
        if [[ "$line" =~ 'Executed ([0-9]+) tests?, with (([0-9]+) tests? skipped(,| and) )?([0-9]+) failures? \(' ]]; then
            executed="${match[1]}"
            if [[ -n "${match[3]:-}" ]]; then
                skipped="${match[3]}"
            else
                skipped=0
            fi
            failures="${match[5]}"
            found=1
        fi
    done < "$logfile"
    (( found )) || return 1
    print -r -- "${executed} ${skipped} ${failures}"
}

# evaluate_xctest_log <logfile> [required_executed_count]
# On stdout: nothing when the run is clean; a one-line human-readable reason
# when it is not. Return 0 only for a genuinely clean, fully-run suite: a
# parseable summary, zero skipped tests, zero failures, and — when a required
# count is given — an executed count that matches it exactly. Any skip at all
# fails the check; "0 tests skipped" and "0 failures" are not read as "some
# skips happened", since the digit is compared numerically, not the presence
# of the word "skipped".
evaluate_xctest_log() {
    local logfile="$1" required="${2:-}"
    local parsed
    if ! parsed="$(parse_xctest_summary "$logfile")"; then
        print -r -- "could not find an XCTest summary line in the log"
        return 1
    fi
    local -a fields
    fields=(${=parsed})
    local executed="${fields[1]}" skipped="${fields[2]}" failures="${fields[3]}"
    if (( skipped != 0 )); then
        print -r -- "${skipped} test(s) skipped (executed ${executed}, failures ${failures})"
        return 1
    fi
    if [[ -n "$required" ]] && (( executed != required )); then
        print -r -- "executed ${executed} tests, expected exactly ${required}"
        return 1
    fi
    if (( failures != 0 )); then
        print -r -- "${failures} failure(s) reported in summary"
        return 1
    fi
    return 0
}

# Internal self-check for the two functions above: synthetic XCTest summary
# lines, no real XCTest runtime needed. Not a supported CLI flag — triggered
# only by an undocumented environment variable so Codex (or anyone) can
# verify the parser fails closed on skips even on a host that can never run
# `swift test` for real.
run_selftest() {
    local tmp
    tmp="$(mktemp -d)"
    local failures=0

    write_selftest_case() {
        local file="$1" body="$2"
        print -r -- "Test Suite 'All tests' passed at 2026-01-01 00:00:00.000." > "$file"
        print -r -- $'\t '"$body" >> "$file"
    }

    write_selftest_case "${tmp}/zero-skip.log" \
        "Executed 5 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/zero-skip.log" >/dev/null; then
        print -r -- "selftest: 0 skipped -> PASS (expected PASS): ok"
    else
        print -r -- "selftest: 0 skipped -> unexpectedly FAILED"
        failures=$((failures + 1))
    fi

    write_selftest_case "${tmp}/one-skip-comma.log" \
        "Executed 5 tests, with 1 test skipped, 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/one-skip-comma.log" >/dev/null; then
        print -r -- "selftest: 1 test skipped (comma form) -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: 1 test skipped (comma form) -> FAIL (expected FAIL): ok"
    fi

    # XCTest toolchains have used both "N tests skipped, F failures" and
    # "N tests skipped and F failures" — Finding 2 was that only the comma
    # form was recognised, so a real "and"-separated summary line slipped
    # past parse_xctest_summary entirely (falling through to "0 skipped").
    write_selftest_case "${tmp}/one-skip-and.log" \
        "Executed 5 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/one-skip-and.log" >/dev/null; then
        print -r -- "selftest: 1 test skipped (and form) -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: 1 test skipped (and form) -> FAIL (expected FAIL): ok"
    fi

    write_selftest_case "${tmp}/two-skip-comma.log" \
        "Executed 5 tests, with 2 tests skipped, 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/two-skip-comma.log" >/dev/null; then
        print -r -- "selftest: 2 tests skipped (comma form, plural) -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: 2 tests skipped (comma form, plural) -> FAIL (expected FAIL): ok"
    fi

    write_selftest_case "${tmp}/executed-7.log" \
        "Executed 7 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/executed-7.log" 8 >/dev/null; then
        print -r -- "selftest: executed=7, required=8 -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: executed=7, required=8 -> FAIL (expected FAIL): ok"
    fi

    write_selftest_case "${tmp}/executed-8.log" \
        "Executed 8 tests, with 0 tests skipped, 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/executed-8.log" 8 >/dev/null; then
        print -r -- "selftest: executed=8, required=8 -> PASS (expected PASS): ok"
    else
        print -r -- "selftest: executed=8, required=8 -> unexpectedly FAILED"
        failures=$((failures + 1))
    fi

    write_selftest_case "${tmp}/executed-9.log" \
        "Executed 9 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/executed-9.log" 8 >/dev/null; then
        print -r -- "selftest: executed=9, required=8 -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: executed=9, required=8 -> FAIL (expected FAIL): ok"
    fi

    print -r -- "no XCTest summary in this log at all" > "${tmp}/unparsable.log"
    if evaluate_xctest_log "${tmp}/unparsable.log" >/dev/null; then
        print -r -- "selftest: unparsable log -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: unparsable log -> FAIL (expected FAIL): ok"
    fi

    # A synthetic fast command: run_with_timeout must complete it well inside
    # its budget, report no timeout, and preserve its exit code.
    if run_with_timeout 10 "${tmp}/fast.log" zsh -c 'exit 0'; then
        if (( TIMEOUT_HIT == 0 )); then
            print -r -- "selftest: fast command -> PASS, no timeout (expected): ok"
        else
            print -r -- "selftest: fast command -> unexpectedly reported a timeout"
            failures=$((failures + 1))
        fi
    else
        print -r -- "selftest: fast command -> unexpectedly failed"
        failures=$((failures + 1))
    fi

    # A synthetic hanging command: a short 2s budget must cut it off within a
    # few seconds (2s wait + up to 5s grace, bounded), report a timeout, and
    # leave no descendant process running afterward.
    local hang_start=$SECONDS
    local hang_rc=0
    run_with_timeout 2 "${tmp}/hang.log" zsh -c 'sleep 60' || hang_rc=$?
    local hang_elapsed=$((SECONDS - hang_start))
    if (( TIMEOUT_HIT == 1 && hang_rc == 124 )); then
        print -r -- "selftest: hanging command -> reported timeout (expected): ok"
    else
        print -r -- "selftest: hanging command -> did not report a timeout as expected"
        failures=$((failures + 1))
    fi
    if (( hang_elapsed <= 15 )); then
        print -r -- "selftest: hanging command -> cut off within ${hang_elapsed}s (expected): ok"
    else
        print -r -- "selftest: hanging command -> took ${hang_elapsed}s, expected well under 15s"
        failures=$((failures + 1))
    fi
    # `pgrep -f` here matches only the exact synthetic self-test payload this
    # function just launched (a `sleep 60` under a `zsh -c` argument unique to
    # this check), never a broad process-name pattern.
    if pgrep -f 'zsh -c sleep 60' >/dev/null 2>&1; then
        print -r -- "selftest: hanging command -> a descendant process survived the kill"
        failures=$((failures + 1))
    else
        print -r -- "selftest: hanging command -> no descendant process left running (expected): ok"
    fi

    # This mktemp -d is the self-check's own private scratch directory, not
    # a user fixture or storage test directory — cleaning it up here is not
    # the destructive-operation-on-user-data this script otherwise forbids.
    rm -rf -- "$tmp"

    if (( failures == 0 )); then
        print -r -- "selftest: all cases behaved as expected"
        return 0
    else
        print -r -- "selftest: ${failures} case(s) behaved unexpectedly"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Timeout watchdog. Stock-macOS-only (no GNU coreutils `timeout`, no
# Homebrew): a command is launched inside its own subshell — the "wrapper
# process" — so the wrapper's PID is a stable root for walking exactly its
# own descendants via `pgrep -P`, never a broad process-name match. On
# timeout, every live descendant gets TERM, then (after a short grace period)
# KILL for anyone still alive.
# ---------------------------------------------------------------------------

# kill_descendants_of <root_pid> <signal>
# Recursively collects every live descendant of root_pid (root_pid included)
# via `pgrep -P` and signals each one. Scoped entirely to this process's own
# subtree, so it cannot touch an unrelated swift/xcodebuild process elsewhere
# on the machine.
kill_descendants_of() {
    local root_pid="$1" sig="$2"
    local -a to_visit=("$root_pid") all_pids=()
    while (( ${#to_visit[@]} > 0 )); do
        local pid="${to_visit[1]}"
        to_visit=("${to_visit[@]:1}")
        [[ -n "$pid" ]] || continue
        all_pids+=("$pid")
        local -a children
        local pgrep_output=""
        # `set -e` treats a failed command substitution inside an assignment
        # as the assignment's own failure, and pgrep exits 1 whenever a pid
        # simply has no children — the normal, expected case at the bottom
        # of the tree — so that has to be caught explicitly rather than left
        # to abort the whole watchdog.
        pgrep_output="$(pgrep -P "$pid" 2>/dev/null)" || true
        children=("${(f)pgrep_output}")
        local child
        for child in "${children[@]}"; do
            [[ -n "$child" ]] && to_visit+=("$child")
        done
    done
    local p
    for p in "${all_pids[@]}"; do
        [[ -n "$p" ]] || continue
        kill -"$sig" "$p" 2>/dev/null || true
    done
}

# run_with_timeout <timeout_seconds> <logfile> cmd...
# Runs cmd... (cwd = ROOT_DIR) as the sole child of a dedicated wrapper
# subshell, mirroring its combined output to both the console and logfile.
# Sets the global TIMEOUT_HIT (0/1) and RUN_WITH_TIMEOUT_PID (the wrapper's
# PID, valid only while the command is running — callers needing to react to
# an external interrupt read it before this function returns). Returns the
# command's own exit code, or 124 on a timeout.
TIMEOUT_HIT=0
RUN_WITH_TIMEOUT_PID=0
run_with_timeout() {
    local timeout_seconds="$1" logfile="$2"
    shift 2
    TIMEOUT_HIT=0

    : > "$logfile"
    ( cd "$ROOT_DIR" && "$@" ) >>"$logfile" 2>&1 &
    local cmd_pid=$!
    RUN_WITH_TIMEOUT_PID=$cmd_pid

    # Mirrors the log to the console live. Not part of the watched subtree —
    # it reads the file, never touches the command — so it is always safe to
    # kill on our own once the command finishes or is timed out.
    tail -f -n +1 -- "$logfile" &
    local tail_pid=$!

    local elapsed=0 grace=5
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if (( elapsed >= timeout_seconds )); then
            TIMEOUT_HIT=1
            kill_descendants_of "$cmd_pid" TERM
            local waited=0
            while (( waited < grace )) && kill -0 "$cmd_pid" 2>/dev/null; do
                sleep 1
                waited=$((waited + 1))
            done
            kill_descendants_of "$cmd_pid" KILL
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # `wait` returns the child's own exit status, which `set -e` would treat
    # as this line failing (and abort the script) whenever the command it
    # waited on was non-zero — exactly the case being reported here, so it
    # has to be captured through `||`, not read from a bare `wait; $?`.
    local exit_code=0
    wait "$cmd_pid" 2>/dev/null || exit_code=$?
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    RUN_WITH_TIMEOUT_PID=0

    if (( TIMEOUT_HIT )); then
        return 124
    fi
    return $exit_code
}

if [[ -n "${LUMAHARBOR_RUNNER_SELFTEST:-}" ]]; then
    run_selftest
    exit $?
fi

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

PREFLIGHT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --preflight-only)
            PREFLIGHT_ONLY=1
            ;;
        *)
            print -u2 -r -- "error: unknown argument: ${arg}"
            print -u2 -r -- "usage: $0 [--preflight-only]"
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Per-run scratch directory. ROOT_DIR itself was already resolved above.
# ---------------------------------------------------------------------------

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${ROOT_DIR}/.build/mvp-acceptance/${TIMESTAMP}"
mkdir -p -- "$RUN_DIR"

PREFLIGHT_LOG="${RUN_DIR}/preflight.log"
BUILD_LOG="${RUN_DIR}/strict-build.log"
TEST_LOG="${RUN_DIR}/swift-test.log"
RAWFIXTURE_LOG="${RUN_DIR}/raw-fixture-test.log"
SUMMARY_FILE="${RUN_DIR}/summary.md"

# Per-step watchdog budget (Phase 3). Validated and possibly overridden by
# run_preflight below; this default is what a run gets when the environment
# variable is unset.
STEP_TIMEOUT_SECONDS_DEFAULT=900
STEP_TIMEOUT_SECONDS=$STEP_TIMEOUT_SECONDS_DEFAULT

: > "$PREFLIGHT_LOG"

# ---------------------------------------------------------------------------
# Preflight bookkeeping. No eval anywhere in this script; every path is
# quoted so directories with spaces are handled safely.
# ---------------------------------------------------------------------------

preflight_ok=1
PREFLIGHT_LINES=()

record() {
    # record "label" "STATE" ["detail, never a private path"]
    local label="$1" state="$2" detail="${3:-}"
    local line="${label}: ${state}"
    if [[ -n "$detail" ]]; then
        line="${line} (${detail})"
    fi
    PREFLIGHT_LINES+=("$line")
    print -r -- "$line" | tee -a "$PREFLIGHT_LOG" >/dev/null
    print -r -- "$line"
}

fail_check() {
    record "$1" "FAIL" "${2:-}"
    preflight_ok=0
}

pass_check() {
    record "$1" "PASS" "${2:-}"
}

# Resolves the filesystem type (e.g. "apfs", "exfat") of an arbitrary
# directory without ever needing to parse a path that might contain spaces:
# `df`'s device-node field and `mount`'s trailing "(fstype, ...)" field are
# both delimiter-safe, so the directory's own text never has to be split.
filesystem_type_for_dir() {
    local dir="$1"
    local df_line device mount_line paren fstype
    df_line="$(df -P -- "$dir" 2>/dev/null | tail -n 1)" || return 1
    device="${df_line%% *}"
    [[ -n "$device" ]] || return 1
    mount_line="$(mount 2>/dev/null | grep -F -- "${device} on ")" || return 1
    mount_line="${mount_line%%$'\n'*}"
    paren="${mount_line##*\(}"
    fstype="${paren%%,*}"
    fstype="${fstype%)}"
    fstype="${fstype:l}"
    [[ -n "$fstype" ]] || return 1
    print -r -- "$fstype"
}

check_storage_dir() {
    # check_storage_dir "ENV_VAR_NAME" "expected-lowercase-fstype"
    local var_name="$1" expected_fs="$2"
    local dir="${(P)var_name:-}"
    [[ -n "$dir" ]] || return 0 # already flagged missing by the presence check

    if [[ ! -d "$dir" ]]; then
        fail_check "$var_name" "directory does not exist"
        return
    fi

    local fstype
    if ! fstype="$(filesystem_type_for_dir "$dir")"; then
        fail_check "$var_name" "could not identify filesystem"
        return
    fi

    if [[ "$fstype" == "$expected_fs" ]]; then
        pass_check "$var_name" "directory ok, filesystem=${fstype}"
    else
        fail_check "$var_name" "filesystem is ${fstype}, expected ${expected_fs}"
    fi
}

# ---------------------------------------------------------------------------
# Preflight: architecture, toolchain, then the three private test directories.
# ---------------------------------------------------------------------------

run_preflight() {
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "arm64" ]]; then
        pass_check "uname -m" "$arch"
    else
        fail_check "uname -m" "expected arm64, got ${arch}"
    fi

    if [[ -d "/Applications/Xcode.app" ]]; then
        pass_check "/Applications/Xcode.app" "present"
    else
        fail_check "/Applications/Xcode.app" "missing"
    fi

    local xcode_select_path
    if xcode_select_path="$(xcode-select -p 2>/dev/null)"; then
        if [[ "$xcode_select_path" == /Applications/Xcode.app/* ]]; then
            pass_check "xcode-select -p" "points at Xcode"
        else
            fail_check "xcode-select -p" "not pointed at /Applications/Xcode.app; run xcode-select -s"
        fi
    else
        fail_check "xcode-select -p" "command failed"
    fi

    if ! command -v xcodebuild >/dev/null 2>&1; then
        fail_check "xcodebuild" "not found on PATH"
    elif xcodebuild -version >>"$PREFLIGHT_LOG" 2>&1; then
        pass_check "xcodebuild -version" "ok"
    else
        fail_check "xcodebuild -version" "command failed"
    fi

    if ! command -v swift >/dev/null 2>&1; then
        fail_check "swift" "not found on PATH"
    elif swift --version >>"$PREFLIGHT_LOG" 2>&1; then
        pass_check "swift --version" "ok"
    else
        fail_check "swift --version" "command failed"
    fi

    if [[ -z "${LUMAHARBOR_STEP_TIMEOUT_SECONDS:-}" ]]; then
        STEP_TIMEOUT_SECONDS=$STEP_TIMEOUT_SECONDS_DEFAULT
        pass_check "LUMAHARBOR_STEP_TIMEOUT_SECONDS" "not set, defaulting to ${STEP_TIMEOUT_SECONDS_DEFAULT}s"
    elif [[ "${LUMAHARBOR_STEP_TIMEOUT_SECONDS}" == <-> ]] && (( LUMAHARBOR_STEP_TIMEOUT_SECONDS > 0 )); then
        STEP_TIMEOUT_SECONDS=$LUMAHARBOR_STEP_TIMEOUT_SECONDS
        pass_check "LUMAHARBOR_STEP_TIMEOUT_SECONDS" "${STEP_TIMEOUT_SECONDS}s"
    else
        fail_check "LUMAHARBOR_STEP_TIMEOUT_SECONDS" \
            "must be a positive integer, got '${LUMAHARBOR_STEP_TIMEOUT_SECONDS}'"
        STEP_TIMEOUT_SECONDS=$STEP_TIMEOUT_SECONDS_DEFAULT
    fi

    if [[ -z "${LUMAHARBOR_RAW_FIXTURE_DIR:-}" ]]; then
        fail_check "LUMAHARBOR_RAW_FIXTURE_DIR" "not set"
    elif [[ ! -d "$LUMAHARBOR_RAW_FIXTURE_DIR" ]]; then
        fail_check "LUMAHARBOR_RAW_FIXTURE_DIR" "directory does not exist"
    else
        local -a arw_files
        arw_files=("${LUMAHARBOR_RAW_FIXTURE_DIR}"/*.[Aa][Rr][Ww](N.))
        if (( ${#arw_files[@]} > 0 )); then
            local sample
            sample="${arw_files[1]:t}"
            pass_check "LUMAHARBOR_RAW_FIXTURE_DIR" \
                "directory ok, ${#arw_files[@]} .ARW file(s), e.g. ${sample}"
        else
            fail_check "LUMAHARBOR_RAW_FIXTURE_DIR" "directory exists but has no .ARW files"
        fi
    fi

    if [[ -z "${LUMAHARBOR_APFS_TEST_DIR:-}" ]]; then
        fail_check "LUMAHARBOR_APFS_TEST_DIR" "not set"
    else
        check_storage_dir "LUMAHARBOR_APFS_TEST_DIR" "apfs"
    fi

    if [[ -z "${LUMAHARBOR_EXFAT_TEST_DIR:-}" ]]; then
        fail_check "LUMAHARBOR_EXFAT_TEST_DIR" "not set"
    else
        check_storage_dir "LUMAHARBOR_EXFAT_TEST_DIR" "exfat"
    fi
}

print -r -- "==> Preflight"
run_preflight

# ---------------------------------------------------------------------------
# Steps. Only reached when preflight passed and --preflight-only wasn't
# given. A step is only run if every step before it passed; anything after
# the first failure is recorded as SKIPPED, never as a pass.
# ---------------------------------------------------------------------------

STEP_BUILD="SKIPPED (preflight failed)"
STEP_TEST="SKIPPED (preflight failed)"
STEP_RAWFIXTURE="SKIPPED (preflight failed)"
overall_ok=$preflight_ok

# Tracks whichever step is actually running right now, so a signal that
# arrives mid-step can mark it accurately and clean up its process tree —
# see the trap handler below, which reads RUN_WITH_TIMEOUT_PID (kept live by
# run_with_timeout itself) for the actual PID to clean up. Empty whenever no
# step is in flight.
CURRENT_STEP_LABEL=""

LAST_STEP_TIMED_OUT=0
run_logged_step() {
    # run_logged_step "step-label" "Step name" "$logfile" cmd...
    # Only runs the command (under the timeout watchdog) and mirrors its
    # output into the log. It never prints a final PASS/FAIL itself: for the
    # test steps, the command's own exit code is not the full story (see
    # evaluate_xctest_log — `swift test` exits 0 even when XCTest skipped
    # something), so printing PASS here could put a wrong PASS on the console
    # before the caller has actually checked the summary. Each call site
    # below prints exactly one final state line per step, once it knows the
    # real answer. Sets LAST_STEP_TIMED_OUT so the caller can decide whether
    # a dependent step (RawFixtureTests after the full test suite) must be
    # skipped rather than run against a wedged process.
    local label="$1" name="$2" logfile="$3"
    shift 3
    print -r -- "==> ${name}"
    CURRENT_STEP_LABEL="$label"

    # Called directly, not backgrounded: zsh backgrounding forks a subshell,
    # and RUN_WITH_TIMEOUT_PID/TIMEOUT_HIT are only meaningful as globals the
    # signal trap below can read if run_with_timeout executes in this same
    # process. The command it launches internally still runs as a real
    # background child, which is what actually lets the timeout loop and a
    # signal both observe/act on it concurrently.
    local rc=0
    run_with_timeout "$STEP_TIMEOUT_SECONDS" "$logfile" "$@" || rc=$?
    CURRENT_STEP_LABEL=""

    if (( TIMEOUT_HIT )); then
        LAST_STEP_TIMED_OUT=1
        print -r -- "${name}: command timed out after ${STEP_TIMEOUT_SECONDS}s"
        return 1
    fi
    LAST_STEP_TIMED_OUT=0
    if (( rc == 0 )); then
        print -r -- "${name}: command completed"
        return 0
    else
        print -r -- "${name}: command failed"
        return 1
    fi
}

announce_step_result() {
    # announce_step_result "Step name" "STATE" — the single place a step's
    # final PASS/FAIL/FAIL(reason) line is printed, so console and summary
    # can never show a step in two different states.
    print -r -- "$1: $2"
}

# ---------------------------------------------------------------------------
# Summary + signal handling. Defined and trapped *before* any step runs (not
# after), because the whole reason Phase 3 exists is to guarantee a report
# when a step is interrupted — a step is exactly when INT/TERM/HUP can land,
# so registering these traps only after the step block finishes would leave
# every step running with no handler in place at all. Refactored into an
# idempotent function so both the normal exit path and the signal traps below
# can call it — whichever happens first wins, and later calls are no-ops.
# Written atomically (temp file + rename) so a reader never observes a
# partially written summary.md.
# ---------------------------------------------------------------------------

SUMMARY_WRITTEN=0
write_summary() {
    (( SUMMARY_WRITTEN )) && return 0
    SUMMARY_WRITTEN=1

    local tmp_summary="${SUMMARY_FILE}.tmp.$$"
    {
        print -r -- "# MVP acceptance run ${TIMESTAMP}"
        print -r -- ""
        print -r -- "## Preflight"
        print -r -- ""
        for line in "${PREFLIGHT_LINES[@]}"; do
            print -r -- "- ${line}"
        done
        print -r -- ""
        if (( PREFLIGHT_ONLY )); then
            print -r -- "Preflight-only run: no build or test steps executed."
            print -r -- ""
            if (( preflight_ok )); then
                print -r -- "Preflight result: PASS"
            else
                print -r -- "Preflight result: FAIL"
            fi
        else
            print -r -- "## Steps"
            print -r -- ""
            print -r -- "- strict-concurrency build: ${STEP_BUILD}"
            print -r -- "- full swift test: ${STEP_TEST}"
            print -r -- "- RawFixtureTests: ${STEP_RAWFIXTURE}"
            print -r -- ""
            if (( overall_ok )); then
                print -r -- "Overall result: PASS"
            else
                print -r -- "Overall result: FAIL"
            fi
        fi
    } > "$tmp_summary"
    mv -f -- "$tmp_summary" "$SUMMARY_FILE"
}

# handle_terminating_signal <SIGNAL>
# INT/TERM/HUP must still produce a usable summary.md (acceptance criterion
# 10): mark whichever step was in flight as interrupted, tear down exactly
# that step's own process tree (never a broad process-name kill), then write
# the summary before exiting.
handle_terminating_signal() {
    local sig="$1"
    if [[ -n "$CURRENT_STEP_LABEL" ]]; then
        local reason="FAIL (interrupted by ${sig})"
        case "$CURRENT_STEP_LABEL" in
            build) STEP_BUILD="$reason" ;;
            test) STEP_TEST="$reason"; STEP_RAWFIXTURE="SKIPPED (full swift test failed)" ;;
            rawfixture) STEP_RAWFIXTURE="$reason" ;;
        esac
        overall_ok=0
        if (( RUN_WITH_TIMEOUT_PID != 0 )); then
            kill_descendants_of "$RUN_WITH_TIMEOUT_PID" TERM
            sleep 1
            kill_descendants_of "$RUN_WITH_TIMEOUT_PID" KILL
        fi
    fi
    write_summary
    print -r -- ""
    print -r -- "Full logs and summary: ${RUN_DIR}"
    exit 130
}

trap 'handle_terminating_signal INT' INT
trap 'handle_terminating_signal TERM' TERM
trap 'handle_terminating_signal HUP' HUP

if (( ! PREFLIGHT_ONLY )); then
    if (( preflight_ok )); then
        overall_ok=1

        if run_logged_step build "strict-concurrency build" "$BUILD_LOG" \
            swift build -Xswiftc -strict-concurrency=complete; then
            STEP_BUILD="PASS"
        elif (( LAST_STEP_TIMED_OUT )); then
            STEP_BUILD="FAIL (timed out after ${STEP_TIMEOUT_SECONDS}s; see ${BUILD_LOG:t})"
            overall_ok=0
        else
            STEP_BUILD="FAIL"
            overall_ok=0
        fi
        announce_step_result "strict-concurrency build" "$STEP_BUILD"

        if [[ "$STEP_BUILD" == "PASS" ]]; then
            local full_test_timed_out=0
            if run_logged_step test "full swift test" "$TEST_LOG" \
                swift test -Xswiftc -strict-concurrency=complete; then
                if step_reason="$(evaluate_xctest_log "$TEST_LOG")"; then
                    STEP_TEST="PASS"
                else
                    STEP_TEST="FAIL (${step_reason})"
                    overall_ok=0
                fi
            elif (( LAST_STEP_TIMED_OUT )); then
                full_test_timed_out=1
                STEP_TEST="FAIL (timed out after ${STEP_TIMEOUT_SECONDS}s; see ${TEST_LOG:t})"
                overall_ok=0
            else
                STEP_TEST="FAIL (command exited non-zero; see ${TEST_LOG:t})"
                overall_ok=0
            fi
            announce_step_result "full swift test" "$STEP_TEST"

            if (( full_test_timed_out )); then
                # A timed-out full test leaves the process tree freshly torn
                # down (or wedged mid-teardown); running RawFixtureTests on
                # top of that would race a half-terminated `swift test`
                # rather than proving anything about the fixtures.
                STEP_RAWFIXTURE="SKIPPED (full swift test failed)"
                overall_ok=0
                announce_step_result "RawFixtureTests" "$STEP_RAWFIXTURE"
            elif run_logged_step rawfixture "RawFixtureTests" "$RAWFIXTURE_LOG" \
                swift test --filter RawFixtureTests; then
                if step_reason="$(evaluate_xctest_log "$RAWFIXTURE_LOG" 8)"; then
                    STEP_RAWFIXTURE="PASS"
                else
                    STEP_RAWFIXTURE="FAIL (${step_reason})"
                    overall_ok=0
                fi
                announce_step_result "RawFixtureTests" "$STEP_RAWFIXTURE"
            elif (( LAST_STEP_TIMED_OUT )); then
                STEP_RAWFIXTURE="FAIL (timed out after ${STEP_TIMEOUT_SECONDS}s; see ${RAWFIXTURE_LOG:t})"
                overall_ok=0
                announce_step_result "RawFixtureTests" "$STEP_RAWFIXTURE"
            else
                STEP_RAWFIXTURE="FAIL (command exited non-zero; see ${RAWFIXTURE_LOG:t})"
                overall_ok=0
                announce_step_result "RawFixtureTests" "$STEP_RAWFIXTURE"
            fi
        else
            STEP_TEST="SKIPPED (strict-concurrency build failed)"
            STEP_RAWFIXTURE="SKIPPED (strict-concurrency build failed)"
            announce_step_result "full swift test" "$STEP_TEST"
            announce_step_result "RawFixtureTests" "$STEP_RAWFIXTURE"
        fi
    fi
fi

write_summary

print -r -- ""
print -r -- "Full logs and summary: ${RUN_DIR}"

if (( PREFLIGHT_ONLY )); then
    (( preflight_ok )) || exit 1
    exit 0
fi

(( overall_ok )) || exit 1
exit 0
