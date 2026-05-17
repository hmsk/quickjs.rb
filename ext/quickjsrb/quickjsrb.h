#ifndef QUICKJSRB_H
#define QUICKJSRB_H 1

#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/thread.h"

#include "quickjs.h"
#include "quickjs-libc.h"
#include "cutils.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

extern const uint32_t qjsc_polyfill_intl_en_min_size;
extern const uint8_t qjsc_polyfill_intl_en_min;
extern const uint32_t qjsc_polyfill_file_min_size;
extern const uint8_t qjsc_polyfill_file_min;
extern const uint32_t qjsc_polyfill_encoding_min_size;
extern const uint8_t qjsc_polyfill_encoding_min;
extern const uint32_t qjsc_polyfill_url_min_size;
extern const uint8_t qjsc_polyfill_url_min;

extern const char *featureStdId;
extern const char *featureOsId;
extern const char *featureTimeoutId;
extern const char *featurePolyfillIntlId;
extern const char *featurePolyfillFileId;
extern const char *featurePolyfillEncodingId;
extern const char *featurePolyfillUrlId;
extern const char *featurePolyfillCryptoId;

extern const char *undefinedId;
extern const char *nanId;

extern const char *native_errors[];
extern const int num_native_errors;

#define QUICKJSRB_SYM(id) \
  (VALUE) { ID2SYM(rb_intern(id)) }

// VM data structure

typedef struct EvalTime
{
  int64_t limit_ms;
  struct timespec started_at;
} EvalTime;

typedef struct VMData
{
  struct JSContext *context;
  VALUE defined_functions;
  struct EvalTime *eval_time;
  VALUE log_listener;
  VALUE alive_objects;
  VALUE module_loader;
  JSValue j_file_proxy_creator;
  // Once the runtime has hit JS-level "out of memory", the QuickJS heap is in
  // a fragile state where further evaluation can trigger a use-after-free in
  // the parser-error-during-OOM cascade (segfault inside js_shape_hash_unlink).
  // Trip this flag so subsequent eval_code/call calls refuse cleanly with a
  // Ruby exception instead of risking a process crash.
  bool oom_poisoned;
  // Set by VM#dispose! to release the multi-MB JS heap before Ruby GC sees
  // enough pressure to collect the wrapper. Doubles as a double-free guard
  // for the dfree handler.
  bool disposed;
} VMData;

static void vm_teardown_context(JSContext *ctx)
{
  JSRuntime *runtime = JS_GetRuntime(ctx);
  JS_SetInterruptHandler(runtime, NULL, NULL);
  js_std_free_handlers(runtime);
  JS_FreeContext(ctx);
  JS_FreeRuntime(runtime);
}

static void vm_free(void *ptr)
{
  VMData *data = (VMData *)ptr;
  free(data->eval_time);

  if (!data->disposed)
  {
    if (!JS_IsUndefined(data->j_file_proxy_creator))
      JS_FreeValue(data->context, data->j_file_proxy_creator);

    vm_teardown_context(data->context);
  }

  xfree(ptr);
}

static size_t vm_size(const void *data)
{
  return sizeof(VMData);
}

static void vm_mark(void *ptr)
{
  VMData *data = (VMData *)ptr;
  rb_gc_mark_movable(data->defined_functions);
  rb_gc_mark_movable(data->log_listener);
  rb_gc_mark_movable(data->alive_objects);
  rb_gc_mark_movable(data->module_loader);
}

static void vm_compact(void *ptr)
{
  VMData *data = (VMData *)ptr;
  data->defined_functions = rb_gc_location(data->defined_functions);
  data->log_listener = rb_gc_location(data->log_listener);
  data->alive_objects = rb_gc_location(data->alive_objects);
  data->module_loader = rb_gc_location(data->module_loader);
}

