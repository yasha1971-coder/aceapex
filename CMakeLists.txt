# CMake build (2.6.4, VCPKG_CHECK): the library from src/aceapex_api.cpp (target aceapex::aceapex, header aceapex.h) and
# the CLI from the same file with -DACEAPEX_CLI, as the Makefile. No optimisation flags are forced: the build type (or
# the toolchain, vcpkg) decides; an unset build type means Release. zstd: its CMake package when one is installed
# (vcpkg, zstd's own install), else pkg-config. The Makefile stays the reference build of the release packages.
cmake_minimum_required(VERSION 3.14)
file(STRINGS src/aceapex.h _ax_ver REGEX "^#define ACEAPEX_VERSION_STRING ")
string(REGEX REPLACE ".*\"([0-9.]+)\".*" "\\1" ACEAPEX_VERSION "${_ax_ver}")
project(aceapex VERSION ${ACEAPEX_VERSION} LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
option(ACEAPEX_BUILD_CLI "Build the aceapex command-line tool" ON)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
find_package(Threads REQUIRED)

set(ACEAPEX_ZSTD_CONFIG OFF)
find_package(zstd CONFIG QUIET)
if(TARGET zstd::libzstd)
  set(ACEAPEX_ZSTD zstd::libzstd)
elseif(TARGET zstd::libzstd_shared)
  set(ACEAPEX_ZSTD zstd::libzstd_shared)
elseif(TARGET zstd::libzstd_static)
  set(ACEAPEX_ZSTD zstd::libzstd_static)
endif()
if(ACEAPEX_ZSTD)
  set(ACEAPEX_ZSTD_CONFIG ON)
else()
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(ZSTD REQUIRED libzstd)
endif()

function(aceapex_link_zstd tgt)
  if(ACEAPEX_ZSTD_CONFIG)
    target_link_libraries(${tgt} PRIVATE ${ACEAPEX_ZSTD})
  else()
    target_include_directories(${tgt} PRIVATE ${ZSTD_INCLUDE_DIRS})
    target_link_directories(${tgt} PUBLIC ${ZSTD_LIBRARY_DIRS})
    target_link_libraries(${tgt} PRIVATE ${ZSTD_LIBRARIES})
  endif()
endfunction()

add_library(aceapex src/aceapex_api.cpp)
add_library(aceapex::aceapex ALIAS aceapex)
target_compile_features(aceapex PUBLIC cxx_std_17)
target_include_directories(aceapex PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src> $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
target_link_libraries(aceapex PUBLIC Threads::Threads)
aceapex_link_zstd(aceapex)

if(ACEAPEX_BUILD_CLI)
  add_executable(aceapex_cli src/aceapex_api.cpp)
  set_target_properties(aceapex_cli PROPERTIES OUTPUT_NAME aceapex)
  target_compile_definitions(aceapex_cli PRIVATE ACEAPEX_CLI)
  target_compile_features(aceapex_cli PRIVATE cxx_std_17)
  target_include_directories(aceapex_cli PRIVATE src)
  target_link_libraries(aceapex_cli PRIVATE Threads::Threads)
  aceapex_link_zstd(aceapex_cli)
  install(TARGETS aceapex_cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

install(TARGETS aceapex EXPORT aceapex-targets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR} LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES src/aceapex.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT aceapex-targets NAMESPACE aceapex:: DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/aceapex)
configure_package_config_file(cmake/aceapex-config.cmake.in ${CMAKE_CURRENT_BINARY_DIR}/aceapex-config.cmake
                              INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/aceapex)
write_basic_package_version_file(${CMAKE_CURRENT_BINARY_DIR}/aceapex-config-version.cmake COMPATIBILITY SameMinorVersion)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/aceapex-config.cmake ${CMAKE_CURRENT_BINARY_DIR}/aceapex-config-version.cmake
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/aceapex)
