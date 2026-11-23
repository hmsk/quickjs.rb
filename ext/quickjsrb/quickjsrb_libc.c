// quickjs-libc keeps its event loop state static and the submodule is not ours
// to change, so it is compiled as part of this unit to reach that state.
#include "quickjs-libc.c"

#include "quickjsrb_libc.h"

int quickjsrb_os_poll(JSContext *ctx)
{
  return os_poll_func ? os_poll_func(ctx) : -1;
}
