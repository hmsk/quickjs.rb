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

  JSValue j_result, ret;
  if (error_state)
  {
    VALUE r_error = rb_errinfo();
    VALUE r_message = rb_funcall(r_error, rb_intern("message"), 0);
    j_result = JS_NewError(ctx);
    JS_SetPropertyStr(ctx, j_result, "message", JS_NewString(ctx, StringValueCStr(r_message)));
    ret = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
  }
  else
  {
    j_result = JS_NewArrayBufferCopy(ctx, (const uint8_t *)RSTRING_PTR(r_result), RSTRING_LEN(r_result));
    ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
  }

  JS_FreeValue(ctx, j_result);
  JS_FreeValue(ctx, ret);
  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

void quickjsrb_init_crypto_subtle(JSContext *ctx, JSValueConst j_crypto)
{
  JSValue j_subtle = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, j_subtle, "digest",
                    JS_NewCFunction(ctx, js_subtle_digest, "digest", 2));
  JS_SetPropertyStr(ctx, j_crypto, "subtle", j_subtle);
}
