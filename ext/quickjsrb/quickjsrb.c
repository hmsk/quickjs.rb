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

VALUE rb_mQuickjs, rb_cLog;
VALUE rb_cQuickjsSyntaxError, rb_cQuickjsRuntimeError, rb_cQuickjsInterruptedError, rb_cQuickjsNoAwaitError, rb_cQuickjsTypeError, rb_cQuickjsReferenceError, rb_cQuickjsRangeError, rb_cQuickjsEvalError, rb_cQuickjsURIError, rb_cQuickjsAggregateError;
const char *undefinedId = "undefined";
const char *nanId = "NaN";

const char *featureStdId = "feature_std";
const char *featureOsId = "feature_os";
const char *featureOsTimeoutId = "feature_os_timeout";

JSValue to_js_value(JSContext *ctx, VALUE r_value)
{
  if (RTEST(rb_funcall(
          r_value,
          rb_intern("is_a?"),
          1, rb_const_get(rb_cClass, rb_intern("Exception")))))
  {
    JSValue j_error = JS_NewError(ctx);
    VALUE r_str = rb_funcall(r_value, rb_intern("message"), 0, NULL);
    char *exceptionMessage = StringValueCStr(r_str);
    VALUE r_exception_name = rb_funcall(rb_funcall(r_value, rb_intern("class"), 0, NULL), rb_intern("name"), 0, NULL);
    char *exceptionName = StringValueCStr(r_exception_name);
    JS_SetPropertyStr(ctx, j_error, "name", JS_NewString(ctx, exceptionName));
    JS_SetPropertyStr(ctx, j_error, "message", JS_NewString(ctx, exceptionMessage));
    return JS_Throw(ctx, j_error);
  }

  switch (TYPE(r_value))
  {
  case T_NIL:
    return JS_NULL;
  case T_FIXNUM:
  case T_FLOAT:
  {
    VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0, NULL);
    char *str = StringValueCStr(r_str);
    JSValue j_global = JS_GetGlobalObject(ctx);
    JSValue j_numberClass = JS_GetPropertyStr(ctx, j_global, "Number");
    JSValue j_str = JS_NewString(ctx, str);
    JSValue j_stringified = JS_Call(ctx, j_numberClass, JS_UNDEFINED, 1, &j_str);
    JS_FreeValue(ctx, j_global);
    JS_FreeValue(ctx, j_numberClass);
    JS_FreeValue(ctx, j_str);

    return j_stringified;
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
    JSValue j_global = JS_GetGlobalObject(ctx);
    JSValue j_jsonClass = JS_GetPropertyStr(ctx, j_global, "JSON");
    JSValue j_parseFunc = JS_GetPropertyStr(ctx, j_jsonClass, "parse");
    JSValue j_str = JS_NewString(ctx, str);
    JSValue j_stringified = JS_Call(ctx, j_parseFunc, j_jsonClass, 1, &j_str);
    JS_FreeValue(ctx, j_global);
    JS_FreeValue(ctx, j_jsonClass);
    JS_FreeValue(ctx, j_parseFunc);
    JS_FreeValue(ctx, j_str);

    return j_stringified;
  }
  default:
  {
    VALUE r_inspect_str = rb_funcall(r_value, rb_intern("inspect"), 0, NULL);
    char *str = StringValueCStr(r_inspect_str);

    return JS_NewString(ctx, str);
  }
  }
}

