#include "quickjsrb.h"
#include "quickjsrb_crypto_subtle.h"

// Extract algorithm name from a string or { name: "..." } object.
// Caller must JS_FreeCString the result.
static const char *js_get_algorithm_name(JSContext *ctx, JSValueConst j_algo)
{
  if (JS_IsString(j_algo))
  {
    // Drained like the reads below: a conversion that cannot allocate answers
    // NULL with its throw still set, and the caller reports a missing
    // algorithm name over the top of it.
    const char *name = JS_ToCString(ctx, j_algo);
    if (name == NULL)
      quickjsrb_drain_pending(ctx);
    return name;
  }
  // A getter answers this read, so it can throw, and a throw from a bridge
  // carries a host exception that only find_ruby_error takes back out of
  // alive_objects. Same for the conversion below, which runs toString.
  JSValue j_name = JS_GetPropertyStr(ctx, j_algo, "name");
  if (JS_IsException(j_name))
  {
    quickjsrb_drain_pending(ctx);
    return NULL;
  }

  const char *name = JS_ToCString(ctx, j_name);
  JS_FreeValue(ctx, j_name);
  if (name == NULL)
    quickjsrb_drain_pending(ctx);
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
  // Every read here is a property of an object the guest handed in, answerable
  // by a getter that can reach a bridge, so each drains what it throws for the
  // reason js_algo_read gives. What the operation then does with a usages list
  // that could not be read is the refusal path nothing has yet: #130.
  VALUE r_usages = rb_ary_new();
  JSValue j_len = JS_GetPropertyStr(ctx, j_usages, "length");
  if (JS_IsException(j_len))
  {
    quickjsrb_drain_pending(ctx);
    return r_usages;
  }

  int32_t count = 0;
  if (JS_ToInt32(ctx, &count, j_len) < 0)
  {
    quickjsrb_drain_pending(ctx);
    count = 0;
  }
  JS_FreeValue(ctx, j_len);

  for (int32_t i = 0; i < count; i++)
  {
    JSValue j_u = JS_GetPropertyUint32(ctx, j_usages, (uint32_t)i);
    if (JS_IsException(j_u))
    {
      quickjsrb_drain_pending(ctx);
      continue;
    }

    const char *u_str = JS_ToCString(ctx, j_u);
    if (u_str)
      rb_ary_push(r_usages, rb_str_new_cstr(u_str));
    else
      quickjsrb_drain_pending(ctx);
    JS_FreeCString(ctx, u_str);
    JS_FreeValue(ctx, j_u);
  }
  return r_usages;
}

// Settles with the value, or rejects with whatever stopped it being built.
// Never resolves with the sentinel: typeof reads "unknown" for it and the guest
// has no way to name, catch or discard what it was handed. Always settles, so
// no caller is left returning a promise nothing will ever resolve.
static void js_settle_or_reject(JSContext *ctx, JSValueConst *resolving_funcs, JSValue j_key)
{
  JSValue j_settled;
  if (JS_IsException(j_key))
  {
    // JS_GetException answers JS_UNINITIALIZED when nothing is set, and that
    // is an internal sentinel, not a value to hand a guest. The slot can be
    // empty here: a describe failure sets its throw, and a later step that
    // takes a throw of its own unconditionally clears it on the way past.
    if (!JS_HasException(ctx))
      JS_ThrowInternalError(ctx, "quickjs: the operation failed without saying why");
    JSValue j_thrown = JS_GetException(ctx);
    j_settled = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED, 1, (JSValueConst *)&j_thrown);
    JS_FreeValue(ctx, j_thrown);
  }
  else
  {
    j_settled = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_key);
    JS_FreeValue(ctx, j_key);
  }
  JS_FreeValue(ctx, j_settled);
}

// Reject a promise with a plain JS Error built from Ruby exception info.
static void js_reject_with_ruby_error(JSContext *ctx, JSValueConst *resolving_funcs)
{
  VALUE r_error = rb_errinfo();
  rb_set_errinfo(Qnil);
  VALUE r_message = rb_funcall(r_error, rb_intern("message"), 0);
  JSValue j_err = JS_NewError(ctx);
  if (JS_IsException(j_err))
  {
    // Settling with the sentinel would hand the guest a value it cannot name,
    // which is what js_quickjsrb_call_global refuses to do for the same reason.
    // The runtime's own throw is the honest answer, and it is already pending.
    // Nothing left to describe the failure with, so the promise is rejected
    // with the runtime's own throw rather than left for a guest that is still
    // awaiting it, and rather than carried out of here to be attributed to
    // whatever asks for an exception next.
    JS_FreeValue(ctx, j_err);
    js_settle_or_reject(ctx, resolving_funcs, JS_EXCEPTION);
    return;
  }
  // Defined, not assigned, for the reason j_error_from_ruby_error gives: an
  // accessor on Error.prototype absorbs the write, and the guest reads whatever
  // that getter says instead of why its call was rejected. Built first and
  // checked, so the sentinel is never what the error says its message is.
  JSValue j_message = JS_NewString(ctx, StringValueCStr(r_message));
  if (JS_IsException(j_message))
  {
    JS_FreeValue(ctx, j_message);
    JS_FreeValue(ctx, j_err);
    js_settle_or_reject(ctx, resolving_funcs, JS_EXCEPTION);
    return;
  }
  if (JS_DefinePropertyValueStr(ctx, j_err, "message", j_message,
                                JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) < 0)
  {
    // An Error with no own message is one Error.prototype answers for, which
    // is what defining it was for, and the define's throw would be left to
    // land on an unrelated evaluation.
    JS_FreeValue(ctx, j_err);
    js_settle_or_reject(ctx, resolving_funcs, JS_EXCEPTION);
    return;
  }
  JSValue ret = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED, 1, (JSValueConst *)&j_err);
  JS_FreeValue(ctx, j_err);
  JS_FreeValue(ctx, ret);
}

