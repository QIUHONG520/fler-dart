#!/usr/bin/env python3
"""Small, version-tolerant hardening patches for the pinned Blutter tree."""
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
changed = []

def edit(name, transform):
    p = root / name
    if not p.exists():
        print(f"WARN: {p} missing")
        return
    s = p.read_text(encoding="utf-8")
    out = transform(s)
    if out != s:
        p.write_text(out, encoding="utf-8")
        changed.append(name)

def codeanalyzer_h(s):
    old = ": first_addr{ asm_texts.front().addr }, last_addr{ asm_texts.back().addr }, first_stack_limit_addr{ first_stack_limit_addr },"
    new = ": first_addr{ asm_texts.empty() ? 0 : asm_texts.front().addr }, last_addr{ asm_texts.empty() ? 0 : asm_texts.back().addr }, first_stack_limit_addr{ first_stack_limit_addr },"
    return s.replace(old, new, 1)

def arm64(s):
    old = "\t\tmemset(text_asm.text, ' ', 16);\n\t\tmemcpy(text_asm.text, insn->mnemonic, strlen(insn->mnemonic));\n\t\tauto ptr = text_asm.text + 16;"
    new = "\t\tmemset(text_asm.text, ' ', sizeof(text_asm.text));\n\t\tconst size_t mnemonic_len = std::min(strlen(insn->mnemonic), sizeof(text_asm.text) - 1);\n\t\tmemcpy(text_asm.text, insn->mnemonic, mnemonic_len);\n\t\tauto ptr = text_asm.text + 16;\n\t\tauto end_ptr = text_asm.text + sizeof(text_asm.text) - 1;"
    s = s.replace(old, new, 1)
    old = "\t\t\t*ptr++ = *op_ptr++;\n\t\t}\n\t\t*ptr = '\\0';"
    new = "\t\t\tif (ptr < end_ptr) *ptr++ = *op_ptr++;\n\t\t\telse break;\n\t\t}\n\t\t*ptr = '\\0';"
    return s.replace(old, new, 1)

def analyzer_cpp(s):
    # Contain ordinary C++ failures per function. SIGSEGV remains handled by the
    # outer isolated engine process; this prevents one malformed function from
    # aborting the remaining functions when the analyzer throws.
    if "fler-dart: skip function" in s:
        return s
    pat = re.compile(
        r"(?P<i>\t+)// start from PayloadAddress or Address\?\n"
        r"(?P<c>\t+)// the assemblies will be deleted after finish analysis because assembly with details consume too much memory\n"
        r"(?P<a>\t+)auto asm_insns = disasmer\.Disasm\(\(uint8_t\*\)dartFn->MemAddress\(\), dartFn->Size\(\), dartFn->Address\(\)\);\n\n"
        r"(?P<b>\t+)dartFn->SetAnalyzedData\(std::make_unique<AnalyzedFnData>\(app, \*dartFn, convertAsm\(asm_insns\)\)\);\n\n"
        r"(?P<d>\t+)asm2il\(dartFn, asm_insns\);"
    )
    def repl(m):
        i = m.group('i')
        body = m.group(0)
        return (i + "try {\n" + body +
                "\n" + i + "} catch (const std::exception& e) {\n" +
                i + "\tstd::cerr << \"fler-dart: skip function \" << std::hex << dartFn->Address()\n" +
                i + "\t          << std::dec << \" (\" << e.what() << \")\\n\";\n" + i + "}")
    out = pat.sub(repl, s, count=1)
    # Analyze code objects recovered into DartApp::nativeLib as well. These are
    # common in obfuscated snapshots and are not part of app.libs.
    native_marker = "fler-dart: analyze native synthetic functions"
    if native_marker not in out:
        end = out.find("\n}\n\n#endif // NO_CODE_ANALYSIS", out.find("void CodeAnalyzer::AnalyzeAll()"))
        if end != -1:
            native = '''
\t// fler-dart: analyze native synthetic functions
\tfor (auto cls : app.nativeLib.classes) {
\t\tfor (auto dartFn : cls->Functions()) {
\t\t\tif (dartFn->Size() == 0) continue;
\t\t\ttry {
\t\t\t\tauto asm_insns = disasmer.Disasm((uint8_t*)dartFn->MemAddress(), dartFn->Size(), dartFn->Address());
\t\t\t\tif (asm_insns.Count() == 0) continue;
\t\t\t\tdartFn->SetAnalyzedData(std::make_unique<AnalyzedFnData>(app, *dartFn, convertAsm(asm_insns)));
\t\t\t\tasm2il(dartFn, asm_insns);
\t\t\t} catch (const std::exception& e) {
\t\t\t\tstd::cerr << "fler-dart: skip native function " << std::hex << dartFn->Address()
\t\t\t\t          << std::dec << " (" << e.what() << ")\\n";
\t\t\t}
\t\t}
\t}
'''
            out = out[:end] + native + out[end:]
    # Record concrete C++ exceptions for method_analysis.error.
    if "analysis_errors[dartFn->Address()]" not in out:
        out = out.replace(
            'std::cerr << "fler-dart: skip function " << std::hex << dartFn->Address()\n',
            'app.analysis_errors[dartFn->Address()] = e.what();\n'
            '                    std::cerr << "fler-dart: skip function " << std::hex << dartFn->Address()\n',
            1)
        out = out.replace(
            'std::cerr << "fler-dart: skip native function " << std::hex << dartFn->Address()\n',
            'app.analysis_errors[dartFn->Address()] = e.what();\n'
            '                std::cerr << "fler-dart: skip native function " << std::hex << dartFn->Address()\n',
            1)
    return out


