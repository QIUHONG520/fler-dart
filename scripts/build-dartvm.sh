#!/bin/bash
# ─── Build dartvm.so for Android ARM64 (official Dart GN build) ───
# Part of fler-dart: standalone dartvm.so build system for Fler.
#
# Usage:
#   ./scripts/build-dartvm.sh --dart-version 3.12.2 \
#                              --ndk-path /opt/android-ndk-r27 \
#                              --output-dir ./output
#
# Pipeline:
#   1. gclient sync Dart SDK at target version
#   2. Build Dart VM static lib for Android ARM64 (official GN + Ninja)
#   3. Clone Blutter C++ source
#   4. Cross-compile Capstone static lib for ARM64 (via NDK CMake)
#   5. Compile dartvm.so (Blutter C++ + blutter_entry.cpp + SQLite)

set -euo pipefail

cleanup() {
    local ec=$?
    echo "─── build-dartvm.sh exit code: $ec ───" >&2
}
trap cleanup EXIT

DART_VERSION=""
NDK_PATH="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/output"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT=""
JOBS=$(nproc 2>/dev/null || echo 4)
BLUTTER_REPO="https://github.com/worawit/blutter.git"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dart-version) DART_VERSION="$2"; shift 2 ;;
        --ndk-path) NDK_PATH="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --build-root) BUILD_ROOT="$2"; shift 2 ;;
        *) echo "ERROR: Unknown $1"; exit 1 ;;
    esac
done

if [ -z "$DART_VERSION" ]; then echo "ERROR: --dart-version required"; exit 1; fi
if [ ! -d "$NDK_PATH" ]; then
    echo "ERROR: NDK not found at $NDK_PATH"
    exit 1
fi

if [ -z "$BUILD_ROOT" ]; then
    BUILD_ROOT="$(mktemp -d -t fler-dart-build-XXXXXX)"
    CLEANUP=1
else
    mkdir -p "$BUILD_ROOT"
    CLEANUP=0
fi

TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake"
if [ ! -f "$TOOLCHAIN_FILE" ]; then
    echo "ERROR: NDK toolchain not found at $TOOLCHAIN_FILE"
    exit 1
fi

DART_SDK_DIR="$BUILD_ROOT/dart-sdk/sdk"
BLUTTER_DIR="$BUILD_ROOT/blutter"
CAPSTONE_BUILD_DIR="$BUILD_ROOT/capstone_build"
DARTVM_SO_BUILD_DIR="$BUILD_ROOT/dartvm_so_build"
SQLITE_DIR="$BUILD_ROOT/sqlite"
ARCH_TAG="android_arm64"

echo "════════════════════════════════════════════"
echo " fler-dart: dartvm.so Build (official Dart GN)"
echo " Dart version: $DART_VERSION"
echo " NDK:          $NDK_PATH"
echo " Build root:   $BUILD_ROOT"
echo "════════════════════════════════════════════"

# ═══════════════════════════════════════════════
# Step 1: gclient sync Dart SDK
# ═══════════════════════════════════════════════
echo ""
echo "─── [1/4] Syncing Dart SDK v$DART_VERSION ───"

DART_SDK_ROOT="$BUILD_ROOT/dart-sdk"
if [ ! -d "$DART_SDK_DIR" ]; then
    mkdir -p "$DART_SDK_ROOT"
    cd "$DART_SDK_ROOT"

    # Create .gclient for Android targeting
    cat > .gclient << EOF
solutions = [
  {
    "name": "sdk",
    "url": "https://dart.googlesource.com/sdk.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
  },
]
target_os = ["android"]
EOF

    echo "Running gclient sync (this may take a while on first run)..."
    gclient sync --no-history -j "$JOBS"

    cd sdk
    git fetch --tags
    git checkout "tags/$DART_VERSION"
    cd "$DART_SDK_ROOT"
    gclient sync -D --no-history -j "$JOBS"
else
    echo "Dart SDK already present at $DART_SDK_DIR"
fi

# ═══════════════════════════════════════════════
# Step 1b: Determine version-specific defines
# ═══════════════════════════════════════════════
echo ""
echo "─── [1b] Detecting version-specific defines ───"
VER_MAJOR=$(echo "$DART_VERSION" | cut -d. -f1)
VER_MINOR=$(echo "$DART_VERSION" | cut -d. -f2)

