#!/bin/bash
# ─── Build dartvm.so for Android ARM64 ───
# Part of fler-dart: standalone dartvm.so build system for Fler.
#
# Pipeline (v4 — static capstone):
#   1. Clone Blutter (provides dartvm_fetch_build.py + C++ source)
#   2. Patch Blutter's CMake template for NDK ARM64 cross-compile
#   3. dartvm_fetch_build.py: sparse-checkout Dart SDK → CMake → ARM64 .a
#   4. Cross-compile Capstone as STATIC lib (libcapstone.a) for ARM64
#   5. Compile dartvm.so (Blutter C++ + blutter_entry.cpp + SQLite)
#      - Statically links Capstone; dynamically links libicuuc.so, libicudata.so
#      - Uses $ORIGIN rpath for runtime shared lib resolution
#   6. Strip → output/dartvm_<version>_android_arm64.so
#
# 说明：默认静态 capstone（USE_SHARED_CAPSTONE=OFF），dartvm.so 自带 Capstone，
# 引擎包不再产出 libcapstone.so；capstone 已静态链接进 fler APK（SO 编辑器反汇编
# 零引擎依赖）。如需旧的动态模式用 --dynamic-capstone。
#
# Shared libraries (built once, reused across all Dart versions):
#   libicuuc.so      — ICU Unicode library
#   libicudata.so    — ICU data tables
#   libc++_shared.so — NDK C++ standard library
#
# Usage (engine build — per Dart version):
#   bash build-dartvm.sh --dart-version 3.12.1
#
# Usage (shared libs build — once):
#   bash build-dartvm.sh --build-shared-libs-only

set -euo pipefail

DART_VERSION=""
NDK_PATH="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/output"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT=""
JOBS=$(nproc 2>/dev/null || echo 4)
BLUTTER_REPO="https://github.com/worawit/blutter.git"
# 固定 blutter commit：401c783（DartFnBase / DartStub / topClasses 重构版）。
# 该版本把 Function/Stub 统一到 DartFnBase 基类、库顶层函数/字段迁到 topClass("::")、
# DartApp 增加 stubs/topClasses/GetStaticField 等；引擎 wrapper(blutter_entry.cpp) 已兼容：
#   - app.GetFunction() 返回 DartFnBase*（仅用其 FullName()/ReturnType()）
#   - cls->Functions() 仍返回 std::vector<DartFunction*>
# 无需 Step 1b / patch-elfhelper（同 528acbe）。
BLUTTER_COMMIT="4a60ac648bf448c5a7596437243bcd0b9376fdf0"
# 默认静态 capstone：dartvm.so 自带 Capstone，引擎包不再产 libcapstone.so
# （capstone 已静态进 fler APK）。--dynamic-capstone 可切回旧动态模式。
USE_SHARED_CAPSTONE="OFF"
BUILD_SHARED_LIBS_ONLY="0"
PREBUILT_SHARED_LIBS_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dart-version) DART_VERSION="$2"; shift 2 ;;
        --ndk-path) NDK_PATH="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --build-root) BUILD_ROOT="$2"; shift 2 ;;
        --static-capstone) USE_SHARED_CAPSTONE="OFF"; shift ;;
        --dynamic-capstone) USE_SHARED_CAPSTONE="ON"; shift ;;
        --build-shared-libs-only) BUILD_SHARED_LIBS_ONLY="1"; shift ;;
        --prebuilt-shared-libs-dir) PREBUILT_SHARED_LIBS_DIR="$2"; shift 2 ;;
        *) echo "ERROR: Unknown $1"; exit 1 ;;
    esac
done

if [ -z "$DART_VERSION" ] && [ "$BUILD_SHARED_LIBS_ONLY" != "1" ]; then
    echo "ERROR: --dart-version required (or use --build-shared-libs-only)"
    exit 1
fi
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

# Shared libs output (built once, reused)
SHARED_LIBS_OUT="$OUTPUT_DIR/shared_libs"
mkdir -p "$SHARED_LIBS_OUT"

