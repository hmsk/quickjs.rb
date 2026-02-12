#include "quickjsrb.h"

static int dispatch_log(VMData *data, const char *severity, VALUE r_row);

JSValue j_error_from_ruby_error(JSContext *ctx, VALUE r_error)
{
  JSValue j_error = JS_NewError(ctx); // may wanna have custom error class to determine in JS' end

  VALUE r_object_id = rb_funcall(r_error, rb_intern("object_id"), 0);
  int objectId = NUM2INT(r_object_id);
  JS_SetPropertyStr(ctx, j_error, "rb_object_id", JS_NewInt32(ctx, objectId));

  // Keep the error alive in VMData to prevent GC before find_ruby_error retrieves it
  VMData *data = JS_GetContextOpaque(ctx);
  rb_hash_aset(data->alive_objects, r_object_id, r_error);

  VALUE r_exception_message = rb_funcall(r_error, rb_intern("message"), 0);
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
    VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0);
    char *str = StringValueCStr(r_str);
    JSValue j_global = JS_GetGlobalObject(ctx);
    JSValue j_numberClass = JS_GetPropertyStr(ctx, j_global, "Number");
    JSValue j_str = JS_NewString(ctx, str);
    JSValue j_stringified = JS_Call(ctx, j_numberClass, JS_UNDEFINED, 1, (JSValueConst *)&j_str);
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
    VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0);
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
    VALUE r_json_str = rb_funcall(r_value, rb_intern("to_json"), 0);
    char *str = StringValueCStr(r_json_str);
    JSValue j_parsed = JS_ParseJSON(ctx, str, strlen(str), "<quickjsrb.c>");

    return j_parsed;
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
    VALUE r_inspect_str = rb_funcall(r_value, rb_intern("inspect"), 0);
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
      VMData *data = JS_GetContextOpaque(ctx);
      VALUE r_key = INT2NUM(errorOriginalRubyObjectId);
      VALUE r_error = rb_hash_aref(data->alive_objects, r_key);
      rb_hash_delete(data->alive_objects, r_key);
      return r_error;
    }
  }
  else
  {
    JS_FreeValue(ctx, j_errorOriginalRubyObjectId);
  }
  return Qnil;
}

VALUE r_try_json_parse(VALUE r_str)
{
  return rb_funcall(rb_const_get(rb_cClass, rb_intern("JSON")), rb_intern("parse"), 1, r_str);
}

VALUE to_r_json(JSContext *ctx, JSValue j_val)
{
  JSValue j_stringified = JS_JSONStringify(ctx, j_val, JS_UNDEFINED, JS_UNDEFINED);

  const char *msg = JS_ToCString(ctx, j_stringified);
  VALUE r_str = rb_str_new2(msg);
  JS_FreeCString(ctx, msg);

  JS_FreeValue(ctx, j_stringified);

  return r_str;
}

