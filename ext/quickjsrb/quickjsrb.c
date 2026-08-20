#include "quickjsrb.h"
#include "quickjsrb_file.h"
#include "quickjsrb_crypto.h"

const char *featureStdId = "feature_std";
const char *featureOsId = "feature_os";
const char *featureTimeoutId = "feature_timeout";
const char *featurePolyfillFileId = "feature_polyfill_file";
const char *featurePolyfillEncodingId = "feature_polyfill_encoding";
const char *featurePolyfillUrlId = "feature_polyfill_url";
const char *featurePolyfillCryptoId = "feature_polyfill_crypto";

const char *undefinedId = "undefined";
const char *nanId = "NaN";
const char *vmInternalFilename = "<vm>";

const char *native_errors[] = {
    "SyntaxError",
    "TypeError",
    "ReferenceError",
    "RangeError",
    "EvalError",
    "URIError",
    "AggregateError"};
const int num_native_errors = sizeof(native_errors) / sizeof(native_errors[0]);

static int dispatch_log(VMData *data, const char *severity, VALUE r_row);
static void check_disposed(VMData *data);
static void run_gvl_release_region(VMData *data, void *(*job_run)(void *), void *job, JSValue *j_result, void *owned_buf0, void *owned_buf1);
// Defined below, next to the stack-bounds query it depends on; enter_js_entry
// above needs it.
static void rebase_stack_limit(VMData *data);

JSValue to_js_value(JSContext *ctx, VALUE r_value);
VALUE to_rb_value(JSContext *ctx, JSValue j_val);
static VALUE to_rb_value_inner(JSContext *ctx, JSValue j_val, VALUE r_visited);
static VALUE vm_m_memoryUsage(VALUE r_self);
static VALUE vm_m_runGC(VALUE r_self);
static VALUE vm_m_memoryPoisoned(VALUE r_self);
static VALUE vm_m_dispose(VALUE r_self);
static VALUE vm_m_disposed(VALUE r_self);
static VALUE vm_m_drainJobs(VALUE r_self);

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

typedef struct
{
  JSContext *ctx;
  JSValue j_obj;
} RbHashToJsArg;

static int rb_hash_entry_to_js(VALUE r_key, VALUE r_val, VALUE extra)
{
  RbHashToJsArg *arg = (RbHashToJsArg *)extra;
  const char *key_cstr;
  if (SYMBOL_P(r_key))
  {
    key_cstr = rb_id2name(SYM2ID(r_key));
  }
  else if (RB_TYPE_P(r_key, T_STRING))
  {
    key_cstr = StringValueCStr(r_key);
  }
  else
  {
    VALUE r_key_str = rb_funcall(r_key, rb_intern("to_s"), 0);
    key_cstr = StringValueCStr(r_key_str);
  }
  JS_SetPropertyStr(arg->ctx, arg->j_obj, key_cstr, to_js_value(arg->ctx, r_val));
  return ST_CONTINUE;
}

JSValue to_js_value(JSContext *ctx, VALUE r_value)
{
  switch (TYPE(r_value))
  {
  case T_NIL:
    return JS_NULL;
  case T_FIXNUM:
    return JS_NewInt64(ctx, NUM2LL(r_value));
  case T_FLOAT:
    return JS_NewFloat64(ctx, NUM2DBL(r_value));
  case T_BIGNUM:
  {
    VALUE r_str = rb_funcall(r_value, rb_intern("to_s"), 0);
    JSValue j_str = JS_NewStringLen(ctx, RSTRING_PTR(r_str), RSTRING_LEN(r_str));
    JSValue j_global = JS_GetGlobalObject(ctx);
    JSValue j_numberClass = JS_GetPropertyStr(ctx, j_global, "Number");
    JSValue j_num = JS_Call(ctx, j_numberClass, JS_UNDEFINED, 1, (JSValueConst *)&j_str);
    JS_FreeValue(ctx, j_str);
    JS_FreeValue(ctx, j_numberClass);
    JS_FreeValue(ctx, j_global);
    return j_num;
  }
  case T_STRING:
    return JS_NewStringLen(ctx, RSTRING_PTR(r_value), RSTRING_LEN(r_value));
  case T_SYMBOL:
  {
    if (r_value == QUICKJSRB_SYM(undefinedId))
      return JS_UNDEFINED;
    if (r_value == QUICKJSRB_SYM(nanId))
    {
      JSValue j_global = JS_GetGlobalObject(ctx);
      JSValue j_nan = JS_GetPropertyStr(ctx, j_global, "NaN");
      JS_FreeValue(ctx, j_global);
      return j_nan;
    }
    const char *name = rb_id2name(SYM2ID(r_value));
    return JS_NewString(ctx, name);
  }
  case T_TRUE:
    return JS_TRUE;
  case T_FALSE:
    return JS_FALSE;
  case T_ARRAY:
  {
    int len = RARRAY_LEN(r_value);
    JSValue j_arr = JS_NewArray(ctx);
    for (int i = 0; i < len; i++)
    {
      JS_SetPropertyUint32(ctx, j_arr, (uint32_t)i, to_js_value(ctx, RARRAY_AREF(r_value, i)));
    }
    return j_arr;
  }
  case T_HASH:
  {
    JSValue j_obj = JS_NewObject(ctx);
    RbHashToJsArg arg = {ctx, j_obj};
    rb_hash_foreach(r_value, rb_hash_entry_to_js, (VALUE)&arg);
    return j_obj;
  }
  default:
  {
    if (rb_obj_is_kind_of(r_value, rb_cFile))
    {
      VMData *data = JS_GetContextOpaque(ctx);
      if (!JS_IsUndefined(data->j_file_proxy_creator))
        return quickjsrb_file_to_js(ctx, r_value);
    }
    if (rb_obj_is_kind_of(r_value, rb_eException))
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

// Convert a JS Error.stack string into a Ruby Array suitable for
// Exception#set_backtrace. Lines are stripped; empty lines (including the
// trailing newline that QuickJS appends) are dropped. The frames keep
// QuickJS's native format ("at func (file:line)") — Ruby's backtrace API
// doesn't enforce a layout, and reshaping into "file:line:in 'method'"
// would lose information for no real win.
static VALUE r_backtrace_from_js_stack(const char *stack)
{
  if (stack == NULL || stack[0] == '\0')
    return Qnil;

  VALUE r_lines = rb_str_split(rb_str_new_cstr(stack), "\n");
  VALUE r_filtered = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(r_lines); i++)
  {
    VALUE r_line = rb_funcall(rb_ary_entry(r_lines, i), rb_intern("strip"), 0);
    if (RSTRING_LEN(r_line) > 0)
      rb_ary_push(r_filtered, r_line);
  }
  return RARRAY_LEN(r_filtered) > 0 ? r_filtered : Qnil;
}

VALUE to_r_json(JSContext *ctx, JSValue j_val)
{
  JSValue j_stringified = JS_JSONStringify(ctx, j_val, JS_UNDEFINED, JS_UNDEFINED);

  // JSON.stringify throws on circular structures (e.g. jQuery objects'
  // prevObject chain). Clear the pending exception so it doesn't poison
  // subsequent eval, and return nil so callers fall through to "couldn't
  // parse" handling rather than crashing on rb_str_new2(NULL) below.
  if (JS_IsException(j_stringified))
  {
    JS_FreeValue(ctx, j_stringified);
    JSValue j_pending = JS_GetException(ctx);
    JS_FreeValue(ctx, j_pending);
    return Qnil;
  }

  const char *msg = JS_ToCString(ctx, j_stringified);
  JS_FreeValue(ctx, j_stringified);
  if (msg == NULL)
    return Qnil;
  VALUE r_str = rb_str_new2(msg);
  JS_FreeCString(ctx, msg);
  return r_str;
}

static int js_is_plain_object(JSContext *ctx, JSValue j_val)
{
  JSValue j_proto = JS_GetPrototype(ctx, j_val);
  if (JS_IsNull(j_proto))
    return 1; // Object.create(null)
  JSValue j_global = JS_GetGlobalObject(ctx);
  JSValue j_Object = JS_GetPropertyStr(ctx, j_global, "Object");
  JSValue j_Object_proto = JS_GetPropertyStr(ctx, j_Object, "prototype");
  int result = JS_StrictEq(ctx, j_proto, j_Object_proto);
  JS_FreeValue(ctx, j_proto);
  JS_FreeValue(ctx, j_global);
  JS_FreeValue(ctx, j_Object);
  JS_FreeValue(ctx, j_Object_proto);
  return result;
}

static VALUE js_array_to_rb(JSContext *ctx, JSValue j_val, VALUE r_visited)
{
  JSValue j_length = JS_GetPropertyStr(ctx, j_val, "length");
  uint32_t length = 0;
  JS_ToUint32(ctx, &length, j_length);
  JS_FreeValue(ctx, j_length);

  VALUE r_array = rb_ary_new_capa(length);
  for (uint32_t i = 0; i < length; i++)
  {
    JSValue j_elem = JS_GetPropertyUint32(ctx, j_val, i);
    rb_ary_push(r_array, to_rb_value_inner(ctx, j_elem, r_visited));
    JS_FreeValue(ctx, j_elem);
  }
  return r_array;
}

static VALUE js_plain_object_to_rb(JSContext *ctx, JSValue j_val, VALUE r_visited)
{
  JSPropertyEnum *ptab;
  uint32_t plen;
  if (JS_GetOwnPropertyNames(ctx, &ptab, &plen, j_val, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0)
    return rb_hash_new();

  VALUE r_hash = rb_hash_new();
  for (uint32_t i = 0; i < plen; i++)
  {
    const char *key = JS_AtomToCString(ctx, ptab[i].atom);
    JSValue j_prop = JS_GetProperty(ctx, j_val, ptab[i].atom);
    rb_hash_aset(r_hash, rb_str_new2(key), to_rb_value_inner(ctx, j_prop, r_visited));
    JS_FreeCString(ctx, key);
    JS_FreeValue(ctx, j_prop);
  }
  JS_FreePropertyEnum(ctx, ptab, plen);
  return r_hash;
}

VALUE to_rb_value(JSContext *ctx, JSValue j_val)
{
  return to_rb_value_inner(ctx, j_val, Qnil);
}

static VALUE to_rb_value_inner(JSContext *ctx, JSValue j_val, VALUE r_visited)
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
  case JS_TAG_STRING_ROPE:
  {
    // QuickJS keeps long `s += chunk` chains as a rope (JS_TAG_STRING_ROPE)
    // until something materialises them. JS_ToCStringLen flattens ropes
    // transparently, so both tags share the same conversion path.
    size_t len;
    const char *str = JS_ToCStringLen(ctx, &len, j_val);
    if (str == NULL)
      return Qnil;
    VALUE r_str = rb_utf8_str_new(str, (long)len);
    JS_FreeCString(ctx, str);
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

    if (JS_IsFunction(ctx, j_val))
    {
      JSValue j_toStringFunc = JS_GetPropertyStr(ctx, j_val, "toString");
      JSValue j_source = JS_Call(ctx, j_toStringFunc, j_val, 0, NULL);
      JS_FreeValue(ctx, j_toStringFunc);
      const char *source = JS_ToCString(ctx, j_source);
      JS_FreeValue(ctx, j_source);
      VALUE r_source = rb_str_new2(source);
      JS_FreeCString(ctx, source);
      return rb_funcall(rb_path2class("Quickjs::Function"), rb_intern("new"), 1, r_source);
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

    // Check for Ruby object proxy (e.g., File proxy with rb_object_id on target)
    {
      JSValue j_rb_id = JS_GetPropertyStr(ctx, j_val, "rb_object_id");
      if (JS_VALUE_GET_NORM_TAG(j_rb_id) == JS_TAG_INT || JS_VALUE_GET_NORM_TAG(j_rb_id) == JS_TAG_FLOAT64)
      {
        int64_t object_id;
        JS_ToInt64(ctx, &object_id, j_rb_id);
        JS_FreeValue(ctx, j_rb_id);
        if (object_id > 0)
        {
          VMData *data = JS_GetContextOpaque(ctx);
          VALUE r_obj = rb_hash_aref(data->alive_objects, LONG2NUM(object_id));
          if (!NIL_P(r_obj) && !rb_obj_is_kind_of(r_obj, rb_eException))
            return r_obj;
        }
      }
      else
      {
        JS_FreeValue(ctx, j_rb_id);
      }
    }

    // JS File → Quickjs::File
    {
      VALUE r_maybe_file = quickjsrb_try_convert_js_file(ctx, j_val);
      if (!NIL_P(r_maybe_file))
        return r_maybe_file;
    }

    // Below this point, conversion recurses into own properties / elements
    // via to_rb_value_inner. Track JS object pointers to break cycles —
    // re-entering the same object returns nil instead of blowing the stack.
    if (NIL_P(r_visited))
      r_visited = rb_hash_new();
    VALUE r_visit_key = ULL2NUM((uintptr_t)JS_VALUE_GET_PTR(j_val));
    if (RTEST(rb_hash_lookup(r_visited, r_visit_key)))
      return Qnil;
    rb_hash_aset(r_visited, r_visit_key, Qtrue);

    if (JS_IsArray(ctx, j_val))
      return js_array_to_rb(ctx, j_val, r_visited);

    if (js_is_plain_object(ctx, j_val))
      return js_plain_object_to_rb(ctx, j_val, r_visited);

    // Non-plain objects (Date, RegExp, Map, class instances, etc.).
    // If the object opts in to a JSON representation via toJSON (e.g. Date),
    // honour it — recurse on the returned value. Otherwise dump own enumerable
    // string-keyed properties; this is faster than the JSON round-trip and
    // preserves `undefined` values nested inside class instances.
    JSValue j_toJSON = JS_GetPropertyStr(ctx, j_val, "toJSON");
    if (JS_IsFunction(ctx, j_toJSON))
    {
      JSValue j_jsonValue = JS_Call(ctx, j_toJSON, j_val, 0, NULL);
      JS_FreeValue(ctx, j_toJSON);
      VALUE r_result = to_rb_value_inner(ctx, j_jsonValue, r_visited);
      JS_FreeValue(ctx, j_jsonValue);
      return r_result;
    }
    JS_FreeValue(ctx, j_toJSON);
    return js_plain_object_to_rb(ctx, j_val, r_visited);
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
      free(headline);

      VALUE r_error_class, r_error_message = rb_str_new2(errorClassMessage);
      VALUE r_error_name = rb_str_new2(errorClassName);
      VALUE r_backtrace = r_backtrace_from_js_stack(stackTrace);
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
      else if (strcmp(errorClassName, "InternalError") == 0 && strstr(errorClassMessage, "out of memory") != NULL)
      {
        // Once OOM has fired, the QuickJS heap is in a state where another
        // throw inside the parser-error path can corrupt the shape table and
        // segfault. Mark the VM so further eval/call calls refuse cleanly.
        data->oom_poisoned = true;
        r_error_class = QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR);
      }
      else
      {
        r_error_class = QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR);
      }
      JS_FreeValue(ctx, j_errorClassMessage);
      JS_FreeValue(ctx, j_errorClassName);
      JS_FreeValue(ctx, j_stackTrace);
      JS_FreeCString(ctx, stackTrace);
      JS_FreeCString(ctx, errorClassName);
      JS_FreeCString(ctx, errorClassMessage);
      JS_FreeValue(ctx, j_exceptionVal);

      VALUE r_exc = rb_funcall(r_error_class, rb_intern("new"), 2, r_error_message, r_error_name);
      if (!NIL_P(r_backtrace))
        rb_funcall(r_exc, rb_intern("set_backtrace"), 1, r_backtrace);
      rb_exc_raise(r_exc);
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

struct module_loader_call_args
{
  VALUE proc;
  VALUE r_specifier;
  VALUE r_importer;
};

// Calls the user's loader with one or two args based on its arity. Procs
// declared with a single positional (`->(name) { ... }`) get the legacy
// 1-arg form so existing callers keep working; everything else (2-arity
// lambdas, varargs procs) receives `(specifier, importer)`.
static VALUE r_module_loader_call(VALUE r_args_val)
{
  struct module_loader_call_args *args = (struct module_loader_call_args *)r_args_val;
  int arity = NUM2INT(rb_funcall(args->proc, rb_intern("arity"), 0));
  if (arity == 1)
    return rb_funcall(args->proc, rb_intern("call"), 1, args->r_specifier);
  return rb_funcall(args->proc, rb_intern("call"), 2, args->r_specifier, args->r_importer);
}

// Normalize hook. Resolves `(specifier, importer)` to a canonical name by
// consulting the resolution cache or invoking the user's loader Proc.
// The Proc's return value drives both the canonical name AND the source
// the load hook will eval:
//   - String          → canonical = specifier, source = the string
//   - { code:, as: }  → canonical = as,        source = code
//   - nil / false     → ReferenceError
// Source is stashed in `module_source_cache` keyed by canonical so the
// load hook can pick it up. The resolution cache memoizes the call so
// the Proc fires at most once per `(specifier, importer)` pair.
static char *quickjsrb_module_normalize(JSContext *ctx, const char *base_name, const char *name, void *opaque)
{
  VMData *data = JS_GetContextOpaque(ctx);

  VALUE r_specifier = rb_str_new_cstr(name);
  VALUE r_importer = rb_str_new_cstr(base_name);
  VALUE r_key = rb_ary_new3(2, r_specifier, r_importer);

  VALUE r_cached_canonical = rb_hash_aref(data->module_resolution_cache, r_key);
  if (!NIL_P(r_cached_canonical))
    return js_strdup(ctx, StringValueCStr(r_cached_canonical));

  // A preloaded name is already in ctx->loaded_modules, so js_find_loaded_module
  // will hand back that module the moment we return the name. Resolving it here
  // keeps the user's loader out of it entirely: it is never asked for a module
  // the VM was constructed with, the way a browser's module map short-circuits
  // a fetch.
  if (RTEST(rb_hash_aref(data->preloaded_module_names, r_specifier)))
    return js_strdup(ctx, StringValueCStr(r_specifier));

  struct module_loader_call_args args = {data->module_loader, r_specifier, r_importer};
  int state;
  VALUE r_return = rb_protect(r_module_loader_call, (VALUE)&args, &state);
  if (state)
  {
    VALUE r_error = rb_errinfo();
    rb_set_errinfo(Qnil);
    JSValue j_error = j_error_from_ruby_error(ctx, r_error);
    JS_Throw(ctx, j_error);
    return NULL;
  }

  if (NIL_P(r_return) || r_return == Qfalse)
  {
    JS_ThrowReferenceError(ctx, "module loader returned no source for '%s'", name);
    return NULL;
  }

  VALUE r_canonical, r_source;
  if (RB_TYPE_P(r_return, T_STRING))
  {
    r_canonical = r_specifier;
    r_source = r_return;
  }
  else if (RB_TYPE_P(r_return, T_HASH))
  {
    r_source = rb_hash_aref(r_return, ID2SYM(rb_intern("code")));
    r_canonical = rb_hash_aref(r_return, ID2SYM(rb_intern("as")));
    if (!RB_TYPE_P(r_canonical, T_STRING))
    {
      JS_ThrowTypeError(ctx, "module loader Hash must include as: (String, the canonical module name)");
      return NULL;
    }
    // `code:` is optional: omitting it makes the Hash a pure redirect, "resolve
    // this specifier to `as:`", which is meaningful exactly when that module is
    // already in the map and has no source left to provide. Requiring it would
    // force importmap-style loaders to invent a source value nothing reads.
    if (!NIL_P(r_source) && !RB_TYPE_P(r_source, T_STRING))
    {
      JS_ThrowTypeError(ctx, "module loader Hash code: must be a String (the module source), or omitted to redirect to as:");
      return NULL;
    }
  }
  else
  {
    JS_ThrowTypeError(ctx, "module loader must return a String, a Hash with code: and as:, or nil; got %s",
                      rb_obj_classname(r_return));
    return NULL;
  }

  // The loader can also land on a preloaded module the long way round: an
  // importmap-style scope maps a bare specifier to a canonical that was
  // preloaded. QuickJS finds it in ctx->loaded_modules and never calls the
  // load hook, so stashing the source it just handed us would leave an entry
  // nothing ever clears.
  if (!NIL_P(r_source) && !RTEST(rb_hash_aref(data->preloaded_module_names, r_canonical)))
    rb_hash_aset(data->module_source_cache, r_canonical, r_source);
  rb_hash_aset(data->module_resolution_cache, r_key, r_canonical);

  return js_strdup(ctx, StringValueCStr(r_canonical));
}

static JSModuleDef *quickjsrb_module_loader(JSContext *ctx, const char *module_name, void *opaque, JSValueConst attributes)
{
  VMData *data = JS_GetContextOpaque(ctx);

  VALUE r_canonical = rb_str_new_cstr(module_name);
  VALUE r_source = rb_hash_aref(data->module_source_cache, r_canonical);
  if (NIL_P(r_source))
  {
    // Reachable through a redirect: a Hash without `code:` resolves a specifier
    // onto another canonical without providing any source, which only works if
    // that module is already loaded — and if it were, QuickJS would have found
    // it and never called this hook. For every other path normalize stashes a
    // source on the way past, so arriving here means the redirect dangled.
    JS_ThrowReferenceError(ctx, "module loader has no source for '%s': a Hash without code: redirects to an already-loaded module, and this one isn't loaded", module_name);
    return NULL;
  }
  // QuickJS won't call load again for this canonical — its own module cache
  // takes over — so the source is dead weight once we've compiled it.
  rb_hash_delete(data->module_source_cache, r_canonical);

  JSValue j_func = JS_Eval(ctx, RSTRING_PTR(r_source), RSTRING_LEN(r_source), module_name,
                           JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(j_func))
    return NULL;

  js_module_set_import_meta(ctx, j_func, FALSE, FALSE);
  JSModuleDef *m = JS_VALUE_GET_PTR(j_func);
  JS_FreeValue(ctx, j_func);
  return m;
}

// When no Ruby loader is set we hand resolution back to QuickJS's defaults
// (URL-style normalize + filesystem load). When a loader is set we own both
// phases so we can thread (specifier, importer) through and honor `as:`.
static void register_module_loader_funcs(VMData *data)
{
  JSRuntime *runtime = JS_GetRuntime(data->context);
  if (NIL_P(data->module_loader))
    JS_SetModuleLoaderFunc2(runtime, NULL, js_module_loader, js_module_check_attributes, NULL);
  else
    JS_SetModuleLoaderFunc2(runtime, quickjsrb_module_normalize, quickjsrb_module_loader, js_module_check_attributes, NULL);
}

static VALUE r_exception_from_js_reason(JSContext *ctx, JSValueConst j_reason)
{
  if (JS_IsError(ctx, j_reason))
  {
    VALUE r_maybe_ruby_error = find_ruby_error(ctx, j_reason);
    if (!NIL_P(r_maybe_ruby_error))
      return r_maybe_ruby_error;

    JSValue j_name = JS_GetPropertyStr(ctx, j_reason, "name");
    JSValue j_message = JS_GetPropertyStr(ctx, j_reason, "message");
    JSValue j_stack = JS_GetPropertyStr(ctx, j_reason, "stack");
    const char *name = JS_ToCString(ctx, j_name);
    const char *message = JS_ToCString(ctx, j_message);
    const char *stack = JS_ToCString(ctx, j_stack);

    VALUE r_class = is_native_error_name(name)
                        ? QUICKJSRB_ERROR_FOR(name)
                        : QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR);
    VALUE r_exc = rb_funcall(r_class, rb_intern("new"), 2,
                             rb_str_new2(message), rb_str_new2(name));
    VALUE r_backtrace = r_backtrace_from_js_stack(stack);
    if (!NIL_P(r_backtrace))
      rb_funcall(r_exc, rb_intern("set_backtrace"), 1, r_backtrace);

    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, message);
    if (stack)
      JS_FreeCString(ctx, stack);
    JS_FreeValue(ctx, j_name);
    JS_FreeValue(ctx, j_message);
    JS_FreeValue(ctx, j_stack);
    return r_exc;
  }

  const char *str = JS_ToCString(ctx, j_reason);
  VALUE r_exc = rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"),
                           2, rb_str_new2(str ? str : "(non-stringifiable rejection)"), Qnil);
  if (str)
    JS_FreeCString(ctx, str);
  return r_exc;
}

