set(DISKANN_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/diskann")

find_package(Threads REQUIRED)
find_package(OpenMP REQUIRED)
find_package(Boost REQUIRED COMPONENTS program_options)
find_package(BLAS REQUIRED)
find_package(LAPACK REQUIRED)

find_path(CBLAS_INCLUDE_DIR
  NAMES cblas.h
  PATH_SUFFIXES
    openblas
    openblas-pthread
    aarch64-linux-gnu
    x86_64-linux-gnu)
find_path(LAPACKE_INCLUDE_DIR
  NAMES lapacke.h
  PATH_SUFFIXES
    openblas
    openblas-pthread
    aarch64-linux-gnu
    x86_64-linux-gnu)
find_library(LAPACKE_LIBRARY
  NAMES lapacke
  PATH_SUFFIXES openblas openblas-pthread)
find_path(AIO_INCLUDE_DIR NAMES libaio.h)
find_library(AIO_LIBRARY NAMES aio)
find_library(CBLAS_LIBRARY NAMES openblas cblas)

foreach(required_var IN ITEMS
    CBLAS_INCLUDE_DIR LAPACKE_INCLUDE_DIR
    AIO_INCLUDE_DIR AIO_LIBRARY)
  if(NOT ${required_var})
    message(FATAL_ERROR "Required DiskANN dependency was not found: ${required_var}")
  endif()
endforeach()

# Some OpenBLAS packages export LAPACKE from libopenblas instead of installing
# a separate liblapacke. Verify the exact DiskANN symbol before accepting that
# layout so a missing LAPACKE implementation still fails during configuration.
set(COTRA_LAPACKE_LIBRARIES)
if(LAPACKE_LIBRARY)
  list(APPEND COTRA_LAPACKE_LIBRARIES "${LAPACKE_LIBRARY}")
else()
  include(CheckFunctionExists)
  set(_COTRA_SAVED_REQUIRED_LIBRARIES "${CMAKE_REQUIRED_LIBRARIES}")
  set(CMAKE_REQUIRED_LIBRARIES ${LAPACK_LIBRARIES} ${BLAS_LIBRARIES})
  check_function_exists(LAPACKE_sgesdd COTRA_LAPACKE_IN_LAPACK)
  set(CMAKE_REQUIRED_LIBRARIES "${_COTRA_SAVED_REQUIRED_LIBRARIES}")
  unset(_COTRA_SAVED_REQUIRED_LIBRARIES)
  if(NOT COTRA_LAPACKE_IN_LAPACK)
    message(FATAL_ERROR
      "LAPACKE_sgesdd was not found in liblapacke, LAPACK, or BLAS")
  endif()
endif()

file(GLOB DISKANN_SOURCES CONFIGURE_DEPENDS
  "${DISKANN_SOURCE_DIR}/src/*.cpp")

add_library(diskann STATIC ${DISKANN_SOURCES})
target_include_directories(diskann
  PUBLIC
    "${DISKANN_SOURCE_DIR}/include"
    "${CBLAS_INCLUDE_DIR}"
    "${LAPACKE_INCLUDE_DIR}"
    "${AIO_INCLUDE_DIR}")

target_link_libraries(diskann
  PUBLIC
    Threads::Threads
    OpenMP::OpenMP_CXX
    Boost::program_options
    ${COTRA_LAPACKE_LIBRARIES}
    ${LAPACK_LIBRARIES}
    ${BLAS_LIBRARIES}
    ${AIO_LIBRARY})

if(CBLAS_LIBRARY)
  target_link_libraries(diskann PUBLIC ${CBLAS_LIBRARY})
endif()

target_compile_definitions(diskann PRIVATE _FILE_OFFSET_BITS=64)
target_compile_options(diskann PRIVATE
  $<$<CONFIG:Release>:-O3>
  $<$<CONFIG:Debug>:-g>)

if(COTRA_NATIVE_ARCH AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(diskann PRIVATE -march=native)
endif()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|i.86)$")
  include(CheckCXXCompilerFlag)
  check_cxx_compiler_flag("-mavx2" COTRA_HAS_MAVX2)
  check_cxx_compiler_flag("-mfma" COTRA_HAS_MFMA)
  if(COTRA_HAS_MAVX2)
    target_compile_options(diskann PRIVATE -mavx2)
    target_compile_definitions(diskann PRIVATE USE_AVX2)
  endif()
  if(COTRA_HAS_MFMA)
    target_compile_options(diskann PRIVATE -mfma)
  endif()
endif()

set(DISKANN_ASYNC_LIB "${AIO_LIBRARY}" PARENT_SCOPE)
