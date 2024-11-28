#include "quickjsrb.h"

JSValue j_error_from_ruby_error(JSContext *ctx, VALUE r_error)
{
  JSValue j_error = JS_NewError(ctx); // may wanna have custom error class to determine in JS' end

  VALUE r_object_id = rb_funcall(r_error, rb_intern("object_id"), 0, NULL);
  int objectId = NUM2INT(r_object_id);
  JS_SetPropertyStr(ctx, j_error, "rb_object_id", JS_NewInt32(ctx, objectId));

  VALUE r_exception_message = rb_funcall(r_error, rb_intern("message"), 0, NULL);
  const char *errorMessage = StringValueCStr(r_exception_message);
  JS_SetPropertyStr(ctx, j_error, "message", JS_NewString(ctx, errorMessage));

  return j_error;
}

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
    if (TYPE(r_value) == T_OBJECT && RTEST(rb_funcall(
                                         r_value,
                                         rb_intern("is_a?"),
                                         1, rb_const_get(rb_cClass, rb_intern("Exception")))))
    {
      return j_error_from_ruby_error(ctx, r_value);
    }
    VALUE r_inspect_str = rb_funcall(r_value, rb_intern("inspect"), 0, NULL);
    char *str = StringValueCStr(r_inspect_str);

    return JS_NewString(ctx, str);
  }
  }
}

VALUE find_ruby_error(JSContext *ctx, JSValue j_error)
{
  JSValue j_errorOriginalRubyObjectId = JS_GetPropertyStr(ctx, j_error, "rb_object_id");
  int errorOriginalRubyObjectId = 0;
  if (JS_VALUE_GET_NORM_TAG(j_errorOriginalRubyObjectId) == JS_TAG_INT)
  {
    JS_ToInt32(ctx, &errorOriginalRubyObjectId, j_errorOriginalRubyObjectId);
    JS_FreeValue(ctx, j_errorOriginalRubyObjectId);
    if (errorOriginalRubyObjectId > 0)
    {
      // may be nice if cover the case of object is missing
      return rb_funcall(rb_const_get(rb_cClass, rb_intern("ObjectSpace")), rb_intern("_id2ref"), 1, INT2NUM(errorOriginalRubyObjectId));
    }
  }
  return Qnil;
}

