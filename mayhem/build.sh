#!/usr/bin/env bash
#
# mayhem/build.sh — builds Alive2's `alive` front end (no LLVM needed: upstream master tracks LLVM
# trunk, which Debian does not package) as
#   1) a sanitized + SanCov-instrumented static library set used by the two fuzz harnesses
#      (build-mayhem/), plus <fuzzer> and <fuzzer>-standalone binaries in /mayhem, and
#   2) a clean, normal-flags `alive` binary (build-tests/) that mayhem/test.sh runs.
# Re-runnable and offline: every dependency (libz3, re2c, cmake) is installed in the image.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# --- 1) sanitized, coverage-instrumented project libraries ---------------------------------------
# -Wno-error: upstream builds with -Wall -Werror against whatever compiler it targets.
FUZZ_CXXFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -Wno-error"
cmake -S . -B build-mayhem -G Ninja \
  -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$FUZZ_CXXFLAGS"
# `alive` pulls in ir/smt/tools/util and generates build-mayhem/tools/alive_lexer.cpp.
cmake --build build-mayhem -j"$MAYHEM_JOBS" --target alive

LIBS=(build-mayhem/libtools.a build-mayhem/libir.a build-mayhem/libsmt.a build-mayhem/libutil.a)
INCS=(-I"$SRC" -Ibuild-mayhem -I"$SRC/mayhem")
CXXSTD=(-std=c++20 -fPIC -fstrict-enums -Wno-error)

# LeakSanitizer off, at build time (docs/rules/c.md).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-mayhem/lsan_off.o
# $STANDALONE_FUZZ_MAIN is C: compile it as C so its LLVMFuzzerTestOneInput reference isn't mangled.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-mayhem/standalone_main.o

PARSER_SRCS=(build-mayhem/tools/alive_lexer.cpp)
for h in alive_parse alive_verify; do
  $CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 "${CXXSTD[@]}" "${INCS[@]}" \
    -c "mayhem/$h.cpp" -o "build-mayhem/$h.o"
  objs=(build-mayhem/$h.o)
  for s in "${PARSER_SRCS[@]}"; do
    o="build-mayhem/$(basename "$s").o"
    if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then
      $CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 "${CXXSTD[@]}" "${INCS[@]}" -c "$s" -o "$o"
    fi
    objs+=("$o")
  done
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${objs[@]}" build-mayhem/lsan_off.o \
    "${LIBS[@]}" -lz3 -o "/mayhem/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${objs[@]}" build-mayhem/lsan_off.o build-mayhem/standalone_main.o \
    "${LIBS[@]}" -lz3 -o "/mayhem/$h-standalone"
done

# --- 2) the project's own test binary, NORMAL flags (honest oracle) --------------------------------
cmake -S . -B build-tests -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_CXX_FLAGS="-Wno-error $COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS" --target alive
