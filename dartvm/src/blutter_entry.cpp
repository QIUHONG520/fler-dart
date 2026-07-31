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
        "  src_code TEXT"
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
        "  value TEXT,"
        "  so_addr INTEGER"
        ")"
    );
    g_db.exec(
        "CREATE TABLE IF NOT EXISTS string_refs ("
        "  string_id INTEGER REFERENCES strings(id),"
        "  method_address INTEGER NOT NULL,"
        "  PRIMARY KEY (string_id, method_address)"
        ")"
    );
}

// ─── 直接内存导出（方案 A）─────────────────────

// 用 AnalyzedFnData 的 asm 文本生成函数反汇编（src_code，App 端 ASM 浏览用）
static std::string buildFunctionAsm(DartFunction* fn) {
    std::string out;
    if (!fn) return out;
    const auto* data = fn->GetAnalyzedData();
    if (data) {
        const auto& texts = data->asmTexts.Data();
        char buf[160];
        for (const auto& t : texts) {
            snprintf(buf, sizeof(buf), "// 0x%llx: %s\n",
                     (unsigned long long)t.addr, t.text);
            out += buf;
        }
    }
    if (out.empty()) {
        out = fn->Name();
    }
    return out;
}

// 导出 classes + methods（直接遍历 DartApp 内存结构）
static void exportClassesAndMethods(DartApp& app) {
    const auto& libs = app.fler_libs();
    int classes = 0, methods = 0;
    g_db.exec("BEGIN TRANSACTION");

    for (auto* lib : libs) {
        if (!lib) continue;
        for (auto* cls : lib->classes) {
            if (!cls) continue;

            // classes (id, name, super_cls)
            {
                sqlite3_stmt* st = nullptr;
                if (sqlite3_prepare_v2(g_db.db,
                    "INSERT OR IGNORE INTO classes (id, name, super_cls) VALUES (?,?,?)",
                    -1, &st, nullptr) == SQLITE_OK) {
                    sqlite3_bind_int64(st, 1, (int64_t)cls->Id());
                    sqlite3_bind_text(st, 2, cls->Name().c_str(), -1, SQLITE_TRANSIENT);
                    const std::string super =
                        cls->Parent() ? cls->Parent()->Name() : std::string();
                    sqlite3_bind_text(st, 3, super.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_step(st);
                }
                sqlite3_finalize(st);
                classes++;
            }

            // methods (class_id, name, address, size, src_code)
            for (auto* fn : cls->Functions()) {
                if (!fn) continue;
                const std::string asmText = buildFunctionAsm(fn);
                sqlite3_stmt* st = nullptr;
                if (sqlite3_prepare_v2(g_db.db,
                    "INSERT INTO methods (class_id, name, address, size, src_code) VALUES (?,?,?,?,?)",
                    -1, &st, nullptr) == SQLITE_OK) {
                    sqlite3_bind_int64(st, 1, (int64_t)cls->Id());
                    sqlite3_bind_text(st, 2, fn->Name().c_str(), -1, SQLITE_TRANSIENT);
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

// 导出 pp_entries + strings（复用 DartDumper 的对象池描述）
static void exportObjectPool(DartApp& app, DartDumper& dumper) {
    const auto& pool = app.GetObjectPool();
    intptr_t num = pool.Length();
    int pp = 0, strings = 0;
    g_db.exec("BEGIN TRANSACTION");

    for (intptr_t i = 0; i < num; i++) {
        intptr_t offset = dart::ObjectPool::OffsetFromIndex(i) + 1;
        std::string desc = dumper.FlPoolDescription(offset, true);
        if (desc.empty()) continue;

        // 拆 type / value（"Type: value" 形式）
        std::string type, value;
        auto pos = desc.find(": ");
        if (pos != std::string::npos && pos > 0) {
            type = desc.substr(0, pos);
            value = desc.substr(pos + 2);
        } else {
            type = "";
            value = desc;
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
        if (type == "String") {
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

// ─── Temp dir helpers ──────────────────────────
static bool createTempDir(char* buf, size_t sz) {
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
// Returns 0 on success

extern "C" __attribute__((visibility("default")))
int blutter_analyze(const char* so_path, const char* db_path) {
    fprintf(stderr, "fler-dart: analyze(so=%s, db=%s)\n", so_path, db_path);

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
            exportClassesAndMethods(app);
            exportObjectPool(app, dumper);
        }
        app.ExitScope();

        g_db.close();
    } catch (std::exception& e) {
        fprintf(stderr, "fler-dart: analysis failed: %s\n", e.what());
        removeDir(tmpdir); return -2;
    }

    removeDir(tmpdir);
    fprintf(stderr, "fler-dart: done, db = %s\n", db_path);
    return 0;
}