# If --build-shared-libs-only, build shared libs and exit
if [ "$BUILD_SHARED_LIBS_ONLY" = "1" ]; then
    echo "════════════════════════════════════════════"
    echo " fler-dart: Building shared libraries only"
    echo " NDK:        $NDK_PATH"
    echo " Output:     $SHARED_LIBS_OUT"
    echo "════════════════════════════════════════════"

    # 1. Build Capstone (shared lib in dynamic mode; static lib in static mode —
    #    static 模式下 capstone 静态链接进 dartvm.so，引擎包不再需要 libcapstone.so，
    #    但需产出 libcapstone.a 供各版本 dartvm.so 链接复用)
    echo ""
    if [ "$USE_SHARED_CAPSTONE" = "ON" ]; then
        echo "─── [1/4] Building Capstone shared lib (ARM64) ───"
    else
        echo "─── [1/4] Building Capstone static lib (ARM64) ───"
    fi
    CAPSTONE_SRC="$BUILD_ROOT/capstone-src"
    if [ ! -d "$CAPSTONE_SRC" ]; then
        mkdir -p "$CAPSTONE_SRC"
        curl -sL "https://github.com/capstone-engine/capstone/archive/refs/tags/5.0.9.tar.gz" \
            -o "$BUILD_ROOT/capstone.tar.gz"
        tar xzf "$BUILD_ROOT/capstone.tar.gz" -C "$CAPSTONE_SRC" --strip-components=1
    fi
    mkdir -p "$CAPSTONE_BUILD_DIR"
    cd "$CAPSTONE_BUILD_DIR"
    if [ "$USE_SHARED_CAPSTONE" = "ON" ]; then
        cmake -G Ninja \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
            -DCMAKE_BUILD_TYPE=Release \
            -DANDROID_ABI=arm64-v8a \
            -DANDROID_PLATFORM=android-24 \
            -DANDROID_STL=c++_shared \
            -DBUILD_SHARED_LIBS=ON \
            -DBUILD_STATIC_LIBS=OFF \
            -DCAPSTONE_BUILD_TESTS=OFF \
            -DCAPSTONE_BUILD_CSTOOL=OFF \
            -DCAPSTONE_BUILD_CSTEST=OFF \
            "$CAPSTONE_SRC"
        cmake --build . -j "$JOBS"
        cp "$CAPSTONE_BUILD_DIR/libcapstone.so" "$SHARED_LIBS_OUT/"
    else
        cmake -G Ninja \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
            -DCMAKE_BUILD_TYPE=Release \
            -DANDROID_ABI=arm64-v8a \
            -DANDROID_PLATFORM=android-24 \
            -DANDROID_STL=c++_shared \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_STATIC_LIBS=ON \
            -DCAPSTONE_BUILD_TESTS=OFF \
            -DCAPSTONE_BUILD_CSTOOL=OFF \
            -DCAPSTONE_BUILD_CSTEST=OFF \
            "$CAPSTONE_SRC"
        cmake --build . -j "$JOBS"
        cp "$CAPSTONE_BUILD_DIR/libcapstone.a" "$SHARED_LIBS_OUT/"
    fi

    # 2. Copy NDK shared libs
    echo ""
    echo "─── [2/4] Copying NDK shared libs ───"
    CPP_SHARED="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
    if [ -f "$CPP_SHARED" ]; then
        cp "$CPP_SHARED" "$SHARED_LIBS_OUT/"
        echo "  → libc++_shared.so"
    fi

    # 3. Cross-compile ICU shared libs for ARM64 Android
    #    ICU requires a host build first (for --with-cross-build), then cross-compile.
    #    Android doesn't support .so version suffixes, so patchelf fixes sonames.
    echo ""
    echo "─── [3/4] Building ICU shared libs (ARM64 Android) ───"
    ICU_SRC="$BUILD_ROOT/icu-src"
    ICU_HOST_BUILD="$BUILD_ROOT/icu-host-build"
    ICU_CROSS_BUILD="$BUILD_ROOT/icu-cross-build"

    if [ ! -d "$ICU_SRC" ]; then
        echo "  Downloading ICU 73.2 source..."
        curl -fsSL "https://github.com/unicode-org/icu/releases/download/release-73-2/icu4c-73_2-src.tgz" \
            -o "$BUILD_ROOT/icu-src.tgz"
        if ! file "$BUILD_ROOT/icu-src.tgz" | grep -q "gzip"; then
            echo "ERROR: ICU download failed, not a gzip file"
            echo "  First 100 bytes: $(head -c 100 "$BUILD_ROOT/icu-src.tgz")"
            exit 1
        fi
        mkdir -p "$ICU_SRC"
        tar xzf "$BUILD_ROOT/icu-src.tgz" -C "$ICU_SRC" --strip-components=1
        rm -f "$BUILD_ROOT/icu-src.tgz"
    fi

    # Host build (required by ICU cross-compile for config tools)
    if [ ! -f "$ICU_HOST_BUILD/config.status" ]; then
        echo "  Building ICU host configuration..."
        mkdir -p "$ICU_HOST_BUILD"
        cd "$ICU_HOST_BUILD"
        CFLAGS="-O2" CXXFLAGS="-O2" "$ICU_SRC/source/configure" \
            --disable-shared --enable-static \
            --disable-tests --disable-samples \
            --disable-extras --disable-icuio \
            > /dev/null 2>&1
        make -j"$JOBS" > /dev/null 2>&1
    fi

    # Cross-compile for ARM64 Android
    echo "  Cross-compiling ICU for ARM64 Android..."
    NDK_TOOLCHAIN="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/bin"
    SYSROOT="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    mkdir -p "$ICU_CROSS_BUILD"
    cd "$ICU_CROSS_BUILD"

    # Clean previous attempt if config failed
    if [ ! -f config.status ]; then
        CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" \
        "$ICU_SRC/source/configure" \
            --host=aarch64-linux-android \
            --with-cross-build="$ICU_HOST_BUILD" \
            --with-sysroot="$SYSROOT" \
            --enable-shared --disable-static \
            --disable-tests --disable-samples \
            --disable-extras --disable-icuio \
            --with-data-packaging=library \
            CC="$NDK_TOOLCHAIN/aarch64-linux-android24-clang" \
            CXX="$NDK_TOOLCHAIN/aarch64-linux-android24-clang++" \
            AR="$NDK_TOOLCHAIN/llvm-ar" \
            RANLIB="$NDK_TOOLCHAIN/llvm-ranlib" \
            STRIP="$NDK_TOOLCHAIN/llvm-strip"
    fi
    make -j"$JOBS"

    # Copy ICU shared libs and fix sonames (Android doesn't support version suffixes)
    for lib in libicuuc libicudata; do
        src=$(ls "$ICU_CROSS_BUILD/lib/${lib}.so."* 2>/dev/null | head -1)
        if [ -n "$src" ]; then
            cp "$src" "$SHARED_LIBS_OUT/${lib}.so"
            patchelf --set-soname "${lib}.so" "$SHARED_LIBS_OUT/${lib}.so" 2>/dev/null || \
                echo "  WARNING: patchelf not available, soname may be incorrect"
            echo "  → ${lib}.so"
        else
            echo "  WARNING: ${lib}.so not found in ICU build output"
        fi
    done

    # 4. Verify all shared libs
    echo ""
    echo "─── [4/4] Verifying shared libs ───"
    for f in "$SHARED_LIBS_OUT"/lib*.so; do
        if [ -f "$f" ]; then
            echo "  $(basename "$f")  ($(ls -lh "$f" | awk '{print $5}'))  $(file "$f" | grep -o 'ELF.*ARM')"
        fi
    done

    echo ""
    echo "════════════════════════════════════════════"
    echo " Shared libs build complete!"
    echo " Output dir: $SHARED_LIBS_OUT"
    for f in "$SHARED_LIBS_OUT"/lib*.so; do
        if [ -f "$f" ]; then
            echo "   $(basename "$f")  ($(ls -lh "$f" | awk '{print $5}'))"
        fi
    done
    echo "════════════════════════════════════════════"
    exit 0
