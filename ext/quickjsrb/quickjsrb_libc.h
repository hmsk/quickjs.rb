#ifndef QUICKJSRB_LIBC_H
#define QUICKJSRB_LIBC_H 1

#include "quickjs.h"

// One pass of quickjs-libc's event loop. Zero when it waited or ran a handler,
// nonzero when it had nothing to wait on.
int quickjsrb_os_poll(JSContext *ctx);

#endif
