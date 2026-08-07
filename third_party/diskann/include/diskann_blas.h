#pragma once

#include <omp.h>

#if defined(COTRA_USE_MKL)
#include <mkl.h>

inline void diskann_set_blas_threads(int thread_count) {
  mkl_set_num_threads(thread_count);
}
#else
#include <cblas.h>
#include <lapacke.h>

using MKL_INT = lapack_int;

// Generic BLAS implementations do not expose one common thread-control API.
// OpenMP is always enabled for this project, and vendor-specific thread counts
// can additionally be controlled with OPENBLAS_NUM_THREADS or ARMPL_NUM_THREADS.
inline void diskann_set_blas_threads(int thread_count) {
  omp_set_num_threads(thread_count);
}
#endif