fi

cleanup() { [ "${CLEANUP:-0}" = "1" ] && rm -rf "$BUILD_ROOT" || true; }
trap cleanup EXIT

echo "════════════════════════════════════════════"
echo " fler-dart: dartvm.so Build (dartvm_fetch_build.py + NDK)"
echo " Dart version: $DART_VERSION"
echo " NDK:          $NDK_PATH"
echo " Build root:   $BUILD_ROOT"
echo "════════════════════════════════════════════"

# ═══════════════════════════════════════════════
# Step 1: Clone Blutter（固定到已验证 commit）
# ═══════════════════════════════════════════════
echo ""
echo "─── [1/5] Cloning Blutter @ ${BLUTTER_COMMIT} ───"
# 每次都强制拉取并 checkout 固定 commit，避免 CI 缓存的旧 blutter 被静默复用
if [ ! -d "$BLUTTER_DIR" ]; then
    mkdir -p "$BLUTTER_DIR"
fi
git -C "$BLUTTER_DIR" init -q 2>/dev/null || true
git -C "$BLUTTER_DIR" remote remove origin 2>/dev/null || true
git -C "$BLUTTER_DIR" remote add origin "$BLUTTER_REPO"
git -C "$BLUTTER_DIR" fetch --depth 1 origin "$BLUTTER_COMMIT"
git -C "$BLUTTER_DIR" checkout -f FETCH_HEAD
echo "Blutter: $BLUTTER_DIR @ $(git -C "$BLUTTER_DIR" rev-parse HEAD)"

# ═══════════════════════════════════════════════
# Step 1b / 1b-elf：已移除
# - Step 1b（closure.entry_point → func.entry_point）曾为编译兼容，但 DART_PRECOMPILED_RUNTIME
#   补齐后 Closure::entry_point() 在所有矩阵版本均存在，无需补丁。
# - patch-elfhelper：401c783 的 ElfHelper 宿主验证可正常分析，非必需。
# ═══════════════════════════════════════════════

# ═══════════════════════════════════════════════
# Step 1d: Patch Blutter for direct in-memory DB export（非侵入式）
# - DartApp.h: 添加 fler_libs() 访问器（暴露 libs 私有成员）
# - DartDumper.h: 公开 FlPoolDescription() 包装 getPoolObjectDescription()
# 仅新增访问器/公开方法，不改变任何行为。幂等：已含 fler-dart 标记则跳过。
# ═══════════════════════════════════════════════
echo ""
echo "─── [1d] Patching Blutter for direct export accessors ───"

BLUTTER_DARTAPP_H="$BLUTTER_DIR/blutter/src/DartApp.h"
if ! grep -q "fler_libs" "$BLUTTER_DARTAPP_H" 2>/dev/null; then
    python3 - "$BLUTTER_DARTAPP_H" << 'PYEOF'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
accessor = (
    "\n\t// fler-dart: accessors for direct in-memory DB export\n"
    "\tconst std::vector<DartLibrary*>& fler_libs() const { return libs; }\n"
    "\n"
)
needle = "\nprivate:\n"
assert needle in s, "DartApp.h private: marker not found"
s = s.replace(needle, accessor + needle, 1)
open(path, 'w', encoding='utf-8').write(s)
print("  DartApp.h: fler_libs() accessor added")
PYEOF
fi

BLUTTER_DARTDUMPER_H="$BLUTTER_DIR/blutter/src/DartDumper.h"
if ! grep -q "FlPoolDescription" "$BLUTTER_DARTDUMPER_H" 2>/dev/null; then
    python3 - "$BLUTTER_DARTDUMPER_H" << 'PYEOF'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
wrapper = (
    "\n\t// fler-dart: expose pool description for direct in-memory DB export\n"
    "\tstd::string FlPoolDescription(intptr_t offset, bool simpleForm = true) {\n"
    "\t\treturn getPoolObjectDescription(offset, simpleForm);\n"
    "\t}\n"
    "\n"
)
needle = "\nprivate:\n"
assert needle in s, "DartDumper.h private: marker not found"
s = s.replace(needle, wrapper + needle, 1)
open(path, 'w', encoding='utf-8').write(s)
print("  DartDumper.h: FlPoolDescription() added")
PYEOF
fi