struct rejection_call_args
{
  VALUE proc;
  VALUE r_reason;
};

static VALUE r_rejection_call(VALUE r_args_val)
{
  struct rejection_call_args *args = (struct rejection_call_args *)r_args_val;
  return rb_funcall(args->proc, rb_intern("call"), 1, args->r_reason);
}

static void quickjsrb_promise_rejection_tracker(
    JSContext *ctx, JSValueConst promise, JSValueConst reason,
    JS_BOOL is_handled, void *opaque)
{
  if (is_handled)
    return;

  VMData *data = JS_GetContextOpaque(ctx);
  if (NIL_P(data->on_unhandled_rejection))
    return;

  VALUE r_reason = r_exception_from_js_reason(ctx, reason);
  struct rejection_call_args args = {data->on_unhandled_rejection, r_reason};
  int state;
  rb_protect(r_rejection_call, (VALUE)&args, &state);
  if (state)
  {
    // Longjmping out of a QuickJS host callback corrupts the runtime, so
    // a raise inside the user's tracker has to be dropped on the floor.
    rb_set_errinfo(Qnil);
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
  // func_data[0] holds the Ruby Symbol ID for the defined function (stored by
  // vm_m_defineGlobalFunction). Looking up by ID avoids a JS_ToCString +
  // rb_intern round-trip on every call.
  int64_t key_id;
  JS_ToInt64(ctx, &key_id, func_data[0]);

  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_proc = rb_hash_aref(data->defined_functions, ID2SYM((ID)key_id));
  // Shouldn't happen
  if (r_proc == Qnil)
  {
    return JS_ThrowReferenceError(ctx, "Proc is not defined");
  }

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

// The single way the on_log listener is invoked. Called under rb_protect by
// dispatch_log (uncaught-error headline rows) and unprotected — the caller's
// outer rb_protect covers it — by r_build_and_dispatch_log (console rows).
static VALUE r_call_log_listener(VALUE r_args)
{
  VALUE r_listener = RARRAY_AREF(r_args, 0);
  VALUE r_log = RARRAY_AREF(r_args, 1);
  return rb_funcall(r_listener, rb_intern("call"), 1, r_log);
}

static int dispatch_log(VMData *data, const char *severity, VALUE r_row)
{
  if (NIL_P(data->log_listener))
    return 0;

  VALUE r_log = r_log_new(severity, r_row);
  VALUE r_args = rb_ary_new3(2, data->log_listener, r_log);
  int error;
  rb_protect(r_call_log_listener, r_args, &error);
  return error;
}

static VALUE vm_m_on_log(VALUE r_self)
{
  rb_need_block();

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  data->log_listener = rb_block_proc();

  return Qnil;
}

struct quickjsrb_log_call
{
  JSContext *ctx;
  int argc;
  JSValueConst *argv;
  const char *severity;
  JSValue result;
};

// Runs under rb_protect (see js_quickjsrb_log_inner) so no Ruby raise —
// to_rb_value on an unconvertible argument (e.g. a Promise nested inside an
// array), allocation failure, or the user's on_log listener — can longjmp
// through QuickJS's interpreter frames, or, on the pure path (where this
// runs inside rb_thread_call_with_gvl), across the rb_thread_call_without_gvl
// region — which would leak its buffers and leave gvl_released_js stuck.
static VALUE r_build_and_dispatch_log(VALUE r_call)
{
  struct quickjsrb_log_call *call = (struct quickjsrb_log_call *)r_call;
  JSContext *ctx = call->ctx;
  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_row = rb_ary_new();
  for (int i = 0; i < call->argc; i++)
  {
    JSValueConst j_logged = call->argv[i];
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

    rb_ary_push(r_row, r_log_body_new(r_raw, r_c));
  }

  r_call_log_listener(rb_ary_new3(2, data->log_listener, r_log_new(call->severity, r_row)));
  return Qnil;
}

// Requires the GVL. A caught Ruby exception (from row building or the
// listener) becomes a JS throw, so it unwinds through QuickJS as a regular
// JS exception instead of a cross-boundary longjmp.
static JSValue js_quickjsrb_log_inner(JSContext *ctx, int argc, JSValueConst *argv, const char *severity)
{
  struct quickjsrb_log_call call = {ctx, argc, argv, severity, JS_UNDEFINED};
  int error;
  rb_protect(r_build_and_dispatch_log, (VALUE)&call, &error);
  if (error)
  {
    VALUE r_error = rb_errinfo();
    rb_set_errinfo(Qnil);
    JSValue j_error = j_error_from_ruby_error(ctx, r_error);
    return JS_Throw(ctx, j_error);
  }
  return JS_UNDEFINED;
}

static void *quickjsrb_log_with_gvl(void *p)
{
  struct quickjsrb_log_call *c = p;
  VMData *data = JS_GetContextOpaque(c->ctx);
  // The GVL is held for the duration of this callback. Clear the flag so
  // JS re-entered from the on_log listener (a bridged eval_code, call,
  // eval_bytecode, ...) routes its console.log inline — with the flag
  // still true it would call rb_thread_call_with_gvl while already holding
  // the GVL, which MRI aborts on. A plain save/restore pair suffices: the
  // listener can't longjmp out (js_quickjsrb_log_inner rb_protects
  // everything it runs).
  bool prev = data->gvl_released_js;
  data->gvl_released_js = false;
  c->result = js_quickjsrb_log_inner(c->ctx, c->argc, c->argv, c->severity);
  data->gvl_released_js = prev;
  return NULL;
}

// Dispatcher: when the caller released the GVL around JS_Eval (see
// vm_m_evalCode pure-path), Ruby APIs can't be touched directly. Re-acquire
// the GVL via rb_thread_call_with_gvl before running the row-building body.
// When the GVL is already held, call the body inline to avoid the re-acquire
// overhead.
static JSValue js_quickjsrb_log(JSContext *ctx, int argc, JSValueConst *argv, const char *severity)
{
  VMData *data = JS_GetContextOpaque(ctx);
  // With no listener registered the built row would be discarded, so skip
  // the whole pipeline — most importantly the GVL re-acquire below, which
  // would otherwise turn every console.log of a log-heavy pure-path script
  // into a full GVL round-trip for nothing. This deliberately also skips
  // argument stringification (getters / toString / to_rb_value) and its
  // side effects or failures: console.log with no listener is a true
  // no-op. Reading a VALUE field for a Qnil comparison is a plain aligned
  // pointer-sized read, safe without the GVL; a racing on_log registration
  // (which itself requires the GVL) at worst drops this one row.
  if (NIL_P(data->log_listener))
    return JS_UNDEFINED;
  if (data->gvl_released_js)
  {
    struct quickjsrb_log_call c = {ctx, argc, argv, severity, JS_UNDEFINED};
    rb_thread_call_with_gvl(quickjsrb_log_with_gvl, &c);
    return c.result;
  }
  return js_quickjsrb_log_inner(ctx, argc, argv, severity);
}

static JSValue js_console_info(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, argc, argv, "info");
}

static JSValue js_console_verbose(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, argc, argv, "verbose");
}

