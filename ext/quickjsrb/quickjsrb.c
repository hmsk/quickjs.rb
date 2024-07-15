#include "quickjsrb.h"

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

static VALUE vm_alloc(VALUE self)
{
  VMData *data;
  VALUE obj = TypedData_Make_Struct(self, VMData, &vm_type, data);
  data->defined_functions = rb_hash_new();

  EvalTime *eval_time = malloc(sizeof(EvalTime));
  data->eval_time = eval_time;

  JSRuntime *runtime = JS_NewRuntime();
  data->context = JS_NewContext(runtime);

  return obj;
}

VALUE rb_mQuickjs;
const char *undefinedId = "undefined";
const char *nanId = "NaN";

const char *featureStdId = "feature_std";
const char *featureOsId = "feature_os";

JSValue to_js_value(JSContext *ctx, VALUE r_value)
{
  switch (TYPE(r_value))
  {
  case T_NIL:
    return JS_NULL;
  case T_FIXNUM:
  case T_FLOAT:
  {
    VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0, NULL);
    char *str = StringValueCStr(r_str);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue numberClass = JS_GetPropertyStr(ctx, global, "Number");
    JSValue j_str = JS_NewString(ctx, str);
    JSValue stringified = JS_Call(ctx, numberClass, JS_UNDEFINED, 1, &j_str);
    JS_FreeValue(ctx, global);
    JS_FreeValue(ctx, numberClass);
    JS_FreeValue(ctx, j_str);

    return stringified;
  }
  case T_STRING:
  {
    char *str = StringValueCStr(r_value);

    return JS_NewString(ctx, str);
  }
  case T_SYMBOL:
  {
    VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0, NULL);
    char *str = StringValueCStr(r_str);

    return JS_NewString(ctx, str);
  }
  case T_TRUE:
    return JS_TRUE;
  case T_FALSE:
    return JS_FALSE;
  case T_HASH:
  case T_ARRAY:
  {
    VALUE r_json_str = rb_funcall(r_value, rb_intern("to_json"), 0, NULL);
    char *str = StringValueCStr(r_json_str);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue jsonClass = JS_GetPropertyStr(ctx, global, "JSON");
    JSValue parseFunc = JS_GetPropertyStr(ctx, jsonClass, "parse");
    JSValue j_str = JS_NewString(ctx, str);
    JSValue stringified = JS_Call(ctx, parseFunc, jsonClass, 1, &j_str);
    JS_FreeValue(ctx, global);
    JS_FreeValue(ctx, jsonClass);
    JS_FreeValue(ctx, parseFunc);
    JS_FreeValue(ctx, j_str);

    return stringified;
  }
  default:
  {
    VALUE r_inspect_str = rb_funcall(r_value, rb_intern("inspect"), 0, NULL);
    char *str = StringValueCStr(r_inspect_str);

    return JS_NewString(ctx, str);
  }
  }
}

