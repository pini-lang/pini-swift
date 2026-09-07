#!/usr/bin/env bash
# Capability sweep: measure LLVM-backend pass rate over the examples corpus.
# For each .pini file records: emit status, run-llvm status, interpreter status.
# Output: TSV at tools/capability-sweep.tsv (file \t emit \t llvm \t interp \t note)
# Re-run after each grid lands (LLVM rewrite M5) to refresh the matrix.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${PINI_SWEEP_BIN:-$REPO_ROOT/.build/debug/pini}"
OUT="$REPO_ROOT/tools/capability-sweep.tsv"

if [[ ! -x "$BIN" ]]; then
  echo "pini binary not found at $BIN (set PINI_SWEEP_BIN or build --product pini)" >&2
  exit 1
fi

: > "$OUT"
total=0
while IFS= read -r -d '' f; do
  total=$((total + 1))
  rel="${f#"$REPO_ROOT"/}"

  emit_note=""
  llvm_note=""
  if "$BIN" emit "$f" > /dev/null 2> /tmp/cap-emit.err; then
    emit="PASS"
  else
    emit="FAIL"
    emit_note="$(head -c 160 /tmp/cap-emit.err | tr '\n\t' '  ')"
  fi

  if [[ "$emit" == "PASS" ]]; then
    if "$BIN" run-llvm "$f" > /dev/null 2> /tmp/cap-llvm.err; then
      llvm="PASS"
    else
      llvm="FAIL"
      llvm_note="$(head -c 160 /tmp/cap-llvm.err | tr '\n\t' '  ')"
    fi
  else
    llvm="SKIP"
  fi

  if "$BIN" run "$f" > /dev/null 2>&1; then
    interp="PASS"
  else
    interp="FAIL"
  fi

  note="$emit_note"
  [[ -n "$llvm_note" ]] && note="$note | llvm: $llvm_note"
  printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$emit" "$llvm" "$interp" "$note" >> "$OUT"
done < <(find "$REPO_ROOT/examples" -name "*.pini" -not -path "*/selfhost/*" -print0 | sort -z)

echo "swept $total files -> $OUT"