# ═══════════════════════════════════════════════
# Step 1e: Patch FridaWriter so a missing frida.template.js does not crash.
# FridaWriter::Create() copies FRIDA_TEMPLATE_DIR/frida.template.js with the
# throwing copy_file() overload. On device the compile-time template dir does
# not exist → filesystem_error → SIGABRT. Patch to the std::error_code
# overload so a missing template is silently skipped; the class-table tail of
# blutter_frida.js is still appended (usable for AOT layout/offsets).
# Idempotent: skips when the fler-dart marker is already present.
# ═══════════════════════════════════════════════
echo ""
echo "─── [1e] Patching FridaWriter.cpp (tolerant template copy) ───"

BLUTTER_FRIDAWRITER="$BLUTTER_DIR/blutter/src/FridaWriter.cpp"
if ! grep -q "fler-dart tolerant template" "$BLUTTER_FRIDAWRITER" 2>/dev/null; then
    python3 - "$BLUTTER_FRIDAWRITER" << 'PYEOF'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
old = "std::filesystem::copy_file(FRIDA_TEMPLATE_DIR \"/frida.template.js\", filename, std::filesystem::copy_options::overwrite_existing);"
new = ("// fler-dart tolerant template copy: missing template no longer crashes\n"
       "std::error_code _ec;\n"
       "std::filesystem::copy_file(FRIDA_TEMPLATE_DIR \"/frida.template.js\", filename,\n"
       "    std::filesystem::copy_options::overwrite_existing, _ec);")
assert old in s, "FridaWriter.cpp copy_file pattern not found"
s = s.replace(old, new)
open(path, 'w', encoding='utf-8').write(s)
print("  FridaWriter.cpp: tolerant template copy applied")
PYEOF
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
       "        f'-DANDROID_ABI=arm64-v8a', f'-DANDROID_PLATFORM=android-31',\n"
       "        f'-DANDROID_STL=c++_static',")

assert old in c, "Pattern not found in dartvm_fetch_build.py"
c = c.replace(old, new)
print("  dartvm_fetch_build.py: patched OK")
with open(fetch_file, 'w') as f:
    f.write(c)
PYEOF
fi

# 1b. Patch dartvm_fetch_build.py: 支持 --no-compressed-pointers 构建 no_cptr VM。
# 上游脚本 __main__ 不接收 has_compressed_ptrs（Android 恒 compressed），且 lib_name
# 不含变体后缀。这里补：argv[4]=='--no-compressed-pointers' → has_compressed_ptrs=False，
# 且 no_cptr 时 lib_name 追加 _nocptr，避免与 compressed 构建目录/产物冲突。
if ! grep -q "fler-dart no_cptr" "$BLUTTER_FETCH" 2>/dev/null; then
    echo "Patching dartvm_fetch_build.py (no_cptr support)..."
    python3 - "$BLUTTER_FETCH" << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old1 = "self.lib_name = f'dartvm{version}_{os_name}_{arch}'"
new1 = "self.lib_name = f'dartvm{version}_{os_name}_{arch}' + ('' if self.has_compressed_ptrs else '_nocptr')  # fler-dart no_cptr"
assert old1 in s, "lib_name pattern not found"
s = s.replace(old1, new1)

old2 = "    snapshot_hash = None if len(sys.argv) < 5 else sys.argv[4]\n    info = DartLibInfo(ver, os_name, arch, snapshot_hash=snapshot_hash)"
new2 = ("    snapshot_hash = None if len(sys.argv) < 5 else sys.argv[4]\n"
        "    # fler-dart no_cptr: argv[4]=='--no-compressed-pointers' builds non-compressed VM\n"
        "    no_cptr = len(sys.argv) >= 5 and sys.argv[4] == '--no-compressed-pointers'\n"
        "    info = DartLibInfo(ver, os_name, arch, has_compressed_ptrs=(not no_cptr), snapshot_hash=(None if no_cptr else snapshot_hash))")
assert old2 in s, "__main__ pattern not found"
s = s.replace(old2, new2)

open(p, 'w', encoding='utf-8').write(s)
print("  dartvm_fetch_build.py: no_cptr support added")
PYEOF
fi

# 2. Patch CMake template (idempotent — always safe to re-apply)
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

# 3. Exclude regexp/ dir (missing ICU headers on NDK; not needed for DART_PRECOMPILED_RUNTIME)
c = c.replace(
    "include(sourcelist.cmake)\\nadd_library",
    "include(sourcelist.cmake)\\nif(ANDROID)\\n    list(FILTER SRCS EXCLUDE REGEX \\\"regexp\\\")\\nendif()\\nadd_library"
)

# 4. no_cptr 变体：.a 文件名由 LIBNAME 决定（非 DartLibInfo.lib_name）。当 COMPRESSED_PTRS=0
#    时给 LIBNAME 追加 _nocptr，使 no_cptr VM 产出 libdartvm<v>_<os>_<arch>_nocptr.a，
#    避免与 compressed 的同名 .a 互相覆盖。头文件仍共用 include/${PROJECT_NAME}（相同）。
c = c.replace(
    'set(LIBNAME "dartvm${DART_VERSION}_${TARGET_OS}_${TARGET_ARCH}")',
    'set(LIBNAME "dartvm${DART_VERSION}_${TARGET_OS}_${TARGET_ARCH}")\\nif(DEFINED COMPRESSED_PTRS AND COMPRESSED_PTRS STREQUAL "0")\\n\\tset(LIBNAME "${LIBNAME}_nocptr")\\nendif()'
)

