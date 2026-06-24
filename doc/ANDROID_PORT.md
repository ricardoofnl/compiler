# Android / Termux Port Design

This document describes the plan for building the Pawn Community Compiler on
Android, primarily so it can be compiled and run inside Termux. It also tracks
the findings of the preparation phases.

## Background

The Pawn compiler is a bytecode compiler. Its output (the `.amx` file) is
architecture independent: a compiler built on Android produces the same bytecode
as one built on x86, as long as the cell size and compiler options match. The
porting effort is therefore mostly about compiling the existing C sources under
Termux (bionic libc) rather than about generating code for a new target.

Relevant components:

- `pawncc`: the command line driver.
- `libpawnc`: the compiler core (`sc1.c` through `sc7.c`).
- `pawndisasm`: the AMX disassembler.
- `source/amx/`: the AMX runtime, used by `pawnruns` and the test harness, not by
  the compiler itself.
- `source/linux/`: platform code (`binreloc.c`, `getch.c`, `sclinux.h`).

## Goals

- Support building natively inside Termux (`pkg install clang cmake`).
- Support cross compiling with the Android NDK for `arm64-v8a` (aarch64),
  `armeabi-v7a` (armv7) and `x86_64`.
- Keep `.amx` output byte identical to the official x86 32-bit build, because
  binary compatibility with SA-MP and open.mp toolchains is required.

## Key Obstacles

1. The official build uses `-m32` (x86 32-bit). On a modern Termux device the CPU
   is aarch64 (or armv7), where x86 `-m32` is impossible. The port must build a
   native ARM binary with `PAWN_CELL_SIZE=32` (the default). `amx.h` already
   handles 64-bit hosts and uses `uintptr_t` in its address macros, which is a
   good sign, but the output must be audited and tested for byte equality.
2. On ARM, `char` is unsigned by default, while on x86 it is signed. This is a
   classic source of differences in codepage handling (`sci18n.c`) and EOF
   checks. The plan is to force `-fsigned-char` on ARM so behaviour matches x86.
3. Library linking: bionic folds `pthread` and `dl` into libc, so the existing
   unconditional `link_libraries(pthread)` and `target_link_libraries(... dl)`
   need a guard on Android.

The platform code is otherwise compatible with Termux:

- `binreloc.c` uses `/proc/self/exe` and `/proc/self/maps`, both available on
  Android.
- `getch.c` uses termios and select, both available.
- `sclinux.h` uses `endian.h`, which bionic provides.
- `memfile.h` includes `<malloc.h>`, which bionic provides.
- `SC_FASTCALL` in `sc.h` is only defined for x86 and falls back to empty on ARM.

## Guiding Principle

Because the output must be byte identical, the compiler logic and output format
must not change. Only the build configuration and portability hygiene may change.

Consequences per architecture:

- armv7 (ARM 32-bit) is closest to the official build (32-bit pointers, 32-bit
  cells). It is the easiest path to byte identical output and the safest
  baseline.
- aarch64 and x86_64 are 64-bit hosts with 32-bit cells. They require a
  64-bit cleanliness audit so that no pointer to cell truncation or word-size
  dependent ordering changes the output.

## Phases

### Phase 0: Baseline

Build the official x86 32-bit compiler and capture a set of golden `.amx`
artifacts from reference sources, hashed with SHA-256. These become the
reference for every later build.

### Phase 1: Portability Audit

Review the sources for anything that could change output or break the build on
ARM or on a 64-bit host: char signedness, pointer to integer casts, assumptions
that `sizeof(int) == sizeof(void*)`, structures written directly to the output
file, and any ordering that depends on pointer values.

### Phase 2: CMake Platform Detection

Add Android detection to `source/compiler/CMakeLists.txt`: do not force `-m32`,
add `-fsigned-char`, keep `PAWN_CELL_SIZE=32` and `sNAMEMAX=63`, and guard the
`pthread` and `dl` linking.

### Phase 3: Build Paths

- Native Termux: a `build_termux.sh` script plus documentation.
- NDK cross compile: a script driving the three ABIs, optionally wired into CI.

### Phase 4: Byte Identical Verification

For each architecture, build the compiler, compile the golden sources, and
compare SHA-256 hashes against the Phase 0 reference. Investigate any difference
with `pawndisasm`. armv7 is expected to match first.

### Phase 5: Documentation and Packaging

Add an Android / Termux section to `readme.md` and optionally provide Termux
packaging metadata.

## Files Expected To Change

- `source/compiler/CMakeLists.txt`: Android detection, flags, link guards.
- `build_termux.sh` (new): native Termux build script.
- `build_android_ndk.sh` (new): cross compile script for the three ABIs.
- `.github/workflows/build.yml`: optional Android build job.
- `readme.md`: documentation.
- `source/*.c`: only if the audit finds a portability problem; ideally none.

## Findings

The preparation phases were carried out on an x86_64 Linux host. Because no
aarch64 hardware was available, the two architecture dimensions that ARM
introduces were each isolated and reproduced on x86_64:

- The 64-bit host dimension was tested directly by building a native x86_64
  compiler (64-bit pointers).
- The unsigned `char` default that ARM uses was tested by forcing
  `-funsigned-char` on the x86_64 build.

This makes the results predictive for aarch64 (a 64-bit, unsigned-char target)
and for armv7 (a 32-bit, unsigned-char target).

### Reproduction

