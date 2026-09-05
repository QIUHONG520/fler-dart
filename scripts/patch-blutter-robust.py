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
    return out


def dartapp_h(s):
    # Keep a per-analysis visited set so recursive const/object graphs cannot
    # loop forever. The set is cleared by loadFromObjectPool().
    if "fler-dart: walked object guard" in s:
        return s
    needle = "\tvoid walkObject(dart::Object& obj); // to check field types from existed object"
    s = s.replace("#include <unordered_map>", "#include <unordered_map>\n#include <unordered_set>", 1)
    replacement = needle + "\n\n\t// fler-dart: walked object guard\n\tstd::unordered_set<intptr_t> walked_objects;"
    if needle not in s:
        return s
    return s.replace(needle, replacement, 1)

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


edit("CodeAnalyzer.h", codeanalyzer_h)
edit("DartApp.h", dartapp_h)
edit("DartApp.cpp", dartapp_cpp)
edit("CodeAnalyzer_arm64.cpp", arm64)
edit("CodeAnalyzer.cpp", analyzer_cpp)
print("fler-dart robust patches: " + (", ".join(changed) if changed else "already applied or no matching upstream pattern"))