VALUE r_try_json_parse(VALUE r_str)
{
  return rb_funcall(rb_const_get(rb_cClass, rb_intern("JSON")), rb_intern("parse"), 1, r_str);
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
      return QUICKJSRB_SYM(nanId);
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
      rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
      return Qnil;
    }

    if (JS_IsError(ctx, j_val))
    {
      VALUE r_maybe_ruby_error = find_ruby_error(ctx, j_val);
      if (!NIL_P(r_maybe_ruby_error))
      {
        return r_maybe_ruby_error;
      }
      // will support other errors like just returning an instance of Error
    }

    JSValue j_global = JS_GetGlobalObject(ctx);
    JSValue j_jsonClass = JS_GetPropertyStr(ctx, j_global, "JSON");
    JSValue j_stringifyFunc = JS_GetPropertyStr(ctx, j_jsonClass, "stringify");
    JSValue j_strigified = JS_Call(ctx, j_stringifyFunc, j_jsonClass, 1, &j_val);

    const char *msg = JS_ToCString(ctx, j_strigified);
    VALUE r_str = rb_str_new2(msg);
    JS_FreeCString(ctx, msg);

    JS_FreeValue(ctx, j_strigified);
    JS_FreeValue(ctx, j_stringifyFunc);
    JS_FreeValue(ctx, j_jsonClass);
    JS_FreeValue(ctx, j_global);

    if (rb_funcall(r_str, rb_intern("=="), 1, rb_str_new2("undefined")))
    {
      return QUICKJSRB_SYM(undefinedId);
    }

    int couldntParse;
    VALUE r_result = rb_protect(r_try_json_parse, r_str, &couldntParse);
    if (couldntParse)
    {
      return Qnil;
    }
    else
    {
      return r_result;
    }
  }
  case JS_TAG_NULL:
    return Qnil;
  case JS_TAG_UNDEFINED:
    return QUICKJSRB_SYM(undefinedId);
  case JS_TAG_EXCEPTION:
  {
    JSValue j_exceptionVal = JS_GetException(ctx);
    if (JS_IsError(ctx, j_exceptionVal))
    {
      VALUE r_maybe_ruby_error = find_ruby_error(ctx, j_exceptionVal);
      if (!NIL_P(r_maybe_ruby_error))
      {
        JS_FreeValue(ctx, j_exceptionVal);
        rb_exc_raise(r_maybe_ruby_error);
        return Qnil;
      }

      JSValue j_errorClassName = JS_GetPropertyStr(ctx, j_exceptionVal, "name");
      const char *errorClassName = JS_ToCString(ctx, j_errorClassName);

      JSValue j_errorClassMessage = JS_GetPropertyStr(ctx, j_exceptionVal, "message");
      const char *errorClassMessage = JS_ToCString(ctx, j_errorClassMessage);

      JSValue j_stackTrace = JS_GetPropertyStr(ctx, j_exceptionVal, "stack");
      const char *stackTrace = JS_ToCString(ctx, j_stackTrace);
      const char *headlineTemplate = "Uncaught %s: %s\n%s";
      int length = snprintf(NULL, 0, headlineTemplate, errorClassName, errorClassMessage, stackTrace);
      char *headline = (char *)malloc(length + 1);
      snprintf(headline, length + 1, headlineTemplate, errorClassName, errorClassMessage, stackTrace);

      VMData *data = JS_GetContextOpaque(ctx);
      VALUE r_headline = rb_str_new2(headline);
      rb_ary_push(data->logs, r_log_new("error", rb_ary_new3(1, r_log_body_new(r_headline, r_headline))));

      JS_FreeValue(ctx, j_errorClassMessage);
      JS_FreeValue(ctx, j_errorClassName);
      JS_FreeValue(ctx, j_stackTrace);
      JS_FreeCString(ctx, stackTrace);
      free(headline);

      VALUE r_error_class, r_error_message = rb_str_new2(errorClassMessage);
      if (is_native_error_name(errorClassName))
      {
        r_error_class = QUICKJSRB_ERROR_FOR(errorClassName);
      }
      else if (strcmp(errorClassName, "InternalError") == 0 && strstr(errorClassMessage, "interrupted") != NULL)
      {
        r_error_class = QUICKJSRB_ERROR_FOR(QUICKJSRB_INTERRUPTED_ERROR);
        r_error_message = rb_str_new2("Code evaluation is interrupted by the timeout or something");
      }
      else if (strcmp(errorClassName, "Quickjs::InterruptedError") == 0)
      {
        r_error_class = QUICKJSRB_ERROR_FOR(QUICKJSRB_INTERRUPTED_ERROR);
      }
      else
      {
        r_error_class = QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR);
      }
      JS_FreeCString(ctx, errorClassName);
      JS_FreeCString(ctx, errorClassMessage);
      JS_FreeValue(ctx, j_exceptionVal);

      rb_exc_raise(rb_funcall(r_error_class, rb_intern("new"), 2, r_error_message, rb_str_new2(errorClassName)));
    }
    else // exception without Error object
    {
      const char *errorMessage = JS_ToCString(ctx, j_exceptionVal);
      const char *headlineTemplate = "Uncaught '%s'";
      int length = snprintf(NULL, 0, headlineTemplate, errorMessage);
      char *headline = (char *)malloc(length + 1);
      snprintf(headline, length + 1, headlineTemplate, errorMessage);

      VMData *data = JS_GetContextOpaque(ctx);
      VALUE r_headline = rb_str_new2(headline);
      rb_ary_push(data->logs, r_log_new("error", rb_ary_new3(1, r_log_body_new(r_headline, r_headline))));

      free(headline);

      VALUE r_error_message = rb_sprintf("%s", errorMessage);
      JS_FreeCString(ctx, errorMessage);
      JS_FreeValue(ctx, j_exceptionVal);
      rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
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

static VALUE r_try_call_proc(VALUE r_try_args)
{
  return rb_funcall(
      rb_const_get(rb_cClass, rb_intern("Quickjs")),
      rb_intern("_with_timeout"),
      3,
      RARRAY_AREF(r_try_args, 2), // timeout
      RARRAY_AREF(r_try_args, 0), // proc
      RARRAY_AREF(r_try_args, 1)  // args for proc
  );
}

static JSValue js_quickjsrb_call_global(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv, int _magic, JSValue *func_data)
{
  const char *funcName = JS_ToCString(ctx, func_data[0]);

  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_proc = rb_hash_aref(data->defined_functions, rb_str_new2(funcName));
  if (r_proc == Qnil)
  {                                                                           // Shouldn't happen
    return JS_ThrowReferenceError(ctx, "Proc `%s` is not defined", funcName); // TODO: Free funcnName
  }
  JS_FreeCString(ctx, funcName);

  VALUE r_call_args = rb_ary_new();
  rb_ary_push(r_call_args, r_proc);

  VALUE r_argv = rb_ary_new();
  for (int i = 0; i < argc; i++)
  {
    rb_ary_push(r_argv, to_rb_value(ctx, argv[i]));
  }
  rb_ary_push(r_call_args, r_argv);
  rb_ary_push(r_call_args, ULONG2NUM(data->eval_time->limit * 1000 / CLOCKS_PER_SEC));

  int sadnessHappened;

  if (JS_ToBool(ctx, func_data[1]))
  {
    JSValue promise, resolving_funcs[2];
    JSValue ret_val;

    promise = JS_NewPromiseCapability(ctx, resolving_funcs);
    if (JS_IsException(promise))
      return JS_EXCEPTION;

    // Currently, it's blocking process but should be asynchronized
    JSValue j_result;
    VALUE r_result = rb_protect(r_try_call_proc, r_call_args, &sadnessHappened);
    if (sadnessHappened)
    {
      VALUE r_error = rb_errinfo();
      j_result = j_error_from_ruby_error(ctx, r_error);
      ret_val = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED,
                        1, (JSValueConst *)&j_result);
    }
    else
    {
      j_result = to_js_value(ctx, r_result);
      ret_val = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED,
                        1, (JSValueConst *)&j_result);
    }
    JS_FreeValue(ctx, j_result);
    JS_FreeValue(ctx, ret_val);
    JS_FreeValue(ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);
    return promise;
  }
  else
  {
    VALUE r_result = rb_protect(r_try_call_proc, r_call_args, &sadnessHappened);
    if (sadnessHappened)
    {
      VALUE r_error = rb_errinfo();
      JSValue j_error = j_error_from_ruby_error(ctx, r_error);
      return JS_Throw(ctx, j_error);
    }
    else
    {
      return to_js_value(ctx, r_result);
    }
  }
}

