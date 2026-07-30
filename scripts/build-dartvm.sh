#!/bin/bash
# ─── Build dartvm.so for Android ARM64 ───
# Part of fler-dart: standalone dartvm.so build system for Fler.
#
# Pipeline:
#   1. Clone Blutter (provides dartvm_fetch_build.py + C++ source)
#   2. Patch Blutter's CMake template for NDK ARM64 cross-compile
#   3. dartvm_fetch_build.py: sparse-checkout Dart SDK → CMake → ARM64 .a
#   4. Cross-compile Capstone static lib for ARM64
#   5. Compile dartvm.so (Blutter C++ + blutter_entry.cpp + SQLite)
#   6. Strip → output/dartvm_<version>_android_arm64.so

set -euo pipefail

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
    echo "ERROR: NDK not found at $NDK_PATH"; exit 1
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
    echo "ERROR: NDK toolchain not found at $TOOLCHAIN_FILE"; exit 1
fi

BLUTTER_DIR="$BUILD_ROOT/blutter"
CAPSTONE_BUILD_DIR="$BUILD_ROOT/capstone_build"
DARTVM_SO_BUILD_DIR="$BUILD_ROOT/dartvm_so_build"
SQLITE_DIR="$BUILD_ROOT/sqlite"
ARCH_TAG="android_arm64"

cleanup() { [ "${CLEANUP:-0}" = "1" ] && rm -rf "$BUILD_ROOT"; }
trap cleanup EXIT

echo "════════════════════════════════════════════"
echo " fler-dart: dartvm.so Build (dartvm_fetch_build.py + NDK)"
echo " Dart version: $DART_VERSION"
echo " NDK:          $NDK_PATH"
echo " Build root:   $BUILD_ROOT"
echo "════════════════════════════════════════════"

# ═══════════════════════════════════════════════
# Step 1: Clone Blutter
# ═══════════════════════════════════════════════
echo ""
echo "─── [1/5] Cloning Blutter ───"
if [ ! -d "$BLUTTER_DIR" ]; then
    git clone --depth 1 "$BLUTTER_REPO" "$BLUTTER_DIR"
fi
echo "Blutter: $BLUTTER_DIR"

# ═══════════════════════════════════════════════
# Step 1b: Patch Blutter source for Dart 3.12.x API compat
# ═══════════════════════════════════════════════
echo ""
echo "─── [1b] Patching Blutter for Dart SDK API compat ───"

BLUTTER_DARTAPP="$BLUTTER_DIR/blutter/src/DartApp.cpp"
if grep -q "closure\.entry_point()" "$BLUTTER_DARTAPP" 2>/dev/null; then
    echo "Patching DartApp.cpp: closure.entry_point() → func.entry_point()"
    python3 -c "
import re
with open('$BLUTTER_DARTAPP', 'r') as f:
    c = f.read()
# Dart 3.12.x: Closure has no entry_point(). Access via the underlying Function.
c, n = re.subn(
    r'const auto ep_addr = closure\.entry_point\(\) - base\(\);'
    r'\s+const auto& func = dart::Function::Handle\(closure\.function\(\)\);',
    r'const auto& func = dart::Function::Handle(closure.function());\n\t\t\tconst auto ep_addr = func.entry_point() - base();',
    c
)
print(f'  DartApp.cpp: {n} occurrences')
with open('$BLUTTER_DARTAPP', 'w') as f:
    f.write(c)
"
fi

BLUTTER_DARTDUMPER="$BLUTTER_DIR/blutter/src/DartDumper.cpp"
if grep -q "closure\.entry_point()" "$BLUTTER_DARTDUMPER" 2>/dev/null; then
    echo "Patching DartDumper.cpp: closure.entry_point() → Function::Handle entry_point()"
    python3 -c "
with open('$BLUTTER_DARTDUMPER', 'r') as f:
    c = f.read()
# closure.function() returns CompressedObjectPtr, not FunctionPtr handle.
# Need Function::Handle to access entry_point().
c = c.replace(
    'closure.entry_point() - app.base()',
    'dart::Function::Handle(closure.function()).entry_point() - app.base()'
)
c = c.replace(
    'closure.entry_point()',
    'dart::Function::Handle(closure.function()).entry_point()'
)
print(f'  DartDumper.cpp patched')
with open('$BLUTTER_DARTDUMPER', 'w') as f:
    f.write(c)
"
fi

# ═══════════════════════════════════════════════
# Step 1c: Inject NDK toolchain + ICU fixes
# ═══════════════════════════════════════════════
echo ""
echo "─── [1c] Injecting NDK into build pipeline ───"

BLUTTER_FETCH="$BLUTTER_DIR/dartvm_fetch_build.py"
BLUTTER_TEMPLATE="$BLUTTER_DIR/scripts/CMakeLists.txt"

