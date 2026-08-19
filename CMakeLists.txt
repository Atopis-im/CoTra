cmake_minimum_required(VERSION 3.16)
project(CoTra LANGUAGES C CXX)

# CMake 3.29 introduced CMP0144: find_package() now uses the
# <PACKAGENAME>_ROOT variables (matching the package-name case, e.g.
# Boost_ROOT) instead of the historical ALL_CAPS BOOST_ROOT. Setting NEW
# here makes our Boost_ROOT hint (passed from the 8-node deployment
# script) actually take effect, so --deps-dir installs on nodes without
# sudo do not accidentally pick up a system Boost headers-only install.
if(POLICY CMP0144)
  cmake_policy(SET CMP0144 NEW)
endif()

if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND
   CMAKE_CXX_COMPILER_VERSION VERSION_LESS 10.3)
  message(FATAL_ERROR
    "CoTra requires GCC 10.3 or newer for C++20 coroutines; found "
    "${CMAKE_CXX_COMPILER_VERSION}")
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# GCC 10 implements C++20 coroutines behind an explicit experimental flag.
# GCC 11 and newer enable the standard coroutine implementation in C++20 mode.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND
   CMAKE_CXX_COMPILER_VERSION VERSION_LESS 11)
  add_compile_options($<$<COMPILE_LANGUAGE:CXX>:-fcoroutines>)
endif()

option(COTRA_NATIVE_ARCH "Optimize for the CPU used to build CoTra" ON)
set(COTRA_MACHINE_NUM 16 CACHE STRING
  "Number of CoTra machines; every node must use the same value")
set(COTRA_MAX_THREAD_NUM 128 CACHE STRING
  "Maximum worker threads represented in exchanged RDMA metadata")

if(NOT COTRA_MACHINE_NUM MATCHES "^[1-9][0-9]*$")
  message(FATAL_ERROR "COTRA_MACHINE_NUM must be a positive integer")
endif()
if(NOT COTRA_MAX_THREAD_NUM MATCHES "^[1-9][0-9]*$")
  message(FATAL_ERROR "COTRA_MAX_THREAD_NUM must be a positive integer")
endif()

add_compile_definitions(
  HAVE_CXX0X
  MACHINE_NUM=${COTRA_MACHINE_NUM}
  MAX_THREAD_NUM=${COTRA_MAX_THREAD_NUM}
  COMM_PROFILE)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  add_compile_definitions(_FILE_OFFSET_BITS=64)
endif()

