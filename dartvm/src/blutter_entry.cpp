// ─── fler-dart: Blutter wrapper entry point ───
// Compiled as libdartvm.so. Exports blutter_analyze() callable from
// Fler's libfler.so via dlopen/dlsym.
//
// Pipeline:
//   1. Run Blutter analysis (LoadInfo + CodeAnalyzer)
//   2. Directly export classes/methods/pp_entries/strings from
//      DartApp's in-memory structures into SQLite (no text-file parsing;
//      之前的文本解析器与 blutter 真实输出格式不匹配，导致 classes/methods/strings 为空)
//
// Links against Blutter C++ sources + Dart VM static lib + Capstone + SQLite.

#include "pch.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cinttypes>
#include <filesystem>

#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>

#include "DartApp.h"
#include "DartDumper.h"
#include "CodeAnalyzer.h"
#include "DartThreadInfo.h"
#include "FridaWriter.h"

#include "sqlite3.h"

namespace fs = std::filesystem;

// ─── SQLite wrapper ─────────────────────────────
struct Db {
    sqlite3* db = nullptr;

    bool open(const char* path) {
        int rc = sqlite3_open(path, &db);
        if (rc != SQLITE_OK) {
            fprintf(stderr, "SQLite open failed: %s\n", sqlite3_errmsg(db));
            return false;
        }
        return true;
    }

    void exec(const char* sql) {
        char* err = nullptr;
        if (sqlite3_exec(db, sql, 0, 0, &err) != SQLITE_OK) {
            fprintf(stderr, "SQLite error: %s\n  SQL: %s\n", err, sql);
            sqlite3_free(err);
        }
    }

    void close() {
        if (db) { sqlite3_close(db); db = nullptr; }
    }
};

static Db g_db;

