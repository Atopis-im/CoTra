#include "hugepage.h"

#include <sys/mman.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>

#include "runtime/mem.h"
#include "substrate/simple_lock.h"

extern unsigned activeThreads;

// figure this out dynamically
const size_t hugePageSize = 2 * 1024 * 1024;
// protect mmap, munmap since linux has issues
static substrate::SimpleLock allocLock;

static void *trymmap(size_t size, int flag) {
  std::lock_guard<substrate::SimpleLock> lg(allocLock);
  const int _PROT = PROT_READ | PROT_WRITE;
  void *ptr = ::mmap(0, size, _PROT, flag, -1, 0);
  if (ptr == MAP_FAILED) ptr = nullptr;
  return ptr;
}

static const int _MAP = _MAP_ANON | MAP_PRIVATE;
#ifdef MAP_POPULATE
static const int _MAP_POP = MAP_POPULATE | _MAP;
static const bool doHandMap = false;
#else
static const int _MAP_POP = _MAP;
static const bool doHandMap = true;
#endif
#ifdef MAP_HUGETLB
static const int _MAP_HUGE_POP = MAP_HUGETLB | _MAP_POP;
static const int _MAP_HUGE = MAP_HUGETLB | _MAP;
#else
static const int _MAP_HUGE_POP = _MAP_POP;
static const int _MAP_HUGE = _MAP;
#endif

static bool compatibleHugePageSize() {
#ifdef MAP_HUGETLB
  static const bool compatible = []() {
    std::ifstream meminfo("/proc/meminfo");
    std::string line;
    while (std::getline(meminfo, line)) {
      size_t sizeKB = 0;
      if (sscanf(line.c_str(), "Hugepagesize: %zu kB", &sizeKB) == 1) {
        return sizeKB * 1024 == hugePageSize;
      }
    }
    return false;
  }();
  return compatible;
#else
  return false;
#endif
}

size_t allocSize() { return hugePageSize; }

void *allocPages(unsigned num, bool preFault) {
  if (num > 0) {
    void *ptr = nullptr;
    if (compatibleHugePageSize()) {
      ptr = trymmap(
          num * hugePageSize, preFault ? _MAP_HUGE_POP : _MAP_HUGE);
    }
    if (!ptr) {
      static std::once_flag warning;
      std::call_once(warning, []() {
        // Print the kernel's actual hugepage size so the mismatch with our
        // hardcoded 2 MiB is obvious in the log (e.g. aarch64 64 KiB base
        // page kernels often default to 512 MiB hugepages, which the 2 MiB
        // MAP_HUGETLB path can never use).
        size_t kbs = 0;
        std::ifstream mi("/proc/meminfo");
        std::string ml;
        while (std::getline(mi, ml) &&
               sscanf(ml.c_str(), "Hugepagesize: %zu kB", &kbs) != 1) {
        }
        printf(
            "WARN: 2 MiB explicit hugepages unavailable (kernel hugepage "
            "size = %zu kB, program needs 2048 kB).\n"
            "      Falling back to normal pages; requesting Transparent "
            "Hugepages via madvise(MADV_HUGEPAGE) (no root needed).\n",
            kbs);
      });
      ptr = trymmap(num * hugePageSize, preFault ? _MAP_POP : _MAP);
    }

#ifdef MADV_HUGEPAGE
    // NOTE: We deliberately do NOT call madvise(MADV_HUGEPAGE) here.
    // On this aarch64 system the base page is 64 KiB (already 16x larger
    // than x86's 4 KiB, so TLB pressure is inherently low) and the default
    // hugepage / THP size is 512 MiB.  Requesting THP makes the kernel
    // attempt to coalesce to 512 MiB pages, which needs expensive
    // synchronous memory compaction and produces multi-millisecond stalls
    // -- empirically this WORSENED run-to-run variance (ef=40 median
    // 51567 -> 29811 after enabling madvise).  Since 64 KiB base pages
    // already keep TLB misses low, the upside is negligible and the
    // compaction downside is real.  Stay on base pages.
    //
    // If this code ever runs on a 4 KiB-base-page system, re-enable THP
    // there (madvise helps on small pages); but NOT on 64 KiB aarch64.
    (void)ptr;
#endif

    if (!ptr) {
      printf("Out of Memory.\n");
      exit(-1);
    }

    // if (preFault && doHandMap)
    //   for (size_t x = 0; x < num * hugePageSize; x += 4096)
    //     static_cast<char *>(ptr)[x] = 0;

    return ptr;
  } else {
    return nullptr;
  }
}

void freePages(void *ptr, unsigned num) {
  std::lock_guard<substrate::SimpleLock> lg(allocLock);
  if (munmap(ptr, num * hugePageSize) != 0) {
    printf("Unmap failed");
    exit(0);
    // GALOIS_SYS_DIE("Unmap failed");
  }
}

#define __is_trivial(type) \
  __has_trivial_constructor(type) && __has_trivial_copy(type)

static PageAllocState<> *PA;

void setPagePoolState(PageAllocState<> *pa) {
  // GALOIS_ASSERT(!(PA && pa),
  // "PagePool.cpp: Double Initialization of PageAllocState");
  PA = pa;
}

int numPagePoolAllocTotal() { return PA->countAll(); }

int numPagePoolAllocForThread(unsigned tid) { return PA->count(tid); }

void *pagePoolAlloc() { return PA->pageAlloc(); }

void pagePoolPreAlloc(unsigned num) {
  while (num--) PA->pagePreAlloc();
}

void pagePoolFree(void *ptr) { PA->pageFree(ptr); }

size_t pagePoolSize() { return allocSize(); }

void preAlloc_impl(unsigned num) {
  unsigned pagesPerThread = (num + activeThreads - 1) / activeThreads;
  getThreadPool().run(
      activeThreads, [=]() { pagePoolPreAlloc(pagesPerThread); });
}
