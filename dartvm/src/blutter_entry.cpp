// ─── fler-dart: Blutter wrapper entry point ───
// Compiled as libdartvm.so. Exports blutter_analyze() callable from
// Fler's libfler.so via dlopen/dlsym.
//
// Pipeline:
//   1. Create temp output directory
//   2. Run Blutter analysis pipeline → pp.txt, objs.txt, asm/
//   3. Parse output files into SQLite database
//   4. Cleanup temp dir
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

// ─── pp.txt parser ──────────────────────────────
struct PpEntry {
    uint64_t pp_offset;
    std::string type;
    std::string value;
};

static const char* trim(const char* s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

static bool parsePpLine(const std::string& line, PpEntry& entry) {
    const char* p = line.c_str();
    int n = 0;
    if (sscanf(p, "%" SCNx64 ":%n", &entry.pp_offset, &n) < 1) return false;
    p += n; p = trim(p);
    entry.value = p;

    if (entry.value.size() >= 2 && entry.value[0] == '\'' && entry.value.back() == '\'') {
        entry.type = "String";
    } else if (entry.value.find(" of ") != std::string::npos) {
        auto pos = entry.value.find(" of ");
        entry.type = entry.value.substr(pos + 4);
    } else {
        entry.type = entry.value;
    }
    return true;
}

static void parsePpTxt(const char* path) {
    std::ifstream file(path);
    if (!file.is_open()) { fprintf(stderr, "Cannot open pp.txt\n"); return; }

    const int BATCH = 500;
    int count = 0;
    std::string line;
    g_db.exec("BEGIN TRANSACTION");

    while (std::getline(file, line)) {
        if (line.empty()) continue;
        PpEntry e;
        if (!parsePpLine(line, e)) continue;

        sqlite3_stmt* stmt;
        sqlite3_prepare_v2(g_db.db,
            "INSERT OR IGNORE INTO pp_entries (pp_offset, type, value) VALUES (?, ?, ?)",
            -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, (int64_t)e.pp_offset);
        sqlite3_bind_text(stmt, 2, e.type.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, e.value.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt); sqlite3_finalize(stmt);

        if (e.type == "String" ||
            e.value.find("_StringBase") != std::string::npos ||
            e.value.find("_OneByteString") != std::string::npos) {
            sqlite3_prepare_v2(g_db.db,
                "INSERT OR IGNORE INTO strings (pp_offset, value) VALUES (?, ?)",
                -1, &stmt, nullptr);
            sqlite3_bind_int64(stmt, 1, (int64_t)e.pp_offset);
            sqlite3_bind_text(stmt, 2, e.value.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt); sqlite3_finalize(stmt);
        }

        if (++count % BATCH == 0) { g_db.exec("COMMIT"); g_db.exec("BEGIN TRANSACTION"); }
    }
    g_db.exec("COMMIT");
    fprintf(stderr, "Parsed %d pp entries\n", count);
}

// ─── objs.txt parser ────────────────────────────
static void parseObjsTxt(const char* path) {
    std::ifstream file(path);
    if (!file.is_open()) { fprintf(stderr, "Cannot open objs.txt\n"); return; }

    const int BATCH = 200;
    int count = 0;
    std::string line;
    uint64_t cur_pp = 0;
    std::string cur_cls;

    g_db.exec("BEGIN TRANSACTION");

    auto flush = [&]() {
        if (cur_pp == 0) return;
        sqlite3_stmt* stmt;
        sqlite3_prepare_v2(g_db.db,
            "UPDATE pp_entries SET type = ? WHERE pp_offset = ?", -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, cur_cls.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 2, (int64_t)cur_pp);
        sqlite3_step(stmt); sqlite3_finalize(stmt);
    };

    while (std::getline(file, line)) {
        if (line.find(" (") != std::string::npos && line.find("): ") != std::string::npos) {
            flush();
            uint64_t s = 0, e = 0;
            char cn[256] = {};
            if (sscanf(line.c_str(), "%" SCNx64 " - %" SCNx64 " (%*[^)]) %255s", &s, &e, cn) >= 2) {
                cur_pp = s; cur_cls = cn;
                if (!cur_cls.empty() && cur_cls.back() == ':') cur_cls.pop_back();

                sqlite3_stmt* stmt;
                sqlite3_prepare_v2(g_db.db,
                    "INSERT OR IGNORE INTO classes (id, name) VALUES (?, ?)", -1, &stmt, nullptr);
                sqlite3_bind_int64(stmt, 1, (int64_t)s);
                sqlite3_bind_text(stmt, 2, cur_cls.c_str(), -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt); sqlite3_finalize(stmt);
            }
            continue;
        }

        if (!line.empty() && line[0] == ' ') {
            const char* p = trim(line.c_str());
            if (strncmp(p, "value: ", 7) == 0) {
                const char* v = trim(p + 7);
                std::string sv;
                if (v[0] == '\'') { v++; const char* end = strchr(v, '\''); sv = end ? std::string(v, end - v) : v; }
                else sv = v;
                if (!sv.empty()) {
                    sqlite3_stmt* stmt;
                    sqlite3_prepare_v2(g_db.db,
                        "UPDATE strings SET value = ? WHERE pp_offset = ?", -1, &stmt, nullptr);
                    sqlite3_bind_text(stmt, 1, sv.c_str(), -1, SQLITE_TRANSIENT);
                    sqlite3_bind_int64(stmt, 2, (int64_t)cur_pp);
                    sqlite3_step(stmt); sqlite3_finalize(stmt);
                }
            }
        }

        if (line.find("=>") != std::string::npos) {
            uint64_t pp = 0;
            if (sscanf(line.c_str(), "%" SCNx64, &pp) >= 1) cur_pp = pp;
        }

        if (++count % BATCH == 0) { g_db.exec("COMMIT"); g_db.exec("BEGIN TRANSACTION"); }
    }
    flush();
    g_db.exec("COMMIT");
    fprintf(stderr, "Parsed %d obj entries\n", count);
}

// ─── asm/*.txt parser ───────────────────────────
struct MethodInfo {
    std::string class_name, method_name;
    uint64_t address = 0, size = 0;
    std::string src_code;
};

static void parseAsmFile(const std::string& path, std::vector<MethodInfo>& out) {
    std::ifstream file(path);
    if (!file.is_open()) return;

    MethodInfo cur;
    std::string line;

    auto flush = [&]() {
        if (cur.address == 0) return;
        if (!cur.src_code.empty() && cur.src_code.back() == '\n') cur.src_code.pop_back();
        out.push_back(cur);
        cur = MethodInfo{};
    };

    while (std::getline(file, line)) {
        if (line.empty()) continue;
        if (line[0] == ';') {
            if (line.find("; Function: ") == 0) {
                flush();
                std::string fn = line.substr(12);
                auto p = fn.find_last_of('.');
                if (p != std::string::npos) { cur.class_name = fn.substr(0, p); cur.method_name = fn.substr(p + 1); }
                else cur.method_name = fn;
            } else if (line.find("; Address: 0x") == 0) sscanf(line.c_str(), "; Address: 0x%" SCNx64, &cur.address);
            else if (line.find("; Size: 0x") == 0) sscanf(line.c_str(), "; Size: 0x%" SCNx64, &cur.size);
            continue;
        }
        cur.src_code += line + "\n";
    }
    flush();
}

static void collectAsmFiles(const char* dir, std::vector<std::string>& out) {
    DIR* d = opendir(dir); if (!d) return;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        std::string n(e->d_name);
        if (n == "." || n == "..") continue;
        std::string f = std::string(dir) + "/" + n;
        if (e->d_type == DT_DIR) collectAsmFiles(f.c_str(), out);
        else if (n.size() > 4 && n.substr(n.size() - 4) == ".txt") out.push_back(f);
    }
    closedir(d);
}

