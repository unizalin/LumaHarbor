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
#   .build/ipad-vertical-slice/<UTC timestamp>-<pid>-<random>/
# as summary.md plus one log per step. Every artifact that is kept in that
# directory has private absolute paths (repo checkout, $HOME, fixture
# directories, /Users, /Volumes, /private/var, /private/tmp, and the bare
# /tmp, /var aliases) rewritten to a fixed <TOKEN> before the run is
# considered finished; a grep safety net over every kept artifact enforces
# this and flips the run to FAIL if anything slipped through, or if the
# scan itself could not run at all.
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
# ---------------------------------------------------------------------------
# Self-test architecture (not a supported CLI flag for normal use):
#
#   Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest
#
# runs run_selftest, the self-test DRIVER — an explicit argv subcommand,
# deliberately not an environment variable, so a self-test invocation can
# never be triggered by (or accidentally leak into) a later zero-argument
# production invocation via a stray inherited/exported shell variable. The
# driver spawns fresh
# subprocesses of THIS SAME FILE, but never as a normal (production)
# invocation — always via a distinct, internal subcommand:
#
#   Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest_simulate_steps \
#       <cmd-strictbuild> <cmd-swifttest> <cmd-simbuild> <cmd-mvppreflight> \
#       <cmd-mvpacceptance> [--pause-at=NAME --pause-ready=PATH --pause-go=PATH] \
#       [--fake-mv=PATH]
#
# This is a hard architectural boundary, not a credential check: a normal,
# documented invocation (zero arguments) NEVER reaches, and this script's
# production code path (step_command_for, the finalize_run publish
# sequence) NEVER READS, any LUMAHARBOR_IPAD_SELFTEST_* environment
# variable — there is no such variable name anywhere in that code. An
# earlier design instead gated a shared code path behind a marker-file
# credential (a file whose path and content had to match); that was
# demonstrated to be forgeable by a caller who simply creates a matching
# marker and token pair itself, since both live in the same
# fully-caller-controlled channel (environment variables). The fix here is
# structural, not cryptographic: the command-simulation capability lives in
# a function (selftest_simulated_command_for) production's own code path
# never calls, reachable only by literally passing this specific,
# internal-looking first argument — which the normal "Args" check just
# below error out on for anything else. Simulated runs are additionally
# fully isolated from real acceptance evidence: they land under
# .build/ipad-vertical-slice-selftest/ (see SELFTEST_RUN_TREE), a
# completely separate directory tree from real runs
# (.build/ipad-vertical-slice/, see PRODUCTION_RUN_TREE), and their
# summary.md is stamped "Run mode: SELFTEST" as its very first line so that
# even a report collector that only inspects file *content* — not the path
# it came from — can identify and reject one.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repo root from this script's own location, not $PWD.
# ---------------------------------------------------------------------------

SCRIPT_PATH="${0:A}"
SCRIPT_DIR="${SCRIPT_PATH:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

PRODUCTION_RUN_TREE=".build/ipad-vertical-slice"
SELFTEST_RUN_TREE=".build/ipad-vertical-slice-selftest"

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
# the generic prefix patterns are a catch-all safety net for everything else
# (DerivedData paths, mounted-volume paths, /private/var, /private/tmp, and
# the bare /tmp, /var aliases macOS symlinks to them) that isn't
# informative to keep anyway.
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
    # `|| true`: a disk-full or permission error here must never abort the
    # script under `set -e` before has_private_path gets a chance to run —
    # a failed edit leaves the original, still-unredacted text in place,
    # which the grep safety net downstream is exactly what's supposed to
    # catch and fail closed on. Guarded here at the source (not just at
    # finalize_run's own outer call to redact_file) because a failure on
    # e.g. the very first of redact_file's several redact_literal/
    # redact_pattern calls would otherwise abort the function immediately,
    # skipping every later call for the SAME file too.
    sed -i '' -e "s|${escaped}|${token}|g" "$file" || true
}

redact_pattern() {
    # redact_pattern <file> <extended-regex> <token>
    local file="$1" pattern="$2" token="$3"
    [[ -f "$file" ]] || return 0
    sed -i '' -E "s#${pattern}#${token}#g" "$file" || true
}

redact_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    redact_literal "$file" "$ROOT_DIR" "<REPO_ROOT>"
    redact_literal "$file" "${LUMAHARBOR_RAW_FIXTURE_DIR:-}" "<RAW_FIXTURE_DIR>"
    redact_literal "$file" "${LUMAHARBOR_APFS_TEST_DIR:-}" "<APFS_TEST_DIR>"
    redact_literal "$file" "${LUMAHARBOR_EXFAT_TEST_DIR:-}" "<EXFAT_TEST_DIR>"
    redact_literal "$file" "${HOME:-}" "<HOME>"
    # Quoted forms first: a path that was wrapped in quotes (common in
    # xcodebuild/Xcode diagnostics — e.g. "/Volumes/Client Photos/x.ARW")
    # can contain spaces, parens, or non-ASCII (Traditional Chinese, etc.)
    # with no ambiguity about where it ends, since the matching quote
    # unambiguously bounds it. The whole quoted span, quotes included, is
    # replaced.
    redact_pattern "$file" '"(/Users/[^"]*|/Volumes/[^"]*|/private/var/[^"]*|/private/tmp/[^"]*|/var/[^"]*|/tmp/[^"]*)"' '"<PATH>"'
    redact_pattern "$file" "'(/Users/[^']*|/Volumes/[^']*|/private/var/[^']*|/private/tmp/[^']*|/var/[^']*|/tmp/[^']*)'" "'<PATH>'"
    # Unquoted catch-all: everything after the prefix up to the next quote,
    # angle bracket, pipe, or end of line is treated as part of the path —
    # deliberately not stopping at plain spaces or restricted to ASCII, so
    # a bare (unquoted) path containing spaces or non-ASCII characters is
    # still fully consumed rather than leaving its second half (a volume
    # name, a filename) sitting unredacted in the log. Over-redacting a
    # few trailing words of surrounding prose on the same line is an
    # acceptable, safe-direction trade-off for a privacy filter — the
    # failure mode this must avoid is a private path surviving, not a log
    # line reading slightly less precisely. /var/ and /tmp/ (the bare,
    # un-prefixed macOS symlink aliases for /private/var and /private/tmp)
    # are included explicitly: a tool that logs a path via the alias rather
    # than its resolved form would otherwise sail straight past the
    # /private/... patterns.
    redact_pattern "$file" '/Users/[^"'\''<>|]+' "<HOME_PATH>"
    redact_pattern "$file" '/Volumes/[^"'\''<>|]+' "<VOLUME_PATH>"
    redact_pattern "$file" '/private/var/[^"'\''<>|]+' "<PRIVATE_VAR_PATH>"
    redact_pattern "$file" '/private/tmp/[^"'\''<>|]+' "<PRIVATE_TMP_PATH>"
    redact_pattern "$file" '/var/[^"'\''<>|]+' "<VAR_PATH>"
    redact_pattern "$file" '/tmp/[^"'\''<>|]+' "<TMP_PATH>"
}

# _privacy_grep_result <exit-code> — the shared fail-closed interpretation
# of a grep-family exit code: 1 (a clean, definitive "no match") is the
# ONLY code that means "keep looking elsewhere"; both 0 (a match — a real
# leak) and 2+ (the scan itself failed: a bad file, an I/O error, an
# unavailable grep binary, ...) mean "treat this as not-clean". Conflating
# "clean" with "the scan could not run" is exactly how a private path could
# previously survive undetected if grep itself ever failed.
_privacy_grep_result() {
    local rc="$1"
    (( rc == 1 )) && return 1
    return 0
}

# has_private_path <file> — the grep safety net. True (0) means either a
# forbidden absolute-path prefix is still present after redact_file ran, OR
# the scan itself could not be completed (fail closed on either). Checks
# both the generic prefixes (/Users/, /Volumes/, /private/var/,
# /private/tmp/, /var/, /tmp/) AND the actual literal values this run
# cares about (the repo root, $HOME, and each of the three fixture
# directories) directly — the generic prefixes alone would miss a fixture
# directory mounted somewhere that doesn't start with any of them, or a
# path logged via some other alias.
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

# collect_xcode_version — best-effort; always prints something (never fails
# and never aborts the caller under `set -e`). `xcodebuild -version` being
# missing from PATH, or existing but exiting non-zero, must not be able to
# take down finalize_run before summary.md is written — this is exactly the
# same class of bug the earlier SIGPIPE fix addressed for the same call
# site, generalized to cover "xcodebuild isn't there at all" too. Prints
# "unknown" rather than an empty string when nothing usable comes back.
collect_xcode_version() {
    local output=""
    output="$(xcodebuild -version 2>/dev/null)" || output=""
    local first_line="${output%%$'\n'*}"
    if [[ -z "$first_line" ]]; then
        print -r -- "unknown"
    else
        print -r -- "$first_line"
    fi
}

# git_worktree_fingerprint <repo_root>
# Prints a hash that changes whenever the *content* of the working tree
# differs from HEAD in any way (a bare `git status --porcelain | wc -l`
# comparison is blind to: the same dirty file's content changing further,
# one dirty file being reverted while a different one becomes dirty, and a
# file moving between tracked and untracked). Prints nothing and returns 1
# if ANY step needed to compute it fails (git itself, enumerating
# untracked entries, reading one, or hashing) — callers MUST treat that as
# "cannot verify, fail closed", never compare two empty results and call
# them "unchanged".
#
# NUL-safe throughout (`git ls-files -z`, `read -d ''`) so a filename
# containing an embedded newline cannot desynchronize the per-entry loop.
# Every untracked entry from `git ls-files --others --exclude-standard -z`
# is classified before anything is read:
#   - a symlink's TARGET path is recorded (via `readlink`) and never
#     dereferenced — this detects the link being repointed without this
#     function ever opening whatever it currently points at;
#   - a regular file has its type, POSIX mode, size, and actual byte
#     content recorded;
#   - anything else (FIFO, device, socket, directory, ...) has only its
#     type and mode recorded, content deliberately never read — `cat`-ing
#     a FIFO with nothing writing to it would block forever, hanging this
#     function and therefore the entire acceptance run. `stat` failing even
#     for this mode-only read (permission error, the entry disappearing
#     mid-scan, ...) fails the whole function closed (empty output, exit 1)
#     rather than substituting a placeholder like "unknown" and continuing
#     — a placeholder there would make two different failure states hash
#     identically to two different real states, defeating the point of a
#     fingerprint.
# Tracked-vs-HEAD differences (staged and unstaged, content included) come
# from `git diff HEAD --binary`, which git computes internally without
# this function ever needing to open a tracked file itself.
git_worktree_fingerprint() {
    local repo_root="$1"

    # Each of `git diff` and `git ls-files` is captured as the CONDITION of
    # an `if`, not via a trailing `|| fallback` on its own line: in zsh (and
    # bash), guarding a failing command with a trailing `||` makes `set -e`
    # treat that command as "protected", and that protection extends INTO
    # a command substitution's own subshell — a failure of the git command
    # running *inside* `$(...)` then no longer aborts that subshell, so any
    # further commands placed after it in the same substitution keep
    # running on top of a git failure instead of the whole substitution
    # correctly coming back empty. Putting the assignment directly as an
    # `if` condition is a different, safe form of "protected": here each
    # substitution wraps exactly one command, so its own exit code is
    # simply git's exit code either way, and the `if`/`else` gives an
    # explicit branch to fail closed in rather than silently continuing.
    local diff_output
    if ! diff_output="$(git -C "$repo_root" diff HEAD --binary 2>/dev/null)"; then
        print -r -- ""
        return 1
    fi

    local raw
    if ! raw="$(git -C "$repo_root" ls-files --others --exclude-standard -z 2>/dev/null)"; then
        print -r -- ""
        return 1
    fi

    # NUL-safe split into an array (not a piped `while read`, which would
    # run the loop body in its own pipeline subshell — an explicit `exit 1`
    # inside it would only end that inner subshell, never propagate out to
    # make the outer `out="$(...)"` below correctly observe the failure).
    local -a files
    files=(${(0)raw})

    local out
    if ! out="$(
        print -r -- "$diff_output"
        print -r -- "---untracked---"
        local f
        for f in "${files[@]}"; do
            [[ -n "$f" ]] || continue
            local full="${repo_root}/${f}"
            if [[ -L "$full" ]]; then
                local target
                target="$(readlink -- "$full")" || exit 1
                print -r -- "==> ${f} type=symlink target=${target}"
            elif [[ -f "$full" ]]; then
                local mode size
                mode="$(stat -f '%p' -- "$full" 2>/dev/null)" || exit 1
                size="$(stat -f '%z' -- "$full" 2>/dev/null)" || exit 1
                print -r -- "==> ${f} type=file mode=${mode} size=${size}"
                cat -- "$full" || exit 1
            else
                local mode
                mode="$(stat -f '%p' -- "$full" 2>/dev/null)" || exit 1
                print -r -- "==> ${f} type=other mode=${mode} (content intentionally not read)"
            fi
        done
    )"; then
        print -r -- ""
        return 1
    fi

    local hash
    if ! hash="$(print -r -- "$out" | shasum -a 256 2>/dev/null)" || [[ -z "$hash" ]]; then
        print -r -- ""
        return 1
    fi
    hash="${hash%% *}"
    if [[ -z "$hash" ]]; then
        print -r -- ""
        return 1
    fi
    print -r -- "$hash"
    return 0
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
# when it is not. Returns 0 only for a parseable summary with a non-zero
# executed count, zero skipped tests, and zero failures.
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
    if (( executed == 0 )); then
        print -r -- "0 tests executed — an empty run must never count as a pass"
        return 1
    fi
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
# `timeout`, no `setsid`). A command runs inside its own subshell wrapper so
# the wrapper's PID is a stable root for walking exactly its own descendants
# via `pgrep -P` — never a broad process-name match, so this can never touch
# an unrelated swift/xcodebuild process elsewhere on the machine.
#
# Process groups were deliberately NOT adopted here in place of this
# snapshot-and-walk approach, despite a process-group-wide `kill -TERM --
# -PGID` being immune to both of the residual races documented below (a
# child forked after the snapshot, and a recycled PID). Getting each step
# its own process group on stock macOS/zsh requires enabling job control
# (`setopt monitor`) for a non-interactive script — there is no `setsid`
# binary on macOS, and zsh only assigns a background job its own process
# group when MONITOR is on. That trade is worse than the race it would
# close: a non-interactive invocation (exactly how this runner is normally
# used — CI, backgrounded, no controlling TTY) is precisely the situation
# where job-control machinery is least predictable — a backgrounded job
# that tries to read or write the terminal under MONITOR can be stopped
# with SIGTTIN/SIGTTOU, which has no controlling TTY to even deliver a
# meaningful stop to here, and turns a rare, narrow race into a new class
# of hangs that would be far harder to diagnose than the two remaining
# risks below. Those two are instead mitigated directly:
#
#   1. A descendant forked *after* the initial snapshot but *before* the
#      final KILL (e.g. during the TERM grace period) would, in the naive
#      version of this design, never be discovered. Mitigated by
#      re-collecting the tree exactly once more, but ONLY while the root
#      PID is confirmed still alive — see run_with_timeout and
#      handle_terminating_signal, which each take this supplemental
#      snapshot before their final KILL, not after the root has already
#      exited (which was the original, already-fixed bug: rescanning
#      *after* root death finds nothing, since exited processes' children
#      are reparented away from them). A process forked in the sub-second
#      gap between the very first snapshot and the first TERM landing, by
#      a process that *also* exits before that supplemental rescan, is a
#      narrower residual window this cannot close without process groups;
#      it was judged acceptable given how this runner's actual commands
#      (swift/xcodebuild/run-mvp-acceptance.zsh) behave in practice.
#   2. A PID already signalled and exited could, after some delay, be
#      recycled by the OS for a completely unrelated process before this
#      runner's own later KILL is sent to what it still believes is the
#      original target. Mitigated by recording each PID's process start
#      time (`ps -o lstart=`) at snapshot time and re-checking it
#      immediately before every signal: a PID whose start time no longer
#      matches — or that no longer exists — is skipped rather than
#      blindly signalled.
# ---------------------------------------------------------------------------

