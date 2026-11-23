// quickjs-libc keeps its event loop state static and the submodule is not ours
// to change, so it is compiled as part of this unit to reach that state.
#include "quickjs-libc.c"

#include "quickjsrb_libc.h"

int quickjsrb_os_poll(JSContext *ctx)
{
  return os_poll_func ? os_poll_func(ctx) : -1;
}

int quickjsrb_os_has_event_source(JSContext *ctx)
{
  JSThreadState *ts = JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
  return !list_empty(&ts->os_timers) || !list_empty(&ts->os_rw_handlers) ||
         !list_empty(&ts->port_list) || !list_empty(&ts->os_signal_handlers);
}
