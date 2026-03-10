#include "quickjsrb.h"
#include "quickjsrb_crypto_subtle.h"

// Extract algorithm name from a string or { name: "..." } object.
// Caller must JS_FreeCString the result.
static const char *js_get_algorithm_name(JSContext *ctx, JSValueConst j_algo)
{
  if (JS_IsString(j_algo))
    return JS_ToCString(ctx, j_algo);
  JSValue j_name = JS_GetPropertyStr(ctx, j_algo, "name");
  const char *name = JS_ToCString(ctx, j_name);
  JS_FreeValue(ctx, j_name);
  return name;
}

// Convert a JS ArrayBuffer or TypedArray to a Ruby binary String.
// Returns Qnil if the value is neither.
static VALUE js_buffer_to_ruby_str(JSContext *ctx, JSValueConst j_val)
{
  size_t byte_offset = 0, byte_length = 0, bytes_per_element = 0;
  int is_typed_array = 1;
  JSValue j_buf = JS_GetTypedArrayBuffer(ctx, j_val, &byte_offset, &byte_length, &bytes_per_element);
  if (JS_IsException(j_buf))
  {
    JSValue j_exc = JS_GetException(ctx);
    JS_FreeValue(ctx, j_exc);
    is_typed_array = 0;
    j_buf = JS_DupValue(ctx, j_val);
  }

  size_t buf_size;
  uint8_t *buf = JS_GetArrayBuffer(ctx, &buf_size, j_buf);
  JS_FreeValue(ctx, j_buf);

  if (!buf)
    return Qnil;

  size_t len = is_typed_array ? byte_length : buf_size;
  VALUE r_str = rb_str_new((const char *)(buf + byte_offset), len);
  rb_funcall(r_str, rb_intern("force_encoding"), 1, rb_str_new_cstr("BINARY"));
  return r_str;
}

// Build a Ruby Array of strings from a JS array value.
static VALUE js_usages_to_ruby_array(JSContext *ctx, JSValueConst j_usages)
{
  VALUE r_usages = rb_ary_new();
  JSValue j_len = JS_GetPropertyStr(ctx, j_usages, "length");
  int32_t count = 0;
  JS_ToInt32(ctx, &count, j_len);
  JS_FreeValue(ctx, j_len);
  for (int32_t i = 0; i < count; i++)
  {
    JSValue j_u = JS_GetPropertyUint32(ctx, j_usages, (uint32_t)i);
    const char *u_str = JS_ToCString(ctx, j_u);
    if (u_str)
      rb_ary_push(r_usages, rb_str_new_cstr(u_str));
    JS_FreeCString(ctx, u_str);
    JS_FreeValue(ctx, j_u);
  }
  return r_usages;
}

// Reject a promise with a plain JS Error built from Ruby exception info.
static void js_reject_with_ruby_error(JSContext *ctx, JSValueConst *resolving_funcs)
{
  VALUE r_error = rb_errinfo();
  VALUE r_message = rb_funcall(r_error, rb_intern("message"), 0);
  JSValue j_err = JS_NewError(ctx);
  JS_SetPropertyStr(ctx, j_err, "message", JS_NewString(ctx, StringValueCStr(r_message)));
  JSValue ret = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED, 1, (JSValueConst *)&j_err);
  JS_FreeValue(ctx, j_err);
  JS_FreeValue(ctx, ret);
}

