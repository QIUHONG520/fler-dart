cmake_minimum_required(VERSION 3.20)
project(dartvm C CXX)

# ─── Input variables (set by build-dartvm.sh) ───
# BLUTTER_SRC_DIR     - path to blutter/src/ (contains all .cpp/.h)
# DARTVM_PACKAGES     - path to blutter's packages/ dir (dartvm_fetch_build.py output)
# DARTVM_LIB_NAME     - e.g. "dartvm3.12.2_android_arm64"
# DARTVM_STATIC_LIB   - path to libdart*.a (direct or from packages/)
# DART_INCLUDE_DIR    - optional override for Dart headers
# DART_VERSION        - e.g. "3.12.2"
# CAPSTONE_STATIC_LIB  - path to prebuilt libcapstone.a
# CAPSTONE_INCLUDE_DIR - path to capstone headers
# SQLITE_DIR          - path to SQLite amalgamation

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ─── Validate inputs ───
if(NOT DARTVM_STATIC_LIB)
    message(FATAL_ERROR "DARTVM_STATIC_LIB required")
endif()
if(NOT CAPSTONE_STATIC_LIB)
    message(FATAL_ERROR "CAPSTONE_STATIC_LIB required")
endif()
if(NOT BLUTTER_SRC_DIR)
    message(FATAL_ERROR "BLUTTER_SRC_DIR required")
endif()

# Determine Dart include dir
if(NOT DART_INCLUDE_DIR)
    if(DARTVM_PACKAGES AND DARTVM_LIB_NAME)
        if(EXISTS "${DARTVM_PACKAGES}/include/${DARTVM_LIB_NAME}")
            set(DART_INCLUDE_DIR "${DARTVM_PACKAGES}/include/${DARTVM_LIB_NAME}")
        else()
            file(GLOB _dartvm_inc "${DARTVM_PACKAGES}/include/dartvm*")
            list(GET _dartvm_inc 0 DART_INCLUDE_DIR)
        endif()
    endif()
endif()
if(NOT DART_INCLUDE_DIR)
    message(FATAL_ERROR "DART_INCLUDE_DIR not determined (set DARTVM_PACKAGES or DART_INCLUDE_DIR)")
endif()

message(STATUS "Dart VM lib:     ${DARTVM_STATIC_LIB}")
message(STATUS "Dart include:    ${DART_INCLUDE_DIR}")
message(STATUS "Blutter sources: ${BLUTTER_SRC_DIR}")

# ─── Capstone ───
if(NOT CAPSTONE_INCLUDE_DIR)
    set(CAPSTONE_INCLUDE_DIR "${BLUTTER_SRC_DIR}/../third_party/capstone/include")
endif()

# ─── Blutter sources ───
set(BLUTTER_SRCS
    ${BLUTTER_SRC_DIR}/CodeAnalyzer.cpp
    ${BLUTTER_SRC_DIR}/CodeAnalyzer_arm64.cpp
    ${BLUTTER_SRC_DIR}/DartApp.cpp
    ${BLUTTER_SRC_DIR}/DartClass.cpp
    ${BLUTTER_SRC_DIR}/DartDumper.cpp
    ${BLUTTER_SRC_DIR}/DartField.cpp
    ${BLUTTER_SRC_DIR}/DartFunction.cpp
    ${BLUTTER_SRC_DIR}/DartLibrary.cpp
    ${BLUTTER_SRC_DIR}/DartLoader.cpp
    ${BLUTTER_SRC_DIR}/DartStub.cpp
    ${BLUTTER_SRC_DIR}/DartThreadInfo.cpp
    ${BLUTTER_SRC_DIR}/DartTypes.cpp
    ${BLUTTER_SRC_DIR}/Disassembler.cpp
    ${BLUTTER_SRC_DIR}/Disassembler_arm64.cpp
    ${BLUTTER_SRC_DIR}/ElfHelper.cpp
    ${BLUTTER_SRC_DIR}/FridaWriter.cpp
    ${BLUTTER_SRC_DIR}/Util.cpp
    ${BLUTTER_SRC_DIR}/VarValue.cpp
    ${BLUTTER_SRC_DIR}/il.cpp
)