# pid_identity <pid> — prints the process's start time (a cheap, good-enough
# fingerprint), or nothing if it doesn't currently exist. Two calls for the
# same PID returning different non-empty values means the OS recycled that
# PID for a different process in between.
pid_identity() {
    ps -o lstart= -p "$1" 2>/dev/null
}

# collect_descendant_pids <root_pid>
# Prints, one per line, "<pid> <identity>" for root_pid followed by every
# currently-live descendant discovered via `pgrep -P`, ordered leaf-first
# (the deepest descendants first, root_pid last). This is a one-shot
# snapshot: callers MUST take it BEFORE sending any signal to root_pid, and
# reuse that same snapshot for every signal in the escalation (TERM, then
# KILL) — a *second* pgrep traversal rooted at root_pid, taken after
# root_pid has already been signalled, can find zero descendants even while
# they are still alive: once root_pid exits, its children are reparented
# away from it (typically to launchd), so `pgrep -P root_pid` no longer
# sees them at all. Re-deriving the descendant list after the first signal
# is exactly how a live descendant survives cleanup undetected. See the
# block comment above for the one narrowly-scoped exception to "never
# re-derive" this runner does use, and why.
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
        print -r -- "${ordered_pids[$idx]} $(pid_identity "${ordered_pids[$idx]}")"
    done
}

# signal_pid_list <signal> <"pid identity">...
# Sends exactly one signal to exactly the given PIDs — never a broad
# process-name or process-group kill, and never a PID whose current
# identity (start time) no longer matches the one recorded when it was
# snapshotted, since that means either it already exited or the OS has
# since reused its number for an unrelated process.
signal_pid_list() {
    local sig="$1"
    shift
    local entry pid identity current
    for entry in "$@"; do
        [[ -n "$entry" ]] || continue
        pid="${entry%% *}"
        identity="${entry#* }"
        [[ -n "$pid" ]] || continue
        current="$(pid_identity "$pid")"
        [[ -n "$current" ]] || continue
        if [[ -n "$identity" && "$current" != "$identity" ]]; then
            continue
        fi
        kill -"$sig" "$pid" 2>/dev/null || true
    done
}

# all_pids_gone <"pid identity">...
# True (0) only once every given PID has exited. Used to bound the grace
# wait between TERM and KILL, and to confirm cleanup actually completed
# rather than merely having been requested.
all_pids_gone() {
    local entry pid
    for entry in "$@"; do
        [[ -n "$entry" ]] || continue
        pid="${entry%% *}"
        [[ -n "$pid" ]] || continue
        kill -0 "$pid" 2>/dev/null && return 1
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
            # Supplemental rescan for anything forked during the grace
            # window above — ONLY while cmd_pid is confirmed still alive,
            # never after it has already exited (see the block comment
            # above collect_descendant_pids for why that distinction
            # matters).
            if kill -0 "$cmd_pid" 2>/dev/null; then
                local -a fresh
                fresh=("${(f)$(collect_descendant_pids "$cmd_pid")}")
                victims=("${victims[@]}" "${fresh[@]}")
            fi
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
#
# step_command_for is the ONE AND ONLY production command resolver, and it
# is pure: given a step key, it always sets the same hardcoded command —
# there is no LUMAHARBOR_IPAD_SELFTEST_* variable name anywhere in this
# function, or anywhere else on the production code path. Self-test's
# ability to substitute a fake command lives entirely in
# selftest_simulated_command_for below, reached only via the
# __selftest_simulate_steps subcommand dispatch at the bottom of this
# script — never via step_command_for, and never via any environment
# variable a production invocation could stumble into.
# ---------------------------------------------------------------------------

STEP_TIMEOUT_SECONDS_DEFAULT=3600
STEP_TIMEOUT_SECONDS=$STEP_TIMEOUT_SECONDS_DEFAULT

CURRENT_STEP_KEY=""

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
}

# selftest_simulated_command_for <key> — the self-test-only counterpart to
# step_command_for, used ONLY when SIMULATION_MODE=1 (set only by the
# __selftest_simulate_steps dispatch below, never by any environment
# variable). Reads the five commands from SIM_CMD_<KEY>, plain script
# globals populated directly from __selftest_simulate_steps's own
# positional arguments — never from the environment. Each value is a bare,
# unquoted command word (or a helper path plus bare arguments), split via
# `${(z)}` exactly like a shell would.
typeset -A SIM_CMD
selftest_simulated_command_for() {
    local key="$1"
    STEP_CWD="$ROOT_DIR"
    STEP_CMD=(${(z)SIM_CMD[$key]})
}

# run_step <key> — runs one step under the timeout watchdog, sets
# STEP_STATE[key] and STEP_EXITCODE[key], and returns 0/1 for the caller's
# fail-fast loop. Never prints a step's own final PASS itself for swifttest
# before checking the parsed XCTest summary, since `swift test` exiting 0
# is not the full story. COMMAND_RESOLVER selects step_command_for
# (production, the default) or selftest_simulated_command_for (only ever
# set by __selftest_simulate_steps) — the choice is made once, structurally,
# based on how this script's own main() was entered, not per step.
COMMAND_RESOLVER="step_command_for"
run_step() {
    local key="$1"
    local label="${STEP_LABEL[$key]}"
    local logfile="${RUN_DIR}/${STEP_LOGFILE[$key]}"

    "$COMMAND_RESOLVER" "$key"

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
# Summary + signal handling.
# ---------------------------------------------------------------------------

# SIMULATION_MODE and the SIM_PAUSE_*/PUBLISH_MV_CMD globals below are set
# ONLY by the __selftest_simulate_steps dispatch at the bottom of this
# script, from its own explicit argv flags — never from any environment
# variable, and never touched anywhere on the production code path.
SIMULATION_MODE=0
SIM_PAUSE_AT=""
SIM_PAUSE_READY_FILE=""
SIM_PAUSE_GO_FILE=""
PUBLISH_MV_CMD=(mv -f --)

# selftest_pause_at <checkpoint-name> — a no-op unless SIMULATION_MODE=1 AND
# this exact checkpoint name was requested via --pause-at=. Touches
# SIM_PAUSE_READY_FILE and blocks (bounded) until SIM_PAUSE_GO_FILE
# appears — a deterministic handshake, never a fixed sleep guess. Called at
# five points below (finalize-start, before-mv, after-mv-before-finalized,
# after-finalized, and interstep-after-<key> from the main step loop) so a
# test can land a real signal at exactly one of those instants.
selftest_pause_at() {
    (( SIMULATION_MODE )) || return 0
    [[ "$1" == "$SIM_PAUSE_AT" ]] || return 0
    [[ -n "$SIM_PAUSE_READY_FILE" && -n "$SIM_PAUSE_GO_FILE" ]] || return 0
    touch "$SIM_PAUSE_READY_FILE"
    local deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )) && [[ ! -f "$SIM_PAUSE_GO_FILE" ]]; do
        sleep 0.02
    done
}

# SUMMARY_STATE is a three-state machine, not a single "written" flag:
#   notStarted -> finalizing -> finalized
# A signal that lands while state is "finalizing" does not re-enter or
# abort finalize_run at all; it just records DEFERRED_SIGNAL and returns,
# letting the interrupted call resume and run to completion (through the
# atomic mv and the privacy scan) before anything exits. Whichever code
# path called finalize_run checks DEFERRED_SIGNAL once it returns and exits
# with the right signal-derived code instead of falling through to its
# normal ending.
SUMMARY_STATE="notStarted"
DEFERRED_SIGNAL=""

# exit_for_signal <SIGNAL> — the one place the HUP/INT/TERM -> exit-code
# mapping lives, shared by handle_terminating_signal and every code path
# that has to honor a DEFERRED_SIGNAL after finalize_run returns.
exit_for_signal() {
    local sig="$1"
    case "$sig" in
        HUP) exit 129 ;;
        INT) exit 130 ;;
        TERM) exit 143 ;;
        *) exit 130 ;;
    esac
}

# force_summary_overall_fail — the authoritative, pure-zsh (no grep, no
# sed, no dependence on any external binary's exit code) last-resort
# correction: if $SUMMARY_FILE currently exists and its content contains
# "Overall result: PASS", rewrites it to FAIL and republishes via
# PUBLISH_MV_CMD. A missing file, or one that doesn't currently read PASS,
# is not an error — this is meant to be called defensively, from anywhere a
# terminating signal might legitimately require the already-published file
# corrected, including well after finalize_run's own publish loop has
# already run and returned. Returns 1 only when the file exists but the
# correction itself could not be written (e.g. disk full) — callers that
# need this to have actually succeeded must check the return value; callers
# that are just taking a defensive extra pass may ignore it.
force_summary_overall_fail() {
    [[ -n "$SUMMARY_FILE" && -f "$SUMMARY_FILE" ]] || return 0
    local content
    content="$(<"$SUMMARY_FILE")" 2>/dev/null || return 1
    [[ "$content" == *'Overall result: PASS'* ]] || return 0
    content="${content//Overall result: PASS/Overall result: FAIL}"
    local fixed="${SUMMARY_FILE}.fix.$$.${RANDOM}"
    print -r -- "$content" > "$fixed" 2>/dev/null || return 1
    if ! "${PUBLISH_MV_CMD[@]}" "$fixed" "$SUMMARY_FILE" 2>/dev/null; then
        rm -f -- "$fixed"
        return 1
    fi
    return 0
}

