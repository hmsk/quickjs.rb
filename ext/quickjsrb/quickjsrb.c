#include "quickjsrb.h"

VALUE rb_mQuickjs;
const char *undefinedId = "undefined";
const char *nanId = "NaN";

const char *featureStdId = "feature_std";
const char *featureOsId = "feature_os";

VALUE to_rb_value (JSValue jsv, JSContext *ctx) {
  switch(JS_VALUE_GET_NORM_TAG(jsv)) {
  case JS_TAG_INT: {
    int int_res = 0;
    JS_ToInt32(ctx, &int_res, jsv);
    return INT2NUM(int_res);
  }
  case JS_TAG_FLOAT64: {
    if (JS_VALUE_IS_NAN(jsv)) {
      return ID2SYM(rb_intern(nanId));
    }
    double double_res;
    JS_ToFloat64(ctx, &double_res, jsv);
    return DBL2NUM(double_res);
  }
  case JS_TAG_BOOL: {
    return JS_ToBool(ctx, jsv) > 0 ? Qtrue : Qfalse;
  }
  case JS_TAG_STRING: {
    JSValue maybeString = JS_ToString(ctx, jsv);
    const char *msg = JS_ToCString(ctx, maybeString);
    return rb_str_new2(msg);
  }
  case JS_TAG_OBJECT: {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue jsonClass = JS_GetPropertyStr(ctx, global, "JSON");
    JSValue stringifyFunc = JS_GetPropertyStr(ctx, jsonClass, "stringify");
    JSValue strigified = JS_Call(ctx, stringifyFunc, jsonClass, 1, &jsv);

    const char *msg = JS_ToCString(ctx, strigified);
    VALUE rbString = rb_str_new2(msg);

    JS_FreeValue(ctx, global);
    JS_FreeValue(ctx, strigified);
    JS_FreeValue(ctx, stringifyFunc);
    JS_FreeValue(ctx, jsonClass);

    return rb_funcall(rb_const_get(rb_cClass, rb_intern("JSON")), rb_intern("parse"), 1, rbString);
  }
  case JS_TAG_NULL:
    return Qnil;
  case JS_TAG_UNDEFINED:
    return ID2SYM(rb_intern(undefinedId));
  case JS_TAG_EXCEPTION:
    rb_raise(rb_eRuntimeError, "Something happened by evaluating as JavaScript code");
    return Qnil;
  case JS_TAG_BIG_INT: {
    JSValue toStringFunc = JS_GetPropertyStr(ctx, jsv, "toString");
    JSValue strigified = JS_Call(ctx, toStringFunc, jsv, 0, NULL);

    const char *msg = JS_ToCString(ctx, strigified);
    VALUE rbString = rb_str_new2(msg);
    JS_FreeValue(ctx, strigified);
    JS_FreeValue(ctx, toStringFunc);

    return rb_funcall(rbString, rb_intern("to_i"), 0, NULL);
  }
  case JS_TAG_BIG_FLOAT:
  case JS_TAG_BIG_DECIMAL:
  case JS_TAG_SYMBOL:
  default:
    return Qnil;
  }
}

struct qvmdata {
  struct JSContext *context;
  char alive;
};

void qvm_free(void* data)
{
  free(data);
}

size_t qvm_size(const void* data)
{
  return sizeof(data);
}