// ─── Schema ─────────────────────────────────────
static void createTables() {
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS classes ("
        "  id INTEGER PRIMARY KEY,"
        "  name TEXT NOT NULL,"
        "  super_cls TEXT,"
        "  fields TEXT"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS methods ("
        "  id INTEGER PRIMARY KEY,"
        "  class_id INTEGER REFERENCES classes(id),"
        "  name TEXT NOT NULL,"
        "  address INTEGER NOT NULL,"
        "  size INTEGER,"
        "  src_code TEXT,"
        "  UNIQUE(class_id, address)"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS asm_blocks ("
        "  id INTEGER PRIMARY KEY,"
        "  method_address INTEGER,"
        "  size INTEGER,"
        "  url TEXT,"
        "  body TEXT"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS strings ("
        "  id INTEGER PRIMARY KEY,"
        "  pp_offset INTEGER NOT NULL UNIQUE,"
        "  value TEXT NOT NULL,"
        "  ref_count INTEGER DEFAULT 0"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS pp_entries ("
        "  pp_offset INTEGER PRIMARY KEY,"
        "  type TEXT NOT NULL,"
        "  value TEXT"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS string_refs ("
        "  string_id INTEGER REFERENCES strings(id),"
        "  method_address INTEGER NOT NULL,"
        "  PRIMARY KEY (string_id, method_address)"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS objs ("
        "  obj_address INTEGER PRIMARY KEY,"
        "  class_name TEXT,"
        "  field_hint TEXT"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS enum_map ("
        "  class_name TEXT NOT NULL,"
        "  enum_index INTEGER NOT NULL,"
        "  enum_name TEXT NOT NULL,"
        "  PRIMARY KEY (class_name, enum_index)"
        ")"
    );
}

// ─── 直接内存导出（方案 A）─────────────────────

// ─── 完整反汇编生成（双轨）─────────────────────
// 复刻 DartDumper::DumpCode 内层循环（DartDumper.cpp:338-391）：
// 交错遍历 asmTexts（裸指令行）+ il_insns（IL 语义行）+ dataType 附加注释。
//
// standard=false：methods.src_code 用，fler 兼容格式——行首直接 `// `（无前导
//   空格），App 端 DartCallGraphBuilder::collectEdges 要求 line[0]=='/'；
//   `  ; extra` 后缀不影响 bl/b #0x 目标提取（hex 在空格处截断）。
// standard=true ：asm_blocks 用，标准 DumpCode 格式——`    // ` 带缩进，
//   与 asm/*.dart 产物逐字节一致。
static std::string buildFunctionAsmFull(DartFunction* fn, DartApp& app, DartDumper& dumper, bool standard) {
    std::string out;
    if (!fn) return out;
    auto* data = fn->GetAnalyzedData();
    if (!data) return out;
    const auto& asmTexts = data->asmTexts.Data();
    auto& il_insns = data->il_insns;
    auto il_itr = il_insns.begin();
    AddrRange range;
    char buf[512];
    for (const auto& t : asmTexts) {
        std::string extra;
        switch (t.dataType) {
        case AsmText::ThreadOffset:
            extra = "THR::" + GetThreadOffsetName(t.threadOffset);
            break;
        case AsmText::PoolOffset:
            extra = dumper.FlPoolDescription(t.poolOffset);
            break;
        case AsmText::Boolean:
            extra = t.boolVal ? "true" : "false";
            break;
        case AsmText::Call: {
            auto* fn2 = app.GetFunction(t.callAddress);
            if (fn2) {
                extra = fn2->FullName();
                auto retCid = fn2->ReturnType();
                if (retCid != dart::kIllegalCid) {
                    auto* retCls = app.GetClass(retCid);
                    if (retCls) {
                        extra += std::format(" -> {} (size={:#x})", retCls->FullName(), retCls->Size());
                    }
                }
            }
            break;
        }
        default:
            break;
        }

        if (standard) out += "    // ";
        else out += "// ";

        if (range.Has(t.addr)) {
            if (standard) out += "    ";
        } else {
            while (il_itr != il_insns.end() && (*il_itr)->Start() < t.addr) {
                if ((*il_itr)->Kind() != ILInstr::Unknown) {
                    snprintf(buf, sizeof(buf), "0x%llx: %s\n",
                             (unsigned long long)(*il_itr)->Start(),
                             (*il_itr)->ToString().c_str());
                    out += buf;
                    if (standard) out += "    // ";
                    else out += "// ";
                }
                ++il_itr;
            }
            if (il_itr != il_insns.end() && (*il_itr)->Start() == t.addr) {
                if ((*il_itr)->Kind() != ILInstr::Unknown) {
                    snprintf(buf, sizeof(buf), "0x%llx: %s\n",
                             (unsigned long long)t.addr,
                             (*il_itr)->ToString().c_str());
                    out += buf;
                    if (standard) out += "    //     ";
                    else out += "// ";
                    range = (*il_itr)->Range();
                }
                ++il_itr;
            }
        }

        if (extra.empty())
            snprintf(buf, sizeof(buf), "0x%llx: %s\n",
                     (unsigned long long)t.addr, &t.text[0]);
        else
            snprintf(buf, sizeof(buf), "0x%llx: %s  ; %s\n",
                     (unsigned long long)t.addr, &t.text[0], extra.c_str());
        out += buf;
    }
    return out;
}

// src_code 用（fler 兼容格式）；空壳回退 fn->Name() 占位。
static std::string buildFunctionAsm(DartFunction* fn, DartApp& app, DartDumper& dumper) {
    if (!fn) return std::string();
    std::string out = buildFunctionAsmFull(fn, app, dumper, false);
    if (out.empty()) out = fn->Name();
    return out;
}

// 生成方法名（消除 <anonymous closure>，闭包带归属类前缀）
// 命名规则与标准 Blutter Dump4Ida 一致：闭包 -> "{cls}::{_anon_closure}_{addr}"
// 普通方法保留原名。返回可读名。
static std::string buildFunctionName(DartFunction* fn, DartClass* cls) {
    if (!fn) return std::string();
    std::string name = fn->Name();
    if (fn->IsClosure() || name == "<anonymous closure>") {
        std::string clsName = cls ? cls->Name() : std::string();
        char buf[64];
        snprintf(buf, sizeof(buf), "::_anon_closure_%llx",
                 (unsigned long long)fn->Address());
        return clsName + buf;
    }
    return name;
}

// 从对象 dump 文本提取类名（形如 "Obj!ClassName@addr" 或 "Obj!Class@addr"）
// 对象摘要：取顶层字段的字符串/int 值（丢弃嵌套体），供 objs 轻量索引
static std::string buildObjFieldHint(const std::string& dump) {
    // 提取第一层字段（depth==1 的直接子字段）的字符串/int 值做摘要
    // 格式：`  off_8: Map<...>(5) {`, `  off_1c: false`, `  off_18: "text"`
    // 只取字符串（含引号）与 int(0x..)，拼成 "off_x=\"val\", off_y=int(0xN)"
    std::string hint;
    std::string line;
    std::istringstream iss(dump);
    while (std::getline(iss, line)) {
        // 前导空格数 / 2 = 层级
        size_t lead = 0;
        while (lead < line.size() && line[lead] == ' ') lead++;
        int depth = (int)(lead / 2);
        std::string t = line.substr(lead);
        if (t.empty()) continue;
        // 只看第一层直接字段：off_xx: <value>
        if (depth == 1) {
            auto colon = t.find(':');
            if (colon == std::string::npos) continue;
            std::string key = t.substr(0, colon);
            // 去掉尾部空格；字段名形如 off_8 / off_10_Obj!xx@addr
            while (!key.empty() && (key.back() == ' ' || key.back() == '\t')) key.pop_back();
            if (key.empty()) continue;

            std::string val = t.substr(colon + 1);
            size_t vs = 0;
            while (vs < val.size() && (val[vs] == ' ' || val[vs] == '\t')) vs++;
            val = val.substr(vs);
            // 去掉尾逗号/花括号标记
            while (!val.empty() && (val.back() == ',' || val.back() == ' ' || val.back() == '\t')) val.pop_back();
            if (val.empty()) continue;

            // 只取字符串（"..."）与 int(0x..)/int(n)
            bool isStr = val.size() >= 2 && val.front() == '"' && val.back() == '"';
            bool isInt = val.rfind("int(", 0) == 0 && val.back() == ')';
            if (!isStr && !isInt) continue;

            if (!hint.empty()) hint += ", ";
            if (isStr) {
                std::string v = val.substr(1, val.size() - 2);
                if (v.size() > 80) v = v.substr(0, 80);
                hint += key + "=\"" + v + "\"";
            } else {
                hint += key + "=" + val;
            }
        }
    }
    if (hint.size() > 512) hint = hint.substr(0, 512);
    return hint;
}

// 从 dump 文本检测枚举：Super!_Enum : { off_8: int(0x..), off_10: "name" }
static void extractEnumMap(const std::string& dump, const std::string& clsName,
                           sqlite3* db) {
    if (dump.find("_Enum") == std::string::npos) return;
    // 找 off_8: int(0x..) 与 off_10: "name" 形态
    size_t idx8 = dump.find("off_8: int(0x");
    size_t idx10 = dump.find("off_10: \"");
    if (idx8 == std::string::npos || idx10 == std::string::npos) return;
    // 解析 index
    long long index = 0;
    {
        // "off_8: int(0x" 长度 13，数字紧随其后
        size_t v = idx8 + 13;
        index = strtoll(dump.c_str() + v, nullptr, 16);
    }
    // 解析 name
    std::string name;
    {
        // "off_10: \"" 长度 10，引号后内容紧随其后
        size_t v = idx10 + 10;
        size_t e = dump.find('"', v);
        if (e != std::string::npos) name = dump.substr(v, e - v);
    }
    if (name.empty()) return;
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db,
        "INSERT OR IGNORE INTO enum_map (class_name, enum_index, enum_name) VALUES (?,?,?)",
        -1, &st, nullptr) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, clsName.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 2, index);
        sqlite3_bind_text(st, 3, name.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_step(st);
    }
    sqlite3_finalize(st);
}

// 导出 classes + methods（直接遍历 DartApp 内存结构）
static void exportClassesAndMethods(DartApp& app, DartDumper& dumper) {
    const auto& libs = app.fler_libs();
    int classes = 0, methods = 0;
    g_db.exec("BEGIN TRANSACTION");

    for (auto* lib : libs) {
        if (!lib) continue;
        for (auto* cls : lib->classes) {
            if (!cls) continue;

            // classes (id, name, super_cls, fields)
            {
                // 生成字段描述："name@offset:type" 逗号分隔
                std::string fields;
                for (auto* f : cls->Fields()) {
                    if (!f) continue;
                    if (!fields.empty()) fields += ", ";
                    char offbuf[24];
                    snprintf(offbuf, sizeof(offbuf), "0x%x", f->Offset());
                    std::string typeName = "?";
                    if (f->Type()) typeName = f->Type()->ToString();
                    fields += f->Name() + "@" + offbuf + ":" + typeName;
                }
                sqlite3_stmt* st = nullptr;
                if (sqlite3_prepare_v2(g_db.db,
                    "INSERT OR IGNORE INTO classes (id, name, super_cls, fields) VALUES (?,?,?,?)",
                    -1, &st, nullptr) == SQLITE_OK) {
                    sqlite3_bind_int64(st, 1, (int64_t)cls->Id());
                    sqlite3_bind_text(st, 2, cls->Name().c_str(), -1, SQLITE_TRANSIENT);
                    const std::string super =
                        cls->Parent() ? cls->Parent()->Name() : std::string();
                    sqlite3_bind_text(st, 3, super.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(st, 4, fields.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_step(st);
                }
                sqlite3_finalize(st);
                classes++;
            }

            // methods (class_id, name, address, size, src_code)
            for (auto* fn : cls->Functions()) {
                if (!fn) continue;
                const std::string asmText = buildFunctionAsm(fn, app, dumper);
                const std::string mname = buildFunctionName(fn, cls);
                sqlite3_stmt* st = nullptr;
                if (sqlite3_prepare_v2(g_db.db,
                    "INSERT OR IGNORE INTO methods (class_id, name, address, size, src_code) VALUES (?,?,?,?,?)",
                    -1, &st, nullptr) == SQLITE_OK) {
                    sqlite3_bind_int64(st, 1, (int64_t)cls->Id());
                    sqlite3_bind_text(st, 2, mname.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_bind_int64(st, 3, (int64_t)fn->Address());
                    sqlite3_bind_int64(st, 4, (int64_t)fn->Size());
                    sqlite3_bind_text(st, 5, asmText.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_step(st);
                }
                sqlite3_finalize(st);
                methods++;
            }
        }
    }

    g_db.exec("COMMIT");
    fprintf(stderr, "fler-dart: exported %d classes, %d methods\n", classes, methods);
}

// 导出 asm_blocks（标准 DumpCode 格式的完整反汇编存档，独立于 methods.src_code）。
// 每方法一行：method_address（vaddr，与 methods.address 同坐标）、size、
// url（来源库名）、body（完整语义反汇编，与 asm/*.dart 内容一致）。
// 空壳方法（无 AnalyzedData / 无指令）跳过——引擎无法恢复的数据不产生记录。
static void exportAsmBlocks(DartApp& app, DartDumper& dumper) {
    const auto& libs = app.fler_libs();
    int blocks = 0;
    g_db.exec("BEGIN TRANSACTION");
    for (auto* lib : libs) {
        if (!lib) continue;
        const std::string url = lib->Url();
        for (auto* cls : lib->classes) {
            if (!cls) continue;
            for (auto* fn : cls->Functions()) {
                if (!fn) continue;
                auto* data = fn->GetAnalyzedData();
                if (!data || data->asmTexts.Data().empty()) continue;
                const std::string body = buildFunctionAsmFull(fn, app, dumper, true);
                if (body.empty()) continue;
                sqlite3_stmt* st = nullptr;
                if (sqlite3_prepare_v2(g_db.db,
                    "INSERT INTO asm_blocks (method_address, size, url, body) VALUES (?,?,?,?)",
                    -1, &st, nullptr) == SQLITE_OK) {
                    sqlite3_bind_int64(st, 1, (int64_t)fn->Address());
                    sqlite3_bind_int64(st, 2, (int64_t)fn->Size());
                    sqlite3_bind_text(st, 3, url.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(st, 4, body.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_step(st);
                }
                sqlite3_finalize(st);
                blocks++;
            }
        }
    }
    g_db.exec("COMMIT");
    fprintf(stderr, "fler-dart: exported %d asm_blocks\n", blocks);
}

// 导出 pp_entries + strings（复用 DartDumper 的对象池描述）
// 注意：必须用 simpleForm=false（与标准 Blutter DumpObjectPool 一致），
// 才能得到 "[pp+0x58] String: "..." / "List<qCb>(3) [Obj!...]" 完整格式，
// 且填充 knownObjectPtrs（供后续 DumpObjects 产出完整 objs.txt）。
static void exportObjectPool(DartApp& app, DartDumper& dumper) {
    const auto& pool = app.GetObjectPool();
    intptr_t num = pool.Length();
    int pp = 0, strings = 0;
    g_db.exec("BEGIN TRANSACTION");

    for (intptr_t i = 0; i < num; i++) {
        intptr_t offset = dart::ObjectPool::OffsetFromIndex(i) + 1;
        std::string desc = dumper.FlPoolDescription(offset, false);
        if (desc.empty()) continue;

        // 拆分 type / value（"Type: value" 形式）
        // desc 形如 "[pp+0x58] String: "内容"" / "[pp+0x40] List(5) [..]" / "[pp+0x10] Stub: X (0x..)"
        std::string type, value;
        auto pos = desc.find(": ");
        if (pos != std::string::npos && pos > 0) {
            type = desc.substr(0, pos);
            // 0.5.1 schema: type stores only the semantic type. The PP offset
            // is already available in pp_offset and must not be duplicated here.
            if (type.rfind("[pp+", 0) == 0) {
                const auto close = type.find(']');
                if (close != std::string::npos) type = type.substr(close + 1);
                while (!type.empty() && type.front() == ' ') type.erase(type.begin());
            }
            value = desc.substr(pos + 2);
        } else {
            type = "";
            value = desc;
        }

        // 判断是否为 String：描述含 "] String: "
        bool isString = false;
        {
            auto sp = desc.find("] String: ");
            isString = (sp != std::string::npos);
        }

        sqlite3_stmt* st = nullptr;
        if (sqlite3_prepare_v2(g_db.db,
            "INSERT OR IGNORE INTO pp_entries (pp_offset, type, value) VALUES (?,?,?)",
            -1, &st, nullptr) == SQLITE_OK) {
            sqlite3_bind_int64(st, 1, (int64_t)offset);
            sqlite3_bind_text(st, 2, type.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 3, value.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_step(st);
        }
        sqlite3_finalize(st);
        pp++;

        // String 类型同时进 strings 表（去掉引号）
        if (isString) {
            std::string sv = value;
            if (sv.size() >= 2 && sv.front() == '"' && sv.back() == '"')
                sv = sv.substr(1, sv.size() - 2);
            sqlite3_stmt* s2 = nullptr;
            if (sqlite3_prepare_v2(g_db.db,
                "INSERT OR IGNORE INTO strings (pp_offset, value) VALUES (?,?)",
                -1, &s2, nullptr) == SQLITE_OK) {
                sqlite3_bind_int64(s2, 1, (int64_t)offset);
                sqlite3_bind_text(s2, 2, sv.c_str(), -1, SQLITE_TRANSIENT);
                sqlite3_step(s2);
            }
            sqlite3_finalize(s2);
            strings++;
        }
    }

    g_db.exec("COMMIT");
    fprintf(stderr, "fler-dart: exported %d pp entries, %d strings\n", pp, strings);
}

// 建立字符串到方法的交叉引用。AsmText::PoolOffset 是恢复后的真实 PP 槽偏移，
// 与 strings.pp_offset 一一对应；用主键去重，避免同一方法重复引用造成计数膨胀。
static void exportStringRefs(DartApp& app) {
    sqlite3_stmt* insert = nullptr;
    if (sqlite3_prepare_v2(g_db.db,
        "INSERT OR IGNORE INTO string_refs (string_id, method_address) "
        "SELECT id, ? FROM strings WHERE pp_offset = ?",
        -1, &insert, nullptr) != SQLITE_OK) return;

    int refs = 0;
    g_db.exec("BEGIN TRANSACTION");
    for (auto* lib : app.fler_libs()) {
        if (!lib) continue;
        for (auto* cls : lib->classes) {
            if (!cls) continue;
            for (auto* fn : cls->Functions()) {
                if (!fn) continue;
                auto* data = fn->GetAnalyzedData();
                if (!data) continue;
                for (const auto& text : data->asmTexts.Data()) {
                    if (text.dataType != AsmText::PoolOffset) continue;
                    sqlite3_reset(insert);
                    sqlite3_clear_bindings(insert);
                    sqlite3_bind_int64(insert, 1, (int64_t)fn->Address());
                    sqlite3_bind_int64(insert, 2, (int64_t)text.poolOffset);
                    if (sqlite3_step(insert) == SQLITE_DONE && sqlite3_changes(g_db.db) > 0) refs++;
                }
            }
        }
    }
    sqlite3_finalize(insert);
    g_db.exec("UPDATE strings SET ref_count = "
              "(SELECT COUNT(*) FROM string_refs r WHERE r.string_id = strings.id)");
    g_db.exec("COMMIT");
    fprintf(stderr, "fler-dart: exported %d string refs\n", refs);
}

// 导出 objs 轻量索引 + enum_map（对象堆 dump 的摘要）
// 依赖：exportProducts 已调用 DumpObjects 产出 objs.txt（knownObjectPtrs 由
// exportObjectPool(simpleForm=false) 填充）。本函数解析 objs.txt 文本入库，
// 保证索引与落地产物完全一致。
static void exportObjsIndex(const std::string& objsPath) {
    std::ifstream in(objsPath);
    if (!in) {
        fprintf(stderr, "fler-dart: cannot open objs.txt: %s\n", objsPath.c_str());
        return;
    }
    int objs = 0;
    g_db.exec("BEGIN TRANSACTION");
    std::string dump, line;
    while (std::getline(in, line)) {
        // 对象以 "Obj!X@addr : {" 开头，空行结束
        auto p = line.find("Obj!");
        if (p != std::string::npos && dump.empty()) {
            // 提取地址与类名
            auto at = line.find('@', p + 4);
            if (at == std::string::npos) { dump.clear(); continue; }
            std::string addrStr;
            size_t a = at + 1;
            while (a < line.size() && line[a] != ' ' && line[a] != ':') { addrStr += line[a]; a++; }
            if (addrStr.empty()) { dump.clear(); continue; }
            long long addr = strtoll(addrStr.c_str(), nullptr, 16);
            std::string clsName = line.substr(p + 4, at - (p + 4));
            dump = line;
            // 继续读直到空行（对象结束）
            std::string rest;
            while (std::getline(in, rest)) {
                if (rest.empty()) break;
                dump += "\n" + rest;
            }
            // 摘要 + enum
            std::string hint = buildObjFieldHint(dump);
            sqlite3_stmt* st = nullptr;
            if (sqlite3_prepare_v2(g_db.db,
                "INSERT OR IGNORE INTO objs (obj_address, class_name, field_hint) VALUES (?,?,?)",
                -1, &st, nullptr) == SQLITE_OK) {
                sqlite3_bind_int64(st, 1, addr);
                sqlite3_bind_text(st, 2, clsName.c_str(), -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(st, 3, hint.c_str(), -1, SQLITE_TRANSIENT);
                sqlite3_step(st);
            }
            sqlite3_finalize(st);
            objs++;
            extractEnumMap(dump, clsName, g_db.db);
            dump.clear();
        } else if (!dump.empty()) {
            // 理论上不会到这（上面已消费到空行）
            dump.clear();
        }
    }
    g_db.exec("COMMIT");
    fprintf(stderr, "fler-dart: exported %d objs entries from objs.txt\n", objs);
}

// 落地全部标准 Blutter 产物到 out_dir（与标准 main.cpp 一致）
static void exportProducts(DartApp& app, DartDumper& dumper, const std::string& outDir) {
    std::error_code ec;
    fs::create_directories(outDir, ec);

    std::string ppPath = outDir + "/pp.txt";
    std::string objsPath = outDir + "/objs.txt";
    std::string asmDir = outDir + "/asm";
    std::string idaDir = outDir + "/ida_script";
    std::string fridaPath = outDir + "/blutter_frida.js";

    fprintf(stderr, "fler-dart: dumping products to %s\n", outDir.c_str());

    // pp.txt
    dumper.DumpObjectPool(ppPath.c_str());
    fprintf(stderr, "fler-dart: pp.txt dumped\n");

    // objs.txt（knownObjectPtrs 由 exportObjectPool 填充）
    dumper.DumpObjects(objsPath.c_str());
    fprintf(stderr, "fler-dart: objs.txt dumped\n");

    // asm/
    fs::create_directories(asmDir, ec);
    dumper.DumpCode(asmDir.c_str());
    fprintf(stderr, "fler-dart: asm/ dumped\n");

    // ida_script/
    dumper.Dump4Ida(idaDir);
    fprintf(stderr, "fler-dart: ida_script dumped\n");

    // blutter_frida.js
    FridaWriter fwriter{ app };
    fwriter.Create(fridaPath.c_str());
    fprintf(stderr, "fler-dart: blutter_frida.js dumped\n");
}

// ─── Temp dir helpers ──────────────────────────
static bool createTempDir(char* buf, size_t sz) {
    // 优先用 TMPDIR（bridge 会 chdir + setenv 到 App 可写目录，避免 /data/local/tmp 不可写）
    const char* tmp = getenv("TMPDIR");
    if (tmp && tmp[0]) {
        std::string tmpl = std::string(tmp) + "/fler_XXXXXX";
        if (sz >= tmpl.size() + 1) {
            strncpy(buf, tmpl.c_str(), sz);
            if (mkdtemp(buf) != nullptr) return true;
        }
    }
    const char* tmpl = "/data/local/tmp/fler_XXXXXX";
    if (sz < strlen(tmpl) + 1) return false;
    strncpy(buf, tmpl, sz);
    if (mkdtemp(buf) == nullptr) {
        const char* alt = "/tmp/fler_XXXXXX";
        strncpy(buf, alt, sz);
        if (mkdtemp(buf) == nullptr) return false;
    }
    return true;
}

static void removeDir(const char* path) {
    DIR* d = opendir(path); if (!d) return;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        std::string n(e->d_name);
        if (n == "." || n == "..") continue;
        std::string f = std::string(path) + "/" + n;
        if (e->d_type == DT_DIR) removeDir(f.c_str());
        else unlink(f.c_str());
    }
    closedir(d); rmdir(path);
}

// ─── Exported entry point ─────────────────────
// so_path: path to libapp.so on device
// db_path: path for SQLite output
// out_dir: path for dumped products (pp.txt/objs.txt/asm/ida_script/blutter_frida.js)
// Returns 0 on success

// fler-dart vm-reuse: the Dart VM is kept alive across analyses in the same
// process (Dart_Cleanup is not called). If a worker (IO) thread is reused for a
// new analysis, the previous isolate may still be current on it, which makes
// Dart_CreateIsolate fail with:
//   "CreateIsolate expects there to be no current isolate".
// Detach (and shut down) any leftover isolate before starting the next analysis
// so the thread is left in a clean state. App-side analysis is serialized onto a
// single dedicated thread (AnalysisSerialExecutor) which also helps here.
static void detachLeftoverIsolate() {
    if (Dart_CurrentIsolate() != nullptr) {
        // Dart_ExitIsolate clears the thread's current isolate; the subsequent
        // Dart_ShutdownIsolate releases the isolate so repeated analyses do not
        // leak isolates inside the (kept-alive) Dart VM.
        Dart_ExitIsolate();
        Dart_ShutdownIsolate();
    }
}

extern "C" __attribute__((visibility("default")))
int blutter_analyze(const char* so_path, const char* db_path, const char* out_dir) {
    fprintf(stderr, "fler-dart: analyze(so=%s, db=%s, out=%s)\n", so_path, db_path, out_dir);

    detachLeftoverIsolate();

    char tmpdir[256] = {};
    if (!createTempDir(tmpdir, sizeof(tmpdir))) { fprintf(stderr, "fler-dart: temp dir failed\n"); return -1; }

    try {
        DartApp app{ so_path };
        app.EnterScope(); app.LoadInfo(); app.ExitScope();
#ifndef NO_CODE_ANALYSIS
        app.EnterScope(); CodeAnalyzer ca{ app }; ca.AnalyzeAll(); app.ExitScope();
#endif
        if (!g_db.open(db_path)) { removeDir(tmpdir); return -3; }
        createTables();

        app.EnterScope();
        {
            DartDumper dumper{ app };
            exportClassesAndMethods(app, dumper);
            // 独立表：标准 DumpCode 格式完整反汇编存档（与 asm/*.dart 一致）
            exportAsmBlocks(app, dumper);
            // simpleForm=false：恢复标准描述格式 + 填充 knownObjectPtrs
            exportObjectPool(app, dumper);
            exportStringRefs(app);
            // 落地全部标准产物
            std::string od = out_dir ? out_dir : "";
            if (!od.empty()) {
                exportProducts(app, dumper, od);
                exportObjsIndex(od + "/objs.txt");
            }
        }
        app.ExitScope();

        g_db.close();
    } catch (std::exception& e) {
        fprintf(stderr, "fler-dart: analysis failed: %s\n", e.what());
        removeDir(tmpdir); return -2;
    } catch (...) {
        fprintf(stderr, "fler-dart: analysis failed: uncaught exception (InsnException etc.)\n");
        removeDir(tmpdir); return -2;
    }

    // Leave the worker thread with no current isolate so the next analysis on
    // the same thread can create a fresh one (vm-reuse keeps the VM alive).
    detachLeftoverIsolate();

    removeDir(tmpdir);
    fprintf(stderr, "fler-dart: done, db = %s\n", db_path);
    return 0;
}