# ─── SQLite amalgamation ───
if(NOT SQLITE_DIR)
    set(SQLITE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/sqlite")
endif()
set(SQLITE_SRC "${SQLITE_DIR}/sqlite3.c")
if(NOT EXISTS ${SQLITE_SRC})
    message(FATAL_ERROR "SQLite amalgamation not found at ${SQLITE_SRC}")
endif()

# ─── Our wrapper ───
set(DARTVM_SO_SRCS
    ${CMAKE_CURRENT_SOURCE_DIR}/src/blutter_entry.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/regexp_stubs.cpp
    ${SQLITE_SRC}
)

# PCH must be disabled for regexp_stubs.cpp: the stubs forward-declare
# `namespace dart::BootstrapNatives`, which would ODR-conflict with the
# Dart SDK's `class dart::BootstrapNatives` if pulled in via pch.h.
set_source_files_properties(
    ${CMAKE_CURRENT_SOURCE_DIR}/src/regexp_stubs.cpp
    PROPERTIES SKIP_PRECOMPILE_HEADERS ON
)

# ─── Shared library ───
add_library(dartvm SHARED
    ${BLUTTER_SRCS}
    ${DARTVM_SO_SRCS}
)

# ─── Include paths ───
target_include_directories(dartvm PRIVATE
    ${BLUTTER_SRC_DIR}
    ${DART_INCLUDE_DIR}
    ${CAPSTONE_INCLUDE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${SQLITE_DIR}
)

# ─── Force-include atomic_ref compat (NDK r27 libc++ may lack std::atomic_ref) ───
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    target_compile_options(dartvm PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:-include;${CMAKE_CURRENT_SOURCE_DIR}/src/atomic_ref_compat.h>"
    )
endif()

# ─── Compile definitions ───
target_compile_definitions(dartvm PRIVATE
    DART_VERSION="${DART_VERSION}"
    DART_COMPRESSED_POINTERS
    SQLITE_THREADSAFE=0
    SQLITE_OMIT_LOAD_EXTENSION
    NDEBUG
    FRIDA_TEMPLATE_DIR="${BLUTTER_SRC_DIR}/../scripts"
)

# Version-specific defines
if(OLD_MAP_SET_NAME)
    target_compile_definitions(dartvm PRIVATE OLD_MAP_SET_NAME)
endif()
if(OLD_MAP_NO_IMMUTABLE)
    target_compile_definitions(dartvm PRIVATE OLD_MAP_NO_IMMUTABLE)
endif()
if(NO_LAST_INTERNAL_ONLY_CID)
    target_compile_definitions(dartvm PRIVATE NO_LAST_INTERNAL_ONLY_CID)
endif()
if(HAS_SHARED_CLASS_TABLE)
    target_compile_definitions(dartvm PRIVATE HAS_SHARED_CLASS_TABLE)
endif()
if(HAS_RECORD_TYPE)
    target_compile_definitions(dartvm PRIVATE HAS_RECORD_TYPE)
endif()
if(NO_INIT_LATE_STATIC_FIELD)
    target_compile_definitions(dartvm PRIVATE NO_INIT_LATE_STATIC_FIELD)
endif()
if(NO_CODE_ANALYSIS)
    target_compile_definitions(dartvm PRIVATE NO_CODE_ANALYSIS)
endif()
if(NO_METHOD_EXTRACTOR_STUB)
    target_compile_definitions(dartvm PRIVATE NO_METHOD_EXTRACTOR_STUB)
endif()
if(UNIFORM_INTEGER_ACCESS)
    target_compile_definitions(dartvm PRIVATE UNIFORM_INTEGER_ACCESS)
endif()

# ─── Link libraries ───
target_link_libraries(dartvm PRIVATE
    "${DARTVM_STATIC_LIB}"
    "${CAPSTONE_STATIC_LIB}"
    atomic log z
)

# ─── Compile options ───
target_compile_options(dartvm PRIVATE
    -O3 -fno-rtti
    -fvisibility=hidden -fvisibility-inlines-hidden
    -fno-omit-frame-pointer
)

# ─── Precompiled header (CXX only; pch.h contains C++ headers) ───
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    target_precompile_headers(dartvm PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:${BLUTTER_SRC_DIR}/pch.h>"
    )
endif()

# ─── Properties ───
set_target_properties(dartvm PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

# ─── Post-build strip ───
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_custom_command(TARGET dartvm POST_BUILD
        COMMAND ${CMAKE_STRIP} --strip-unneeded "$<TARGET_FILE:dartvm>"
        COMMENT "Stripping debug symbols..."
    )
endif()