def function_size_guard(s):
    # A corrupt Code::Size() can make Capstone read far beyond the mapped
    # executable range. Bound analysis work before the disassembler is called.
    return s.replace(
        "if (dartFn->Size() == 0)",
        "if (dartFn->Size() <= 0 || dartFn->Size() > 0x1000000)")


def dartloader_cpp(s):
    # The Android worker is short-lived. Dart_Cleanup is process-global and
    # crashes with some snapshot revisions after successful export; the worker
    # is killed after writing its result, so let the OS reclaim VM state.
    old = """void DartLoader::Unload()
{
\tif (Dart_CurrentIsolate() != nullptr) {
\t\tDart_ShutdownIsolate();
\t}
\tignore_result(Dart_Cleanup());
}"""
    new = """void DartLoader::Unload()
{
\t// fler-dart: the Android analysis worker is short-lived and is terminated
\t// after the result file is written. Do not shut down or globally clean the
\t// Dart VM from DartApp's destructor: Dart 2.14/3.6 can crash while tearing
\t// down snapshot-owned isolate state after a successful export. Leaking this
\t// process-local VM is intentional; the OS reclaims it on worker exit.
}"""
    return s.replace(old, new, 1)


def arm64_analyzer_tolerance(s):
    # A split CFG can enter an epilogue without the linear scanner having seen
    # EnterFrame. The epilogue itself is enough evidence for this flag.
    s = s.replace("""\t\tINSN_ASSERT(fnInfo->useFramePointer);
\t\tconst auto ins0_addr""", """\t\t// Dart 3.6 may enter through a split basic block.
\t\tfnInfo->useFramePointer = true;
\t\tconst auto ins0_addr""", 1)
    # Do not throw when the stack-limit sequence crosses a basic-block edge.
    s = s.replace("""\t\t// cmp SP, TMP
INSN_ASSERT(insn.id() == ARM64_INS_CMP);
INSN_ASSERT(insn.ops(0).reg == CSREG_DART_SP);
INSN_ASSERT(insn.ops(1).reg == CSREG_DART_TMP);
++insn;

INSN_ASSERT(insn.id() == ARM64_INS_B);
INSN_ASSERT(insn.ops(0).type == ARM64_OP_IMM);
uint64_t target = (uint64_t)insn.ops(0).imm;""", """\t\t// cmp SP, TMP. If it is not adjacent, leave the iterator untouched
\t\t// and let the generic parser handle the valid instructions.
\t\tif (insn.id() != ARM64_INS_CMP ||
\t\t\tinsn.ops(0).reg != CSREG_DART_SP ||
\t\t\tinsn.ops(1).reg != CSREG_DART_TMP) return nullptr;
\t\t++insn;

\t\tif (insn.id() != ARM64_INS_B || insn.ops(0).type != ARM64_OP_IMM)
\t\t\treturn nullptr;
\t\tuint64_t target = (uint64_t)insn.ops(0).imm;""", 1)
    # ADD PP, #imm followed by a branch is not an adjacent pool load.
    s = s.replace("""\t\t\telse {
\t\t\t\tINSN_ASSERT(false);
\t\t\t}
\t\t\tdstReg = A64::Register{ insn.ops(0).reg };""", """\t\t\telse {
\t\t\t\treturn ObjectPoolInstr{};
\t\t\t}
\t\t\tdstReg = A64::Register{ insn.ops(0).reg };""", 1)
    return s


