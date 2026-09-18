#!/usr/bin/env bash
# M6 triage probe (2026-09-10).
# Purpose: measure the HIR channel against the TEST FIXTURE corpus (not just
# examples/) and separate TRUE flip blockers from front-end rejects.
#
#   A true blocker = legacy emit PASSES but HIR emit FAILS
#                    (i.e. a capability HIR lacks, would regress on flip)
#   Not a blocker  = both fail (front-end/checker rejects it; not a backend gap)
#
# Usage: bash tools/m6-triage-probe.sh
#   PINI_SWEEP_BIN overrides the CLI path; requires a build with --product pini.
#   REPO_ROOT overrides the repo location (default: the repo this script sits in,
#   else the pinned absolute path below).
# Output: /tmp/hir-fixture-sweep.tsv, /tmp/m6-blockers.tsv  (regenerated)
set -u

if [[ -z "${REPO_ROOT:-}" ]]; then
  _guess="$(cd "$(dirname "$0")/../../../pini-swift" 2>/dev/null && pwd || true)"
  if [[ -n "$_guess" && -f "$_guess/Package.swift" ]]; then
    REPO_ROOT="$_guess"
  else
    REPO_ROOT="/Volumes/ZWTPSSD/Projects/Pini语言语法与Swift-Package实现_20260827/pini-swift"
  fi
fi
BIN="${PINI_SWEEP_BIN:-/tmp/pini-build/arm64-apple-macosx/debug/pini}"
SWEEP=/tmp/hir-fixture-sweep.tsv
BLOCK=/tmp/m6-blockers.tsv
BUILD_HINT="swift build --disable-sandbox --scratch-path /tmp/pini-build --product pini"

if [[ ! -x "$BIN" ]]; then
  echo "pini binary not found at $BIN — rebuild first:" >&2
  echo "  $BUILD_HINT" >&2
  exit 1
fi

# ---- pass 1: HIR emit over every .pini under Tests/ ----------------------
: > "$SWEEP"
total=0; pass=0; fail=0
while IFS= read -r -d '' f; do
  total=$((total + 1))
  rel="${f#"$REPO_ROOT"/}"
  if "$BIN" emit "$f" > /dev/null 2> /tmp/m6t.err; then
    pass=$((pass + 1))
    printf '%s\tPASS\t\n' "$rel" >> "$SWEEP"
  else
    fail=$((fail + 1))
    msg="$(head -1 /tmp/m6t.err | cut -c1-150 | tr '\n\t' '  ')"
    printf '%s\tFAIL\t%s\n' "$rel" "$msg" >> "$SWEEP"
  fi
done < <(find "$REPO_ROOT/Tests" -name '*.pini' -print0 | sort -z)
echo "pass1 (HIR emit): total=$total pass=$pass fail=$fail"

# Zero corpus is not a clean sweep. This pass reads the test surface, and that
# surface can be emptied by a deletion; "total=0 pass=0 fail=0" then reads
# exactly like a run that found nothing wrong, and the two must not share an
# output shape. Say which one happened.
if [[ "$total" -eq 0 ]]; then
  echo "pass1: NO CORPUS -- 0 .pini under $REPO_ROOT/Tests. Not a pass." >&2
  exit 2
fi

# ---- pass 2: classify each FAIL by the legacy channel --------------------
: > "$BLOCK"
while IFS=$'\t' read -r rel status msg; do
  [[ "$status" == "FAIL" ]] || continue
  if "$BIN" emit "$REPO_ROOT/$rel" > /dev/null 2>&1; then
    printf '%s\tLEGACY_PASS_HIR_FAIL\t%s\n' "$rel" "$msg" >> "$BLOCK"
  else
    printf '%s\tBOTH_FAIL\t%s\n' "$rel" "$msg" >> "$BLOCK"
  fi
done < "$SWEEP"

echo "--- true flip blockers (legacy PASS, HIR FAIL) ---"
grep -c 'LEGACY_PASS_HIR_FAIL' "$BLOCK"
echo "--- failing on both sides (front-end reject, not a backend gap) ---"
grep -c 'BOTH_FAIL' "$BLOCK"
echo "detail -> $SWEEP , $BLOCK"
