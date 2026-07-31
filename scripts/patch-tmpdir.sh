#!/usr/bin/env bash
# =============================================================================
# patch-tmpdir.sh
#
# 修改 blutter_entry.cpp 的 createTempDir，让 blutter 在 Android 上能正确
# 创建临时目录。
#
# 背景：
#   原实现硬编码 "/data/local/tmp/fler_XXXXXX" 和 "/tmp/fler_XXXXXX"，
#   Android app 进程对这两个路径都没有写权限。导致 blutter_analyze 在
#   第一阶段 mkdtemp 就失败，返回 -1。
#
# 修复：
#   优先级: $TMPDIR > $TEMP > $TMP > /data/local/tmp > /tmp
#   app 端在调用 blutter_analyze 前用 setenv("TMPDIR", app_cache_dir) 即可。
#
# 此脚本在 GitHub Action 的 build 步骤前自动运行。
# Ubuntu runner 自带 python3。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FILE="$SCRIPT_DIR/../dartvm/src/blutter_entry.cpp"

if [ ! -f "$SRC_FILE" ]; then
    echo "[patch-tmpdir] ERROR: $SRC_FILE not found"
    exit 1
fi

# 幂等：已 patch 过则跳过
if grep -q 'getenv("TMPDIR")' "$SRC_FILE"; then
    echo "[patch-tmpdir] already patched, skip"
    exit 0
fi

# 备份一次
if [ ! -f "$SRC_FILE.orig" ]; then
    cp "$SRC_FILE" "$SRC_FILE.orig"
    echo "[patch-tmpdir] backup: $SRC_FILE.orig"
fi

# 用 python 做精确多行替换（sed 跨平台多行处理不可靠）
python3 - "$SRC_FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

old = (
    'static bool createTempDir(char* buf, size_t sz) {\n'
    '    const char* tmpl = "/data/local/tmp/fler_XXXXXX";\n'
    '    if (sz < strlen(tmpl) + 1) return false;\n'
    '    strncpy(buf, tmpl, sz);\n'
    '    if (mkdtemp(buf) == nullptr) {\n'
    '        const char* alt = "/tmp/fler_XXXXXX";\n'
    '        strncpy(buf, alt, sz);\n'
    '        if (mkdtemp(buf) == nullptr) return false;\n'
    '    }\n'
    '    return true;\n'
    '}\n'
)

new = (
    'static bool createTempDir(char* buf, size_t sz) {\n'
    '    // Priority: TMPDIR > TEMP > TMP > /data/local/tmp > /tmp\n'
    '    // Android app has no write permission for /data/local/tmp and /tmp.\n'
    '    // App should setenv("TMPDIR", app_cache_dir) before calling blutter_analyze.\n'
    '    const char* env_dirs[] = {\n'
    '        getenv("TMPDIR"),\n'
    '        getenv("TEMP"),\n'
    '        getenv("TMP"),\n'
    '    };\n'
    '    for (const char* d : env_dirs) {\n'
    '        if (d == nullptr || d[0] == \'\\0\') continue;\n'
    '        size_t need = strlen(d) + 1 + 12 + 1;  // dir + "/" + "fler_XXXXXX" + "\\0"\n'
    '        if (need > sz) continue;\n'
    '        snprintf(buf, sz, "%s/fler_XXXXXX", d);\n'
    '        if (mkdtemp(buf) != nullptr) return true;\n'
    '    }\n'
    '    // fallback 1: /data/local/tmp (root device or classic Android)\n'
    '    const char* tmpl = "/data/local/tmp/fler_XXXXXX";\n'
    '    if (sz < strlen(tmpl) + 1) return false;\n'
    '    strncpy(buf, tmpl, sz);\n'
    '    if (mkdtemp(buf) == nullptr) {\n'
    '        // fallback 2: /tmp\n'
    '        const char* alt = "/tmp/fler_XXXXXX";\n'
    '        strncpy(buf, alt, sz);\n'
    '        if (mkdtemp(buf) == nullptr) return false;\n'
    '    }\n'
    '    return true;\n'
    '}\n'
)

if old not in src:
    print('[patch-tmpdir] ERROR: original createTempDir block not found')
    print('[patch-tmpdir] file may have been modified or pattern mismatched')
    sys.exit(2)

src = src.replace(old, new, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)

print('[patch-tmpdir] patched createTempDir to respect TMPDIR/TEMP/TMP env')
PYEOF

echo "[patch-tmpdir] done"