static const rb_data_type_t qvm_type = {
  .wrap_struct_name = "qvm",
  .function = {
    .dmark = NULL,
    .dfree = qvm_free,
    .dsize = qvm_size,
  },
  .data = NULL,
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

VALUE qvm_alloc(VALUE self)
{
  struct qvmdata *data;

  return TypedData_Make_Struct(self, struct qvmdata, &qvm_type, data);
}

VALUE qvm_m_initialize(int argc, VALUE* argv, VALUE self)
{
  VALUE r_opts;
  rb_scan_args(argc, argv, ":", &r_opts);
  if (NIL_P(r_opts)) r_opts = rb_hash_new();

  VALUE r_memoryLimit = rb_hash_aref(r_opts, ID2SYM(rb_intern("memory_limit")));
  if (NIL_P(r_memoryLimit)) r_memoryLimit = UINT2NUM(1024 * 1024 * 128);
  VALUE r_maxStackSize = rb_hash_aref(r_opts, ID2SYM(rb_intern("max_stack_size")));
  if (NIL_P(r_maxStackSize)) r_maxStackSize = UINT2NUM(1024 * 1024 * 4);
  VALUE r_features = rb_hash_aref(r_opts, ID2SYM(rb_intern("features")));
  if (NIL_P(r_features)) r_features = rb_ary_new();

  struct qvmdata *data;
  TypedData_Get_Struct(self, struct qvmdata, &qvm_type, data);
  JSRuntime *runtime = JS_NewRuntime();
  data->context = JS_NewContext(runtime);
  data->alive = 1;

  JS_SetMemoryLimit(runtime, NUM2UINT(r_memoryLimit));
  JS_SetMaxStackSize(runtime, NUM2UINT(r_maxStackSize));

  JS_AddIntrinsicBigFloat(data->context);
  JS_AddIntrinsicBigDecimal(data->context);
  JS_AddIntrinsicOperators(data->context);
  JS_EnableBignumExt(data->context, TRUE);
  js_std_add_helpers(data->context, 0, NULL);

  JS_SetModuleLoaderFunc(runtime, NULL, js_module_loader, NULL);
  js_std_init_handlers(runtime);

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, ID2SYM(rb_intern(featureStdId))))) {
    js_init_module_std(data->context, "std");
    const char *enableStd = "import * as std from 'std';\n"
        "globalThis.std = std;\n";
    JSValue stdEval = JS_Eval(data->context, enableStd, strlen(enableStd), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, stdEval);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, ID2SYM(rb_intern(featureOsId))))) {
    js_init_module_os(data->context, "os");
    const char *enableOs = "import * as os from 'os';\n"
        "globalThis.os = os;\n";
    JSValue osEval = JS_Eval(data->context, enableOs, strlen(enableOs), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, osEval);
  }

  return self;
}

VALUE qvm_m_evalCode(VALUE self, VALUE r_code)
{
  struct qvmdata *data;
  TypedData_Get_Struct(self, struct qvmdata, &qvm_type, data);

  if (data->alive < 1) {
    rb_raise(rb_eRuntimeError, "Quickjs::VM was disposed");
    return Qnil;
  }
  char *code = StringValueCStr(r_code);
  JSValue codeResult = JS_Eval(data->context, code, strlen(code), "<code>", JS_EVAL_TYPE_GLOBAL);
  VALUE result = to_rb_value(codeResult, data->context);

  JS_FreeValue(data->context, codeResult);
  return result;
}

VALUE qvm_m_dispose(VALUE self)
{
  struct qvmdata *data;
  TypedData_Get_Struct(self, struct qvmdata, &qvm_type, data);

  JSRuntime *runtime = JS_GetRuntime(data->context);
  js_std_free_handlers(runtime);
  JS_FreeContext(data->context);
  JS_FreeRuntime(runtime);
  data->alive = 0;

  return Qnil;
}

RUBY_FUNC_EXPORTED void
Init_quickjsrb(void)
{
  rb_mQuickjs = rb_define_module("Quickjs");
  rb_define_const(rb_mQuickjs, "MODULE_STD", ID2SYM(rb_intern(featureStdId)));
  rb_define_const(rb_mQuickjs, "MODULE_OS", ID2SYM(rb_intern(featureOsId)));

  VALUE valueClass = rb_define_class_under(rb_mQuickjs, "Value", rb_cObject);
  rb_define_const(valueClass, "UNDEFINED", ID2SYM(rb_intern(undefinedId)));
  rb_define_const(valueClass, "NAN", ID2SYM(rb_intern(nanId)));

  VALUE vmClass = rb_define_class_under(rb_mQuickjs, "VM", rb_cObject);
  rb_define_alloc_func(vmClass, qvm_alloc);
  rb_define_method(vmClass, "initialize", qvm_m_initialize, -1);
  rb_define_method(vmClass, "eval_code", qvm_m_evalCode, 1);
  rb_define_method(vmClass, "dispose!", qvm_m_dispose, 0);
}
