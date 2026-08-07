#ifndef COROGRAPH_COROLOCK
#define COROGRAPH_COROLOCK

#include <atomic>
#include <coroutine>
#include <thread>

inline static void coroAsmPause() {
#if defined(__i386__) || defined(__amd64__)
  asm volatile("pause");
#elif defined(__aarch64__) || defined(__arm__)
  asm volatile("yield");
#else
  std::this_thread::yield();
#endif
}

class CoroLock {
public:
  CoroLock() = default;
  void lock(std::coroutine_handle<> hd) {
    while (flag.test_and_set(std::memory_order_acquire)) {
      if (!hd.done())
        hd();
      else
        std::this_thread::yield();
    }
  }
  void lock() {
    while (flag.test_and_set(std::memory_order_acquire)) {
      coroAsmPause();
    }
  }
  void unlock() { flag.clear(std::memory_order_release); }

private:
  std::atomic_flag flag = ATOMIC_FLAG_INIT;
};

#endif
