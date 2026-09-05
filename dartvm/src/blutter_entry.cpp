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
#include <csetjmp>
#include <csignal>
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

// ─── CodeAnalyzer 崩溃隔离（SIGSEGV → 降级为只导出不反汇编）───
// Blutter CodeAnalyzer 对某些 libapp.so 会读无效内存导致 SIGSEGV（健壮性缺陷）。
// 该崩溃是进程级信号，C++ try-catch 捕获不到；这里用 sigsetjmp/siglongjmp 把
// CodeAnalyzer 隔离在独立保护区：崩溃则跳过反汇编、继续导出对象池/类/方法，
// 使「引擎崩溃」降级为「部分成功」而不是整个分析失败。
namespace {
// 注意：不能用 thread_local！引擎 .so 是运行时 dlopen 的，其 TLS 走 general-dynamic
// 模型，signal handler 里访问会触发 __tls_get_addr（非 async-signal-safe），导致
// caCrashHandler 在崩溃现场再次卡死/崩溃，siglongjmp 无法执行。分析本身单线程
// （blutter_analyze 在单一线程内跑，watchdog 仅 pthread_kill 不触碰这些变量），
// 用普通 static 全局即可，signal handler 里直接绝对地址访问，安全。
static sigjmp_buf g_ca_jmp;
static volatile sig_atomic_t g_ca_crash = 0;

static void caCrashHandler(int sig, siginfo_t*, void*) {
    g_ca_crash = sig;
    // write(2) 为 async-signal-safe，用于确认 handler 被调用（fprintf 不安全）。
    const char msg[] = "fler-dart: caCrashHandler called\n";
    write(2, msg, sizeof(msg) - 1);
    siglongjmp(g_ca_jmp, 1);
}
} // namespace

// ─── SQLite wrapper ─────────────────────────────
struct Db {
    sqlite3* db = nullptr;