// Quickjs::CryptoKey, or Qnil while the Ruby layer that defines it has not been
// loaded — requiring the extension alone is enough to reach the callers below.
// Resolved without rb_const_get's raise, because these run inside QuickJS
// native callbacks with no rb_protect between them and the interpreter: a
// NameError there longjmps through QuickJS's own frames, past the JS values
// they still hold.
//
// Looked up per call rather than cached in a static. A class held only by a
// constant table is movable, so a cached VALUE survives GC.compact as an
// address the collector has since handed to something else — which would name
// the wrong class, or a non-class that makes rb_obj_is_kind_of raise the very
// unprotected raise this function exists to avoid. Two constant lookups are
// nothing beside the OpenSSL work every caller goes on to do.
static VALUE r_crypto_key_class(void)
{
  // Gated too, though Init_quickjsrb defines it before any of this can run.
  // Not for the promise, which every caller creates after resolving the key,
  // but because a raise out of a JSCFunction unwinds past QuickJS's own call
  // frame, which is what this function exists to answer instead of.
  if (!rb_const_defined_at(rb_cObject, rb_intern("Quickjs")))
    return Qnil;
  // Defined answers true for an autoload here too, and rb_const_get would run
  // its body from this callback, which is the raise being avoided.
  if (!NIL_P(rb_autoload_p(rb_cObject, rb_intern("Quickjs"))))
    return Qnil;

  VALUE r_quickjs = rb_const_get(rb_cObject, rb_intern("Quickjs"));
  // Same reason the inner one is type-checked: rb_const_defined_at reads a
  // constant table off its receiver, so a non-module bound to the name is
  // worse than the NameError being avoided.
  if (!RB_TYPE_P(r_quickjs, T_MODULE))
    return Qnil;
  if (!rb_const_defined_at(r_quickjs, rb_intern("CryptoKey")))
    return Qnil;
  // Defined answers true for a registered autoload too, and rb_const_get would
  // then run the autoload body here, which is a raise this function cannot
  // afford for the reason above. Nobody autoloads this constant, but the claim
  // has to hold rather than happen to.
  if (!NIL_P(rb_autoload_p(r_quickjs, rb_intern("CryptoKey"))))
    return Qnil;

  VALUE r_class = rb_const_get(r_quickjs, rb_intern("CryptoKey"));
  // Defined is not the same as a class. rb_obj_is_kind_of takes a class or a
  // module and raises TypeError on anything else, so a String bound to the
  // name would make the unprotected raise above; a Module would not raise but
  // is not what a key is an instance of either. One predicate covers both.
  return RB_TYPE_P(r_class, T_CLASS) ? r_class : Qnil;
}

// Find Ruby CryptoKey from a JS CryptoKey object via rb_object_id handle.
static VALUE r_find_alive_crypto_key(JSContext *ctx, JSValueConst j_key)
{
  // Both of the reads below can run the guest's own code on a value it chose:
  // a getter for the property, a valueOf for the conversion, either of which
  // can reach a Ruby bridge. Nothing here can report what that raises, since
  // this runs after its caller's rb_protect has returned, but the exception it
  // parked in alive_objects has to come back out: find_ruby_error is the only
  // thing that takes one out, so leaving it would pin one per call, at a rate
  // the guest picks.
  JSValue j_handle = JS_GetPropertyStr(ctx, j_key, "rb_object_id");
  if (JS_IsException(j_handle))
  {
    quickjsrb_drain_pending(ctx);
    return Qnil;
  }

  // Only a number is a handle. Asking JS_ToInt64 for one is what runs valueOf,
  // and the answer for anything else was never going to be a handle anyway.
  int32_t tag = JS_VALUE_GET_NORM_TAG(j_handle);
  if (tag != JS_TAG_INT && tag != JS_TAG_FLOAT64)
  {
    JS_FreeValue(ctx, j_handle);
    return Qnil;
  }

  int64_t handle = 0;
  JS_ToInt64(ctx, &handle, j_handle);
  JS_FreeValue(ctx, j_handle);
  if (handle <= 0)
    return Qnil;
  VMData *data = JS_GetContextOpaque(ctx);
  VALUE r_key = rb_hash_aref(data->alive_objects, LL2NUM(handle));
  // Before the class lookup, which is otherwise paid on the path a guest can
  // repeat for free: sign('HMAC', {}, buf) reaches no OpenSSL work to dwarf it.
  if (NIL_P(r_key))
    return Qnil;
  // The handle is read off whatever the guest passed as the key, and
  // alive_objects also holds bridged exceptions and the Ruby object behind a
  // File proxy. Without this an object carrying another entry's id reaches the
  // operations below as if it were a key, and the caller is told about a
  // method missing on a File rather than about an invalid CryptoKey.
  VALUE r_key_class = r_crypto_key_class();
  if (NIL_P(r_key_class) || !rb_obj_is_kind_of(r_key, r_key_class))
    return Qnil;
  return r_key;
}

// Every read below is a property of an object the guest handed in, so a getter
// answers it and may throw. The block that follows each read already skips an
// exception, but skipping is not enough: a throw from a bridge carries a host
// exception that find_ruby_error is the only thing to take back out of
// alive_objects, so a skipped one pins it for the life of the VM, once per
// read, at a rate the guest picks.
//
// The read only. What each block then does with the value, JS_ToInt32 on a
// length, JS_ToCString on a curve name, a buffer conversion on an iv, runs the
// guest's valueOf or toString and can throw for the same reason, and those
// returns are unchecked here as they were before. #130.
static JSValue js_algo_read(JSContext *ctx, JSValueConst j_algo, const char *name)
{
  JSValue j_value = JS_GetPropertyStr(ctx, j_algo, name);
  if (JS_IsException(j_value))
    // Taken, not put back. Putting it back and carrying on would leave it
    // pending for the next thing that asks, and carrying on is what this does:
    // the block below skips the property and the operation runs without it. So
    // the guest's own error is lost here, replaced by whatever the call fails
    // with next. Both halves want the same fix, a way for this function to
    // refuse, which its ten callers do not have yet. #130.
    quickjsrb_drain_pending(ctx);
  return j_value;
}