# verify_published_summary <file> — the postcondition gate for a publish
# attempt, deliberately pure zsh throughout (never grep, never sed) so it
# stays trustworthy even in every self-test scenario below where one of
# those tools has been deliberately broken. Requires: the file exists, is a
# regular file (never a symlink left behind by some unexpected mv target),
# is readable, contains EXACTLY ONE "Overall result: " line, and — if
# DEFERRED_SIGNAL is set — that line reads exactly "Overall result: FAIL".
verify_published_summary() {
    local file="$1"
    [[ -n "$file" && -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    local content
    content="$(<"$file")" 2>/dev/null || return 1
    local -a lines
    lines=("${(@f)content}")
    local line count=0 last_overall=""
    for line in "${lines[@]}"; do
        if [[ "$line" == "Overall result: "* ]]; then
            count=$((count + 1))
            last_overall="$line"
        fi
    done
    (( count == 1 )) || return 1
    if [[ -n "$DEFERRED_SIGNAL" ]]; then
        [[ "$last_overall" == "Overall result: FAIL" ]] || return 1
    fi
    return 0
}

# finalize_run — redacts every log that exists, writes summary.md (a
# SELFTEST run-mode stamp when applicable, commit, timestamp, Xcode
# version, architecture, per-step state/exit-code, the parsed swift-test
# executed/skipped/failures counts, a repo-state check, a privacy-scan
# result, and the overall result), then runs the grep safety net over every
# kept artifact. The Overall line is derived fresh from STEP_STATE here —
# every step must literally read "PASS" — rather than trusting an external
# `overall_ok` flag that a signal landing outside any step could leave
# untouched.
#
# Publishing (the section from "Overall decided" through
# "SUMMARY_STATE=finalized") is itself guarded against a signal landing at
# ANY of four points: before the atomic mv, DURING the mv (an external,
# uninterruptible-by-our-trap command — see the publish loop below), after
# the mv but before SUMMARY_STATE flips, and after it flips. All four must
# leave the published file reading Overall FAIL, not just the process's own
# exit code — force_summary_overall_fail is called after the publish loop
# and again after each of the two later checkpoints (and, for a signal
# landing strictly after SUMMARY_STATE="finalized", from the top of
# handle_terminating_signal itself), so every one of the four windows gets
# an explicit correction attempt regardless of how far finalize_run had
# already progressed when the signal arrived.
finalize_run() {
    if [[ "$SUMMARY_STATE" == "finalized" || "$SUMMARY_STATE" == "finalizing" ]]; then
        return 0
    fi
    SUMMARY_STATE="finalizing"

    selftest_pause_at "finalize-start"

    local key
    for key in "${STEP_ORDER[@]}"; do
        redact_file "${RUN_DIR}/${STEP_LOGFILE[$key]}" || true
    done

    local commit xcode_version arch
    commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || print -r -- unknown)"
    xcode_version="$(collect_xcode_version)"
    arch="$(uname -m)"

    # Repo state must not have moved out from under a long-running run —
    # otherwise a build/test log produced against one commit could end up
    # attributed to whatever HEAD happens to be current by the time this
    # summary is written. Fails closed if fingerprinting itself failed at
    # either end (an empty START_FINGERPRINT or end_fingerprint), never
    # comparing two empty strings and calling that "unchanged".
    local end_head end_fingerprint repo_state_ok=1
    end_head="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || print -r -- unknown)"
    end_fingerprint="$(git_worktree_fingerprint "$ROOT_DIR")" || end_fingerprint=""
    if [[ -z "$START_FINGERPRINT" || -z "$end_fingerprint" ]]; then
        repo_state_ok=0
    fi
    if [[ "$end_head" != "$START_HEAD" || "$end_fingerprint" != "$START_FINGERPRINT" ]]; then
        repo_state_ok=0
    fi

    local tmp_summary="${SUMMARY_FILE}.tmp.$$"
    {
        print -r -- "# iPad RAW editing vertical slice acceptance run ${TIMESTAMP}"
        print -r -- ""
        if (( SIMULATION_MODE )); then
            print -r -- "**Run mode: SELFTEST** — this is a self-test simulation run, produced by"
            print -r -- "__selftest_simulate_steps against fake commands. It is not real Task 8"
            print -r -- "acceptance evidence and must never be accepted as such by a report"
            print -r -- "collector; it is also physically isolated under"
            print -r -- "\`${SELFTEST_RUN_TREE}/\`, never \`${PRODUCTION_RUN_TREE}/\`."
            print -r -- ""
        fi
        print -r -- "- Commit: ${START_HEAD}"
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
            print -r -- "- ${STEP_LABEL[$key]}: ${RUN_TREE_NAME}/${RUN_DIR_NAME}/${STEP_LOGFILE[$key]}"
        done
        print -r -- ""
        print -r -- "## Repo state"
        print -r -- ""
        if (( repo_state_ok )); then
            print -r -- "Repo state: PASS (HEAD and working-tree content fingerprint unchanged since the run started)"
        else
            print -r -- "Repo state: FAIL (HEAD or the working tree's content changed during the run, or the fingerprint could not be computed — start HEAD ${START_HEAD}, end HEAD ${end_head}, start fingerprint '${START_FINGERPRINT}', end fingerprint '${end_fingerprint}')"
        fi
    } > "$tmp_summary"

    # A redaction failure (disk full, a permission error, ...) must not be
    # allowed to abort the script under `set -e` before the privacy scan
    # below ever runs — `|| true` lets execution continue to that scan,
    # which is the actual fail-closed guarantee: an sed call that silently
    # did nothing leaves the original, still-unredacted text in place, and
    # has_private_path below will find it and flip Overall to FAIL, exactly
    # as if redaction had never been attempted.
    redact_file "$tmp_summary" || true

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
        print -r -- "Privacy scan: $(( privacy_ok )) (1 = clean, 0 = leak found or scan failed)"
        if (( ! privacy_ok )); then
            print -r -- "Files still matching a private absolute-path pattern (or that could not be scanned) after redaction (names only):"
            local lf
            for lf in "${leaked_files[@]}"; do
                print -r -- "  - ${lf}"
            done
        fi
    } > "$diagnostic"

    # Every required step must literally read "PASS" — computed fresh here,
    # never trusted from an external flag, so a signal delivered outside
    # any step (before the first one, between two, or after the last) can
    # never leave stale SKIPPED steps sitting next to an Overall PASS.
    local steps_ok=1
    for key in "${STEP_ORDER[@]}"; do
        [[ "${STEP_STATE[$key]}" == "PASS" ]] || steps_ok=0
    done
    [[ -n "$DEFERRED_SIGNAL" ]] && steps_ok=0
    (( repo_state_ok )) || steps_ok=0

    {
        print -r -- ""
        print -r -- "## Privacy scan"
        print -r -- ""
        if (( privacy_ok )); then
            print -r -- "Privacy scan: PASS (no /Users, /Volumes, /private/var, /private/tmp, /var, /tmp, repo root, \$HOME, or fixture directory paths found in summary or logs, and the scan itself completed cleanly)"
        else
            print -r -- "Privacy scan: FAIL (see runner-diagnostic.log for affected file names)"
        fi
        print -r -- ""
        if (( steps_ok && privacy_ok )); then
            print -r -- "Overall result: PASS"
        else
            print -r -- "Overall result: FAIL"
        fi
    } >> "$tmp_summary"

    selftest_pause_at "before-mv"

    # Publish loop: closes the race Codex demonstrated against a single
    # "check DEFERRED_SIGNAL, maybe fix, then mv" sequence — a signal that
    # arrives DURING the mv itself (an external command; our trap cannot
    # interrupt it mid-flight, only record DEFERRED_SIGNAL and resume once
    # it returns) previously left a stale "PASS" published with no further
    # check ever running. This loop is a best-effort FAST PATH ONLY — the
    # actual fail-closed guarantee is force_summary_overall_fail plus
    # verify_published_summary below, which never depend on grep, sed, or
    # any external tool's exit code. Three things this loop must never do
    # again (all three were real bugs Codex demonstrated):
    #   - swallow a failing mv with `|| true` and carry on as if it had
    #     published (Codex reproduced "five steps PASS, runner exit 0, no
    #     summary.md" with a fake mv that always exits 1);
    #   - treat a grep exit code of 1 (a real detection) the same as 2+ (the
    #     scan itself failing) — `_privacy_grep_result` is reused here for
    #     exactly the fail-closed interpretation already established for
    #     the privacy scan: only exit 1 means "confirmed clean", 0 and 2+
    #     both mean "must not skip the fix / must not treat as converged";
    #   - call the loop "converged" just because it exited — publish_converged
    #     is ONLY ever set true by the one path that actually confirmed a
    #     clean, published result; a permanently-failing mv, a permanently
    #     failing sed, or a grep that never confirms clean all exhaust the
    #     20-pass cap with publish_converged left false, which is the
    #     explicit fail-closed outcome the cap exists to produce.
    local publish_target="$tmp_summary"
    local publish_pass=0
    local publish_converged=0
    local grep_rc mv_rc
    while (( publish_pass < 20 )); do
        publish_pass=$((publish_pass + 1))

        if [[ -n "$DEFERRED_SIGNAL" ]]; then
            # `cmd; rc=$?` on two lines does NOT shield `cmd` from `set -e`
            # — errexit aborts as soon as the failing command returns,
            # before the next line ever runs to inspect $?. The `&& rc=0
            # || rc=$?` form keeps the whole thing a single `&&`/`||` list,
            # which IS exempt from errexit, while still capturing the real
            # exit code either way (this is exactly the class of bug this
            # round is fixing — grep/mv failures must be observed, not
            # silently abort the script before they can be handled).
            grep -q '^Overall result: PASS$' "$publish_target" 2>/dev/null && grep_rc=0 || grep_rc=$?
            if _privacy_grep_result "$grep_rc"; then
                steps_ok=0
                sed -i '' -e 's/^Overall result: PASS$/Overall result: FAIL/' "$publish_target" 2>/dev/null || true
            fi
        fi

        "${PUBLISH_MV_CMD[@]}" "$publish_target" "$SUMMARY_FILE" 2>/dev/null && mv_rc=0 || mv_rc=$?
        if (( mv_rc != 0 )); then
            continue
        fi
        publish_target="$SUMMARY_FILE"

        if [[ -n "$DEFERRED_SIGNAL" ]]; then
            grep -q '^Overall result: PASS$' "$SUMMARY_FILE" 2>/dev/null && grep_rc=0 || grep_rc=$?
            if _privacy_grep_result "$grep_rc"; then
                continue
            fi
        fi

        publish_converged=1
        break
    done

    # Authoritative correction + postcondition check — pure zsh throughout,
    # so it stays trustworthy even when the fast path above just exhausted
    # its cap because grep, sed, or mv itself is broken. Guarded on
    # DEFERRED_SIGNAL, unlike the unconditional call at the top of
    # handle_terminating_signal: these three calls run on EVERY finalize_run
    # invocation, signal or not, and force_summary_overall_fail has no way
    # to tell "genuinely passed" apart from "PASS that needs correcting"
    # except via DEFERRED_SIGNAL — calling it unconditionally here would
    # wrongly flip an ordinary, uninterrupted PASS run to FAIL.
    if [[ -n "$DEFERRED_SIGNAL" ]]; then
        force_summary_overall_fail || publish_converged=0
    fi

    local publish_ok=0
    if (( publish_converged )) && verify_published_summary "$SUMMARY_FILE"; then
        publish_ok=1
    fi

    {
        print -r -- "Publish: $(( publish_converged )) (1 = the retry loop above confirmed a clean publish within its 20-pass cap, 0 = it did not and the cap was exhausted)"
        print -r -- "Publish result: $(( publish_ok )) (1 = summary.md verified present, readable, exactly one Overall line, and FAIL if a signal was ever deferred; 0 = one of those checks failed)"
    } >> "$diagnostic"

    overall_ok=$(( steps_ok && privacy_ok && publish_ok ))

    selftest_pause_at "after-mv-before-finalized"
    [[ -n "$DEFERRED_SIGNAL" ]] && { force_summary_overall_fail || true }

    if (( publish_ok )); then
        SUMMARY_STATE="finalized"
    fi

    selftest_pause_at "after-finalized"
    [[ -n "$DEFERRED_SIGNAL" ]] && { force_summary_overall_fail || true }

    if (( publish_ok )); then
        print -r -- ""
        print -r -- "Full logs and summary: ${RUN_TREE_NAME}/${RUN_DIR_NAME}"
    else
        print -u2 -r -- "error: failed to publish a valid summary.md after ${publish_pass} attempt(s) (run: ${RUN_TREE_NAME}/${RUN_DIR_NAME})"
    fi
}

# handle_terminating_signal <SIGNAL>
# INT/TERM/HUP must still produce a usable summary.md, and the run must
# always end up FAIL, no matter where in the run the signal actually lands —
# mid-step, in the gap between two steps, or while finalize_run itself is
# already running. `overall_ok=0` is set unconditionally, first thing,
# before even checking whether a step is in flight: a signal arriving
# outside any step (CURRENT_STEP_KEY empty) must never leave overall_ok
# untouched, which is exactly how a run interrupted between steps or during
# finalization could previously still summarize as Overall PASS with every
# remaining step sitting there SKIPPED.
#
# If finalize_run is already running (SUMMARY_STATE == "finalizing"), this
# does none of its own cleanup and does not exit — it only records
# DEFERRED_SIGNAL and returns, letting the interrupted finalize_run resume
# and run to completion (through its atomic mv and privacy scan) rather
# than leaving a half-written tmp file or no summary.md at all. Whichever
# code called finalize_run checks DEFERRED_SIGNAL once it returns and exits
# from there instead of falling through to its normal ending.
handle_terminating_signal() {
    local sig="$1"
    overall_ok=0

    # Unconditional and first thing, regardless of which branch below ends
    # up applying: every one of the four finalize_run publish-sequence
    # checkpoints (finalize-start, before-mv, after-mv-before-finalized,
    # after-finalized) must leave the published summary reading Overall
    # FAIL, including the two AFTER SUMMARY_STATE has already flipped to
    # "finalized" — the earlier architecture treated the process's own exit
    # code as sufficient once finalized, but a signal at any point up
    # through process exit must never leave a PASS-marked artifact sitting
    # on disk. A no-op if $SUMMARY_FILE doesn't exist yet or doesn't
    # currently read PASS.
    force_summary_overall_fail || true

    if [[ "$SUMMARY_STATE" == "finalizing" ]]; then
        [[ -z "$DEFERRED_SIGNAL" ]] && DEFERRED_SIGNAL="$sig"
        return
    fi

    if [[ -n "$CURRENT_STEP_KEY" ]]; then
        local key="$CURRENT_STEP_KEY"
        STEP_STATE[$key]="FAIL (interrupted by ${sig})"
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
            # See run_with_timeout's own timeout branch for why a second,
            # narrowly-scoped rescan happens here before the final KILL.
            if kill -0 "$RUN_WITH_TIMEOUT_PID" 2>/dev/null; then
                local -a fresh
                fresh=("${(f)$(collect_descendant_pids "$RUN_WITH_TIMEOUT_PID")}")
                victims=("${victims[@]}" "${fresh[@]}")
            fi
            signal_pid_list KILL "${victims[@]}"

            # Reap the wrapper subshell — it is this process's own direct
            # child (everything deeper was only ever reachable through it,
            # never `wait`-able by us directly) — before finalize_run runs,
            # so it is never left as a zombie. `wait` returning the
            # torn-down child's own (often nonzero/signal) exit status must
            # not itself be treated as this line failing under `set -e`.
            wait "$RUN_WITH_TIMEOUT_PID" 2>/dev/null || true
            RUN_WITH_TIMEOUT_PID=0
        fi
    fi

    if [[ "$SUMMARY_STATE" != "finalized" ]]; then
        finalize_run
    fi

    if [[ -n "$DEFERRED_SIGNAL" ]]; then
        exit_for_signal "$DEFERRED_SIGNAL"
    fi
    exit_for_signal "$sig"
}