VALUE to_rb_value(JSContext *ctx, JSValue j_val)
{
  switch (JS_VALUE_GET_NORM_TAG(j_val))
  {
  case JS_TAG_INT:
  {
    int int_res = 0;
    JS_ToInt32(ctx, &int_res, j_val);
    return INT2NUM(int_res);
  }
  case JS_TAG_FLOAT64:
  {
    if (JS_VALUE_IS_NAN(j_val))
    {
      return ID2SYM(rb_intern(nanId));
    }
    double double_res;
    JS_ToFloat64(ctx, &double_res, j_val);
    return DBL2NUM(double_res);
  }
  case JS_TAG_BOOL:
  {
    return JS_ToBool(ctx, j_val) > 0 ? Qtrue : Qfalse;
  }
  case JS_TAG_STRING:
  {
    const char *msg = JS_ToCString(ctx, j_val);
    VALUE r_str = rb_str_new2(msg);
    JS_FreeCString(ctx, msg);
    return r_str;
  }
  case JS_TAG_OBJECT:
  {
    int promiseState = JS_PromiseState(ctx, j_val);
    if (promiseState != -1)
    {
      VALUE r_error_message = rb_str_new2("cannot translate a Promise to Ruby. await within JavaScript's end");
      rb_exc_raise(rb_exc_new_str(rb_eRuntimeError, r_error_message));
      return Qnil;
    }

    JSValue j_global = JS_GetGlobalObject(ctx);
    JSValue j_jsonClass = JS_GetPropertyStr(ctx, j_global, "JSON");
    JSValue j_stringifyFunc = JS_GetPropertyStr(ctx, j_jsonClass, "stringify");
    JSValue j_strigified = JS_Call(ctx, j_stringifyFunc, j_jsonClass, 1, &j_val);

    const char *msg = JS_ToCString(ctx, j_strigified);
    VALUE r_str = rb_str_new2(msg);
    JS_FreeCString(ctx, msg);

    JS_FreeValue(ctx, j_global);
    JS_FreeValue(ctx, j_strigified);
    JS_FreeValue(ctx, j_stringifyFunc);
    JS_FreeValue(ctx, j_jsonClass);

    return rb_funcall(rb_const_get(rb_cClass, rb_intern("JSON")), rb_intern("parse"), 1, r_str);
  }
  case JS_TAG_NULL:
    return Qnil;
  case JS_TAG_UNDEFINED:
    return ID2SYM(rb_intern(undefinedId));
  case JS_TAG_EXCEPTION:
  {
    JSValue j_exceptionVal = JS_GetException(ctx);
    if (JS_IsError(ctx, j_exceptionVal))
    {
      JSValue j_errorClassName = JS_GetPropertyStr(ctx, j_exceptionVal, "name");
      const char *errorClassName = JS_ToCString(ctx, j_errorClassName);

      JSValue j_errorClassMessage = JS_GetPropertyStr(ctx, j_exceptionVal, "message");
      const char *errorClassMessage = JS_ToCString(ctx, j_errorClassMessage);

      JS_FreeValue(ctx, j_errorClassMessage);
      JS_FreeValue(ctx, j_errorClassName);

      VALUE r_error_message = rb_sprintf("%s: %s", errorClassName, errorClassMessage);
      VALUE r_error_class = rb_eRuntimeError;

      if (strcmp(errorClassName, "SyntaxError") == 0)
      {
        r_error_class = rb_cQuickjsSyntaxError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      else if (strcmp(errorClassName, "TypeError") == 0)
      {
        r_error_class = rb_cQuickjsTypeError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      else if (strcmp(errorClassName, "ReferenceError") == 0)
      {
        r_error_class = rb_cQuickjsReferenceError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      else if (strcmp(errorClassName, "RangeError") == 0)
      {
        r_error_class = rb_cQuickjsRangeError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      else if (strcmp(errorClassName, "EvalError") == 0)
      {
        r_error_class = rb_cQuickjsEvalError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      else if (strcmp(errorClassName, "URIError") == 0)
      {
        r_error_class = rb_cQuickjsURIError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      else if (strcmp(errorClassName, "AggregateError") == 0)
      {
        r_error_class = rb_cQuickjsAggregateError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      else if (strcmp(errorClassName, "InternalError") == 0 && strstr(errorClassMessage, "interrupted") != NULL)
      {
        r_error_class = rb_cQuickjsInterruptedError;
        r_error_message = rb_str_new2("Code evaluation is interrupted by the timeout or something");
      }
      else if (strcmp(errorClassName, "Quickjs::InterruptedError") == 0)
      {
        r_error_class = rb_cQuickjsInterruptedError;
        r_error_message = rb_str_new2(errorClassMessage);
      }
      JS_FreeCString(ctx, errorClassName);
      JS_FreeCString(ctx, errorClassMessage);
      JS_FreeValue(ctx, j_exceptionVal);

      rb_exc_raise(rb_exc_new_str(r_error_class, r_error_message));
    }
    else // exception without Error object
    {
      const char *errorMessage = JS_ToCString(ctx, j_exceptionVal);
      VALUE r_error_message = rb_sprintf("%s", errorMessage);

      JS_FreeCString(ctx, errorMessage);
      JS_FreeValue(ctx, j_exceptionVal);
      rb_exc_raise(rb_exc_new_str(rb_cQuickjsRuntimeError, r_error_message));
    }
    return Qnil;
  }
  case JS_TAG_BIG_INT:
  {
    JSValue j_toStringFunc = JS_GetPropertyStr(ctx, j_val, "toString");
    JSValue j_strigified = JS_Call(ctx, j_toStringFunc, j_val, 0, NULL);

    const char *msg = JS_ToCString(ctx, j_strigified);
    VALUE r_str = rb_str_new2(msg);
    JS_FreeValue(ctx, j_toStringFunc);
    JS_FreeValue(ctx, j_strigified);
    JS_FreeCString(ctx, msg);

    return rb_funcall(r_str, rb_intern("to_i"), 0, NULL);
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
  JSValue j_maybeFuncName = JS_ToString(ctx, argv[0]);
  const char *funcName = JS_ToCString(ctx, j_maybeFuncName);
  JS_FreeValue(ctx, j_maybeFuncName);

  VALUE r_proc = rb_hash_aref(data->defined_functions, rb_str_new2(funcName));
  if (r_proc == Qnil)
  { // Shouldn't happen
    return JS_ThrowReferenceError(ctx, "Proc `%s` is not defined", funcName);
  }
  JS_FreeCString(ctx, funcName);

  VALUE r_result = rb_funcall(
      rb_const_get(rb_cClass, rb_intern("Quickjs")),
      rb_intern("_with_timeout"),
      3,
      ULONG2NUM(data->eval_time->limit * 1000 / CLOCKS_PER_SEC),
      r_proc,
      to_rb_value(ctx, argv[1]));

  return to_js_value(ctx, r_result);
}

static JSValue js_quickjsrb_log(JSContext *ctx, JSValueConst _this, int _argc, JSValueConst *argv)
{
  VMData *data = JS_GetContextOpaque(ctx);
  JSValue j_severity = JS_ToString(ctx, argv[0]);
  const char *severity = JS_ToCString(ctx, j_severity);
  JS_FreeValue(ctx, j_severity);

  VALUE r_log = rb_funcall(rb_cLog, rb_intern("new"), 0);
  rb_iv_set(r_log, "@severity", ID2SYM(rb_intern(severity)));

  VALUE r_row = rb_ary_new();
  int i;
  JSValue j_length = JS_GetPropertyStr(ctx, argv[1], "length");
  int count;
  JS_ToInt32(ctx, &count, j_length);
  JS_FreeValue(ctx, j_length);
  for (i = 0; i < count; i++)
  {
    JSValue j_logged = JS_GetPropertyUint32(ctx, argv[1], i);
    const char *body = JS_ToCString(ctx, j_logged);
    VALUE r_loghash = rb_hash_new();
    rb_hash_aset(r_loghash, ID2SYM(rb_intern("c")), rb_str_new2(body));
    rb_ary_push(r_row, r_loghash);
    JS_FreeValue(ctx, j_logged);
    JS_FreeCString(ctx, body);
  }

  rb_iv_set(r_log, "@row", r_row);
  rb_ary_push(data->logs, r_log);
  JS_FreeCString(ctx, severity);

  return JS_UNDEFINED;
}

static VALUE vm_m_initialize(int argc, VALUE *argv, VALUE r_self)
{
  VALUE r_opts;
  rb_scan_args(argc, argv, ":", &r_opts);
  if (NIL_P(r_opts))
    r_opts = rb_hash_new();

  VALUE r_memory_limit = rb_hash_aref(r_opts, ID2SYM(rb_intern("memory_limit")));
  if (NIL_P(r_memory_limit))
    r_memory_limit = UINT2NUM(1024 * 1024 * 128);
  VALUE r_max_stack_size = rb_hash_aref(r_opts, ID2SYM(rb_intern("max_stack_size")));
  if (NIL_P(r_max_stack_size))
    r_max_stack_size = UINT2NUM(1024 * 1024 * 4);
  VALUE r_features = rb_hash_aref(r_opts, ID2SYM(rb_intern("features")));
  if (NIL_P(r_features))
    r_features = rb_ary_new();
  VALUE r_timeout_msec = rb_hash_aref(r_opts, ID2SYM(rb_intern("timeout_msec")));
  if (NIL_P(r_timeout_msec))
    r_timeout_msec = UINT2NUM(100);

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  data->eval_time->limit = (clock_t)(CLOCKS_PER_SEC * NUM2UINT(r_timeout_msec) / 1000);
  JS_SetContextOpaque(data->context, data);
  JSRuntime *runtime = JS_GetRuntime(data->context);

  JS_SetMemoryLimit(runtime, NUM2UINT(r_memory_limit));
  JS_SetMaxStackSize(runtime, NUM2UINT(r_max_stack_size));

  JS_AddIntrinsicBigFloat(data->context);
  JS_AddIntrinsicBigDecimal(data->context);
  JS_AddIntrinsicOperators(data->context);
  JS_EnableBignumExt(data->context, TRUE);

  JS_SetModuleLoaderFunc(runtime, NULL, js_module_loader, NULL);
  js_std_init_handlers(runtime);

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, ID2SYM(rb_intern(featureStdId)))))
  {
    js_init_module_std(data->context, "std");
    const char *enableStd = "import * as std from 'std';\n"
                            "globalThis.std = std;\n";
    JSValue j_stdEval = JS_Eval(data->context, enableStd, strlen(enableStd), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, j_stdEval);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, ID2SYM(rb_intern(featureOsId)))))
  {
    js_init_module_os(data->context, "os");
    const char *enableOs = "import * as os from 'os';\n"
                           "globalThis.os = os;\n";
    JSValue j_osEval = JS_Eval(data->context, enableOs, strlen(enableOs), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, j_osEval);
  }
  else if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, ID2SYM(rb_intern(featureOsTimeoutId)))))
  {
    js_init_module_os(data->context, "_os"); // Better if this is limited just only for setTimeout and clearTimeout
    const char *enableTimeout = "import * as _os from '_os';\n"
                                "globalThis.setTimeout = _os.setTimeout;\n"
                                "globalThis.clearTimeout = _os.clearTimeout;\n";
    JSValue j_timeoutEval = JS_Eval(data->context, enableTimeout, strlen(enableTimeout), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, j_timeoutEval);
  }

  JSValue j_global = JS_GetGlobalObject(data->context);
  JSValue j_quickjsrbGlobal = JS_NewObject(data->context);
  JS_SetPropertyStr(
      data->context, j_quickjsrbGlobal, "runRubyMethod",
      JS_NewCFunction(data->context, js_quickjsrb_call_global, "runRubyMethod", 2));

  JS_SetPropertyStr(data->context, j_global, "__quickjsrb", j_quickjsrbGlobal);

  JSValue j_console = JS_NewObject(data->context);
  JS_SetPropertyStr(
      data->context, j_quickjsrbGlobal, "log",
      JS_NewCFunction(data->context, js_quickjsrb_log, "log", 2));
  JS_SetPropertyStr(data->context, j_global, "console", j_console);
  JS_FreeValue(data->context, j_global);

  const char *defineLoggers = "console.log = (...args) => __quickjsrb.log('info', args);\n"
                              "console.debug = (...args) => __quickjsrb.log('verbose', args);\n"
                              "console.info = (...args) => __quickjsrb.log('info', args);\n"
                              "console.warn = (...args) => __quickjsrb.log('warning', args);\n"
                              "console.error = (...args) => __quickjsrb.log('error', args);\n";
  JSValue j_defineLoggers = JS_Eval(data->context, defineLoggers, strlen(defineLoggers), "<vm>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(data->context, j_defineLoggers);

  return r_self;
}

static int interrupt_handler(JSRuntime *runtime, void *opaque)
{
  EvalTime *eval_time = opaque;
  return clock() >= eval_time->started_at + eval_time->limit ? 1 : 0;
}

static VALUE vm_m_evalCode(VALUE r_self, VALUE r_code)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  data->eval_time->started_at = clock();
  JS_SetInterruptHandler(JS_GetRuntime(data->context), interrupt_handler, data->eval_time);

  char *code = StringValueCStr(r_code);
  JSValue j_codeResult = JS_Eval(data->context, code, strlen(code), "<code>", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC);
  JSValue j_awaitedResult = js_std_await(data->context, j_codeResult);
  JSValue j_returnedValue = JS_GetPropertyStr(data->context, j_awaitedResult, "value");
  // Do this by rescuing to_rb_value
  if (JS_VALUE_GET_NORM_TAG(j_returnedValue) == JS_TAG_OBJECT && JS_PromiseState(data->context, j_returnedValue) != -1)
  {
    JS_FreeValue(data->context, j_returnedValue);
    JS_FreeValue(data->context, j_awaitedResult);
    VALUE r_error_message = rb_str_new2("An unawaited Promise was returned to the top-level");
    rb_exc_raise(rb_exc_new_str(rb_cQuickjsNoAwaitError, r_error_message));
    return Qnil;
  }
  else
  {
    VALUE result = to_rb_value(data->context, j_returnedValue);
    JS_FreeValue(data->context, j_returnedValue);
    JS_FreeValue(data->context, j_awaitedResult);
    return result;
  }
}

static VALUE vm_m_defineGlobalFunction(VALUE r_self, VALUE r_name)
{
  rb_need_block();

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  if (rb_block_given_p())
  {
    VALUE r_proc = rb_block_proc();
    rb_hash_aset(data->defined_functions, r_name, r_proc);
    char *funcName = StringValueCStr(r_name);

    const char *template = "globalThis['%s'] = (...args) => __quickjsrb.runRubyMethod('%s', args);\n";
    int length = snprintf(NULL, 0, template, funcName, funcName);
    char *result = (char *)malloc(length + 1);
    snprintf(result, length + 1, template, funcName, funcName);

    JSValue j_codeResult = JS_Eval(data->context, result, strlen(result), "<vm>", JS_EVAL_TYPE_MODULE);

    free(result);
    JS_FreeValue(data->context, j_codeResult);
    return rb_funcall(r_name, rb_intern("to_sym"), 0, NULL);
  }

  return Qnil;
}

static VALUE vm_m_getLogs(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  return data->logs;
}

static VALUE pick_c(VALUE block_arg, VALUE data, int argc, const VALUE *argv, VALUE blockarg)
{
  return rb_hash_aref(block_arg, ID2SYM(rb_intern("c")));
}

static VALUE vm_m_to_s(VALUE r_self)
{
  VALUE row = rb_iv_get(r_self, "@row");
  VALUE r_ary = rb_block_call(row, rb_intern("map"), 0, NULL, pick_c, Qnil);

  return rb_funcall(r_ary, rb_intern("join"), 1, rb_str_new2(" "));
}

RUBY_FUNC_EXPORTED void
Init_quickjsrb(void)
{
  rb_mQuickjs = rb_define_module("Quickjs");
  rb_define_const(rb_mQuickjs, "MODULE_STD", ID2SYM(rb_intern(featureStdId)));
  rb_define_const(rb_mQuickjs, "MODULE_OS", ID2SYM(rb_intern(featureOsId)));
  rb_define_const(rb_mQuickjs, "FEATURES_TIMEOUT", ID2SYM(rb_intern(featureOsTimeoutId)));

  VALUE valueClass = rb_define_class_under(rb_mQuickjs, "Value", rb_cObject);
  rb_define_const(valueClass, "UNDEFINED", ID2SYM(rb_intern(undefinedId)));
  rb_define_const(valueClass, "NAN", ID2SYM(rb_intern(nanId)));

  VALUE vmClass = rb_define_class_under(rb_mQuickjs, "VM", rb_cObject);
  rb_define_alloc_func(vmClass, vm_alloc);
  rb_define_method(vmClass, "initialize", vm_m_initialize, -1);
  rb_define_method(vmClass, "eval_code", vm_m_evalCode, 1);
  rb_define_method(vmClass, "define_function", vm_m_defineGlobalFunction, 1);
  rb_define_method(vmClass, "logs", vm_m_getLogs, 0);

  rb_cLog = rb_define_class_under(vmClass, "Log", rb_cObject);
  rb_define_attr(rb_cLog, "severity", 1, 0);
  rb_define_method(rb_cLog, "to_s", vm_m_to_s, 0);
  rb_define_method(rb_cLog, "inspect", vm_m_to_s, 0);

  rb_cQuickjsRuntimeError = rb_define_class_under(rb_mQuickjs, "RuntimeError", rb_eRuntimeError);

  rb_cQuickjsSyntaxError = rb_define_class_under(rb_mQuickjs, "SyntaxError", rb_cQuickjsRuntimeError);
  rb_cQuickjsTypeError = rb_define_class_under(rb_mQuickjs, "TypeError", rb_cQuickjsRuntimeError);
  rb_cQuickjsRangeError = rb_define_class_under(rb_mQuickjs, "RangeError", rb_cQuickjsRuntimeError);
  rb_cQuickjsReferenceError = rb_define_class_under(rb_mQuickjs, "ReferenceError", rb_cQuickjsRuntimeError);
  rb_cQuickjsURIError = rb_define_class_under(rb_mQuickjs, "URIError", rb_cQuickjsRuntimeError);
  rb_cQuickjsEvalError = rb_define_class_under(rb_mQuickjs, "EvalError", rb_cQuickjsRuntimeError);
  rb_cQuickjsAggregateError = rb_define_class_under(rb_mQuickjs, "AggregateError", rb_cQuickjsRuntimeError);

  rb_cQuickjsInterruptedError = rb_define_class_under(rb_mQuickjs, "InterruptedError", rb_cQuickjsRuntimeError);
  rb_cQuickjsNoAwaitError = rb_define_class_under(rb_mQuickjs, "NoAwaitError", rb_cQuickjsRuntimeError);
}
