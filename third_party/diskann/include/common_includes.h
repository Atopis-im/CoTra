// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT license.

#pragma once

#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <omp.h>
#include <queue>
#include <random>
#include <set>
#include <shared_mutex>
#include <sys/stat.h>
#include <sstream>
#include <unordered_map>
#include <vector>

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
#endif