static JSValue js_console_warn(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, argc, argv, "warning");
}

static JSValue js_console_error(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
  return js_quickjsrb_log(ctx, argc, argv, "error");
}

// Run bytecode load + eval without the GVL so background threads (warmer
// pools populating VMs, per-thread Runnable#run) proceed in parallel with
// the main thread on multi-core hosts.
//
// Four call sites use the run_bytecode_release_gvl wrapper below:
//
//   1. vm_m_initialize — pre-built polyfill bytecode (file / encoding /
//      url) embedded as static C constants. setTimeout (FEATURE_TIMEOUT)
//      and the File proxy (POLYFILL_FILE, registered ahead of the
//      encoding/url loads) can already be live here, so the release is
//      safe not because nothing is registered, but because a load never
//      runs bridge code: js_quickjsrb_set_timeout only enqueues (pure C;
//      the Ruby-calling js_delay_and_eval_job runs later, under a
//      GVL-held drain/await), a load never drains the job queue, and the
//      bundled polyfill top-levels (built from polyfills/src in this
//      repo) don't call the File proxy. That audit is the invariant to
//      preserve when rebuilding bundles or reordering vm_m_initialize.
//
//   2. vm_m_loadPolyfillBytecode — bytecode from a Ruby String, copied to
//      a malloc'd buffer first so the buffer survives a GC compact. This
//      bytecode is arbitrary (registered by companion gems), so no audit
//      applies: the caller gates the release on can_eval_gvl_free() to
//      bail whenever a direct-rb_funcall bridge (File proxy, crypto, …)
//      is installed; console.log is covered by js_quickjsrb_log's
//      gvl_released_js re-acquire either way.
//
//   3. vm_m_evalBytecode — user bytecode via Runnable#run, same gate and
//      buffer copy as 2, but with the awaiting runner: js_std_await's job
//      drain is bridge-free under the gate, the same argument eval_code's
//      released path relies on.
//
//   4. vm_m_preloadModuleBytecode — module bytecode from a Ruby String,
//      copied like 2/3, but with the deserialize-only runner
//      (bytecode_read_job_run) and no can_eval_gvl_free gate. A preload
//      registers the module def without running any top level, so no bridge
//      can fire regardless of what's installed — the release is
//      unconditional, and safe even on a bridged VM where 2/3 fall back to
//      the GVL-held path.
//
// run_bytecode_release_gvl delegates to the shared GVL-release region
// (see run_gvl_release_region) so every caller inherits the re-acquire
// safety, the dispose! handshake, and interrupt-proof cleanup
// automatically.
struct bytecode_load_job
{
  JSContext *ctx;
  const uint8_t *buf;
  size_t buf_len;
  JSValue result;
};

// Shared bytecode read + eval core — pure C over JSValues, MUST NOT touch
// the Ruby VM (the polyfill and bytecode-run release paths run it without
// the GVL; the GVL-held call sites invoke it directly).
static void *bytecode_load_job_run(void *p)
{
  struct bytecode_load_job *job = p;
  JSValue obj = JS_ReadObject(job->ctx, job->buf, job->buf_len, JS_READ_OBJ_BYTECODE);
  // JS_EvalFunction on a JS_EXCEPTION input replaces the pending exception
  // with a generic "bytecode function expected" TypeError, losing the actual
  // deserialization diagnostic from JS_ReadObject. Short-circuit instead.
  if (JS_IsException(obj))
  {
    job->result = obj;
    return NULL;
  }
  job->result = JS_EvalFunction(job->ctx, obj); // frees obj
  return NULL;
}

// Awaiting variant of the core, for vm_m_evalBytecode: js_std_await drains
// the job queue until the eval's promise settles. Same MUST-NOT-touch-Ruby
// constraint — on a pure VM (can_eval_gvl_free) every drained job is
// bridge-free JS, the same argument eval_code's released path relies on.
// js_std_await passes a non-promise — including an exception preserved by
// the JS_ReadObject short-circuit — through untouched.
static void *bytecode_eval_await_job_run(void *p)
{
  struct bytecode_load_job *job = p;
  bytecode_load_job_run(job);
  job->result = js_std_await(job->ctx, job->result);
  return NULL;
}

// Deserialize-only variant, for vm_m_preloadModuleBytecode: reads a module
// def into ctx->loaded_modules without evaluating it, so a later import can
// link and run it. Unlike the two runners above this never reaches JS
// execution or the job queue — JS_ReadObject only deserializes, deferring
// import resolution to js_link_module at eval time — so its release needs no
// can_eval_gvl_free gate: there is no top level that could reach a Ruby
// bridge, on any VM. Same MUST-NOT-touch-Ruby constraint all the same.
static void *bytecode_read_job_run(void *p)
{
  struct bytecode_load_job *job = p;
  job->result = JS_ReadObject(job->ctx, job->buf, job->buf_len, JS_READ_OBJ_BYTECODE);
  return NULL;
}

// job_run: bytecode_load_job_run (load only) or bytecode_eval_await_job_run
// (load + await). take_ownership: true when buf is malloc'd storage that
// the release region should free on every exit path (including
// async-interrupt unwinds); false when buf points at static bytecode.
static JSValue run_bytecode_release_gvl(VMData *data, void *(*job_run)(void *), const uint8_t *buf, size_t buf_len, bool take_ownership)
{
  struct bytecode_load_job job = {data->context, buf, buf_len, JS_UNDEFINED};
  run_gvl_release_region(data, job_run, &job, &job.result, take_ownership ? (uint8_t *)buf : NULL, NULL);
  return job.result;
}

// Every polyfill load takes the load-only runner; naming that keeps the
// call sites, which pass their result straight to finish_polyfill_load,
// down to one line.
static JSValue load_polyfill_bytecode(VMData *data, const uint8_t *buf, size_t buf_len, bool take_ownership)
{
  return run_bytecode_release_gvl(data, bytecode_load_job_run, buf, buf_len, take_ownership);
}

// Shared settle check for every polyfill load's result, bundled or
// registered. The compiled bytecode is async-wrapped (JS_EVAL_FLAG_ASYNC),
// so a top-level throw comes back as a rejected promise, not JS_EXCEPTION;
// re-throwing the reason routes it through to_rb_value's standard
// exception path (interrupted/OOM mapping, oom_poisoned latching, on_log
// dispatch). And a top level that awaits is still pending: loads never
// drain the job queue, so nothing past the first await has run — refuse
// loudly instead of shipping a silently half-applied VM; polyfill top
// levels must settle synchronously (the register_polyfill contract).
// That refusal reuses NoAwaitError, the same class eval_code raises for
// a promise left unawaited at the top level.
// Frees j_result on every path.
static void finish_polyfill_load(VMData *data, JSValue j_result)
{
  if (JS_IsException(j_result))
  {
    to_rb_value(data->context, j_result); // raises
    return;
  }

  JSPromiseStateEnum state = JS_PromiseState(data->context, j_result);
  if (state == JS_PROMISE_REJECTED)
  {
    JSValue j_reason = JS_PromiseResult(data->context, j_result);
    JS_FreeValue(data->context, j_result);
    JS_Throw(data->context, j_reason); // consumes j_reason
    to_rb_value(data->context, JS_EXCEPTION); // raises
    return;
  }
  if (state == JS_PROMISE_PENDING)
  {
    JS_FreeValue(data->context, j_result);
    VALUE r_msg = rb_str_new2("polyfill top level must settle synchronously: top-level await leaves the load pending and the polyfill silently half-applied");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_NO_AWAIT_ERROR), rb_intern("new"), 2, r_msg, Qnil));
  }

  JS_FreeValue(data->context, j_result);
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
  data->requested_max_stack_size = (size_t)NUM2ULL(r_max_stack_size);
  JS_SetMaxStackSize(runtime, data->requested_max_stack_size);

  register_module_loader_funcs(data);
  JS_SetHostPromiseRejectionTracker(runtime, quickjsrb_promise_rejection_tracker, NULL);
  js_std_init_handlers(runtime);

  JSValue j_global = JS_GetGlobalObject(data->context);

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featureStdId))))
  {
    js_init_module_std(data->context, "std");
    const char *enableStd = "import * as std from 'std';\n"
                            "globalThis.std = std;\n";
    JSValue j_stdEval = JS_Eval(data->context, enableStd, strlen(enableStd), vmInternalFilename, JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, j_stdEval);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featureOsId))))
  {
    js_init_module_os(data->context, "os");
    const char *enableOs = "import * as os from 'os';\n"
                           "globalThis.os = os;\n";
    JSValue j_osEval = JS_Eval(data->context, enableOs, strlen(enableOs), vmInternalFilename, JS_EVAL_TYPE_MODULE);
    JS_FreeValue(data->context, j_osEval);
  }
  else if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featureTimeoutId))))
  {
    // setTimeout itself only enqueues, but js_delay_and_eval_job (the
    // enqueued callback) calls rb_funcall and rb_thread_wait_for
    // synchronously while js_std_await drains the queue — so this counts
    // as a Ruby bridge and eval must keep the GVL.
    JS_SetPropertyStr(
        data->context, j_global, "setTimeout",
        quickjsrb_new_ruby_bridge(data->context, js_quickjsrb_set_timeout, "setTimeout", 2));
  }

  // finish_polyfill_load raises (Ruby longjmp) on a load that fails or
  // doesn't settle, so nothing holding a JSValue may stay live across the
  // loads: the free at the bottom of this function would be skipped and
  // the leaked reference pins its whole object graph past JS_FreeRuntime
  // (the teardown GC only reclaims what's internally referenced, and the
  // gc_obj_list assert is compiled out by -DNDEBUG). Drop the global here
  // and re-acquire it below.
  JS_FreeValue(data->context, j_global);

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillFileId))))
  {
    finish_polyfill_load(data, load_polyfill_bytecode(data, &qjsc_polyfill_file_min, qjsc_polyfill_file_min_size, false));

    quickjsrb_init_file_proxy(data);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillEncodingId))))
  {
    finish_polyfill_load(data, load_polyfill_bytecode(data, &qjsc_polyfill_encoding_min, qjsc_polyfill_encoding_min_size, false));
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillUrlId))))
  {
    finish_polyfill_load(data, load_polyfill_bytecode(data, &qjsc_polyfill_url_min, qjsc_polyfill_url_min_size, false));
  }

  j_global = JS_GetGlobalObject(data->context);

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillCryptoId))))
  {
    quickjsrb_init_crypto(data->context, j_global);
  }

  // console and the remaining host callbacks are registered below this
  // point. setTimeout and the File proxy above predate the GVL-released
  // polyfill loads only under the audit described at
  // run_bytecode_release_gvl — re-read it before reordering this function
  // or registering anything else above the loads.
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

static VALUE to_rb_return_value(JSContext *ctx, JSValue j_val)
{
  if (JS_VALUE_GET_NORM_TAG(j_val) == JS_TAG_OBJECT && JS_PromiseState(ctx, j_val) != -1)
  {
    JS_FreeValue(ctx, j_val);
    VALUE r_error_message = rb_str_new2("An unawaited Promise was returned to the top-level");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_NO_AWAIT_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
    return Qnil;
  }
  VALUE result = to_rb_value(ctx, j_val);
  JS_FreeValue(ctx, j_val);
  return result;
}

static void check_oom_poisoned(VMData *data)
{
  if (data->oom_poisoned)
  {
    VALUE r_msg = rb_str_new2("VM is poisoned: a previous evaluation hit out-of-memory; further evaluation may segfault. Recreate the Quickjs::VM.");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_msg, Qnil));
  }
}

static void check_disposed(VMData *data)
{
  if (data->disposed)
  {
    VALUE r_msg = rb_str_new2("VM has been disposed; create a new Quickjs::VM");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_msg, Qnil));
  }
}

