#!/data/data/com.termux/files/usr/bin/bash
#
# Build the Pawn compiler natively inside Termux.
#
# Prerequisites (run once):
#   pkg install clang cmake make
#
# Usage:
#   ./build_termux.sh [BUILD_TYPE]
#
# BUILD_TYPE defaults to Release. The resulting binaries (pawncc, pawndisasm and
# libpawnc.so) are placed in the build/ directory.

set -e

BUILD_TYPE="${1:-Release}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

for tool in cmake make; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found. Run: pkg install clang cmake make" >&2
    exit 1
  fi
done

echo "Configuring (${BUILD_TYPE})..."
cmake \
  -S "${SCRIPT_DIR}/source/compiler" \
  -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_C_FLAGS="-DsNAMEMAX=63"

echo "Building..."
cmake --build "${BUILD_DIR}" --parallel "$(nproc)"

echo
echo "Done. Binaries are in ${BUILD_DIR}:"
ls -1 "${BUILD_DIR}/pawncc" "${BUILD_DIR}/pawndisasm" "${BUILD_DIR}"/libpawnc.so 2>/dev/null || true