VALUE to_rb_value(JSValue jsv, JSContext *ctx)
{
  switch (JS_VALUE_GET_NORM_TAG(jsv))
  {
  case JS_TAG_INT:
  {
    int int_res = 0;
    JS_ToInt32(ctx, &int_res, jsv);
    return INT2NUM(int_res);
  }
  case JS_TAG_FLOAT64:
  {
    if (JS_VALUE_IS_NAN(jsv))
    {
      return ID2SYM(rb_intern(nanId));
    }
    double double_res;
    JS_ToFloat64(ctx, &double_res, jsv);
    return DBL2NUM(double_res);
  }
  case JS_TAG_BOOL:
  {
    return JS_ToBool(ctx, jsv) > 0 ? Qtrue : Qfalse;
  }
  case JS_TAG_STRING:
  {
    JSValue maybeString = JS_ToString(ctx, jsv);
    const char *msg = JS_ToCString(ctx, maybeString);
    JS_FreeValue(ctx, maybeString);
    JS_FreeCString(ctx, msg);
    return rb_str_new2(msg);
  }
  case JS_TAG_OBJECT:
  {
    int promiseState = JS_PromiseState(ctx, jsv);
    if (promiseState == JS_PROMISE_FULFILLED || promiseState == JS_PROMISE_PENDING)
    {
      JSValue awaited = js_std_await(ctx, jsv);
      VALUE rb_awaited = to_rb_value(awaited, ctx); // TODO: should have timeout
      JS_FreeValue(ctx, awaited);
      return rb_awaited;
    }
    else if (promiseState == JS_PROMISE_REJECTED)
    {
      JSValue promiseResult = JS_PromiseResult(ctx, jsv);
      JSValue throw = JS_Throw(ctx, promiseResult);
      JS_FreeValue(ctx, promiseResult);
      VALUE rb_errored = to_rb_value(throw, ctx);
      JS_FreeValue(ctx, throw);
      return rb_errored;
    }

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue jsonClass = JS_GetPropertyStr(ctx, global, "JSON");
    JSValue stringifyFunc = JS_GetPropertyStr(ctx, jsonClass, "stringify");
    JSValue strigified = JS_Call(ctx, stringifyFunc, jsonClass, 1, &jsv);

    const char *msg = JS_ToCString(ctx, strigified);
    VALUE rbString = rb_str_new2(msg);
    JS_FreeCString(ctx, msg);

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
  {
    JSValue exceptionVal = JS_GetException(ctx);
    if (JS_IsError(ctx, exceptionVal))
    {
      JSValue jsErrorClassName = JS_GetPropertyStr(ctx, exceptionVal, "name");
      const char *errorClassName = JS_ToCString(ctx, jsErrorClassName);

      JSValue jsErrorClassMessage = JS_GetPropertyStr(ctx, exceptionVal, "message");
      const char *errorClassMessage = JS_ToCString(ctx, jsErrorClassMessage);

      JS_FreeValue(ctx, jsErrorClassMessage);
      JS_FreeValue(ctx, jsErrorClassName);

      VALUE rb_errorMessage = rb_sprintf("%s: %s", errorClassName, errorClassMessage);
      JS_FreeCString(ctx, errorClassName);
      JS_FreeCString(ctx, errorClassMessage);
      JS_FreeValue(ctx, exceptionVal);
      rb_exc_raise(rb_exc_new_str(rb_eRuntimeError, rb_errorMessage));
    }
    else
    {
      const char *errorMessage = JS_ToCString(ctx, exceptionVal);

      VALUE rb_errorMessage = rb_sprintf("%s", errorMessage);
      JS_FreeCString(ctx, errorMessage);
      JS_FreeValue(ctx, exceptionVal);
      rb_exc_raise(rb_exc_new_str(rb_eRuntimeError, rb_errorMessage));
    }
    return Qnil;
  }
  case JS_TAG_BIG_INT:
  {
    JSValue toStringFunc = JS_GetPropertyStr(ctx, jsv, "toString");
    JSValue strigified = JS_Call(ctx, toStringFunc, jsv, 0, NULL);

    const char *msg = JS_ToCString(ctx, strigified);
    VALUE rbString = rb_str_new2(msg);
    JS_FreeValue(ctx, toStringFunc);
    JS_FreeValue(ctx, strigified);
    JS_FreeCString(ctx, msg);

    return rb_funcall(rbString, rb_intern("to_i"), 0, NULL);
  }
  case JS_TAG_BIG_FLOAT:
  case JS_TAG_BIG_DECIMAL:
  case JS_TAG_SYMBOL:
  default:
    return Qnil;
  }
}

static JSValue js_quickjsrb_call_global(JSContext *ctx, JSValueConst _this, int _argc, JSValueConst *argv)
{
  VMData *data = JS_GetContextOpaque(ctx);
  JSValue maybeFuncName = JS_ToString(ctx, argv[0]);
  const char *funcName = JS_ToCString(ctx, maybeFuncName);
  JS_FreeValue(ctx, maybeFuncName);

  VALUE proc = rb_hash_aref(data->defined_functions, rb_str_new2(funcName));
  if (proc == Qnil)
  { // Shouldn't happen
    return JS_ThrowReferenceError(ctx, "Proc `%s` is not defined", funcName);
  }
  JS_FreeCString(ctx, funcName);

  // TODO: cover timeout for calling proc
  VALUE r_result = rb_apply(proc, rb_intern("call"), to_rb_value(argv[1], ctx));
  return to_js_value(ctx, r_result);
}

static VALUE vm_m_initialize(int argc, VALUE *argv, VALUE self)
{
  VALUE r_opts;
  rb_scan_args(argc, argv, ":", &r_opts);
  if (NIL_P(r_opts))
    r_opts = rb_hash_new();

  VALUE r_memoryLimit = rb_hash_aref(r_opts, ID2SYM(rb_intern("memory_limit")));
  if (NIL_P(r_memoryLimit))
    r_memoryLimit = UINT2NUM(1024 * 1024 * 128);
  VALUE r_maxStackSize = rb_hash_aref(r_opts, ID2SYM(rb_intern("max_stack_size")));
  if (NIL_P(r_maxStackSize))
    r_maxStackSize = UINT2NUM(1024 * 1024 * 4);
  VALUE r_features = rb_hash_aref(r_opts, ID2SYM(rb_intern("features")));
  if (NIL_P(r_features))
    r_features = rb_ary_new();
  VALUE r_timeout_msec = rb_hash_aref(r_opts, ID2SYM(rb_intern("timeout_msec")));
  if (NIL_P(r_timeout_msec))
    r_timeout_msec = UINT2NUM(100);

  VMData *data;
  TypedData_Get_Struct(self, VMData, &vm_type, data);

  data->eval_time->limit = (clock_t)(CLOCKS_PER_SEC * NUM2UINT(r_timeout_msec) / 1000);
  JS_SetContextOpaque(data->context, data);
  JSRuntime *runtime = JS_GetRuntime(data->context);

  JS_SetMemoryLimit(runtime, NUM2UINT(r_memoryLimit));
  JS_SetMaxStackSize(runtime, NUM2UINT(r_maxStackSize));

  JS_AddIntrinsicBigFloat(data->context);
  JS_AddIntrinsicBigDecimal(data->context);
  JS_AddIntrinsicOperators(data->context);
  JS_EnableBignumExt(data->context, TRUE);
  js_std_add_helpers(data->context, 0, NULL);

  JS_SetModuleLoaderFunc(runtime, NULL, js_module_loader, NULL);
  js_std_init_handlers(runtime);

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, ID2SYM(rb_intern(featureStdId)))))
  {
    js_init_module_std(data->context, "std");
    const char *enableStd = "import * as std from 'std';\n"
                            "globalThis.std = std;\n";
    JSValue stdEval = JS_Eval(data->context, enableStd, strlen(enableStd), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, stdEval);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, ID2SYM(rb_intern(featureOsId)))))
  {
    js_init_module_os(data->context, "os");
    const char *enableOs = "import * as os from 'os';\n"
                           "globalThis.os = os;\n";
    JSValue osEval = JS_Eval(data->context, enableOs, strlen(enableOs), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, osEval);
  }

  const char *setupGlobalRuby = "globalThis.__ruby = {};\n";
  JSValue rubyEval = JS_Eval(data->context, setupGlobalRuby, strlen(setupGlobalRuby), "<vm>", JS_EVAL_TYPE_MODULE);
  JS_FreeValue(data->context, rubyEval);

  JSValue global = JS_GetGlobalObject(data->context);
  JSValue func = JS_NewCFunction(data->context, js_quickjsrb_call_global, "rubyGlobal", 2);
  JS_SetPropertyStr(data->context, global, "rubyGlobal", func);
  JS_FreeValue(data->context, global);

  return self;
}