print("  CMake template: patched OK")
with open(tmpl, 'w') as f:
    f.write(c)
PYEOF

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

# ─── no_cptr VM static lib（--no-compressed-pointers）───
echo ""
echo "─── [2b/5] Building Dart VM static lib (no_cptr variant) ───"
DARMVM_LIB_NAME_NOCPTR="dartvm${DART_VERSION}_android_arm64_nocptr"
# .a 直接平铺在 packages/lib/ 下（CMake install ARCHIVE DESTINATION lib → lib/lib<LIBNAME>.a）
DARTVM_LIB_NOCPTR="$PACKAGES_DIR/lib/lib${DARMVM_LIB_NAME_NOCPTR}.a"
# 头文件与 compressed 共用（install DESTINATION include/${PROJECT_NAME}，PROJECT_NAME 不含 os/arch）
DARTVM_INCLUDE_DIR_NOCPTR="$PACKAGES_DIR/include/dartvm${DART_VERSION}"
if [ -f "$DARTVM_LIB_NOCPTR" ] && command -v file > /dev/null && file "$DARTVM_LIB_NOCPTR" | grep -qi "ARM\|aarch64"; then
    echo "  cached no_cptr VM lib: $DARTVM_LIB_NOCPTR"
else
    echo "Running dartvm_fetch_build.py $DART_VERSION android arm64 --no-compressed-pointers..."
    python3 dartvm_fetch_build.py "$DART_VERSION" android arm64 --no-compressed-pointers
fi
if [ ! -f "$DARTVM_LIB_NOCPTR" ]; then
    echo "ERROR: no_cptr Dart VM static lib not found: $DARTVM_LIB_NOCPTR"
    exit 1
fi
echo "no_cptr VM lib: $DARTVM_LIB_NOCPTR"
echo "  size: $(ls -lh "$DARTVM_LIB_NOCPTR" | awk '{print $5}')"

# ═══════════════════════════════════════════════
# Step 1j: Patch Dart 3.x write-barrier false-positive guard
# Dart 3.6+ may emit `tst x16, x28, lsr #32` in ordinary generated code.
# Older Blutter versions classify this sequence as a write barrier and assert
# `insn.ops(1).reg == CSREG_DART_HEAP`, repeatedly reporting the same address.
# Convert only that assertion into InsnException so the per-function guard skips
# the incompatible function and continues with the remaining functions.
# ═══════════════════════════════════════════════
echo ""
echo "─── [1j] Patching write-barrier false-positive assertion ───"
BLUTTER_SRC_DIR="$BLUTTER_DIR/blutter/src"
python3 - "$BLUTTER_SRC_DIR" << 'PYEOF'
import sys, os, re
root = sys.argv[1]
count = 0
for name in ("CodeAnalyzer.cpp", "CodeAnalyzer_arm64.cpp"):
    path = os.path.join(root, name)
    if not os.path.isfile(path):
        continue
    lines = open(path, encoding="utf-8").read().splitlines(True)
    out = []
    changed = False
    for line in lines:
        if "CSREG_DART_HEAP" in line and re.search(r"\b(?:ASSERT|RELEASE_ASSERT|FATAL)\s*\(", line):
            indent = line[:len(line)-len(line.lstrip())]
            out.append(indent + 'throw InsnException("write barrier register mismatch", insn); // fler-dart wb-guard\n')
            count += 1
            changed = True
        else:
            out.append(line)
    if changed:
        open(path, "w", encoding="utf-8").writelines(out)
print(f"  write-barrier assertion guards added: {count}")
PYEOF

# ═══════════════════════════════════════════════
# Step 1h: Patch DartLoader isolate lifecycle
# Dart_ShutdownIsolate() does not detach the isolate from the calling thread.
# When FlutterEditM reuses an IO-pool thread, the next analysis then fails with:
#   CreateIsolate expects there to be no current isolate
# Always leave the current isolate before shutting it down, and keep the VM alive
# for subsequent analyses in the same process.
# ═══════════════════════════════════════════════
echo ""
echo "─── [1h] Patching DartLoader isolate lifecycle ───"
BLUTTER_DARTLOADER_CPP="$BLUTTER_DIR/blutter/src/DartLoader.cpp"
if [ -f "$BLUTTER_DARTLOADER_CPP" ]; then
    python3 - "$BLUTTER_DARTLOADER_CPP" << 'PYEOF'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()

# Idempotent textual patch: unlike matching the whole upstream method body,
# this survives harmless formatting and SDK-version differences.
if 'fler-dart isolate-detach' not in s:
    old = '\t\tDart_ShutdownIsolate();'
    if old in s:
        s = s.replace(old,
            '\t\t// fler-dart isolate-detach: detach before shutdown so the thread\n'
            '\t\t// can create the next isolate when the App reuses this IO thread.\n'
            '\t\tDart_ExitIsolate();\n'
            '\t\tDart_ShutdownIsolate();', 1)
        print('  DartLoader: Dart_ExitIsolate before Dart_ShutdownIsolate added')
    else:
        print('  WARN: Dart_ShutdownIsolate target not found')
    open(path, 'w', encoding='utf-8').write(s)
else:
    print('  DartLoader: isolate-detach already present, skipped')
PYEOF
else
    echo "  WARN: DartLoader.cpp not found (will be available after Blutter source fetch)"