// Build a JS CryptoKey plain object from a Ruby Quickjs::CryptoKey.
// Stores the Ruby object in alive_objects; sets rb_object_id as non-enumerable.
static JSValue js_crypto_key_to_js(JSContext *ctx, VALUE r_key)
{
  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_object_id = rb_funcall(r_key, rb_intern("object_id"), 0);
  rb_hash_aset(data->alive_objects, r_object_id, r_key);
  int64_t handle = NUM2LONG(r_object_id);

  VALUE r_type = rb_funcall(r_key, rb_intern("type"), 0);
  VALUE r_extractable = rb_funcall(r_key, rb_intern("extractable"), 0);
  VALUE r_algorithm = rb_funcall(r_key, rb_intern("algorithm"), 0);
  VALUE r_usages = rb_funcall(r_key, rb_intern("usages"), 0);

  JSValue j_key = JS_NewObject(ctx);

  JS_SetPropertyStr(ctx, j_key, "type", JS_NewString(ctx, StringValueCStr(r_type)));
  JS_SetPropertyStr(ctx, j_key, "extractable", JS_NewBool(ctx, RTEST(r_extractable)));

  JSValue j_algo = JS_NewObject(ctx);
  VALUE r_algo_name = rb_hash_aref(r_algorithm, rb_str_new_cstr("name"));
  VALUE r_algo_length = rb_hash_aref(r_algorithm, rb_str_new_cstr("length"));
  JS_SetPropertyStr(ctx, j_algo, "name", JS_NewString(ctx, StringValueCStr(r_algo_name)));
  if (!NIL_P(r_algo_length))
    JS_SetPropertyStr(ctx, j_algo, "length", JS_NewInt32(ctx, NUM2INT(r_algo_length)));
  JS_SetPropertyStr(ctx, j_key, "algorithm", j_algo);

  long usages_len = RARRAY_LEN(r_usages);
  JSValue j_usages = JS_NewArray(ctx);
  for (long i = 0; i < usages_len; i++)
  {
    VALUE r_usage = rb_ary_entry(r_usages, i);
    JS_SetPropertyUint32(ctx, j_usages, (uint32_t)i, JS_NewString(ctx, StringValueCStr(r_usage)));
  }
  JS_SetPropertyStr(ctx, j_key, "usages", j_usages);

  JS_DefinePropertyValueStr(ctx, j_key, "rb_object_id",
                            JS_NewInt64(ctx, handle),
                            JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);

  return j_key;
}

// Find Ruby CryptoKey from a JS CryptoKey object via rb_object_id handle.
static VALUE r_find_alive_crypto_key(JSContext *ctx, JSValueConst j_key)
{
  JSValue j_handle = JS_GetPropertyStr(ctx, j_key, "rb_object_id");
  int64_t handle = 0;
  JS_ToInt64(ctx, &handle, j_handle);
  JS_FreeValue(ctx, j_handle);
  if (handle <= 0)
    return Qnil;
  VMData *data = JS_GetContextOpaque(ctx);
  return rb_hash_aref(data->alive_objects, LONG2NUM(handle));
}

static VALUE r_subtle_digest_call(VALUE r_args)
{
  VALUE r_algorithm = rb_ary_entry(r_args, 0);
  VALUE r_data = rb_ary_entry(r_args, 1);
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("digest"), 2, r_algorithm, r_data);
}

static JSValue js_subtle_digest(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 2)
    return JS_ThrowTypeError(ctx, "Failed to execute 'digest': 2 arguments required.");

  const char *algorithm_name = js_get_algorithm_name(ctx, argv[0]);
  if (!algorithm_name)
    return JS_ThrowTypeError(ctx, "Failed to execute 'digest': algorithm name is required.");
  VALUE r_algorithm = rb_str_new_cstr(algorithm_name);
  JS_FreeCString(ctx, algorithm_name);

  VALUE r_data = js_buffer_to_ruby_str(ctx, argv[1]);
  if (NIL_P(r_data))
    return JS_ThrowTypeError(ctx, "Failed to execute 'digest': data must be an ArrayBuffer or TypedArray.");

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(2, r_algorithm, r_data);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_digest_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    JSValue j_result = JS_NewArrayBufferCopy(ctx, (const uint8_t *)RSTRING_PTR(r_result), RSTRING_LEN(r_result));
    JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
    JS_FreeValue(ctx, j_result);
    JS_FreeValue(ctx, ret);
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static VALUE r_subtle_generate_key_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("generate_key"), 4,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3));
}