// Build a comprehensive Ruby Hash (symbol keys) from a JS algorithm object.
// Extracts all possible properties used across SubtleCrypto operations.
static VALUE js_algo_to_ruby_hash(JSContext *ctx, JSValueConst j_algo)
{
  VALUE r_hash = rb_hash_new();

  const char *name = js_get_algorithm_name(ctx, j_algo);
  if (name)
  {
    rb_hash_aset(r_hash, ID2SYM(rb_intern("name")), rb_str_new_cstr(name));
    JS_FreeCString(ctx, name);
  }

  if (JS_IsString(j_algo))
    return r_hash;

  JSValue j_length = js_algo_read(ctx, j_algo, "length");
  if (!JS_IsUndefined(j_length) && !JS_IsException(j_length))
  {
    int32_t length = 0;
    JS_ToInt32(ctx, &length, j_length);
    rb_hash_aset(r_hash, ID2SYM(rb_intern("length")), INT2NUM(length));
  }
  JS_FreeValue(ctx, j_length);

  JSValue j_named_curve = js_algo_read(ctx, j_algo, "namedCurve");
  if (!JS_IsUndefined(j_named_curve) && !JS_IsException(j_named_curve))
  {
    const char *nc = JS_ToCString(ctx, j_named_curve);
    if (nc)
    {
      rb_hash_aset(r_hash, ID2SYM(rb_intern("named_curve")), rb_str_new_cstr(nc));
      JS_FreeCString(ctx, nc);
    }
  }
  JS_FreeValue(ctx, j_named_curve);

  JSValue j_hash = js_algo_read(ctx, j_algo, "hash");
  if (!JS_IsUndefined(j_hash) && !JS_IsException(j_hash))
  {
    const char *hash_name = js_get_algorithm_name(ctx, j_hash);
    if (hash_name)
    {
      rb_hash_aset(r_hash, ID2SYM(rb_intern("hash")), rb_str_new_cstr(hash_name));
      JS_FreeCString(ctx, hash_name);
    }
  }
  JS_FreeValue(ctx, j_hash);

  JSValue j_modulus_length = js_algo_read(ctx, j_algo, "modulusLength");
  if (!JS_IsUndefined(j_modulus_length) && !JS_IsException(j_modulus_length))
  {
    int32_t mod_len = 0;
    JS_ToInt32(ctx, &mod_len, j_modulus_length);
    rb_hash_aset(r_hash, ID2SYM(rb_intern("modulus_length")), INT2NUM(mod_len));
  }
  JS_FreeValue(ctx, j_modulus_length);

  JSValue j_pub_exp = js_algo_read(ctx, j_algo, "publicExponent");
  if (!JS_IsUndefined(j_pub_exp) && !JS_IsException(j_pub_exp))
  {
    VALUE r_pe = js_buffer_to_ruby_str(ctx, j_pub_exp);
    if (!NIL_P(r_pe))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("public_exponent")), r_pe);
  }
  JS_FreeValue(ctx, j_pub_exp);

  JSValue j_iv = js_algo_read(ctx, j_algo, "iv");
  if (!JS_IsUndefined(j_iv) && !JS_IsException(j_iv))
  {
    VALUE r_iv = js_buffer_to_ruby_str(ctx, j_iv);
    if (!NIL_P(r_iv))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("iv")), r_iv);
  }
  JS_FreeValue(ctx, j_iv);

  JSValue j_tag_length = js_algo_read(ctx, j_algo, "tagLength");
  if (!JS_IsUndefined(j_tag_length) && !JS_IsException(j_tag_length))
  {
    int32_t tag_length = 0;
    JS_ToInt32(ctx, &tag_length, j_tag_length);
    rb_hash_aset(r_hash, ID2SYM(rb_intern("tag_length")), INT2NUM(tag_length));
  }
  JS_FreeValue(ctx, j_tag_length);

  JSValue j_additional_data = js_algo_read(ctx, j_algo, "additionalData");
  if (!JS_IsUndefined(j_additional_data) && !JS_IsException(j_additional_data))
  {
    VALUE r_ad = js_buffer_to_ruby_str(ctx, j_additional_data);
    if (!NIL_P(r_ad))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("additional_data")), r_ad);
  }
  JS_FreeValue(ctx, j_additional_data);

  JSValue j_counter = js_algo_read(ctx, j_algo, "counter");
  if (!JS_IsUndefined(j_counter) && !JS_IsException(j_counter))
  {
    VALUE r_counter = js_buffer_to_ruby_str(ctx, j_counter);
    if (!NIL_P(r_counter))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("counter")), r_counter);
  }
  JS_FreeValue(ctx, j_counter);

  JSValue j_salt = js_algo_read(ctx, j_algo, "salt");
  if (!JS_IsUndefined(j_salt) && !JS_IsException(j_salt))
  {
    VALUE r_salt = js_buffer_to_ruby_str(ctx, j_salt);
    if (!NIL_P(r_salt))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("salt")), r_salt);
  }
  JS_FreeValue(ctx, j_salt);

  JSValue j_iterations = js_algo_read(ctx, j_algo, "iterations");
  if (!JS_IsUndefined(j_iterations) && !JS_IsException(j_iterations))
  {
    int32_t iterations = 0;
    JS_ToInt32(ctx, &iterations, j_iterations);
    rb_hash_aset(r_hash, ID2SYM(rb_intern("iterations")), INT2NUM(iterations));
  }
  JS_FreeValue(ctx, j_iterations);

  JSValue j_info = js_algo_read(ctx, j_algo, "info");
  if (!JS_IsUndefined(j_info) && !JS_IsException(j_info))
  {
    VALUE r_info = js_buffer_to_ruby_str(ctx, j_info);
    if (!NIL_P(r_info))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("info")), r_info);
  }
  JS_FreeValue(ctx, j_info);

  JSValue j_salt_length = js_algo_read(ctx, j_algo, "saltLength");
  if (!JS_IsUndefined(j_salt_length) && !JS_IsException(j_salt_length))
  {
    int32_t salt_length = 0;
    JS_ToInt32(ctx, &salt_length, j_salt_length);
    rb_hash_aset(r_hash, ID2SYM(rb_intern("salt_length")), INT2NUM(salt_length));
  }
  JS_FreeValue(ctx, j_salt_length);

  JSValue j_label = js_algo_read(ctx, j_algo, "label");
  if (!JS_IsUndefined(j_label) && !JS_IsException(j_label))
  {
    VALUE r_label = js_buffer_to_ruby_str(ctx, j_label);
    if (!NIL_P(r_label))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("label")), r_label);
  }
  JS_FreeValue(ctx, j_label);

  JSValue j_public = js_algo_read(ctx, j_algo, "public");
  if (!JS_IsUndefined(j_public) && !JS_IsException(j_public) && JS_IsObject(j_public))
  {
    VALUE r_public = r_find_alive_crypto_key(ctx, j_public);
    if (!NIL_P(r_public))
      rb_hash_aset(r_hash, ID2SYM(rb_intern("public")), r_public);
  }
  JS_FreeValue(ctx, j_public);

  return r_hash;
}


