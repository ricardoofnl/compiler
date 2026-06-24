#!/usr/bin/env bash
#
# Cross compile the Pawn compiler for Android using the NDK.
#
# This produces binaries that run on Android (for example inside Termux) for the
# arm64-v8a, armeabi-v7a and x86_64 ABIs. It is intended for CI and release
# builds; to build directly on a device use build_termux.sh instead.
#
# Prerequisites:
#   - Android NDK r21 or newer.
#   - cmake and ninja (or make) on the build host.
#
# Usage:
#   ANDROID_NDK=/path/to/ndk ./build_android_ndk.sh [BUILD_TYPE] [ABI ...]
#
# BUILD_TYPE defaults to Release. If no ABI is given, all three are built.
# Output for each ABI is placed in build-android/<abi>/.

set -euo pipefail

BUILD_TYPE="Release"
ABIS=()
for arg in "$@"; do
  case "$arg" in
    Debug|Release|RelWithDebInfo|MinSizeRel) BUILD_TYPE="$arg" ;;
    *) ABIS+=("$arg") ;;
  esac
done
if [ "${#ABIS[@]}" -eq 0 ]; then
  ABIS=(arm64-v8a armeabi-v7a x86_64)
fi

# Minimum Android API level. 21 is the lowest level on which the NDK merges
# pthread and dl into libc, matching the link assumptions in CMakeLists.txt.
ANDROID_API="${ANDROID_API:-21}"

NDK="${ANDROID_NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
if [ -z "${NDK}" ]; then
  echo "error: set ANDROID_NDK (or ANDROID_NDK_HOME) to your NDK path" >&2
  exit 1
fi
TOOLCHAIN="${NDK}/build/cmake/android.toolchain.cmake"
if [ ! -f "${TOOLCHAIN}" ]; then
  echo "error: NDK toolchain file not found at ${TOOLCHAIN}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
  GENERATOR="Ninja"
fi

for abi in "${ABIS[@]}"; do
  out="${SCRIPT_DIR}/build-android/${abi}"
  echo "=== Building ${abi} (${BUILD_TYPE}) ==="
  cmake \
    -S "${SCRIPT_DIR}/source/compiler" \
    -B "${out}" \
    -G "${GENERATOR}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DANDROID_ABI="${abi}" \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DBUILD_TESTING=OFF \
    -DCMAKE_C_FLAGS="-DsNAMEMAX=63"
  cmake --build "${out}" --parallel "$(nproc 2>/dev/null || echo 4)"
  echo "--- ${abi} output in ${out} ---"
done

echo
echo "Done."