static int interrupt_handler(JSRuntime *runtime, void *opaque)
{
  EvalTime *eval_time = opaque;
  return clock() >= eval_time->started_at + eval_time->limit ? 1 : 0;
}

static VALUE vm_m_evalCode(VALUE self, VALUE r_code)
{
  VMData *data;
  TypedData_Get_Struct(self, VMData, &vm_type, data);

  data->eval_time->started_at = clock();
  JS_SetInterruptHandler(JS_GetRuntime(data->context), interrupt_handler, data->eval_time);

  char *code = StringValueCStr(r_code);
  JSValue codeResult = JS_Eval(data->context, code, strlen(code), "<code>", JS_EVAL_TYPE_GLOBAL);
  VALUE result = to_rb_value(codeResult, data->context);

  JS_FreeValue(data->context, codeResult);
  return result;
}

static VALUE vm_m_defineGlobalFunction(VALUE self, VALUE r_name)
{
  rb_need_block();

  VMData *data;
  TypedData_Get_Struct(self, VMData, &vm_type, data);

  if (rb_block_given_p())
  {
    VALUE proc = rb_block_proc();

    char *funcName = StringValueCStr(r_name);

    rb_hash_aset(data->defined_functions, r_name, proc);

    const char *template = "globalThis.__ruby['%s'] = (...args) => rubyGlobal('%s', args);\nglobalThis['%s'] = globalThis.__ruby['%s'];\n";
    int length = snprintf(NULL, 0, template, funcName, funcName, funcName, funcName);
    char *result = (char *)malloc(length + 1);
    snprintf(result, length + 1, template, funcName, funcName, funcName, funcName);

    JSValue codeResult = JS_Eval(data->context, result, strlen(result), "<vm>", JS_EVAL_TYPE_MODULE);

    free(result);
    JS_FreeValue(data->context, codeResult);
    return rb_funcall(r_name, rb_intern("to_sym"), 0, NULL);
  }

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
  rb_define_alloc_func(vmClass, vm_alloc);
  rb_define_method(vmClass, "initialize", vm_m_initialize, -1);
  rb_define_method(vmClass, "eval_code", vm_m_evalCode, 1);
  rb_define_method(vmClass, "define_function", vm_m_defineGlobalFunction, 1);
}