# 1. Patch dartvm_fetch_build.py: add -DCMAKE_TOOLCHAIN_FILE to cmake command
if ! grep -q "fler-dart NDK injected" "$BLUTTER_FETCH" 2>/dev/null; then
    echo "Patching dartvm_fetch_build.py..."
    python3 - "$BLUTTER_FETCH" "$NDK_PATH" << 'PYEOF'
import sys
fetch_file = sys.argv[1]
ndk_path = sys.argv[2]
with open(fetch_file, 'r') as f:
    c = f.read()

old = "    subprocess.run([CMAKE_CMD, '-GNinja', '-B', builddir,"
new = ("    # fler-dart NDK injected\n"
       "    tc = '" + ndk_path + "/build/cmake/android.toolchain.cmake'\n"
       "    subprocess.run([CMAKE_CMD, '-GNinja', '-B', builddir,\n"
       "        f'-DCMAKE_TOOLCHAIN_FILE={tc}',\n"
       "        f'-DANDROID_ABI=arm64-v8a', f'-DANDROID_PLATFORM=android-24',\n"
       "        f'-DANDROID_STL=c++_static',")

assert old in c, "Pattern not found in dartvm_fetch_build.py"
c = c.replace(old, new)
print("  dartvm_fetch_build.py: patched OK")
with open(fetch_file, 'w') as f:
    f.write(c)
PYEOF
fi

# 2. Patch CMake template: make ICU optional + Android link flags + atomic_ref
if ! grep -q "fler-dart-patched-v2" "$BLUTTER_TEMPLATE" 2>/dev/null; then
    echo "Patching CMake template..."
    python3 - "$BLUTTER_TEMPLATE" "$BLUTTER_DIR" << 'PYEOF'
import sys
tmpl = sys.argv[1]
blutter_dir = sys.argv[2]
with open(tmpl, 'r') as f:
    c = f.read()

c = c.replace(
    "find_package(ICU REQUIRED uc)",
    "# fler-dart-patched-v2\n# fler-dart: ICU optional\nif(ANDROID)\n    find_package(ICU QUIET)\n    set(ICU_LIBRARIES \"\")\nelse()\n    find_package(ICU REQUIRED uc)\nendif()"
)

c = c.replace(
    "target_compile_options(${LIBNAME} PRIVATE ${cc_opts})",
    "target_compile_options(${LIBNAME} PRIVATE ${cc_opts})\nif(ANDROID)\n    target_compile_options(${LIBNAME} PRIVATE -include \"" + blutter_dir + "/atomic_ref_compat.h\")\nendif()"
)

c = c.replace(
    "if (MSVC)\n\ttarget_link_libraries(${LIBNAME} PUBLIC ${ICU_LIBRARIES})\nelse()\n\ttarget_link_libraries(${LIBNAME} PUBLIC dl pthread ${ICU_LIBRARIES})\nendif()",
    "if(ANDROID)\n\ttarget_link_libraries(${LIBNAME} PUBLIC atomic log ${ICU_LIBRARIES})\nelseif(MSVC)\n\ttarget_link_libraries(${LIBNAME} PUBLIC ${ICU_LIBRARIES})\nelse()\n\ttarget_link_libraries(${LIBNAME} PUBLIC dl pthread ${ICU_LIBRARIES})\nendif()"
)

# 3. Exclude char-predicates.cc (ICU regex) for Android
c = c.replace(
    "include(sourcelist.cmake)",
    "include(sourcelist.cmake)\nif(ANDROID)\n    list(REMOVE_ITEM SRCS \"${SRCDIR}/vm/regexp/char-predicates.cc\")\nendif()"
)

print("  CMake template: patched OK")
with open(tmpl, 'w') as f:
    f.write(c)
PYEOF
fi

# Copy atomic_ref_compat.h to blutter dir (CMake template references it there)
cp "$REPO_DIR/dartvm/src/atomic_ref_compat.h" "$BLUTTER_DIR/" 2>/dev/null || true

# ═══════════════════════════════════════════════
# Step 2: Run dartvm_fetch_build.py (with NDK env)
# ═══════════════════════════════════════════════
echo ""
echo "─── [2/5] Building Dart VM static lib via dartvm_fetch_build.py ───"

cd "$BLUTTER_DIR"
pip install -q -r requirements.txt 2>/dev/null || true

echo "Exporting NDK for dartvm_fetch_build.py..."
export ANDROID_NDK_HOME="$NDK_PATH"
export ANDROID_NDK_ROOT="$NDK_PATH"
export FLER_NDK="$NDK_PATH"

