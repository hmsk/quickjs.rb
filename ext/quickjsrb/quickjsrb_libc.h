#ifndef QUICKJSRB_LIBC_H
#define QUICKJSRB_LIBC_H 1

#include "quickjs.h"

// One pass of quickjs-libc's event loop. Zero when it waited or ran a handler,
// nonzero when it had nothing to wait on.
int quickjsrb_os_poll(JSContext *ctx);

// Whether a timer, I/O handler, worker port or signal handler could still run
// JS on this runtime.
int quickjsrb_os_has_event_source(JSContext *ctx);

#endif
