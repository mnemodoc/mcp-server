/* FSEvents bridge for the macOS watch backend (Watch::FSEvents).

   FSEvents delivers its callback on a dispatch queue, i.e. on a thread the
   Crystal runtime does not know about. Running Crystal code there — even
   allocating — is unsafe, so the callback runs none: it serialises each event
   into a pipe, and a Crystal fiber reads the other end through the event loop.

   Record format, one per event, native endianness:
     uint32 flags, uint32 path length in bytes, path bytes (no terminator).
   Length-prefixed rather than line-based, so a file name containing a newline
   or a tab travels intact.

   The write end stays blocking and belongs to this file: the queue is serial,
   so records never interleave, and a full pipe only delays the callback while
   the reader catches up. Stopping the stream closes it, which is how the
   reader learns the stream is gone. */

#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct mnemo_fsevents {
  FSEventStreamRef stream;
  dispatch_queue_t queue;
  int write_fd;
} mnemo_fsevents;

static int write_all(int fd, const void *data, size_t size) {
  const char *cursor = data;
  while (size > 0) {
    ssize_t written = write(fd, cursor, size);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    cursor += written;
    size -= (size_t)written;
  }
  return 0;
}

static void on_events(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                      const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
  (void)stream;
  (void)ids;
  mnemo_fsevents *watch = info;
  char **event_paths = paths;
  for (size_t i = 0; i < count; i++) {
    uint32_t header[2];
    size_t length = strlen(event_paths[i]);
    header[0] = (uint32_t)flags[i];
    header[1] = (uint32_t)length;
    /* A failed write means the reader is gone: nothing left to tell. */
    if (write_all(watch->write_fd, header, sizeof(header)) != 0 ||
        write_all(watch->write_fd, event_paths[i], length) != 0) {
      return;
    }
  }
}

/* Starts a stream over *count* root paths. Returns the watch handle and stores
   the pipe's read end in *read_fd*, or returns NULL when the pipe or the stream
   could not be created or started. */
mnemo_fsevents *mnemo_fsevents_start(const char **roots, int count, double latency, int *read_fd) {
  int fds[2];
  if (pipe(fds) != 0) {
    return NULL;
  }
  /* Close-on-exec on both ends: Crystal starts a child with fork and exec and
     closes nothing, so without it every pdftotext the daemon ran inherited the
     pipe — and a child holding the write end delays the end of file the reader
     waits for at stop. macOS has no pipe2, hence fcntl. */
  fcntl(fds[0], F_SETFD, FD_CLOEXEC);
  fcntl(fds[1], F_SETFD, FD_CLOEXEC);

  mnemo_fsevents *watch = calloc(1, sizeof(mnemo_fsevents));
  CFMutableArrayRef paths = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
  if (!watch || !paths) {
    free(watch);
    if (paths) {
      CFRelease(paths);
    }
    close(fds[0]);
    close(fds[1]);
    return NULL;
  }
  for (int i = 0; i < count; i++) {
    CFStringRef path = CFStringCreateWithCString(NULL, roots[i], kCFStringEncodingUTF8);
    if (path) {
      CFArrayAppendValue(paths, path);
      CFRelease(path);
    }
  }

  watch->write_fd = fds[1];
  FSEventStreamContext context = {0, watch, NULL, NULL, NULL};
  /* FileEvents: one event per file rather than per directory. NoDefer: the
     first event of a burst is delivered at once. WatchRoot: a configured root
     that is moved or deleted reports itself (RootChanged). */
  FSEventStreamCreateFlags create_flags = kFSEventStreamCreateFlagFileEvents |
                                          kFSEventStreamCreateFlagNoDefer |
                                          kFSEventStreamCreateFlagWatchRoot;
  watch->stream = FSEventStreamCreate(NULL, on_events, &context, paths, kFSEventStreamEventIdSinceNow,
                                      latency, create_flags);
  CFRelease(paths);
  if (!watch->stream) {
    close(fds[0]);
    close(fds[1]);
    free(watch);
    return NULL;
  }

  watch->queue = dispatch_queue_create("mnemodoc.fsevents", DISPATCH_QUEUE_SERIAL);
  FSEventStreamSetDispatchQueue(watch->stream, watch->queue);
  if (!FSEventStreamStart(watch->stream)) {
    FSEventStreamInvalidate(watch->stream);
    FSEventStreamRelease(watch->stream);
    dispatch_release(watch->queue);
    close(fds[0]);
    close(fds[1]);
    free(watch);
    return NULL;
  }

  *read_fd = fds[0];
  return watch;
}

/* Stops the stream, waits for any callback in flight, then closes the write
   end — the reader sees end of file. The read end is the caller's to close. */
void mnemo_fsevents_stop(mnemo_fsevents *watch) {
  if (!watch) {
    return;
  }
  FSEventStreamStop(watch->stream);
  FSEventStreamInvalidate(watch->stream);
  FSEventStreamRelease(watch->stream);
  /* Drains the serial queue: no callback can still be writing after this. */
  dispatch_sync(watch->queue, ^{
                });
  dispatch_release(watch->queue);
  close(watch->write_fd);
  free(watch);
}
