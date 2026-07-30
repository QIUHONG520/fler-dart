// ─── fler-dart: Stubs for Dart VM symbols missing when regexp/ is excluded ───
//
// The Dart VM static lib (libdartvm*.a) is built with the regexp/ directory
// excluded (NDK lacks ICU headers required by regexp.cc). However, other
// compiled-in objects still reference symbols from regexp.cc, causing link
// errors when building dartvm.so.
//
// This file provides no-op stubs for those symbols. They are never called
// during Blutter's static analysis pass, so empty/zero definitions are safe.
//
// PCH is disabled for this file (see CMakeLists.txt) to avoid ODR conflicts
// with Dart SDK headers.
//
// Weak symbols: stubs use __attribute__((weak)) so that when the real
// definitions exist (Dart 3.12+ moved these symbols out of regexp/), the
// linker picks the real ones instead of our stubs.

// ─── Forward declarations matching Dart SDK ───
namespace dart {
class Thread;
class Zone;
class NativeArguments;
class String;
}

// Minimal RuntimeEntry matching Dart SDK's vm/runtime_entry.h layout.
// Uses function pointer for storage (C++ forbids plain function-type members).
namespace dart {
template <typename Signature>
class RuntimeEntry {
 public:
  constexpr RuntimeEntry(const char* name, Signature* function)
      : name_(name), function_(function) {}
 private:
  const char* name_;
  Signature* function_;
};
}

// ─── DN_RegExp_* function stubs ───
namespace dart {
namespace BootstrapNatives {

void DN_RegExp_factory(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_getPattern(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_getIsMultiLine(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_getIsCaseSensitive(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_getIsUnicode(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_getIsDotAll(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_getGroupCount(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_getGroupNameMap(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_ExecuteMatch(Thread*, Zone*, NativeArguments*) {}
void DN_RegExp_ExecuteMatchSticky(Thread*, Zone*, NativeArguments*) {}

} // namespace BootstrapNatives
} // namespace dart

// ─── RuntimeEntry data stubs (used by thread.cc InitVMConstants) ───
// These are defined in regexp.cc for Dart <=3.11, but moved to object.cc
// or symbols.cc in Dart 3.12+. Using weak symbols ensures compatibility:
//   - 3.12+: real definitions exist → weak stubs are ignored
//   - 3.10/3.11: real definitions missing → weak stubs satisfy linker
namespace dart {

#define FLER_DART_WEAK __attribute__((weak))

FLER_DART_WEAK extern const RuntimeEntry<bool(const String&, const String&)>
    kCaseInsensitiveCompareUCS2RuntimeEntry(
        "CaseInsensitiveCompareUCS2", nullptr);

FLER_DART_WEAK extern const RuntimeEntry<bool(const String&, const String&)>
    kCaseInsensitiveCompareUTF16RuntimeEntry(
        "CaseInsensitiveCompareUTF16", nullptr);

} // namespace dart
