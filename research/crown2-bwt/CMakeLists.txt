cmake_minimum_required(VERSION 3.22)
project(crown2_bwt_phase LANGUAGES C CXX)

if(NOT UNIX OR APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
    message(FATAL_ERROR "The registered CROWN-2 phase build targets Linux x86-64")
endif()
if(NOT CMAKE_C_COMPILER_ID MATCHES "GNU|Clang" OR
   NOT CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    message(FATAL_ERROR "The registered build requires matching GNU/Clang C and C++ compilers")
endif()

set(CMAKE_BUILD_TYPE Release CACHE STRING "Registered build type" FORCE)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Identical optimization/ISA policy for both phase implementations and both
# dependency builds; no native-host tuning and no link-time optimization.
add_compile_options(-O3 -march=x86-64-v3)
add_compile_definitions(NDEBUG)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF)

include(FetchContent)
set(BSC_ENABLE_NATIVE_COMPILATION OFF CACHE BOOL "Portable registered ISA" FORCE)
set(BSC_ENABLE_OPENMP OFF CACHE BOOL "One timed CPU" FORCE)
set(BSC_ENABLE_CUDA OFF CACHE BOOL "CPU baseline only" FORCE)
set(BSC_BUILD_SHARED_LIB OFF CACHE BOOL "Hide the unmodified archive inside our DSO" FORCE)
set(LIBSAIS_USE_OPENMP OFF CACHE BOOL "Single-thread forward construction" FORCE)
set(LIBSAIS_BUILD_SHARED_LIB OFF CACHE BOOL "Own forward dependency is static" FORCE)

FetchContent_Declare(crown2_libbsc
    GIT_REPOSITORY https://github.com/IlyaGrebnov/libbsc.git
    GIT_TAG 6542faafd0c235975e77e219c77f8227f770fe91
    GIT_SHALLOW FALSE
    GIT_PROGRESS FALSE)
FetchContent_Declare(crown2_libsais
    GIT_REPOSITORY https://github.com/IlyaGrebnov/libsais.git
    GIT_TAG b1aa1fde090e00a4e2030b9fb54198698b84e463
    GIT_SHALLOW FALSE
    GIT_PROGRESS FALSE)
# The pinned upstream libbsc CMake entry point requires CMake 3.24. Ubuntu
# 22.04/ace-core has 3.22, so enumerate its same unchanged CPU source list here
# instead of patching upstream or silently changing the build environment.
FetchContent_GetProperties(crown2_libbsc)
if(NOT crown2_libbsc_POPULATED)
    FetchContent_Populate(crown2_libbsc)
endif()
FetchContent_MakeAvailable(crown2_libsais)
set(crown2_libbsc_sources
    libbsc/adler32/adler32.cpp
    libbsc/bwt/bwt.cpp
    libbsc/bwt/libsais/libsais.c
    libbsc/coder/coder.cpp
    libbsc/coder/qlfc/qlfc.cpp
    libbsc/coder/qlfc/qlfc_model.cpp
    libbsc/filters/detectors.cpp
    libbsc/filters/preprocessing.cpp
    libbsc/libbsc/libbsc.cpp
    libbsc/lzp/lzp.cpp
    libbsc/platform/platform.cpp
    libbsc/st/st.cpp)
list(TRANSFORM crown2_libbsc_sources PREPEND "${crown2_libbsc_SOURCE_DIR}/")
add_library(libbsc STATIC ${crown2_libbsc_sources})
add_library(bsc::libbsc ALIAS libbsc)
set_target_properties(libbsc PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)

# libbsc has its own embedded libsais. It must not bind to our newer standalone
# libsais through ELF symbol interposition. No upstream source is patched.
set_target_properties(libbsc PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)

add_library(crown2_baseline SHARED baseline.cpp)
target_include_directories(crown2_baseline
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}"
    PRIVATE "${crown2_libbsc_SOURCE_DIR}")
target_compile_features(crown2_baseline PUBLIC cxx_std_20)
target_link_libraries(crown2_baseline PRIVATE bsc::libbsc)
set_target_properties(crown2_baseline PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
set(crown2_baseline_exports "${CMAKE_CURRENT_BINARY_DIR}/crown2-baseline.exports")
file(GENERATE OUTPUT "${crown2_baseline_exports}" CONTENT
"CROWN2_BASELINE_1 {\n  global:\n    _ZN6crown215baseline_encode*;\n    _ZN6crown215baseline_decode*;\n    _ZN6crown223baseline_decode_inplace*;\n  local: *;\n};\n")
target_link_options(crown2_baseline PRIVATE
    "LINKER:-Bsymbolic"
    "LINKER:--exclude-libs,ALL"
    "LINKER:--version-script=${crown2_baseline_exports}")
set_property(TARGET crown2_baseline APPEND PROPERTY LINK_DEPENDS "${crown2_baseline_exports}")

add_library(crown2_core STATIC core.cpp)
target_include_directories(crown2_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_features(crown2_core PUBLIC cxx_std_20)
target_link_libraries(crown2_core PUBLIC libsais)

add_executable(crown2_probe cli.cpp)
target_compile_features(crown2_probe PRIVATE cxx_std_20)
target_link_libraries(crown2_probe PRIVATE crown2_core crown2_baseline)
set_target_properties(crown2_probe PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    BUILD_RPATH "$ORIGIN"
    INSTALL_RPATH "$ORIGIN"
    BUILD_WITH_INSTALL_RPATH TRUE)

message(STATUS "CROWN-2 libbsc pin: 6542faafd0c235975e77e219c77f8227f770fe91")
message(STATUS "CROWN-2 standalone libsais pin: b1aa1fde090e00a4e2030b9fb54198698b84e463")
message(STATUS "CROWN-2 flags: Release, -O3 -DNDEBUG -march=x86-64-v3; OpenMP/CUDA/native/LTO OFF")
