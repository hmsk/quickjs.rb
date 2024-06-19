#include "quickjsrb.h"

VALUE rb_mQuickjs;
VALUE rb_mQuickjsValue;
const char *undefinedId = "undefined";
const char *nanId = "NaN";

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

VALUE rb_module_eval_js_code(
  VALUE klass,
  VALUE r_code,
  VALUE r_memoryLimit,
  VALUE r_maxStackSize,
  VALUE r_enableStd,
  VALUE r_enableOs
) {
  JSRuntime *rt = JS_NewRuntime();
  JSContext *ctx = JS_NewContext(rt);

  JS_SetMemoryLimit(rt, NUM2UINT(r_memoryLimit));
  JS_SetMaxStackSize(rt, NUM2UINT(r_maxStackSize));

  JS_AddIntrinsicBigFloat(ctx);
  JS_AddIntrinsicBigDecimal(ctx);
  JS_AddIntrinsicOperators(ctx);
  JS_EnableBignumExt(ctx, TRUE);

  JS_SetModuleLoaderFunc(rt, NULL, js_module_loader, NULL);
  js_std_add_helpers(ctx, 0, NULL);

  js_std_init_handlers(rt);
  if (r_enableStd == Qtrue) {
    js_init_module_std(ctx, "std");
    const char *enableStd = "import * as std from 'std';\n"
        "globalThis.std = std;\n";
    JSValue stdEval = JS_Eval(ctx, enableStd, strlen(enableStd), "<code>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(ctx, stdEval);
  }

  if (r_enableOs == Qtrue) {
    js_init_module_os(ctx, "os");

    const char *enableOs = "import * as os from 'os';\n"
        "globalThis.os = os;\n";
    JSValue osEval = JS_Eval(ctx, enableOs, strlen(enableOs), "<code>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(ctx, osEval);
  }

  char *code = StringValueCStr(r_code);
  JSValue codeResult = JS_Eval(ctx, code, strlen(code), "<code>", JS_EVAL_TYPE_GLOBAL);
  VALUE result = to_rb_value(codeResult, ctx);

  JS_FreeValue(ctx, codeResult);
  js_std_free_handlers(rt);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);

  return result;
}

RUBY_FUNC_EXPORTED void
Init_quickjsrb(void)
{
  rb_mQuickjs = rb_define_module("Quickjs");
  rb_define_module_function(rb_mQuickjs, "_evalCode", rb_module_eval_js_code, 5);

  VALUE valueClass = rb_define_class_under(rb_mQuickjs, "Value", rb_cObject);
  rb_define_const(valueClass, "UNDEFINED", ID2SYM(rb_intern(undefinedId)));
  rb_define_const(valueClass, "NAN", ID2SYM(rb_intern(nanId)));
}