if(COTRA_NATIVE_ARCH AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  add_compile_options(-march=native)
endif()

add_compile_options(
  $<$<CONFIG:Release>:-O3>
  $<$<CONFIG:Release>:-g>
  $<$<CONFIG:Debug>:-g>)

# Export symbols so backtrace_symbols_fd can resolve addresses in the
# main executable (otherwise only shared-lib frames get symbol names).
add_link_options($<$<CONFIG:Release>:-rdynamic>
                 $<$<CONFIG:Debug>:-rdynamic>)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Modules")

find_package(Threads REQUIRED)
find_package(OpenMP REQUIRED)
find_package(Boost 1.58 REQUIRED COMPONENTS
  serialization iostreams program_options system filesystem regex)
find_package(fmt REQUIRED)

# ---------------------------------------------------------------------------
# Workaround: FindBoost.cmake on CMake 3.29 sometimes fails to register the
# IMPORTED target for a Boost component even when the .so file actually
# exists (e.g. Boost::regex for Boost::iostreams INTERFACE_LINK_LIBRARIES).
# This happens because FindBoost searches for many library name variants
# (with/without -mt suffix, compiler tag, ABI tag, etc.) and when none
# matches exactly, it silently leaves Boost_<COMP>_LIBRARY empty and skips
# target creation -- but we run on nodes with a minimal shared_deps bundle
# where only libboost_<comp>.so.1.66.0 exists and the .so symlink is what
# the linker really needs.
#
# For every expected Boost::* target that FindBoost failed to create, we
# manually declare an UNKNOWN IMPORTED library using:
#   - Boost_INCLUDE_DIRS (already set by FindBoost, since headers were OK)
#   - find_library search on CMAKE_LIBRARY_PATH / CMAKE_PREFIX_PATH
# The list of components below matches our COMPONENTS request plus the
# Boost::iostreams implicit dep "regex" whose missing target produces the
# exact error:
#   The link interface of target "Boost::iostreams" contains: Boost::regex
#   but the target was not found.
# ---------------------------------------------------------------------------
set(_boost_expected_components
    regex serialization iostreams program_options system filesystem)

foreach(_comp IN LISTS _boost_expected_components)
  set(_tgt "Boost::${_comp}")
  if(NOT TARGET "${_tgt}")
    string(TOUPPER "${_comp}" _COMP)
    # Prefer names FindBoost already set, otherwise search generic forms.
    set(_candidates)
    if(Boost_${_COMP}_LIBRARY)
      list(APPEND _candidates "${Boost_${_COMP}_LIBRARY}")
    endif()
    if(Boost_${_COMP}_LIBRARY_RELEASE)
      list(APPEND _candidates "${Boost_${_COMP}_LIBRARY_RELEASE}")
    endif()
    # Fallback: generic names we know our shared_deps install produces.
    list(APPEND _candidates
         "boost_${_comp}"
         "boost_${_comp}-mt"
         "boost_${_comp}-gcc"
         "boost_${_comp}-mt-gcc")

    unset(_found_lib CACHE)
    find_library(_found_lib
      NAMES ${_candidates}
      DOC "Location of libboost_${_comp} library (fallback)"
      NO_DEFAULT_PATH)
    if(NOT _found_lib)
      find_library(_found_lib
        NAMES ${_candidates}
        DOC "Location of libboost_${_comp} library (fallback, default)")
    endif()

    if(_found_lib)
      message(STATUS "Fallback: creating imported target ${_tgt} from ${_found_lib}")
      add_library("${_tgt}" UNKNOWN IMPORTED)
      set_target_properties("${_tgt}" PROPERTIES
        IMPORTED_LOCATION "${_found_lib}"
        INTERFACE_INCLUDE_DIRECTORIES "${Boost_INCLUDE_DIRS}")
      # Make Boost_<COMP>_FOUND look true for any downstream check.
      set("Boost_${_COMP}_FOUND" TRUE CACHE BOOL "Fallback: boost_${_comp} found" FORCE)
      set("Boost_${_COMP}_LIBRARY" "${_found_lib}" CACHE FILEPATH
          "Fallback: boost_${_comp} library path" FORCE)
    else()
      message(FATAL_ERROR
        "Boost component '${_comp}' library file not found. "
        "Expected in deps dir under lib64/libboost_${_comp}.so / "
        "libboost_${_comp}.so.1.66.0 . Please copy Boost .so files "
        "(including regex, serialization, iostreams, program_options, "
        "system, filesystem) from the system into your --deps-dir/lib64 "
        "and make .so -> .so.1.66.0 symlinks, then retry cmake.")
    endif()
  endif()
endforeach()
unset(_boost_expected_components)

find_path(MEMCACHED_INCLUDE_DIR NAMES libmemcached/memcached.h)
find_library(MEMCACHED_LIBRARY NAMES memcached)
find_path(IBVERBS_INCLUDE_DIR NAMES infiniband/verbs.h)
find_library(IBVERBS_LIBRARY NAMES ibverbs)
find_path(RDMACM_INCLUDE_DIR NAMES rdma/rdma_cma.h)
find_library(RDMACM_LIBRARY NAMES rdmacm)

foreach(required_var IN ITEMS
    MEMCACHED_INCLUDE_DIR MEMCACHED_LIBRARY
    IBVERBS_INCLUDE_DIR IBVERBS_LIBRARY
    RDMACM_INCLUDE_DIR RDMACM_LIBRARY)
  if(NOT ${required_var})
    message(FATAL_ERROR "Required dependency was not found: ${required_var}")
  endif()
endforeach()

add_subdirectory(third_party)

add_custom_target(lib)
add_subdirectory(coromem)

file(GLOB RDMA_ANNS_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/rdma/*.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/anns/*.cc")

add_library(rdma_anns STATIC ${RDMA_ANNS_SOURCES})
target_include_directories(rdma_anns
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/diskann/include"
  PRIVATE
    "${MEMCACHED_INCLUDE_DIR}"
    "${IBVERBS_INCLUDE_DIR}"
    "${RDMACM_INCLUDE_DIR}")
target_link_libraries(rdma_anns
  PUBLIC
    coromem
    Threads::Threads
    OpenMP::OpenMP_CXX
    Boost::serialization
    Boost::iostreams
    Boost::program_options
    Boost::system
    Boost::filesystem
    fmt::fmt
    ${MEMCACHED_LIBRARY}
    ${IBVERBS_LIBRARY}
    ${RDMACM_LIBRARY}
    ${CMAKE_DL_LIBS}
    m)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_libraries(rdma_anns PUBLIC rt)
endif()

file(GLOB RDMA_INDEX_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/src/index/*.cc")

add_library(rdma_index STATIC ${RDMA_INDEX_SOURCES})
target_include_directories(rdma_index
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/diskann/include")
target_link_libraries(rdma_index
  PUBLIC
    rdma_anns
    diskann
    coromem
    OpenMP::OpenMP_CXX
    Boost::program_options
    Boost::system
    Boost::filesystem)

add_subdirectory(tests)

message(STATUS "")
message(STATUS "CoTra configuration")
message(STATUS "  Architecture:       ${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "  Compiler:           ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "  Machine count:      ${COTRA_MACHINE_NUM}")
message(STATUS "  Max worker threads: ${COTRA_MAX_THREAD_NUM}")
message(STATUS "  Native tuning:      ${COTRA_NATIVE_ARCH}")
message(STATUS "  BLAS libraries:     ${BLAS_LIBRARIES}")
message(STATUS "")