// Builds the string and defines it, reporting whether it got that far, so a
// caller can throw away a half-described object rather than define the
// allocation-failure sentinel as an ordinary property value. Defined, not
// assigned, for the reason js_crypto_key_to_js gives.
static bool j_define_str(JSContext *ctx, JSValue j_obj, const char *prop, VALUE r_str)
{
  JSValue j_val = JS_NewString(ctx, StringValueCStr(r_str));
  if (JS_IsException(j_val))
  {
    JS_FreeValue(ctx, j_val);
    return false;
  }
  return JS_DefinePropertyValueStr(ctx, j_obj, prop, j_val, JS_PROP_C_W_E) >= 0;
}

// Build a JS CryptoKey plain object from a Ruby Quickjs::CryptoKey. Stores the
// Ruby object in alive_objects; sets rb_object_id as non-enumerable.
//
// registered_here, when given, says whether this call is the one that put the
// key in alive_objects, so a caller that has to throw the key away can take
// exactly the row it caused and not one an earlier crossing still relies on.
static JSValue js_crypto_key_to_js(JSContext *ctx, VALUE r_key, bool *registered_here_out)
{
  VMData *data = JS_GetContextOpaque(ctx);

  // Nothing is registered until the key is fully described, which is the
  // ordering j_error_from_ruby_error follows and the only version of it that
  // holds: the reads below raise, and so does describing them, since
  // StringValueCStr rejects a non-String and a NUL, and NUM2INT rejects a
  // non-Integer. A raise out of a JSCFunction after registering would leave a
  // row anchoring this key for the life of the VM with nothing able to reach
  // it. With the draw last, there is nothing to leave.
  VALUE r_type = rb_funcall(r_key, rb_intern("type"), 0);
  VALUE r_extractable = rb_funcall(r_key, rb_intern("extractable"), 0);
  VALUE r_algorithm = rb_funcall(r_key, rb_intern("algorithm"), 0);
  VALUE r_usages = rb_funcall(r_key, rb_intern("usages"), 0);

  VALUE r_algo_name = rb_hash_aref(r_algorithm, rb_str_new_cstr("name"));
  VALUE r_algo_length = rb_hash_aref(r_algorithm, rb_str_new_cstr("length"));
  VALUE r_algo_named_curve = rb_hash_aref(r_algorithm, rb_str_new_cstr("namedCurve"));
  VALUE r_algo_hash = rb_hash_aref(r_algorithm, rb_str_new_cstr("hash"));
  VALUE r_algo_modulus_length = rb_hash_aref(r_algorithm, rb_str_new_cstr("modulusLength"));
  VALUE r_algo_pub_exp = rb_hash_aref(r_algorithm, rb_str_new_cstr("publicExponent"));
  long usages_len = RARRAY_LEN(r_usages);

  // Touched for their conversions, not their values: StringValueCStr raises on
  // a non-String and on an embedded NUL, NUM2INT on a non-Integer. Doing that
  // here means the describing below cannot raise, which is what lets the draw
  // sit between the two. Both orderings cost something otherwise: draw first
  // and a raise from describing orphans a table row that anchors this key, with
  // its private material, for the life of the VM; draw last and a raise from
  // the draw leaves j_key, and the promise capability the caller is holding,
  // unreleased. With nothing between them able to raise, neither is reachable.
  StringValueCStr(r_type);
  StringValueCStr(r_algo_name);
  if (!NIL_P(r_algo_length))
    NUM2INT(r_algo_length);
  if (!NIL_P(r_algo_named_curve))
    StringValueCStr(r_algo_named_curve);
  if (!NIL_P(r_algo_hash))
    StringValueCStr(r_algo_hash);
  if (!NIL_P(r_algo_modulus_length))
    NUM2INT(r_algo_modulus_length);
  if (!NIL_P(r_algo_pub_exp))
    StringValue(r_algo_pub_exp);
  // Into a list of our own, because StringValueCStr converts the local it is
  // given and rb_ary_entry hands back a temporary: touching that would leave
  // the caller's array holding the unconverted member, and the describing loop
  // would convert it a second time, after the draw and with j_key allocated,
  // which is the raise the ordering above exists to rule out.
  VALUE r_usage_strings = rb_ary_new_capa(usages_len);
  for (long i = 0; i < usages_len; i++)
  {
    VALUE r_usage = rb_ary_entry(r_usages, i);
    StringValueCStr(r_usage);
    rb_ary_push(r_usage_strings, r_usage);
  }

  // Taken here, in the same raise-safe stretch, so the rollback paths below can
  // undo a registration without dispatching from inside a JSCFunction.
  VALUE r_key_object_id = rb_obj_id(r_key);

  // Drawn here, with everything that can raise behind it and nothing allocated
  // in front of it.
  bool registered_here = false;
  VALUE r_object_id = alive_objects_register(data, r_key, &registered_here);
  if (registered_here_out != NULL)
    *registered_here_out = registered_here;
  if (NIL_P(r_object_id))
    return JS_ThrowInternalError(ctx, "quickjs: could not publish a handle for a CryptoKey");

  // Checked, like every value that becomes a property of the key: passing the
  // sentinel to JS_DefinePropertyValue* stores it as an ordinary value, which
  // is the shape the rest of this branch refuses.
  JSValue j_key = JS_NewObject(ctx);
  if (JS_IsException(j_key))
  {
    if (registered_here)
    {
      alive_objects_unregister(data, r_object_id, r_key_object_id);
      // The claim goes with the row: a caller told the row is theirs would ask
      // alive_objects_forget for one that is already gone.
      registered_here = false;
      if (registered_here_out != NULL)
        *registered_here_out = false;
    }
    return j_key;
  }

  bool described = j_define_str(ctx, j_key, "type", r_type);
  described = JS_DefinePropertyValueStr(ctx, j_key, "extractable", JS_NewBool(ctx, RTEST(r_extractable)),
                                       JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE) >= 0 && described;

  // Every one of these is defined rather than assigned: an accessor a guest
  // puts on Object.prototype otherwise absorbs the write, and the key ends up
  // describing itself with whatever that getter says, including reporting
  // extractable: true for a key generated without it.
  JSValue j_algo = JS_NewObject(ctx);
  if (JS_IsException(j_algo))
  {
    if (registered_here)
    {
      alive_objects_unregister(data, r_object_id, r_key_object_id);
      // The claim goes with the row: a caller told the row is theirs would ask
      // alive_objects_forget for one that is already gone.
      registered_here = false;
      if (registered_here_out != NULL)
        *registered_here_out = false;
    }
    JS_FreeValue(ctx, j_key);
    return j_algo;
  }

  described = j_define_str(ctx, j_algo, "name", r_algo_name) && described;

  if (!NIL_P(r_algo_length))
    described = JS_DefinePropertyValueStr(ctx, j_algo, "length", JS_NewInt32(ctx, NUM2INT(r_algo_length)),
                                         JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE) >= 0 && described;

  if (!NIL_P(r_algo_named_curve))
    described = j_define_str(ctx, j_algo, "namedCurve", r_algo_named_curve) && described;

  if (!NIL_P(r_algo_hash))
  {
    JSValue j_hash_obj = JS_NewObject(ctx);
    if (JS_IsException(j_hash_obj))
    {
      if (registered_here)
        alive_objects_unregister(data, r_object_id, r_key_object_id);
      JS_FreeValue(ctx, j_algo);
      JS_FreeValue(ctx, j_key);
      return j_hash_obj;
    }
    described = j_define_str(ctx, j_hash_obj, "name", r_algo_hash) && described;
    described = JS_DefinePropertyValueStr(ctx, j_algo, "hash", j_hash_obj,
                                         JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE) >= 0 && described;
  }

  if (!NIL_P(r_algo_modulus_length))
    described = JS_DefinePropertyValueStr(ctx, j_algo, "modulusLength", JS_NewInt32(ctx, NUM2INT(r_algo_modulus_length)),
                                         JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE) >= 0 && described;

  if (!NIL_P(r_algo_pub_exp))
  {
    // Built through JS_NewTypedArray rather than by calling globalThis's
    // Uint8Array. That constructor is the guest's to delete or replace, and a
    // replacement can throw anything it likes, including a Ruby exception from
    // a bridge: nothing here can report it, because this runs after its
    // caller's rb_protect has returned and every caller stores the result
    // unchecked. Not reading the global removes the question rather than
    // answering it. What remains is the runtime's own allocation failing, and
    // both branches below take that rather than leave it: no caller of this
    // function returns JS_EXCEPTION, so a throw left set would be attributed to
    // whatever evaluation next asked for one. The cost is that a key can come
    // back describing itself without publicExponent, with the out-of-memory
    // reported nowhere. #129.
    JSValue j_pe_buf = JS_NewArrayBufferCopy(ctx,
                                             (const uint8_t *)RSTRING_PTR(r_algo_pub_exp),
                                             RSTRING_LEN(r_algo_pub_exp));
    if (JS_IsException(j_pe_buf))
    {
      // Taken here for the reason the branch below gives: the key is still
      // handed over without a publicExponent, so leaving this set would
      // attribute the allocation failure to whatever asked next.
      JS_FreeValue(ctx, JS_GetException(ctx));
    }
    else
    {
      JSValue j_args[3] = {j_pe_buf, JS_NewInt32(ctx, 0), JS_NewInt64(ctx, RSTRING_LEN(r_algo_pub_exp))};
      JSValue j_pe = JS_NewTypedArray(ctx, 3, (JSValueConst *)j_args, JS_TYPED_ARRAY_UINT8);
      JS_FreeValue(ctx, j_pe_buf);
      if (JS_IsException(j_pe))
        // Taken and lost, because the key is still described well enough to
        // hand over and a throw left here would surface at whatever calls
        // JS_GetException next. It can be a throw an earlier describe set, so
        // js_settle_or_reject no longer assumes the slot is full. The only way
        // to get here is the runtime's own allocation failing, which the next
        // one will fail at too.
        JS_FreeValue(ctx, JS_GetException(ctx));
      else
        described = JS_DefinePropertyValueStr(ctx, j_algo, "publicExponent", j_pe,
                                             JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE) >= 0 && described;
    }
  }

  described = JS_DefinePropertyValueStr(ctx, j_key, "algorithm", j_algo,
                                       JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE) >= 0 && described;

  JSValue j_usages = JS_NewArray(ctx);
  if (JS_IsException(j_usages))
  {
    if (registered_here)
    {
      alive_objects_unregister(data, r_object_id, r_key_object_id);
      // The claim goes with the row: a caller told the row is theirs would ask
      // alive_objects_forget for one that is already gone.
      registered_here = false;
      if (registered_here_out != NULL)
        *registered_here_out = false;
    }
    JS_FreeValue(ctx, j_key);
    return j_usages;
  }
  for (long i = 0; i < usages_len; i++)
  {
    VALUE r_usage = rb_ary_entry(r_usage_strings, i);
    // Defined, like every other property of the key: an index property on
    // Array.prototype takes the fast array path away, and the element write
    // then walks the chain into the guest's setter like any named one would.
    // StringValueCStr cannot raise here: it is a String already, converted
    // above, before anything was drawn or allocated.
    JSValue j_usage = JS_NewString(ctx, StringValueCStr(r_usage));
    if (JS_IsException(j_usage))
    {
      JS_FreeValue(ctx, j_usage);
      described = false;
    }
    else
    {
      described = JS_DefinePropertyValueUint32(ctx, j_usages, (uint32_t)i, j_usage, JS_PROP_C_W_E) >= 0 && described;
    }
  }
  described = JS_DefinePropertyValueStr(ctx, j_key, "usages", j_usages,
                                       JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE) >= 0 && described;

  if (!described)
  {
    // A key that cannot say what it is, is not one to hand over: the runtime's
    // own throw is already pending from whichever allocation failed. The row
    // goes with it, since the draw is behind us now: left there it would anchor
    // this key, key_data included, for the life of the VM with nothing in JS
    // able to reach it. Only what this call made, because the same key crossing
    // twice reuses its handle and the earlier crossing still relies on that row.
    if (registered_here)
    {
      alive_objects_unregister(data, r_object_id, r_key_object_id);
      // The claim goes with the row: a caller told the row is theirs would ask
      // alive_objects_forget for one that is already gone.
      registered_here = false;
      if (registered_here_out != NULL)
        *registered_here_out = false;
    }
    JS_FreeValue(ctx, j_key);
    return JS_EXCEPTION;
  }

  // A key that looks like a key and carries no handle is worse than no key:
  // every later sign or exportKey on it fails as an invalid key while the row
  // keeps anchoring the Ruby object.
  if (JS_DefinePropertyValueStr(ctx, j_key, "rb_object_id",
                                JS_NewInt64(ctx, NUM2LL(r_object_id)),
                                JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE) < 0)
  {
    // Only what this call put there: the same key object crossing twice reuses
    // its handle, and taking that row would unanchor the key the earlier
    // crossing handed the guest.
    if (registered_here)
    {
      alive_objects_unregister(data, r_object_id, r_key_object_id);
      if (registered_here_out != NULL)
        *registered_here_out = false;
    }
    JS_FreeValue(ctx, j_key);
    return JS_EXCEPTION;
  }

  return j_key;
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
  return rb_funcall(r_mod, rb_intern("generate_key"), 3,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2));
}

