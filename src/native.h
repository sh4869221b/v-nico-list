#include <signal.h>
#include <stdio.h>
#include <errno.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
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

/* Direct descriptor writes report the accepted prefix even when a later write
   fails. No stdio buffer can hide successfully emitted lines on a broken pipe.
   The caller limits each batch to 32 KiB; stdout keeps its existing binary mode. */
static unsigned int nico_output_prefix(const unsigned char *s, unsigned int n) {
  unsigned int done = 0;
  while (done < n) {
#ifdef _WIN32
    int written = _write(_fileno(stdout), s + done, n - done);
#else
    ssize_t written = write(fileno(stdout), s + done, n - done);
#endif
    if (written < 0 && errno == EINTR && !nico_cancelled()) continue;
    if (written <= 0) break;
    done += (unsigned int)written;
  }
  return done;
}