VERSION_DEFINES=""
if [ "$VER_MAJOR" -le 3 ] && [ "$VER_MINOR" -lt 1 ]; then
    VERSION_DEFINES="$VERSION_DEFINES -DOLD_MAP_SET_NAME=ON"
fi
if [ "$VER_MAJOR" -ge 3 ]; then
    VERSION_DEFINES="$VERSION_DEFINES -DHAS_RECORD_TYPE=ON"
fi
if [ "$VER_MAJOR" -ge 3 ] && [ "$VER_MINOR" -ge 6 ]; then
    VERSION_DEFINES="$VERSION_DEFINES -DUNIFORM_INTEGER_ACCESS=ON"
    VERSION_DEFINES="$VERSION_DEFINES -DNO_METHOD_EXTRACTOR_STUB=ON"
fi
if [ "$VER_MAJOR" -ge 2 ] && [ "$VER_MINOR" -ge 16 ]; then
    VERSION_DEFINES="$VERSION_DEFINES -DNO_INIT_LATE_STATIC_FIELD=ON"
fi
echo "Version defines: $VERSION_DEFINES"

# ═══════════════════════════════════════════════
# Step 2: Build Dart VM static lib via official GN
# ═══════════════════════════════════════════════
echo ""
echo "─── [2/4] Building Dart VM static lib (ARM64) ───"

cd "$DART_SDK_DIR"

export ANDROID_NDK_HOME="$NDK_PATH"
export ANDROID_NDK_ROOT="$NDK_PATH"

# Generate GN build files for Android ARM64
DART_BUILD_DIR="out/ReleaseAndroidARM64"

# Dart SDK's GN expects NDK at third_party/android_tools/ndk.
# Create symlink to the system NDK instead of using GN args.
mkdir -p third_party/android_tools
if [ ! -L third_party/android_tools/ndk ]; then
    ln -s "$NDK_PATH" third_party/android_tools/ndk
fi

if [ ! -f "$DART_BUILD_DIR/build.ninja" ]; then
    echo "Generating GN build files..."
    python3 tools/gn.py -m release -a arm64 --os android --no-git-version --no-verify-sdk-hash
fi

echo "Building libdart (finding correct target)..."
# Try known target names; GN outputs vary by configuration
ninja -C "$DART_BUILD_DIR" -j "$JOBS" -t targets all 2>/dev/null | grep -i "libdart" | head -5 || true
DART_TARGET=$(ninja -C "$DART_BUILD_DIR" -j "$JOBS" -t targets all 2>/dev/null | grep -E "^(runtime/|//runtime:)?libdart[^:]*:" | head -1 | cut -d: -f1)
if [ -z "$DART_TARGET" ]; then
    # Fallback: build 'dart' executable which depends on the library
    echo "No libdart target found, building 'dart'..."
    ninja -C "$DART_BUILD_DIR" -j "$JOBS" dart
else
    echo "Using target: $DART_TARGET"
    ninja -C "$DART_BUILD_DIR" -j "$JOBS" "$DART_TARGET"
fi

# Find the static library
DARTVM_LIB=$(find "$DART_BUILD_DIR" -name "libdart*.a" 2>/dev/null | head -1)
if [ -z "$DARTVM_LIB" ]; then
    # Try alternate locations
    DARTVM_LIB=$(find "$DART_BUILD_DIR/obj" -name "libdart*.a" 2>/dev/null | head -1)
fi
if [ -z "$DARTVM_LIB" ]; then
    echo "ERROR: Cannot find libdart*.a in $DART_BUILD_DIR"
    exit 1
fi

echo "Dart VM static lib: $DARTVM_LIB"
echo "  size: $(ls -lh "$DARTVM_LIB" | awk '{print $5}')"

