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
    if (!RB_TYPE_P(r_source, T_STRING))
    {
      JS_ThrowTypeError(ctx, "module loader Hash must include code: (String, the module source)");
      return NULL;
    }
    if (!RB_TYPE_P(r_canonical, T_STRING))
    {
      JS_ThrowTypeError(ctx, "module loader Hash must include as: (String, the canonical module name)");
      return NULL;
    }
  }
  else
  {
    JS_ThrowTypeError(ctx, "module loader must return a String, a Hash with code: and as:, or nil; got %s",
                      rb_obj_classname(r_return));
    return NULL;
  }

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
    // Defensive: normalize populates this on every miss.
    JS_ThrowReferenceError(ctx, "module loader: no cached source for '%s'", module_name);
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
// region — which would leak its buffers and leave gvl_released_eval stuck.
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
  bool prev = data->gvl_released_eval;
  data->gvl_released_eval = false;
  c->result = js_quickjsrb_log_inner(c->ctx, c->argc, c->argv, c->severity);
  data->gvl_released_eval = prev;
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
  if (data->gvl_released_eval)
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

// Run polyfill bytecode load + eval without the GVL so a background
// warmer thread can populate a VM pool in parallel with the main thread
// on multi-core hosts.
//
// Two bridges can already be live when these loads run in
// vm_m_initialize — setTimeout (FEATURE_TIMEOUT) and the File proxy
// (POLYFILL_FILE registers it ahead of the encoding/url loads) — so
// releasing the GVL is safe not because nothing is registered, but
// because a load never runs bridge code: js_quickjsrb_set_timeout only
// enqueues (pure C; the Ruby-calling js_delay_and_eval_job runs later,
// under a GVL-held drain/await), a load never drains the job queue, and
// the bundled polyfill top-levels (file / encoding / url, built from
// polyfills/src in this repo) don't call the File proxy. That audit is
// the invariant to preserve when rebuilding bundles or reordering
// vm_m_initialize. Arbitrary user bytecode must not come through here —
// vm_m_loadPolyfillBytecode keeps the GVL for that.
struct polyfill_load_args
{
  JSContext *ctx;
  const uint8_t *buf;
  size_t buf_len;
  JSValue result;
};

static void *polyfill_load_no_gvl(void *p)
{
  struct polyfill_load_args *args = p;
  JSValue obj = JS_ReadObject(args->ctx, args->buf, args->buf_len, JS_READ_OBJ_BYTECODE);
  args->result = JS_EvalFunction(args->ctx, obj); // frees obj
  return NULL;
}

static JSValue load_polyfill_bytecode(JSContext *ctx, const uint8_t *buf, size_t buf_len)
{
  struct polyfill_load_args args = {ctx, buf, buf_len, JS_UNDEFINED};
  rb_thread_call_without_gvl(polyfill_load_no_gvl, &args, NULL, NULL);
  return args.result;
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

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillFileId))))
  {
    JSValue j_polyfillFileResult = load_polyfill_bytecode(data->context, &qjsc_polyfill_file_min, qjsc_polyfill_file_min_size);
    JS_FreeValue(data->context, j_polyfillFileResult);

    quickjsrb_init_file_proxy(data);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillEncodingId))))
  {
    JSValue j_polyfillEncodingResult = load_polyfill_bytecode(data->context, &qjsc_polyfill_encoding_min, qjsc_polyfill_encoding_min_size);
    JS_FreeValue(data->context, j_polyfillEncodingResult);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillUrlId))))
  {
    JSValue j_polyfillUrlResult = load_polyfill_bytecode(data->context, &qjsc_polyfill_url_min, qjsc_polyfill_url_min_size);
    JS_FreeValue(data->context, j_polyfillUrlResult);
  }

  if (RTEST(rb_funcall(r_features, rb_intern("include?"), 1, QUICKJSRB_SYM(featurePolyfillCryptoId))))
  {
    quickjsrb_init_crypto(data->context, j_global);
  }

  // console and the remaining host callbacks are registered below this
  // point. setTimeout and the File proxy above predate the GVL-released
  // polyfill loads only under the audit described at
  // load_polyfill_bytecode — re-read it before reordering this function
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
// gvl_released_eval re-acquire). When true, eval can safely run with the
// GVL released so other Ruby threads make progress on different cores.
// C-function bridges registered via quickjsrb_new_ruby_bridge (crypto.*,
// File proxy, setTimeout) call rb_funcall directly — those would need to
// learn the gvl_released_eval pattern before they can run under a released
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

