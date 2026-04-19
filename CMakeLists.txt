cmake_minimum_required(VERSION 3.14)
project(aceapex CXX C)
set(CMAKE_CXX_STANDARD 17)
add_compile_options(-O3 -march=native -funroll-loops)


set(ZSTD_DIR ${CMAKE_SOURCE_DIR}/zstd_src)

add_executable(aceapex
    src/aceapex_main.cpp
    src/zstd_xxhash.c
    ${ZSTD_DIR}/lib/compress/fse_compress.c
    ${ZSTD_DIR}/lib/common/fse_decompress.c
    ${ZSTD_DIR}/lib/common/entropy_common.c
    ${ZSTD_DIR}/lib/common/error_private.c
    ${ZSTD_DIR}/lib/common/zstd_common.c
)

target_include_directories(aceapex PRIVATE
    ${ZSTD_DIR}/lib
)

find_package(Threads REQUIRED)
target_link_libraries(aceapex PRIVATE Threads::Threads -lzstd -lxxhash)

set_source_files_properties(src/aceapex_main.cpp PROPERTIES
    COMPILE_FLAGS "-O3 -march=native -funroll-loops -ffast-math"
)
set_source_files_properties(
    ${ZSTD_DIR}/lib/compress/fse_compress.c
    ${ZSTD_DIR}/lib/common/fse_decompress.c
    ${ZSTD_DIR}/lib/common/entropy_common.c
    ${ZSTD_DIR}/lib/common/error_private.c
    ${ZSTD_DIR}/lib/common/zstd_common.c
    src/zstd_xxhash.c
    PROPERTIES COMPILE_FLAGS "-DXXH_NAMESPACE=ZSTD_ -I${CMAKE_SOURCE_DIR}/zstd_src/lib/common"
)