static const rb_data_type_t vm_type = {
    .wrap_struct_name = "quickjsvm",
    .function = {
        .dmark = vm_mark,
        .dfree = vm_free,
        .dsize = vm_size,
        .dcompact = vm_compact,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

struct vm_create_args
{
  JSContext *context;
};

static void *vm_create_no_gvl(void *p)
{
  struct vm_create_args *args = p;
  args->context = JS_NewContext(JS_NewRuntime());
  return NULL;
}

static VALUE vm_alloc(VALUE r_self)
{
  VMData *data;
  VALUE obj = TypedData_Make_Struct(r_self, VMData, &vm_type, data);
  data->defined_functions = rb_hash_new();
  data->log_listener = Qnil;
  data->alive_objects = rb_hash_new();
  data->module_loader = Qnil;
  data->j_file_proxy_creator = JS_UNDEFINED;
  data->oom_poisoned = false;
  data->disposed = false;

  EvalTime *eval_time = malloc(sizeof(EvalTime));
  data->eval_time = eval_time;

  // JSRuntime / JSContext creation is pure QuickJS C work — no Ruby state
  // touched. Release the GVL so a background warmer thread can run this in
  // parallel with the main thread on multi-core hosts.
  struct vm_create_args args = {NULL};
  rb_thread_call_without_gvl(vm_create_no_gvl, &args, NULL, NULL);
  data->context = args.context;

  return obj;
}

// Utils

static char *random_string()
{
  VALUE r_rand = rb_funcall(
      rb_const_get(rb_cClass, rb_intern("SecureRandom")),
      rb_intern("alphanumeric"),
      1,
      INT2NUM(12));
  return StringValueCStr(r_rand);
}

static bool is_native_error_name(const char *error_name)
{
  for (int i = 0; i < num_native_errors; i++)
  {
    if (strcmp(native_errors[i], error_name) == 0)
      return true;
  }
  return false;
}

// Constants

static void r_define_constants(VALUE r_parent_class)
{
  rb_define_const(r_parent_class, "MODULE_STD", QUICKJSRB_SYM(featureStdId));
  rb_define_const(r_parent_class, "MODULE_OS", QUICKJSRB_SYM(featureOsId));
  rb_define_const(r_parent_class, "FEATURE_TIMEOUT", QUICKJSRB_SYM(featureTimeoutId));
  rb_define_const(r_parent_class, "POLYFILL_INTL", QUICKJSRB_SYM(featurePolyfillIntlId));
  rb_define_const(r_parent_class, "POLYFILL_FILE", QUICKJSRB_SYM(featurePolyfillFileId));
  rb_define_const(r_parent_class, "POLYFILL_ENCODING", QUICKJSRB_SYM(featurePolyfillEncodingId));
  rb_define_const(r_parent_class, "POLYFILL_URL", QUICKJSRB_SYM(featurePolyfillUrlId));
  rb_define_const(r_parent_class, "POLYFILL_CRYPTO", QUICKJSRB_SYM(featurePolyfillCryptoId));

  VALUE rb_cQuickjsValue = rb_define_class_under(r_parent_class, "Value", rb_cObject);
  rb_define_const(rb_cQuickjsValue, "UNDEFINED", QUICKJSRB_SYM(undefinedId));
  rb_define_const(rb_cQuickjsValue, "NAN", QUICKJSRB_SYM(nanId));
}

// Log class

static VALUE r_proc_pick_raw(VALUE block_arg, VALUE data, int argc, const VALUE *argv, VALUE blockarg)
{
  return rb_hash_aref(block_arg, ID2SYM(rb_intern("raw")));
}

static VALUE r_log_m_raw(VALUE r_self)
{
  VALUE row = rb_iv_get(r_self, "@row");
  VALUE r_ary = rb_block_call(row, rb_intern("map"), 0, NULL, r_proc_pick_raw, Qnil);

  return r_ary;
}

static VALUE r_proc_pick_c(VALUE block_arg, VALUE data, int argc, const VALUE *argv, VALUE blockarg)
{
  return rb_hash_aref(block_arg, ID2SYM(rb_intern("c")));
}

static VALUE r_log_m_to_s(VALUE r_self)
{
  VALUE row = rb_iv_get(r_self, "@row");
  VALUE r_ary = rb_block_call(row, rb_intern("map"), 0, NULL, r_proc_pick_c, Qnil);

  return rb_funcall(r_ary, rb_intern("join"), 1, rb_str_new2(" "));
}

static VALUE r_define_log_class(VALUE r_parent_class)
{
  VALUE r_log_class = rb_define_class_under(r_parent_class, "Log", rb_cObject);
  rb_define_attr(r_log_class, "severity", 1, 0);
  rb_define_method(r_log_class, "raw", r_log_m_raw, 0);
  rb_define_method(r_log_class, "to_s", r_log_m_to_s, 0);
  rb_define_method(r_log_class, "inspect", r_log_m_to_s, 0);

  return r_log_class;
}

static VALUE r_log_new(const char *severity, VALUE r_row)
{
  VALUE r_log_class = rb_const_get(rb_const_get(rb_const_get(rb_cClass, rb_intern("Quickjs")), rb_intern("VM")), rb_intern("Log"));
  VALUE r_log = rb_funcall(r_log_class, rb_intern("new"), 0);
  rb_iv_set(r_log, "@severity", ID2SYM(rb_intern(severity)));
  rb_iv_set(r_log, "@row", r_row);
  return r_log;
}

static VALUE r_log_body_new(VALUE r_raw, VALUE r_c)
{
  VALUE r_log_body = rb_hash_new();
  rb_hash_aset(r_log_body, ID2SYM(rb_intern("raw")), r_raw);
  rb_hash_aset(r_log_body, ID2SYM(rb_intern("c")), r_c);
  return r_log_body;
}

// Exceptions

#define QUICKJSRB_ROOT_RUNTIME_ERROR "RuntimeError"
#define QUICKJSRB_INTERRUPTED_ERROR "InterruptedError"
#define QUICKJSRB_NO_AWAIT_ERROR "NoAwaitError"

#define QUICKJSRB_ERROR_FOR(name) \
  (VALUE) { rb_const_get(rb_const_get(rb_cClass, rb_intern("Quickjs")), rb_intern(name)) }

static VALUE vm_m_initialize_quickjs_error(VALUE self, VALUE r_message, VALUE r_js_name)
{
  rb_call_super(1, &r_message);
  rb_iv_set(self, "@js_name", r_js_name);

  return self;
}

static void r_define_exception_classes(VALUE r_parent_class)
{
  VALUE r_runtime_error = rb_define_class_under(r_parent_class, QUICKJSRB_ROOT_RUNTIME_ERROR, rb_eRuntimeError);
  rb_define_method(r_runtime_error, "initialize", vm_m_initialize_quickjs_error, 2);
  rb_define_attr(r_runtime_error, "js_name", 1, 0);

  for (int i = 0; i < num_native_errors; i++)
  {
    rb_define_class_under(r_parent_class, native_errors[i], r_runtime_error);
  }

  // quickjsrb specific errors
  rb_define_class_under(r_parent_class, QUICKJSRB_INTERRUPTED_ERROR, r_runtime_error);
  rb_define_class_under(r_parent_class, QUICKJSRB_NO_AWAIT_ERROR, r_runtime_error);
}

#endif /* QUICKJSRB_H */