static JSValue js_subtle_generate_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 3)
    return JS_ThrowTypeError(ctx, "Failed to execute 'generateKey': 3 arguments required.");

  VALUE r_algo_hash = js_algo_to_ruby_hash(ctx, argv[0]);
  VALUE r_extractable = JS_ToBool(ctx, argv[1]) ? Qtrue : Qfalse;
  VALUE r_usages = js_usages_to_ruby_array(ctx, argv[2]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(3, r_algo_hash, r_extractable, r_usages);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_generate_key_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else if (RB_TYPE_P(r_result, T_HASH))
  {
    VALUE r_priv = rb_hash_aref(r_result, ID2SYM(rb_intern("private_key")));
    VALUE r_pub = rb_hash_aref(r_result, ID2SYM(rb_intern("public_key")));
    bool priv_registered_here = false;
    bool pub_registered_here = false;
    JSValue j_priv = js_crypto_key_to_js(ctx, r_priv, &priv_registered_here);
    JSValue j_pub = js_crypto_key_to_js(ctx, r_pub, &pub_registered_here);
    JSValue j_pair = JS_NewObject(ctx);
    bool built = !JS_IsException(j_priv) && !JS_IsException(j_pub) && !JS_IsException(j_pair);
    if (built)
    {
      built = JS_DefinePropertyValueStr(ctx, j_pair, "privateKey", j_priv, JS_PROP_C_W_E) >= 0;
      built = JS_DefinePropertyValueStr(ctx, j_pair, "publicKey", j_pub, JS_PROP_C_W_E) >= 0 && built;
    }
    else
    {
      // Half a pair is not a pair, and the sentinel is not a value to hand on.
      JS_FreeValue(ctx, j_priv);
      JS_FreeValue(ctx, j_pub);
    }

    if (built)
    {
      js_settle_or_reject(ctx, resolving_funcs, j_pair);
    }
    else
    {
      // Whichever key did get built is being dropped here, so its row goes with
      // it. Left behind, it would anchor a Ruby CryptoKey, private material
      // included, for the life of the VM with nothing in JS able to reach it.
      VMData *data = JS_GetContextOpaque(ctx);
      if (priv_registered_here)
        alive_objects_forget(data, r_priv);
      if (pub_registered_here)
        alive_objects_forget(data, r_pub);
      JS_FreeValue(ctx, j_pair);
      js_settle_or_reject(ctx, resolving_funcs, JS_EXCEPTION);
    }
  }
  else
  {
    js_settle_or_reject(ctx, resolving_funcs, js_crypto_key_to_js(ctx, r_result, NULL));
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

  VALUE r_algo_hash = js_algo_to_ruby_hash(ctx, argv[2]);
  VALUE r_extractable = JS_ToBool(ctx, argv[3]) ? Qtrue : Qfalse;
  VALUE r_usages = js_usages_to_ruby_array(ctx, argv[4]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(5, r_format, r_key_data, r_algo_hash, r_extractable, r_usages);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_import_key_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    js_settle_or_reject(ctx, resolving_funcs, js_crypto_key_to_js(ctx, r_result, NULL));
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

static JSValue js_subtle_crypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv,
                               VALUE (*r_call_func)(VALUE))
{
  if (argc < 3)
    return JS_ThrowTypeError(ctx, "3 arguments required.");

  VALUE r_algo_hash = js_algo_to_ruby_hash(ctx, argv[0]);
  VALUE r_name = rb_hash_aref(r_algo_hash, ID2SYM(rb_intern("name")));
  if (NIL_P(r_name))
    return JS_ThrowTypeError(ctx, "algorithm name is required.");

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "invalid CryptoKey.");

  VALUE r_data = js_buffer_to_ruby_str(ctx, argv[2]);
  if (NIL_P(r_data))
    return JS_ThrowTypeError(ctx, "data must be an ArrayBuffer or TypedArray.");

  VALUE r_args = rb_ary_new3(4, r_name, r_key, r_data, r_algo_hash);

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

static VALUE r_subtle_sign_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("sign"), 4,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3));
}

