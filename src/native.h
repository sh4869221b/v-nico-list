#include <signal.h>
#include <stdio.h>
#include <errno.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
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
static void *nico_log_open(const void *path) {
#ifdef _WIN32
  return _wfopen((const wchar_t *)path, L"a");
#else
  return fopen((const char *)path, "a");
#endif
}

static int nico_log_write(void *file, const unsigned char *s, size_t n) {
  return fwrite(s, 1, n, (FILE *)file) == n && fflush((FILE *)file) == 0;
}

static int nico_log_close(void *file) { return fclose((FILE *)file); }

/* On Linux open a separate file description so setting O_NONBLOCK cannot
   affect another process that inherited the same pipe writer. With no procfs,
   temporarily set the flag on the original descriptor and restore it on exit. */
#ifndef _WIN32
static int nico_pipe_writer(int fd, int *original_flags) {
  struct stat st;
  if (fstat(fd, &st) < 0 || !S_ISFIFO(st.st_mode)) return fd;
#ifdef __linux__
  char path[64];
  snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
  int independent = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (independent >= 0) return independent;
#endif
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return -1;
  if (flags & O_NONBLOCK) return fd;
  if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
  *original_flags = flags;
  return fd;
}
#endif

/* Keep writing completed results if the pipe can take them. Once a write
   would wait, both signal and internal cancellation abandon the remainder. */
static size_t nico_output_prefix(const unsigned char *s, size_t n, int *interrupted) {
  size_t done = 0;
#ifdef _WIN32
  int fd = _fileno(stdout);
#else
  int stdout_fd = fileno(stdout);
  int original_flags = -1;
  int fd = nico_pipe_writer(stdout_fd, &original_flags);
  if (fd < 0) return 0;
#endif
  while (done < n) {
#ifdef _WIN32
    unsigned int chunk = n - done < 32768 ? (unsigned int)(n - done) : 32768;
    int written = _write(fd, s + done, chunk);
#else
    ssize_t written = write(fd, s + done, n - done);
#endif
    if (written > 0) {
      done += (size_t)written;
      continue;
    }
    if (written < 0 && (errno == EINTR || errno == EAGAIN)) {
      if (nico_cancelled()) {
        *interrupted = 1;
        break;
      }
      if (errno == EINTR) continue;
#ifndef _WIN32
      struct pollfd wait = {fd, POLLOUT, 0};
      if (poll(&wait, 1, 20) >= 0 || errno == EINTR) continue;
#endif
    }
    break;
  }
#ifndef _WIN32
  if (fd != stdout_fd) close(fd);
  if (original_flags >= 0) fcntl(fd, F_SETFL, original_flags);
#endif
  return done;
}