# ---------------------------------------------------------------------------
# run_acceptance_flow — the shared driver: per-run scratch directory setup,
# repo-state capture, signal-trap registration, runner_preflight, the
# fail-fast STEP_ORDER loop (with the self-test-only inter-step pause
# checkpoint), and finalize_run. Used identically by a normal production
# invocation and by __selftest_simulate_steps — the only two differences
# between them are which command resolver COMMAND_RESOLVER names and which
# directory tree RUN_TREE_NAME names, both of which the caller sets BEFORE
# calling this function, never inside it. Returns the process's intended
# exit code (0 or 1); a DEFERRED_SIGNAL is handled by calling
# exit_for_signal directly, since that always terminates the process.
# ---------------------------------------------------------------------------

run_acceptance_flow() {
    if [[ -n "${LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS:-}" ]]; then
        if [[ "${LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS}" == <-> ]] && (( LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS > 0 )); then
            STEP_TIMEOUT_SECONDS=$LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS
        else
            print -u2 -r -- "warning: LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS must be a positive integer; using default ${STEP_TIMEOUT_SECONDS_DEFAULT}s"
        fi
    fi

    # Per-run scratch directory. Exclusive, not `mkdir -p`: two runners
    # started in the same UTC second used to collide on an identical
    # directory name and silently share (and clobber) each other's logs and
    # summary.md. The candidate name folds in this process's own PID and
    # three random components on top of the timestamp, and `mkdir` (no -p)
    # on the leaf component fails atomically if that exact path already
    # exists — the loop below only exists as a defensive retry for the
    # astronomically unlikely case of a collision even with that much
    # entropy, never silently falling back to a shared dir.
    TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p -- "${ROOT_DIR}/${RUN_TREE_NAME}"
    RUN_DIR=""
    local run_dir_attempt=0
    local run_dir_candidate=""
    while (( run_dir_attempt < 20 )); do
        run_dir_candidate="${ROOT_DIR}/${RUN_TREE_NAME}/${TIMESTAMP}-$$-${RANDOM}${RANDOM}${RANDOM}"
        if mkdir -- "$run_dir_candidate" 2>/dev/null; then
            RUN_DIR="$run_dir_candidate"
            break
        fi
        run_dir_attempt=$((run_dir_attempt + 1))
    done
    if [[ -z "$RUN_DIR" ]]; then
        print -u2 -r -- "error: could not create a unique run directory after ${run_dir_attempt} attempts"
        return 1
    fi
    RUN_DIR_NAME="${RUN_DIR:t}"
    SUMMARY_FILE="${RUN_DIR}/summary.md"

    # Repo state at the moment the run starts — compared against the state
    # at finalize_run time.
    START_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || print -r -- unknown)"
    START_FINGERPRINT="$(git_worktree_fingerprint "$ROOT_DIR")" || START_FINGERPRINT=""

    overall_ok=1
    RUNNER_PREFLIGHT_REASON=""

    local local_key=""
    for local_key in "${STEP_ORDER[@]}"; do
        STEP_STATE[$local_key]="SKIPPED (runner interrupted before this step started)"
        STEP_EXITCODE[$local_key]="n/a"
    done

    trap 'handle_terminating_signal INT' INT
    trap 'handle_terminating_signal TERM' TERM
    trap 'handle_terminating_signal HUP' HUP

    if ! runner_preflight; then
        overall_ok=0
        for local_key in "${STEP_ORDER[@]}"; do
            STEP_STATE[$local_key]="SKIPPED (runner preflight failed: ${RUNNER_PREFLIGHT_REASON})"
        done
        finalize_run
        if [[ -n "$DEFERRED_SIGNAL" ]]; then
            exit_for_signal "$DEFERRED_SIGNAL"
        fi
        return 1
    fi

    local blocked=0 blocking_reason="" step_key=""
    for step_key in "${STEP_ORDER[@]}"; do
        if (( blocked )); then
            STEP_STATE[$step_key]="SKIPPED (${blocking_reason})"
            continue
        fi
        if run_step "$step_key"; then
            selftest_pause_at "interstep-after-${step_key}"
        else
            overall_ok=0
            blocked=1
            blocking_reason="${STEP_BLOCK_REASON[$step_key]:-}"
        fi
    done

    finalize_run

    if [[ -n "$DEFERRED_SIGNAL" ]]; then
        exit_for_signal "$DEFERRED_SIGNAL"
    fi

    (( overall_ok )) || return 1
    return 0
}

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

# ===========================================================================
# Self-test. Not a supported CLI flag for normal use — triggered only by
# the explicit argv subcommand `__selftest`, never an environment variable.
# Every case below spawns its simulated runs via spawn_simulated_run, which
# dispatches to __selftest_simulate_steps — never a plain invocation of
# this script, and never via any LUMAHARBOR_IPAD_SELFTEST_* environment
# variable (there is no such mechanism left to use).
# ===========================================================================

typeset -A FASTPASS_CMD
FAIL_WITH_7_HELPER=""
INTERRUPT_ROOT_HELPER=""
INTERRUPT_CHILD_HELPER=""
LAST_SPAWNED_PID=0

# spawn_simulated_run <cmd-strictbuild> <cmd-swifttest> <cmd-simbuild>
#   <cmd-mvppreflight> <cmd-mvpacceptance> [extra __selftest_simulate_steps
#   flags...]
# Backgrounds a fresh subprocess of this script's dedicated simulation
# entry point and sets LAST_SPAWNED_PID to its PID. Runs the background job
# directly in the CALLER's shell (no command-substitution subshell wrapping
# it) so `$!`, captured here, is a real direct child the caller can later
# `wait` on and signal.
spawn_simulated_run() {
    (
        exec "$SCRIPT_PATH" __selftest_simulate_steps "$@"
    ) >/dev/null 2>&1 &
    LAST_SPAWNED_PID=$!
}

# cleanup_signal_case_helper <runner_pid> <root_helper_pid> <leaf_pid> <label>
# The one cleanup path every exit of run_signal_selftest_case (and the
# dedicated ready-handshake-failure case below) funnels through, so no
# return path can skip it. Two independent guarantees, in order:
#   1. If runner_pid is still alive, its ENTIRE current descendant tree is
#      collected fresh (collect_descendant_pids — a one-shot, leaf-first
#      snapshot, the same mechanism the real runner uses on itself) and
#      torn down TERM-then-KILL, then runner_pid itself is wait/reaped —
#      this is what actually prevents a leak on a broken/hung case
#      (ready-timeout or an empty pidfile), where the runner is never
#      signalled by the case itself and so never runs its own cleanup.
#   2. If root_helper_pid and/or leaf_pid are known (read from the
#      pidfiles), each is checked by its own exact PID — never a broad
#      `pgrep -f` name pattern — and force-killed if it somehow survived
#      step 1 (e.g. the runner's OWN signal handler is what was supposed to
#      clean it up, and this is the check that would catch that handler
#      failing to do so).
# Returns non-zero only when step 2 finds and has to force-kill a survivor —
# step 1 succeeding or having nothing to do is never itself a failure.
cleanup_signal_case_helper() {
    local runner_pid="$1" root_helper_pid="$2" leaf_pid="$3" label="$4"
    local ok=1

    if [[ -n "$runner_pid" ]] && kill -0 "$runner_pid" 2>/dev/null; then
        local -a victims
        victims=("${(f)$(collect_descendant_pids "$runner_pid")}")
        signal_pid_list TERM "${victims[@]}"
        local deadline=$((SECONDS + 5))
        while (( SECONDS < deadline )) && ! all_pids_gone "${victims[@]}"; do
            sleep 0.1
        done
        if kill -0 "$runner_pid" 2>/dev/null; then
            local -a fresh
            fresh=("${(f)$(collect_descendant_pids "$runner_pid")}")
            victims=("${victims[@]}" "${fresh[@]}")
        fi
        signal_pid_list KILL "${victims[@]}"
    fi
    if [[ -n "$runner_pid" ]]; then
        wait "$runner_pid" 2>/dev/null || true
    fi

    if [[ -n "$root_helper_pid" || -n "$leaf_pid" ]]; then
        local root_gone=1 leaf_gone=1
        [[ -n "$root_helper_pid" ]] && root_gone=0
        [[ -n "$leaf_pid" ]] && leaf_gone=0
        local survive_deadline=$((SECONDS + 5))
        while (( SECONDS < survive_deadline )); do
            if [[ -n "$root_helper_pid" ]]; then
                kill -0 "$root_helper_pid" 2>/dev/null || root_gone=1
            fi
            if [[ -n "$leaf_pid" ]]; then
                kill -0 "$leaf_pid" 2>/dev/null || leaf_gone=1
            fi
            (( root_gone && leaf_gone )) && break
            sleep 0.1
        done
        if (( root_gone && leaf_gone )); then
            print -r -- "selftest: ${label} -> helper root and leaf both exited (expected): ok"
        else
            print -r -- "selftest: ${label} -> a helper process survived cleanup (root_gone=${root_gone} leaf_gone=${leaf_gone})"
            ok=0
            [[ -n "$root_helper_pid" ]] && { kill -KILL "$root_helper_pid" 2>/dev/null || true }
            [[ -n "$leaf_pid" ]] && { kill -KILL "$leaf_pid" 2>/dev/null || true }
        fi
    fi

    (( ok ))
}

# new_selftest_run_dir <before-dirs-array-name>
# Prints the one directory under SELFTEST_RUN_TREE that exists now but did
# not exist in the array named by $1 (captured by the caller before
# spawning), or nothing if none is found.
new_selftest_run_dir() {
    local -a before=("${(@P)1}")
    local d
    for d in "${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N); do
        if (( ${before[(Ie)$d]} == 0 )); then
            print -r -- "$d"
            return 0
        fi
    done
    return 1
}

# run_signal_selftest_case <target-key> <signal-name> <expected-exit-code>
# Spawns a simulated run with every step up to and including target-key
# substituted for a cheap, controllable command (steps before the target
# get an instant-pass stand-in; the target gets INTERRUPT_ROOT_HELPER, a
# dedicated two-process helper — see its own comment below for why).
# Readiness is a deterministic handshake (a ready file, written only once
# both the helper's root process and its real leaf process have confirmed
# PIDs on disk) rather than any fixed sleep guess. A real OS signal is then
# sent to the runner subprocess itself, and both the resulting summary.md
# and the helper's own two exact PIDs (read back from the pidfiles it
# wrote, never a broad `pgrep -f` pattern match) are checked the same way
# an operator would. Every exit path — ready-timeout, an empty pidfile, or
# the normal post-signal path — funnels through cleanup_signal_case_helper
# before case_tmp is ever removed.
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
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    local -a cmds
    local k
    for k in "${STEP_ORDER[@]}"; do
        if [[ "$k" == "$target_key" ]]; then
            cmds+=("${INTERRUPT_ROOT_HELPER} ${root_pidfile} ${child_pidfile} ${ready_file} ${INTERRUPT_CHILD_HELPER}")
        else
            cmds+=("${FASTPASS_CMD[$k]}")
        fi
    done
    spawn_simulated_run "${cmds[@]}"
    local child_pid=$LAST_SPAWNED_PID

    # Deterministic handshake: the ready file only exists once the helper's
    # root process has confirmed its leaf is alive (see INTERRUPT_ROOT_HELPER's
    # own script body) — never a fixed sleep guess.
    local ready_deadline=$((SECONDS + 20))
    while (( SECONDS < ready_deadline )) && [[ ! -f "$ready_file" ]]; do
        sleep 0.02
    done

    # Read back whatever pidfiles exist regardless of which path this case
    # takes below — even a case that never reaches "ready" may have a
    # partially-written root pidfile, and cleanup_signal_case_helper should
    # verify whatever is actually known.
    local root_helper_pid="" leaf_pid=""
    [[ -s "$root_pidfile" ]] && root_helper_pid="$(<"$root_pidfile")"
    [[ -s "$child_pidfile" ]] && leaf_pid="$(<"$child_pidfile")"

    if [[ ! -f "$ready_file" ]]; then
        print -r -- "selftest: ${label} -> the interrupt-target helper never signalled ready"
        case_failures=$((case_failures + 1))
        cleanup_signal_case_helper "$child_pid" "$root_helper_pid" "$leaf_pid" "$label" || case_failures=$((case_failures + 1))
        rm -rf -- "$case_tmp"
        (( case_failures == 0 ))
        return
    fi

    if [[ -z "$root_helper_pid" || -z "$leaf_pid" ]]; then
        print -r -- "selftest: ${label} -> ready file existed but a pidfile was empty"
        case_failures=$((case_failures + 1))
        cleanup_signal_case_helper "$child_pid" "$root_helper_pid" "$leaf_pid" "$label" || case_failures=$((case_failures + 1))
        rm -rf -- "$case_tmp"
        (( case_failures == 0 ))
        return
    fi

    # The run directory the runner subprocess created — needed to locate
    # summary.md afterward, not for timing (the ready-file wait above
    # already proves the target step is genuinely in flight).
    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""

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
                local found=0 kk downstream_ok=1
                for kk in "${STEP_ORDER[@]}"; do
                    if (( found )); then
                        if ! grep -qF -- "- ${STEP_LABEL[$kk]}: SKIPPED (${reason})" "$summary"; then
                            downstream_ok=0
                        fi
                    fi
                    [[ "$kk" == "$target_key" ]] && found=1
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

    # Final, unconditional cleanup + precise-PID verification. By this point
    # the runner already exited via `wait` above, so step 1 inside the
    # helper is normally a no-op; step 2 is the real assertion here — it is
    # what actually proves handle_terminating_signal cleaned up correctly.
    cleanup_signal_case_helper "$child_pid" "$root_helper_pid" "$leaf_pid" "$label" || case_failures=$((case_failures + 1))

    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_ready_handshake_failure_selftest_case — a deterministic