static JSValue js_subtle_sign(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 3)
    return JS_ThrowTypeError(ctx, "Failed to execute 'sign': 3 arguments required.");

  VALUE r_algo_hash = js_algo_to_ruby_hash(ctx, argv[0]);
  VALUE r_name = rb_hash_aref(r_algo_hash, ID2SYM(rb_intern("name")));
  if (NIL_P(r_name))
    return JS_ThrowTypeError(ctx, "Failed to execute 'sign': algorithm name is required.");

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'sign': invalid CryptoKey.");

  VALUE r_data = js_buffer_to_ruby_str(ctx, argv[2]);
  if (NIL_P(r_data))
    return JS_ThrowTypeError(ctx, "Failed to execute 'sign': data must be an ArrayBuffer or TypedArray.");

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(4, r_name, r_key, r_data, r_algo_hash);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_sign_call, r_args, &error_state);

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

static VALUE r_subtle_verify_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("verify"), 5,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3),
                    rb_ary_entry(r_args, 4));
}

static JSValue js_subtle_verify(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 4)
    return JS_ThrowTypeError(ctx, "Failed to execute 'verify': 4 arguments required.");

  VALUE r_algo_hash = js_algo_to_ruby_hash(ctx, argv[0]);
  VALUE r_name = rb_hash_aref(r_algo_hash, ID2SYM(rb_intern("name")));
  if (NIL_P(r_name))
    return JS_ThrowTypeError(ctx, "Failed to execute 'verify': algorithm name is required.");

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'verify': invalid CryptoKey.");

  VALUE r_signature = js_buffer_to_ruby_str(ctx, argv[2]);
  if (NIL_P(r_signature))
    return JS_ThrowTypeError(ctx, "Failed to execute 'verify': signature must be an ArrayBuffer or TypedArray.");

  VALUE r_data = js_buffer_to_ruby_str(ctx, argv[3]);
  if (NIL_P(r_data))
    return JS_ThrowTypeError(ctx, "Failed to execute 'verify': data must be an ArrayBuffer or TypedArray.");

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(5, r_name, r_key, r_signature, r_data, r_algo_hash);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_verify_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    JSValue j_result = JS_NewBool(ctx, RTEST(r_result));
    JSValue ret = JS_Call(ctx, resolving_funcs[0], JS_UNDEFINED, 1, (JSValueConst *)&j_result);
    JS_FreeValue(ctx, ret);
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static VALUE r_subtle_derive_bits_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("derive_bits"), 4,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3));
}

