#include "quickjsrb.h"
#include "quickjsrb_file.h"

static VALUE r_find_alive_rb_file(JSContext *ctx, JSValue j_handle)
{
  int64_t handle;
  JS_ToInt64(ctx, &handle, j_handle);
  VMData *data = JS_GetContextOpaque(ctx);
  return rb_hash_aref(data->alive_objects, LONG2NUM(handle));
}

static JSValue js_ruby_file_name(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  VALUE r_file = r_find_alive_rb_file(ctx, argv[0]);
  if (NIL_P(r_file))
    return JS_UNDEFINED;

  VALUE r_path = rb_funcall(r_file, rb_intern("path"), 0);
  VALUE r_basename = rb_funcall(rb_cFile, rb_intern("basename"), 1, r_path);
  return JS_NewString(ctx, StringValueCStr(r_basename));
}

static JSValue js_ruby_file_size(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  VALUE r_file = r_find_alive_rb_file(ctx, argv[0]);
  if (NIL_P(r_file))
    return JS_UNDEFINED;

  VALUE r_size = rb_funcall(r_file, rb_intern("size"), 0);
  return JS_NewInt64(ctx, NUM2LONG(r_size));
}

static JSValue js_ruby_file_type(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  return JS_NewString(ctx, "");
}

static JSValue js_ruby_file_last_modified(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  VALUE r_file = r_find_alive_rb_file(ctx, argv[0]);
  if (NIL_P(r_file))
    return JS_UNDEFINED;

  VALUE r_mtime = rb_funcall(r_file, rb_intern("mtime"), 0);
  VALUE r_epoch_f = rb_funcall(r_mtime, rb_intern("to_f"), 0);
  double epoch_ms = NUM2DBL(r_epoch_f) * 1000.0;
  return JS_NewFloat64(ctx, epoch_ms);
}

static JSValue js_ruby_file_text(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  VALUE r_file = r_find_alive_rb_file(ctx, argv[0]);
  if (NIL_P(r_file))
    return JS_UNDEFINED;

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  rb_funcall(r_file, rb_intern("rewind"), 0);
  VALUE r_content = rb_funcall(r_file, rb_intern("read"), 0);
  JSValue j_content = JS_NewString(ctx, StringValueCStr(r_content));

  JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, &j_content);
  JS_FreeValue(ctx, j_content);
  JS_FreeValue(ctx, ret);
  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static JSValue js_ruby_file_array_buffer(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  VALUE r_file = r_find_alive_rb_file(ctx, argv[0]);
  if (NIL_P(r_file))
    return JS_UNDEFINED;

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  rb_funcall(r_file, rb_intern("rewind"), 0);
  VALUE r_content = rb_funcall(r_file, rb_intern("read"), 0);
  rb_funcall(r_content, rb_intern("force_encoding"), 1, rb_str_new_cstr("BINARY"));
  long len = RSTRING_LEN(r_content);
  const char *ptr = RSTRING_PTR(r_content);

  JSValue j_buf = JS_NewArrayBufferCopy(ctx, (const uint8_t *)ptr, len);

  JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, &j_buf);
  JS_FreeValue(ctx, j_buf);
  JS_FreeValue(ctx, ret);
  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static JSValue js_ruby_file_slice(JSContext *ctx, JSValueConst _this, int argc, JSValueConst *argv)
{
  VALUE r_file = r_find_alive_rb_file(ctx, argv[0]);
  if (NIL_P(r_file))
    return JS_UNDEFINED;

  VALUE r_size = rb_funcall(r_file, rb_intern("size"), 0);
  long file_size = NUM2LONG(r_size);

  long start = 0;
  if (argc > 1 && !JS_IsUndefined(argv[1]))
  {
    int64_t s;
    JS_ToInt64(ctx, &s, argv[1]);
    start = (long)s;
    if (start < 0)
      start = file_size + start;
    if (start < 0)
      start = 0;
    if (start > file_size)
      start = file_size;
  }

  long end = file_size;
  if (argc > 2 && !JS_IsUndefined(argv[2]))
  {
    int64_t e;
    JS_ToInt64(ctx, &e, argv[2]);
    end = (long)e;
    if (end < 0)
      end = file_size + end;
    if (end < 0)
      end = 0;
    if (end > file_size)
      end = file_size;
  }

  const char *content_type = "";
  if (argc > 3 && JS_IsString(argv[3]))
    content_type = JS_ToCString(ctx, argv[3]);

  long len = end > start ? end - start : 0;

  rb_funcall(r_file, rb_intern("rewind"), 0);
  if (start > 0)
    rb_funcall(r_file, rb_intern("seek"), 1, LONG2NUM(start));
  VALUE r_bytes = rb_funcall(r_file, rb_intern("read"), 1, LONG2NUM(len));
  rb_funcall(r_bytes, rb_intern("force_encoding"), 1, rb_str_new_cstr("BINARY"));

  JSValue j_buf = JS_NewArrayBufferCopy(ctx, (const uint8_t *)RSTRING_PTR(r_bytes), RSTRING_LEN(r_bytes));
  JSValue j_global = JS_GetGlobalObject(ctx);
  JSValue j_uint8_ctor = JS_GetPropertyStr(ctx, j_global, "Uint8Array");
  JSValue j_uint8 = JS_CallConstructor(ctx, j_uint8_ctor, 1, &j_buf);

  JSValue j_parts = JS_NewArray(ctx);
  JS_SetPropertyUint32(ctx, j_parts, 0, j_uint8);

  JSValue j_opts = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, j_opts, "type", JS_NewString(ctx, content_type));

  JSValue j_blob_ctor = JS_GetPropertyStr(ctx, j_global, "Blob");
  JSValueConst blob_args[2] = {j_parts, j_opts};
  JSValue j_blob = JS_CallConstructor(ctx, j_blob_ctor, 2, blob_args);

  if (argc > 3 && JS_IsString(argv[3]))
    JS_FreeCString(ctx, content_type);

  JS_FreeValue(ctx, j_buf);
  JS_FreeValue(ctx, j_uint8_ctor);
  JS_FreeValue(ctx, j_parts);
  JS_FreeValue(ctx, j_opts);
  JS_FreeValue(ctx, j_blob_ctor);
  JS_FreeValue(ctx, j_global);

  return j_blob;
}

