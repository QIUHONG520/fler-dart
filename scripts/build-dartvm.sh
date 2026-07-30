# ═══════════════════════════════════════════════
# Step 1c: Inject NDK toolchain into dartvm_fetch_build.py + CMake template
# ═══════════════════════════════════════════════
echo ""
echo "─── [1c] Injecting NDK into build pipeline ───"

BLUTTER_FETCH="$BLUTTER_DIR/dartvm_fetch_build.py"
BLUTTER_TEMPLATE="$BLUTTER_DIR/scripts/CMakeLists.txt"

# 1. Patch dartvm_fetch_build.py: add NDK toolchain to cmake command
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
       f"    tc = '{ndk_path}/build/cmake/android.toolchain.cmake'\n"
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

# 2. Patch CMake template: make ICU optional + Android link flags
if ! grep -q "fler-dart: ICU optional" "$BLUTTER_TEMPLATE" 2>/dev/null; then
    echo "Patching CMake template..."
    python3 - "$BLUTTER_TEMPLATE" << 'PYEOF'
import sys
tmpl = sys.argv[1]
with open(tmpl, 'r') as f:
    c = f.read()

c = c.replace(
    "find_package(ICU REQUIRED uc)",
    "# fler-dart: ICU optional\nif(ANDROID)\n    find_package(ICU QUIET uc)\n    if(NOT ICU_FOUND)\n        set(ICU_LIBRARIES \"\")\n        set(ICU_INCLUDE_DIRS \"\")\n    endif()\nelse()\n    find_package(ICU REQUIRED uc)\nendif()"
)

c = c.replace(
    "if (MSVC)\n\ttarget_link_libraries(${LIBNAME} PUBLIC ${ICU_LIBRARIES})\nelse()\n\ttarget_link_libraries(${LIBNAME} PUBLIC dl pthread ${ICU_LIBRARIES})\nendif()",
    "if(ANDROID)\n\ttarget_link_libraries(${LIBNAME} PUBLIC atomic log ${ICU_LIBRARIES})\nelseif(MSVC)\n\ttarget_link_libraries(${LIBNAME} PUBLIC ${ICU_LIBRARIES})\nelse()\n\ttarget_link_libraries(${LIBNAME} PUBLIC dl pthread ${ICU_LIBRARIES})\nendif()"
)

print("  CMake template: patched OK")
with open(tmpl, 'w') as f:
    f.write(c)
PYEOF
fi