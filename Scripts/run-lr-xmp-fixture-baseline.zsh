#!/bin/zsh
set -euo pipefail

fixture_directory="${LUMAHARBOR_LR_XMP_FIXTURE_DIR:-}"
if [[ -z "$fixture_directory" ]]; then
    print "SKIPPED private Lightroom XMP corpus is not configured"
    exit 0
fi

if [[ ! -d "$fixture_directory" ]]; then
    print "FAIL private Lightroom XMP corpus directory is unavailable"
    exit 1
fi

typeset -a fixture_files
for candidate in "$fixture_directory"/*.xmp(N) "$fixture_directory"/*.XMP(N); do
    [[ -f "$candidate" ]] && fixture_files+=("$candidate")
done

if (( ${#fixture_files} != 5 )); then
    print "FAIL private Lightroom XMP fixture count=${#fixture_files}, expected=5"
    exit 1
fi

export LUMAHARBOR_LR_XMP_FIXTURE_DIR="$fixture_directory"

typeset test_output
if ! test_output="$(swift test --filter LightroomXMPFixtureTests 2>&1)"; then
    print "FAIL private Lightroom XMP fixture preview"
    exit 1
fi

typeset summary
summary="$(print -r -- "$test_output" | awk '/Executed [0-9]+ tests/ { line = $0 } END { print line }')"
if [[ "$summary" != *"Executed 5 tests, with 0 failures"* || "$summary" == *"skipped"* ]]; then
    print "FAIL private Lightroom XMP fixture preview"
    exit 1
fi

print "PASS private Lightroom XMP fixture count=5 preview=PASS report=redacted"
