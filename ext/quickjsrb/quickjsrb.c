#include "quickjsrb.h"

VALUE rb_mQuickjs;
VALUE rb_mQuickjsValue;
const char *undefinedId = "undefined";
const char *nanId = "NaN";

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
  JSValue res = JS_Eval(ctx, code, strlen(code), "<code>", JS_EVAL_TYPE_GLOBAL);

  VALUE result;
  int r = 0;
  if (JS_IsException(res)) {
    rb_raise(rb_eRuntimeError, "Something happened by evaluating as JavaScript code");
    result = Qnil;
  } else if (JS_IsObject(res)) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue jsonClass = JS_GetPropertyStr(ctx, global, "JSON");
    JSValue stringifyFunc = JS_GetPropertyStr(ctx, jsonClass, "stringify");
    JSValue strigified = JS_Call(ctx, stringifyFunc, jsonClass, 1, &res);

    const char *msg = JS_ToCString(ctx, strigified);
    VALUE rbString = rb_str_new2(msg);
    VALUE rb_cJson = rb_const_get(rb_cClass, rb_intern("JSON"));
    result = rb_funcall(rb_cJson, rb_intern("parse"), 1, rbString);

    JS_FreeValue(ctx, global);
    JS_FreeValue(ctx, strigified);
    JS_FreeValue(ctx, stringifyFunc);
    JS_FreeValue(ctx, jsonClass);
  } else if (JS_VALUE_IS_NAN(res)) {
    result = ID2SYM(rb_intern(nanId));
  } else if (JS_IsNumber(res)) {
    JS_ToInt32(ctx, &r, res);
    result = INT2NUM(r);
  } else if (JS_IsString(res)) {
    JSValue maybeString = JS_ToString(ctx, res);
    const char *msg = JS_ToCString(ctx, maybeString);
    result = rb_str_new2(msg);
  } else if (JS_IsBool(res)) {
    result = JS_ToBool(ctx, res) > 0 ? Qtrue : Qfalse;
  } else if (JS_IsUndefined(res)) {
    result = ID2SYM(rb_intern(undefinedId));
  } else if (JS_IsNull(res)) {
    result = Qnil;
  } else {
    result = Qnil;
  }
  JS_FreeValue(ctx, res);

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
