#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Upstream's own suite: every tests/*.praia is a standalone script that prints
# "Results: <P> passed, <F> failed, <T> total" via the `testing` grain (and exits non-zero on failure).
# A file that prints no Results line, or exits non-zero, counts as one failure — so a no-op interpreter
# (exit 0, no output) fails every file.
# tests/test_sand_*.praia need the `sand` git submodule (empty in this tree) and the network.
PRAIA="$SRC/praia"
[ -x "$PRAIA" ] || { echo "missing $PRAIA (mayhem/build.sh builds it)" >&2; emit_ctrf "praia-tests" 0 1 0; exit 1; }

export HOME="${TMPDIR:-/tmp}/praia-test-home"; mkdir -p "$HOME"
passed=0; failed=0; skipped=0
for f in tests/test_*.praia; do
  case "$f" in tests/test_sand_*) skipped=$((skipped+1)); continue;; esac
  out="$(timeout 120 "$PRAIA" "$f" 2>&1)"; rc=$?
  read -r p q <<<"$(printf '%s\n' "$out" | awk '/^Results: [0-9]+ passed, [0-9]+ failed/ {p+=$2; q+=$4} END {print p+0, q+0}')"
  if [ -z "$(printf '%s\n' "$out" | grep '^Results: ')" ] || [ "$rc" -ne 0 ] || [ "$q" -ne 0 ]; then
    echo "FAIL $f (rc=$rc, $p passed, $q failed)"; printf '%s\n' "$out" | tail -15
    failed=$((failed+1+q)); passed=$((passed+p))
  else
    passed=$((passed+p))
  fi
done
emit_ctrf "praia-tests" "$passed" "$failed" "$skipped"
