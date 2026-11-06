#include <signal.h>
#include <stdio.h>
#ifdef _MSC_VER
#include <intrin.h>
static volatile long nico_signal = 0;
static int nico_cancelled(void) {
  return (int)_InterlockedCompareExchange(&nico_signal, 0, 0);
}
static void nico_cancel(void) { _InterlockedExchange(&nico_signal, 1); }
#else
/* int atomics are lock-free on the supported Linux/Windows architectures;
   the signal handler never enters the allocator or a library mutex. */
static int nico_signal = 0;
static int nico_cancelled(void) {
  return __atomic_load_n(&nico_signal, __ATOMIC_RELAXED);
}
static void nico_cancel(void) {
  __atomic_store_n(&nico_signal, 1, __ATOMIC_RELAXED);
}
#endif
static void nico_handler(int sig) { (void)sig; nico_cancel(); }
static void nico_signals(void) {
  signal(SIGINT, nico_handler);
  signal(SIGTERM, nico_handler);
#ifndef _WIN32
  signal(SIGPIPE, SIG_IGN);
#endif
}
static int nico_output(const unsigned char *s, size_t n) {
  return fwrite(s, 1, n, stdout) == n && fflush(stdout) == 0;
}
