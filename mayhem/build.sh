#!/usr/bin/env bash
#
# acpi/mayhem/build.sh — build the ACPI AML interpreter fuzz target as a sanitized libFuzzer binary
# (cargo-fuzz + ASan via RUSTFLAGS, OSS-Fuzz Rust path). The fuzzed code is the `acpi` crate's AML
# bytecode VM (acpi::aml::Interpreter::load_table). Our additive cargo-fuzz crate (mayhem/fuzz/)
# drives that entry point with modern libfuzzer-sys; cargo-fuzz targets it via `--fuzz-dir mayhem/fuzz`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  [ -e "$f" ] || continue
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
TRIPLE="x86_64-unknown-linux-gnu"

# Sanitizer note: cargo-fuzz drives Rust instrumentation through RUSTFLAGS `-Zsanitizer=address`
# (the OSS-Fuzz FUZZING_LANGUAGE=rust path), NOT clang's $SANITIZER_FLAGS / $CFLAGS — those don't
# apply to rustc, so the fuzzed `acpi` crate is sanitized via RUSTFLAGS below, not $SANITIZER_FLAGS.
#
# Debug-info contract (SPEC section 6.2 item 10): thread $RUST_DEBUG_FLAGS so the fuzz binaries carry
# a .debug_info section with DWARF < 4 (Mayhem triage cannot read DWARF >= 4). Default forces DWARF-3
# via rustc (-Zdwarf-version=3, nightly); the base image may override RUST_DEBUG_FLAGS.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS"
# libfuzzer-sys compiles a bundled libFuzzer via the cc crate (clang -> DWARF-5 by default); force
# DWARF-3 on those C/C++ objects too, so NO compilation unit in the linked binary is >= 4 (the
# prebuilt std/asan archives are debug-stripped in the Dockerfile).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

echo "=== cargo fuzz build (image-default nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Force a clean relink so no stale DWARF-5 object lingers from a prior cache (memory: old-rust-dwarf).
rm -rf "$SRC/$FUZZ_DIR/target"
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "/mayhem/${FUZZ_TARGETS[@]}" 2>&1 || true