fi

# ═══════════════════════════════════════════════
# Step 2b: 版本兼容宏（对齐 blutter.py find_compat_macro 官方逻辑，grep 检测头文件）
# ═══════════════════════════════════════════════
VER_MAJOR=$(echo "$DART_VERSION" | cut -d. -f1)

VERSION_DEFINES=""
DART_VM_INC="$DARTVM_INCLUDE_DIR/vm"
CLASS_ID_H="$DART_VM_INC/class_id.h"

# 老 Map/Set 布局（class_id.h 含 V(LinkedHashMap)，2.18 及更早）
if grep -q "V(LinkedHashMap)" "$CLASS_ID_H"; then
    VERSION_DEFINES="$VERSION_DEFINES -DOLD_MAP_SET_NAME=ON"
    # 无 immutable Map/Set（2.14~2.17）：blutter pch.h 编译需要此宏，否则报
    # "unknown type name 'ImmutableLinkedHashMap'" / use of undeclared
    # identifier 'kImmutableLinkedHashMapCid'（参见 2.14.4 构建失败）。
    if ! grep -q "V(ImmutableLinkedHashMap)" "$CLASS_ID_H"; then
        VERSION_DEFINES="$VERSION_DEFINES -DOLD_MAP_NO_IMMUTABLE=ON"
    fi
fi

# 无 kLastInternalOnlyCid（2.14~2.17）
if ! grep -q " kLastInternalOnlyCid " "$CLASS_ID_H"; then
    VERSION_DEFINES="$VERSION_DEFINES -DNO_LAST_INTERNAL_ONLY_CID=ON"
fi

# 有 TypeRef（2.x~3.0，3.1 移除）
if grep -q "V(TypeRef)" "$CLASS_ID_H"; then
    VERSION_DEFINES="$VERSION_DEFINES -DHAS_TYPE_REF=ON"
fi

# 有 RecordType（3.x）
if [ "$VER_MAJOR" -ge 3 ] && grep -q "V(RecordType)" "$CLASS_ID_H"; then
    VERSION_DEFINES="$VERSION_DEFINES -DHAS_RECORD_TYPE=ON"
fi

# 有 SharedClassTable（2.18 及更早，2.19 起并入 ClassTable）
if grep -q "class SharedClassTable {" "$DART_VM_INC/class_table.h"; then
    VERSION_DEFINES="$VERSION_DEFINES -DHAS_SHARED_CLASS_TABLE=ON"
fi

# 无 InitLateStaticField stub（2.14~2.15）
if ! grep -q "V(InitLateStaticField)" "$DART_VM_INC/stub_code_list.h"; then
    VERSION_DEFINES="$VERSION_DEFINES -DNO_INIT_LATE_STATIC_FIELD=ON"
fi

# 无 method extractor code（3.4 起）
if ! grep -q "build_generic_method_extractor_code)" "$DART_VM_INC/object_store.h"; then
    VERSION_DEFINES="$VERSION_DEFINES -DNO_METHOD_EXTRACTOR_STUB=ON"
fi

# 无 AsTruncatedInt64Value（3.6 起整数访问统一为 Value()）
if ! grep -q "AsTruncatedInt64Value()" "$DART_VM_INC/object.h"; then
    VERSION_DEFINES="$VERSION_DEFINES -DUNIFORM_INTEGER_ACCESS=ON"
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
# Step 3: Build Capstone (static by default; SHARED lib in dynamic mode)
# ═══════════════════════════════════════════════
echo ""
echo "─── [3/5] Capstone setup (mode: $USE_SHARED_CAPSTONE) ───"

# Pre-built capstone from shared-libs stage: static mode uses libcapstone.a,
# dynamic mode uses libcapstone.so. Skip source build when present.
PREBUILT_CAP=""
if [ -n "$PREBUILT_SHARED_LIBS_DIR" ]; then
    if [ "$USE_SHARED_CAPSTONE" = "ON" ] && [ -f "$PREBUILT_SHARED_LIBS_DIR/libcapstone.so" ]; then
        PREBUILT_CAP="$PREBUILT_SHARED_LIBS_DIR/libcapstone.so"
    elif [ "$USE_SHARED_CAPSTONE" = "OFF" ] && [ -f "$PREBUILT_SHARED_LIBS_DIR/libcapstone.a" ]; then
        PREBUILT_CAP="$PREBUILT_SHARED_LIBS_DIR/libcapstone.a"
    fi
fi

if [ -n "$PREBUILT_CAP" ]; then
    echo "  Using pre-built Capstone from: $PREBUILT_CAP"
    CAPSTONE_LIB="$PREBUILT_CAP"

    # Capstone headers: download source for headers only (fast, no compilation)
    CAPSTONE_SRC="$BUILD_ROOT/capstone-src"
    if [ ! -d "$CAPSTONE_SRC" ]; then
        echo "  Fetching Capstone headers..."
        curl -sL "https://github.com/capstone-engine/capstone/archive/refs/tags/5.0.9.tar.gz" \
            -o "$BUILD_ROOT/capstone.tar.gz"
        mkdir -p "$CAPSTONE_SRC"
        tar xzf "$BUILD_ROOT/capstone.tar.gz" -C "$CAPSTONE_SRC" --strip-components=1
    fi
    CAPSTONE_INCLUDE_DIR="$CAPSTONE_SRC/include/capstone"
    echo "  Capstone (pre-built lib, source for headers): $CAPSTONE_LIB"
