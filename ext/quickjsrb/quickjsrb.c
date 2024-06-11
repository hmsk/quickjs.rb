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

  int r = 0;
  if (JS_IsException(res)) {
  } else {
    JS_ToInt32(ctx, &r, res);
  }
  JS_FreeValue(ctx, res);
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);

  return INT2NUM(r);
}

RUBY_FUNC_EXPORTED void
Init_quickjsrb(void)
{
  rb_mQuickjs = rb_define_module("Quickjs");
  rb_define_module_function(rb_mQuickjs, "evalCode", rb_module_eval_js_code, 1);
}
