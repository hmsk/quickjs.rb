#include "quickjsrb.h"

VALUE rb_mQuickjs;

VALUE rb_module_eval_js_code(VALUE klass, VALUE r_code)
{
  JSRuntime *rt = JS_NewRuntime();
  JSContext *ctx = JS_NewContext(rt);

  JS_SetMemoryLimit(rt, 0x4000000);
  JS_SetMaxStackSize(rt, 0x10000);
  JS_AddIntrinsicBigFloat(ctx);
  JS_AddIntrinsicBigDecimal(ctx);
  JS_AddIntrinsicOperators(ctx);
  JS_EnableBignumExt(ctx, 1);
  JS_SetModuleLoaderFunc(rt, NULL, js_module_loader, NULL);
  js_std_add_helpers(ctx, 0, NULL);

  js_std_init_handlers(rt);
  js_init_module_std(ctx, "std");
  js_init_module_os(ctx, "os");

  char *code = StringValueCStr(r_code);
  JSValue res = JS_Eval(ctx, code, strlen(code), "<code>", JS_EVAL_TYPE_GLOBAL);

  VALUE result;
  int r = 0;
  if (JS_IsException(res)) {
    rb_raise(rb_eRuntimeError, "Something happened by evaluating as JavaScript code");
    result = Qnil;
  } else if (JS_IsNumber(res)) {
    JS_ToInt32(ctx, &r, res);
    result = INT2NUM(r);
  } else if (JS_IsString(res)) {
    JSValue maybeString = JS_ToString(ctx, res);
    const char *msg = JS_ToCString(ctx, maybeString);
    result = rb_str_new2(msg);
  } else if (JS_IsBool(res)) {
    result = JS_ToBool(ctx, res) > 0 ? Qtrue : Qfalse;
  } else if (JS_IsNull(res) || JS_IsUndefined(res)) {
    result = Qnil;
  } else {
    result = Qnil;
  }
  JS_FreeValue(ctx, res);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);

  return result;
}

RUBY_FUNC_EXPORTED void
Init_quickjsrb(void)
{
  rb_mQuickjs = rb_define_module("Quickjs");
  rb_define_module_function(rb_mQuickjs, "evalCode", rb_module_eval_js_code, 1);
}