# failure-path case: the target step's own command hangs (a bare `sleep`,
# never routed through INTERRUPT_ROOT_HELPER) and so can never produce the
# ready-file handshake. Must FAIL within the real, bounded ready-file
# deadline — never hang — and must leave nothing from the runner's process
# tree behind.
run_ready_handshake_failure_selftest_case() {
    local label="ready-handshake failure (strictbuild)"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local ready_file="${case_tmp}/ready"

    spawn_simulated_run "sleep 3600" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local child_pid=$LAST_SPAWNED_PID

    local ready_deadline=$((SECONDS + 20))
    while (( SECONDS < ready_deadline )) && [[ ! -f "$ready_file" ]]; do
        sleep 0.02
    done

    if [[ -f "$ready_file" ]]; then
        print -r -- "selftest: ${label} -> ready file unexpectedly appeared (this case must never produce one)"
        case_failures=$((case_failures + 1))
    else
        print -r -- "selftest: ${label} -> correctly never completed the ready handshake within the deadline (expected): ok"
    fi

    # Snapshot the runner's entire live descendant tree (its bare
    # `sleep 3600` payload included) by exact PID BEFORE any cleanup, via
    # the same pgrep-P-scoped-to-a-known-root walk the runner uses on
    # itself — never a broad process-name pattern — so cleanup can be
    # verified precisely afterward even though no pidfile was ever written
    # for this deliberately-broken case.
    local -a before_cleanup_pids=()
    if kill -0 "$child_pid" 2>/dev/null; then
        before_cleanup_pids=("${(f)$(collect_descendant_pids "$child_pid")}")
    fi

    cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))

    if (( ${#before_cleanup_pids[@]} > 0 )); then
        if all_pids_gone "${before_cleanup_pids[@]}"; then
            print -r -- "selftest: ${label} -> every process in the runner's tree exited after cleanup (expected): ok"
        else
            print -r -- "selftest: ${label} -> at least one process from the runner's tree survived cleanup"
            case_failures=$((case_failures + 1))
        fi
    else
        print -r -- "selftest: ${label} -> the runner subprocess already had no live tree to check (unexpected for this case)"
        case_failures=$((case_failures + 1))
    fi

    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_fastfail_selftest_case — a step fails for an ordinary (non-signal)
# reason; the run must still fail fast, skip every later step with the
# correct reason, and exit 1 (not a signal exit code).
run_fastfail_selftest_case() {
    local case_failures=0
    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "$FAIL_WITH_7_HELPER" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local child_pid=$LAST_SPAWNED_PID
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 1 )); then
        print -r -- "selftest: non-signal failure -> exit 1 (expected): ok"
    else
        print -r -- "selftest: non-signal failure -> exit ${rc}, expected 1"
        case_failures=$((case_failures + 1))
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""
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

# run_fakepass_selftest_case — every step passes via a fast stand-in; the
# run must execute all five in order and report Overall PASS.
run_fakepass_selftest_case() {
    local case_failures=0
    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local child_pid=$LAST_SPAWNED_PID
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 0 )); then
        print -r -- "selftest: fake successful run -> exit 0 (expected): ok"
    else
        print -r -- "selftest: fake successful run -> exit ${rc}, expected 0"
        case_failures=$((case_failures + 1))
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""
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

    if grep -qF -- 'Run mode: SELFTEST' "$summary"; then
        print -r -- "selftest: fake successful run -> summary.md is stamped Run mode: SELFTEST (expected): ok"
    else
        print -r -- "selftest: fake successful run -> summary.md is missing the SELFTEST run-mode stamp"
        case_failures=$((case_failures + 1))
    fi

    (( case_failures == 0 ))
}

# run_missinghelper_selftest_case — a required step command cannot even be
# found (simulating a missing helper). This must surface as FAIL, never as
# a silent skip or an accidental pass.
run_missinghelper_selftest_case() {
    local case_failures=0
    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "/nonexistent/lumaharbor-selftest-missing-helper" "${FASTPASS_CMD[mvpacceptance]}"
    local child_pid=$LAST_SPAWNED_PID
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 1 )); then
        print -r -- "selftest: missing helper -> exit 1 (expected): ok"
    else
        print -r -- "selftest: missing helper -> exit ${rc}, expected 1"
        case_failures=$((case_failures + 1))
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""
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

# run_step_command_for_is_pure_selftest_case — the direct architectural
# proof for the child-marker bypass finding: no matter what
# LUMAHARBOR_IPAD_SELFTEST_* environment variables are set to — including a
# perfectly self-consistent, hand-forged marker/token pair, exactly
# replicating what an attacker with full control over their own invocation
# could construct — step_command_for (the ONLY resolver a plain, zero-argument
# invocation of this script ever uses) returns the five real production
# commands. There is no longer a marker/token check inside
# step_command_for to bypass; this test exists so that if one is ever
# reintroduced, it fails immediately.
run_step_command_for_is_pure_selftest_case() {
    local case_failures=0
    local label="step_command_for ignores every LUMAHARBOR_IPAD_SELFTEST_* variable unconditionally"

    local forged_marker
    forged_marker="$(mktemp)"
    print -rn -- "attacker-chosen-content" > "$forged_marker"

    local k
    for k in "${STEP_ORDER[@]}"; do
        export "LUMAHARBOR_IPAD_SELFTEST_${k:u}_CMD"="true"
    done
    export LUMAHARBOR_IPAD_SELFTEST_CHILD_MARKER="$forged_marker"
    export LUMAHARBOR_IPAD_SELFTEST_CHILD_TOKEN="attacker-chosen-content"

    local all_real=1
    for k in "${STEP_ORDER[@]}"; do
        step_command_for "$k"
        case "$k" in
            strictbuild|swifttest)
                [[ "${STEP_CMD[1]}" == "swift" ]] || all_real=0
                ;;
            simbuild)
                [[ "${STEP_CMD[1]}" == "xcodebuild" ]] || all_real=0
                ;;
            mvppreflight|mvpacceptance)
                [[ "${STEP_CMD[1]}" == "${ROOT_DIR}/Scripts/run-mvp-acceptance.zsh" ]] || all_real=0
                ;;
        esac
    done

    for k in "${STEP_ORDER[@]}"; do
        unset "LUMAHARBOR_IPAD_SELFTEST_${k:u}_CMD"
    done
    unset LUMAHARBOR_IPAD_SELFTEST_CHILD_MARKER LUMAHARBOR_IPAD_SELFTEST_CHILD_TOKEN
    rm -f -- "$forged_marker"

    if (( all_real )); then
        print -r -- "selftest: ${label} -> all five steps used their real production command even with a self-consistent forged credential (expected): ok"
    else
        print -r -- "selftest: ${label} -> at least one step deviated from its real production command"
        case_failures=$((case_failures + 1))
    fi

    (( case_failures == 0 ))
}

# run_timeout_selftest_case — a deterministic, non-signal trigger of
# run_with_timeout's own TIMEOUT_HIT path: strictbuild is given a 1-second
# STEP_TIMEOUT_SECONDS budget (a legitimate, production-facing config knob,
# unrelated to command overrides) and a target that blocks indefinitely.
# Must surface as an ordinary FAIL (exit 1, not a signal exit code), record
# exit 124 for the timed-out step, correctly skip everything after it, and
# leave nothing running.
run_timeout_selftest_case() {
    local label="strictbuild times out"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local root_pidfile="${case_tmp}/root.pid"
    local child_pidfile="${case_tmp}/child.pid"
    local ready_file="${case_tmp}/ready"

    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS=1 \
        spawn_simulated_run "${INTERRUPT_ROOT_HELPER} ${root_pidfile} ${child_pidfile} ${ready_file} ${INTERRUPT_CHILD_HELPER}" \
        "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local child_pid=$LAST_SPAWNED_PID

    local ready_deadline=$((SECONDS + 20))
    while (( SECONDS < ready_deadline )) && [[ ! -f "$ready_file" ]]; do
        sleep 0.02
    done

    local root_helper_pid="" leaf_pid=""
    [[ -s "$root_pidfile" ]] && root_helper_pid="$(<"$root_pidfile")"
    [[ -s "$child_pidfile" ]] && leaf_pid="$(<"$child_pidfile")"

    if [[ ! -f "$ready_file" ]]; then
        print -r -- "selftest: ${label} -> the interrupt-target helper never signalled ready"
        case_failures=$((case_failures + 1))
        cleanup_signal_case_helper "$child_pid" "$root_helper_pid" "$leaf_pid" "$label" || case_failures=$((case_failures + 1))
        rm -rf -- "$case_tmp"
        (( case_failures == 0 ))
        return
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""

    # No signal sent here — the 1-second STEP_TIMEOUT_SECONDS override is
    # what must trip run_with_timeout's own TIMEOUT_HIT path on its own.
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 1 )); then
        print -r -- "selftest: ${label} -> exit code ${rc} (expected 1, an ordinary FAIL, not a signal exit): ok"
    else
        print -r -- "selftest: ${label} -> exit code ${rc}, expected 1"
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
            if grep -qF -- "- ${STEP_LABEL[strictbuild]}: FAIL (timed out after 1s" "$summary"; then
                print -r -- "selftest: ${label} -> timed-out step labelled correctly: ok"
            else
                print -r -- "selftest: ${label} -> timed-out step was not labelled correctly"
                case_failures=$((case_failures + 1))
            fi
            if grep -qF -- '[exit 124]' "$summary"; then
                print -r -- "selftest: ${label} -> step exit code recorded as 124: ok"
            else
                print -r -- "selftest: ${label} -> step exit code was not recorded as 124"
                case_failures=$((case_failures + 1))
            fi
            if grep -qF -- "- ${STEP_LABEL[swifttest]}: SKIPPED (${STEP_BLOCK_REASON[strictbuild]})" "$summary"; then
                print -r -- "selftest: ${label} -> downstream step correctly blames strictbuild: ok"
            else
                print -r -- "selftest: ${label} -> downstream step did not correctly blame strictbuild"
                case_failures=$((case_failures + 1))
            fi
            if has_private_path "$summary"; then
                print -r -- "selftest: ${label} -> summary.md leaked a private absolute path"
                case_failures=$((case_failures + 1))
            else
                print -r -- "selftest: ${label} -> no private path in summary.md (expected): ok"
            fi
        fi
    fi

    cleanup_signal_case_helper "$child_pid" "$root_helper_pid" "$leaf_pid" "$label" || case_failures=$((case_failures + 1))
    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_checkpoint_signal_selftest_case <checkpoint> <signal> <expected-exit>
#   <label-suffix> <expect-overall-fail(0/1)>
# Shared driver for every "signal lands at exactly this checkpoint" case
# (interstep, and the four finalize_run publish-sequence checkpoints):
# spawns a fakepass run with --pause-at=<checkpoint>, waits for the ready
# handshake, signals, releases the pause, and checks exit code plus
# summary.md content. Used by all the checkpoint-specific cases below so
# each one only has to supply what differs.
run_checkpoint_signal_selftest_case() {
    local checkpoint="$1" signal_name="$2" expected_exit="$3" label="$4" expect_fail="$5"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local ready_file="${case_tmp}/ready"
    local go_file="${case_tmp}/go"

    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}" \
        "--pause-at=${checkpoint}" "--pause-ready=${ready_file}" "--pause-go=${go_file}"
    local child_pid=$LAST_SPAWNED_PID

    local ready_deadline=$((SECONDS + 20))
    while (( SECONDS < ready_deadline )) && [[ ! -f "$ready_file" ]]; do
        sleep 0.02
    done

    if [[ ! -f "$ready_file" ]]; then
        print -r -- "selftest: ${label} -> the runner never reached the ${checkpoint} pause"
        case_failures=$((case_failures + 1))
        cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))
        rm -rf -- "$case_tmp"
        (( case_failures == 0 ))
        return
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""

    kill -s "$signal_name" "$child_pid" 2>/dev/null || true
    sleep 0.3
    touch "$go_file"

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
            print -r -- "selftest: ${label} -> summary.md was written (expected): ok"
            if (( expect_fail )); then
                if grep -q '^Overall result: FAIL$' "$summary"; then
                    print -r -- "selftest: ${label} -> Overall result: FAIL (expected): ok"
                else
                    print -r -- "selftest: ${label} -> summary.md incorrectly published Overall PASS"
                    case_failures=$((case_failures + 1))
                fi
            else
                if grep -q '^Overall result: PASS$' "$summary"; then
                    print -r -- "selftest: ${label} -> Overall result: PASS (expected — the signal landed too late to need to change an already-correct, already-published result): ok"
                else
                    print -r -- "selftest: ${label} -> summary.md unexpectedly does not read Overall PASS"
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

    cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))
    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_publish_during_mv_selftest_case — the checkpoint above cannot reach
# "signal arrives while mv itself is executing" (mv is normally
# near-instantaneous). Uses --fake-mv= to substitute a controllable script
# that pauses (ready/go handshake) before actually performing the real
# rename, so a signal can be deterministically landed exactly while
# publishing is "in flight".
run_publish_during_mv_selftest_case() {
    local label="signal TERM while the atomic mv itself is in flight"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local ready_file="${case_tmp}/mv-ready"
    local go_file="${case_tmp}/mv-go"
    local fake_mv="${case_tmp}/fake-mv.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- "touch '${ready_file}'"
        print -r -- "deadline=\$((SECONDS + 30))"
        print -r -- "while (( SECONDS < deadline )) && [[ ! -f '${go_file}' ]]; do sleep 0.02; done"
        print -r -- 'exec mv -f -- "$1" "$2"'
    } > "$fake_mv"
    chmod +x "$fake_mv"

    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}" \
        "--fake-mv=${fake_mv}"
    local child_pid=$LAST_SPAWNED_PID

    local ready_deadline=$((SECONDS + 20))
    while (( SECONDS < ready_deadline )) && [[ ! -f "$ready_file" ]]; do
        sleep 0.02
    done

    if [[ ! -f "$ready_file" ]]; then
        print -r -- "selftest: ${label} -> the fake mv never signalled ready"
        case_failures=$((case_failures + 1))
        cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))
        rm -rf -- "$case_tmp"
        (( case_failures == 0 ))
        return
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""

    kill -s TERM "$child_pid" 2>/dev/null || true
    sleep 0.3
    touch "$go_file"

    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 143 )); then
        print -r -- "selftest: ${label} -> exit code ${rc} (expected 143): ok"
    else
        print -r -- "selftest: ${label} -> exit code ${rc}, expected 143"
        case_failures=$((case_failures + 1))
    fi

    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: ${label} -> no run directory was found for this case"
        case_failures=$((case_failures + 1))
    else
        local summary="${new_dir}/summary.md"
        if [[ ! -f "$summary" ]]; then
            print -r -- "selftest: ${label} -> no summary.md was published despite the fake mv eventually running"
            case_failures=$((case_failures + 1))
        else
            print -r -- "selftest: ${label} -> summary.md was published (expected): ok"
            if grep -q '^Overall result: FAIL$' "$summary"; then
                print -r -- "selftest: ${label} -> Overall result: FAIL (expected — the publish guard loop must have corrected the published file): ok"
            else
                print -r -- "selftest: ${label} -> summary.md incorrectly published Overall PASS despite the signal landing during mv"
                case_failures=$((case_failures + 1))
            fi
            if has_private_path "$summary"; then
                print -r -- "selftest: ${label} -> summary.md leaked a private absolute path"
                case_failures=$((case_failures + 1))
            else
                print -r -- "selftest: ${label} -> no private path in summary.md (expected): ok"
            fi
        fi
    fi

    cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))
    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_publish_mv_permanent_failure_selftest_case — Codex's exact
