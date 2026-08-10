#pragma once

// Keep the existing x86 prefetch call sites source-compatible while providing
// an implementation for AArch64 and other GCC/Clang targets.
#if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || \
    defined(_M_X64)
#include <xmmintrin.h>
#elif defined(__GNUC__) || defined(__clang__)
#ifndef _MM_HINT_T0
#define _MM_HINT_T0 3
#endif
#ifndef _MM_HINT_T1
#define _MM_HINT_T1 2
#endif
#ifndef _mm_prefetch
#define _mm_prefetch(address, hint) \
  __builtin_prefetch((const void *)(address), 0, (hint))
#endif
#else
#ifndef _MM_HINT_T0
#define _MM_HINT_T0 0
#endif
#ifndef _MM_HINT_T1
#define _MM_HINT_T1 0
#endif
#ifndef _mm_prefetch
#define _mm_prefetch(address, hint) ((void)(address), (void)(hint))
#endif
#endif
