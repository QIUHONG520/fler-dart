#!/bin/bash
# ─── Build dartvm.so for Android ARM64 ───
# Part of fler-dart: standalone dartvm.so build system for Fler.
#
# Usage:
#   ./scripts/build-dartvm.sh --dart-version 3.12.2 \
#                              --ndk-path /opt/android-ndk-r27 \
#                              --output-dir ./output
#
# Pipeline:
#   1. Clone Blutter repo
#   2. Checkout Dart SDK source; dartvm_fetch_build.py builds ARM64 static lib
#      (NDK env vars exported for cross-compilation)
#   3. Verify ARM64 Dart VM static lib from packages/lib/
#      Falls back to GN-based cross-compile if not found or wrong arch
#   4. Cross-compile Capstone static lib for ARM64 (via NDK CMake)
#   5. Compile dartvm.so (Blutter C++ + blutter_entry.cpp + SQLite)
#   6. Strip → output/dartvm_<version>_android_arm64.so

set -euo pipefail

cleanup() {
    local ec=$?
    echo "─── build-dartvm.sh exit code: $ec ───" >&2
}
trap cleanup EXIT

# ═══════════════════════════════════════════════
# Configuration & args
# ═══════════════════════════════════════════════

DART_VERSION=""
NDK_PATH="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/output"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT=""
JOBS=$(nproc 2>/dev/null || echo 4)
BLUTTER_REPO="https://github.com/worawit/blutter.git"
BLUTTER_COMMIT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dart-version) DART_VERSION="$2"; shift 2 ;;
        --ndk-path) NDK_PATH="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --blutter-commit) BLUTTER_COMMIT="$2"; shift 2 ;;
        --build-root) BUILD_ROOT="$2"; shift 2 ;;
        *) echo "ERROR: Unknown $1"; exit 1 ;;
    esac
done

if [ -z "$DART_VERSION" ]; then echo "ERROR: --dart-version required"; exit 1; fi
if [ ! -d "$NDK_PATH" ]; then
    echo "ERROR: NDK not found at $NDK_PATH"
    echo "  Set ANDROID_NDK_HOME or pass --ndk-path"
    exit 1
fi

if [ -z "$BUILD_ROOT" ]; then
    BUILD_ROOT="$(mktemp -d -t fler-dart-build-XXXXXX)"
    CLEANUP=1
else
    mkdir -p "$BUILD_ROOT"
    CLEANUP=0
fi

BLUTTER_DIR="$BUILD_ROOT/blutter"
PACKAGES_DIR="$BLUTTER_DIR/packages"
DARTVM_BUILD_DIR="$BUILD_ROOT/dartvm_build"
CAPSTONE_BUILD_DIR="$BUILD_ROOT/capstone_build"
DARTVM_SO_BUILD_DIR="$BUILD_ROOT/dartvm_so_build"
INSTALL_DIR="$BUILD_ROOT/install"
SQLITE_DIR="$BUILD_ROOT/sqlite"

TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake"
if [ ! -f "$TOOLCHAIN_FILE" ]; then
    echo "ERROR: NDK toolchain not found at $TOOLCHAIN_FILE"
    exit 1
fi

cleanup() { [ "$CLEANUP" = "1" ] && rm -rf "$BUILD_ROOT"; }
trap cleanup EXIT

# ═══════════════════════════════════════════════
# Architecture detection
# ═══════════════════════════════════════════════

USE_NDK=true
ARCH_TAG="android_arm64"
# Must match what dartvm_fetch_build.py generates in packages/
DARTVM_LIB_NAME="dartvm${DART_VERSION}_android_arm64"

echo "════════════════════════════════════════════"
echo " fler-dart: dartvm.so Build"
echo " Dart version: $DART_VERSION"
echo " NDK:          $NDK_PATH"
echo " Build root:   $BUILD_ROOT"
echo "════════════════════════════════════════════"

# ═══════════════════════════════════════════════
# Step 1: Clone Blutter
# ═══════════════════════════════════════════════
echo ""
echo "─── [1/5] Cloning Blutter ───"
if [ -d "$BLUTTER_DIR" ]; then
    echo "Already exists"
else
    git clone --depth 1 "$BLUTTER_REPO" "$BLUTTER_DIR"
    if [ -n "$BLUTTER_COMMIT" ]; then
        cd "$BLUTTER_DIR" && git checkout "$BLUTTER_COMMIT"
    fi