else
    echo "  Building Capstone from source..."
    CAPSTONE_SRC="$BUILD_ROOT/capstone-src"
    if [ ! -d "$CAPSTONE_SRC" ]; then
        echo "Downloading Capstone 5.0.9..."
        mkdir -p "$CAPSTONE_SRC"
        curl -sL "https://github.com/capstone-engine/capstone/archive/refs/tags/5.0.9.tar.gz" \
            -o "$BUILD_ROOT/capstone.tar.gz"
        tar xzf "$BUILD_ROOT/capstone.tar.gz" -C "$CAPSTONE_SRC" --strip-components=1
    fi
    mkdir -p "$CAPSTONE_BUILD_DIR"
    cd "$CAPSTONE_BUILD_DIR"

    if [ "$USE_SHARED_CAPSTONE" = "ON" ]; then
        # Dynamic linking mode: build shared library
        cmake -G Ninja \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
            -DCMAKE_BUILD_TYPE=Release \
            -DANDROID_ABI=arm64-v8a \
            -DANDROID_PLATFORM=android-24 \
            -DANDROID_STL=c++_shared \
            -DBUILD_SHARED_LIBS=ON \
            -DBUILD_STATIC_LIBS=OFF \
            -DCAPSTONE_BUILD_TESTS=OFF \
            -DCAPSTONE_BUILD_CSTOOL=OFF \
            -DCAPSTONE_BUILD_CSTEST=OFF \
            "$CAPSTONE_SRC"
        cmake --build . -j "$JOBS"
        CAPSTONE_LIB=$(find "$CAPSTONE_BUILD_DIR" -name "libcapstone.so" 2>/dev/null | head -1 || true)
        CAPSTONE_INCLUDE_DIR="$CAPSTONE_SRC/include/capstone"
        echo "Capstone (shared): $CAPSTONE_LIB"
    else
        # Legacy static mode
        cmake -G Ninja \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
            -DCMAKE_BUILD_TYPE=Release \
            -DANDROID_ABI=arm64-v8a \
            -DANDROID_PLATFORM=android-24 \
            -DANDROID_STL=c++_static \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_STATIC_LIBS=ON \
            -DCAPSTONE_BUILD_TESTS=OFF \
            -DCAPSTONE_BUILD_CSTOOL=OFF \
            -DCAPSTONE_BUILD_CSTEST=OFF \
            "$CAPSTONE_SRC"
        cmake --build . -j "$JOBS"
        CAPSTONE_LIB=$(find "$CAPSTONE_BUILD_DIR" -name "libcapstone.a" 2>/dev/null | head -1 || true)
        CAPSTONE_INCLUDE_DIR="$CAPSTONE_SRC/include/capstone"
        echo "Capstone (static): $CAPSTONE_LIB"
    fi
fi

# ═══════════════════════════════════════════════
# Step 4: Build dartvm.so
# ═══════════════════════════════════════════════
echo ""
echo "─── [4/5] Building dartvm.so (dynamic linking mode: $USE_SHARED_CAPSTONE) ───"
mkdir -p "$DARTVM_SO_BUILD_DIR"
cd "$DARTVM_SO_BUILD_DIR"

# ICU setup for dynamic linking
ICU_DIR="$BUILD_ROOT/icu"
ICU_LIB_DIR="$ICU_DIR/lib"
mkdir -p "$ICU_LIB_DIR"

# Copy shared libs into output for bundling with engine
SHARED_LIBS_DIR="$OUTPUT_DIR/shared_libs"
mkdir -p "$SHARED_LIBS_DIR"

if [ "$USE_SHARED_CAPSTONE" = "ON" ] && [ -f "$CAPSTONE_BUILD_DIR/libcapstone.so" ]; then
    # Copy libcapstone.so to shared libs output (only when built from source)
    cp "$CAPSTONE_BUILD_DIR/libcapstone.so" "$SHARED_LIBS_DIR/"
    echo "  → libcapstone.so → shared_libs/"
fi

# Copy NDK c++_shared to shared libs output
CPP_SHARED="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
if [ -f "$CPP_SHARED" ]; then
    cp "$CPP_SHARED" "$SHARED_LIBS_DIR/"
    echo "  → libc++_shared.so → shared_libs/"
fi

# ICU (prebuilt from blutter or downloaded separately)
# If ICU_DIR is pre-populated (from shared libs build), skip download
if [ ! -f "$ICU_LIB_DIR/libicuuc.so" ]; then
    echo "  ICU not pre-built. If ICU is needed for full feature set,"
    echo "  build shared libs first: bash build-dartvm.sh --build-shared-libs-only"
fi

cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-31 \
    -DANDROID_STL=c++_shared \
    -DDART_VERSION="$DART_VERSION" \
    -DBLUTTER_SRC_DIR="$BLUTTER_DIR/blutter/src" \
    -DDARTVM_PACKAGES="$PACKAGES_DIR" \
    -DDARTVM_LIB_NAME="$DARMVM_LIB_NAME" \
    -DDARTVM_STATIC_LIB="$DARTVM_LIB" \
    -DCAPSTONE_LIB="$CAPSTONE_LIB" \
    -DCAPSTONE_INCLUDE_DIR="$CAPSTONE_INCLUDE_DIR" \
    -DUSE_SHARED_CAPSTONE="$USE_SHARED_CAPSTONE" \
    -DSQLITE_DIR="$SQLITE_DIR" \
    -DICU_DIR="$ICU_DIR" \
    $VERSION_DEFINES \
    "$REPO_DIR/dartvm"