# reproduction: a `mv` that always fails (disk full, permissions, ...)
# during an otherwise completely normal, uninterrupted, all-five-steps-pass
# run, no signal involved at all. The bug this guards: the old publish step
# swallowed the mv's exit code with `|| true` and carried on as if it had
# published, so the runner reported exit 0 and "all five steps PASS" even
# though summary.md was never actually written anywhere. Must now: exit
# non-zero, and never claim success — here, that means no summary.md at
# all, since the publish never once succeeded.
run_publish_mv_permanent_failure_selftest_case() {
    local label="a permanently-failing mv must not be reported as success"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local fake_mv="${case_tmp}/fake-mv-always-fails.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'exit 1'
    } > "$fake_mv"
    chmod +x "$fake_mv"

    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}" \
        "--fake-mv=${fake_mv}"
    local child_pid=$LAST_SPAWNED_PID
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc != 0 )); then
        print -r -- "selftest: ${label} -> exit ${rc} (expected non-zero): ok"
    else
        print -r -- "selftest: ${label} -> exit 0, expected non-zero"
        case_failures=$((case_failures + 1))
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""
    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: ${label} -> no run directory was found for this case"
        case_failures=$((case_failures + 1))
    else
        local summary="${new_dir}/summary.md"
        if [[ -f "$summary" ]]; then
            if grep -q '^Overall result: PASS$' "$summary"; then
                print -r -- "selftest: ${label} -> summary.md was published showing PASS despite mv never succeeding"
                case_failures=$((case_failures + 1))
            else
                print -r -- "selftest: ${label} -> a summary.md exists but correctly does not read PASS: ok"
            fi
        else
            print -r -- "selftest: ${label} -> no summary.md was published (expected, since mv never once succeeded): ok"
        fi
        local diagnostic="${new_dir}/runner-diagnostic.log"
        if [[ -f "$diagnostic" ]] && grep -q '^Publish result: 0' "$diagnostic"; then
            print -r -- "selftest: ${label} -> runner-diagnostic.log records the publish failure (expected): ok"
        else
            print -r -- "selftest: ${label} -> runner-diagnostic.log does not record the publish failure"
            case_failures=$((case_failures + 1))
        fi
    fi

    cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))
    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# _run_publish_tool_failure_selftest_case <label> <fake-tool-name>
#   <fake-tool-body-lines-as-one-string-with-\n> <diagnostic-publish-marker>
# Shared driver for the three "signal lands, and one of the publish loop's
# own tools (sed / grep / a lying grep) is broken" cases below: installs
# the fake tool at the front of PATH for the spawned child only, pauses at
# the "before-mv" checkpoint (Overall has already been decided as PASS,
# nothing published yet), sends TERM once ready, and checks that the
# process still exits via the signal and the eventually-published
# summary.md still reads Overall FAIL — using verify_published_summary's
# same pure-zsh logic indirectly (grep here is the REAL grep on this
# harness process's own PATH, never the fake one, which is only prepended
# for the spawned child).
_run_publish_tool_failure_selftest_case() {
    local label="$1" tool_name="$2" tool_body="$3" diagnostic_marker="$4"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local fake_bin="${case_tmp}/bin"
    mkdir -p -- "$fake_bin"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- "$tool_body"
    } > "${fake_bin}/${tool_name}"
    chmod +x "${fake_bin}/${tool_name}"

    local ready_file="${case_tmp}/ready"
    local go_file="${case_tmp}/go"

    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    PATH="${fake_bin}:${PATH}" spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}" \
        "--pause-at=before-mv" "--pause-ready=${ready_file}" "--pause-go=${go_file}"
    local child_pid=$LAST_SPAWNED_PID

    local ready_deadline=$((SECONDS + 20))
    while (( SECONDS < ready_deadline )) && [[ ! -f "$ready_file" ]]; do
        sleep 0.02
    done
    if [[ ! -f "$ready_file" ]]; then
        print -r -- "selftest: ${label} -> the runner never reached the before-mv pause"
        case_failures=$((case_failures + 1))
        cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))
        rm -rf -- "$case_tmp"
        (( case_failures == 0 ))
        return
    fi

    kill -s TERM "$child_pid" 2>/dev/null || true
    sleep 0.3
    touch "$go_file"

    local rc=0
    local start=$SECONDS
    wait "$child_pid" 2>/dev/null || rc=$?
    local elapsed=$((SECONDS - start))

    if (( rc == 143 )); then
        print -r -- "selftest: ${label} -> exit code ${rc} (expected 143): ok"
    else
        print -r -- "selftest: ${label} -> exit code ${rc}, expected 143"
        case_failures=$((case_failures + 1))
    fi

    if (( elapsed <= 10 )); then
        print -r -- "selftest: ${label} -> finished within ${elapsed}s, not hung on the broken tool (expected): ok"
    else
        print -r -- "selftest: ${label} -> took ${elapsed}s — the publish loop may not be bounded correctly"
        case_failures=$((case_failures + 1))
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""
    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: ${label} -> no run directory was found for this case"
        case_failures=$((case_failures + 1))
    else
        local summary="${new_dir}/summary.md"
        if [[ -f "$summary" ]] && grep -q '^Overall result: FAIL$' "$summary"; then
            print -r -- "selftest: ${label} -> summary.md was published with Overall result: FAIL despite the broken ${tool_name} (expected): ok"
        else
            print -r -- "selftest: ${label} -> summary.md is missing or does not read Overall FAIL"
            case_failures=$((case_failures + 1))
        fi
        local diagnostic="${new_dir}/runner-diagnostic.log"
        if [[ -f "$diagnostic" ]] && grep -qF -- "$diagnostic_marker" "$diagnostic"; then
            print -r -- "selftest: ${label} -> runner-diagnostic.log shows '${diagnostic_marker}' (expected): ok"
        else
            print -r -- "selftest: ${label} -> runner-diagnostic.log does not show '${diagnostic_marker}'"
            case_failures=$((case_failures + 1))
        fi
    fi

    cleanup_signal_case_helper "$child_pid" "" "" "$label" || case_failures=$((case_failures + 1))
    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_publish_sed_permanent_failure_selftest_case — a signal lands
# (DEFERRED_SIGNAL gets set) while `sed` — the publish loop's own tool for
# correcting an already-decided PASS to FAIL — is permanently broken. The
# fake only intercepts the exact invocation that touches the "Overall
# result: PASS" line (delegating everything else, including redact_file's
# unrelated calls, to the real /usr/bin/sed), isolating this from the
# privacy scan. Must still converge on a published summary.md whose
# Overall line reads FAIL, purely via force_summary_overall_fail's pure-zsh
# fallback, which never shells out to sed at all — and the publish loop's
# own retry bookkeeping must never mistake the broken sed for success (see
# the "Publish: 0" diagnostic assertion below).
run_publish_sed_permanent_failure_selftest_case() {
    _run_publish_tool_failure_selftest_case \
        "signal + permanently-failing sed in the publish loop" \
        "sed" \
        $'for arg in "$@"; do\n    if [[ "$arg" == *"Overall result: PASS"* ]]; then\n        exit 1\n    fi\ndone\nexec /usr/bin/sed "$@"' \
        "Publish: 0"
}

# run_publish_grep_permanent_failure_selftest_case — a signal lands while
# `grep` — used by the publish loop to check whether the file it's about to
# publish (or just published) still says PASS — always returns exit code 2
# (a scan failure, distinct from exit 1's definitive "no match") for
# exactly that check. Exit 2 must never be treated the same as exit 1
# ("confirmed clean"); _privacy_grep_result's fail-closed interpretation is
# reused here for exactly that reason. The fake delegates every other
# invocation (including the privacy scan's own grep calls) to the real
# /usr/bin/grep, isolating this from the (separately, already covered)
# privacy-scan-specific grep failure case.
run_publish_grep_permanent_failure_selftest_case() {
    _run_publish_tool_failure_selftest_case \
        "signal + grep exit 2 in the publish loop" \
        "grep" \
        $'for arg in "$@"; do\n    if [[ "$arg" == \'^Overall result: PASS$\' ]]; then\n        exit 2\n    fi\ndone\nexec /usr/bin/grep "$@"' \
        "Publish: 0"
}

# run_publish_cap_exhausted_selftest_case — a signal lands while `grep`
# unconditionally lies and reports "Overall result: PASS still present"
# (exit 0) for the publish loop's own check, no matter what the file
# actually says. sed and mv are both real, so the file's actual content
# does get corrected to FAIL almost immediately — but the loop's own
# bookkeeping can never confirm that through the lying grep, so it must
# exhaust its full 20-pass cap and treat that exhaustion itself as
# fail-closed (recorded as "Publish: 0" in the diagnostic), regardless of
# what the file happens to already say. force_summary_overall_fail and
# verify_published_summary — both pure zsh, unaffected by the lying grep —
# are what actually guarantee the published file is correct.
run_publish_cap_exhausted_selftest_case() {
    _run_publish_tool_failure_selftest_case \
        "signal + a permanently-lying grep exhausts the publish loop's 20-pass cap" \
        "grep" \
        $'for arg in "$@"; do\n    if [[ "$arg" == \'^Overall result: PASS$\' ]]; then\n        exit 0\n    fi\ndone\nexec /usr/bin/grep "$@"' \
        "Publish: 0"
}