// Validate that r_code is a String and resolve the :filename option (default "<code>")
// from the keyword-args hash that rb_scan_args(... "1:") collects. Both eval_code and
// compile share this argument shape.
static const char *parse_code_and_filename(VALUE r_code, VALUE r_opts)
{
  if (!RB_TYPE_P(r_code, T_STRING))
  {
    VALUE r_code_class = rb_class_name(CLASS_OF(r_code));
    rb_raise(rb_eTypeError, "JavaScript code must be a String, got %s", StringValueCStr(r_code_class));
  }
  if (NIL_P(r_opts))
    return "<code>";
  VALUE r_filename = rb_hash_aref(r_opts, ID2SYM(rb_intern("filename")));
  if (NIL_P(r_filename))
    return "<code>";
  Check_Type(r_filename, T_STRING);
  return StringValueCStr(r_filename);
}

static void arm_eval_timer(VMData *data)
{
  clock_gettime(CLOCK_MONOTONIC, &data->eval_time->started_at);
  JS_SetInterruptHandler(JS_GetRuntime(data->context), interrupt_handler, data->eval_time);
}

// Pure-path predicate: true when no JS→Ruby bridge can fire during eval
// other than console.log (which is handled by js_quickjsrb_log's
// gvl_released_js re-acquire). When true, eval can safely run with the
// GVL released so other Ruby threads make progress on different cores.
// C-function bridges registered via quickjsrb_new_ruby_bridge (crypto.*,
// File proxy, setTimeout) call rb_funcall directly — those would need to
// learn the gvl_released_js pattern before they can run under a released
// GVL, so we hold the GVL when any of them is installed.
//
// :feature_std / :feature_os intentionally pass: quickjs-libc never calls
// into Ruby, and its state is almost entirely per-runtime (JSThreadState).
// The exceptions are two file-scope globals reachable from niche APIs —
// `oldtty` (os.ttySetRaw) and `os_pending_signals` (os.signal) — which can
// race when multiple VMs run those APIs concurrently. Gating the whole
// feature would re-serialize os.sleep / os.setTimeout across threads, so
// the constraint is documented in the README instead.
static bool can_eval_gvl_free(VMData *data)
{
  return RHASH_SIZE(data->defined_functions) == 0
      && NIL_P(data->module_loader)
      && NIL_P(data->on_unhandled_rejection)
      && !data->has_native_ruby_bridge;
}

struct eval_code_job
{
  JSContext *ctx;
  const char *code;
  size_t code_len;
  const char *filename;
  bool async_mode;
  JSValue result;
};

// Shared eval core: JS_Eval (+ js_std_await and the {value, done} unwrap for
// async). Pure C over JSValues — MUST NOT touch the Ruby VM, because the
// pure path runs it with the GVL released (see js_quickjsrb_log's dispatcher
// for how console.log re-acquires). The bridged path calls it directly with
// the GVL held; both paths share this body so a future fix to the eval
// sequence can't silently diverge between them.
static void *eval_code_job_run(void *p)
{
  struct eval_code_job *job = p;
  int eval_flags = job->async_mode ? (JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC) : JS_EVAL_TYPE_GLOBAL;
  JSValue j_codeResult = JS_Eval(job->ctx, job->code, job->code_len, job->filename, eval_flags);
  if (job->async_mode)
  {
    JSValue j_awaitedResult = js_std_await(job->ctx, j_codeResult); // frees j_codeResult
    job->result = JS_GetPropertyStr(job->ctx, j_awaitedResult, "value");
    JS_FreeValue(job->ctx, j_awaitedResult);
  }
  else
  {
    job->result = j_codeResult;
  }
  return NULL;
}

// Opens a JS entry on this VM, or refuses if another thread already has one
// open. README's "one VM, one thread at a time" rule stops being advisory
// here: QuickJS contexts have no internal locking, so two threads inside
// JS_Eval on the same context corrupt the heap, and since eval can release
// the GVL they really do run at the same time rather than interleaving by
// accident.
//
// A mutex would be the wrong instrument twice over. Held across the release
// it deadlocks — the unlock lives after rb_thread_call_without_gvl
// re-acquires the GVL, so a second thread blocks in pthread_mutex_lock
// while holding the GVL and the first can never get back in to release it.
// And a plain mutex self-deadlocks on the nesting this codebase relies on,
// where an on_log listener inside a released region re-enters the same VM
// on the same thread. Comparing the owner has neither problem: it lets
// nesting through by construction and needs no lock at all.
// Split from the raise so callers holding malloc'd state can test first and
// clean up before unwinding (run_gvl_release_region owns input buffers by
// the time it asks).
static bool js_entry_owned_elsewhere(VMData *data)
{
  return data->evals_in_flight > 0 && data->owner_thread != rb_thread_current();
}

static void refuse_cross_thread_entry(VMData *data)
{
  rb_raise(rb_eThreadError,
           "cannot use a Quickjs::VM from two threads at once; it is already evaluating on %+" PRIsVALUE,
           data->owner_thread);
}

// Entry-point guard, sitting next to check_disposed. enter_js_entry alone is
// not enough: several entry points read or mutate runtime state before they
// reach a counted region — JS_IsJobPending in drain_jobs!, arm_eval_timer
// almost everywhere, JS_SetModuleLoaderFunc2 in compile_module — and those
// touches are already unsafe against another thread's in-flight JS.
static void check_js_entry_owner(VMData *data)
{
  if (js_entry_owned_elsewhere(data))
    refuse_cross_thread_entry(data);
}

static void enter_js_entry(VMData *data)
{
  if (js_entry_owned_elsewhere(data))
    refuse_cross_thread_entry(data);

  // After the refusal and before the count, in that order for two reasons.
  // The re-base mutates rt->stack_top, which another thread's in-flight JS is
  // checking itself against, so a caller about to be turned away must not have
  // touched it. And rebase_stack_limit reads evals_in_flight to recognise the
  // outermost entry, which the increment below is about to spoil.
  rebase_stack_limit(data);

  data->owner_thread = rb_thread_current();
  data->evals_in_flight++;
}

// Balances enter_js_entry. Clearing the owner only as the outermost entry
// closes is what lets a VM be handed between threads sequentially, which
// the README allows and pool warmers depend on.
static void leave_js_entry(VMData *data)
{
  if (--data->evals_in_flight == 0)
    data->owner_thread = Qnil;
}

// A GVL-release region — the one place that owns the handshake required to
// run a pure-C QuickJS job with the GVL released: the save/restore of
// gvl_released_js (restore, not clear, so a region nested through an
// on_log listener doesn't flip the outer region's console.log back to the
// inline path), the evals_in_flight increment that makes dispose! refuse,
// the stale-dispose re-check, and an rb_ensure cleanup that keeps all of
// it balanced when an async interrupt (Thread#raise / Thread#kill /
// Timeout) fires in rb_thread_call_without_gvl's GVL-re-acquire epilogue.
struct gvl_release_region
{
  VMData *data;
  void *(*job_run)(void *); // pure C over JSValues — must not touch Ruby
  void *job;
  // Where the job stores its JSValue result; the cleanup frees it when an
  // interrupt lands inside the region (no-op for JS_UNDEFINED).
  JSValue *j_result;
  // malloc'd inputs owned by the region so they survive an interrupt
  // unwinding past the caller's own frees; NULL slots are fine.
  void *owned_bufs[2];
  bool prev_gvl_released;
  bool completed;
};

static VALUE gvl_release_region_run(VALUE p)
{
  struct gvl_release_region *region = (struct gvl_release_region *)p;
  rb_thread_call_without_gvl(region->job_run, region->job, NULL, NULL);
  region->completed = true;
  return Qnil;
}

static VALUE gvl_release_region_cleanup(VALUE p)
{
  struct gvl_release_region *region = (struct gvl_release_region *)p;
  VMData *data = region->data;
  data->gvl_released_js = region->prev_gvl_released;
  leave_js_entry(data);
  data->gvl_release_regions--;
  free(region->owned_bufs[0]);
  free(region->owned_bufs[1]);
  // Frees the result when the interrupt landed after the job ran but
  // before the run function marked completion. An interrupt during the
  // caller's subsequent Ruby conversion can still leak the result — the
  // same (accepted) exposure every GVL-held path has always had.
  if (!region->completed)
    JS_FreeValue(data->context, *region->j_result);
  return Qnil;
}

// How much stack the calling thread still has below this frame, or 0 when the
// platform won't say. Both calls are non-POSIX, and the two the CI matrix
// covers are the two spelled out here; anywhere else answers 0, which
// rebase_stack_limit reads as "leave this VM alone".
static size_t current_thread_stack_headroom(void)
{
  uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
  uintptr_t low = 0, high = 0;
#if defined(__APPLE__)
  pthread_t self = pthread_self();
  // Apple reports the address one past the top of the stack, growing down.
  high = (uintptr_t)pthread_get_stackaddr_np(self);
  size_t size = pthread_get_stacksize_np(self);
  if (high == 0 || size == 0 || size > high)
    return 0;
  low = high - size;
#elif defined(__linux__)
  pthread_attr_t attr;
  if (pthread_getattr_np(pthread_self(), &attr) != 0)
    return 0;
  void *base;
  size_t size;
  int rc = pthread_attr_getstack(&attr, &base, &size);
  pthread_attr_destroy(&attr);
  if (rc != 0 || base == NULL || size == 0)
    return 0;
  low = (uintptr_t)base;
  high = low + size;
#else
  return 0;
#endif
  // Both bounds, not just the lower one. A Ruby Fiber runs on its own mmap'd
  // stack, and where the allocator puts it relative to the thread stack is not
  // ours to predict: below it, sp <= low and the old check already answered 0;
  // above it, sp - low measures across unrelated mappings and reports headroom
  // that is not there. Believing it would re-base onto the fiber with a budget
  // sized for another stack, which is the crash this function exists to avoid.
  return (sp > low && sp < high) ? (size_t)(sp - low) : 0;
}

// Room left for QuickJS to report the overflow and for Ruby to unwind through
// the bridge frames above it once it does. The check itself only compares the
// frame pointer, so the margin has to cover everything that still has to run
// after it fires.
#define QUICKJSRB_STACK_MARGIN (256 * 1024)

// QuickJS latches rt->stack_top from whichever thread called JS_NewRuntime and
// never revisits it, so rt->stack_limit (stack_top - stack_size) keeps pointing
// into that thread's stack for the life of the VM. Evaluate from a thread whose
// stack sits below that limit and js_check_stack_overflow trips on its very
// first check, reporting "stack overflow" on code as trivial as 1 + 1.
//
// Whether it fires is luck of where the OS put the two stacks: on macOS the gap
// stays under the 4MB default, so the handoff README.md:472 promises appears to
// work, while on Linux every cross-thread eval raises.
//
// Re-basing alone would trade that for something worse. A Ruby thread's machine
// stack is a fraction of the main thread's, so a 4MB budget re-based onto one
// outlives the stack it is measuring: Ruby's guard page is reached first and the
// eval dies with SystemStackError instead of QuickJS raising. Base and budget
// therefore move together, or not at all.
//
// Not at all is a real case. pthread reports the *thread's* stack, and a Ruby
// Fiber runs on its own mmap'd one outside those bounds, as do Enumerator and
// every fiber scheduler; the query returns 0 there, and on platforms with
// neither call it always does. Re-basing without being able to clamp is the
// worst of the three outcomes, so an unmeasurable stack leaves the VM exactly
// as it was: still latched to its creating thread, still the pre-existing
// behaviour, and no new way to run off the end of a stack.
//
// Outermost entry only: a nested one (a bridge re-entering its own VM, an
// on_log listener evaluating) sits deeper on the same stack, and re-basing
// there would hand it a fresh full budget, removing the guard exactly where
// runaway recursion is what needs catching.
static void rebase_stack_limit(VMData *data)
{
  if (data->evals_in_flight != 0)
    return;

  size_t headroom = current_thread_stack_headroom();
  if (headroom == 0)
    return; // cannot measure this stack, so do not start describing it

  JSRuntime *runtime = JS_GetRuntime(data->context);
  JS_UpdateStackTop(runtime);

  if (data->requested_max_stack_size == 0)
    return; // caller asked for no limit; honour it

  // Below the margin there is no budget worth granting: clamping to what is
  // left makes the first check fire and raise, which beats running on into
  // the guard page.
  size_t usable = headroom > QUICKJSRB_STACK_MARGIN ? headroom - QUICKJSRB_STACK_MARGIN : 1;
  JS_SetMaxStackSize(runtime, usable < data->requested_max_stack_size ? usable : data->requested_max_stack_size);
}

// Run job_run(job) with the GVL released. owned_buf0/1 are malloc'd
// buffers backing the job's inputs; ownership transfers to the region,
// which frees them on every exit path — including the disposed bail-out
// below and async-interrupt unwinds. The caller's check_disposed may be
// stale by now (argument parsing can yield the GVL to a concurrent
// dispose!), so re-check here: nothing between this check and the release
// yields, and dispose! refuses while evals_in_flight > 0, so the two
// sides can't miss each other.

static void run_gvl_release_region(VMData *data, void *(*job_run)(void *), void *job, JSValue *j_result, void *owned_buf0, void *owned_buf1)
{
  // Both refusals have to happen before the buffers are handed to the
  // region, since the rb_ensure that would free them is not armed yet.
  if (data->disposed || js_entry_owned_elsewhere(data))
  {
    free(owned_buf0);
    free(owned_buf1);
    check_disposed(data);            // raises when disposed
    refuse_cross_thread_entry(data); // otherwise it was the owner check
  }

  struct gvl_release_region region = {
      .data = data,
      .job_run = job_run,
      .job = job,
      .j_result = j_result,
      .owned_bufs = {owned_buf0, owned_buf1},
      .prev_gvl_released = data->gvl_released_js,
      .completed = false,
  };

  enter_js_entry(data); // cannot raise: the check above already passed
  data->gvl_release_regions++;
  data->gvl_released_js = true;
  rb_ensure(gvl_release_region_run, (VALUE)&region, gvl_release_region_cleanup, (VALUE)&region);
}