    bool open(const char* path) {
        int rc = sqlite3_open(path, &db);
        if (rc != SQLITE_OK) {
            fprintf(stderr, "SQLite open failed: %s\n", sqlite3_errmsg(db));
            return false;
        }
        sqlite3_busy_timeout(db, 5000);
        exec("PRAGMA temp_store=MEMORY");
        exec("PRAGMA synchronous=NORMAL");
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
        "  UNIQUE(class_id, name, address)"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS analysis_meta ("
        "  key TEXT PRIMARY KEY,"
        "  value TEXT NOT NULL"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS method_analysis ("
        "  method_id INTEGER PRIMARY KEY,"
        "  method_address INTEGER NOT NULL,"
        "  status TEXT NOT NULL,"
        "  error TEXT"
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

// Include the synthetic/native library as well. Obfuscated AOT snapshots can
// contain code objects whose owner is not recoverable; DartApp stores those
// functions under nativeLib instead of the normal library vector.
static std::vector<DartLibrary*> exportLibraries(DartApp& app) {
    std::vector<DartLibrary*> out = app.fler_libs();
    auto* native = app.fler_native_lib();
    if (native && std::find(out.begin(), out.end(), native) == out.end())
        out.push_back(native);
    return out;
}

// Classify every exported method, including methods for which disassembly
// failed or was intentionally disabled. This makes partial results explicit.
static void writeMethodAnalysis(DartApp& app) {
    g_db.exec("DELETE FROM method_analysis");
    g_db.exec(
        "INSERT OR REPLACE INTO method_analysis(method_id,method_address,status,error) "
        "SELECT rowid, address, CASE "
        "WHEN size IS NULL OR size <= 0 THEN 'EMPTY' "
        "WHEN src_code IS NOT NULL AND instr(src_code, '0x') > 0 THEN 'ANALYZED' "
        "ELSE 'METADATA_ONLY' END, NULL FROM methods"
    );
    sqlite3_stmt* update = nullptr;
    if (sqlite3_prepare_v2(g_db.db,
        "UPDATE method_analysis SET error=? WHERE method_address=?",
        -1, &update, nullptr) == SQLITE_OK) {
        for (const auto& [address, error] : app.fler_analysis_errors()) {
            sqlite3_reset(update);
            sqlite3_clear_bindings(update);
            sqlite3_bind_text(update, 1, error.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(update, 2, static_cast<sqlite3_int64>(address));
            sqlite3_step(update);
        }
    }
    sqlite3_finalize(update);
}

// Store factual coverage statistics instead of treating rc=0 as a complete
// analysis. Values are text so this table remains forward/backward compatible.
static void writeAnalysisMeta(bool noCodeAnalysis) {
    g_db.exec("DELETE FROM analysis_meta");
    sqlite3_stmt* st = nullptr;
    const char* sql = "INSERT OR REPLACE INTO analysis_meta(key,value) VALUES(?,?)";
    if (sqlite3_prepare_v2(g_db.db, sql, -1, &st, nullptr) != SQLITE_OK) return;

    auto put = [&](const char* key, const std::string& value) {
        sqlite3_reset(st);
        sqlite3_clear_bindings(st);
        sqlite3_bind_text(st, 1, key, -1, SQLITE_STATIC);
        sqlite3_bind_text(st, 2, value.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_step(st);
    };
    auto count = [&](const char* table) -> long long {
        std::string q = "SELECT COUNT(*) FROM " + std::string(table);
        sqlite3_stmt* qst = nullptr;
        long long n = 0;
        if (sqlite3_prepare_v2(g_db.db, q.c_str(), -1, &qst, nullptr) == SQLITE_OK &&
            sqlite3_step(qst) == SQLITE_ROW) n = sqlite3_column_int64(qst, 0);
        sqlite3_finalize(qst);
        return n;
    };
    auto scalar = [&](const char* key, const char* expression) {
        std::string q = "SELECT COUNT(*) FROM methods WHERE " + std::string(expression);
        sqlite3_stmt* qst = nullptr;
        long long n = 0;
        if (sqlite3_prepare_v2(g_db.db, q.c_str(), -1, &qst, nullptr) == SQLITE_OK &&
            sqlite3_step(qst) == SQLITE_ROW) n = sqlite3_column_int64(qst, 0);
        sqlite3_finalize(qst);
        put(key, std::to_string(n));
    };

    put("engine_abi", "fler-dart-v0.5.16");
#ifdef DART_VERSION
    put("dart_version", DART_VERSION);
#else
    put("dart_version", "unknown");
#endif
#ifdef DART_COMPRESSED_POINTERS
    put("compressed_pointers", "true");
#else
    put("compressed_pointers", "false");
#endif
    put("analysis_mode", noCodeAnalysis ? "metadata_only" : "code_analysis");
    put("total_classes", std::to_string(count("classes")));
    put("total_methods", std::to_string(count("methods")));
    scalar("analyzed_methods", "src_code IS NOT NULL AND instr(src_code, '0x') > 0");
    scalar("metadata_only_methods", "src_code IS NULL OR instr(src_code, '0x') = 0");
    auto statusCount = [&](const char* status) -> long long {
        sqlite3_stmt* qst = nullptr;
        long long n = 0;
        if (sqlite3_prepare_v2(g_db.db,
                "SELECT COUNT(*) FROM method_analysis WHERE status=?",
                -1, &qst, nullptr) == SQLITE_OK) {
            sqlite3_bind_text(qst, 1, status, -1, SQLITE_STATIC);
            if (sqlite3_step(qst) == SQLITE_ROW) n = sqlite3_column_int64(qst, 0);
        }
        sqlite3_finalize(qst);
        return n;
    };
    put("empty_methods", std::to_string(statusCount("EMPTY")));
    put("failed_methods", std::to_string(noCodeAnalysis ? 0 : statusCount("METADATA_ONLY")));
    put("unknown_functions", std::to_string(statusCount("UNKNOWN")));
    sqlite3_stmt* errorStmt = nullptr;
    long long errorCount = 0;
    if (sqlite3_prepare_v2(g_db.db,
            "SELECT COUNT(*) FROM method_analysis WHERE error IS NOT NULL AND error <> ''",
            -1, &errorStmt, nullptr) == SQLITE_OK && sqlite3_step(errorStmt) == SQLITE_ROW)
        errorCount = sqlite3_column_int64(errorStmt, 0);
    sqlite3_finalize(errorStmt);
    put("method_errors", std::to_string(errorCount));
    put("asm_blocks", std::to_string(count("asm_blocks")));
    put("pp_entries", std::to_string(count("pp_entries")));
    put("strings", std::to_string(count("strings")));
    put("string_refs", std::to_string(count("string_refs")));
    sqlite3_finalize(st);
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
    const auto libs = exportLibraries(app);
    int classes = 0, methods = 0, classErrors = 0, methodErrors = 0;
    sqlite3_stmt* classStmt = nullptr;
    sqlite3_stmt* methodStmt = nullptr;
    const char* classSql =
        "INSERT OR IGNORE INTO classes (id, name, super_cls, fields) VALUES (?,?,?,?)";
    const char* methodSql =
        "INSERT OR IGNORE INTO methods (class_id, name, address, size, src_code) VALUES (?,?,?,?,?)";
    if (sqlite3_prepare_v2(g_db.db, classSql, -1, &classStmt, nullptr) != SQLITE_OK ||
        sqlite3_prepare_v2(g_db.db, methodSql, -1, &methodStmt, nullptr) != SQLITE_OK) {
        fprintf(stderr, "fler-dart: prepare classes/methods statements failed\n");
        sqlite3_finalize(classStmt);
        sqlite3_finalize(methodStmt);
        return;
    }

    g_db.exec("BEGIN TRANSACTION");
    for (auto* lib : libs) {
        if (!lib) continue;
        for (auto* cls : lib->classes) {
            if (!cls) continue;
            std::string fields;
#ifndef NO_CODE_ANALYSIS
            for (auto* f : cls->Fields()) {
                if (!f) continue;
                if (!fields.empty()) fields += ", ";
                char offbuf[24];
                snprintf(offbuf, sizeof(offbuf), "0x%x", f->Offset());
                std::string typeName = "?";
                if (f->Type()) typeName = f->Type()->ToString();
                fields += f->Name() + "@" + offbuf + ":" + typeName;
            }
#endif
            sqlite3_reset(classStmt);
            sqlite3_clear_bindings(classStmt);
            sqlite3_bind_int64(classStmt, 1, (int64_t)cls->Id());
            sqlite3_bind_text(classStmt, 2, cls->Name().c_str(), -1, SQLITE_TRANSIENT);
#ifndef NO_CODE_ANALYSIS
            const std::string super = cls->Parent() ? cls->Parent()->Name() : std::string();
#else
            const std::string super;
#endif
            sqlite3_bind_text(classStmt, 3, super.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(classStmt, 4, fields.c_str(), -1, SQLITE_TRANSIENT);
            if (sqlite3_step(classStmt) == SQLITE_DONE) classes++;
            else classErrors++;

            for (auto* fn : cls->Functions()) {
                if (!fn) continue;
                const std::string asmText =
#ifndef NO_CODE_ANALYSIS
                    buildFunctionAsm(fn, app, dumper);
#else
                    fn->Name();
#endif
                const std::string mname = buildFunctionName(fn, cls);
                sqlite3_reset(methodStmt);
                sqlite3_clear_bindings(methodStmt);
                sqlite3_bind_int64(methodStmt, 1, (int64_t)cls->Id());
                sqlite3_bind_text(methodStmt, 2, mname.c_str(), -1, SQLITE_TRANSIENT);
                sqlite3_bind_int64(methodStmt, 3, (int64_t)fn->Address());
                sqlite3_bind_int64(methodStmt, 4, (int64_t)fn->Size());
                sqlite3_bind_text(methodStmt, 5, asmText.c_str(), -1, SQLITE_TRANSIENT);
                if (sqlite3_step(methodStmt) == SQLITE_DONE) methods++;
                else methodErrors++;
            }
        }
    }
    g_db.exec("COMMIT");
    sqlite3_finalize(classStmt);
    sqlite3_finalize(methodStmt);
    fprintf(stderr, "fler-dart: exported %d classes, %d methods (db errors: %d/%d)\n",
            classes, methods, classErrors, methodErrors);
}

// 导出 asm_blocks（标准 DumpCode 格式的完整反汇编存档，独立于 methods.src_code）。
// 每方法一行：method_address（vaddr，与 methods.address 同坐标）、size、
// url（来源库名）、body（完整语义反汇编，与 asm/*.dart 内容一致）。
// 空壳方法（无 AnalyzedData / 无指令）跳过——引擎无法恢复的数据不产生记录。
static void exportAsmBlocks(DartApp& app, DartDumper& dumper) {
    const auto libs = exportLibraries(app);
    int blocks = 0, errors = 0;
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(g_db.db,
            "INSERT INTO asm_blocks (method_address, size, url, body) VALUES (?,?,?,?)",
            -1, &stmt, nullptr) != SQLITE_OK) {
        fprintf(stderr, "fler-dart: prepare asm_blocks statement failed\n");
        return;
    }
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
                sqlite3_reset(stmt);
                sqlite3_clear_bindings(stmt);
                sqlite3_bind_int64(stmt, 1, (int64_t)fn->Address());
                sqlite3_bind_int64(stmt, 2, (int64_t)fn->Size());
                sqlite3_bind_text(stmt, 3, url.c_str(), -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmt, 4, body.c_str(), -1, SQLITE_TRANSIENT);
                if (sqlite3_step(stmt) == SQLITE_DONE) blocks++;
                else errors++;
            }
        }
    }
    g_db.exec("COMMIT");
    sqlite3_finalize(stmt);
    fprintf(stderr, "fler-dart: exported %d asm_blocks (errors=%d)\n", blocks, errors);
}

// 导出 pp_entries + strings（复用 DartDumper 的对象池描述）
// 注意：必须用 simpleForm=false（与标准 Blutter DumpObjectPool 一致），
// 才能得到 "[pp+0x58] String: "..." / "List<qCb>(3) [Obj!...]" 完整格式，
// 且填充 knownObjectPtrs（供后续 DumpObjects 产出完整 objs.txt）。
static void exportObjectPool(DartApp& app, DartDumper& dumper) {
    const auto& pool = app.GetObjectPool();
    intptr_t num = pool.Length();
    int pp = 0, strings = 0, errors = 0;
    sqlite3_stmt* ppStmt = nullptr;
    sqlite3_stmt* stringStmt = nullptr;
    if (sqlite3_prepare_v2(g_db.db,
            "INSERT OR IGNORE INTO pp_entries (pp_offset, type, value) VALUES (?,?,?)",
            -1, &ppStmt, nullptr) != SQLITE_OK ||
        sqlite3_prepare_v2(g_db.db,
            "INSERT OR IGNORE INTO strings (pp_offset, value) VALUES (?,?)",
            -1, &stringStmt, nullptr) != SQLITE_OK) {
        fprintf(stderr, "fler-dart: prepare object pool statements failed\n");
        sqlite3_finalize(ppStmt);
        sqlite3_finalize(stringStmt);
        return;
    }

    g_db.exec("BEGIN TRANSACTION");
    for (intptr_t i = 0; i < num; i++) {
        intptr_t offset = dart::ObjectPool::OffsetFromIndex(i) + 1;
        std::string desc;
        try {
            desc = dumper.FlPoolDescription(offset, false);
        } catch (const std::exception& e) {
            fprintf(stderr, "fler-dart: skip object pool index=%ld (%s)\n", (long)i, e.what());
            errors++;
            continue;
        }
        if (desc.empty()) continue;

        std::string type, value;
        auto pos = desc.find(": ");
        if (pos != std::string::npos && pos > 0) {
            type = desc.substr(0, pos);
            if (type.rfind("[pp+", 0) == 0) {
                const auto close = type.find(']');
                if (close != std::string::npos) type = type.substr(close + 1);
                while (!type.empty() && type.front() == ' ') type.erase(type.begin());
            }
            value = desc.substr(pos + 2);
        } else {
            value = desc;
        }

        sqlite3_reset(ppStmt);
        sqlite3_clear_bindings(ppStmt);
        sqlite3_bind_int64(ppStmt, 1, (int64_t)offset);
        sqlite3_bind_text(ppStmt, 2, type.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(ppStmt, 3, value.c_str(), -1, SQLITE_TRANSIENT);
        if (sqlite3_step(ppStmt) != SQLITE_DONE) errors++;
        else pp++;

        const bool isString = desc.find("] String: ") != std::string::npos;
        if (isString) {
            std::string sv = value;
            if (sv.size() >= 2 && sv.front() == '"' && sv.back() == '"')
                sv = sv.substr(1, sv.size() - 2);
            sqlite3_reset(stringStmt);
            sqlite3_clear_bindings(stringStmt);
            sqlite3_bind_int64(stringStmt, 1, (int64_t)offset);
            sqlite3_bind_text(stringStmt, 2, sv.c_str(), -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stringStmt) != SQLITE_DONE) errors++;
            else strings++;
        }
    }
    g_db.exec("COMMIT");
    sqlite3_finalize(ppStmt);
    sqlite3_finalize(stringStmt);
    fprintf(stderr, "fler-dart: exported %d pp entries, %d strings (errors=%d)\n",
            pp, strings, errors);
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

    fprintf(stderr, "fler-dart: stage=detach-isolate\n");
    fflush(stderr);
    detachLeftoverIsolate();

    char tmpdir[256] = {};
    if (!createTempDir(tmpdir, sizeof(tmpdir))) { fprintf(stderr, "fler-dart: temp dir failed\n"); return -1; }

    try {
        fprintf(stderr, "fler-dart: stage=create-app\n");
        fflush(stderr);
        DartApp app{ so_path };
        fprintf(stderr, "fler-dart: stage=load-info\n");
        fflush(stderr);
        app.EnterScope(); app.LoadInfo(); app.ExitScope();
        fprintf(stderr, "fler-dart: stage=load-info-done\n");
        fflush(stderr);
#ifndef NO_CODE_ANALYSIS
        {
            // 隔离 CodeAnalyzer：崩溃则降级为只导出不反汇编（见 caCrashHandler）。
            struct sigaction sa;
            memset(&sa, 0, sizeof(sa));
            sa.sa_sigaction = caCrashHandler;
            sa.sa_flags = SA_SIGINFO;
            sigemptyset(&sa.sa_mask);
            struct sigaction old_segv, old_bus, old_fpe, old_abrt, old_ill;
            sigaction(SIGSEGV, &sa, &old_segv);
            sigaction(SIGBUS, &sa, &old_bus);
            sigaction(SIGFPE, &sa, &old_fpe);
            sigaction(SIGABRT, &sa, &old_abrt);
            sigaction(SIGILL, &sa, &old_ill);

            g_ca_crash = 0;
            if (sigsetjmp(g_ca_jmp, 1) == 0) {
                app.EnterScope();
                CodeAnalyzer ca{ app };
                ca.AnalyzeAll();
                app.ExitScope();
            } else {
                // CodeAnalyzer 崩溃：跳过反汇编。这里【不】调用 ExitScope——Dart_ExitScope
                // 在 isolate 状态可能已损坏时也会崩溃，而崩溃隔离的 signal handler 尚未恢复，
                // 二次崩溃会再次 siglongjmp（g_ca_jmp 已消费，行为未定义）导致降级失效、
                // 最终仍以 -997 收场。EnterScope/ExitScope 均有 inScope 幂等标志，保持
                // inScope=true 不会 double-enter，后续导出按 GetAnalyzedData()==null 自动退化。
                fprintf(stderr,
                        "fler-dart: CodeAnalyzer crashed (signal %d), fallback to no-analysis export\n",
                        (int)g_ca_crash);
            }

            sigaction(SIGSEGV, &old_segv, nullptr);
            sigaction(SIGBUS, &old_bus, nullptr);
            sigaction(SIGFPE, &old_fpe, nullptr);
            sigaction(SIGABRT, &old_abrt, nullptr);
            sigaction(SIGILL, &old_ill, nullptr);
        }
#endif
        fprintf(stderr, "fler-dart: stage=open-database\n");
        fflush(stderr);
        if (!g_db.open(db_path)) { removeDir(tmpdir); return -3; }
        createTables();

        app.EnterScope();
        {
            DartDumper dumper{ app };
            // 核心表最先导出并独立 COMMIT。即使之后对象池、附加文件或析构崩溃，
            // App 也能检测并保留 classes/methods，而不是误重试压缩指针对侧变体。
            fprintf(stderr, "fler-dart: stage=export-classes-methods\n");
            fflush(stderr);
            exportClassesAndMethods(app, dumper);
            fprintf(stderr, "fler-dart: stage=export-classes-methods-done\n");
            fflush(stderr);
#ifndef NO_CODE_ANALYSIS
            fprintf(stderr, "fler-dart: stage=export-asm\n");
            fflush(stderr);
            exportAsmBlocks(app, dumper);
#endif
            fprintf(stderr, "fler-dart: stage=export-object-pool\n");
            fflush(stderr);
            exportObjectPool(app, dumper);
#ifndef NO_CODE_ANALYSIS
            exportStringRefs(app);
            // 标准引擎落地全部 Blutter 附加产物。安全引擎不生成 objs/IDA/Frida：
            // 这些并非数据库浏览必需，并且是旧 Dart 快照后处理崩溃的高风险区。
            std::string od = out_dir ? out_dir : "";
            if (!od.empty()) {
                fprintf(stderr, "fler-dart: stage=export-products\n");
                fflush(stderr);
                exportProducts(app, dumper, od);
                exportObjsIndex(od + "/objs.txt");
            }
#endif
            fprintf(stderr, "fler-dart: stage=exports-done\n");
            fflush(stderr);
        }
        app.ExitScope();

        writeMethodAnalysis(app);
#ifndef NO_CODE_ANALYSIS
        writeAnalysisMeta(false);
#else
        writeAnalysisMeta(true);
#endif
        fprintf(stderr, "fler-dart: stage=analysis-meta-written\n");
        fflush(stderr);
        g_db.close();
        fprintf(stderr, "fler-dart: stage=database-closed\n");
        fflush(stderr);
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