# run_concurrent_runs_selftest_case — two fastpass runners launched back to
# back, virtually guaranteed to land in the same UTC second: must get two
# distinct, exclusively-created run directories, never share or clobber
# one another's logs/summary.md.
run_concurrent_runs_selftest_case() {
    local label="concurrent runs get isolated run directories"
    local case_failures=0

    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local pid_a=$LAST_SPAWNED_PID
    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local pid_b=$LAST_SPAWNED_PID

    local rc_a=0 rc_b=0
    wait "$pid_a" 2>/dev/null || rc_a=$?
    wait "$pid_b" 2>/dev/null || rc_b=$?

    if (( rc_a == 0 && rc_b == 0 )); then
        print -r -- "selftest: ${label} -> both concurrent runs exited 0 (expected): ok"
    else
        print -r -- "selftest: ${label} -> exit codes were ${rc_a} and ${rc_b}, expected 0 and 0"
        case_failures=$((case_failures + 1))
    fi

    local -a new_dirs=()
    local d
    for d in "${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N); do
        if (( ${before_dirs[(Ie)$d]} == 0 )); then
            new_dirs+=("$d")
        fi
    done

    if (( ${#new_dirs[@]} == 2 )); then
        print -r -- "selftest: ${label} -> exactly two new, distinct run directories were created (expected): ok"
    else
        print -r -- "selftest: ${label} -> found ${#new_dirs[@]} new run director(y/ies), expected 2 — a collision would show up as 1"
        case_failures=$((case_failures + 1))
    fi

    local both_pass=1
    for d in "${new_dirs[@]}"; do
        if [[ ! -f "${d}/summary.md" ]] || ! grep -q '^Overall result: PASS$' "${d}/summary.md"; then
            both_pass=0
        fi
    done
    if (( ${#new_dirs[@]} == 2 && both_pass )); then
        print -r -- "selftest: ${label} -> both run directories have their own Overall PASS summary.md: ok"
    else
        print -r -- "selftest: ${label} -> at least one run directory is missing an Overall PASS summary.md"
        case_failures=$((case_failures + 1))
    fi

    (( case_failures == 0 ))
}

# run_isolation_selftest_case — finding 6: verifies simulated runs never
# land under PRODUCTION_RUN_TREE and are always stamped as SELFTEST.
run_isolation_selftest_case() {
    local label="self-test runs are isolated from real acceptance evidence"
    local case_failures=0

    local -a before_prod_dirs
    before_prod_dirs=("${ROOT_DIR}/${PRODUCTION_RUN_TREE}"/*(N))
    local -a before_selftest_dirs
    before_selftest_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    spawn_simulated_run "${FASTPASS_CMD[strictbuild]}" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local child_pid=$LAST_SPAWNED_PID
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    local -a new_prod_dirs=()
    local d
    for d in "${ROOT_DIR}/${PRODUCTION_RUN_TREE}"/*(N); do
        if (( ${before_prod_dirs[(Ie)$d]} == 0 )); then
            new_prod_dirs+=("$d")
        fi
    done
    if (( ${#new_prod_dirs[@]} == 0 )); then
        print -r -- "selftest: ${label} -> no new directory appeared under ${PRODUCTION_RUN_TREE} (expected): ok"
    else
        print -r -- "selftest: ${label} -> a simulated run created ${#new_prod_dirs[@]} director(y/ies) under the PRODUCTION tree"
        case_failures=$((case_failures + 1))
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_selftest_dirs)" || new_dir=""
    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: ${label} -> no run directory was found under ${SELFTEST_RUN_TREE}"
        case_failures=$((case_failures + 1))
    else
        print -r -- "selftest: ${label} -> the simulated run landed under ${SELFTEST_RUN_TREE} (expected): ok"
        if [[ -f "${new_dir}/summary.md" ]] && grep -qF -- 'Run mode: SELFTEST' "${new_dir}/summary.md"; then
            print -r -- "selftest: ${label} -> summary.md is stamped Run mode: SELFTEST (expected): ok"
        else
            print -r -- "selftest: ${label} -> summary.md is missing the SELFTEST run-mode stamp"
            case_failures=$((case_failures + 1))
        fi
    fi

    (( case_failures == 0 ))
}

# run_redaction_failure_selftest_case — an end-to-end simulation of `sed`
# itself failing (disk full, permissions, ...): prepends a scratch bin
# directory containing a fake `sed` that always exits 1 to the child's PATH,
# so every redact_literal/redact_pattern call inside finalize_run fails.
# Must still: complete finalize_run at all (no `set -e` abort), run the
# privacy scan, correctly detect the now-fully-unredacted private path
# still sitting in the log (proving the safety net actually engaged, not
# just that nothing crashed), and report both Privacy scan and Overall as
# FAIL. One step's fake command deliberately writes a real /Users/ path
# into its own log first, specifically so there is something genuine for
# the safety net to have a chance to catch.
run_redaction_failure_selftest_case() {
    local label="redact_file failure (sed unavailable) still completes finalize_run, runs the privacy scan, and reports FAIL"
    local case_failures=0

    local case_tmp
    case_tmp="$(mktemp -d)"
    local fake_bin="${case_tmp}/bin"
    mkdir -p -- "$fake_bin"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'exit 1'
    } > "${fake_bin}/sed"
    chmod +x "${fake_bin}/sed"

    local leak_helper="${case_tmp}/leak-helper.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'print -r -- "note: /Users/someone/leak-marker-for-selftest.txt"'
    } > "$leak_helper"
    chmod +x "$leak_helper"

    local -a before_dirs
    before_dirs=("${ROOT_DIR}/${SELFTEST_RUN_TREE}"/*(N))

    PATH="${fake_bin}:${PATH}" spawn_simulated_run "$leak_helper" "${FASTPASS_CMD[swifttest]}" "${FASTPASS_CMD[simbuild]}" "${FASTPASS_CMD[mvppreflight]}" "${FASTPASS_CMD[mvpacceptance]}"
    local child_pid=$LAST_SPAWNED_PID
    local rc=0
    wait "$child_pid" 2>/dev/null || rc=$?

    if (( rc == 1 )); then
        print -r -- "selftest: ${label} -> exit 1 (expected): ok"
    else
        print -r -- "selftest: ${label} -> exit ${rc}, expected 1"
        case_failures=$((case_failures + 1))
    fi

    local new_dir=""
    new_dir="$(new_selftest_run_dir before_dirs)" || new_dir=""
    if [[ -z "$new_dir" ]]; then
        print -r -- "selftest: ${label} -> no run directory was found for this case"
        case_failures=$((case_failures + 1))
    else
        local summary="${new_dir}/summary.md"
        if [[ ! -f "$summary" ]]; then
            print -r -- "selftest: ${label} -> no summary.md was written despite sed failing (finalize_run must still complete)"
            case_failures=$((case_failures + 1))
        else
            print -r -- "selftest: ${label} -> summary.md was still written despite sed failing (expected): ok"
            if grep -q '^Privacy scan: FAIL' "$summary"; then
                print -r -- "selftest: ${label} -> Privacy scan: FAIL — the safety net actually caught the unredacted leak (expected): ok"
            else
                print -r -- "selftest: ${label} -> Privacy scan did not correctly report FAIL"
                case_failures=$((case_failures + 1))
            fi
            if grep -q '^Overall result: FAIL$' "$summary"; then
                print -r -- "selftest: ${label} -> Overall result: FAIL (expected): ok"
            else
                print -r -- "selftest: ${label} -> summary.md did not report an overall FAIL"
                case_failures=$((case_failures + 1))
            fi
        fi
    fi

    rm -rf -- "$case_tmp"
    (( case_failures == 0 ))
}

# run_privacy_scan_error_selftest_case — a grep failure (exit code >= 2,
# distinct from exit 1's definitive "no match") must be treated as
# not-clean, never as clean. Verified directly against has_private_path
# with a fake, always-failing `grep` shadowing the real one on PATH for
# just this check — a direct, fast unit-style test of the exact function
# this bug lived in.
run_privacy_scan_error_selftest_case() {
    local case_failures=0
    local label="privacy scan treats a grep failure (exit code >= 2) as not-clean"

    local scratch_bin
    scratch_bin="$(mktemp -d)"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'exit 2'
    } > "${scratch_bin}/grep"
    chmod +x "${scratch_bin}/grep"

    local test_file
    test_file="$(mktemp)"
    print -r -- "nothing sensitive in this line at all" > "$test_file"

    local rc=0
    ( PATH="${scratch_bin}:${PATH}"; has_private_path "$test_file" )
    rc=$?

    if (( rc == 0 )); then
        print -r -- "selftest: ${label} -> has_private_path returned 0 (not-clean) when grep itself failed (expected): ok"
    else
        print -r -- "selftest: ${label} -> has_private_path returned ${rc} (treated a grep failure as clean)"
        case_failures=$((case_failures + 1))
    fi

    rm -f -- "$test_file"
    rm -rf -- "$scratch_bin"
    (( case_failures == 0 ))
}

# run_worktree_fingerprint_selftest_case — verifies git_worktree_fingerprint
# discriminates the three cases a bare `git status --porcelain | wc -l`
# comparison is blind to, against a disposable scratch git repo (never the
# real project repo): the same already-dirty file's content changing
# further, one dirty file being reverted while a different one becomes
# dirty instead (same file *count* either way), and a file moving between
# untracked and staged/tracked.
run_worktree_fingerprint_selftest_case() {
    local label="git_worktree_fingerprint detects content-level working-tree changes"
    local case_failures=0

    local scratch_repo
    scratch_repo="$(mktemp -d)"
    (
        cd "$scratch_repo" && \
        git init -q . && \
        git config user.email "selftest@example.com" && \
        git config user.name "selftest" && \
        print -r -- "line one" > tracked.txt && \
        git add tracked.txt && \
        git commit -q -m init
    ) >/dev/null 2>&1

    # Case A: the same dirty file, content changed further.
    print -r -- "line one" > "${scratch_repo}/tracked.txt"
    print -r -- "dirty A" >> "${scratch_repo}/tracked.txt"
    local fp_a fp_a2
    fp_a="$(git_worktree_fingerprint "$scratch_repo")"
    print -r -- "line one" > "${scratch_repo}/tracked.txt"
    print -r -- "dirty A, but different content now" >> "${scratch_repo}/tracked.txt"
    fp_a2="$(git_worktree_fingerprint "$scratch_repo")"
    if [[ -n "$fp_a" && "$fp_a" != "$fp_a2" ]]; then
        print -r -- "selftest: ${label} -> same dirty file, content changed further -> fingerprint changed (expected): ok"
    else
        print -r -- "selftest: ${label} -> same dirty file, content changed further -> fingerprint did NOT change"
        case_failures=$((case_failures + 1))
    fi

    # Case B: dirty file A reverted, a different dirty file B introduced —
    # one dirty file either way, so a bare porcelain-line count could not
    # tell these apart.
    print -r -- "line one" > "${scratch_repo}/tracked.txt"
    print -r -- "second file content" > "${scratch_repo}/other.txt"
    git -C "$scratch_repo" add other.txt >/dev/null 2>&1
    local fp_b
    fp_b="$(git_worktree_fingerprint "$scratch_repo")"
    git -C "$scratch_repo" reset -q -- other.txt >/dev/null 2>&1
    rm -f -- "${scratch_repo}/other.txt"
    print -r -- "line one" > "${scratch_repo}/tracked.txt"
    print -r -- "dirty B instead" >> "${scratch_repo}/tracked.txt"
    local fp_b2
    fp_b2="$(git_worktree_fingerprint "$scratch_repo")"
    if [[ -n "$fp_b" && "$fp_b" != "$fp_b2" ]]; then
        print -r -- "selftest: ${label} -> dirty file A swapped for dirty file B -> fingerprint changed (expected): ok"
    else
        print -r -- "selftest: ${label} -> dirty file A swapped for dirty file B -> fingerprint did NOT change"
        case_failures=$((case_failures + 1))
    fi
    print -r -- "line one" > "${scratch_repo}/tracked.txt"

    # Case C: a file moving between untracked and staged/tracked.
    print -r -- "third file content" > "${scratch_repo}/swap.txt"
    local fp_c_untracked
    fp_c_untracked="$(git_worktree_fingerprint "$scratch_repo")"
    git -C "$scratch_repo" add swap.txt >/dev/null 2>&1
    local fp_c_tracked
    fp_c_tracked="$(git_worktree_fingerprint "$scratch_repo")"
    if [[ -n "$fp_c_untracked" && "$fp_c_untracked" != "$fp_c_tracked" ]]; then
        print -r -- "selftest: ${label} -> untracked file staged (tracked/untracked swap) -> fingerprint changed (expected): ok"
    else
        print -r -- "selftest: ${label} -> tracked/untracked swap -> fingerprint did NOT change"
        case_failures=$((case_failures + 1))
    fi
    git -C "$scratch_repo" reset -q -- swap.txt >/dev/null 2>&1
    rm -f -- "${scratch_repo}/swap.txt"

    rm -rf -- "$scratch_repo"
    (( case_failures == 0 ))
}

# run_worktree_fingerprint_edge_cases_selftest_case — a FIFO, a symlink,
# and a filename containing an embedded newline, all as untracked entries
# in a disposable scratch git repo.
run_worktree_fingerprint_edge_cases_selftest_case() {
    local label="git_worktree_fingerprint handles FIFOs, symlinks, and newline-containing filenames safely"
    local case_failures=0

    local scratch_repo
    scratch_repo="$(mktemp -d)"
    (
        cd "$scratch_repo" && \
        git init -q . && \
        git config user.email "selftest@example.com" && \
        git config user.name "selftest" && \
        print -r -- "line one" > tracked.txt && \
        git add tracked.txt && \
        git commit -q -m init
    ) >/dev/null 2>&1

    # --- FIFO: must not hang (cat-ing a FIFO with no writer blocks forever).
    # Run in a background subprocess with a REAL deadline plus TERM/KILL
    # (the same collect_descendant_pids/signal_pid_list machinery used
    # elsewhere in this file), not just a post-hoc elapsed-time check in
    # this process: if a future regression reintroduces the hang, a bare
    # "$(...)" call here would wedge THIS self-test call forever and take
    # the entire self-test suite down with it. Bounding it in a killable
    # child means a regression fails only this one case.
    mkfifo -- "${scratch_repo}/a-fifo" 2>/dev/null
    local fifo_out="${scratch_repo}/.fifo-fingerprint-output"
    (
        git_worktree_fingerprint "$scratch_repo" > "$fifo_out" 2>/dev/null
    ) &
    local fifo_pid=$!
    local fifo_deadline=$((SECONDS + 10))
    while (( SECONDS < fifo_deadline )) && kill -0 "$fifo_pid" 2>/dev/null; do
        sleep 0.1
    done
    local fifo_hung=0
    if kill -0 "$fifo_pid" 2>/dev/null; then
        fifo_hung=1
        local -a fifo_victims
        fifo_victims=("${(f)$(collect_descendant_pids "$fifo_pid")}")
        signal_pid_list TERM "${fifo_victims[@]}"
        local fifo_waited=0
        while (( fifo_waited < 3 )) && ! all_pids_gone "${fifo_victims[@]}"; do
            sleep 1
            fifo_waited=$((fifo_waited + 1))
        done
        if kill -0 "$fifo_pid" 2>/dev/null; then
            local -a fifo_fresh
            fifo_fresh=("${(f)$(collect_descendant_pids "$fifo_pid")}")
            fifo_victims=("${fifo_victims[@]}" "${fifo_fresh[@]}")
        fi
        signal_pid_list KILL "${fifo_victims[@]}"
    fi
    wait "$fifo_pid" 2>/dev/null || true
    local fifo_fp=""
    [[ -f "$fifo_out" ]] && fifo_fp="$(<"$fifo_out")"
    rm -f -- "$fifo_out"
    if (( ! fifo_hung )) && [[ -n "$fifo_fp" ]]; then
        print -r -- "selftest: ${label} -> an untracked FIFO did not hang the fingerprint (expected): ok"
    else
        print -r -- "selftest: ${label} -> untracked FIFO case hung (killed via TERM/KILL after a 10s deadline) or produced no fingerprint"
        case_failures=$((case_failures + 1))
    fi
    rm -f -- "${scratch_repo}/a-fifo"

    # --- Symlink: changing the TARGET must change the fingerprint, without
    # the function ever needing to read through it. ---
    ln -s -- "/nonexistent-target-one" "${scratch_repo}/a-symlink"
    local fp_link1
    fp_link1="$(git_worktree_fingerprint "$scratch_repo")"
    rm -f -- "${scratch_repo}/a-symlink"
    ln -s -- "/nonexistent-target-two" "${scratch_repo}/a-symlink"
    local fp_link2
    fp_link2="$(git_worktree_fingerprint "$scratch_repo")"
    if [[ -n "$fp_link1" && -n "$fp_link2" && "$fp_link1" != "$fp_link2" ]]; then
        print -r -- "selftest: ${label} -> changing a symlink's target changed the fingerprint (expected): ok"
    else
        print -r -- "selftest: ${label} -> changing a symlink's target did not change the fingerprint"
        case_failures=$((case_failures + 1))
    fi
    rm -f -- "${scratch_repo}/a-symlink"

    # --- Newline-containing filename: must not desynchronize enumeration. ---
    local newline_name=$'weird\nname.txt'
    print -r -- "content one" > "${scratch_repo}/${newline_name}"
    local fp_nl1
    fp_nl1="$(git_worktree_fingerprint "$scratch_repo")"
    print -r -- "content two, different" > "${scratch_repo}/${newline_name}"
    local fp_nl2
    fp_nl2="$(git_worktree_fingerprint "$scratch_repo")"
    if [[ -n "$fp_nl1" && -n "$fp_nl2" && "$fp_nl1" != "$fp_nl2" ]]; then
        print -r -- "selftest: ${label} -> a newline-containing filename's content change still changed the fingerprint (expected): ok"
    else
        print -r -- "selftest: ${label} -> a newline-containing filename case did not behave correctly"
        case_failures=$((case_failures + 1))
    fi
    rm -f -- "${scratch_repo}/${newline_name}"

    rm -rf -- "$scratch_repo"
    (( case_failures == 0 ))
}

# run_worktree_fingerprint_tool_failure_selftest_case — git itself failing
# must fail closed (empty output), never produce a misleadingly-stable hash
# that a start/end comparison could mistake for "unchanged".
run_worktree_fingerprint_tool_failure_selftest_case() {
    local label="git_worktree_fingerprint fails closed (empty) when git itself is unavailable"
    local case_failures=0

    local scratch_repo
    scratch_repo="$(mktemp -d)"
    (
        cd "$scratch_repo" && \
        git init -q . && \
        git config user.email "selftest@example.com" && \
        git config user.name "selftest" && \
        print -r -- "line one" > tracked.txt && \
        git add tracked.txt && \
        git commit -q -m init
    ) >/dev/null 2>&1

    local scratch_bin
    scratch_bin="$(mktemp -d)"
    local fake_git="${scratch_bin}/git"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'exit 1'
    } > "$fake_git"
    chmod +x "$fake_git"

    local fp=""
    fp="$( (PATH="${scratch_bin}:${PATH}"; git_worktree_fingerprint "$scratch_repo") )" || true
    if [[ -z "$fp" ]]; then
        print -r -- "selftest: ${label} -> a failing git produced an empty fingerprint, never a misleadingly-stable hash (expected): ok"
    else
        print -r -- "selftest: ${label} -> a failing git still produced a non-empty fingerprint ('${fp}')"
        case_failures=$((case_failures + 1))
    fi

    rm -rf -- "$scratch_repo" "$scratch_bin"
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

    print -r -- "Executed 0 tests, with 0 failures (0 unexpected) in 0.01 (0.01) seconds" > "${tmp}/zero-executed.log"
    if evaluate_xctest_log "${tmp}/zero-executed.log" >/dev/null; then
        print -r -- "selftest: parser executed-zero -> unexpectedly PASSED (an empty run must never count as a pass)"
        failures=$((failures + 1))
    else
        print -r -- "selftest: parser executed-zero -> FAIL (expected): ok"
    fi

    print -r -- "Executed 1 test, with 0 failures (0 unexpected) in 0.01 (0.01) seconds" > "${tmp}/one-executed.log"
    if evaluate_xctest_log "${tmp}/one-executed.log" >/dev/null; then
        print -r -- "selftest: parser executed-one -> PASS (expected, a real non-empty run): ok"
    else
        print -r -- "selftest: parser executed-one -> unexpectedly FAILED"
        failures=$((failures + 1))
    fi

    # --- Redaction correctness: masks private paths (including ones with
    # embedded spaces, Traditional Chinese, quotes and parens, and the bare
    # /tmp and /var aliases), preserves relative source locations, test
    # counts and error text untouched. ---
    local sample="${tmp}/sample.log"
    {
        print -r -- "error at ${ROOT_DIR}/Sources/Foo.swift:12:5: bad thing happened"
        print -r -- "note: derived data at ${HOME}/Library/Developer/Xcode/DerivedData/Foo-abc123/Build"
        print -r -- "note: external drive /Volumes/SomeDrive/file.ARW"
        print -r -- "note: scratch /private/tmp/abc123/x"
        print -r -- "note: var scratch /private/var/folders/xy/abc/T/thing"
        print -r -- "note: bare tmp alias /tmp/customer-secret/private-photo.ARW"
        print -r -- "note: bare var alias /var/folders/zz/whatever"
        print -r -- 'note: unquoted volume with a space /Volumes/Client Photos/secret.ARW copy failed'
        print -r -- 'note: quoted volume with a space "/Volumes/Client Photos/secret.ARW" copy failed'
        print -r -- "note: unicode volume /Volumes/客戶照片/機密檔案.ARW copy failed"
        print -r -- "note: parens (see /Users/someone/My Documents/notes.txt) for detail"
        print -r -- "Executed 4 tests, with 0 failures (0 unexpected) in 0.01 (0.01) seconds"
    } > "$sample"
    redact_file "$sample"
    local redaction_ok=1
    if has_private_path "$sample"; then
        redaction_ok=0
    fi
    if grep -qF -- 'Client Photos' "$sample" || grep -qF -- 'secret.ARW' "$sample"; then
        redaction_ok=0
    fi
    if grep -qF -- '客戶照片' "$sample" || grep -qF -- '機密檔案' "$sample"; then
        redaction_ok=0
    fi
    if grep -qF -- 'My Documents' "$sample" || grep -qF -- 'notes.txt' "$sample"; then
        redaction_ok=0
    fi
    if grep -qF -- 'customer-secret' "$sample" || grep -qF -- 'private-photo' "$sample"; then
        redaction_ok=0
    fi
    if ! grep -qF -- '<REPO_ROOT>/Sources/Foo.swift:12:5: bad thing happened' "$sample"; then
        redaction_ok=0
    fi
    if ! grep -qF -- 'Executed 4 tests, with 0 failures' "$sample"; then
        redaction_ok=0
    fi
    if (( redaction_ok )); then
        print -r -- "selftest: redaction masks private paths (space/Unicode/quotes/parens/bare-tmp-var-alias included) and preserves counts/relative paths: ok"
    else
        print -r -- "selftest: redaction check FAILED"
        failures=$((failures + 1))
    fi

    rm -rf -- "$tmp"

    # --- xcodebuild missing/failing must never abort finalize_run: verified
    # directly against collect_xcode_version. ---
    local xcode_scratch_bin
    xcode_scratch_bin="$(mktemp -d)"
    local missing_result
    missing_result="$( (PATH="$xcode_scratch_bin"; collect_xcode_version) )"
    if [[ "$missing_result" == "unknown" ]]; then
        print -r -- "selftest: collect_xcode_version with xcodebuild missing -> 'unknown' (expected): ok"
    else
        print -r -- "selftest: collect_xcode_version with xcodebuild missing -> '${missing_result}', expected 'unknown'"
        failures=$((failures + 1))
    fi
    local fake_failing_xcodebuild="${xcode_scratch_bin}/xcodebuild"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'exit 1'
    } > "$fake_failing_xcodebuild"
    chmod +x "$fake_failing_xcodebuild"
    local failing_result
    failing_result="$( (PATH="$xcode_scratch_bin"; collect_xcode_version) )"
    if [[ "$failing_result" == "unknown" ]]; then
        print -r -- "selftest: collect_xcode_version with xcodebuild failing -> 'unknown' (expected): ok"
    else
        print -r -- "selftest: collect_xcode_version with xcodebuild failing -> '${failing_result}', expected 'unknown'"
        failures=$((failures + 1))
    fi
    rm -rf -- "$xcode_scratch_bin"

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
    # below: a real leaf process (not just the wrapper subshell
    # run_with_timeout already forks) whose exact PID is recorded on disk,
    # so a case can assert on precise PIDs instead of a `pgrep -f` name
    # pattern. INTERRUPT_CHILD_HELPER writes its own PID to $1, then execs
    # straight into `sleep` — exec replaces the process image but keeps the
    # same PID, so the PID written to $1 is the PID of the actual process
    # left blocking (the leaf), not a zsh wrapper shell that itself spawns
    # one more, untracked `sleep` underneath it.
    INTERRUPT_CHILD_HELPER="${helper_dir}/interrupt-child.zsh"
    {
        print -r -- '#!/usr/bin/env zsh'
        print -r -- 'print -r -- "$$" > "$1"'
        print -r -- 'exec sleep 3600'
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
        print -r -- 'leaf_pid="$(<"$child_pidfile")"'
        print -r -- 'while ! kill -0 "$leaf_pid" 2>/dev/null; do sleep 0.02; done'
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
    run_ready_handshake_failure_selftest_case || failures=$((failures + 1))
    run_step_command_for_is_pure_selftest_case || failures=$((failures + 1))
    run_timeout_selftest_case || failures=$((failures + 1))

    run_checkpoint_signal_selftest_case "interstep-after-strictbuild" TERM 143 \
        "signal TERM between steps (after strictbuild)" 1 || failures=$((failures + 1))
    run_checkpoint_signal_selftest_case "finalize-start" TERM 143 \
        "signal TERM during finalize_run (right at the start)" 1 || failures=$((failures + 1))
    run_checkpoint_signal_selftest_case "before-mv" TERM 143 \
        "signal TERM after Overall PASS is decided, before the atomic write" 1 || failures=$((failures + 1))
    run_checkpoint_signal_selftest_case "after-mv-before-finalized" TERM 143 \
        "signal TERM after the atomic write, before SUMMARY_STATE=finalized" 1 || failures=$((failures + 1))
    run_checkpoint_signal_selftest_case "after-finalized" TERM 143 \
        "signal TERM after SUMMARY_STATE=finalized, before exit" 1 || failures=$((failures + 1))
    run_publish_during_mv_selftest_case || failures=$((failures + 1))
    run_publish_mv_permanent_failure_selftest_case || failures=$((failures + 1))
    run_publish_sed_permanent_failure_selftest_case || failures=$((failures + 1))
    run_publish_grep_permanent_failure_selftest_case || failures=$((failures + 1))
    run_publish_cap_exhausted_selftest_case || failures=$((failures + 1))

    run_concurrent_runs_selftest_case || failures=$((failures + 1))
    run_isolation_selftest_case || failures=$((failures + 1))
    run_redaction_failure_selftest_case || failures=$((failures + 1))
    run_privacy_scan_error_selftest_case || failures=$((failures + 1))
    run_worktree_fingerprint_selftest_case || failures=$((failures + 1))
    run_worktree_fingerprint_edge_cases_selftest_case || failures=$((failures + 1))
    run_worktree_fingerprint_tool_failure_selftest_case || failures=$((failures + 1))

    rm -rf -- "$helper_dir"

    if (( failures == 0 )); then
        print -r -- "selftest: all cases behaved as expected"
        return 0
    else
        print -r -- "selftest: ${failures} case(s) behaved unexpectedly"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# __selftest_simulate_steps — the dedicated, structurally separate self-test
# simulation entry point (see the header comment for the full rationale).
# Recognized ONLY as the literal first argument. Checked before the
# __selftest dispatch just below for the same reason __selftest itself must
# be an explicit argv subcommand rather than an environment variable: an
# unambiguous, first-argument check always wins over anything a process's
# environment happens to still carry from its parent, the same
# "explicit beats ambient/inherited" principle finding 1 (see below) applies
# to production's own command resolution.
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "__selftest_simulate_steps" ]]; then
    shift
    if (( $# < 5 )); then
        print -u2 -r -- "error: __selftest_simulate_steps requires 5 step commands"
        exit 2
    fi
    SIMULATION_MODE=1
    COMMAND_RESOLVER="selftest_simulated_command_for"
    RUN_TREE_NAME="$SELFTEST_RUN_TREE"
    SIM_CMD[strictbuild]="$1"; shift
    SIM_CMD[swifttest]="$1"; shift
    SIM_CMD[simbuild]="$1"; shift
    SIM_CMD[mvppreflight]="$1"; shift
    SIM_CMD[mvpacceptance]="$1"; shift
    for arg in "$@"; do
        case "$arg" in
            --pause-at=*) SIM_PAUSE_AT="${arg#--pause-at=}" ;;
            --pause-ready=*) SIM_PAUSE_READY_FILE="${arg#--pause-ready=}" ;;
            --pause-go=*) SIM_PAUSE_GO_FILE="${arg#--pause-go=}" ;;
            --fake-mv=*) PUBLISH_MV_CMD=("${arg#--fake-mv=}") ;;
            *)
                print -u2 -r -- "error: unknown __selftest_simulate_steps flag: ${arg}"
                exit 2
                ;;
        esac
    done
    run_acceptance_flow
    exit $?
fi

# __selftest — the ONLY way to invoke run_selftest. Deliberately an
# explicit argv subcommand, not an environment variable (this file used to
# key off LUMAHARBOR_IPAD_RUNNER_SELFTEST=1): an env var set once in an
# interactive debugging session — via `export`, a shell rc file, or simply
# left behind in a long-lived terminal — silently survives into a LATER,
# completely unrelated zero-argument invocation of this same script in that
# same shell, turning what the caller believes is a real production
# acceptance run into a self-test run instead, with no argv-visible sign of
# why. A first-argument check has no such ambient-persistence failure mode:
# every invocation's dispatch is fully determined by what was actually
# typed on that command line.
if [[ "${1:-}" == "__selftest" ]]; then
    shift
    if (( $# > 0 )); then
        print -u2 -r -- "error: __selftest takes no arguments"
        exit 2
    fi
    run_selftest
    exit $?
fi

# ---------------------------------------------------------------------------
# Args — a production run takes none.
# ---------------------------------------------------------------------------

if (( $# > 0 )); then
    print -u2 -r -- "error: unknown argument(s): $*"
    print -u2 -r -- "usage: $0 [__selftest]"
    exit 2
fi

COMMAND_RESOLVER="step_command_for"
RUN_TREE_NAME="$PRODUCTION_RUN_TREE"
run_acceptance_flow
exit $?
