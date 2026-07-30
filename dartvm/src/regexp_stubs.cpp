// ─── fler-dart: Stubs for dart::BootstrapNatives::DN_RegExp_* ───
//
// The Dart VM static lib (libdartvm*.a) is built with the regexp/ directory
// excluded (NDK lacks ICU headers required by regexp.cc). However,
// bootstrap_natives.cc (compiled into the .a) still references these
// DN_RegExp_* symbols, causing link errors when building dartvm.so.
//
// Provide empty no-op stubs to satisfy the linker. These functions are
// never called during Blutter's static analysis pass, so empty bodies are safe.
//
// PCH is disabled for this file (see CMakeLists.txt) to avoid ODR conflicts
// with Dart SDK headers that may declare `class BootstrapNatives`.

namespace dart {
class Thread;
class Zone;
class NativeArguments;
}

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