# Determine snapshot hash from installed packages for cache key
SNAPSHOT_HASH=""
DARMVM_LIB_NAME="dartvm${DART_VERSION}_android_arm64"
PACKAGES_DIR="$BLUTTER_DIR/packages"
PACKAGES_LIB="$PACKAGES_DIR/lib/$DARMVM_LIB_NAME/lib$DARMVM_LIB_NAME.a"

DARTVM_LIB=""
DARTVM_INCLUDE_DIR=""

# Use cached .a only if it is already ARM64
if [ -f "$PACKAGES_LIB" ] && command -v file > /dev/null; then
    FILE_OUT=$(file "$PACKAGES_LIB" 2>/dev/null || true)
    if echo "$FILE_OUT" | grep -qi "ARM\|aarch64"; then
        echo "Pre-built ARM64 Dart VM lib found: $PACKAGES_LIB"
        DARTVM_LIB="$PACKAGES_LIB"
        DARTVM_INCLUDE_DIR="$PACKAGES_DIR/include/$DARMVM_LIB_NAME"
    else
        echo "Cached lib is not ARM64, will rebuild: $FILE_OUT"
    fi
fi

if [ -z "$DARTVM_LIB" ]; then
    echo "Running dartvm_fetch_build.py $DART_VERSION android arm64..."

# Remove stale host-arch build and lib (force rebuild with NDK toolchain)
BLUTTER_BUILD_DIR="$BLUTTER_DIR/build"
if [ -d "$BLUTTER_BUILD_DIR" ]; then
    echo "Removing stale build dir: $BLUTTER_BUILD_DIR"
    rm -rf "$BLUTTER_BUILD_DIR"
fi
if [ -f "$PACKAGES_LIB" ]; then
    echo "Removing stale cached lib: $PACKAGES_LIB"
    rm -f "$PACKAGES_DIR/lib/$DARMVM_LIB_NAME"/*.a
fi

python3 dartvm_fetch_build.py "$DART_VERSION" android arm64

    DARTVM_LIB=$(find "$PACKAGES_DIR/lib" -name "*.a" 2>/dev/null | head -1 || true)
    DARTVM_INCLUDE_DIR=$(find "$PACKAGES_DIR/include" -maxdepth 1 -type d -name "dartvm*" 2>/dev/null | head -1 || true)
fi

if [ -z "$DARTVM_LIB" ] || [ ! -f "$DARTVM_LIB" ]; then
    echo "ERROR: Dart VM static lib not found in packages/lib/"
    exit 1
fi
if [ -z "$DARTVM_INCLUDE_DIR" ] || [ ! -d "$DARTVM_INCLUDE_DIR" ]; then
    echo "ERROR: Dart VM headers not found in packages/include/"
    exit 1
fi

echo "Dart VM lib: $DARTVM_LIB"
echo "  size: $(ls -lh "$DARTVM_LIB" | awk '{print $5}')"
echo "Dart include: $DARTVM_INCLUDE_DIR"

# Verify ARM64
if command -v file > /dev/null; then
    FILE_OUT=$(file "$DARTVM_LIB" 2>/dev/null || true)
    echo "  $FILE_OUT"
    if echo "$FILE_OUT" | grep -qi "ARM\|aarch64"; then
        echo "  Architecture: ARM64 ✓"
    else
        echo "  ERROR: Dart VM lib is not ARM64!"
        echo "  NDK cross-compile failed. Check CMake log above for 'fler-dart: Using NDK toolchain'"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════
# Step 2b: Version-specific defines
# ═══════════════════════════════════════════════
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
# Step 3: Build Capstone static lib for ARM64
# ═══════════════════════════════════════════════
echo ""
echo "─── [3/5] Building Capstone static lib (ARM64) ───"

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
CAPSTONE_LIB=$(find "$CAPSTONE_BUILD_DIR" -name "libcapstone.a" 2>/dev/null | head -1 || true)
CAPSTONE_INCLUDE_DIR="$CAPSTONE_SRC/include/capstone"
echo "Capstone: $CAPSTONE_LIB"

# ═══════════════════════════════════════════════
# Step 4: Build dartvm.so
# ═══════════════════════════════════════════════
echo ""
echo "─── [4/5] Building dartvm.so ───"
mkdir -p "$DARTVM_SO_BUILD_DIR"
cd "$DARTVM_SO_BUILD_DIR"

cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_static \
    -DDART_VERSION="$DART_VERSION" \
    -DBLUTTER_SRC_DIR="$BLUTTER_DIR/blutter/src" \
    -DDARTVM_PACKAGES="$PACKAGES_DIR" \
    -DDARTVM_LIB_NAME="$DARMVM_LIB_NAME" \
    -DDARTVM_STATIC_LIB="$DARTVM_LIB" \
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
