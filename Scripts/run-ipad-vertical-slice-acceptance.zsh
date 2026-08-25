#!/usr/bin/env zsh
#
# iPad RAW editing vertical slice acceptance runner:
#   docs/superpowers/plans/2026-08-24-ipad-raw-editing-vertical-slice.md (Task 8)
#
# Runs, in strict fail-fast order:
#   1. swift build -Xswiftc -strict-concurrency=complete
#   2. swift test
#   3. (cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad
#        -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)
#   4. Scripts/run-mvp-acceptance.zsh --preflight-only
#   5. Scripts/run-mvp-acceptance.zsh
#
# Any step failing (non-zero exit, timeout, or being interrupted by a signal)
# stops the run: every later step is recorded SKIPPED with the concrete
# reason, never silently, and never as a PASS. Output lands under
#   .build/ipad-vertical-slice/<UTC timestamp>/
# as summary.md plus one log per step. Every artifact that is kept in that
# directory has private absolute paths (repo checkout, $HOME, fixture
# directories, /Users, /Volumes, /private/var, /private/tmp) rewritten to a
# fixed <TOKEN> before the run is considered finished; a grep safety net over
# every kept artifact enforces this and flips the run to FAIL if anything
# slipped through.
#
# Usage:
#   Scripts/run-ipad-vertical-slice-acceptance.zsh
#
# Required environment variables for step 5 (Scripts/run-mvp-acceptance.zsh)
# to do anything beyond preflight — this script itself never reads their
# values, only forwards the already-exported environment:
#   LUMAHARBOR_RAW_FIXTURE_DIR, LUMAHARBOR_APFS_TEST_DIR,
#   LUMAHARBOR_EXFAT_TEST_DIR
#
# Internal self-test (not a supported CLI flag):
#   LUMAHARBOR_IPAD_RUNNER_SELFTEST=1 Scripts/run-ipad-vertical-slice-acceptance.zsh
# Exercises fail-fast ordering, real INT/TERM/HUP interruption of each of the
# five steps, subprocess cleanup and privacy redaction end-to-end. Substitutes
# cheap, controllable commands for the five real steps via the
# LUMAHARBOR_IPAD_SELFTEST_<STEP>_CMD hooks read by run_step below — these
# hooks are read only when set, are never a default a real run could stumble
# into, and are not reachable by an unauthenticated caller: they only take
# effect when this exact env var is exported by the invoking shell.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repo root from this script's own location, not $PWD.
# ---------------------------------------------------------------------------

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

# ---------------------------------------------------------------------------
# Step catalog. Associative arrays keyed by a short internal step id, in the
# fixed order STEP_ORDER. STEP_BLOCK_REASON has no entry for the last step
# (mvpacceptance): nothing runs after it, so nothing ever needs to blame it.
# ---------------------------------------------------------------------------

STEP_ORDER=(strictbuild swifttest simbuild mvppreflight mvpacceptance)

typeset -A STEP_LABEL
STEP_LABEL=(
    strictbuild   "strict-concurrency build"
    swifttest     "swift test"
    simbuild      "iOS Simulator build"
    mvppreflight  "MVP preflight"
    mvpacceptance "MVP acceptance"
)

typeset -A STEP_LOGFILE
STEP_LOGFILE=(
    strictbuild   "strict-build.log"
    swifttest     "swift-test.log"
    simbuild      "ios-simulator-build.log"
    mvppreflight  "mvp-preflight.log"
    mvpacceptance "mvp-acceptance.log"
)

typeset -A STEP_BLOCK_REASON
STEP_BLOCK_REASON=(
    strictbuild  "strict-concurrency build failed"
    swifttest    "swift test failed"
    simbuild     "iOS Simulator build failed"
    mvppreflight "MVP preflight failed"
)

typeset -A STEP_STATE
typeset -A STEP_EXITCODE

# ---------------------------------------------------------------------------
# Privacy redaction. Applied to every log and to the summary before the run
# is considered finished. Order matters: the most specific literal paths
# (repo root, the three fixture directories, $HOME) are rewritten first so
# their useful relative suffix survives (e.g. an error at
# "<REPO_ROOT>/Sources/Foo.swift:12:5" instead of being fully swallowed);
# the four generic prefix patterns are a catch-all safety net for everything
# else (DerivedData paths, mounted-volume paths, /private/var and
# /private/tmp scratch paths) that isn't informative to keep anyway.
# ---------------------------------------------------------------------------

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
    # redact_literal <file> <literal> <token>
    local file="$1" literal="$2" token="$3"
    [[ -n "$literal" && -f "$file" ]] || return 0
    local escaped
    escaped="$(sed_escape_literal "$literal")"
    sed -i '' -e "s|${escaped}|${token}|g" "$file"
}

redact_pattern() {
    # redact_pattern <file> <extended-regex> <token>
    local file="$1" pattern="$2" token="$3"
    [[ -f "$file" ]] || return 0
    sed -i '' -E "s#${pattern}#${token}#g" "$file"
}

redact_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    redact_literal "$file" "$ROOT_DIR" "<REPO_ROOT>"
    redact_literal "$file" "${LUMAHARBOR_RAW_FIXTURE_DIR:-}" "<RAW_FIXTURE_DIR>"
    redact_literal "$file" "${LUMAHARBOR_APFS_TEST_DIR:-}" "<APFS_TEST_DIR>"
    redact_literal "$file" "${LUMAHARBOR_EXFAT_TEST_DIR:-}" "<EXFAT_TEST_DIR>"
    redact_literal "$file" "${HOME:-}" "<HOME>"
    redact_pattern "$file" '/Users/[A-Za-z0-9_./+=@%-]+' "<HOME_PATH>"
    redact_pattern "$file" '/Volumes/[A-Za-z0-9_./+=@%-]+' "<VOLUME_PATH>"
    redact_pattern "$file" '/private/var/[A-Za-z0-9_./+=@%-]+' "<PRIVATE_VAR_PATH>"
    redact_pattern "$file" '/private/tmp/[A-Za-z0-9_./+=@%-]+' "<PRIVATE_TMP_PATH>"
}