# ═══════════════════════════════════════════════
# Step 2b: Download SQLite amalgamation
# ═══════════════════════════════════════════════
if [ ! -f "$SQLITE_DIR/sqlite3.c" ]; then
    echo "Downloading SQLite amalgamation..."
    mkdir -p "$SQLITE_DIR"
    SQLITE_URL="https://www.sqlite.org/2024/sqlite-amalgamation-3460100.zip"
    curl -sL "$SQLITE_URL" -o "$BUILD_ROOT/sqlite.zip"
    unzip -q -o "$BUILD_ROOT/sqlite.zip" -d "$BUILD_ROOT/sqlite_tmp"
    cp "$BUILD_ROOT"/sqlite_tmp/*/sqlite3.c "$SQLITE_DIR/"
    cp "$BUILD_ROOT"/sqlite_tmp/*/sqlite3.h "$SQLITE_DIR/"
    rm -rf "$BUILD_ROOT/sqlite.zip" "$BUILD_ROOT/sqlite_tmp"
fi

# ═══════════════════════════════════════════════
# Step 2c: Clone Blutter (C++ source only)
# ═══════════════════════════════════════════════
echo ""
echo "─── [2c] Cloning Blutter ───"
if [ ! -d "$BLUTTER_DIR" ]; then
    git clone --depth 1 "$BLUTTER_REPO" "$BLUTTER_DIR"
fi
echo "Blutter: $BLUTTER_DIR"

# ═══════════════════════════════════════════════
# Step 3: Build Capstone static lib for ARM64
# ═══════════════════════════════════════════════
echo ""
echo "─── [3/4] Building Capstone static lib (ARM64) ───"

CAPSTONE_SRC="$BUILD_ROOT/capstone-src"
if [ ! -d "$CAPSTONE_SRC" ]; then
    echo "Downloading Capstone 4.0.2..."
    mkdir -p "$CAPSTONE_SRC"
    curl -sL "https://github.com/capstone-engine/capstone/archive/refs/tags/4.0.2.tar.gz" \
        -o "$BUILD_ROOT/capstone.tar.gz"
    tar xzf "$BUILD_ROOT/capstone.tar.gz" -C "$CAPSTONE_SRC" --strip-components=1
fi
mkdir -p "$CAPSTONE_BUILD_DIR"
cd "$CAPSTONE_BUILD_DIR"
cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_static \
    -DCAPSTONE_BUILD_SHARED=OFF \
    -DCAPSTONE_BUILD_STATIC=ON \
    -DCAPSTONE_ARCHITECTURES="aarch64" \
    "$CAPSTONE_SRC"
cmake --build . -j "$JOBS"
CAPSTONE_LIB=$(find "$CAPSTONE_BUILD_DIR" -name "libcapstone.a" 2>/dev/null | head -1)
CAPSTONE_INCLUDE_DIR="$CAPSTONE_SRC/include/capstone"
echo "Capstone: $CAPSTONE_LIB"

# ═══════════════════════════════════════════════
# Step 4: Build dartvm.so
# ═══════════════════════════════════════════════
echo ""
echo "─── [4/4] Building dartvm.so ───"
mkdir -p "$DARTVM_SO_BUILD_DIR"
cd "$DARTVM_SO_BUILD_DIR"

# Include path: Dart SDK runtime/ provides both <include/xxx.h> and <vm/xxx.h>
DART_INCLUDE_DIR="$DART_SDK_DIR/runtime"

cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_static \
    -DDART_VERSION="$DART_VERSION" \
    -DDART_INCLUDE_DIR="$DART_INCLUDE_DIR" \
    -DDARTVM_STATIC_LIB="$DARTVM_LIB" \
    -DBLUTTER_SRC_DIR="$BLUTTER_DIR/blutter/src" \
    -DCAPSTONE_STATIC_LIB="$CAPSTONE_LIB" \
    -DCAPSTONE_INCLUDE_DIR="$CAPSTONE_INCLUDE_DIR" \
    -DSQLITE_DIR="$SQLITE_DIR" \
    $VERSION_DEFINES \
    "$REPO_DIR/dartvm"

cmake --build . -j "$JOBS"

# ─── Output ───
OUTPUT_FILE="$OUTPUT_DIR/dartvm_${DART_VERSION}_${ARCH_TAG}.so"
mkdir -p "$OUTPUT_DIR"
cp "$DARTVM_SO_BUILD_DIR/libdartvm.so" "$OUTPUT_FILE"

echo ""
echo "════════════════════════════════════════════"
echo " Build complete!"
echo " Output: $OUTPUT_FILE"
echo " Size:   $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
echo " Arch:   $(file "$OUTPUT_FILE")"
echo "════════════════════════════════════════════"