// A GVL-release region — the one place that owns the handshake required to
// run a pure-C QuickJS job with the GVL released: the save/restore of
// gvl_released_eval (restore, not clear, so a region nested through an
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
  data->gvl_released_eval = region->prev_gvl_released;
  data->evals_in_flight--;
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
  if (data->disposed)
  {
    free(owned_buf0);
    free(owned_buf1);
    check_disposed(data); // raises
  }

  struct gvl_release_region region = {
      .data = data,
      .job_run = job_run,
      .job = job,
      .j_result = j_result,
      .owned_bufs = {owned_buf0, owned_buf1},
      .prev_gvl_released = data->gvl_released_eval,
      .completed = false,
  };

  data->evals_in_flight++;
  data->gvl_release_regions++;
  data->gvl_released_eval = true;
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
  ((VMData *)p)->evals_in_flight--;
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
  data->evals_in_flight++;
  return rb_ensure(body, arg, evals_in_flight_release, (VALUE)data);
}

static VALUE eval_code_job_run_body(VALUE p)
{
  eval_code_job_run((struct eval_code_job *)p);
  return Qnil;
}

struct eval_function_job
{
  JSContext *ctx;
  JSValue j_func;
  JSValue j_awaited;
};

static VALUE eval_function_job_run_body(VALUE p)
{
  struct eval_function_job *job = (struct eval_function_job *)p;
  JSValue j_codeResult = JS_EvalFunction(job->ctx, job->j_func); // frees j_func
  job->j_awaited = js_std_await(job->ctx, j_codeResult);
  return Qnil;
}

// Run the eval core without the GVL. Inputs are copied to malloc'd buffers
// because RSTRING_PTR can be invalidated by GC compaction while we're
// released — see feedback memory on RSTRING_PTR + GVL release.
static VALUE eval_code_release_gvl(VMData *data, VALUE r_code, const char *filename, bool async_mode)
{
  size_t code_len = (size_t)RSTRING_LEN(r_code);
  // QuickJS's parser reads code_len bytes plus a sentinel NUL; Ruby strings
  // are always NUL-terminated past RSTRING_LEN, so the original GVL-held path
  // works by accident. Our malloc'd copy must preserve that invariant.
  char *code_buf = malloc(code_len + 1);
  if (code_buf == NULL)
    rb_raise(rb_eNoMemError, "failed to allocate eval code buffer");
  memcpy(code_buf, RSTRING_PTR(r_code), code_len);
  code_buf[code_len] = '\0';

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

static VALUE vm_m_compile(int argc, VALUE *argv, VALUE r_self)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);

  VALUE r_code, r_opts;
  rb_scan_args(argc, argv, "1:", &r_code, &r_opts);
  const char *filename = parse_code_and_filename(r_code, r_opts);

  arm_eval_timer(data);

  StringValue(r_code);
  JSValue j_func = JS_Eval(data->context, RSTRING_PTR(r_code), RSTRING_LEN(r_code), filename,
                           JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(j_func))
  {
    return to_rb_value(data->context, j_func); // raises Ruby exception
  }

  size_t out_len;
  uint8_t *out_buf = JS_WriteObject(data->context, &out_len, j_func, JS_WRITE_OBJ_BYTECODE);
  JS_FreeValue(data->context, j_func);
  if (out_buf == NULL)
  {
    VALUE r_msg = rb_str_new2("failed to serialize compiled bytecode");
    rb_exc_raise(rb_funcall(QUICKJSRB_ERROR_FOR(QUICKJSRB_ROOT_RUNTIME_ERROR), rb_intern("new"), 2, r_msg, Qnil));
  }

  VALUE r_bytecode = rb_str_new((const char *)out_buf, (long)out_len);
  rb_enc_associate(r_bytecode, rb_ascii8bit_encoding());
  js_free(data->context, out_buf);
  return rb_obj_freeze(r_bytecode);
}

