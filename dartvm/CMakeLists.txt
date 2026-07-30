cmake_minimum_required(VERSION 3.20)
project(dartvm C CXX)

# ─── Input variables (set by build-dartvm.sh) ───
# BLUTTER_SRC_DIR     - path to blutter/src/ (contains all .cpp/.h)
# DARTVM_PACKAGES     - path to blutter's packages/ dir
# DARTVM_LIB_NAME     - e.g. "dartvm3.12.2_android_arm64"
# CAPSTONE_STATIC_LIB  - path to prebuilt libcapstone.a
# CAPSTONE_INCLUDE_DIR - path to capstone headers
# DART_VERSION        - e.g. "3.12.2"
# SQLITE_DIR          - path to SQLite amalgamation
#
# Version-specific defines (from Blutter's pch.h):
# OLD_MAP_SET_NAME, NO_LAST_INTERNAL_ONLY_CID, HAS_SHARED_CLASS_TABLE,
# HAS_RECORD_TYPE, NO_INIT_LATE_STATIC_FIELD,
# NO_METHOD_EXTRACTOR_STUB, UNIFORM_INTEGER_ACCESS, NO_CODE_ANALYSIS

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ─── Detect Dart VM lib (before add_library) ───
if(NOT DARTVM_PACKAGES)
    set(DARTVM_PACKAGES "${BLUTTER_SRC_DIR}/../packages")
endif()
if(NOT DARTVM_LIB_NAME)
    message(FATAL_ERROR "DARTVM_LIB_NAME required")
endif()

# DARTVM_STATIC_LIB is set by build-dartvm.sh to the .a path.
# It may come from packages/ (dartvm_fetch_build.py) or from GN build.
if(DARTVM_STATIC_LIB)
    get_filename_component(_dartvm_lib_ext "${DARTVM_STATIC_LIB}" LAST_EXT)
    if("${_dartvm_lib_ext}" MATCHES "^\\.(a|so)$")
        message(STATUS "Dart VM lib (direct): ${DARTVM_STATIC_LIB}")
        set(_DARTVM_USE_DIRECT ON)
        set(_DARTVM_LIB_TO_LINK "${DARTVM_STATIC_LIB}")
    endif()
endif()

if(NOT _DARTVM_USE_DIRECT)
    find_package(${DARTVM_LIB_NAME} REQUIRED PATHS "${DARTVM_PACKAGES}")
    message(STATUS "Found Dart VM (package): ${DARTVM_LIB_NAME}")
    set(_DARTVM_LIB_TO_LINK ${DARTVM_LIB_NAME})
endif()

# ─── Find Capstone ───
if(NOT CAPSTONE_STATIC_LIB)
    message(FATAL_ERROR "CAPSTONE_STATIC_LIB required")
endif()
if(NOT CAPSTONE_INCLUDE_DIR)
    set(CAPSTONE_INCLUDE_DIR "${BLUTTER_SRC_DIR}/../third_party/capstone/include")
endif()

# ─── Blutter sources (all except main.cpp) ───
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
message(STATUS "SQLite: ${SQLITE_SRC}")

# ─── Our files ───
set(DARTVM_SO_SRCS
    ${CMAKE_CURRENT_SOURCE_DIR}/src/blutter_entry.cpp
    ${SQLITE_SRC}
)

# ─── Shared library ───
add_library(dartvm SHARED
    ${BLUTTER_SRCS}
    ${DARTVM_SO_SRCS}
)

# ─── Include paths ───
target_include_directories(dartvm PRIVATE
    ${BLUTTER_SRC_DIR}
)

if(_DARTVM_USE_DIRECT)
    if(DARTVM_INCLUDE_DIR)
        target_include_directories(dartvm PRIVATE ${DARTVM_INCLUDE_DIR})
    elseif(EXISTS "${DARTVM_PACKAGES}/include/${DARTVM_LIB_NAME}")
        target_include_directories(dartvm PRIVATE "${DARTVM_PACKAGES}/include/${DARTVM_LIB_NAME}")
    else()
        target_include_directories(dartvm PRIVATE "${DARTVM_PACKAGES}/include")
    endif()
else()
    get_target_property(_dartvm_inc ${DARTVM_LIB_NAME} INTERFACE_INCLUDE_DIRECTORIES)
    if(NOT _dartvm_inc)
        target_include_directories(dartvm PRIVATE
            "${DARTVM_PACKAGES}/include/${DARTVM_LIB_NAME}"
        )
    endif()
endif()

target_include_directories(dartvm PRIVATE
    ${CAPSTONE_INCLUDE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${SQLITE_DIR}
)

# ─── Link libraries ───
target_link_libraries(dartvm PRIVATE
    ${_DARTVM_LIB_TO_LINK}
    ${CAPSTONE_STATIC_LIB}
)

if(ANDROID)
    target_link_libraries(dartvm PRIVATE atomic log z dl pthread)
else()
    target_link_libraries(dartvm PRIVATE z dl pthread)
endif()

# ─── Compile definitions ───
target_compile_definitions(dartvm PRIVATE
    DART_VERSION="${DART_VERSION}"
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

# ─── Compile options ───
target_compile_options(dartvm PRIVATE
    -O3 -fno-rtti
    -fvisibility=hidden -fvisibility-inlines-hidden
    -fno-omit-frame-pointer
)

# Force-include atomic_ref compatibility layer (NDK r27's libc++
# may not expose std::atomic_ref; this provides a builtin-based fallback)
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    target_compile_options(dartvm PRIVATE
        -include "${CMAKE_CURRENT_SOURCE_DIR}/src/atomic_ref_compat.h"
    )
endif()

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