def arm64_analyzer_recovery(s):
    # Do not abort an entire analysis for patterns that are valid but not
    # recognized by the current Dart-version matcher.
    s = s.replace('''\t\t\tINSN_ASSERT(insn.id() == ARM64_INS_B && insn.cc() == ARM64_CC_EQ);''', '''\t\t\tif (insn.id() != ARM64_INS_B || insn.cc() != ARM64_CC_EQ) return nullptr;''', 1)
    s = s.replace('''\t\tif (insn.id() != ARM64_INS_STR && insn.id() != ARM64_INS_LDR) {
\t\t\tFATAL(\"static field without STR or LDR\");
\t\t}''', '''\t\tif (insn.id() != ARM64_INS_STR && insn.id() != ARM64_INS_LDR) {
\t\t\treturn nullptr;
\t\t}''', 1)
    # Field-table metadata can be stale/misaligned in optimized snapshots. It
    # is still a normal static-field load; preserve that IL instead of throwing.
    needle='''\t\t\t\t\tINSN_ASSERT(dartField.Offset() == field_offset);'''
    replacement='''\t\t\t\t\tif (dartField.Offset() != field_offset) {
\t\t\t\t\t\tinsn.SetCurrent(loadStaicInstr_endIns);
\t\t\t\t\t\treturn std::make_unique<LoadStaticFieldInstr>(insn.Wrap(marker.Take()), dstReg, field_offset);
\t\t\t\t\t}'''
    s=s.replace(needle,replacement,1)
    # Same mismatch occurs in the late-initialization error path; reject the
    # specialized pattern and let the generic parser continue.
    s=s.replace('''\t\t\t\t\tINSN_ASSERT(dartField.Offset() == field_offset);''', '''\t\t\t\t\tif (dartField.Offset() != field_offset) return nullptr;''', 1)
    # Prevent malformed matcher lookahead from spinning forever. Every pass
    # must advance the iterator; a hard bound is a final guard for bad CFGs.
    old='''\tAsmIterator insn(asm_insns.FirstPtr(), asm_insns.LastPtr());

\thandlePrologue(insn, fnInfo->asmTexts.FirstStackLimitAddress());

\tdo {
\t\tbool ok = false;'''
    new='''\tAsmIterator insn(asm_insns.FirstPtr(), asm_insns.LastPtr());

\thandlePrologue(insn, fnInfo->asmTexts.FirstStackLimitAddress());

\t// fler-dart: malformed/split CFGs must never make one function loop.
\tsize_t iterations = 0;
\tconst size_t max_iterations = asm_insns.Count() * 8 + 64;
\tdo {
\t\tif (++iterations > max_iterations) {
\t\t\tstd::cerr << \"fler-dart: stop function parser at \" << std::hex
\t\t\t          << fnInfo->dartFn.Address() << std::dec << \" (iteration guard)\\n\";
\t\t\tbreak;
\t\t}
\t\tconst auto before_addr = insn.address();
\t\tbool ok = false;'''
    s=s.replace(old,new,1)
    old2='''\t\tif (!ok) {
\t\t\t// unhandle case
\t\t\tauto ins = insn.Current();
\t\t\tfnInfo->AddIL(std::make_unique<UnknownInstr>(ins, fnInfo->asmTexts.AtAddr(ins->address)));
\t\t\t++insn;
\t\t}
\t} while (!insn.IsEnd());'''
    new2='''\t\tif (!ok) {
\t\t\t// unhandle case
\t\t\tauto ins = insn.Current();
\t\t\tfnInfo->AddIL(std::make_unique<UnknownInstr>(ins, fnInfo->asmTexts.AtAddr(ins->address)));
\t\t\t++insn;
\t\t}
\t\t// A matcher returning IL without consuming input is a parser bug;
\t\t// force progress while retaining the already-created IL.
\t\tif (!insn.IsEnd() && insn.address() == before_addr) ++insn;
\t} while (!insn.IsEnd());'''
    s=s.replace(old2,new2,1)
    return s

