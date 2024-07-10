#include "quickjsrb.h"

typedef struct VMData {
  char alive;
  struct JSContext *context;
  struct ProcEntryMap *procs;
} VMData;

void vm_free(void* data)
{
  free(data);
}

size_t vm_size(const void* data)
{
  return sizeof(data);
}

static const rb_data_type_t vm_type = {
  .wrap_struct_name = "vm",
  .function = {
    .dmark = NULL,
    .dfree = vm_free,
    .dsize = vm_size,
  },
  .data = NULL,
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

VALUE vm_alloc(VALUE self)
{
  VMData *data;
  return TypedData_Make_Struct(self, VMData, &vm_type, data);
}

VALUE rb_mQuickjs;
const char *undefinedId = "undefined";
const char *nanId = "NaN";

const char *featureStdId = "feature_std";
const char *featureOsId = "feature_os";

JSValue to_js_value(JSContext *ctx, VALUE r_value) {
  switch (TYPE(r_value)) {
    case T_NIL:
      return JS_NULL;
    case T_FIXNUM:
    case T_FLOAT: {
      VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0, NULL);
      char *str = StringValueCStr(r_str);
      JSValue global = JS_GetGlobalObject(ctx);
      JSValue numberClass = JS_GetPropertyStr(ctx, global, "Number");
      JSValue j_str = JS_NewString(ctx, str);
      JSValue stringified = JS_Call(ctx, numberClass, JS_UNDEFINED, 1, &j_str);
      JS_FreeValue(ctx, global);
      JS_FreeValue(ctx, numberClass);

      return stringified;
    }
    case T_STRING: {
      char *str = StringValueCStr(r_value);

      return JS_NewString(ctx, str);
    }
    case T_SYMBOL: {
      VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0, NULL);
      char *str = StringValueCStr(r_str);

      return JS_NewString(ctx, str);
    }
    case T_TRUE:
      return JS_TRUE;
    case T_FALSE:
      return JS_FALSE;
    case T_HASH:
    case T_ARRAY: {
      VALUE r_json_str = rb_funcall(r_value, rb_intern("to_json"), 0, NULL);
      char *str = StringValueCStr(r_json_str);
      JSValue global = JS_GetGlobalObject(ctx);
      JSValue jsonClass = JS_GetPropertyStr(ctx, global, "JSON");
      JSValue parseFunc = JS_GetPropertyStr(ctx, jsonClass, "parse");
      JSValue j_str = JS_NewString(ctx, str);
      JSValue stringified = JS_Call(ctx, parseFunc, jsonClass, 1, &j_str);
      JS_FreeValue(ctx, global);
      JS_FreeValue(ctx, parseFunc);
      JS_FreeValue(ctx, jsonClass);

      return stringified;
    }
    default: {
      VALUE r_inspect_str = rb_funcall(r_value, rb_intern("inspect"), 0, NULL);
      char *str = StringValueCStr(r_inspect_str);

      return JS_NewString(ctx, str);
    }
  }
}