static VALUE vm_m_evalBytecode(VALUE r_self, VALUE r_bytecode)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);

  if (!RB_TYPE_P(r_bytecode, T_STRING))
  {
    VALUE r_class = rb_class_name(CLASS_OF(r_bytecode));
    rb_raise(rb_eTypeError, "Bytecode must be a String, got %s", StringValueCStr(r_class));
  }

  StringValue(r_bytecode);

  arm_eval_timer(data);

  // GVL held: user bytecode may invoke Ruby-bridged callbacks registered
  // via define_function, which call Ruby APIs. A pure VM could release
  // here with the same can_eval_gvl_free gate + buffer copy eval_code
  // uses — left GVL-held deliberately until bytecode eval shows up as a
  // parallelism bottleneck.
  JSValue j_func = JS_ReadObject(data->context,
                                 (const uint8_t *)RSTRING_PTR(r_bytecode),
                                 (size_t)RSTRING_LEN(r_bytecode),
                                 JS_READ_OBJ_BYTECODE);
  if (JS_IsException(j_func))
  {
    return to_rb_value(data->context, j_func); // raises
  }

  struct eval_function_job job = {data->context, j_func, JS_UNDEFINED};
  run_held_js_entry(data, eval_function_job_run_body, (VALUE)&job);
  JSValue j_returnedValue = JS_GetPropertyStr(data->context, job.j_awaited, "value");
  JS_FreeValue(data->context, job.j_awaited);
  return to_rb_return_value(data->context, j_returnedValue);
}

// Loads pre-compiled polyfill bytecode without arming the eval timer.
// The user's `timeout_msec` is a budget for *their* code; running a
// multi-MB polyfill bundle (e.g. the companion `quickjs-polyfill-intl`
// gem registered via Quickjs.register_polyfill) under that budget would
// interrupt the load on tight defaults. Unlike load_polyfill_bytecode
// above we hold the GVL through JS_ReadObject + JS_EvalFunction: the
// bytecode buffer is a Ruby String, so releasing would let GC compact
// the backing storage out from under us. The static-symbol path can
// release safely; this path cannot.
static VALUE vm_m_loadPolyfillBytecode(VALUE r_self, VALUE r_bytecode)
{
  VMData *data;
  TypedData_Get_Struct(r_self, VMData, &vm_type, data);

  check_disposed(data);
  check_oom_poisoned(data);
  StringValue(r_bytecode);

  JSValue j_func = JS_ReadObject(data->context,
                                 (const uint8_t *)RSTRING_PTR(r_bytecode),
                                 (size_t)RSTRING_LEN(r_bytecode),
                                 JS_READ_OBJ_BYTECODE);
  if (JS_IsException(j_func))
    return to_rb_value(data->context, j_func); // raises

  JSValue j_result = JS_EvalFunction(data->context, j_func); // frees j_func
  if (JS_IsException(j_result))
    return to_rb_value(data->context, j_result); // raises
  JS_FreeValue(data->context, j_result);
  return Qnil;
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

  check_disposed(data);
  check_no_gvl_release_in_flight(data);

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

  clock_gettime(CLOCK_MONOTONIC, &data->eval_time->started_at);
  JS_SetInterruptHandler(JS_GetRuntime(data->context), interrupt_handler, data->eval_time);

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
  VALUE r_seeded_key = Qnil;
  if (!NIL_P(r_filename))
  {
    filename = StringValueCStr(r_filename);
  }
  else
  {
    filename = random_string();
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