// Installing a JS→Ruby bridge (define_function, module_loader=,
// on_unhandled_rejection) invalidates the can_eval_gvl_free decision an
// in-flight GVL-released eval was started under: after e.g. an on_log
// listener returns, the still-running JS could reach the new bridge and
// call Ruby APIs without holding the GVL. Refuse loudly — register
// bridges before evaluating. Registration during GVL-held evals stays
// allowed, as it always was: gvl_release_regions only counts released
// regions.
static void check_no_gvl_release_in_flight(VMData *data)
{
  if (data->gvl_release_regions > 0)
    rb_raise(rb_eThreadError, "cannot install a JS-to-Ruby bridge on a Quickjs::VM while it is evaluating with the GVL released");
}

static VALUE evals_in_flight_release(VALUE p)
{
  leave_js_entry((VMData *)p);
  return Qnil;
}

// Counterpart of run_gvl_release_region for the GVL-held entry points:
// bridge callbacks (define_function procs, setTimeout's rb_thread_wait_for,
// on_log listeners) yield the GVL mid-execution, so every JS execution must
// elevate evals_in_flight for dispose! to refuse — and the decrement must
// survive every raise exit: JS exceptions, type errors, conversion
// failures, and async interrupts (Thread#raise / Timeout) delivered inside
// a bridge callback. A stranded counter would make dispose! refuse forever,
// so the check + increment + rb_ensure discipline lives here structurally
// rather than being repeated at each call site. Entry points may have run
// argument parsing that yields the GVL since their own entry check, hence
// the disposed re-check immediately before counting. (The interrupt longjmp
// still rips through QuickJS frames — a pre-existing hazard; whether the
// bridge should rb_protect and convert instead is a semantics decision
// deferred in the #56 review.)
static VALUE run_held_js_entry(VMData *data, VALUE (*body)(VALUE), VALUE arg)
{
  check_disposed(data);
  // Raises before the ensure is armed, which is safe here: unlike the
  // release region, this path owns no malloc'd state at this point.
  enter_js_entry(data);
  return rb_ensure(body, arg, evals_in_flight_release, (VALUE)data);
}

static VALUE eval_code_job_run_body(VALUE p)
{
  eval_code_job_run((struct eval_code_job *)p);
  return Qnil;
}

// rb_ensure bodies over the shared bytecode core, for the GVL-held call
// sites: vm_m_loadPolyfillBytecode's held fallback loads without awaiting
// (matching its release path), vm_m_evalBytecode awaits the result. These
// can take RSTRING_PTR without a copy: JS_ReadObject consumes the buffer
// before any bridge can fire, so the GVL is provably held (no compaction)
// for as long as the pointer is read.
static VALUE bytecode_load_body(VALUE p)
{
  bytecode_load_job_run((struct bytecode_load_job *)p);
  return Qnil;
}

static VALUE bytecode_eval_await_body(VALUE p)
{
  bytecode_eval_await_job_run((struct bytecode_load_job *)p);
  return Qnil;
}

// Copy a Ruby String to a malloc'd buffer that outlives a GVL release —
// RSTRING_PTR is GC-movable, so a released region must not read the
// String's own storage. Ownership passes to the caller (the release
// regions free it on every exit path). nul_terminate preserves the
// sentinel NUL QuickJS's parser reads past the length: Ruby strings carry
// one past RSTRING_LEN, so GVL-held paths get it for free, and a copy
// must add it back. Allocates at least one byte either way — malloc(0)
// may return NULL on success, and an empty String (e.g. empty bytecode)
// must still reach the JS-level diagnostic instead of a spurious
// NoMemError.
static char *copy_rstring_to_owned_buffer(VALUE r_str, size_t *out_len, bool nul_terminate)
{
  size_t len = (size_t)RSTRING_LEN(r_str);
  char *buf = malloc(nul_terminate ? len + 1 : (len > 0 ? len : 1));
  if (buf == NULL)
    rb_raise(rb_eNoMemError, "failed to allocate a GVL-release copy of a Ruby String");
  memcpy(buf, RSTRING_PTR(r_str), len);
  if (nul_terminate)
    buf[len] = '\0';
  *out_len = len;
  return buf;
}

// Run the eval core without the GVL. Inputs are copied to malloc'd buffers
// because RSTRING_PTR can be invalidated by GC compaction while we're
// released.
static VALUE eval_code_release_gvl(VMData *data, VALUE r_code, const char *filename, bool async_mode)
{
  size_t code_len;
  char *code_buf = copy_rstring_to_owned_buffer(r_code, &code_len, true);

  char *filename_buf = strdup(filename);
  if (filename_buf == NULL)
  {
    free(code_buf);
    rb_raise(rb_eNoMemError, "failed to allocate eval filename buffer");
  }

  struct eval_code_job job = {
      .ctx = data->context,
      .code = code_buf,
      .code_len = code_len,
      .filename = filename_buf,
      .async_mode = async_mode,
      .result = JS_UNDEFINED,
  };
  run_gvl_release_region(data, eval_code_job_run, &job, &job.result, code_buf, filename_buf);

  return to_rb_return_value(data->context, job.result);
}

static VALUE vm_m_evalCode(int argc, VALUE *argv, VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  VALUE r_code, r_opts;
  rb_scan_args(argc, argv, "1:", &r_code, &r_opts);
  const char *filename = parse_code_and_filename(r_code, r_opts);

  bool async_mode = true;
  if (!NIL_P(r_opts))
  {
    VALUE r_async = rb_hash_aref(r_opts, ID2SYM(rb_intern("async")));
    if (r_async == Qfalse)
      async_mode = false;
  }

  // Argument parsing allocates, so it can yield the GVL to a concurrent
  // dispose! that leaves data->context dangling — and arm_eval_timer
  // dereferences the runtime, which puts it ahead of both the release
  // region's own re-check and run_held_js_entry's. Nothing between here and
  // the release yields (StringValue can't coerce: parse_code_and_filename
  // already refused a non-String), and dispose! refuses once either of those
  // has counted us, so re-checking here closes the window on both paths.
  check_disposed(data);
  // Ownership needs the same re-check as disposal, and for the same reason:
  // the parsing above yields, so another thread can have taken the VM since
  // the check at entry. arm_eval_timer writes the shared eval_time, so
  // without this it would reset the budget of the eval that thread is
  // already running — the counted regions below refuse, but only after.
  check_js_entry_owner(data);
  arm_eval_timer(data);

  StringValue(r_code);

  if (can_eval_gvl_free(data))
    return eval_code_release_gvl(data, r_code, filename, async_mode);

  // Bridged path: a JS→Ruby bridge (define_function / module loader /
  // setTimeout / File / crypto) may fire mid-eval, so keep the GVL held and
  // run the shared eval core directly. With the GVL held there's no
  // compaction risk, so RSTRING_PTR is usable without a malloc'd copy.
  struct eval_code_job job = {
      .ctx = data->context,
      .code = RSTRING_PTR(r_code),
      .code_len = (size_t)RSTRING_LEN(r_code),
      .filename = filename,
      .async_mode = async_mode,
      .result = JS_UNDEFINED,
  };
  run_held_js_entry(data, eval_code_job_run_body, (VALUE)&job);
  return to_rb_return_value(data->context, job.result);
}

struct compile_job
{
  JSContext *ctx;
  const char *code;
  size_t code_len;
  const char *filename;
  JSValue result;
};

// Parses to a function object and stops there. Like the preload read, and
// unlike the eval core above, this runs no JS at all, so its release needs
// no can_eval_gvl_free gate — there is no top level that could reach a Ruby
// bridge, on any VM. JS_EVAL_TYPE_GLOBAL is what carries that argument:
// __JS_EvalInternal only resolves imports for the JSModuleDef it builds
// under JS_EVAL_TYPE_MODULE, so no module loader can fire here either. A
// module compile is a different story and gets no such freedom. Same
// MUST-NOT-touch-Ruby constraint as every other released job.
static void *compile_job_run(void *p)
{
  struct compile_job *job = p;
  job->result = JS_Eval(job->ctx, job->code, job->code_len, job->filename,
                        JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC | JS_EVAL_FLAG_COMPILE_ONLY);
  return NULL;
}

// Inputs are copied because RSTRING_PTR can be invalidated by GC compaction
// while we're released, same as eval_code_release_gvl.
static JSValue compile_release_gvl(VMData *data, VALUE r_code, const char *filename)
{
  size_t code_len;
  char *code_buf = copy_rstring_to_owned_buffer(r_code, &code_len, true);

  char *filename_buf = strdup(filename);
  if (filename_buf == NULL)
  {
    free(code_buf);
    rb_raise(rb_eNoMemError, "failed to allocate compile filename buffer");
  }

  struct compile_job job = {
      .ctx = data->context,
      .code = code_buf,
      .code_len = code_len,
      .filename = filename_buf,
      .result = JS_UNDEFINED,
  };
  run_gvl_release_region(data, compile_job_run, &job, &job.result, code_buf, filename_buf);

  return job.result;
}

struct bytecode_serialize_job
{
  VMData *data;
  JSValue j_compiled; // owned here; see compiled_to_bytecode_string for the rule
  uint8_t *out_buf;
  const char *failure_message;
};

static VALUE bytecode_serialize_body(VALUE p)
{
  struct bytecode_serialize_job *job = (struct bytecode_serialize_job *)p;

  size_t out_len;
  job->out_buf = JS_WriteObject(job->data->context, &out_len, job->j_compiled, JS_WRITE_OBJ_BYTECODE);
  if (job->out_buf == NULL)
  {
    VALUE r_msg = rb_str_new2(job->failure_message);
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_msg, Qnil));
  }

  VALUE r_bytecode = rb_str_new((const char *)job->out_buf, (long)out_len);
  rb_enc_associate(r_bytecode, rb_ascii8bit_encoding());
  return rb_obj_freeze(r_bytecode);
}

static VALUE bytecode_serialize_cleanup(VALUE p)
{
  struct bytecode_serialize_job *job = (struct bytecode_serialize_job *)p;

  JS_FreeValue(job->data->context, job->j_compiled);
  if (job->out_buf != NULL)
    js_free(job->data->context, job->out_buf);
  return Qnil;
}

static VALUE bytecode_serialize_held(VALUE p)
{
  return rb_ensure(bytecode_serialize_body, p, bytecode_serialize_cleanup, p);
}

// Serializes a compiled function or module into a frozen ASCII-8BIT String.
// Shared by both compile entry points, and a GVL-held JS entry rather than
// plain inline code for two reasons: rb_str_new allocates, which is a thread
// switch point, so without evals_in_flight elevated a concurrent dispose!
// could free the context between JS_WriteObject and the js_free below; and
// the blob JS_WriteObject hands back is js_malloc'd, so it has to go home
// through js_free to keep the runtime's memory accounting straight — the
// ensure gets it there however the body exits, including an async interrupt
// landing in rb_str_new.
//
// Ownership of j_compiled transfers here in full, but "consumes it" is not
// quite the whole rule, because run_held_js_entry's disposed check raises
// ahead of the rb_ensure that does the freeing. That path frees nothing, and
// must not: dispose! sets disposed before handing the teardown to
// JS_FreeRuntime, so by the time the check fires j_compiled's storage is
// either already reclaimed or being reclaimed concurrently with the GVL
// released, and a JS_FreeValue aimed at it would be a use-after-free rather
// than a cleanup. Nothing leaks either way — the runtime took it. So: freed
// through the context on every exit while the VM is alive, abandoned to the
// teardown once it is not. Unreachable today in any case, since neither
// caller yields the GVL between its compile and this call.
static VALUE compiled_to_bytecode_string(VMData *data, JSValue j_compiled, const char *failure_message)
{
  struct bytecode_serialize_job job = {
      .data = data,
      .j_compiled = j_compiled,
      .out_buf = NULL,
      .failure_message = failure_message,
  };
  return run_held_js_entry(data, bytecode_serialize_held, (VALUE)&job);
}

struct js_exception_job
{
  VMData *data;
  JSValue j_exception;
};

static VALUE js_exception_body(VALUE p)
{
  struct js_exception_job *job = (struct js_exception_job *)p;
  return to_rb_value(job->data->context, job->j_exception); // raises
}

// Turns a thrown JSValue into the Ruby exception it raises, as a counted JS
// entry rather than a bare call. Converting an error is JS execution: it
// reads name, message and stack off the thrown object, and any of the three
// can be an accessor inherited from a prototype the VM's own code has
// replaced. So a parse failure on a VM where something did
//
//   Object.defineProperty(SyntaxError.prototype, 'name', { get: () => boom() })
//
// runs boom() during conversion — and with evals_in_flight back at zero after
// the release region, a dispose! from that bridge was granted and the rest of
// the conversion ran against a freed context. Reproducible SIGSEGV.
//
// The parse half of a compile is counted and the serialize half is counted;
// this is the third tail out of the same function, and it was the one left
// bare.
static VALUE js_exception_to_rb(VMData *data, JSValue j_exception)
{
  struct js_exception_job job = {
      .data = data,
      .j_exception = j_exception,
  };
  return run_held_js_entry(data, js_exception_body, (VALUE)&job);
}

static VALUE vm_m_compile(int argc, VALUE *argv, VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  VALUE r_code, r_opts;
  rb_scan_args(argc, argv, "1:", &r_code, &r_opts);
  const char *filename = parse_code_and_filename(r_code, r_opts);

  // Re-check for the same reason vm_m_evalCode does: argument parsing can
  // yield to a concurrent dispose!, and arm_eval_timer is the first thing
  // here to touch the context.
  //
  // Arming buys a compile nothing: the parser never calls js_poll_interrupts
  // — every call site is in the interpreter, for-in, instanceof or regexp
  // exec — so timeout_msec does not bound a compile, and a pathological
  // source parses for as long as it takes. Releasing the GVL at least keeps
  // that off every other Ruby thread. It is kept only so an outermost
  // compile starts from a fresh clock rather than inheriting a lapsed one.
  //
  // Nested, it is worse than useless: a compile issued from a bridge
  // callback (a define_function proc, an on_log listener) would overwrite
  // the enclosing eval's started_at on every call, so interrupt_handler
  // never sees the elapsed limit and the enclosing eval never times out at
  // all. vm_m_loadPolyfillBytecode conditions on the same counter for the
  // same reason.
  //
  // Not a file-wide invariant yet, to be clear. vm_m_evalCode,
  // vm_m_evalBytecode, call_global_function_body, vm_m_import and
  // vm_m_drainJobs all still arm unconditionally and all still defeat
  // timeout_msec the same way. Hoisting the condition into arm_eval_timer
  // would close them together, but it would also start interrupting
  // workloads that re-enter the VM from a bridge and today run unbounded —
  // a semantics change that deserves its own PR rather than a ride on this
  // one.
  check_disposed(data);
  // Same re-check as vm_m_evalCode, for the same reason: parsing yielded, so
  // the owner may have changed since the check at entry.
  check_js_entry_owner(data);
  if (data->evals_in_flight == 0)
    arm_eval_timer(data);

  // A guaranteed no-op: parse_code_and_filename already refused a
  // non-String, so no to_str can run here and open a yield point between
  // the check above and the release below.
  StringValue(r_code);
  // Serializing stays on the GVL-held side of the region: the region frees
  // its buffers with free(), while JS_WriteObject's blob has to go back
  // through js_free, and teaching it a second kind of ownership for one
  // caller isn't worth it. Parsing dominates anyway — leaving the serialize
  // behind only pulls the two-thread ratio from ~0.5 to ~0.55.
  JSValue j_func = compile_release_gvl(data, r_code, filename);
  if (JS_IsException(j_func))
  {
    return js_exception_to_rb(data, j_func); // raises Ruby exception
  }

  return compiled_to_bytecode_string(data, j_func, "failed to serialize compiled bytecode");
}