fi
echo "Blutter: $BLUTTER_DIR"

# ═══════════════════════════════════════════════
# Step 2: Checkout Dart SDK sources
# ═══════════════════════════════════════════════
echo ""
echo "─── [2/5] Checking out Dart SDK v${DART_VERSION} ───"
cd "$BLUTTER_DIR"
pip install -q -r requirements.txt 2>/dev/null || true

echo "Exporting NDK for cross-compilation..."
export ANDROID_NDK_HOME="$NDK_PATH"
export ANDROID_NDK_ROOT="$NDK_PATH"
export NDK="$NDK_PATH"
echo "  ANDROID_NDK_HOME=$NDK_PATH"

python3 dartvm_fetch_build.py "$DART_VERSION" android arm64
SDK_DIR="$BLUTTER_DIR/dartsdk/v${DART_VERSION}"
echo "Dart SDK: $SDK_DIR"

# ═══════════════════════════════════════════════
# Step 2b: Determine version-specific defines
# ═══════════════════════════════════════════════
echo ""
echo "─── [2b] Detecting version-specific defines ───"
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
# Step 2c: Download SQLite amalgamation
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
# Step 3: Verify Dart VM ARM64 static lib
# ═══════════════════════════════════════════════
echo ""
echo "─── [3/5] Verifying Dart VM static lib for ARM64 ───"

# Primary: check packages/lib/ for ARM64 .a from dartvm_fetch_build.py
AARCH64_LIB=$(find "$PACKAGES_DIR/lib" -maxdepth 1 -name "*android_arm64*" \( -name "*.a" -o -name "*.so" \) 2>/dev/null | head -1)

if [ -n "$AARCH64_LIB" ]; then
    USE_NDK=true
    ARCH_TAG="android_arm64"
    DARTVM_LIB="$AARCH64_LIB"
    echo "Found ARM64 Dart VM lib from packages/: $DARTVM_LIB"

    # Verify it's actually ARM64
    if command -v file > /dev/null; then
        FILE_OUT=$(file "$DARTVM_LIB" 2>/dev/null || true)
        if echo "$FILE_OUT" | grep -qi "ARM\|aarch64"; then
            echo "  Architecture: ARM64 (verified)"
        elif echo "$FILE_OUT" | grep -qi "x86\|x86-64\|ELF 64-bit"; then
            echo "  WARNING: ${DARTVM_LIB} is x86_64, not ARM64. dartvm_fetch_build.py miscompiled."
            echo "  Attempting fallback GN build..."
            AARCH64_LIB=""
        fi
    fi
fi