static JSValue js_subtle_generate_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 3)
    return JS_ThrowTypeError(ctx, "Failed to execute 'generateKey': 3 arguments required.");

  const char *algo_name = js_get_algorithm_name(ctx, argv[0]);
  if (!algo_name)
    return JS_ThrowTypeError(ctx, "Failed to execute 'generateKey': algorithm name is required.");
  VALUE r_name = rb_str_new_cstr(algo_name);
  JS_FreeCString(ctx, algo_name);

  JSValue j_length = JS_GetPropertyStr(ctx, argv[0], "length");
  int32_t length = 0;
  if (!JS_IsUndefined(j_length) && !JS_IsException(j_length))
    JS_ToInt32(ctx, &length, j_length);
  JS_FreeValue(ctx, j_length);

  VALUE r_extractable = JS_ToBool(ctx, argv[1]) ? Qtrue : Qfalse;
  VALUE r_usages = js_usages_to_ruby_array(ctx, argv[2]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(4, r_name, INT2NUM(length), r_extractable, r_usages);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_generate_key_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    JSValue j_result = js_crypto_key_to_js(ctx, r_result);
    JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
    JS_FreeValue(ctx, j_result);
    JS_FreeValue(ctx, ret);
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static VALUE r_subtle_import_key_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("import_key"), 5,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3),
                    rb_ary_entry(r_args, 4));
}

static JSValue js_subtle_import_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 5)
    return JS_ThrowTypeError(ctx, "Failed to execute 'importKey': 5 arguments required.");

  const char *format_cstr = JS_ToCString(ctx, argv[0]);
  if (!format_cstr)
    return JS_ThrowTypeError(ctx, "Failed to execute 'importKey': format must be a string.");
  VALUE r_format = rb_str_new_cstr(format_cstr);
  JS_FreeCString(ctx, format_cstr);

  VALUE r_key_data = js_buffer_to_ruby_str(ctx, argv[1]);
  if (NIL_P(r_key_data))
    return JS_ThrowTypeError(ctx, "Failed to execute 'importKey': keyData must be an ArrayBuffer or TypedArray.");

  const char *algo_name = js_get_algorithm_name(ctx, argv[2]);
  if (!algo_name)
    return JS_ThrowTypeError(ctx, "Failed to execute 'importKey': algorithm name is required.");
  VALUE r_name = rb_str_new_cstr(algo_name);
  JS_FreeCString(ctx, algo_name);

  VALUE r_extractable = JS_ToBool(ctx, argv[3]) ? Qtrue : Qfalse;
  VALUE r_usages = js_usages_to_ruby_array(ctx, argv[4]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(5, r_format, r_key_data, r_name, r_extractable, r_usages);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_import_key_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    JSValue j_result = js_crypto_key_to_js(ctx, r_result);
    JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
    JS_FreeValue(ctx, j_result);
    JS_FreeValue(ctx, ret);
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static VALUE r_subtle_export_key_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("export_key"), 2,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1));
}

static JSValue js_subtle_export_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 2)
    return JS_ThrowTypeError(ctx, "Failed to execute 'exportKey': 2 arguments required.");

  const char *format_cstr = JS_ToCString(ctx, argv[0]);
  if (!format_cstr)
    return JS_ThrowTypeError(ctx, "Failed to execute 'exportKey': format must be a string.");
  VALUE r_format = rb_str_new_cstr(format_cstr);
  JS_FreeCString(ctx, format_cstr);

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'exportKey': invalid CryptoKey.");

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(2, r_format, r_key);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_export_key_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    JSValue j_result = JS_NewArrayBufferCopy(ctx, (const uint8_t *)RSTRING_PTR(r_result), RSTRING_LEN(r_result));
    JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
    JS_FreeValue(ctx, j_result);
    JS_FreeValue(ctx, ret);
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static VALUE r_subtle_encrypt_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("encrypt"), 4,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3));
}

static VALUE r_subtle_decrypt_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("decrypt"), 4,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3));
}