static void parseAsmDir(const char* dir_path) {
    std::vector<std::string> files;
    collectAsmFiles(dir_path, files);
    std::vector<MethodInfo> methods;
    for (auto& f : files) parseAsmFile(f, methods);
    if (methods.empty()) return;

    const int BATCH = 50;
    int count = 0;
    g_db.exec("BEGIN TRANSACTION");

    for (auto& m : methods) {
        int64_t cid = 0;
        sqlite3_stmt* stmt;
        sqlite3_prepare_v2(g_db.db, "SELECT id FROM classes WHERE name = ? LIMIT 1", -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, m.class_name.c_str(), -1, SQLITE_STATIC);
        if (sqlite3_step(stmt) == SQLITE_ROW) cid = sqlite3_column_int64(stmt, 0);
        sqlite3_finalize(stmt);

        sqlite3_prepare_v2(g_db.db,
            "INSERT OR REPLACE INTO methods (name, address, size, src_code, class_id) VALUES (?, ?, ?, ?, ?)",
            -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, m.method_name.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int64(stmt, 2, (int64_t)m.address);
        sqlite3_bind_int64(stmt, 3, (int64_t)m.size);
        sqlite3_bind_text(stmt, 4, m.src_code.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 5, cid);
        sqlite3_step(stmt); sqlite3_finalize(stmt);

        if (++count % BATCH == 0) { g_db.exec("COMMIT"); g_db.exec("BEGIN TRANSACTION"); }
    }
    g_db.exec("COMMIT");
    fprintf(stderr, "Parsed %zu methods\n", methods.size());
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
        app.EnterScope();
        DartDumper dumper{ app };
        fs::path out{ tmpdir };
        dumper.DumpObjectPool((out / "pp.txt").string().c_str());
        dumper.DumpObjects((out / "objs.txt").string().c_str());
        dumper.DumpCode((out / "asm").string().c_str());
        app.ExitScope();
    } catch (std::exception& e) {
        fprintf(stderr, "fler-dart: analysis failed: %s\n", e.what());
        removeDir(tmpdir); return -2;
    }

    if (!g_db.open(db_path)) { removeDir(tmpdir); return -3; }
    createTables();

    parsePpTxt((std::string(tmpdir) + "/pp.txt").c_str());
    parseObjsTxt((std::string(tmpdir) + "/objs.txt").c_str());

    std::string asm_dir = std::string(tmpdir) + "/asm";
    struct stat st;
    if (stat(asm_dir.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) parseAsmDir(asm_dir.c_str());
    else fprintf(stderr, "fler-dart: asm/ not found\n");

    g_db.exec("UPDATE strings SET ref_count = (SELECT COUNT(*) FROM string_refs WHERE string_id = strings.id)");
    g_db.close();
    removeDir(tmpdir);

    fprintf(stderr, "fler-dart: done, db = %s\n", db_path);
    return 0;
}
