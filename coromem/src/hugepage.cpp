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
    // No-root hugepage path.  Explicit 2 MiB hugepages are dead on kernels
    // whose default hugepage size != 2 MiB (e.g. 512 MiB on 64 KiB-base
    // aarch64), and we cannot reserve pages without root.  Transparent
    // Hugepages are the workaround: madvise(MADV_HUGEPAGE) marks the VMA so
    // the kernel backs it with THP on fault.  Effective when THP is 'always'
    // or 'madvise'; a harmless no-op (returns EINVAL) when 'never'.
    //
    // Timing: this runs inside allocPages, BEFORE the caller (numa_mem.cpp
    // pageIn) first-touches the pages, so the faults use THP.  For the
    // preFault=true path MAP_POPULATE already faulted base pages, so THP
    // then relies on khugepaged collapsing them asynchronously -- less
    // reliable, but the big interleaved data buffers use preFault=false.
    if (ptr) {
      if (madvise(ptr, (size_t)num * hugePageSize, MADV_HUGEPAGE) != 0) {
        static std::once_flag thp_warn;
        std::call_once(thp_warn, []() {
          printf("INFO: madvise(MADV_HUGEPAGE) failed (errno=%d %s); THP "
                 "may be disabled. Check: "
                 "/sys/kernel/mm/transparent_hugepage/enabled\n",
                 errno, strerror(errno));
        });
      }
    }
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