# has_private_path <file> — the grep safety net. True (0) means a forbidden
# absolute-path prefix is still present after redact_file ran.
has_private_path() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -Eq '/Users/|/Volumes/|/private/var/|/private/tmp/' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# XCTest summary parsing (same contract as Scripts/run-mvp-acceptance.zsh).
# `swift test` exits 0 even when XCTest reports skipped tests, so a bare
# exit-code check would mislabel a run with silent skips as PASS.
# ---------------------------------------------------------------------------

# parse_xctest_summary <logfile>
# Prints "<executed> <skipped> <failures>" from the *last* XCTest
# "Executed N tests, with ... failures ..." line in the log. Returns 1 if no
# such line is found at all, which must never be treated as a passing run.
parse_xctest_summary() {
    local logfile="$1"
    local line found=0
    local executed=0 skipped=0 failures=0
    while IFS= read -r line; do
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

# evaluate_xctest_log <logfile>
# On stdout: nothing when the run is clean; a one-line human-readable reason
# when it is not. Returns 0 only for a parseable summary with zero skipped
# tests and zero failures.
evaluate_xctest_log() {
    local logfile="$1"
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
    if (( failures != 0 )); then
        print -r -- "${failures} failure(s) reported in summary"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Timeout watchdog + descendant cleanup. Stock-macOS-only (no GNU coreutils
# `timeout`). A command runs inside its own subshell wrapper so the wrapper's
# PID is a stable root for walking exactly its own descendants via
# `pgrep -P` — never a broad process-name match, so this can never touch an
# unrelated swift/xcodebuild process elsewhere on the machine.
# ---------------------------------------------------------------------------

# collect_descendant_pids <root_pid>
# Prints, one per line, root_pid followed by every currently-live descendant
# discovered via `pgrep -P`, ordered leaf-first (the deepest descendants
# first, root_pid last). This is a one-shot snapshot: callers MUST take it
# BEFORE sending any signal to root_pid, and reuse that same snapshot for
# every signal in the escalation (TERM, then KILL) — a *second* pgrep
# traversal rooted at root_pid, taken after root_pid has already been
# signalled, can find zero descendants even while they are still alive: once
# root_pid exits, its children are reparented away from it (typically to
# launchd), so `pgrep -P root_pid` no longer sees them at all. Re-deriving
# the descendant list after the first signal is exactly how a live
# descendant survives cleanup undetected.
collect_descendant_pids() {
    local root_pid="$1"
    local -a to_visit=("$root_pid") ordered_pids=()
    while (( ${#to_visit[@]} > 0 )); do
        local pid="${to_visit[1]}"
        to_visit=("${to_visit[@]:1}")
        [[ -n "$pid" ]] || continue
        ordered_pids+=("$pid")
        local -a children
        local pgrep_output=""
        pgrep_output="$(pgrep -P "$pid" 2>/dev/null)" || true
        children=("${(f)pgrep_output}")
        local child
        for child in "${children[@]}"; do
            [[ -n "$child" ]] && to_visit+=("$child")
        done
    done
    # ordered_pids is in BFS order (root, then children, then
    # grandchildren, ...); print it reversed so the caller signals
    # deepest-first, root_pid last — a parent's early exit can then never
    # race a not-yet-signalled child, since every PID was already resolved
    # up front and is signalled directly by PID, never via the parent.
    local idx
    for (( idx = ${#ordered_pids[@]}; idx >= 1; idx-- )); do
        print -r -- "${ordered_pids[$idx]}"
    done
}

# signal_pid_list <signal> <pid>...
# Sends exactly one signal to exactly the given PIDs — never a broad
# process-name or process-group kill — so this can only ever touch PIDs a
# caller already resolved itself.
signal_pid_list() {
    local sig="$1"
    shift
    local p
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        kill -"$sig" "$p" 2>/dev/null || true
    done
}

# all_pids_gone <pid>...
# True (0) only once every given PID has exited. Used to bound the grace
# wait between TERM and KILL, and to confirm cleanup actually completed
# rather than merely having been requested.
all_pids_gone() {
    local p
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        kill -0 "$p" 2>/dev/null && return 1
    done
    return 0
}

# run_with_timeout <timeout_seconds> <logfile> <cwd> cmd...
# Runs cmd... with the given working directory as the sole child of a
# dedicated wrapper subshell. Output is captured only to logfile — there is
# deliberately no live console tail: an earlier version backgrounded
# `tail -f` to mirror progress live, but that gave every exit path (normal
# completion, timeout, and an external INT/TERM/HUP delivered to this
# script) one more backgrounded PID it had to remember to clean up, and a
# signal arriving at exactly the wrong instant could leave that `tail -f`
# running after the acceptance run itself had already exited. Each step's
# own PASS/FAIL line is still printed to the console by its caller once the
# step finishes; the full transcript is always in logfile regardless. Sets
# the global TIMEOUT_HIT (0/1) and RUN_WITH_TIMEOUT_PID (the wrapper's PID,
# valid only while the command is running). Returns the command's own exit
# code, or 124 on a timeout.
TIMEOUT_HIT=0
RUN_WITH_TIMEOUT_PID=0
run_with_timeout() {
    local timeout_seconds="$1" logfile="$2" cwd="$3"
    shift 3
    TIMEOUT_HIT=0

    : > "$logfile"
    ( cd "$cwd" && "$@" ) >>"$logfile" 2>&1 &
    local cmd_pid=$!
    RUN_WITH_TIMEOUT_PID=$cmd_pid

    local elapsed=0 grace=5
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if (( elapsed >= timeout_seconds )); then
            TIMEOUT_HIT=1
            local -a victims
            victims=("${(f)$(collect_descendant_pids "$cmd_pid")}")
            signal_pid_list TERM "${victims[@]}"
            local waited=0
            while (( waited < grace )) && ! all_pids_gone "${victims[@]}"; do
                sleep 1
                waited=$((waited + 1))
            done
            signal_pid_list KILL "${victims[@]}"
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    local exit_code=0
    wait "$cmd_pid" 2>/dev/null || exit_code=$?
    RUN_WITH_TIMEOUT_PID=0

    if (( TIMEOUT_HIT )); then
        return 124
    fi
    return $exit_code
}

# ---------------------------------------------------------------------------
# Step execution.
# ---------------------------------------------------------------------------

STEP_TIMEOUT_SECONDS_DEFAULT=3600
STEP_TIMEOUT_SECONDS=$STEP_TIMEOUT_SECONDS_DEFAULT

CURRENT_STEP_KEY=""

# step_command_for <key> — sets globals STEP_CWD and STEP_CMD (an array) for
# the real command a step runs. Overridden per-step, only when the
# corresponding LUMAHARBOR_IPAD_SELFTEST_<KEY>_CMD env var is set, by the
# self-test below.
STEP_CWD=""
STEP_CMD=()
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
        mvppreflight)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=("${ROOT_DIR}/Scripts/run-mvp-acceptance.zsh" --preflight-only)
            ;;
        mvpacceptance)
            STEP_CWD="$ROOT_DIR"
            STEP_CMD=("${ROOT_DIR}/Scripts/run-mvp-acceptance.zsh")
            ;;
    esac

    local override_var="LUMAHARBOR_IPAD_SELFTEST_${key:u}_CMD"
    local override_value="${(P)override_var:-}"
    if [[ -n "$override_value" ]]; then
        # Self-test hook values are always a bare command (a plain word, or a
        # single word plus a numeric argument, or an executable path) — never
        # quoted — precisely so this shell-word split never has to reason
        # about quoting.
        STEP_CMD=(${(z)override_value})
    fi
}

# run_step <key> — runs one step under the timeout watchdog, sets
# STEP_STATE[key] and STEP_EXITCODE[key], and returns 0/1 for the caller's
# fail-fast loop. Never prints a step's own final PASS itself for swifttest
# before checking the parsed XCTest summary, since `swift test` exiting 0
# is not the full story.
run_step() {
    local key="$1"
    local label="${STEP_LABEL[$key]}"
    local logfile="${RUN_DIR}/${STEP_LOGFILE[$key]}"

    step_command_for "$key"

    print -r -- "==> ${label}"
    CURRENT_STEP_KEY="$key"
    local rc=0
    run_with_timeout "$STEP_TIMEOUT_SECONDS" "$logfile" "$STEP_CWD" "${STEP_CMD[@]}" || rc=$?
    CURRENT_STEP_KEY=""
    STEP_EXITCODE[$key]="$rc"

    if (( TIMEOUT_HIT )); then
        STEP_STATE[$key]="FAIL (timed out after ${STEP_TIMEOUT_SECONDS}s; see ${STEP_LOGFILE[$key]})"
        print -r -- "${label}: FAIL (timed out)"
        return 1
    fi

    if [[ "$key" == "swifttest" ]]; then
        if (( rc == 0 )); then
            local reason
            if reason="$(evaluate_xctest_log "$logfile")"; then
                STEP_STATE[$key]="PASS"
                print -r -- "${label}: PASS"
                return 0
            else
                STEP_STATE[$key]="FAIL (${reason})"
                print -r -- "${label}: FAIL (${reason})"
                return 1
            fi
        else
            STEP_STATE[$key]="FAIL (command exited ${rc}; see ${STEP_LOGFILE[$key]})"
            print -r -- "${label}: FAIL (command exited ${rc})"
            return 1
        fi
    fi

    if (( rc == 0 )); then
        STEP_STATE[$key]="PASS"
        print -r -- "${label}: PASS"
        return 0
    else
        STEP_STATE[$key]="FAIL (command exited ${rc}; see ${STEP_LOGFILE[$key]})"
        print -r -- "${label}: FAIL (command exited ${rc})"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Summary + signal handling. The trap is installed *before* any step runs
# (see the main run section below), and write_summary/finalize_run is
# idempotent (SUMMARY_WRITTEN guard) so both the normal exit path and a
# signal trap can call it safely — whichever happens first wins.
# ---------------------------------------------------------------------------

SUMMARY_WRITTEN=0

# finalize_run — redacts every log that exists, writes summary.md (commit,
# timestamp, Xcode version, architecture, per-step state/exit-code, the
# parsed swift-test executed/skipped/failures counts, a privacy-scan result,
# and the overall result), then runs the grep safety net over every kept
# artifact. A leftover unredacted path flips privacy_ok (and therefore
# overall_ok) to failing even if every step itself passed.
finalize_run() {
    (( SUMMARY_WRITTEN )) && return 0
    SUMMARY_WRITTEN=1

    local key
    for key in "${STEP_ORDER[@]}"; do
        redact_file "${RUN_DIR}/${STEP_LOGFILE[$key]}"
    done

    local commit xcode_version_output xcode_version arch
    commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || print -r -- unknown)"
    # `xcodebuild -version | head -n1` would close its read end as soon as it
    # has one line, which can deliver SIGPIPE to xcodebuild while it is still
    # writing its second line — under `set -o pipefail` that turns into a 141
    # exit for this whole command substitution, which `set -e` then treats as
    # this line failing and aborts the entire runner mid-finalize_run. Capture
    # the full output first (no pipe, so nothing can ever close early on
    # xcodebuild), then take the first line with parameter expansion instead.
    xcode_version_output="$(xcodebuild -version 2>/dev/null)"
    xcode_version="${xcode_version_output%%$'\n'*}"
    [[ -z "$xcode_version" ]] && xcode_version="unknown"
    arch="$(uname -m)"

    local tmp_summary="${SUMMARY_FILE}.tmp.$$"
    {
        print -r -- "# iPad RAW editing vertical slice acceptance run ${TIMESTAMP}"
        print -r -- ""
        print -r -- "- Commit: ${commit}"
        print -r -- "- Timestamp (UTC): ${TIMESTAMP}"
        print -r -- "- Xcode version: ${xcode_version}"
        print -r -- "- Architecture: ${arch}"
        print -r -- ""
        if [[ -n "$RUNNER_PREFLIGHT_REASON" ]]; then
            print -r -- "## Runner preflight"
            print -r -- ""
            print -r -- "Runner preflight: FAIL (${RUNNER_PREFLIGHT_REASON})"
            print -r -- ""
        fi
        print -r -- "## Steps"
        print -r -- ""
        for key in "${STEP_ORDER[@]}"; do
            local extra=""
            if [[ "$key" == "swifttest" ]]; then
                local parsed
                if parsed="$(parse_xctest_summary "${RUN_DIR}/${STEP_LOGFILE[$key]}" 2>/dev/null)"; then
                    local -a test_fields
                    test_fields=(${=parsed})
                    extra=" [executed=${test_fields[1]} skipped=${test_fields[2]} failures=${test_fields[3]}]"
                fi
            fi
            print -r -- "- ${STEP_LABEL[$key]}: ${STEP_STATE[$key]}${extra} [exit ${STEP_EXITCODE[$key]}]"
        done
        print -r -- ""
        print -r -- "## Logs"
        print -r -- ""
        for key in "${STEP_ORDER[@]}"; do
            print -r -- "- ${STEP_LABEL[$key]}: .build/ipad-vertical-slice/${TIMESTAMP}/${STEP_LOGFILE[$key]}"
        done
    } > "$tmp_summary"

    redact_file "$tmp_summary"

    local privacy_ok=1
    local -a leaked_files=()
    for key in "${STEP_ORDER[@]}"; do
        local log_file="${RUN_DIR}/${STEP_LOGFILE[$key]}"
        if has_private_path "$log_file"; then
            privacy_ok=0
            leaked_files+=("${STEP_LOGFILE[$key]}")
        fi
    done
    if has_private_path "$tmp_summary"; then
        privacy_ok=0
        leaked_files+=("summary.md")
    fi

    local diagnostic="${RUN_DIR}/runner-diagnostic.log"
    {
        print -r -- "Runner diagnostic for run ${TIMESTAMP}"
        print -r -- "Privacy scan: $(( privacy_ok )) (1 = clean, 0 = leak found)"
        if (( ! privacy_ok )); then
            print -r -- "Files still matching a private absolute-path pattern after redaction (names only):"
            local lf
            for lf in "${leaked_files[@]}"; do
                print -r -- "  - ${lf}"
            done
        fi
    } > "$diagnostic"

    {
        print -r -- "## Privacy scan"
        print -r -- ""
        if (( privacy_ok )); then
            print -r -- "Privacy scan: PASS (no /Users, /Volumes, /private/var, /private/tmp, repo root, or fixture directory paths found in summary or logs)"
        else
            print -r -- "Privacy scan: FAIL (see runner-diagnostic.log for affected file names)"
        fi
        print -r -- ""
        if (( overall_ok && privacy_ok )); then
            print -r -- "Overall result: PASS"
        else
            print -r -- "Overall result: FAIL"
        fi
    } >> "$tmp_summary"

    mv -f -- "$tmp_summary" "$SUMMARY_FILE"
    overall_ok=$(( overall_ok && privacy_ok ))

    print -r -- ""
    print -r -- "Full logs and summary: .build/ipad-vertical-slice/${TIMESTAMP}"
}

# handle_terminating_signal <SIGNAL>
# INT/TERM/HUP must still produce a usable summary.md: mark whichever step
# was in flight as interrupted, mark every step after it SKIPPED with that
# same step's normal block reason (matching the non-interrupted fail-fast
# path exactly, so a reader never sees two different phrasings for "this
# didn't run because X failed"), tear down exactly that step's own process
# tree, then finalize.
handle_terminating_signal() {
    local sig="$1"
    if [[ -n "$CURRENT_STEP_KEY" ]]; then
        local key="$CURRENT_STEP_KEY"
        STEP_STATE[$key]="FAIL (interrupted by ${sig})"
        overall_ok=0
        local reason="${STEP_BLOCK_REASON[$key]:-}"
        local found=0 k
        for k in "${STEP_ORDER[@]}"; do
            if (( found )); then
                STEP_STATE[$k]="SKIPPED (${reason})"
            fi
            [[ "$k" == "$key" ]] && found=1
        done
        if (( RUN_WITH_TIMEOUT_PID != 0 )); then
            # One snapshot, reused for both signals — see collect_descendant_pids.
            local -a victims
            victims=("${(f)$(collect_descendant_pids "$RUN_WITH_TIMEOUT_PID")}")
            signal_pid_list TERM "${victims[@]}"
            local waited=0
            while (( waited < 5 )) && ! all_pids_gone "${victims[@]}"; do
                sleep 1
                waited=$((waited + 1))
            done
            signal_pid_list KILL "${victims[@]}"
        fi
    fi
    finalize_run

    local exit_code
    case "$sig" in
        HUP) exit_code=129 ;;
        INT) exit_code=130 ;;
        TERM) exit_code=143 ;;
        *) exit_code=130 ;;
    esac
    exit "$exit_code"
}

# ===========================================================================
# Self-test. Not a supported CLI flag — triggered only by
# LUMAHARBOR_IPAD_RUNNER_SELFTEST=1, so an unauthenticated caller can never
# reach the command-injection-shaped hooks below just by controlling
# argv/stdin; they also only do anything once this exact env var is already
# exported by the invoking shell.
# ===========================================================================

typeset -A FASTPASS_CMD
FAIL_WITH_7_HELPER=""
INTERRUPT_ROOT_HELPER=""
INTERRUPT_CHILD_HELPER=""

# run_signal_selftest_case <target-key> <signal-name> <expected-exit-code>
# Launches a fresh subprocess of this very script with every step up to and
# including target-key substituted for a cheap, controllable command (steps
# before the target get an instant-pass stand-in; the target gets
# INTERRUPT_ROOT_HELPER, a dedicated two-process helper — see its own
# comment below for why). Readiness is a deterministic handshake (a ready
# file, written only once both the helper's root process and its real
# grandchild process have confirmed PIDs on disk) rather than any fixed
# sleep guess. A real OS signal is then sent to the runner subprocess
# itself, and both the resulting summary.md and the helper's own two exact
# PIDs (read back from the pidfiles it wrote, never a broad `pgrep -f`
# pattern match) are checked the same way an operator would.
run_signal_selftest_case() {
    local target_key="$1" signal_name="$2" expected_exit="$3"
    local label="signal ${signal_name} during ${target_key}"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local root_pidfile="${case_tmp}/root.pid"
    local child_pidfile="${case_tmp}/child.pid"
    local ready_file="${case_tmp}/ready"

    local -a before_dirs
    before_dirs=("${ROOT_DIR}"/.build/ipad-vertical-slice/*(N))

    (
        unset LUMAHARBOR_IPAD_RUNNER_SELFTEST
        local k
        for k in "${STEP_ORDER[@]}"; do
            if [[ "$k" == "$target_key" ]]; then
                export "LUMAHARBOR_IPAD_SELFTEST_${k:u}_CMD"="${INTERRUPT_ROOT_HELPER} ${root_pidfile} ${child_pidfile} ${ready_file} ${INTERRUPT_CHILD_HELPER}"
                break
            else
                export "LUMAHARBOR_IPAD_SELFTEST_${k:u}_CMD"="${FASTPASS_CMD[$k]}"
            fi
        done
        exec "$SCRIPT_PATH"
    ) >/dev/null 2>&1 &
    local child_pid=$!

    # Deterministic handshake: the ready file only exists once the helper's
    # root process has confirmed its grandchild is alive (see
    # INTERRUPT_ROOT_HELPER's own script body) — never a fixed sleep guess.
    local ready_deadline=$((SECONDS + 20))
    while (( SECONDS < ready_deadline )) && [[ ! -f "$ready_file" ]]; do
        sleep 0.02
    done

    if [[ ! -f "$ready_file" ]]; then
        print -r -- "selftest: ${label} -> the interrupt-target helper never signalled ready"
        kill -KILL "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        rm -rf -- "$case_tmp"
        return 1
    fi

    local root_helper_pid="" grandchild_pid=""
    [[ -s "$root_pidfile" ]] && root_helper_pid="$(<"$root_pidfile")"
    [[ -s "$child_pidfile" ]] && grandchild_pid="$(<"$child_pidfile")"
    if [[ -z "$root_helper_pid" || -z "$grandchild_pid" ]]; then
        print -r -- "selftest: ${label} -> ready file existed but a pidfile was empty"
        kill -KILL "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        rm -rf -- "$case_tmp"
        return 1
    fi

    # The run directory the runner subprocess created — needed to locate
    # summary.md afterward, not for timing (the ready-file wait above
    # already proves the target step is genuinely in flight).
    local new_dir="" d
    for d in "${ROOT_DIR}"/.build/ipad-vertical-slice/*(N); do
        if (( ${before_dirs[(Ie)$d]} == 0 )); then
            new_dir="$d"
            break
        fi
    done

    kill -s "$signal_name" "$child_pid" 2>/dev/null || true
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == expected_exit )); then
        print -r -- "selftest: ${label} -> exit code ${rc} (expected ${expected_exit}): ok"
    else
        print -r -- "selftest: ${label} -> exit code ${rc}, expected ${expected_exit}"
        case_failures=$((case_failures + 1))
    fi

    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: ${label} -> no run directory was found for this case"
        case_failures=$((case_failures + 1))
    else
        local summary="${new_dir}/summary.md"
        if [[ ! -f "$summary" ]]; then
            print -r -- "selftest: ${label} -> no summary.md was written"
            case_failures=$((case_failures + 1))
        else
            if grep -q '^Overall result: FAIL$' "$summary"; then
                print -r -- "selftest: ${label} -> Overall result: FAIL (expected): ok"
            else
                print -r -- "selftest: ${label} -> summary.md did not report an overall FAIL"
                case_failures=$((case_failures + 1))
            fi

            if grep -qF -- "- ${STEP_LABEL[$target_key]}: FAIL (interrupted by ${signal_name})" "$summary"; then
                print -r -- "selftest: ${label} -> interrupted step labelled correctly: ok"
            else
                print -r -- "selftest: ${label} -> interrupted step was not labelled correctly"
                case_failures=$((case_failures + 1))
            fi

            if grep -qF -- 'SKIPPED (not yet run)' "$summary"; then
                print -r -- "selftest: ${label} -> a step still carried the stale default reason"
                case_failures=$((case_failures + 1))
            else
                print -r -- "selftest: ${label} -> no stale default reason leaked: ok"
            fi

            local reason="${STEP_BLOCK_REASON[$target_key]:-}"
            if [[ -n "$reason" ]]; then
                local found=0 k downstream_ok=1
                for k in "${STEP_ORDER[@]}"; do
                    if (( found )); then
                        if ! grep -qF -- "- ${STEP_LABEL[$k]}: SKIPPED (${reason})" "$summary"; then
                            downstream_ok=0
                        fi
                    fi
                    [[ "$k" == "$target_key" ]] && found=1
                done
                if (( downstream_ok )); then
                    print -r -- "selftest: ${label} -> downstream steps correctly blame ${target_key}: ok"
                else
                    print -r -- "selftest: ${label} -> a downstream step did not correctly blame ${target_key}"
                    case_failures=$((case_failures + 1))
                fi
            fi

            if has_private_path "$summary"; then
                print -r -- "selftest: ${label} -> summary.md leaked a private absolute path"
                case_failures=$((case_failures + 1))
            else
                print -r -- "selftest: ${label} -> no private path in summary.md (expected): ok"
            fi
        fi
    fi

    # Precise-PID survivor check against the two exact PIDs the helper
    # itself reported — never a broad `pgrep -f` name/pattern match, which
    # can both miss a renamed process and false-positive on an unrelated one.
    local survivor_deadline=$((SECONDS + 5))
    local root_gone=0 grandchild_gone=0
    while (( SECONDS < survivor_deadline )); do
        kill -0 "$root_helper_pid" 2>/dev/null || root_gone=1
        kill -0 "$grandchild_pid" 2>/dev/null || grandchild_gone=1
        (( root_gone && grandchild_gone )) && break
        sleep 0.1
    done
    if (( root_gone && grandchild_gone )); then
        print -r -- "selftest: ${label} -> helper root and grandchild both exited (expected): ok"
    else
        print -r -- "selftest: ${label} -> a helper process survived the interruption (root_gone=${root_gone} grandchild_gone=${grandchild_gone})"
        case_failures=$((case_failures + 1))
        kill -KILL "$root_helper_pid" 2>/dev/null || true
        kill -KILL "$grandchild_pid" 2>/dev/null || true
    fi

    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_fastfail_selftest_case — case 15: a step fails for an ordinary
# (non-signal) reason; the run must still fail fast, skip every later step
# with the correct reason, and exit 1 (not a signal exit code).
run_fastfail_selftest_case() {
    local case_failures=0
    local -a before_dirs
    before_dirs=("${ROOT_DIR}"/.build/ipad-vertical-slice/*(N))

    (
        unset LUMAHARBOR_IPAD_RUNNER_SELFTEST
        export LUMAHARBOR_IPAD_SELFTEST_STRICTBUILD_CMD="$FAIL_WITH_7_HELPER"
        exec "$SCRIPT_PATH"
    ) >/dev/null 2>&1 &
    local child_pid=$!
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 1 )); then
        print -r -- "selftest: non-signal failure -> exit 1 (expected): ok"
    else
        print -r -- "selftest: non-signal failure -> exit ${rc}, expected 1"
        case_failures=$((case_failures + 1))
    fi

    local new_dir="" d
    for d in "${ROOT_DIR}"/.build/ipad-vertical-slice/*(N); do
        if (( ${before_dirs[(Ie)$d]} == 0 )); then
            new_dir="$d"
            break
        fi
    done
    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: non-signal failure -> no run directory was created"
        return 1
    fi

    local summary="${new_dir}/summary.md"
    if [[ -f "$summary" ]] \
        && grep -q '^Overall result: FAIL$' "$summary" \
        && grep -qF -- "- ${STEP_LABEL[strictbuild]}: FAIL (command exited 7" "$summary" \
        && grep -qF -- "- ${STEP_LABEL[swifttest]}: SKIPPED (${STEP_BLOCK_REASON[strictbuild]})" "$summary" \
        && grep -qF -- "- ${STEP_LABEL[mvpacceptance]}: SKIPPED (${STEP_BLOCK_REASON[strictbuild]})" "$summary"; then
        print -r -- "selftest: non-signal failure -> fail-fast skip chain correct: ok"
    else
        print -r -- "selftest: non-signal failure -> fail-fast skip chain incorrect"
        case_failures=$((case_failures + 1))
    fi

    (( case_failures == 0 ))
}

# run_fakepass_selftest_case — case 16: every step passes via a fast
# stand-in; the run must execute all five in order and report Overall PASS.
run_fakepass_selftest_case() {
    local case_failures=0
    local -a before_dirs
    before_dirs=("${ROOT_DIR}"/.build/ipad-vertical-slice/*(N))

    (
        unset LUMAHARBOR_IPAD_RUNNER_SELFTEST
        local k
        for k in "${STEP_ORDER[@]}"; do
            export "LUMAHARBOR_IPAD_SELFTEST_${k:u}_CMD"="${FASTPASS_CMD[$k]}"
        done
        exec "$SCRIPT_PATH"
    ) >/dev/null 2>&1 &
    local child_pid=$!
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 0 )); then
        print -r -- "selftest: fake successful run -> exit 0 (expected): ok"
    else
        print -r -- "selftest: fake successful run -> exit ${rc}, expected 0"
        case_failures=$((case_failures + 1))
    fi

    local new_dir="" d
    for d in "${ROOT_DIR}"/.build/ipad-vertical-slice/*(N); do
        if (( ${before_dirs[(Ie)$d]} == 0 )); then
            new_dir="$d"
            break
        fi
    done
    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: fake successful run -> no run directory was created"
        return 1
    fi

    local summary="${new_dir}/summary.md"
    if [[ -f "$summary" ]] && grep -q '^Overall result: PASS$' "$summary"; then
        print -r -- "selftest: fake successful run -> Overall result: PASS (expected): ok"
    else
        print -r -- "selftest: fake successful run -> summary.md missing or not PASS"
        case_failures=$((case_failures + 1))
    fi

    local key all_pass=1
    for key in "${STEP_ORDER[@]}"; do
        if [[ -z "$summary" ]] || ! grep -qF -- "- ${STEP_LABEL[$key]}: PASS" "$summary"; then
            all_pass=0
        fi
    done
    if (( all_pass )); then
        print -r -- "selftest: fake successful run -> all five steps show PASS: ok"
    else
        print -r -- "selftest: fake successful run -> not every step shows PASS"
        case_failures=$((case_failures + 1))
    fi

    (( case_failures == 0 ))
}

# run_missinghelper_selftest_case — case 17: a required step command cannot
# even be found (simulating a missing helper). This must surface as FAIL,
# never as a silent skip or an accidental pass.
run_missinghelper_selftest_case() {
    local case_failures=0
    local -a before_dirs
    before_dirs=("${ROOT_DIR}"/.build/ipad-vertical-slice/*(N))

    (
        unset LUMAHARBOR_IPAD_RUNNER_SELFTEST
        export LUMAHARBOR_IPAD_SELFTEST_STRICTBUILD_CMD="${FASTPASS_CMD[strictbuild]}"
        export LUMAHARBOR_IPAD_SELFTEST_SWIFTTEST_CMD="${FASTPASS_CMD[swifttest]}"
        export LUMAHARBOR_IPAD_SELFTEST_SIMBUILD_CMD="${FASTPASS_CMD[simbuild]}"
        export LUMAHARBOR_IPAD_SELFTEST_MVPPREFLIGHT_CMD="/nonexistent/lumaharbor-selftest-missing-helper"
        exec "$SCRIPT_PATH"
    ) >/dev/null 2>&1 &
    local child_pid=$!
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 1 )); then
        print -r -- "selftest: missing helper -> exit 1 (expected): ok"
    else
        print -r -- "selftest: missing helper -> exit ${rc}, expected 1"
        case_failures=$((case_failures + 1))
    fi

    local new_dir="" d
    for d in "${ROOT_DIR}"/.build/ipad-vertical-slice/*(N); do
        if (( ${before_dirs[(Ie)$d]} == 0 )); then
            new_dir="$d"
            break
        fi
    done
    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: missing helper -> no run directory was created"
        return 1
    fi

    local summary="${new_dir}/summary.md"
    if [[ -f "$summary" ]] \
        && grep -qF -- "- ${STEP_LABEL[mvppreflight]}: FAIL" "$summary" \
        && ! grep -qF -- "- ${STEP_LABEL[mvppreflight]}: SKIPPED" "$summary" \
        && ! grep -qF -- "- ${STEP_LABEL[mvppreflight]}: PASS" "$summary" \
        && grep -qF -- "- ${STEP_LABEL[mvpacceptance]}: SKIPPED (${STEP_BLOCK_REASON[mvppreflight]})" "$summary"; then
        print -r -- "selftest: missing helper -> reported as FAIL, not skipped or passed, and blocked the next step: ok"
    else
        print -r -- "selftest: missing helper -> was not correctly reported as FAIL"
        case_failures=$((case_failures + 1))
    fi

    (( case_failures == 0 ))
}

run_selftest() {
    local failures=0
    local tmp
    tmp="$(mktemp -d)"

    # --- XCTest summary parser sanity: quick synthetic-log cases. ---
    print -r -- "Executed 4 tests, with 0 failures (0 unexpected) in 0.01 (0.01) seconds" > "${tmp}/zero-skip.log"
    if evaluate_xctest_log "${tmp}/zero-skip.log" >/dev/null; then
        print -r -- "selftest: parser zero-skip -> PASS (expected): ok"
    else
        print -r -- "selftest: parser zero-skip -> unexpectedly FAILED"
        failures=$((failures + 1))
    fi

    print -r -- "Executed 4 tests, with 1 test skipped, 0 failures (0 unexpected) in 0.01 (0.01) seconds" > "${tmp}/one-skip.log"
    if evaluate_xctest_log "${tmp}/one-skip.log" >/dev/null; then
        print -r -- "selftest: parser one-skip -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: parser one-skip -> FAIL (expected): ok"
    fi

    print -r -- "Executed 4 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.01 (0.01) seconds" > "${tmp}/one-skip-and.log"
    if evaluate_xctest_log "${tmp}/one-skip-and.log" >/dev/null; then
        print -r -- "selftest: parser one-skip (and form) -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: parser one-skip (and form) -> FAIL (expected): ok"
    fi

    print -r -- "Executed 4 tests, with 2 failures (0 unexpected) in 0.01 (0.01) seconds" > "${tmp}/two-fail.log"
    if evaluate_xctest_log "${tmp}/two-fail.log" >/dev/null; then
        print -r -- "selftest: parser two-failures -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: parser two-failures -> FAIL (expected): ok"
    fi

    # --- Redaction correctness: masks private paths, preserves relative
    # source locations, test counts and error text untouched. ---
    local sample="${tmp}/sample.log"
    {
        print -r -- "error at ${ROOT_DIR}/Sources/Foo.swift:12:5: bad thing happened"
        print -r -- "note: derived data at ${HOME}/Library/Developer/Xcode/DerivedData/Foo-abc123/Build"
        print -r -- "note: external drive /Volumes/SomeDrive/file.ARW"
        print -r -- "note: scratch /private/tmp/abc123/x"
        print -r -- "note: var scratch /private/var/folders/xy/abc/T/thing"
        print -r -- "Executed 4 tests, with 0 failures (0 unexpected) in 0.01 (0.01) seconds"
    } > "$sample"
    redact_file "$sample"
    local redaction_ok=1
    if has_private_path "$sample"; then
        redaction_ok=0
    fi
    if ! grep -qF -- '<REPO_ROOT>/Sources/Foo.swift:12:5: bad thing happened' "$sample"; then
        redaction_ok=0
    fi
    if ! grep -qF -- 'Executed 4 tests, with 0 failures' "$sample"; then
        redaction_ok=0
    fi
    if (( redaction_ok )); then
        print -r -- "selftest: redaction masks private paths and preserves counts/relative paths: ok"
    else
        print -r -- "selftest: redaction check FAILED"
        failures=$((failures + 1))
    fi

    rm -rf -- "$tmp"

    # --- Fake step commands for the lifecycle/signal cases below. ---
    local helper_dir
    helper_dir="$(mktemp -d)"
    local fake_swifttest_helper="${helper_dir}/fake-swifttest.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'print -r -- "Executed 4 tests, with 0 failures (0 unexpected) in 0.01 (0.01) seconds"'
    } > "$fake_swifttest_helper"
    chmod +x "$fake_swifttest_helper"

    FAIL_WITH_7_HELPER="${helper_dir}/fail-with-7.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'exit 7'
    } > "$FAIL_WITH_7_HELPER"
    chmod +x "$FAIL_WITH_7_HELPER"

    # Deterministic two-process interrupt target for the signal-case tests
    # below: a real grandchild process (not just the wrapper subshell
    # run_with_timeout already forks) whose exact PID is recorded on disk,
    # so a case can assert on precise PIDs instead of a `pgrep -f` name
    # pattern. INTERRUPT_CHILD_HELPER writes its own PID to $1, then blocks.
    INTERRUPT_CHILD_HELPER="${helper_dir}/interrupt-child.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'print -r -- "$$" > "$1"'
        print -r -- 'while true; do sleep 3600; done'
    } > "$INTERRUPT_CHILD_HELPER"
    chmod +x "$INTERRUPT_CHILD_HELPER"

    # INTERRUPT_ROOT_HELPER args: <root_pidfile> <child_pidfile> <ready_file>
    # <child_script>. Writes its own PID, launches child_script as a real
    # child, waits for that child to confirm its own PID on disk AND for
    # that PID to answer `kill -0`, only then touches ready_file — the
    # caller's readiness handshake — and finally blocks on the child so both
    # processes stay alive together until signalled.
    INTERRUPT_ROOT_HELPER="${helper_dir}/interrupt-root.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'root_pidfile="$1"; child_pidfile="$2"; ready_file="$3"; child_script="$4"'
        print -r -- 'print -r -- "$$" > "$root_pidfile"'
        print -r -- '"$child_script" "$child_pidfile" &'
        print -r -- 'child_pid=$!'
        print -r -- 'while [[ ! -s "$child_pidfile" ]]; do sleep 0.02; done'
        print -r -- 'grandchild_pid="$(<"$child_pidfile")"'
        print -r -- 'while ! kill -0 "$grandchild_pid" 2>/dev/null; do sleep 0.02; done'
        print -r -- 'touch "$ready_file"'
        print -r -- 'wait "$child_pid"'
    } > "$INTERRUPT_ROOT_HELPER"
    chmod +x "$INTERRUPT_ROOT_HELPER"

    FASTPASS_CMD=(
        strictbuild   "true"
        swifttest     "$fake_swifttest_helper"
        simbuild      "true"
        mvppreflight  "true"
        mvpacceptance "true"
    )

    run_signal_selftest_case strictbuild  TERM 143 || failures=$((failures + 1))
    run_signal_selftest_case swifttest    TERM 143 || failures=$((failures + 1))
    run_signal_selftest_case simbuild     TERM 143 || failures=$((failures + 1))
    run_signal_selftest_case mvppreflight TERM 143 || failures=$((failures + 1))
    run_signal_selftest_case mvpacceptance TERM 143 || failures=$((failures + 1))
    run_signal_selftest_case strictbuild  INT  130 || failures=$((failures + 1))
    run_signal_selftest_case strictbuild  HUP  129 || failures=$((failures + 1))

    run_fastfail_selftest_case || failures=$((failures + 1))
    run_fakepass_selftest_case || failures=$((failures + 1))
    run_missinghelper_selftest_case || failures=$((failures + 1))

    rm -rf -- "$helper_dir"

    if (( failures == 0 )); then
        print -r -- "selftest: all cases behaved as expected"
        return 0
    else
        print -r -- "selftest: ${failures} case(s) behaved unexpectedly"
        return 1
    fi
}

if [[ -n "${LUMAHARBOR_IPAD_RUNNER_SELFTEST:-}" ]]; then
    run_selftest
    exit $?
fi

# ---------------------------------------------------------------------------
# Args — this script takes none for a real run.
# ---------------------------------------------------------------------------

if (( $# > 0 )); then
    print -u2 -r -- "error: unknown argument(s): $*"
    print -u2 -r -- "usage: $0"
    exit 2
fi

if [[ -n "${LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS:-}" ]]; then
    if [[ "${LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS}" == <-> ]] && (( LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS > 0 )); then
        STEP_TIMEOUT_SECONDS=$LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS
    else
        print -u2 -r -- "warning: LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS must be a positive integer; using default ${STEP_TIMEOUT_SECONDS_DEFAULT}s"
    fi
fi

# ---------------------------------------------------------------------------
# Per-run scratch directory.
# ---------------------------------------------------------------------------

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${ROOT_DIR}/.build/ipad-vertical-slice/${TIMESTAMP}"
mkdir -p -- "$RUN_DIR"
SUMMARY_FILE="${RUN_DIR}/summary.md"

overall_ok=1
RUNNER_PREFLIGHT_REASON=""

local_key=""
for local_key in "${STEP_ORDER[@]}"; do
    STEP_STATE[$local_key]="SKIPPED (runner interrupted before this step started)"
    STEP_EXITCODE[$local_key]="n/a"
done

trap 'handle_terminating_signal INT' INT
trap 'handle_terminating_signal TERM' TERM
trap 'handle_terminating_signal HUP' HUP

# ---------------------------------------------------------------------------
# Minimal runner preflight: only checks that the tools/files this runner
# itself needs to even attempt step 1 exist. The three fixture directories
# (RAW/APFS/exFAT) are validated by step 4 (Scripts/run-mvp-acceptance.zsh
# --preflight-only) — duplicating that check here would just be two sources
# of truth for the same three env vars.
# ---------------------------------------------------------------------------

runner_preflight() {
    if ! command -v swift >/dev/null 2>&1; then
        RUNNER_PREFLIGHT_REASON="swift not found on PATH"
        return 1
    fi
    if ! command -v xcodebuild >/dev/null 2>&1; then
        RUNNER_PREFLIGHT_REASON="xcodebuild not found on PATH"
        return 1
    fi
    if [[ ! -d "${ROOT_DIR}/Apps/LumaHarborPad.swiftpm" ]]; then
        RUNNER_PREFLIGHT_REASON="Apps/LumaHarborPad.swiftpm not found under the repo root"
        return 1
    fi
    if [[ ! -x "${ROOT_DIR}/Scripts/run-mvp-acceptance.zsh" ]]; then
        RUNNER_PREFLIGHT_REASON="Scripts/run-mvp-acceptance.zsh not found or not executable"
        return 1
    fi
    return 0
}

if ! runner_preflight; then
    overall_ok=0
    local_key=""
    for local_key in "${STEP_ORDER[@]}"; do
        STEP_STATE[$local_key]="SKIPPED (runner preflight failed: ${RUNNER_PREFLIGHT_REASON})"
    done
    finalize_run
    exit 1
fi

# ---------------------------------------------------------------------------
# Steps: only run while nothing before it has failed. Anything after the
# first failure is recorded SKIPPED with the concrete reason, never a pass.
# ---------------------------------------------------------------------------

blocked=0
blocking_reason=""
for step_key in "${STEP_ORDER[@]}"; do
    if (( blocked )); then
        STEP_STATE[$step_key]="SKIPPED (${blocking_reason})"
        continue
    fi
    if run_step "$step_key"; then
        :
    else
        overall_ok=0
        blocked=1
        blocking_reason="${STEP_BLOCK_REASON[$step_key]:-}"
    fi
done

finalize_run

(( overall_ok )) || exit 1
exit 0