void quickjsrb_init_file_proxy(VMData *data)
{
  const char *factory_src =
      "(function(getName, getSize, getType, getLastModified, getText, getArrayBuffer, getSlice) {\n"
      "  return function(handle) {\n"
      "    var target = Object.create(File.prototype);\n"
      "    Object.defineProperty(target, 'rb_object_id', { value: handle, enumerable: false });\n"
      "    return new Proxy(target, {\n"
      "      getPrototypeOf: function() { return File.prototype; },\n"
      "      get: function(target, prop, receiver) {\n"
      "        if (prop === 'name') return getName(handle);\n"
      "        if (prop === 'size') return getSize(handle);\n"
      "        if (prop === 'type') return getType(handle);\n"
      "        if (prop === 'lastModified') return getLastModified(handle);\n"
      "        if (prop === 'text') return function() { return getText(handle); };\n"
      "        if (prop === 'arrayBuffer') return function() { return getArrayBuffer(handle); };\n"
      "        if (prop === 'slice') return function(start, end, contentType) { return getSlice(handle, start, end, contentType); };\n"
      "        if (prop === Symbol.toStringTag) return 'File';\n"
      "        if (prop === 'toString') return function() { return '[object File]'; };\n"
      "        return Reflect.get(target, prop, receiver);\n"
      "      }\n"
      "    });\n"
      "  };\n"
      "})";
  JSValue j_factory_fn = JS_Eval(data->context, factory_src, strlen(factory_src), "<file-proxy>", JS_EVAL_TYPE_GLOBAL);

  JSValue j_helpers[7];
  j_helpers[0] = JS_NewCFunction(data->context, js_ruby_file_name, "__rb_file_name", 1);
  j_helpers[1] = JS_NewCFunction(data->context, js_ruby_file_size, "__rb_file_size", 1);
  j_helpers[2] = JS_NewCFunction(data->context, js_ruby_file_type, "__rb_file_type", 1);
  j_helpers[3] = JS_NewCFunction(data->context, js_ruby_file_last_modified, "__rb_file_last_modified", 1);
  j_helpers[4] = JS_NewCFunction(data->context, js_ruby_file_text, "__rb_file_text", 1);
  j_helpers[5] = JS_NewCFunction(data->context, js_ruby_file_array_buffer, "__rb_file_array_buffer", 1);
  j_helpers[6] = JS_NewCFunction(data->context, js_ruby_file_slice, "__rb_file_slice", 4);

  data->j_file_proxy_creator = JS_Call(data->context, j_factory_fn, JS_UNDEFINED, 7, j_helpers);

  JS_FreeValue(data->context, j_factory_fn);
  for (int i = 0; i < 7; i++)
    JS_FreeValue(data->context, j_helpers[i]);
}

JSValue quickjsrb_file_to_js(JSContext *ctx, VALUE r_file)
{
  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_object_id = rb_funcall(r_file, rb_intern("object_id"), 0);
  rb_hash_aset(data->alive_objects, r_object_id, r_file);
  JSValue j_handle = JS_NewInt64(ctx, NUM2LONG(r_object_id));
  JSValue j_proxy = JS_Call(ctx, data->j_file_proxy_creator, JS_UNDEFINED, 1, &j_handle);
  JS_FreeValue(ctx, j_handle);
  return j_proxy;
}