// Stands in for the real loader while compiling a module to bytecode.
//
// __JS_EvalInternal runs js_resolve_module before it honors
// JS_EVAL_FLAG_COMPILE_ONLY, so compiling `import { x } from 'dep'` tries to
// load 'dep' — which would make a module impossible to compile without its
// whole dependency graph on hand. Nothing about that resolution survives:
// JS_WriteModule stores req_module_entries as the specifier written in the
// source, never the module it resolved to, and export names aren't checked
// until js_link_module at evaluation time. So an empty stub satisfies the
// compile and leaves no trace in the blob; the importing VM resolves the real
// dependency through its own loader.
//
// The stubs do land in the compiling context's module map, so this must only
// ever run on a throwaway VM — otherwise a later real import of 'dep' on that
// VM would find the empty stub.
static JSModuleDef *quickjsrb_stub_module_loader(JSContext *ctx, const char *module_name, void *opaque, JSValueConst attributes)
{
  static const char *empty_module = "export {};";
  JSValue j_stub = JS_Eval(ctx, empty_module, strlen(empty_module), module_name,
                           JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(j_stub))
    return NULL;

  JSModuleDef *m = JS_VALUE_GET_PTR(j_stub);
  JS_FreeValue(ctx, j_stub);
  return m;
}

// Compiles source as an ES module and serializes it. Unlike vm_m_compile,
// `name` is not a debug label: js_read_module rebuilds the JSModuleDef under
// the name baked in here, so it is the module's identity in every VM that
// later reads this blob. Quickjs.register_module keys the registry by that
// same string, which is what keeps the two from drifting apart.
//
// Stays private, and must: the stub loader below is swapped in at the
// *runtime* level for the duration, so this assumes exclusive use of the VM.
// Quickjs._compile_registered_module honors that by compiling on a disposable
// VM it owns; exposing this publicly would let a compile race an import on a
// shared VM and resolve it against stubs.
struct compile_module_job
{
  VMData *data;
  VALUE r_code;
  const char *name;
};

static VALUE compile_module_body(VALUE p);

static VALUE vm_m_compileModule(VALUE r_self, VALUE r_code, VALUE r_name)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);
  Check_Type(r_code, T_STRING);
  Check_Type(r_name, T_STRING);

  // Hoisted above everything that touches the runtime. Check_Type already
  // ruled out a to_str, but StringValueCStr still calls rb_str_modify to
  // NUL-terminate a shared or embedded-NUL-free substring, and that
  // allocates — the same thread switch point the rest of this file treats as
  // a yield. Left where it read most naturally, inline in the JS_Eval
  // arguments, a concurrent dispose! landing there would free the runtime
  // out from under the loader swap and the eval. Coercing first puts the
  // disposed check after the last yield and before the first context access,
  // as on the other JS entry points.
  const char *name = StringValueCStr(r_name);

  check_disposed(data);
  // Re-checked after the coercion above yields, and then immediately turned
  // into a claim by run_held_js_entry below: unlike the other compile paths,
  // the runtime work here is a full JS_Eval plus a runtime-level loader swap,
  // so a check that recorded nothing would leave both of those exposed to a
  // second thread passing the same idle check.
  check_js_entry_owner(data);
  // Guarded for the reason spelled out in vm_m_compile: only the outermost
  // JS entry point owns the timeout budget. Nesting can't happen on this
  // path today — it is private and both callers compile on a disposable VM
  // they own — but the two compile entry points arming differently would be
  // a difference with no reason behind it.
  // Armed before the claim below, not after: the condition reads the counter
  // that run_held_js_entry is about to raise, so claiming first would skip
  // the arm on every outermost compile.
  if (data->evals_in_flight == 0)
    arm_eval_timer(data);

  struct compile_module_job job = {
      .data = data,
      .r_code = r_code,
      .name = name,
  };
  return run_held_js_entry(data, compile_module_body, (VALUE)&job);
}

static VALUE compile_module_body(VALUE p)
{
  struct compile_module_job *job = (struct compile_module_job *)p;
  VMData *data = job->data;
  VALUE r_code = job->r_code;

  JS_SetModuleLoaderFunc2(JS_GetRuntime(data->context), NULL, quickjsrb_stub_module_loader,
                          js_module_check_attributes, NULL);
  // RSTRING_PTR raw, where the released paths copy — the copy there is for GC
  // movability, and the NUL that quickjs.h:835 asks for comes free with it.
  // Held here, the raw pointer carries that NUL anyway: Ruby only shares one
  // String's buffer with another when the substring runs to the parent's end,
  // so ptr[len] is always somebody's terminator. Worth stating because the
  // lexer's comment and regexp scanners test for the NUL before the end
  // pointer, so a buffer without one would let a source ending mid-comment
  // read on into whatever follows it in memory.
  JSValue j_mod = JS_Eval(data->context, RSTRING_PTR(r_code), RSTRING_LEN(r_code), job->name,
                          JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  register_module_loader_funcs(data);
  if (JS_IsException(j_mod))
    return js_exception_to_rb(data, j_mod); // raises

  return compiled_to_bytecode_string(data, j_mod, "failed to serialize compiled module bytecode");
}

// Reads module bytecode into this context. The read registers the JSModuleDef
// in ctx->loaded_modules but does not evaluate it: evaluation still happens on
// first import, and js_resolve_module recurses into it from the importer, so
// no loader hook is involved for a preloaded name.
//
// The name is recorded in preloaded_module_names for the normalize hook's
// short-circuit, and returned so the caller can confirm the blob was filed
// where it asked.
//
// `name` is the name the caller expects the blob to carry. Reading the same
// module into a context twice can't be undone — js_read_module appends a
// second JSModuleDef under the same name, js_find_loaded_module returns the
// first one it walks past, and the orphan holds its bytecode until the
// context is freed — so a name already preloaded here skips the read
// entirely. That also makes this idempotent, which the caller relies on: it
// is legitimate to preload the same module into a VM more than once.
static VALUE vm_m_preloadModuleBytecode(VALUE r_self, VALUE r_bytecode, VALUE r_name)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  // Strict String rather than StringValue's coercion, matching
  // vm_m_evalBytecode: bytecode is a binary blob, so there's no sensible
  // to_str-able stand-in for one, and refusing the coercion means no yield
  // point can open up between the checks above and the context access below.
  if (!RB_TYPE_P(r_bytecode, T_STRING))
  {
    VALUE r_class = rb_class_name(CLASS_OF(r_bytecode));
    rb_raise(rb_eTypeError, "Bytecode must be a String, got %s", StringValueCStr(r_class));
  }
  Check_Type(r_name, T_STRING);

  // A module name crosses into QuickJS as raw bytes and comes back binary, so
  // it is compared and keyed on bytes here. Encoding-aware equality would call
  // a non-ASCII name different from the identical name the caller passed in
  // (UTF-8 from the registry), and this is also the form the normalize hook
  // looks up, since it builds its specifier from a C string too.
  VALUE r_key = rb_str_new(RSTRING_PTR(r_name), RSTRING_LEN(r_name));

  if (RTEST(rb_hash_aref(data->preloaded_module_names, r_key)))
    return r_name;

  // Deserialize with the GVL released. The read touches no Ruby and no
  // bridge — it only registers the def, deferring linking to import — so it
  // releases unconditionally (no can_eval_gvl_free gate): a pool of
  // per-thread VMs each preloading the same modules deserializes in parallel
  // instead of serializing through the GVL. RSTRING_PTR is GC-movable while
  // released, so the bytecode is copied to a buffer the region owns and frees.
  //
  // An async interrupt in the region's GVL re-acquire frees j_mod but leaves
  // the def js_new_module_def already registered in loaded_modules, untracked
  // by preloaded_module_names. That is reachable on a VM the caller keeps —
  // import(names, from:) preloads into a live VM, not just VM.new into a
  // half-built one — so it is worth spelling out what a retry does: the
  // untracked name misses the guard above, a second def is read under the same
  // name, js_find_loaded_module returns the first, and the retry records the
  // name. Behaviour recovers, at the cost of one orphan holding its bytecode
  // for the life of the context, so unregistering on interrupt isn't worth it.
  size_t buf_len;
  uint8_t *buf = (uint8_t *)copy_rstring_to_owned_buffer(r_bytecode, &buf_len, false);
  JSValue j_mod = run_bytecode_release_gvl(data, bytecode_read_job_run, buf, buf_len, true);
  if (JS_IsException(j_mod))
    return to_rb_value(data->context, j_mod); // raises

  if (JS_VALUE_GET_TAG(j_mod) != JS_TAG_MODULE)
  {
    JS_FreeValue(data->context, j_mod);
    rb_raise(rb_eTypeError, "bytecode is not an ES module (compile it with type: :module)");
  }

  js_module_set_import_meta(data->context, j_mod, FALSE, FALSE);

  JSAtom j_baked = JS_GetModuleName(data->context, JS_VALUE_GET_PTR(j_mod));
  const char *baked = JS_AtomToCString(data->context, j_baked);
  VALUE r_baked = rb_str_new_cstr(baked ? baked : "");
  if (baked)
    JS_FreeCString(data->context, baked);
  JS_FreeAtom(data->context, j_baked);

  // The module def is owned by ctx->loaded_modules (js_new_module_def leaves
  // it there with ref_count 1); JS_NewModuleValue dup'd it for us.
  JS_FreeValue(data->context, j_mod);

  // A blob whose baked name disagrees with the name it was filed under would
  // be resolvable only by the baked one, so the guard above would never see
  // it again and every preload would read another copy. There is no way to
  // take the read back, so the VM is already polluted: raise and let the
  // caller discard it.
  if (!RTEST(rb_str_equal(r_baked, r_key)))
  {
    rb_raise(rb_eArgError, "module bytecode is named %"PRIsVALUE", not %"PRIsVALUE,
             rb_str_inspect(r_baked), rb_str_inspect(r_name));
  }

  rb_hash_aset(data->preloaded_module_names, rb_str_freeze(r_key), Qtrue);
  return r_name;
}

// Number of sources the normalize hook is holding for the load hook to pick
// up. Exposed only so tests can assert the cache doesn't accumulate entries
// nothing will ever collect: when a loader resolves a specifier onto a
// preloaded canonical, QuickJS finds the module and never calls the load hook,
// so a source stashed for that name would sit there for the VM's lifetime.
static VALUE vm_m_pendingModuleSourceCount(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  return LONG2NUM(RHASH_SIZE(data->module_source_cache));
}

static VALUE vm_m_evalBytecode(VALUE r_self, VALUE r_bytecode)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  if (!RB_TYPE_P(r_bytecode, T_STRING))
  {
    VALUE r_class = rb_class_name(CLASS_OF(r_bytecode));
    rb_raise(rb_eTypeError, "Bytecode must be a String, got %s", StringValueCStr(r_class));
  }

  StringValue(r_bytecode);

  arm_eval_timer(data);

  JSValue j_result;
  if (can_eval_gvl_free(data))
  {
    // Pure VM: no JS→Ruby bridge can fire during the run or the await's
    // job drain, so run load + await with the GVL released — warmer pools
    // executing one compiled bundle across per-thread VMs recover
    // multi-core scaling instead of serializing every run through the
    // GVL. The bytecode is copied because RSTRING_PTR is GC-movable
    // while the GVL is released.
    size_t buf_len;
    uint8_t *buf = (uint8_t *)copy_rstring_to_owned_buffer(r_bytecode, &buf_len, false);
    j_result = run_bytecode_release_gvl(data, bytecode_eval_await_job_run, buf, buf_len, true);
  }
  else
  {
    // Bridged path: user bytecode may invoke Ruby-bridged callbacks
    // registered via define_function, which call Ruby APIs — keep the GVL
    // held. With it held there's no compaction risk, so RSTRING_PTR is
    // usable without a copy.
    struct bytecode_load_job job = {data->context,
                                    (const uint8_t *)RSTRING_PTR(r_bytecode),
                                    (size_t)RSTRING_LEN(r_bytecode),
                                    JS_UNDEFINED};
    run_held_js_entry(data, bytecode_eval_await_body, (VALUE)&job);
    j_result = job.result;
  }

  if (JS_IsException(j_result))
    return to_rb_value(data->context, j_result); // raises

  JSValue j_returnedValue = JS_GetPropertyStr(data->context, j_result, "value");
  JS_FreeValue(data->context, j_result);
  return to_rb_return_value(data->context, j_returnedValue);
}