All builds were single-command gcc invocations linking the same source set used
by the CMake `libpawnc` plus `pawncc.c` and `../linux/binreloc.c`. The reference
flags matched the official Linux build: `-DLINUX -DENABLE_BINRELOC -DsNAMEMAX=63`
with `PAWN_CELL_SIZE` left at its default (32 under `-m32`). The golden corpus
was every file in `examples/*.p` and `source/compiler/tests/*.pwn` that compiled
cleanly, each compiled with `-d0` and hashed with SHA-256.

### Phase 0 Findings

- The official-equivalent x86 32-bit compiler was built successfully with zero
  warnings.
- 73 reference programs compiled cleanly and were captured as golden artifacts
  with SHA-256 hashes. This is the reference set for all later builds.

### Phase 1 Findings

1. `constexpr` is used as an ordinary identifier (for example the function
   declared at `sc.h:709` and defined in `sc1.c`). In C23 `constexpr` became a
   reserved keyword, so a compiler defaulting to C23 (recent gcc, and possibly
   the clang shipped in current Termux) fails to compile the sources. The fix is
   to build with an older language mode such as `-std=gnu11` or `-std=gnu17`.
   Priority: high, because it is a hard build break independent of architecture.

2. `PAWN_CELL_SIZE` silently defaults to 64 on a 64-bit host. `amx.h` defines
   `__64BIT__` when the pointer is 64-bit (`amx.h:89`), and that selects a 64-bit
   cell (`amx.h:205`). A 64-bit cell changes the on-disk format: the public and
   native record size (`hdr.defsize`, written in `sc6.c`) grows from 8 to 12
   bytes, every offset shifts, and at least one reference program
   (`__emit_pcode_check`) fails to compile at all. The official build avoids this
   only because `-m32` makes the host 32-bit. On aarch64 and x86_64 the build
   must pass `-DPAWN_CELL_SIZE=32` explicitly. armv7 is a 32-bit target and is
   not affected. Priority: critical for the 64-bit targets, since it silently
   produces output that is incompatible with SA-MP and open.mp.

3. With `-DPAWN_CELL_SIZE=32`, a native x86_64 build produces output that is
   byte identical to the x86 32-bit golden set for 72 of 73 programs. The single
   difference is `__timestamp.amx`, which embeds the compile time and was
   confirmed to differ even between two runs of the same binary. This is the
   central result: the output path is 64-bit clean, so a correctly configured
   aarch64 build is expected to be byte identical to the official compiler.

4. Char signedness does not affect the output. An x86_64 build forced to
   `-funsigned-char` (matching the ARM default) produced byte identical output to
   the golden set, apart from the same `__timestamp` file. `-fsigned-char` on ARM
   is therefore a low-cost defensive measure rather than a strict requirement.

5. `SC_FASTCALL` (`sc.h:332`) expands to a `regparm`/`fastcall` attribute on any
   x86 target, including x86_64 where the attribute is ignored and produces
   warnings. The attribute has no effect on output and does not appear on ARM at
   all, where `SC_FASTCALL` expands to nothing. Optional cleanup: restrict it to
   32-bit x86. Not required for the port.

6. `sc1.c:1670` computes `ucharmax` with `1 << (sizeof(cell)-1)*8`, which only
   overflows when the cell is 64-bit. With the 32-bit cell this port uses, the
   expression is well defined and matches the golden output. It is therefore
   benign for the chosen configuration and is another reason 64-bit cells must be
   avoided.

### Phase 2 Findings

`source/compiler/CMakeLists.txt` now detects Android and applies the required
configuration:

- Detection covers both the NDK cross-compile case (the toolchain sets
  `CMAKE_SYSTEM_NAME` to Android) and the native Termux case (the compiler
  predefines `__ANDROID__`, detected with `check_symbol_exists`).
- On Android it adds `-std=gnu11 -fsigned-char`, defines `PAWN_CELL_SIZE=32`,
  and skips the separate `pthread` and `dl` linking, since bionic folds both
  into libc.
- The non-Android path is unchanged.

The change was verified with CMake. On this glibc host the native (non-Android)
configuration reproduces the pre-existing `constexpr` build break, because the
system gcc defaults to C23; this confirms the issue is toolchain driven and not
caused by the CMake change. Configuring with the exact flag set the Android
branch applies builds `pawncc`, `pawndisasm` and `libpawnc.so` cleanly, and the
resulting compiler reproduces the golden set byte for byte (72 of 73, the only
difference being the time-based `__timestamp`). This validates the Android flag
set end to end through the real build system.

### Phase 3 Findings

Two build scripts were added at the repository root:

- `build_termux.sh`: a native in-device build (`pkg install clang cmake make`,
  then configure and build into `build/`).
- `build_android_ndk.sh`: a cross compile driver for `arm64-v8a`,
  `armeabi-v7a` and `x86_64` using the NDK toolchain file, writing per-ABI
  output under `build-android/`. It defaults to API level 21, the lowest level
  on which the NDK merges pthread and dl into libc.

Both scripts pass a shell syntax check. The NDK script could not be executed
here because no NDK is installed; it is structured to fail early with a clear
message if `ANDROID_NDK` is unset or the toolchain file is missing.

### Conclusion For Later Phases

The required build configuration for Android, derived from the findings above,
is: an older C standard (`-std=gnu11`), an explicit 32-bit cell
(`-DPAWN_CELL_SIZE=32`) on 64-bit ABIs, the existing `sNAMEMAX=63`, defensively
`-fsigned-char` on ARM, and a link guard so `pthread` and `dl` are not requested
on bionic. No change to compiler logic is needed to achieve byte identical
output. These requirements drive the CMake work in Phase 2.