cmake --build . -j "$JOBS"

# ─── Output ───
OUTPUT_FILE="$OUTPUT_DIR/dartvm_${DART_VERSION}_${ARCH_TAG}.so"
mkdir -p "$OUTPUT_DIR"
cp "$DARTVM_SO_BUILD_DIR/libdartvm.so" "$OUTPUT_FILE"

# ═══════════════════════════════════════════════
# no_cptr 变体：--no-compressed-pointers（DART_COMPRESSED_POINTERS 不定义）。
# 部分 libapp 以 --no-compressed-pointers 构建（快照配置里无 `compressed`），
# 若用 compressed 变体引擎会报 "Snapshot not compatible ... compressed" 或读错
# 对象布局导致段错误。故每个 Dart 版本同时产出两个变体 .so，与 CI 打包（7z 通配
# dartvm_*.so，compressed + _no_cptr 共存）对应。
# ═══════════════════════════════════════════════
echo ""
echo "─── [4b] Building dartvm.so (no_cptr variant) ───"
NO_CPTR_BUILD_DIR="$BUILD_ROOT/dartvm_so_build_nocptr"
mkdir -p "$NO_CPTR_BUILD_DIR"
cd "$NO_CPTR_BUILD_DIR"
cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-31 \
    -DANDROID_STL=c++_shared \
    -DDART_VERSION="$DART_VERSION" \
    -DBLUTTER_SRC_DIR="$BLUTTER_DIR/blutter/src" \
    -DDARTVM_PACKAGES="$PACKAGES_DIR" \
    -DDARTVM_LIB_NAME="$DARMVM_LIB_NAME_NOCPTR" \
    -DDARTVM_STATIC_LIB="$DARTVM_LIB_NOCPTR" \
    -DCAPSTONE_LIB="$CAPSTONE_LIB" \
    -DCAPSTONE_INCLUDE_DIR="$CAPSTONE_INCLUDE_DIR" \
    -DUSE_SHARED_CAPSTONE="$USE_SHARED_CAPSTONE" \
    -DSQLITE_DIR="$SQLITE_DIR" \
    -DICU_DIR="$ICU_DIR" \
    -DNO_COMPRESSED_POINTERS=ON \
    $VERSION_DEFINES \
    "$REPO_DIR/dartvm"
cmake --build . -j "$JOBS"
NO_CPTR_OUTPUT="$OUTPUT_DIR/dartvm_${DART_VERSION}_${ARCH_TAG}_no_cptr.so"
cp "$NO_CPTR_BUILD_DIR/libdartvm.so" "$NO_CPTR_OUTPUT"
echo "  no_cptr variant: $NO_CPTR_OUTPUT"

# Copy shared libs next to engine (runtime resolution via $ORIGIN)
# 必要共享库（libc++_shared/ICU）在静态/动态模式下都随引擎包；
# libcapstone.so 仅动态模式产出（静态模式 dartvm.so 已自带 Capstone）。
if [ -n "$PREBUILT_SHARED_LIBS_DIR" ]; then
    echo "  Copying pre-built shared libs to output..."
    cp "$PREBUILT_SHARED_LIBS_DIR/libc++_shared.so" "$OUTPUT_DIR/" 2>/dev/null || true
    cp "$PREBUILT_SHARED_LIBS_DIR/libicuuc.so" "$OUTPUT_DIR/" 2>/dev/null || true
    cp "$PREBUILT_SHARED_LIBS_DIR/libicudata.so" "$OUTPUT_DIR/" 2>/dev/null || true
    if [ "$USE_SHARED_CAPSTONE" = "ON" ]; then
        cp "$PREBUILT_SHARED_LIBS_DIR/libcapstone.so" "$OUTPUT_DIR/" 2>/dev/null || true
    fi
else
    if [ -f "$SHARED_LIBS_DIR/libc++_shared.so" ]; then
        cp "$SHARED_LIBS_DIR/libc++_shared.so" "$OUTPUT_DIR/"
    fi
    if [ -f "$ICU_LIB_DIR/libicuuc.so" ]; then
        cp "$ICU_LIB_DIR/libicuuc.so" "$OUTPUT_DIR/"
    fi
    if [ -f "$ICU_LIB_DIR/libicudata.so" ]; then
        cp "$ICU_LIB_DIR/libicudata.so" "$OUTPUT_DIR/"
    fi
    if [ "$USE_SHARED_CAPSTONE" = "ON" ] && [ -f "$SHARED_LIBS_DIR/libcapstone.so" ]; then
        cp "$SHARED_LIBS_DIR/libcapstone.so" "$OUTPUT_DIR/"
    fi
fi

echo ""
echo "════════════════════════════════════════════"
echo " Build complete! (mode: ${USE_SHARED_CAPSTONE})"
echo " Output: $OUTPUT_FILE"
echo " Size:   $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')"
echo " Arch:   $(file "$OUTPUT_FILE")"
if [ "$USE_SHARED_CAPSTONE" = "ON" ]; then
    echo ""
    echo " Shared libraries bundled with engine:"
    for f in "$OUTPUT_DIR"/lib*.so; do
        if [ -f "$f" ]; then
            echo "   → $(basename "$f")  ($(ls -lh "$f" | awk '{print $5}'))"
        fi
    done
fi
echo "════════════════════════════════════════════"