// Loads pre-compiled polyfill bytecode without arming the eval timer.
// The user's `timeout_msec` is a budget for *their* code; running a
// multi-MB polyfill bundle (e.g. the companion `quickjs-polyfill-intl`
// gem registered via Quickjs.register_polyfill) under that budget would
// interrupt the load on tight defaults.
//
// Picks the GVL-released or GVL-held path based on can_eval_gvl_free
// (same gate vm_m_evalCode uses): if POLYFILL_FILE / POLYFILL_CRYPTO is
// enabled, the polyfill's top-level code could reach a Ruby-bridged C
// function that calls rb_funcall directly — those bridges don't honor
// gvl_released_js, so we must keep the GVL. Otherwise, csim and similar
// warmer-thread VM pools recover multi-core scaling: without the release
// every warmer's polyfill load serializes through the GVL, collapsing
// 4-way warmer parallelism to 1.
//
// The GVL-released path copies the Ruby String to a malloc'd buffer
// because RSTRING_PTR can be invalidated by GC compaction while the GVL
// is released. The memcpy cost is microseconds vs hundreds of ms of
// bytecode eval, so it's negligible.
static VALUE vm_m_loadPolyfillBytecode(VALUE r_self, VALUE r_bytecode)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  // The disposed check has to sit after the last GVL-yield point and before
  // the context is touched. Refusing a to_str-able stand-in removes the yield
  // instead of ordering around it: bytecode is a binary blob, so coercion buys
  // nothing, and without it there is no window for a concurrent dispose! to
  // free the context between the check and the load. Same guard as
  // vm_m_evalBytecode and _preload_module_bytecode.
  if (!RB_TYPE_P(r_bytecode, T_STRING))
  {
    VALUE r_class = rb_class_name(CLASS_OF(r_bytecode));
    rb_raise(rb_eTypeError, "Bytecode must be a String, got %s", StringValueCStr(r_class));
  }

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  // "Unbudgeted" needs enforcing, not just skipping arm_eval_timer: the
  // interrupt handler installed by a previous eval stays armed with that
  // eval's started_at, so a load after the budget lapsed would be
  // interrupted on its first check — and because the bytecode is
  // async-wrapped, the interruption surfaces as a rejected promise the
  // old code never looked at: the load "succeeded" with the polyfill
  // silently missing. Disarm for the load; the next eval re-arms. Only
  // when this load is the outermost JS activity, though: a load issued
  // from inside a bridge callback (e.g. an on_log listener) must stay
  // under the in-flight eval's budget, not erase it.
  if (data->evals_in_flight == 0)
    JS_SetInterruptHandler(JS_GetRuntime(data->context), NULL, NULL);

  size_t buf_len = (size_t)RSTRING_LEN(r_bytecode);
  JSValue j_result;
  if (can_eval_gvl_free(data))
  {
    uint8_t *buf = (uint8_t *)copy_rstring_to_owned_buffer(r_bytecode, &buf_len, false);
    j_result = load_polyfill_bytecode(data, buf, buf_len, true);
  }
  else
  {
    // This branch runs exactly when a Ruby bridge (crypto, File, …) is
    // installed, and every rb_funcall inside one is an interrupt
    // checkpoint — run_held_js_entry keeps the counter unwind (and the
    // stale-dispose re-check the released branch gets from its region)
    // on this path too.
    struct bytecode_load_job job = {data->context,
                                    (const uint8_t *)RSTRING_PTR(r_bytecode),
                                    buf_len,
                                    JS_UNDEFINED};
    run_held_js_entry(data, bytecode_load_body, (VALUE)&job);
    j_result = job.result;
  }

  finish_polyfill_load(data, j_result); // raises unless settled fulfilled
  return Qnil;
}

struct define_function_call
{
  VMData *data;
  VALUE r_name;
  VALUE r_flags;
  VALUE r_block;
};

static VALUE define_global_function_body(VALUE p)
{
  struct define_function_call *call = (struct define_function_call *)p;
  VMData *data = call->data;
  VALUE r_name = call->r_name;
  VALUE r_flags = call->r_flags;
  VALUE r_block = call->r_block;

  if (RB_TYPE_P(r_name, T_ARRAY))
  {
    long path_len = RARRAY_LEN(r_name);
    if (path_len < 1)
      rb_raise(rb_eArgError, "function's path array must not be empty");

    for (long i = 0; i < path_len; i++)
    {
      VALUE r_seg = RARRAY_AREF(r_name, i);
      if (!(SYMBOL_P(r_seg) || RB_TYPE_P(r_seg, T_STRING)))
        rb_raise(rb_eTypeError, "function's name should be a Symbol or a String");
    }

    // Build internal lookup key by joining path segments with "."
    // e.g. ["myLib", "hello"] -> :"myLib.hello"
    VALUE r_segs = rb_ary_new();
    for (long i = 0; i < path_len; i++)
      rb_ary_push(r_segs, rb_funcall(RARRAY_AREF(r_name, i), rb_intern("to_s"), 0));
    VALUE r_key_str = rb_funcall(r_segs, rb_intern("join"), 1, rb_str_new2("."));
    VALUE r_key_sym = rb_funcall(r_key_str, rb_intern("to_sym"), 0);
    rb_hash_aset(data->defined_functions, r_key_sym, r_block);

    VALUE r_func_seg_str = rb_funcall(RARRAY_AREF(r_name, path_len - 1), rb_intern("to_s"), 0);
    char *funcName = StringValueCStr(r_func_seg_str);

    JSValueConst ruby_data[2];
    ruby_data[0] = JS_NewInt64(data->context, (int64_t)SYM2ID(r_key_sym));
    ruby_data[1] = JS_NewBool(data->context, RTEST(rb_funcall(r_flags, rb_intern("include?"), 1, ID2SYM(rb_intern("async")))));

    // Resolve the parent object to attach the function to.
    // For a single-element array, parent is the global object.
    // For multi-element arrays, traverse path[0..n-2] using JS_Eval for the first
    // segment (so lexical const/let bindings are resolved, not just global properties)
    // and JS_GetPropertyStr for subsequent segments.
    JSValue j_parent;
    if (path_len == 1)
    {
      j_parent = JS_GetGlobalObject(data->context);
    }
    else
    {
      VALUE r_first_str = rb_funcall(RARRAY_AREF(r_name, 0), rb_intern("to_s"), 0);
      const char *first_seg = StringValueCStr(r_first_str);
      // Resolving the first segment is not a lookup, it is an eval: `myLib`
      // can be an accessor property, so this runs arbitrary JS and can reach
      // a Ruby bridge. It runs under whatever interrupt handler the previous
      // eval left armed, so refresh the clock — a lapsed budget misfires here
      // and masquerades as "'%s' is not an object", blaming the caller's path
      // for what was a timeout.
      arm_eval_timer(data);
      j_parent = JS_Eval(data->context, first_seg, strlen(first_seg), vmInternalFilename, JS_EVAL_TYPE_GLOBAL);

      if (JS_IsException(j_parent) || !JS_IsObject(j_parent))
      {
        JS_FreeValue(data->context, j_parent);
        JS_FreeValue(data->context, ruby_data[0]);
        JS_FreeValue(data->context, ruby_data[1]);
        rb_raise(rb_eArgError, "cannot define function: '%s' is not an object", first_seg);
      }

      for (long i = 1; i < path_len - 1; i++)
      {
        VALUE r_seg_str = rb_funcall(RARRAY_AREF(r_name, i), rb_intern("to_s"), 0);
        JSValue j_next = JS_GetPropertyStr(data->context, j_parent, StringValueCStr(r_seg_str));
        JS_FreeValue(data->context, j_parent);

        if (JS_IsException(j_next) || !JS_IsObject(j_next))
        {
          JS_FreeValue(data->context, j_next);
          JS_FreeValue(data->context, ruby_data[0]);
          JS_FreeValue(data->context, ruby_data[1]);
          rb_raise(rb_eArgError, "cannot define function: '%s' is not an object", StringValueCStr(r_seg_str));
        }
        j_parent = j_next;
      }
    }

    JS_SetPropertyStr(
        data->context, j_parent, funcName,
        JS_NewCFunctionData(data->context, js_quickjsrb_call_global, 1, 0, 2, ruby_data));
    JS_FreeValue(data->context, j_parent);
    JS_FreeValue(data->context, ruby_data[0]);
    JS_FreeValue(data->context, ruby_data[1]);

    VALUE r_result = rb_ary_new();
    for (long i = 0; i < path_len; i++)
      rb_ary_push(r_result, rb_funcall(RARRAY_AREF(r_name, i), rb_intern("to_sym"), 0));
    return r_result;
  }
  else if (SYMBOL_P(r_name) || RB_TYPE_P(r_name, T_STRING))
  {
    VALUE r_name_sym = rb_funcall(r_name, rb_intern("to_sym"), 0);

    rb_hash_aset(data->defined_functions, r_name_sym, r_block);
    VALUE r_name_str = rb_funcall(r_name, rb_intern("to_s"), 0);
    char *funcName = StringValueCStr(r_name_str);

    JSValueConst ruby_data[2];
    ruby_data[0] = JS_NewInt64(data->context, (int64_t)SYM2ID(r_name_sym));
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
  else
  {
    rb_raise(rb_eTypeError, "function's name should be a Symbol or a String");
  }
}

// Registering a function is a JS entry point like any other, and was the one
// that never said so. Two independent problems land on this call, and routing
// the body through run_held_js_entry is what closes both.
//
// Lifetime: the body resolves the path with JS_Eval and JS_GetPropertyStr,
// either of which can land on an accessor property and run user JS that calls
// a bridge — and it interleaves that with rb_funcall(to_s) on caller-supplied
// objects, which yields the GVL. With evals_in_flight left at zero throughout,
// dispose! did not refuse:
//
//   vm.define_function('boom') { vm.dispose!; 1 }
//   vm.eval_code("Object.defineProperty(globalThis, 'myLib', { get() { boom(); return {}; } }); 0")
//   vm.define_function(['myLib', 'hello']) { 1 }   # SIGSEGV
//
// dispose! succeeds from inside the getter, and the traversal then runs
// JS_GetPropertyStr and JS_FreeValue against a freed JSContext. Elevating the
// counter for the whole body is what every other JS entry point already does,
// and it turns that into the ThreadError dispose! owes the caller.
//
// Concurrency: that same GVL yield lets a second thread in. A bare owner check
// would pass on an idle VM and record nothing, so the second thread passes the
// same idle check and walks into JS_Eval alongside the traversal. Only
// claiming the VM closes that.
//
// Neither reason subsumes the other — one is a single thread freeing the
// context under its own traversal, the other is two threads inside JS_Eval at
// once — so retiring one of them is not grounds for unwinding the routing.
//
// The absent check_js_entry_owner beside check_disposed is deliberate, not the
// oversight it looks like next to the other six entry points: this is the one
// where nothing touches the runtime before the counted region, so the claim
// inside run_held_js_entry is the whole guard. check_no_gvl_release_in_flight
// and rb_scan_args above it read no runtime state; anything added there that
// does needs the explicit check back.
static VALUE vm_m_defineGlobalFunction(int argc, VALUE *argv, VALUE r_self)
{
  rb_need_block();

  VALUE r_name;
  VALUE r_flags;
  VALUE r_block;
  rb_scan_args(argc, argv, "10*&", &r_name, &r_flags, &r_block);

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_no_gvl_release_in_flight(data);

  struct define_function_call call = {
      .data = data,
      .r_name = r_name,
      .r_flags = r_flags,
      .r_block = r_block,
  };
  return run_held_js_entry(data, define_global_function_body, (VALUE)&call);
}

struct js_entry_call
{
  int argc;
  VALUE *argv;
  VMData *data;
};

static VALUE call_global_function_body(VALUE p)
{
  struct js_entry_call *call = (struct js_entry_call *)p;
  int argc = call->argc;
  VALUE *argv = call->argv;
  VMData *data = call->data;
  VALUE r_name = argv[0];

  JSValue j_this = JS_UNDEFINED;
  JSValue j_func;

  VALUE r_path;
  if (SYMBOL_P(r_name) || RB_TYPE_P(r_name, T_STRING))
  {
    VALUE r_name_str = rb_funcall(r_name, rb_intern("to_s"), 0);
    const char *name_str = StringValueCStr(r_name_str);
    size_t name_len = strlen(name_str);
    const char *last_bracket = strrchr(name_str, '[');
    const char *last_dot = strrchr(name_str, '.');

    if (last_bracket != NULL && last_bracket != name_str && name_str[name_len - 1] == ']')
    {
      // Bracket notation: 'a["key"]' or 'a.b["key"]' or 'a[0]'
      // Split into parent expression and the bracketed key
      VALUE r_parent = rb_str_new(name_str, last_bracket - name_str);
      const char *key_start = last_bracket + 1;
      size_t key_len = name_len - (key_start - name_str) - 1; // exclude ']'
      // Strip surrounding quotes for string keys: 'a["b"]' → key = b
      if (key_len >= 2 &&
          ((key_start[0] == '\'' && key_start[key_len - 1] == '\'') ||
           (key_start[0] == '"' && key_start[key_len - 1] == '"')))
      {
        key_start++;
        key_len -= 2;
      }
      VALUE r_key = rb_str_new(key_start, key_len);
      r_path = rb_ary_new3(2, r_parent, r_key);
    }
    else if (last_dot != NULL && last_dot != name_str)
    {
      // Dot notation: 'a.b.c' → ['a.b', 'c'] so the parent becomes `this`
      VALUE r_parent = rb_str_new(name_str, last_dot - name_str);
      VALUE r_key = rb_str_new2(last_dot + 1);
      r_path = rb_ary_new3(2, r_parent, r_key);
    }
    else
    {
      r_path = rb_ary_new3(1, r_name_str);
    }
  }
  else
  {
    rb_raise(rb_eTypeError, "function's name should be a Symbol or a String");
  }

  {
    long path_len = RARRAY_LEN(r_path);

    VALUE r_first = RARRAY_AREF(r_path, 0);
    if (!(SYMBOL_P(r_first) || RB_TYPE_P(r_first, T_STRING)))
      rb_raise(rb_eTypeError, "function path elements should be Symbols or Strings");

    VALUE r_first_str = rb_funcall(r_first, rb_intern("to_s"), 0);
    const char *first_seg = StringValueCStr(r_first_str);

    // JS_Eval accesses both global object properties and lexical (const/let) bindings
    JSValue j_cur = JS_Eval(data->context, first_seg, strlen(first_seg), vmInternalFilename, JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(j_cur))
      return to_rb_value(data->context, j_cur); // raises

    for (long i = 1; i < path_len; i++)
    {
      VALUE r_seg = RARRAY_AREF(r_path, i);
      if (!(SYMBOL_P(r_seg) || RB_TYPE_P(r_seg, T_STRING)))
      {
        JS_FreeValue(data->context, j_cur);
        JS_FreeValue(data->context, j_this);
        rb_raise(rb_eTypeError, "function path elements should be Symbols or Strings");
      }
      VALUE r_seg_str = rb_funcall(r_seg, rb_intern("to_s"), 0);
      const char *seg = StringValueCStr(r_seg_str);

      JSValue j_next = JS_GetPropertyStr(data->context, j_cur, seg);
      if (JS_IsException(j_next))
      {
        JS_FreeValue(data->context, j_cur);
        JS_FreeValue(data->context, j_this);
        return to_rb_value(data->context, j_next); // raises
      }

      JS_FreeValue(data->context, j_this);
      j_this = j_cur;
      j_cur = j_next;
    }

    j_func = j_cur;
  }

  if (!JS_IsFunction(data->context, j_func))
  {
    JS_FreeValue(data->context, j_func);
    JS_FreeValue(data->context, j_this);
    VALUE r_error_message = rb_str_new2("given path is not a function");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
    return Qnil;
  }

  int nargs = argc - 1;
  JSValue *j_args = NULL;
  if (nargs > 0)
  {
    j_args = (JSValue *)malloc(sizeof(JSValue) * nargs);
    for (int i = 0; i < nargs; i++)
      j_args[i] = to_js_value(data->context, argv[i + 1]);
  }

  arm_eval_timer(data);

  JSValue j_result = JS_Call(data->context, j_func, j_this, nargs, (JSValueConst *)j_args);

  JS_FreeValue(data->context, j_func);
  JS_FreeValue(data->context, j_this);
  if (j_args)
  {
    for (int i = 0; i < nargs; i++)
      JS_FreeValue(data->context, j_args[i]);
    free(j_args);
  }

  // js_std_await handles both async (promise) and sync results; frees j_result
  return to_rb_return_value(data->context, js_std_await(data->context, j_result));
}

static VALUE vm_m_callGlobalFunction(int argc, VALUE *argv, VALUE r_self)
{
  if (argc < 1)
    rb_raise(rb_eArgError, "wrong number of arguments (given 0, expected 1+)");

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  // evals_in_flight stays elevated for the whole call, not just the
  // JS_Eval / JS_Call moments: the body holds live JSValues across Ruby
  // calls that can yield the GVL (path-segment to_s, argument
  // conversion), and a concurrent dispose! landing in such a gap would
  // free the runtime out from under them.
  struct js_entry_call call = {argc, argv, data};
  return run_held_js_entry(data, call_global_function_body, (VALUE)&call);
}

static VALUE vm_m_set_module_loader(VALUE r_self, VALUE r_loader)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  if (!NIL_P(r_loader) && !rb_obj_is_kind_of(r_loader, rb_cProc))
    rb_raise(rb_eTypeError, "module_loader must be a Proc or nil");

  // register_module_loader_funcs below dereferences the context, so a
  // disposed VM was a use-after-free here, and a VM being evaluated by
  // another thread means swapping the loader out from under a running
  // import. Neither was checked.
  check_disposed(data);
  check_js_entry_owner(data);
  check_no_gvl_release_in_flight(data);
  data->module_loader = r_loader;
  // Stale entries from the previous loader's policy would survive the
  // swap and silently shadow the new behavior.
  rb_hash_clear(data->module_resolution_cache);
  rb_hash_clear(data->module_source_cache);
  register_module_loader_funcs(data);
  return r_loader;
}

