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

const char *featureStdId = "feature_std";
const char *featureOsId = "feature_os";
const char *featureOsTimeoutId = "feature_os_timeout";

const char *undefinedId = "undefined";
const char *nanId = "NaN";

#define QUICKJSRB_SYM(id) \
  (VALUE) { ID2SYM(rb_intern(id)) }

// VM data structure

typedef struct EvalTime
{
  clock_t limit;
  clock_t started_at;
} EvalTime;

typedef struct VMData
{
  struct JSContext *context;
  VALUE defined_functions;
  struct EvalTime *eval_time;
  VALUE logs;
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
}

static const rb_data_type_t vm_type = {
    .wrap_struct_name = "quickjsvm",
    .function = {
        .dmark = vm_mark,
        .dfree = vm_free,
        .dsize = vm_size,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE vm_alloc(VALUE r_self)
{
  VMData *data;
  VALUE obj = TypedData_Make_Struct(r_self, VMData, &vm_type, data);
  data->defined_functions = rb_hash_new();
  data->logs = rb_ary_new();

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

// Constants

static void r_define_constants(VALUE r_parent_class)
{
  rb_define_const(r_parent_class, "MODULE_STD", QUICKJSRB_SYM(featureStdId));
  rb_define_const(r_parent_class, "MODULE_OS", QUICKJSRB_SYM(featureOsId));
  rb_define_const(r_parent_class, "FEATURES_TIMEOUT", QUICKJSRB_SYM(featureOsTimeoutId));

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

#endif /* QUICKJSRB_H */