# Fallback: try GN-based cross-compile from Dart SDK source
if [ -z "$AARCH64_LIB" ]; then
    echo "ARM64 Dart VM lib not found in packages/. Trying Dart SDK GN build..."
    if [ -d "$SDK_DIR" ] && [ -d "$SDK_DIR/runtime" ]; then
        cd "$SDK_DIR"

        # Check if GN args file already exists (from dartvm_fetch_build.py)
        GN_OUT_DIR=$(find "out" -maxdepth 2 -type f -name "args.gn" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
        if [ -z "$GN_OUT_DIR" ]; then
            # Create our own GN args for Android ARM64
            GN_OUT_DIR="out/android_arm64_release"
            mkdir -p "$GN_OUT_DIR"
            cat > "$GN_OUT_DIR/args.gn" << 'GNARGS'
target_os = "android"
target_cpu = "arm64"
is_debug = false
dart_runtime_mode = "release"
GNARGS
            echo "Created GN args at $GN_OUT_DIR/args.gn"
        else
            echo "Using existing GN out dir: $GN_OUT_DIR"

            # Override key args to ensure ARM64 target
            cat >> "$GN_OUT_DIR/args.gn" << 'GNARGS2'
target_os = "android"
target_cpu = "arm64"
is_debug = false
dart_runtime_mode = "release"
GNARGS2
        fi

        # Try GN + Ninja build
        if command -v gn > /dev/null 2>&1 && command -v ninja > /dev/null 2>&1; then
            echo "Running: gn gen $GN_OUT_DIR"
            gn gen "$GN_OUT_DIR" 2>&1 || {
                echo "WARNING: gn gen failed, trying tools/build.py fallback..."
                GN_OUT_DIR=""
            }

            if [ -n "$GN_OUT_DIR" ]; then
                echo "Running: ninja -C $GN_OUT_DIR libdart_lib_withcore"
                ninja -C "$GN_OUT_DIR" -j "$JOBS" libdart_lib_withcore 2>&1 || true

                DARTVM_LIB=$(find "$GN_OUT_DIR" -name "libdart_lib_withcore*" \( -name "*.a" -o -name "*.so" \) 2>/dev/null | head -1)
                if [ -n "$DARTVM_LIB" ]; then
                    echo "GN build succeeded: $DARTVM_LIB"
                    USE_NDK=true
                    ARCH_TAG="android_arm64"
                fi
            fi
        fi

        # Last resort: try Dart SDK's tools/build.py
        if [ -z "$DARTVM_LIB" ] && [ -f "$SDK_DIR/tools/build.py" ]; then
            echo "Trying: python3 tools/build.py --mode=release --arch=arm64 --os=android runtime"
            cd "$SDK_DIR"
            python3 tools/build.py --mode=release --arch=arm64 --os=android runtime 2>&1 || true

            DARTVM_LIB=$(find "out" -name "*.a" -path "*Release*" -o -name "*.a" -path "*arm64*" 2>/dev/null | head -1)
            if [ -n "$DARTVM_LIB" ]; then
                echo "tools/build.py succeeded: $DARTVM_LIB"
                USE_NDK=true
                ARCH_TAG="android_arm64"
            fi
        fi
    fi
fi

# Fail if we still have no ARM64 lib
if [ -z "$DARTVM_LIB" ]; then
    echo ""
    echo "════════════════════════════════════════════"
    echo " ERROR: Cannot produce ARM64 Dart VM static lib."
    echo ""
    echo " Tried:"
    echo "  1. packages/lib/*android_arm64* from dartvm_fetch_build.py"
    echo "  2. GN + Ninja cross-compile from Dart SDK source"
    echo "  3. tools/build.py cross-compile from Dart SDK source"
    echo ""
    echo " Suggestions:"
    echo "  - Ensure NDK r27+ is properly installed"
    echo "  - Ensure depot_tools (gn, ninja) are available in PATH"
    echo "  - Check Blutter's dartvm_fetch_build.py supports Dart v${DART_VERSION}"
    echo "════════════════════════════════════════════"
    exit 1
fi

echo "Dart VM static lib: $DARTVM_LIB"
echo "Target arch:       $ARCH_TAG"

# ═══════════════════════════════════════════════
# Step 4: Build Capstone static lib
# ═══════════════════════════════════════════════
echo ""
echo "─── [4/5] Finding Capstone ───"

# Capstone is a system dependency on Linux (libcapstone-dev).
# For NDK cross-compile, we download and build from source.
if [ "$USE_NDK" = true ]; then
    echo "Downloading capstone source for NDK cross-compile..."
    CAPSTONE_SRC="$BUILD_ROOT/capstone-src"
    if [ ! -d "$CAPSTONE_SRC" ]; then
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
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCAPSTONE_BUILD_SHARED=OFF \
        -DCAPSTONE_BUILD_STATIC=ON \
        -DCAPSTONE_ARCHITECTURES="aarch64" \
        "$CAPSTONE_SRC"
    cmake --build . -j "$JOBS"
    CAPSTONE_LIB=$(find "$CAPSTONE_BUILD_DIR" -name "libcapstone.a" 2>/dev/null | head -1)
    # Source tree: include/capstone/capstone.h → -I<root>/include/capstone
    CAPSTONE_INCLUDE_DIR="$CAPSTONE_SRC/include/capstone"
else
    echo "Using system capstone..."
    CAPSTONE_LIB=$(pkg-config --variable=libdir capstone 2>/dev/null)
    if [ -n "$CAPSTONE_LIB" ]; then
        CAPSTONE_LIB="$CAPSTONE_LIB/libcapstone.a"
        [ ! -f "$CAPSTONE_LIB" ] && CAPSTONE_LIB=$(pkg-config --libs capstone 2>/dev/null)
    fi
    if [ -z "$CAPSTONE_LIB" ] || [ ! -f "$CAPSTONE_LIB" ]; then
        CAPSTONE_LIB=$(find /usr/lib /usr/local/lib -name "libcapstone.a" 2>/dev/null | head -1)
    fi
    if [ -z "$CAPSTONE_LIB" ]; then
        CAPSTONE_LIB="-lcapstone"
    fi
    # System capstone.h lives in /usr/include/capstone/ or /usr/local/include/capstone/
    CAPSTONE_INCLUDE_DIR=$(pkg-config --cflags-only-I capstone 2>/dev/null | sed 's/-I//')
    if [ -z "$CAPSTONE_INCLUDE_DIR" ] || [ ! -f "$CAPSTONE_INCLUDE_DIR/capstone.h" ]; then
        for dir in /usr/include/capstone /usr/local/include/capstone; do
            if [ -f "$dir/capstone.h" ]; then
                CAPSTONE_INCLUDE_DIR="$dir"
                break
            fi
        done
    fi
    echo "Capstone (system): lib=$CAPSTONE_LIB include=$CAPSTONE_INCLUDE_DIR"
fi

if [ -z "$CAPSTONE_LIB" ]; then
    echo "ERROR: Capstone not found"
    exit 1
fi
echo "Capstone: $CAPSTONE_LIB"

# ═══════════════════════════════════════════════
# Step 5: Build dartvm.so
# ═══════════════════════════════════════════════
echo ""
echo "─── [5/5] Building dartvm.so ───"
mkdir -p "$DARTVM_SO_BUILD_DIR"
cd "$DARTVM_SO_BUILD_DIR"

DARTVM_INCLUDE_DIR="$PACKAGES_DIR/include/$DARTVM_LIB_NAME"
if [ ! -d "$DARTVM_INCLUDE_DIR" ]; then
    DARTVM_INCLUDE_DIR=$(find "$PACKAGES_DIR/include" -maxdepth 1 -type d -name "dartvm*" 2>/dev/null | head -1)
fi
# GN fallback: headers are in the Dart SDK source
if [ ! -d "${DARTVM_INCLUDE_DIR:-}" ] && [ -d "$SDK_DIR/runtime" ]; then
    DARTVM_INCLUDE_DIR="$SDK_DIR/runtime"
fi

if [ ! -d "${CAPSTONE_INCLUDE_DIR:-}" ]; then
    CAPSTONE_INCLUDE_DIR="$BLUTTER_DIR/third_party/capstone/include"
fi
if [ ! -d "${CAPSTONE_INCLUDE_DIR:-}" ]; then
    CAPSTONE_INCLUDE_DIR=$(find "$CAPSTONE_BUILD_DIR" -name "capstone.h" -exec dirname {} \; 2>/dev/null | head -1)
fi
if [ ! -d "${CAPSTONE_INCLUDE_DIR:-}" ]; then
    for dir in /usr/include/capstone /usr/local/include/capstone; do
        if [ -f "$dir/capstone.h" ]; then
            CAPSTONE_INCLUDE_DIR="$dir"
            break
        fi
    done
fi

DARTVM_SO_CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
    -DDART_VERSION="$DART_VERSION"
    -DBLUTTER_SRC_DIR="$BLUTTER_DIR/blutter/src"
    -DDARTVM_PACKAGES="$PACKAGES_DIR"
    -DDARTVM_LIB_NAME="$DARTVM_LIB_NAME"
    -DDARTVM_STATIC_LIB="$DARTVM_LIB"
    -DCAPSTONE_STATIC_LIB="$CAPSTONE_LIB"
    -DCAPSTONE_INCLUDE_DIR="$CAPSTONE_INCLUDE_DIR"
    -DSQLITE_DIR="$SQLITE_DIR"
)
if [ -n "${DARTVM_INCLUDE_DIR:-}" ]; then
    DARTVM_SO_CMAKE_ARGS+=(-DDARTVM_INCLUDE_DIR="$DARTVM_INCLUDE_DIR")
fi
if [ "$USE_NDK" = true ]; then
    DARTVM_SO_CMAKE_ARGS+=(
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE"
        -DANDROID_ABI=arm64-v8a
        -DANDROID_PLATFORM=android-24
        -DANDROID_STL=c++_static
    )
fi

cmake "${DARTVM_SO_CMAKE_ARGS[@]}" $VERSION_DEFINES "$REPO_DIR/dartvm"

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