static JSValue js_subtle_derive_bits(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 3)
    return JS_ThrowTypeError(ctx, "Failed to execute 'deriveBits': 3 arguments required.");

  VALUE r_algo_hash = js_algo_to_ruby_hash(ctx, argv[0]);
  VALUE r_name = rb_hash_aref(r_algo_hash, ID2SYM(rb_intern("name")));
  if (NIL_P(r_name))
    return JS_ThrowTypeError(ctx, "Failed to execute 'deriveBits': algorithm name is required.");

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'deriveBits': invalid CryptoKey.");

  int32_t length_bits = 0;
  JS_ToInt32(ctx, &length_bits, argv[2]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(4, r_name, r_key, INT2NUM(length_bits), r_algo_hash);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_derive_bits_call, r_args, &error_state);

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

static VALUE r_subtle_derive_key_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("derive_key"), 6,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3),
                    rb_ary_entry(r_args, 4),
                    rb_ary_entry(r_args, 5));
}

static JSValue js_subtle_derive_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 5)
    return JS_ThrowTypeError(ctx, "Failed to execute 'deriveKey': 5 arguments required.");

  VALUE r_algo_hash = js_algo_to_ruby_hash(ctx, argv[0]);
  VALUE r_name = rb_hash_aref(r_algo_hash, ID2SYM(rb_intern("name")));
  if (NIL_P(r_name))
    return JS_ThrowTypeError(ctx, "Failed to execute 'deriveKey': algorithm name is required.");

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'deriveKey': invalid CryptoKey.");

  VALUE r_derived_algo_hash = js_algo_to_ruby_hash(ctx, argv[2]);
  VALUE r_extractable = JS_ToBool(ctx, argv[3]) ? Qtrue : Qfalse;
  VALUE r_usages = js_usages_to_ruby_array(ctx, argv[4]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(6, r_name, r_key, r_derived_algo_hash, r_extractable, r_usages, r_algo_hash);
  int error_state;
  VALUE r_result = rb_protect(r_subtle_derive_key_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    js_settle_or_reject(ctx, resolving_funcs, js_crypto_key_to_js(ctx, r_result, NULL));
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

static VALUE r_subtle_wrap_key_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("wrap_key"), 5,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3),
                    rb_ary_entry(r_args, 4));
}