static VALUE vm_m_get_module_loader(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);
  return data->module_loader;
}

static VALUE vm_m_on_unhandled_rejection(VALUE r_self)
{
  rb_need_block();

  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_no_gvl_release_in_flight(data);
  data->on_unhandled_rejection = rb_block_proc();
  return Qnil;
}

static VALUE import_body(VALUE p)
{
  struct js_entry_call *call = (struct js_entry_call *)p;
  int argc = call->argc;
  VALUE *argv = call->argv;
  VMData *data = call->data;

  VALUE r_import_string, r_opts;
  rb_scan_args(argc, argv, "10:", &r_import_string, &r_opts);
  if (NIL_P(r_opts))
    r_opts = rb_hash_new();
  VALUE r_from = rb_hash_aref(r_opts, ID2SYM(rb_intern("from")));
  VALUE r_filename = rb_hash_aref(r_opts, ID2SYM(rb_intern("filename")));
  if (NIL_P(r_from) && NIL_P(r_filename))
  {
    VALUE r_error_message = rb_str_new2("missing import source");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_error_message, Qnil));
    return Qnil;
  }
  if (!NIL_P(r_from) && !NIL_P(r_filename))
    rb_raise(rb_eArgError, "pass either from: (inline source) or filename: (loader-resolved), not both");
  VALUE r_custom_exposure = rb_hash_aref(r_opts, ID2SYM(rb_intern("code_to_expose")));

  char *filename;
  char generated_filename[QUICKJSRB_GENERATED_NAME_SIZE];
  VALUE r_seeded_key = Qnil;
  if (!NIL_P(r_filename))
  {
    // Borrowed for the rest of the call, so r_filename has to outlive the
    // bridge snprintf below. A literal String is rooted by the kwargs hash
    // through argv, but StringValueCStr writes a coerced String back through
    // &r_filename, and a to_str result is referenced by nothing else — only
    // this local, which the compiler is free to treat as dead right here
    // while filename is still being read. Guarded after the last read.
    filename = StringValueCStr(r_filename);
  }
  else
  {
    random_filename(generated_filename);
    filename = generated_filename;
    char *source = StringValueCStr(r_from);
    JSValue module = JS_Eval(data->context, source, strlen(source), filename, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(module))
    {
      JS_FreeValue(data->context, module);
      return to_rb_value(data->context, module);
    }
    js_module_set_import_meta(data->context, module, TRUE, FALSE);
    // The bridge module below will `import` this filename; without a
    // resolution-cache seed, our normalize hook would ask the user's
    // module_loader for it (and fail), even though QuickJS already has
    // the module loaded from the JS_Eval just above. Each `from:` call
    // mints a fresh random filename, so we also delete the entry once
    // the bridge eval finishes — otherwise the cache grows unboundedly.
    if (!NIL_P(data->module_loader))
    {
      VALUE r_filename_str = rb_str_new_cstr(filename);
      r_seeded_key = rb_ary_new3(2, r_filename_str, rb_str_new2(vmInternalFilename));
      rb_hash_aset(data->module_resolution_cache, r_seeded_key, r_filename_str);
    }
    JS_FreeValue(data->context, module);
  }

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
  RB_GC_GUARD(r_filename);

  JSValue j_codeResult = JS_Eval(data->context, result, strlen(result), vmInternalFilename, JS_EVAL_TYPE_MODULE);
  free(result);
  if (JS_IsException(j_codeResult))
    return to_rb_value(data->context, j_codeResult);

  // Module eval returns a Promise. Awaiting it surfaces top-level throws,
  // rejected dynamic imports, and rejected top-level awaits as Ruby
  // exceptions instead of silently dropping them.
  JSValue j_awaited = js_std_await(data->context, j_codeResult);
  if (JS_IsException(j_awaited))
    return to_rb_value(data->context, j_awaited);
  JS_FreeValue(data->context, j_awaited);

  if (!NIL_P(r_seeded_key))
    rb_hash_delete(data->module_resolution_cache, r_seeded_key);

  return Qtrue;
}

static VALUE vm_m_import(int argc, VALUE *argv, VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  // Module top-level code is user JS like any eval — budget it. Without
  // this, import ran under whatever handler the previous entry point
  // left behind: a lapsed armed one (spurious interrupt) or none at all
  // after a polyfill load's disarm (unbounded).
  arm_eval_timer(data);

  // Like vm_m_callGlobalFunction: the body registers a module in the
  // context and then runs Ruby code (_build_import, StringValueCStr on
  // user values) that can yield the GVL before the bridge eval — keep
  // evals_in_flight elevated for the whole call so a concurrent dispose!
  // can't free the runtime in those gaps.
  struct js_entry_call call = {argc, argv, data};
  return run_held_js_entry(data, import_body, (VALUE)&call);
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
  rb_define_method(r_class_vm, "eval_code", vm_m_evalCode, -1);
  rb_define_private_method(r_class_vm, "_compile_to_bytecode", vm_m_compile, -1);
  rb_define_private_method(r_class_vm, "_compile_module_to_bytecode", vm_m_compileModule, 2);
  rb_define_private_method(r_class_vm, "_preload_module_bytecode", vm_m_preloadModuleBytecode, 2);
  rb_define_private_method(r_class_vm, "_pending_module_source_count", vm_m_pendingModuleSourceCount, 0);
  rb_define_private_method(r_class_vm, "_run_bytecode", vm_m_evalBytecode, 1);
  rb_define_private_method(r_class_vm, "_load_polyfill_bytecode", vm_m_loadPolyfillBytecode, 1);
  rb_define_method(r_class_vm, "call", vm_m_callGlobalFunction, -1);
  rb_define_method(r_class_vm, "define_function", vm_m_defineGlobalFunction, -1);
  rb_define_method(r_class_vm, "import", vm_m_import, -1);
  rb_define_method(r_class_vm, "module_loader", vm_m_get_module_loader, 0);
  rb_define_method(r_class_vm, "module_loader=", vm_m_set_module_loader, 1);
  rb_define_method(r_class_vm, "on_unhandled_rejection", vm_m_on_unhandled_rejection, 0);
  rb_define_method(r_class_vm, "on_log", vm_m_on_log, 0);
  rb_define_method(r_class_vm, "memory_usage", vm_m_memoryUsage, 0);
  rb_define_method(r_class_vm, "gc!", vm_m_runGC, 0);
  rb_define_method(r_class_vm, "memory_poisoned?", vm_m_memoryPoisoned, 0);
  rb_define_method(r_class_vm, "dispose!", vm_m_dispose, 0);
  rb_define_method(r_class_vm, "disposed?", vm_m_disposed, 0);
  rb_define_method(r_class_vm, "drain_jobs!", vm_m_drainJobs, 0);
  r_define_log_class(r_class_vm);
}

static VALUE vm_m_memoryUsage(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);
  check_disposed(data);
  check_js_entry_owner(data);
  JSMemoryUsage s;
  JS_ComputeMemoryUsage(JS_GetRuntime(data->context), &s);
  VALUE h = rb_hash_new();
  rb_hash_aset(h, ID2SYM(rb_intern("malloc_size")), LL2NUM(s.malloc_size));
  rb_hash_aset(h, ID2SYM(rb_intern("malloc_limit")), LL2NUM(s.malloc_limit));
  rb_hash_aset(h, ID2SYM(rb_intern("memory_used_size")), LL2NUM(s.memory_used_size));
  rb_hash_aset(h, ID2SYM(rb_intern("atom_count")), LL2NUM(s.atom_count));
  rb_hash_aset(h, ID2SYM(rb_intern("str_count")), LL2NUM(s.str_count));
  rb_hash_aset(h, ID2SYM(rb_intern("obj_count")), LL2NUM(s.obj_count));
  rb_hash_aset(h, ID2SYM(rb_intern("prop_count")), LL2NUM(s.prop_count));
  rb_hash_aset(h, ID2SYM(rb_intern("shape_count")), LL2NUM(s.shape_count));
  rb_hash_aset(h, ID2SYM(rb_intern("js_func_count")), LL2NUM(s.js_func_count));
  rb_hash_aset(h, ID2SYM(rb_intern("js_func_code_size")), LL2NUM(s.js_func_code_size));
  rb_hash_aset(h, ID2SYM(rb_intern("c_func_count")), LL2NUM(s.c_func_count));
  rb_hash_aset(h, ID2SYM(rb_intern("array_count")), LL2NUM(s.array_count));
  return h;
}

static VALUE vm_m_runGC(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);
  check_disposed(data);
  check_js_entry_owner(data);
  JS_RunGC(JS_GetRuntime(data->context));
  return Qnil;
}

static VALUE drain_jobs_body(VALUE p)
{
  VMData *data = (VMData *)p;
  JSRuntime *runtime = JS_GetRuntime(data->context);
  int executed = 0;
  for (;;)
  {
    int err = JS_ExecutePendingJob(runtime, NULL);
    if (err == 0)
      break;
    if (err < 0)
      return to_rb_value(data->context, JS_EXCEPTION); // raises
    executed++;
  }
  return INT2NUM(executed);
}

static VALUE vm_m_drainJobs(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  check_js_entry_owner(data);

  if (!JS_IsJobPending(JS_GetRuntime(data->context)))
    return INT2NUM(0);

  arm_eval_timer(data);

  return run_held_js_entry(data, drain_jobs_body, (VALUE)data);
}

static VALUE vm_m_memoryPoisoned(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);
  return data->oom_poisoned ? Qtrue : Qfalse;
}

// JS_FreeContext + JS_FreeRuntime walk the entire heap to run finalisers.
// On a VM with polyfills loaded this can be tens of milliseconds — run it
// without the GVL so other Ruby threads (e.g. the next pool builder) keep
// progressing. Safe to release because nothing in the teardown path calls
// back into Ruby: module_loader, console, and define_function callbacks
// only fire during JS execution, not during free.
static void *vm_dispose_no_gvl(void *p)
{
  vm_teardown_context((JSContext *)p);
  return NULL;
}

static VALUE vm_m_dispose(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  if (data->disposed)
    return Qnil;

  // Freeing the runtime under live JS is a use-after-free. The overlap is
  // reachable both through the GVL release (pure-path evals) and through
  // GVL-yielding bridge callbacks (setTimeout's rb_thread_wait_for,
  // define_function procs, on_log listeners) — including the README's
  // `Thread.new { vm.dispose! }` pattern and a listener calling dispose!
  // mid-eval. Fail loudly instead of corrupting the heap.
  if (data->evals_in_flight > 0)
    rb_raise(rb_eThreadError, "cannot dispose a Quickjs::VM while it is evaluating");

  if (!JS_IsUndefined(data->j_file_proxy_creator))
  {
    JS_FreeValue(data->context, data->j_file_proxy_creator);
    data->j_file_proxy_creator = JS_UNDEFINED;
  }

  // Mark disposed before releasing the GVL so a concurrent dfree finds
  // disposed=true and skips its own teardown.
  data->disposed = true;

  rb_thread_call_without_gvl(vm_dispose_no_gvl, data->context, NULL, NULL);

  // Drop references to user-supplied closures so Ruby GC can reclaim them
  // (and anything they captured) before the wrapping VM object itself is
  // collected. Matters for pool-rebuild workloads that dispose eagerly.
  data->defined_functions = rb_hash_new();
  data->alive_objects = rb_hash_new();
  data->log_listener = Qnil;
  data->module_loader = Qnil;

  return Qnil;
}

static VALUE vm_m_disposed(VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);
  return data->disposed ? Qtrue : Qfalse;
}