static JSValue js_quickjsrb_log(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv, const char *severity)
{
  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_row = rb_ary_new();
  for (int i = 0; i < argc; i++)
  {
    JSValue j_logged = argv[i];
    VALUE r_raw = JS_VALUE_GET_NORM_TAG(j_logged) == JS_TAG_OBJECT && JS_PromiseState(ctx, j_logged) != -1 ? rb_str_new2("Promise") : to_rb_value(ctx, j_logged);
    const char *body = JS_ToCString(ctx, j_logged);
    VALUE r_c = rb_str_new2(body);
    JS_FreeCString(ctx, body);

    rb_ary_push(r_row, r_log_body_new(r_raw, r_c));
  }

  rb_ary_push(data->logs, r_log_new(severity, r_row));
  return JS_UNDEFINED;
}

static JSValue js_console_info(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, this, argc, argv, "info");
}

static JSValue js_console_verbose(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, this, argc, argv, "verbose");
}

static JSValue js_console_warn(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, this, argc, argv, "warning");
}

static JSValue js_console_error(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, this, argc, argv, "error");
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

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featureStdId))))
  {
    js_init_module_std(data->context, "std");
    const char *enableStd = "import * as std from 'std';\n"
                            "globalThis.std = std;\n";
    JSValue j_stdEval = JS_Eval(data->context, enableStd, strlen(enableStd), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, j_stdEval);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featureOsId))))
  {
    js_init_module_os(data->context, "os");
    const char *enableOs = "import * as os from 'os';\n"
                           "globalThis.os = os;\n";
    JSValue j_osEval = JS_Eval(data->context, enableOs, strlen(enableOs), "<vm>", JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, j_osEval);
  }
  else if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featureOsTimeoutId))))
  {
    char *filename = random_string();
    js_init_module_os(data->context, filename); // Better if this is limited just only for setTimeout and clearTimeout
    const char *enableTimeoutTemplate = "import * as _os from '%s';\n"
                                        "globalThis.setTimeout = _os.setTimeout;\n"
                                        "globalThis.clearTimeout = _os.clearTimeout;\n";
    int length = snprintf(NULL, 0, enableTimeoutTemplate, filename);
    char *enableTimeout = (char *)malloc(length + 1);
    snprintf(enableTimeout, length + 1, enableTimeoutTemplate, filename);

    JSValue j_timeoutEval = JS_Eval(data->context, enableTimeout, strlen(enableTimeout), "<vm>", JS_EVAL_TYPE_MODULE);
    free(enableTimeout);
    JS_FreeValue(data->context, j_timeoutEval);
  }

  JSValue j_console = JS_NewObject(data->context);
  JS_SetPropertyStr(
      data->context, j_console, "log",
      JS_NewCFunction(data->context, js_console_info, "log", 1));
  JS_SetPropertyStr(
      data->context, j_console, "debug",
      JS_NewCFunction(data->context, js_console_verbose, "debug", 1));
  JS_SetPropertyStr(
      data->context, j_console, "info",
      JS_NewCFunction(data->context, js_console_info, "info", 1));
  JS_SetPropertyStr(
      data->context, j_console, "warn",
      JS_NewCFunction(data->context, js_console_warn, "warn", 1));
  JS_SetPropertyStr(
      data->context, j_console, "error",
      JS_NewCFunction(data->context, js_console_error, "error", 1));

  JSValue j_global = JS_GetGlobalObject(data->context);
  JS_SetPropertyStr(data->context, j_global, "console", j_console);
  JS_FreeValue(data->context, j_global);

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
  JSValue j_awaitedResult = js_std_await(data->context, j_codeResult); // This frees j_codeResult
  JSValue j_returnedValue = JS_GetPropertyStr(data->context, j_awaitedResult, "value");
  // Do this by rescuing to_rb_value
  if (JS_VALUE_GET_NORM_TAG(j_returnedValue) == JS_TAG_OBJECT && JS_PromiseState(data->context, j_returnedValue) != -1)
  {
    JS_FreeValue(data->context, j_returnedValue);
    JS_FreeValue(data->context, j_awaitedResult);
    VALUE r_error_message = rb_str_new2("An unawaited Promise was returned to the top-level");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_NO_AWAIT_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
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

static VALUE vm_m_defineGlobalFunction(int argc, VALUE *argv, VALUE r_self)
{
  rb_need_block();

  VALUE r_name;
  VALUE r_flags;
  VALUE r_block;
  rb_scan_args(argc, argv, "10*&", &r_name, &r_flags, &r_block);

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  rb_hash_aset(data->defined_functions, r_name, r_block);
  char *funcName = StringValueCStr(r_name);

  JSValueConst ruby_data[2];
  ruby_data[0] = JS_NewString(data->context, funcName);
  ruby_data[1] = JS_NewBool(data->context, RTEST(rb_funcall(r_flags, rb_intern("include?"), 1, ID2SYM(rb_intern("async")))));

  JSValue j_global = JS_GetGlobalObject(data->context);
  JS_SetPropertyStr(
      data->context, j_global, funcName,
      JS_NewCFunctionData(data->context, js_quickjsrb_call_global, 1, 0, 2, ruby_data));
  JS_FreeValue(data->context, j_global);

  return rb_funcall(r_name, rb_intern("to_sym"), 0, NULL);
}

static VALUE vm_m_import(int argc, VALUE *argv, VALUE r_self)
{
  VALUE r_import_string, r_opts;
  rb_scan_args(argc, argv, "10:", &r_import_string, &r_opts);
  if (NIL_P(r_opts))
    r_opts = rb_hash_new();
  VALUE r_from = rb_hash_aref(r_opts, ID2SYM(rb_intern("from")));
  if (NIL_P(r_from))
  {
    VALUE r_error_message = rb_str_new2("missing import source");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
    return Qnil;
  }
  VALUE r_custom_exposure = rb_hash_aref(r_opts, ID2SYM(rb_intern("code_to_expose")));

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  char *filename = random_string();
  char *source = StringValueCStr(r_from);
  JSValue func = JS_Eval(data->context, source, strlen(source), filename, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  js_module_set_import_meta(data->context, func, TRUE, FALSE);
  JS_FreeValue(data->context, func);

  VALUE r_import_settings = rb_funcall(
      rb_const_get(rb_cClass, rb_intern("Quickjs")),
      rb_intern("_build_import"),
      1,
      r_import_string);
  VALUE r_import_name = rb_ary_entry(r_import_settings, 0);
  char *import_name = StringValueCStr(r_import_name);
  VALUE r_default_exposure = rb_ary_entry(r_import_settings, 1);
  char *globalize;
  if (RTEST(r_custom_exposure))
  {
    globalize = StringValueCStr(r_custom_exposure);
  }
  else
  {
    globalize = StringValueCStr(r_default_exposure);
  }

  const char *importAndGlobalizeModule = "import %s from '%s';\n"
                                         "%s\n";
  int length = snprintf(NULL, 0, importAndGlobalizeModule, import_name, filename, globalize);
  char *result = (char *)malloc(length + 1);
  snprintf(result, length + 1, importAndGlobalizeModule, import_name, filename, globalize);

  JSValue j_codeResult = JS_Eval(data->context, result, strlen(result), "<vm>", JS_EVAL_TYPE_MODULE);
  free(result);
  JS_FreeValue(data->context, j_codeResult);

  return Qtrue;
}

static VALUE vm_m_logs(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  return data->logs;
}

RUBY_FUNC_EXPORTED void Init_quickjsrb(void)
{
  rb_require("json");
  rb_require("securerandom");

  VALUE r_module_quickjs = rb_define_module("Quickjs");
  r_define_constants(r_module_quickjs);
  r_define_exception_classes(r_module_quickjs);

  VALUE r_class_vm = rb_define_class_under(r_module_quickjs, "VM", rb_cObject);
  rb_define_alloc_func(r_class_vm, vm_alloc);
  rb_define_method(r_class_vm, "initialize", vm_m_initialize, -1);
  rb_define_method(r_class_vm, "eval_code", vm_m_evalCode, 1);
  rb_define_method(r_class_vm, "define_function", vm_m_defineGlobalFunction, -1);
  rb_define_method(r_class_vm, "import", vm_m_import, -1);
  rb_define_method(r_class_vm, "logs", vm_m_logs, 0);
  r_define_log_class(r_class_vm);
}