// Build Ruby keyword args Hash from AES-GCM/CBC algorithm params.
static VALUE js_algo_params_to_ruby_hash(JSContext *ctx, JSValueConst j_algo)
{
  VALUE r_params = rb_hash_new();

  JSValue j_iv = JS_GetPropertyStr(ctx, j_algo, "iv");
  if (!JS_IsUndefined(j_iv) && !JS_IsException(j_iv))
  {
    VALUE r_iv = js_buffer_to_ruby_str(ctx, j_iv);
    if (!NIL_P(r_iv))
      rb_hash_aset(r_params, ID2SYM(rb_intern("iv")), r_iv);
  }
  JS_FreeValue(ctx, j_iv);

  JSValue j_tag_length = JS_GetPropertyStr(ctx, j_algo, "tagLength");
  if (!JS_IsUndefined(j_tag_length) && !JS_IsException(j_tag_length))
  {
    int32_t tag_length = 128;
    JS_ToInt32(ctx, &tag_length, j_tag_length);
    rb_hash_aset(r_params, ID2SYM(rb_intern("tag_length")), INT2NUM(tag_length));
  }
  JS_FreeValue(ctx, j_tag_length);

  JSValue j_additional_data = JS_GetPropertyStr(ctx, j_algo, "additionalData");
  if (!JS_IsUndefined(j_additional_data) && !JS_IsException(j_additional_data))
  {
    VALUE r_ad = js_buffer_to_ruby_str(ctx, j_additional_data);
    if (!NIL_P(r_ad))
      rb_hash_aset(r_params, ID2SYM(rb_intern("additional_data")), r_ad);
  }
  JS_FreeValue(ctx, j_additional_data);

  return r_params;
}

// Shared implementation for encrypt/decrypt.
// r_call_func: either r_subtle_encrypt_call or r_subtle_decrypt_call
static JSValue js_subtle_crypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv,
                               VALUE (*r_call_func)(VALUE))
{
  if (argc < 3)
    return JS_ThrowTypeError(ctx, "3 arguments required.");

  const char *algo_name = js_get_algorithm_name(ctx, argv[0]);
  if (!algo_name)
    return JS_ThrowTypeError(ctx, "algorithm name is required.");
  VALUE r_name = rb_str_new_cstr(algo_name);
  JS_FreeCString(ctx, algo_name);

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "invalid CryptoKey.");

  VALUE r_data = js_buffer_to_ruby_str(ctx, argv[2]);
  if (NIL_P(r_data))
    return JS_ThrowTypeError(ctx, "data must be an ArrayBuffer or TypedArray.");

  VALUE r_params = js_algo_params_to_ruby_hash(ctx, argv[0]);

  // Merge key and params into a single Ruby object for the call
  // We pass [name, key_with_params, data] — but encrypt() signature is (name, key, data, **params)
  // Instead, attach params to key via a wrapper hash: [name, key, data, params]
  // Actually let's just call encrypt with keyword splat by building a special args array.
  // Since rb_protect only takes one VALUE, pack everything.
  VALUE r_args = rb_ary_new3(4, r_name, r_key, r_data, r_params);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  int error_state;
  VALUE r_result = rb_protect(r_call_func, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    JSValue j_result = JS_NewArrayBufferCopy(ctx, (const uint8_t *)RSTRING_PTR(r_result), RSTRING_LEN(r_result));
    JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
    JS_FreeValue(ctx, j_result);
    JS_FreeValue(ctx, ret);
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static JSValue js_subtle_encrypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  return js_subtle_crypt(ctx, this_val, argc, argv, r_subtle_encrypt_call);
}

static JSValue js_subtle_decrypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  return js_subtle_crypt(ctx, this_val, argc, argv, r_subtle_decrypt_call);
}

void quickjsrb_init_crypto_subtle(JSContext *ctx, JSValueConst j_crypto)
{
  JSValue j_subtle = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, j_subtle, "digest",
                    JS_NewCFunction(ctx, js_subtle_digest, "digest", 2));
  JS_SetPropertyStr(ctx, j_subtle, "generateKey",
                    JS_NewCFunction(ctx, js_subtle_generate_key, "generateKey", 3));
  JS_SetPropertyStr(ctx, j_subtle, "importKey",
                    JS_NewCFunction(ctx, js_subtle_import_key, "importKey", 5));
  JS_SetPropertyStr(ctx, j_subtle, "exportKey",
                    JS_NewCFunction(ctx, js_subtle_export_key, "exportKey", 2));
  JS_SetPropertyStr(ctx, j_subtle, "encrypt",
                    JS_NewCFunction(ctx, js_subtle_encrypt, "encrypt", 3));
  JS_SetPropertyStr(ctx, j_subtle, "decrypt",
                    JS_NewCFunction(ctx, js_subtle_decrypt, "decrypt", 3));
  JS_SetPropertyStr(ctx, j_crypto, "subtle", j_subtle);
}
