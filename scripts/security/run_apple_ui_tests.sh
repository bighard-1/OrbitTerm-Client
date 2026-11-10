#!/usr/bin/env bash
set -euo pipefail

result_bundle="$1"
shift
test_exit=0
xcodebuild "$@" -resultBundlePath "$result_bundle" || test_exit=$?

if [[ ! -d "$result_bundle" ]]; then
    echo '[FAIL] Apple UI tests did not produce a result bundle' >&2
    if [[ "$test_exit" -ne 0 ]]; then exit "$test_exit"; fi
    exit 1
fi

# xcodebuild -quiet may only print a failing test name. Export the assertion
# evidence before the parent gate cleans its temporary DerivedData directory.
summary="${result_bundle%.xcresult}-summary.json"
tests="${result_bundle%.xcresult}-tests.json"
evidence_exit=0
xcrun xcresulttool get test-results summary --path "$result_bundle" > "$summary" || evidence_exit=$?
xcrun xcresulttool get test-results tests --path "$result_bundle" > "$tests" || evidence_exit=$?
if [[ -n "${ORBITTERM_APPLE_TEST_RESULTS_DIR:-}" ]]; then
    if ! mkdir -p "$ORBITTERM_APPLE_TEST_RESULTS_DIR" ||
        ! cp -R "$result_bundle" "$summary" "$tests" "$ORBITTERM_APPLE_TEST_RESULTS_DIR/"; then
        echo '[FAIL] Could not preserve Apple UI test evidence' >&2
        evidence_exit=1
    fi
fi

# An exporter/copy failure must never turn a failed test into success or hide
# its original exit status. Missing evidence also fails an otherwise green run.
if [[ "$test_exit" -ne 0 ]]; then exit "$test_exit"; fi
if [[ "$evidence_exit" -ne 0 ]]; then exit "$evidence_exit"; fi
