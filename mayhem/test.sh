#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS Alive2's own .opt regression suite (tests/unit) through the `alive` binary
# that mayhem/build.sh built with normal flags (build-tests/alive). It applies the same pass rules as
# upstream's lit format (tests/lit/lit/formats/alive2test.py): a file with `; ERROR: <msg>` must
# print that message, an `; XFAIL:` file is tolerated when it prints its marker, any other file must
# print "Transformation seems to be correct!" for its transforms; SMT timeouts are counted as skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

ALIVE="$SRC/build-tests/alive"
if [ ! -x "$ALIVE" ]; then
  echo "missing $ALIVE — mayhem/build.sh should have built it" >&2
  emit_ctrf alive2-opt 0 1 0
  exit 1
fi

OK_STRING='Transformation seems to be correct!'
passed=0; failed=0; skipped=0

# ---- known-answer probes (unconditional) ---------------------------------------------------------
kat_dir="$(mktemp -d)"
trap 'rm -rf "$kat_dir"' EXIT
printf '%%x = shl i8 %%i, 1\n  =>\n%%x = mul i8 %%i, 2\n' > "$kat_dir/ok.opt"
printf '%%x = shl i8 %%i, 1\n  =>\n%%x = mul i8 %%i, 3\n' > "$kat_dir/bad.opt"
out=$("$ALIVE" -smt-to:5000 "$kat_dir/ok.opt" 2>&1)
if grep -qF "$OK_STRING" <<<"$out" && grep -qF '%x = mul i8 %i, 2' <<<"$out"; then
  passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL KAT shl==mul: $out"; fi
out=$("$ALIVE" -smt-to:5000 "$kat_dir/bad.opt" 2>&1)
if grep -qF 'ERROR: Value mismatch' <<<"$out" && grep -qF 'Example:' <<<"$out" && ! grep -qF "$OK_STRING" <<<"$out"; then
  passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL KAT shl!=mul3: $out"; fi

# ---- tests/unit/**/*.opt (in parallel; each file prints one PASS/FAIL/SKIP verdict line) ----------
run_one() {
  f="$1"
  out=$("$ALIVE" -smt-to:5000 $(sed -n 's/^\(;\|\/\/\)[[:space:]]*TEST-ARGS:\(.*\)$/\2/p' "$f") "$f" 2>&1)
  rc=$?
  xfail=$(sed -n 's/^;[[:space:]]*XFAIL:[[:space:]]*\(.*\)$/\1/p' "$f" | head -1)
  want_err=$(sed -n 's/^;[[:space:]]*\(ERROR:.*\)$/\1/p' "$f" | head -1)
  if [ -n "$xfail" ] && grep -qF -- "$xfail" <<<"$out"; then echo "SKIP $f"; return; fi
  if grep -qF 'ERROR: Timeout' <<<"$out" || grep -qF 'smt tactic failed to show goal to be sat/unsat' <<<"$out"; then
    echo "SKIP $f"; return
  fi
  if [ -n "$want_err" ]; then
    if grep -qF -- "$want_err" <<<"$out"; then echo "PASS $f"; else echo "FAIL $f (expected '$want_err')"; fi
  elif [ "$rc" -eq 0 ] && grep -qF "$OK_STRING" <<<"$out" && ! grep -q 'ERROR:' <<<"$out"; then
    echo "PASS $f"
  else
    echo "FAIL $f (rc=$rc)"
  fi
}
export -f run_one
export ALIVE OK_STRING

verdicts=$(find tests/unit -name '*.opt' | LC_ALL=C sort | xargs -P "${MAYHEM_JOBS:-$(nproc)}" -I{} bash -c 'run_one "$1"' _ {})
passed=$((passed + $(grep -c '^PASS ' <<<"$verdicts")))
skipped=$((skipped + $(grep -c '^SKIP ' <<<"$verdicts")))
nfail=$(grep -c '^FAIL ' <<<"$verdicts")
failed=$((failed + nfail))
grep '^FAIL ' <<<"$verdicts" || true

emit_ctrf alive2-opt "$passed" "$failed" "$skipped"
