#!/usr/bin/env bash
# patch-elfhelper.sh — 修复 blutter ElfHelper.cpp 的 null deref 崩溃
#
# 问题：findSnapshots() 在 .dynstr 未找到（dynstr=nullptr）但 .dynsym 找到时，
#   仍然进入符号遍历循环：`const char* name = dynstr + dynsym->name;`
#   nullptr + 0x27 = 0x27 → strcmp(0x27, ...) → SIGSEGV at 0x27
#   C++ try-catch 不能捕获信号，导致进程被杀。
#
# 修复：在遍历 .dynsym 前检查 dynstr/dynsym 是否为 nullptr，是则 throw
#   invalid_argument，被 blutter_entry.cpp 的 try-catch 捕获，返回 -2。
#
# 触发场景：libapp.so 被-strip或符号名不匹配（debug/profile 模式、Dart 版本差异）。

set -euo pipefail

BLUTTER_DIR="${1:-/tmp/fler-dart-cache/dartvm_current/blutter}"
ELFHELPER="$BLUTTER_DIR/blutter/src/ElfHelper.cpp"

if [ ! -f "$ELFHELPER" ]; then
    echo "[patch-elfhelper] ElfHelper.cpp not found at $ELFHELPER — skip"
    exit 0
fi

# 幂等检查：已 patch 过则 skip
if grep -q "fler-dart: null-check dynstr/dynsym" "$ELFHELPER" 2>/dev/null; then
    echo "[patch-elfhelper] already patched — skip"
    exit 0
fi

cp "$ELFHELPER" "$ELFHELPER.orig"

python3 - "$ELFHELPER" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 在 "find the required symbol addresses" 注释行后、第一个 for 循环前插入 null 检查。
# 匹配区间：注释 + 4 个 nullptr 初始化 + for 循环开头
old = '''\t// find the required symbol addresses
\tconst uint8_t* vm_snapshot_data = nullptr;
\tconst uint8_t* vm_snapshot_instructions = nullptr;
\tconst uint8_t* isolate_snapshot_data = nullptr;
\tconst uint8_t* isolate_snapshot_instructions = nullptr;
\tfor (; dynsym < dynsym_end; dynsym++) {'''

new = '''\t// find the required symbol addresses
\t// fler-dart: null-check dynstr/dynsym — 若 .dynstr 未找到（libapp.so 被 strip
\t// 或不含 Dart 快照符号字符串），dynstr 保持 nullptr。下方 `dynstr + dynsym->name`
\t// 会得到小整数（如 0x27），strcmp 解引用触发 SIGSEGV，try-catch 无法捕获。
\tif (dynstr == nullptr)
\t\tthrow std::invalid_argument("ELF: Cannot find .dynstr containing Dart snapshot symbols (libapp.so may be stripped or wrong format)");
\tif (dynsym == nullptr || dynsym_end == nullptr)
\t\tthrow std::invalid_argument("ELF: Cannot find .dynsym section");
\tconst uint8_t* vm_snapshot_data = nullptr;
\tconst uint8_t* vm_snapshot_instructions = nullptr;
\tconst uint8_t* isolate_snapshot_data = nullptr;
\tconst uint8_t* isolate_snapshot_instructions = nullptr;
\tfor (; dynsym < dynsym_end; dynsym++) {'''

if old not in content:
    print("[patch-elfhelper] WARN: expected code block not found — file may have been modified upstream")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("[patch-elfhelper] patched findSnapshots: added null-check for dynstr/dynsym")
PYEOF

echo "[patch-elfhelper] done"