def dartapp_h(s):
    # Keep a per-analysis visited set and expose concrete per-function errors.
    if "#include <unordered_set>" not in s:
        s = s.replace("#include <unordered_map>", "#include <unordered_map>\n#include <unordered_set>", 1)
    needle = "\tvoid walkObject(dart::Object& obj); // to check field types from existed object"
    if "fler-dart: walked object guard" not in s and needle in s:
        replacement = needle + "\n\n\t// fler-dart: walked object guard\n\tstd::unordered_set<intptr_t> walked_objects;\n\tstd::unordered_map<uint64_t, std::string> analysis_errors;"
        s = s.replace(needle, replacement, 1)
    accessor = "\tconst std::unordered_map<uint64_t, std::string>& fler_analysis_errors() const { return analysis_errors; }"
    if "fler_analysis_errors" not in s and "fler_libs()" in s:
        s = s.replace("\tconst std::vector<DartLibrary*>& fler_libs() const { return libs; }", "\tconst std::vector<DartLibrary*>& fler_libs() const { return libs; }\n" + accessor, 1)
    return s

def dartapp_cpp(s):
    if "fler-dart: safe object walk" not in s:
        old = "void DartApp::walkObject(dart::Object& obj)\n{\n\tauto cid = obj.GetClassId();"
        new = ("void DartApp::walkObject(dart::Object& obj)\n{\n"
               "\t// fler-dart: safe object walk; const graphs may contain cycles or\n"
               "\t// objects whose CID is not represented in the current Dart VM table.\n"
               "\tconst auto object_key = static_cast<intptr_t>(obj.ptr());\n"
               "\tif (!walked_objects.insert(object_key).second) return;\n"
               "\tauto cid = obj.GetClassId();")
        s = s.replace(old, new, 1)
    old = "\tASSERT(obj.IsInstance());\n\n\tauto dartCls = classes[cid];\n\tASSERT(dartCls);"
    new = ("\tif (!obj.IsInstance()) return;\n"
           "\tif (cid < 0 || static_cast<size_t>(cid) >= classes.size()) return;\n\n"
           "\tauto dartCls = classes[cid];\n\tif (!dartCls) return;")
    s = s.replace(old, new, 1)
    old = "void DartApp::loadFromObjectPool()\n{\n\tconst auto& pool = GetObjectPool();"
    new = ("void DartApp::loadFromObjectPool()\n{\n"
           "\twalked_objects.clear();\n"
           "\tconst auto& pool = GetObjectPool();")
    s = s.replace(old, new, 1)
    old = "\t\telse {\n\t\t\tthrow std::runtime_error(\"Unknown Object Pool entry type\");\n\t\t}"
    new = ("\t\telse {\n"
           "\t\t\t// Unknown entries are version-specific; preserve the rest of the\n"
           "\t\t\t// snapshot instead of aborting the complete analysis.\n"
           "\t\t\tstd::cerr << \"fler-dart: skip unknown object pool entry type=\"\n"
           "\t\t\t          << static_cast<int>(objType) << \" index=\" << i << \"\\n\";\n"
           "\t\t\tcontinue;\n\t\t}")
    return s.replace(old, new, 1)


edit("DartLoader.cpp", dartloader_cpp)
edit("CodeAnalyzer_arm64.cpp", arm64_analyzer_tolerance)
edit("CodeAnalyzer_arm64.cpp", arm64_analyzer_recovery)
edit("CodeAnalyzer.h", codeanalyzer_h)
edit("DartApp.h", dartapp_h)
edit("DartApp.cpp", dartapp_cpp)
edit("CodeAnalyzer_arm64.cpp", arm64)
edit("CodeAnalyzer.cpp", analyzer_cpp)
edit("CodeAnalyzer.cpp", function_size_guard)
print("fler-dart robust patches: " + (", ".join(changed) if changed else "already applied or no matching upstream pattern"))
