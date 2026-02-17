#ifndef QUICKJSRB_H
#define QUICKJSRB_H 1

#include "ruby.h"

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

const char *featureStdId = "feature_std";
const char *featureOsId = "feature_os";
const char *featureTimeoutId = "feature_timeout";
const char *featurePolyfillIntlId = "feature_polyfill_intl";
const char *featurePolyfillFileId = "feature_polyfill_file";

const char *undefinedId = "undefined";
const char *nanId = "NaN";

const char *native_errors[] = {
    "SyntaxError",
    "TypeError",
    "ReferenceError",
    "RangeError",
    "EvalError",
    "URIError",
    "AggregateError"};

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
  VALUE logs;
  VALUE log_listener;
  VALUE alive_errors;
} VMData;

static void vm_free(void *ptr)
{
  VMData *data = (VMData *)ptr;
  free(data->eval_time);

  JSRuntime *runtime = JS_GetRuntime(data->context);
  JS_SetInterruptHandler(runtime, NULL, NULL);
  js_std_free_handlers(runtime);
  JS_FreeContext(data->context);
  JS_FreeRuntime(runtime);

  xfree(ptr);
}

size_t vm_size(const void *data)
{
  return sizeof(VMData);
}

static void vm_mark(void *ptr)
{
  VMData *data = (VMData *)ptr;
  rb_gc_mark_movable(data->defined_functions);
  rb_gc_mark_movable(data->logs);
  rb_gc_mark_movable(data->log_listener);
  rb_gc_mark_movable(data->alive_errors);
}

static void vm_compact(void *ptr)
{
  VMData *data = (VMData *)ptr;
  data->defined_functions = rb_gc_location(data->defined_functions);
  data->logs = rb_gc_location(data->logs);
  data->log_listener = rb_gc_location(data->log_listener);
  data->alive_errors = rb_gc_location(data->alive_errors);
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

static VALUE vm_alloc(VALUE r_self)
{
  VMData *data;
  VALUE obj = TypedData_Make_Struct(r_self, VMData, &vm_type, data);
  data->defined_functions = rb_hash_new();
  data->logs = rb_ary_new();
  data->log_listener = Qnil;
  data->alive_errors = rb_hash_new();

  EvalTime *eval_time = malloc(sizeof(EvalTime));
  data->eval_time = eval_time;

  JSRuntime *runtime = JS_NewRuntime();
  data->context = JS_NewContext(runtime);

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
  bool is_native_error = false;
  int numStrings = sizeof(native_errors) / sizeof(native_errors[0]);
  for (int i = 0; i < numStrings; i++)
  {
    if (strcmp(native_errors[i], error_name) == 0)
    {
      is_native_error = true;
      break;
    }
  }
  return is_native_error;
}

// Constants

static void r_define_constants(VALUE r_parent_class)
{
  rb_define_const(r_parent_class, "MODULE_STD", QUICKJSRB_SYM(featureStdId));
  rb_define_const(r_parent_class, "MODULE_OS", QUICKJSRB_SYM(featureOsId));
  rb_define_const(r_parent_class, "FEATURE_TIMEOUT", QUICKJSRB_SYM(featureTimeoutId));
  rb_define_const(r_parent_class, "POLYFILL_INTL", QUICKJSRB_SYM(featurePolyfillIntlId));
  rb_define_const(r_parent_class, "POLYFILL_FILE", QUICKJSRB_SYM(featurePolyfillFileId));

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

VALUE vm_m_initialize_quickjs_error(VALUE self, VALUE r_message, VALUE r_js_name)
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

  // JS native errors
  int numStrings = sizeof(native_errors) / sizeof(native_errors[0]);
  for (int i = 0; i < numStrings; i++)
  {
    rb_define_class_under(r_parent_class, native_errors[i], r_runtime_error);
  }

  // quickjsrb specific errors
  rb_define_class_under(r_parent_class, QUICKJSRB_INTERRUPTED_ERROR, r_runtime_error);
  rb_define_class_under(r_parent_class, QUICKJSRB_NO_AWAIT_ERROR, r_runtime_error);
}

#endif /* QUICKJSRB_H */