static JSValue js_subtle_wrap_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 4)
    return JS_ThrowTypeError(ctx, "Failed to execute 'wrapKey': 4 arguments required.");

  const char *format_cstr = JS_ToCString(ctx, argv[0]);
  if (!format_cstr)
    return JS_ThrowTypeError(ctx, "Failed to execute 'wrapKey': format must be a string.");
  VALUE r_format = rb_str_new_cstr(format_cstr);
  JS_FreeCString(ctx, format_cstr);

  VALUE r_key = r_find_alive_crypto_key(ctx, argv[1]);
  if (NIL_P(r_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'wrapKey': invalid CryptoKey.");

  VALUE r_wrapping_key = r_find_alive_crypto_key(ctx, argv[2]);
  if (NIL_P(r_wrapping_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'wrapKey': invalid wrapping CryptoKey.");

  VALUE r_wrap_algo_hash = js_algo_to_ruby_hash(ctx, argv[3]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new3(5, r_format, r_key, r_wrapping_key, r_wrap_algo_hash,
                             rb_hash_aref(r_wrap_algo_hash, ID2SYM(rb_intern("name"))));
  int error_state;
  VALUE r_result = rb_protect(r_subtle_wrap_key_call, r_args, &error_state);

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

static VALUE r_subtle_unwrap_key_call(VALUE r_args)
{
  VALUE r_mod = rb_const_get(rb_const_get(rb_cObject, rb_intern("Quickjs")), rb_intern("SubtleCrypto"));
  return rb_funcall(r_mod, rb_intern("unwrap_key"), 8,
                    rb_ary_entry(r_args, 0),
                    rb_ary_entry(r_args, 1),
                    rb_ary_entry(r_args, 2),
                    rb_ary_entry(r_args, 3),
                    rb_ary_entry(r_args, 4),
                    rb_ary_entry(r_args, 5),
                    rb_ary_entry(r_args, 6),
                    rb_ary_entry(r_args, 7));
}

static JSValue js_subtle_unwrap_key(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
  if (argc < 7)
    return JS_ThrowTypeError(ctx, "Failed to execute 'unwrapKey': 7 arguments required.");

  const char *format_cstr = JS_ToCString(ctx, argv[0]);
  if (!format_cstr)
    return JS_ThrowTypeError(ctx, "Failed to execute 'unwrapKey': format must be a string.");
  VALUE r_format = rb_str_new_cstr(format_cstr);
  JS_FreeCString(ctx, format_cstr);

  VALUE r_wrapped_key = js_buffer_to_ruby_str(ctx, argv[1]);
  if (NIL_P(r_wrapped_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'unwrapKey': wrapped key data must be an ArrayBuffer or TypedArray.");

  VALUE r_unwrapping_key = r_find_alive_crypto_key(ctx, argv[2]);
  if (NIL_P(r_unwrapping_key))
    return JS_ThrowTypeError(ctx, "Failed to execute 'unwrapKey': invalid unwrapping CryptoKey.");

  VALUE r_unwrap_algo_hash = js_algo_to_ruby_hash(ctx, argv[3]);
  VALUE r_unwrapped_algo_hash = js_algo_to_ruby_hash(ctx, argv[4]);
  VALUE r_extractable = JS_ToBool(ctx, argv[5]) ? Qtrue : Qfalse;
  VALUE r_usages = js_usages_to_ruby_array(ctx, argv[6]);

  JSValue promise, resolving_funcs[2];
  promise = JS_NewPromiseCapability(ctx, resolving_funcs);
  if (JS_IsException(promise))
    return JS_EXCEPTION;

  VALUE r_args = rb_ary_new();
  rb_ary_push(r_args, r_format);
  rb_ary_push(r_args, r_wrapped_key);
  rb_ary_push(r_args, r_unwrapping_key);
  rb_ary_push(r_args, r_unwrap_algo_hash);
  rb_ary_push(r_args, r_unwrapped_algo_hash);
  rb_ary_push(r_args, r_extractable);
  rb_ary_push(r_args, r_usages);
  rb_ary_push(r_args, rb_hash_aref(r_unwrap_algo_hash, ID2SYM(rb_intern("name"))));

  int error_state;
  VALUE r_result = rb_protect(r_subtle_unwrap_key_call, r_args, &error_state);

  if (error_state)
  {
    js_reject_with_ruby_error(ctx, resolving_funcs);
  }
  else
  {
    js_settle_or_reject(ctx, resolving_funcs, js_crypto_key_to_js(ctx, r_result, NULL));
  }

  JS_FreeValue(ctx, resolving_funcs[0]);
  JS_FreeValue(ctx, resolving_funcs[1]);

  return promise;
}

void quickjsrb_init_crypto_subtle(JSContext *ctx, JSValueConst j_crypto)
{
  JSValue j_subtle = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, j_subtle, "digest",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_digest, "digest", 2));
  JS_SetPropertyStr(ctx, j_subtle, "generateKey",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_generate_key, "generateKey", 3));
  JS_SetPropertyStr(ctx, j_subtle, "importKey",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_import_key, "importKey", 5));
  JS_SetPropertyStr(ctx, j_subtle, "exportKey",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_export_key, "exportKey", 2));
  JS_SetPropertyStr(ctx, j_subtle, "encrypt",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_encrypt, "encrypt", 3));
  JS_SetPropertyStr(ctx, j_subtle, "decrypt",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_decrypt, "decrypt", 3));
  JS_SetPropertyStr(ctx, j_subtle, "sign",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_sign, "sign", 3));
  JS_SetPropertyStr(ctx, j_subtle, "verify",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_verify, "verify", 4));
  JS_SetPropertyStr(ctx, j_subtle, "deriveBits",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_derive_bits, "deriveBits", 3));
  JS_SetPropertyStr(ctx, j_subtle, "deriveKey",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_derive_key, "deriveKey", 5));
  JS_SetPropertyStr(ctx, j_subtle, "wrapKey",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_wrap_key, "wrapKey", 4));
  JS_SetPropertyStr(ctx, j_subtle, "unwrapKey",
                    quickjsrb_new_ruby_bridge(ctx, js_subtle_unwrap_key, "unwrapKey", 7));
  JS_SetPropertyStr(ctx, j_crypto, "subtle", j_subtle);
}