VALUE to_rb_value(JSContext *ctx, JSValue j_val)
{
  switch (JS_VALUE_GET_NORM_TAG(j_val))
  {
  case JS_TAG_INT:
  {
    return INT2NUM(JS_VALUE_GET_INT(j_val));
  }
  case JS_TAG_FLOAT64:
  {
    if (JS_VALUE_IS_NAN(j_val))
    {
      return QUICKJSRB_SYM(nanId);
    }
    return DBL2NUM(JS_VALUE_GET_FLOAT64(j_val));
  }
  case JS_TAG_BOOL:
  {
    return JS_ToBool(ctx, j_val) > 0 ? Qtrue : Qfalse;
  }
  case JS_TAG_STRING:
  {
    int couldntParse;
    VALUE r_result = rb_protect(r_try_json_parse, to_r_json(ctx, j_val), &couldntParse);
    if (couldntParse)
    {
      return Qnil;
    }
    else
    {
      return r_result;
    }
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
    VALUE r_str = to_r_json(ctx, j_val);

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
      dispatch_log(data, "error", rb_ary_new3(1, r_log_body_new(r_headline, r_headline)));

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
      dispatch_log(data, "error", rb_ary_new3(1, r_log_body_new(r_headline, r_headline)));

      free(headline);

      VALUE r_error_message = rb_sprintf("%s", errorMessage);
      JS_FreeCString(ctx, errorMessage);
      JS_FreeValue(ctx, j_exceptionVal);
      rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
    }
    return Qnil;
  }
  case JS_TAG_BIG_INT:
  case JS_TAG_SHORT_BIG_INT:
  {
    JSValue j_toStringFunc = JS_GetPropertyStr(ctx, j_val, "toString");
    JSValue j_strigified = JS_Call(ctx, j_toStringFunc, j_val, 0, NULL);

    const char *msg = JS_ToCString(ctx, j_strigified);
    VALUE r_str = rb_str_new2(msg);
    JS_FreeValue(ctx, j_toStringFunc);
    JS_FreeValue(ctx, j_strigified);
    JS_FreeCString(ctx, msg);

    return rb_funcall(r_str, rb_intern("to_i"), 0);
  }
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
  VALUE r_proc = rb_hash_aref(data->defined_functions, ID2SYM(rb_intern(funcName)));
  // Shouldn't happen
  if (r_proc == Qnil)
  {
    return JS_ThrowReferenceError(ctx, "Proc `%s` is not defined", funcName); // TODO: Free funcnName
  }
  JS_FreeCString(ctx, funcName);

  VALUE r_call_args = rb_ary_new();
  rb_ary_push(r_call_args, r_proc);

  VALUE r_argv = rb_ary_new();
  for (int i = 0; i < argc; i++)
  {
    JSValue j_v = JS_DupValue(ctx, argv[i]);
    rb_ary_push(r_argv, to_rb_value(ctx, j_v));
    JS_FreeValue(ctx, j_v);
  }
  rb_ary_push(r_call_args, r_argv);
  rb_ary_push(r_call_args, ULONG2NUM(data->eval_time->limit_ms));

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

static JSValue js_delay_and_eval_job(JSContext *ctx, int argc, JSValueConst *argv)
{
  VALUE rb_delay_msec = to_rb_value(ctx, argv[1]);
  VALUE rb_delay_sec = rb_funcall(rb_delay_msec, rb_intern("/"), 1, rb_float_new(1000));
  rb_thread_wait_for(rb_time_interval(rb_delay_sec));
  JS_Call(ctx, argv[0], JS_UNDEFINED, 0, NULL);

  return JS_UNDEFINED;
}

static JSValue js_quickjsrb_set_timeout(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  JSValueConst func;
  int64_t delay;

  func = argv[0];
  if (!JS_IsFunction(ctx, func))
    return JS_ThrowTypeError(ctx, "not a function");
  if (JS_ToInt64(ctx, &delay, argv[1])) // TODO: should be lower than global timeout
    return JS_EXCEPTION;

  JSValueConst args[2];
  args[0] = func;
  args[1] = argv[1]; // delay
  // TODO: implement timer manager and poll with quickjs' queue
  // Currently, queueing multiple js_delay_and_eval_job is not parallelized
  JS_EnqueueJob(ctx, js_delay_and_eval_job, 2, args);

  return JS_UNDEFINED;
}

static VALUE r_try_call_listener(VALUE r_args)
{
  VALUE r_listener = RARRAY_AREF(r_args, 0);
  VALUE r_log = RARRAY_AREF(r_args, 1);
  return rb_funcall(r_listener, rb_intern("call"), 1, r_log);
}

static int dispatch_log(VMData *data, const char *severity, VALUE r_row)
{
  VALUE r_log = r_log_new(severity, r_row);
  if (!NIL_P(data->log_listener))
  {
    VALUE r_args = rb_ary_new3(2, data->log_listener, r_log);
    int error;
    rb_protect(r_try_call_listener, r_args, &error);
    if (error)
      return error;
  }
  else
  {
    rb_ary_push(data->logs, r_log);
  }
  return 0;
}

static VALUE vm_m_on_log(VALUE r_self)
{
  rb_need_block();

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  data->log_listener = rb_block_proc();

  return Qnil;
}

static JSValue js_quickjsrb_log(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv, const char *severity)
{
  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_row = rb_ary_new();
  for (int i = 0; i < argc; i++)
  {
    JSValue j_logged = JS_DupValue(ctx, argv[i]);
    VALUE r_raw;
    if (JS_VALUE_GET_NORM_TAG(j_logged) == JS_TAG_OBJECT && JS_PromiseState(ctx, j_logged) != -1)
    {
      r_raw = rb_str_new2("Promise");
    }
    else if (JS_IsError(ctx, j_logged))
    {
      JSValue j_errorClassName = JS_GetPropertyStr(ctx, j_logged, "name");
      const char *errorClassName = JS_ToCString(ctx, j_errorClassName);
      JS_FreeValue(ctx, j_errorClassName);

      JSValue j_errorClassMessage = JS_GetPropertyStr(ctx, j_logged, "message");
      const char *errorClassMessage = JS_ToCString(ctx, j_errorClassMessage);
      JS_FreeValue(ctx, j_errorClassMessage);

      JSValue j_stackTrace = JS_GetPropertyStr(ctx, j_logged, "stack");
      const char *stackTrace = JS_ToCString(ctx, j_stackTrace);
      JS_FreeValue(ctx, j_stackTrace);

      const char *headlineTemplate = "%s: %s\n%s";
      int length = snprintf(NULL, 0, headlineTemplate, errorClassName, errorClassMessage, stackTrace);
      char *headline = (char *)malloc(length + 1);
      snprintf(headline, length + 1, headlineTemplate, errorClassName, errorClassMessage, stackTrace);
      JS_FreeCString(ctx, errorClassName);
      JS_FreeCString(ctx, errorClassMessage);
      JS_FreeCString(ctx, stackTrace);

      r_raw = rb_str_new2(headline);
      free(headline);
    }
    else
    {
      r_raw = to_rb_value(ctx, j_logged);
    }
    const char *body = JS_ToCString(ctx, j_logged);
    VALUE r_c = rb_str_new2(body);
    JS_FreeCString(ctx, body);
    JS_FreeValue(ctx, j_logged);

    rb_ary_push(r_row, r_log_body_new(r_raw, r_c));
  }

  int error = dispatch_log(data, severity, r_row);
  if (error)
  {
    VALUE r_error = rb_errinfo();
    rb_set_errinfo(Qnil);
    JSValue j_error = j_error_from_ruby_error(ctx, r_error);
    return JS_Throw(ctx, j_error);
  }
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

  data->eval_time->limit_ms = (int64_t)NUM2UINT(r_timeout_msec);
  JS_SetContextOpaque(data->context, data);
  JSRuntime *runtime = JS_GetRuntime(data->context);

  JS_SetMemoryLimit(runtime, NUM2UINT(r_memory_limit));
  JS_SetMaxStackSize(runtime, NUM2UINT(r_max_stack_size));

  JS_SetModuleLoaderFunc2(runtime, NULL, js_module_loader, js_module_check_attributes, NULL);
  js_std_init_handlers(runtime);

  JSValue j_global = JS_GetGlobalObject(data->context);

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
  else if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featureTimeoutId))))
  {
    JS_SetPropertyStr(
        data->context, j_global, "setTimeout",
        JS_NewCFunction(data->context, js_quickjsrb_set_timeout, "setTimeout", 2));
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillIntlId))))
  {
    const char *defineIntl = "Object.defineProperty(globalThis, 'Intl', { value:{} });\n";
    JSValue j_defineIntl = JS_Eval(data->context, defineIntl, strlen(defineIntl), "<vm>", JS_EVAL_TYPE_GLOBAL);
    JS_FreeValue(data->context, j_defineIntl);

    JSValue j_polyfillIntlObject = JS_ReadObject(data->context, &qjsc_polyfill_intl_en_min, qjsc_polyfill_intl_en_min_size, JS_READ_OBJ_BYTECODE);
    JSValue j_polyfillIntlResult = JS_EvalFunction(data->context, j_polyfillIntlObject); // Frees polyfillIntlObject
    JS_FreeValue(data->context, j_polyfillIntlResult);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillFileId))))
  {
    JSValue j_polyfillFileObject = JS_ReadObject(data->context, &qjsc_polyfill_file_min, qjsc_polyfill_file_min_size, JS_READ_OBJ_BYTECODE);
    JSValue j_polyfillFileResult = JS_EvalFunction(data->context, j_polyfillFileObject);
    JS_FreeValue(data->context, j_polyfillFileResult);
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

  JS_SetPropertyStr(data->context, j_global, "console", j_console);
  JS_FreeValue(data->context, j_global);

  return r_self;
}