VALUE to_rb_value(JSValue jsv, JSContext *ctx) {
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
    int promiseState = JS_PromiseState(ctx, jsv);
    if (promiseState == JS_PROMISE_FULFILLED || promiseState == JS_PROMISE_PENDING) {
      return to_rb_value(js_std_await(ctx, jsv), ctx);
    } else if (promiseState == JS_PROMISE_REJECTED) {
      return to_rb_value(JS_Throw(ctx, JS_PromiseResult(ctx, jsv)), ctx);
    }

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
  case JS_TAG_EXCEPTION: {
    JSValue exceptionVal = JS_GetException(ctx);
    if (JS_IsError(ctx, exceptionVal)) {
      JSValue jsErrorClassName = JS_GetPropertyStr(ctx, exceptionVal, "name");
      const char *errorClassName = JS_ToCString(ctx, jsErrorClassName);

      JSValue jsErrorClassMessage = JS_GetPropertyStr(ctx, exceptionVal, "message");
      const char *errorClassMessage = JS_ToCString(ctx, jsErrorClassMessage);

      JS_FreeValue(ctx, jsErrorClassMessage);
      JS_FreeValue(ctx, jsErrorClassName);

      rb_raise(rb_eRuntimeError, "%s: %s", errorClassName, errorClassMessage);
    } else {
      const char *errorMessage = JS_ToCString(ctx, exceptionVal);

      rb_raise(rb_eRuntimeError, "%s", errorMessage);
    }

    JS_FreeValue(ctx, exceptionVal);
    return Qnil;
  }
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

static JSValue js_quickjsrb_call_global(JSContext *ctx, JSValueConst _this, int _argc, JSValueConst *argv) {
  VMData *data = JS_GetContextOpaque(ctx);
  JSValue maybeFuncName = JS_ToString(ctx, argv[0]);
  const char *funcName = JS_ToCString(ctx, maybeFuncName);
  JS_FreeValue(ctx, maybeFuncName);

  VALUE proc = get_proc(data->procs, funcName);
  if (proc == Qnil) { // Shouldn't happen
    return JS_ThrowReferenceError(ctx, "Proc `%s` is not defined", funcName);
  }

  VALUE r_result = rb_apply(proc, rb_intern("call"), to_rb_value(argv[1], ctx));
  return to_js_value(ctx, r_result);
}

VALUE vm_m_initialize(int argc, VALUE* argv, VALUE self)
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

  VMData *data;
  TypedData_Get_Struct(self, VMData, &vm_type, data);

  JSRuntime *runtime = JS_NewRuntime();
  data->context = JS_NewContext(runtime);
  data->procs = create_proc_entries();
  data->alive = 1;
  JS_SetContextOpaque(data->context, data);

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

  const char *setupGlobalRuby = "globalThis.__ruby = {};\n";
  JSValue rubyEval = JS_Eval(data->context, setupGlobalRuby, strlen(setupGlobalRuby), "<vm>", JS_EVAL_TYPE_MODULE);
  JS_FreeValue(data->context, rubyEval);

  JSValue global = JS_GetGlobalObject(data->context);
  JSValue func = JS_NewCFunction(data->context, js_quickjsrb_call_global, "rubyGlobal", 2);
  JS_SetPropertyStr(data->context, global, "rubyGlobal", func);
  JS_FreeValue(data->context, global);

  return self;
}

VALUE vm_m_evalCode(VALUE self, VALUE r_code)
{
  VMData *data;
  TypedData_Get_Struct(self, VMData, &vm_type, data);

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

VALUE vm_m_defineGlobalFunction(VALUE self, VALUE r_name)
{
  rb_need_block();

  VMData *data;
  TypedData_Get_Struct(self, VMData, &vm_type, data);

  if (rb_block_given_p()) {
    VALUE proc = rb_block_proc();

    char *funcName = StringValueCStr(r_name);

    set_proc(data->procs, funcName, proc);

    const char* template = "globalThis.__ruby['%s'] = (...args) => rubyGlobal('%s', args);\nglobalThis['%s'] = globalThis.__ruby['%s'];\n";
    int length = snprintf(NULL, 0, template, funcName, funcName, funcName, funcName);
    char* result = (char*)malloc(length + 1);
    snprintf(result, length + 1, template, funcName, funcName, funcName, funcName);

    JSValue codeResult = JS_Eval(data->context, result, strlen(result), "<vm>", JS_EVAL_TYPE_MODULE);

    JS_FreeValue(data->context, codeResult);
    free(result);
    return rb_funcall(r_name, rb_intern("to_sym"), 0, NULL);
  }

  return Qnil;
}

VALUE vm_m_dispose(VALUE self)
{
  VMData *data;
  TypedData_Get_Struct(self, VMData, &vm_type, data);

  JSRuntime *runtime = JS_GetRuntime(data->context);
  js_std_free_handlers(runtime);
  free_proc_entry_map(data->procs);
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
  rb_define_alloc_func(vmClass, vm_alloc);
  rb_define_method(vmClass, "initialize", vm_m_initialize, -1);
  rb_define_method(vmClass, "eval_code", vm_m_evalCode, 1);
  rb_define_method(vmClass, "define_function", vm_m_defineGlobalFunction, 1);
  rb_define_method(vmClass, "dispose!", vm_m_dispose, 0);
}
