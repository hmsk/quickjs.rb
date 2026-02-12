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

void quickjsrb_init_file_proxy(VMData *data)
{
  const char *factory_src =
      "(function(getName, getSize, getType, getLastModified) {\n"
      "  return function(handle) {\n"
      "    return new Proxy(Object.create(File.prototype), {\n"
      "      getPrototypeOf: function() { return File.prototype; },\n"
      "      get: function(target, prop, receiver) {\n"
      "        if (prop === 'name') return getName(handle);\n"
      "        if (prop === 'size') return getSize(handle);\n"
      "        if (prop === 'type') return getType(handle);\n"
      "        if (prop === 'lastModified') return getLastModified(handle);\n"
      "        if (prop === Symbol.toStringTag) return 'File';\n"
      "        if (prop === 'toString') return function() { return '[object File]'; };\n"
      "        return Reflect.get(target, prop, receiver);\n"
      "      }\n"
      "    });\n"
      "  };\n"
      "})";
  JSValue j_factory_fn = JS_Eval(data->context, factory_src, strlen(factory_src), "<file-proxy>", JS_EVAL_TYPE_GLOBAL);

  JSValue j_helpers[4];
  j_helpers[0] = JS_NewCFunction(data->context, js_ruby_file_name, "__rb_file_name", 1);
  j_helpers[1] = JS_NewCFunction(data->context, js_ruby_file_size, "__rb_file_size", 1);
  j_helpers[2] = JS_NewCFunction(data->context, js_ruby_file_type, "__rb_file_type", 1);
  j_helpers[3] = JS_NewCFunction(data->context, js_ruby_file_last_modified, "__rb_file_last_modified", 1);

  data->j_file_proxy_creator = JS_Call(data->context, j_factory_fn, JS_UNDEFINED, 4, j_helpers);

  JS_FreeValue(data->context, j_factory_fn);
  for (int i = 0; i < 4; i++)
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
