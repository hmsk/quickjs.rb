#include "quickjsrb.h"
#include "quickjsrb_crypto.h"

static VALUE r_secure_random()
{
  return rb_const_get(rb_cObject, rb_intern("SecureRandom"));
}

static JSValue js_crypto_get_random_values(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 1)
    return JS_ThrowTypeError(ctx, "Failed to execute 'getRandomValues': 1 argument required, but only 0 present.");

  size_t byte_offset, byte_length, bytes_per_element;
  JSValue j_buffer = JS_GetTypedArrayBuffer(ctx, argv[0], &byte_offset, &byte_length, &bytes_per_element);
  if (JS_IsException(j_buffer))
    return JS_EXCEPTION;

  JSValue j_ctor = JS_GetPropertyStr(ctx, argv[0], "constructor");
  JSValue j_name = JS_GetPropertyStr(ctx, j_ctor, "name");
  const char *name = JS_ToCString(ctx, j_name);
  int is_float = name && (strcmp(name, "Float16Array") == 0 ||
                          strcmp(name, "Float32Array") == 0 ||
                          strcmp(name, "Float64Array") == 0);
  JS_FreeCString(ctx, name);
  JS_FreeValue(ctx, j_name);
  JS_FreeValue(ctx, j_ctor);

  if (is_float)
  {
    JS_FreeValue(ctx, j_buffer);
    return JS_ThrowTypeError(ctx, "Failed to execute 'getRandomValues': The provided ArrayBufferView value must not be of floating-point type.");
  }

  if (byte_length > 65536)
  {
    JS_FreeValue(ctx, j_buffer);
    return JS_ThrowRangeError(ctx, "Failed to execute 'getRandomValues': The ArrayBufferView's byte length exceeds the number of bytes of entropy available via this API (65536).");
  }

  size_t buf_size;
  uint8_t *buf = JS_GetArrayBuffer(ctx, &buf_size, j_buffer);
  JS_FreeValue(ctx, j_buffer);

  if (!buf)
    return JS_ThrowTypeError(ctx, "Failed to execute 'getRandomValues': Failed to get ArrayBuffer.");

  VALUE r_random_bytes = rb_funcall(r_secure_random(), rb_intern("random_bytes"), 1, SIZET2NUM(byte_length));
  const uint8_t *random_buf = (const uint8_t *)RSTRING_PTR(r_random_bytes);
  memcpy(buf + byte_offset, random_buf, byte_length);

  return JS_DupValue(ctx, argv[0]);
}

static JSValue js_crypto_random_uuid(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  VALUE r_uuid = rb_funcall(r_secure_random(), rb_intern("uuid"), 0);
  return JS_NewString(ctx, StringValueCStr(r_uuid));
}

void quickjsrb_init_crypto(JSContext *ctx, JSValue j_global)
{
  JSValue j_crypto = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, j_crypto, "getRandomValues",
                    JS_NewCFunction(ctx, js_crypto_get_random_values, "getRandomValues", 1));
  JS_SetPropertyStr(ctx, j_crypto, "randomUUID",
                    JS_NewCFunction(ctx, js_crypto_random_uuid, "randomUUID", 0));
  JS_SetPropertyStr(ctx, j_global, "crypto", j_crypto);
}
