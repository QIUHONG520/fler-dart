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
    return pat.sub(repl, s, count=1)

edit("CodeAnalyzer.h", codeanalyzer_h)
edit("CodeAnalyzer_arm64.cpp", arm64)
edit("CodeAnalyzer.cpp", analyzer_cpp)
print("fler-dart robust patches: " + (", ".join(changed) if changed else "already applied or no matching upstream pattern"))