static int interrupt_handler(JSRuntime *runtime, void *opaque)
{
  EvalTime *eval_time = opaque;
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  int64_t elapsed_ms = (int64_t)(now.tv_sec - eval_time->started_at.tv_sec) * 1000
                     + (now.tv_nsec - eval_time->started_at.tv_nsec) / 1000000;
  return elapsed_ms >= eval_time->limit_ms ? 1 : 0;
}

static VALUE vm_m_evalCode(VALUE r_self, VALUE r_code)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  if (!RB_TYPE_P(r_code, T_STRING))
  {
    VALUE r_code_class = rb_class_name(CLASS_OF(r_code));
    rb_raise(rb_eTypeError, "JavaScript code must be a String, got %s", StringValueCStr(r_code_class));
  }

  clock_gettime(CLOCK_MONOTONIC, &data->eval_time->started_at);
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
    // Free j_awaitedResult before to_rb_value because to_rb_value may
    // raise (longjmp) for JS exceptions, which would skip any cleanup
    // after it and leak JS GC objects.
    JS_FreeValue(data->context, j_awaitedResult);
    VALUE result = to_rb_value(data->context, j_returnedValue);
    JS_FreeValue(data->context, j_returnedValue);
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

  if (!(SYMBOL_P(r_name) || RB_TYPE_P(r_name, T_STRING)))
  {
    rb_raise(rb_eTypeError, "function's name should be a Symbol or a String");
  }

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  VALUE r_name_sym = rb_funcall(r_name, rb_intern("to_sym"), 0);

  rb_hash_aset(data->defined_functions, r_name_sym, r_block);
  VALUE r_name_str = rb_funcall(r_name, rb_intern("to_s"), 0);
  char *funcName = StringValueCStr(r_name_str);

  JSValueConst ruby_data[2];
  ruby_data[0] = JS_NewString(data->context, funcName);
  ruby_data[1] = JS_NewBool(data->context, RTEST(rb_funcall(r_flags, rb_intern("include?"), 1, ID2SYM(rb_intern("async")))));

  JSValue j_global = JS_GetGlobalObject(data->context);
  JS_SetPropertyStr(
      data->context, j_global, funcName,
      JS_NewCFunctionData(data->context, js_quickjsrb_call_global, 1, 0, 2, ruby_data));
  JS_FreeValue(data->context, j_global);
  JS_FreeValue(data->context, ruby_data[0]);
  JS_FreeValue(data->context, ruby_data[1]);

  return r_name_sym;
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
  JSValue module = JS_Eval(data->context, source, strlen(source), filename, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(module))
  {
    JS_FreeValue(data->context, module);
    return to_rb_value(data->context, module);
  }
  js_module_set_import_meta(data->context, module, TRUE, FALSE);
  JS_FreeValue(data->context, module);

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
  rb_category_warn(RB_WARN_CATEGORY_DEPRECATED, "Quickjs::VM#logs is deprecated; use Quickjs::VM#on_log instead");

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
  rb_define_method(r_class_vm, "on_log", vm_m_on_log, 0);
  r_define_log_class(r_class_vm);
}
