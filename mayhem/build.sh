#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: builds the four in-tree libFuzzer harnesses (fuzz/*.cpp, linked against only the parser
# sources they drive, as upstream's `make fuzz` does) with $SANITIZER_FLAGS + $DEBUG_FLAGS, a
# -standalone reproducer per harness, and the interpreter itself with upstream's normal flags for
# mayhem/test.sh. Fully offline and re-runnable.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Sanitized objects. build_fuzz/ is gitignored upstream. Two object sets: the fuzzer set carries
#    libFuzzer's coverage instrumentation, the standalone set must not (no libFuzzer runtime there).
OBJ="$SRC/build_fuzz/obj"
rm -rf "$OBJ"
mkdir -p "$OBJ/fuzzer" "$OBJ/standalone"
CXXF="-std=c++20 -O1 -Wno-deprecated-declarations -D_XOPEN_SOURCE=600 -I$SRC/src"

SOURCES="fuzz/fuzz_json.cpp fuzz/fuzz_yaml.cpp fuzz/fuzz_lex_parse.cpp fuzz/fuzz_bytes_unpack.cpp
fuzz/gc_heap_fuzz.cpp src/builtins/json.cpp src/builtins/yaml.cpp src/builtins/bytes.cpp
src/lexer.cpp src/parser.cpp src/unicode.cpp src/encoding.cpp mayhem/lsan_off.cc"

compile_one() {
  local variant="$1" src="$2" extra=""
  [ "$variant" = fuzzer ] && extra="-fsanitize=fuzzer-no-link"
  # shellcheck disable=SC2086
  $CXX $CXXF $SANITIZER_FLAGS $DEBUG_FLAGS $extra -c "$SRC/$src" \
      -o "$OBJ/$variant/$(echo "${src%.*}" | tr / _).o"
}
export -f compile_one
export OBJ CXXF SRC
for v in fuzzer standalone; do
  for s in $SOURCES; do echo "$v $s"; done
done | xargs -P "$MAYHEM_JOBS" -L1 bash -c 'compile_one "$0" "$1"'

# 2) Link each harness twice: against libFuzzer, and against the run-once standalone driver
#    (compiled as C so its LLVMFuzzerTestOneInput reference keeps C linkage).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

link_target() {
  local name="$1"; shift
  local deps=""
  for d in "$@"; do deps="$deps $d"; done
  local fz="" sa=""
  for d in fuzz_gc_heap_fuzz mayhem_lsan_off $deps; do
    fz="$fz $OBJ/fuzzer/$d.o"; sa="$sa $OBJ/standalone/$d.o"
  done
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/fuzzer/fuzz_fuzz_$name.o" $fz -o "/mayhem/fuzz_$name"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/standalone/fuzz_fuzz_$name.o" $sa "$OBJ/standalone_main.o" -o "/mayhem/fuzz_$name-standalone"
}
link_target json     src_builtins_json
link_target yaml     src_builtins_yaml
link_target lex_parse src_lexer src_parser src_unicode
link_target bytes_unpack src_builtins_bytes src_encoding src_unicode

# 3) The interpreter itself with upstream's normal flags (no sanitizers) — mayhem/test.sh runs its own
#    suite (tests/*.praia) with it. Output: ./praia, build/ (both gitignored upstream).
env -u CXXFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS" OPT="-g $COVERAGE_FLAGS" EXTRA_CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" praia
