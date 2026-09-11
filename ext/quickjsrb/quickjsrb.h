#ifndef QUICKJSRB_H
#define QUICKJSRB_H 1

#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/thread.h"

#include "quickjs.h"
#include "quickjs-libc.h"
#include "cutils.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

extern const uint32_t qjsc_polyfill_file_min_size;
extern const uint8_t qjsc_polyfill_file_min;
extern const uint32_t qjsc_polyfill_encoding_min_size;
extern const uint8_t qjsc_polyfill_encoding_min;
extern const uint32_t qjsc_polyfill_url_min_size;
extern const uint8_t qjsc_polyfill_url_min;

extern const char *featureStdId;
extern const char *featureOsId;
extern const char *featureTimeoutId;
extern const char *featurePolyfillFileId;
extern const char *featurePolyfillEncodingId;
extern const char *featurePolyfillUrlId;
extern const char *featurePolyfillCryptoId;

extern const char *undefinedId;
extern const char *nanId;

extern const char *native_errors[];
extern const int num_native_errors;

#define QUICKJSRB_SYM(id) \
  (VALUE) { ID2SYM(rb_intern(id)) }

// VM data structure

typedef struct EvalTime
{
  int64_t limit_ms;
  struct timespec started_at;
} EvalTime;

static int64_t eval_elapsed_ms(const EvalTime *eval_time)
{
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t)(now.tv_sec - eval_time->started_at.tv_sec) * 1000
       + (now.tv_nsec - eval_time->started_at.tv_nsec) / 1000000;
}

typedef struct VMData
{
  struct JSContext *context;
  VALUE defined_functions;
  struct EvalTime *eval_time;
  VALUE log_listener;
  VALUE alive_objects;
  // object_id -> handle, so an object bridged twice keeps one entry. Private:
  // the guest is told the handle, never this key.
  VALUE alive_handles;
  VALUE module_loader;
  VALUE on_unhandled_rejection;
  // Memoize (specifier, importer) → canonical so the user's loader Proc
  // runs at most once per distinct pair across the VM's lifetime. Without
  // this, QuickJS calls normalize on every import statement — including
  // duplicates within the same file — and we'd re-invoke the user proc.
  VALUE module_resolution_cache;
  // Carries `code` from the normalize-phase Proc call to the load-phase
  // JS_Eval that follows. Keyed by canonical; populated when the user's
  // loader returns either a raw source String or `{ code:, as: }`.
  VALUE module_source_cache;
  // Set (name → Qtrue) of modules read into this context by
  // _preload_module_bytecode. QuickJS calls normalize *before* it looks in
  // ctx->loaded_modules, so without this the normalize hook would ask the
  // user's loader for a module that is already loaded — and raise
  // ReferenceError when the loader doesn't know the name.
  VALUE preloaded_module_names;
  JSValue j_file_proxy_creator;
  // Captured with it, at init, so slice does not build its result by calling
  // a constructor the guest has had a chance to replace.
  JSValue j_blob_ctor;
  // Once the runtime has hit JS-level "out of memory", the QuickJS heap is in
  // a fragile state where further evaluation can trigger a use-after-free in
  // the parser-error-during-OOM cascade (segfault inside js_shape_hash_unlink).
  // Trip this flag so subsequent eval_code/call calls refuse cleanly with a
  // Ruby exception instead of risking a process crash.
  bool oom_poisoned;
  // Latched when the handle source stops giving out distinct values. Like
  // oom_poisoned, it is reported from the next entry point rather than from
  // wherever it was noticed, because that place is inside a JSCFunction.
  bool handle_source_broken;
  // What was raised at the registrar, when something was. rb_protect cannot
  // tell a stubbed source apart from an Interrupt, a Timeout::Error or any
  // other Thread#raise landing in that window, and discarding one of those
  // loses it entirely. Kept instead, and re-raised from the next entry point,
  // where there is no QuickJS frame to unwind through.
  VALUE r_registrar_error;
  // The class id a Proxy reports in this runtime, learned at init from a Proxy
  // this extension builds, before any guest code can run. Read from the guest's
  // own Proxy instead and a script that reassigns or deletes that global
  // decides what the readers treat as a Proxy.
  JSClassID proxy_class_id;
  // Whether interrupt_handler is currently installed. started_at belongs to
  // whichever evaluation armed it, so without this the elapsed time is read
  // off a stale clock — an unbudgeted polyfill load disarms deliberately and
  // would otherwise look infinitely overdue.
  bool eval_timer_armed;
  // Set by VM#dispose! to release the multi-MB JS heap before Ruby GC sees
  // enough pressure to collect the wrapper. Doubles as a double-free guard
  // for the dfree handler.
  bool disposed;
  // Set while JS is executing with the GVL released so JS→Ruby bridges
  // (currently js_quickjsrb_log) can re-acquire the GVL before touching
  // Ruby APIs. Covers both vm_m_evalCode and vm_m_loadPolyfillBytecode;
  // reset before to_rb_return_value or other Ruby-touching code runs.
  // Saved/restored (not blindly cleared) so a region nested through an
  // on_log listener doesn't clear the outer region's flag.
  bool gvl_released_js;
  // Number of JS executions currently in flight on this VM — eval_code
  // (both the GVL-released and GVL-held paths), call, bytecode runs,
  // polyfill bytecode loads, import, and job drains. vm_m_dispose refuses
  // (ThreadError) while nonzero: freeing the runtime under live JS is a
  // use-after-free, and both the GVL release and GVL-yielding bridge
  // callbacks (setTimeout's rb_thread_wait_for, define_function procs,
  // on_log listeners) make that overlap reachable — e.g. the README's
  // `Thread.new { vm.dispose! }` pattern, or a listener calling dispose!
  // mid-eval. Only mutated while holding the GVL, so plain int accesses
  // are race-free.
  int evals_in_flight;
  // The Ruby thread that opened the outermost in-flight JS entry, or Qnil
  // when evals_in_flight is 0. A second thread entering while this is set
  // to someone else is the "one VM, one thread at a time" rule being
  // broken, and QuickJS contexts have no internal locking, so it is refused
  // (ThreadError) rather than left to corrupt the heap.
  //
  // Keyed on the owner rather than the counter because same-thread nesting
  // is legitimate and common: an on_log listener or a define_function proc
  // re-entering the VM elevates evals_in_flight without any concurrency.
  // Comparing the owner lets that through and catches only the real thing.
  // Only mutated while holding the GVL.
  VALUE owner_thread;
  // Number of GVL-release regions currently open on this VM (a subset of
  // evals_in_flight). Bridge-registration APIs (define_function,
  // module_loader=, on_unhandled_rejection) refuse (ThreadError) while
  // nonzero: the running JS was allowed to release the GVL because
  // can_eval_gvl_free held at eval start, and installing a bridge
  // mid-flight — e.g. from an on_log listener, whose callback runs with
  // the GVL re-acquired — would hand the still-released JS a path into
  // Ruby APIs without the GVL. Only mutated while holding the GVL.
  int gvl_release_regions;
  // The max_stack_size the caller asked for, kept so rebase_stack_limit can
  // re-apply it on each outermost entry: the budget is re-derived per entry
  // from the running thread's real headroom, and the request is the ceiling
  // it clamps down from. Zero keeps QuickJS's documented "no limit".
size_t requested_max_stack_size;
// Whether initialize ran. Quickjs::VM.allocate is public on every Ruby
// class, and an object allocated but never initialized still reaches
// vm_free, which used to hand js_std_free_handlers a runtime whose
// handlers js_std_init_handlers had never set up. That segfaulted at
// process exit. Teardown consults this instead of assuming.
bool std_handlers_installed;
  // Latched by quickjsrb_new_ruby_bridge whenever a C function that calls
  // into Ruby synchronously (rb_funcall & friends) WITHOUT honoring
  // gvl_released_js is installed into this context. While true,
  // can_eval_gvl_free fails and eval keeps the GVL held. Register every
  // such function through that helper — a bridge registered with plain
  // JS_NewCFunction would run against Ruby under a released GVL and
  // silently corrupt the interpreter.
  bool has_native_ruby_bridge;
} VMData;

// Drop-in replacement for JS_NewCFunction for C functions that call into
// Ruby synchronously without honoring gvl_released_js (crypto.*, File
// proxy helpers, setTimeout's job). Latching has_native_ruby_bridge here
// makes the "keep the GVL held" contract structural instead of relying on
// each feature-init site to remember a flag assignment. Requires
// JS_SetContextOpaque(ctx, data) to have run (vm_m_initialize does this
// before any feature setup). console.log intentionally does NOT go through
// this: js_quickjsrb_log re-acquires the GVL itself, and Proc-backed
// bridges (define_function / module_loader / on_unhandled_rejection) are
// excluded structurally by can_eval_gvl_free's own checks.
static inline JSValue quickjsrb_new_ruby_bridge(JSContext *ctx, JSCFunction *func, const char *name, int length)
{
  VMData *data = JS_GetContextOpaque(ctx);
  data->has_native_ruby_bridge = true;
  return JS_NewCFunction(ctx, func, name, length);
}

static void vm_teardown_context(JSContext *ctx, bool std_handlers_installed)
{
  JSRuntime *runtime = JS_GetRuntime(ctx);
  JS_SetInterruptHandler(runtime, NULL, NULL);
  if (std_handlers_installed)
    js_std_free_handlers(runtime);
  JS_FreeContext(ctx);
  JS_FreeRuntime(runtime);
}

static void vm_free(void *ptr)
{
  VMData *data = (VMData *)ptr;
  free(data->eval_time);

  if (!data->disposed)
  {
    if (!JS_IsUndefined(data->j_file_proxy_creator))
      JS_FreeValue(data->context, data->j_file_proxy_creator);
    if (!JS_IsUndefined(data->j_blob_ctor))
      JS_FreeValue(data->context, data->j_blob_ctor);

    vm_teardown_context(data->context, data->std_handlers_installed);
  }

  xfree(ptr);
}

static size_t vm_size(const void *data)
{
  return sizeof(VMData);
}

static void vm_mark(void *ptr)
{
  VMData *data = (VMData *)ptr;
  rb_gc_mark_movable(data->defined_functions);
  rb_gc_mark_movable(data->log_listener);
  rb_gc_mark_movable(data->alive_objects);
  rb_gc_mark_movable(data->alive_handles);
  rb_gc_mark_movable(data->r_registrar_error);
  rb_gc_mark_movable(data->module_loader);
  rb_gc_mark_movable(data->on_unhandled_rejection);
  rb_gc_mark_movable(data->module_resolution_cache);
  rb_gc_mark_movable(data->module_source_cache);
  rb_gc_mark_movable(data->preloaded_module_names);
  // Pinned rather than movable: it is compared by identity against
  // rb_thread_current(), and it is only ever set for the duration of a JS
  // entry, so there is nothing to gain from letting it move.
  rb_gc_mark(data->owner_thread);
}

static void vm_compact(void *ptr)
{
  VMData *data = (VMData *)ptr;
  data->defined_functions = rb_gc_location(data->defined_functions);
  data->log_listener = rb_gc_location(data->log_listener);
  data->alive_objects = rb_gc_location(data->alive_objects);
  data->alive_handles = rb_gc_location(data->alive_handles);
  data->r_registrar_error = rb_gc_location(data->r_registrar_error);
  data->module_loader = rb_gc_location(data->module_loader);
  data->on_unhandled_rejection = rb_gc_location(data->on_unhandled_rejection);
  data->module_resolution_cache = rb_gc_location(data->module_resolution_cache);
  data->module_source_cache = rb_gc_location(data->module_source_cache);
  data->preloaded_module_names = rb_gc_location(data->preloaded_module_names);
}

static const rb_data_type_t vm_type = {
    .wrap_struct_name = "quickjsvm",
    .function = {
        .dmark = vm_mark,
        .dfree = vm_free,
        .dsize = vm_size,
        .dcompact = vm_compact,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

struct vm_create_args
{
  JSContext *context;
};

static void *vm_create_no_gvl(void *p)
{
  struct vm_create_args *args = p;
  args->context = JS_NewContext(JS_NewRuntime());
  return NULL;
}

static VALUE vm_alloc(VALUE r_self)
{
  VMData *data;
  VALUE obj = TypedData_Make_Struct(r_self, VMData, &vm_type, data);
  data->defined_functions = rb_hash_new();
  data->log_listener = Qnil;
  data->alive_objects = rb_hash_new();
  data->alive_handles = rb_hash_new();
  data->module_loader = Qnil;
  data->on_unhandled_rejection = Qnil;
  data->module_resolution_cache = rb_hash_new();
  data->module_source_cache = rb_hash_new();
  data->preloaded_module_names = rb_hash_new();
  data->j_file_proxy_creator = JS_UNDEFINED;
  data->j_blob_ctor = JS_UNDEFINED;
  data->proxy_class_id = 0;
  data->oom_poisoned = false;
  data->handle_source_broken = false;
  data->r_registrar_error = Qnil;
  data->eval_timer_armed = false;
  data->disposed = false;
  data->gvl_released_js = false;
  data->evals_in_flight = 0;
  data->owner_thread = Qnil;
  data->requested_max_stack_size = 0;
  data->std_handlers_installed = false;
  data->gvl_release_regions = 0;
  data->has_native_ruby_bridge = false;

  EvalTime *eval_time = malloc(sizeof(EvalTime));
  data->eval_time = eval_time;

  // JSRuntime / JSContext creation is pure QuickJS C work — no Ruby state
  // touched. Release the GVL so a background warmer thread can run this in
  // parallel with the main thread on multi-core hosts.
  struct vm_create_args args = {NULL};
  rb_thread_call_without_gvl(vm_create_no_gvl, &args, NULL, NULL);
  data->context = args.context;

  return obj;
}

// Utils

// Derived, not two independent numbers: snprintf truncates silently, so a
// buffer sized apart from the requested length would quietly hand back a
// shorter name than asked for the moment anyone raised the entropy.
#define QUICKJSRB_GENERATED_NAME_LEN 12
#define QUICKJSRB_GENERATED_NAME_SIZE (QUICKJSRB_GENERATED_NAME_LEN + 1)

// The handle a bridged object is published to the guest under. It was the
// Ruby object_id, which is a small sequential integer, and nothing ever leaves
// alive_objects — so a script could walk 1..4000 and be handed back objects it
// had never held: a File to read, a CryptoKey to sign with after every JS
// reference to it was gone. Drawn from 2^48 instead, which stays exact in a JS
// double and is not a space to walk. Collisions are re-drawn rather than
// trusted to be unlikely, since one would hand two subsystems the same entry.
#define QUICKJSRB_HANDLE_BITS 48
#define QUICKJSRB_HANDLE_DRAW_LIMIT 16

// Reads rb_object_id as an own data property, never through the prototype
// chain and never through a getter, and answers whether there was one. All
// three writers define it that way, so nothing legitimate is missed, and an
// accessor a guest puts on Object.prototype otherwise answers for every object
// that crosses back: one line of setup and a returned Hash becomes whichever
// host File or CryptoKey the guest already holds a handle for.
static inline bool j_read_own_handle(JSContext *ctx, JSValueConst j_val, JSValue *j_handle_out)
{
  JSAtom atom = JS_NewAtom(ctx, "rb_object_id");
  JSPropertyDescriptor desc;
  int found = JS_GetOwnProperty(ctx, &desc, j_val, atom);
  JS_FreeAtom(ctx, atom);
  if (found < 0)
  {
    // A Proxy trap answered and threw. The callers drain it.
    *j_handle_out = JS_EXCEPTION;
    return false;
  }
  if (found == 0)
    return false;
  if ((desc.flags & JS_PROP_TMASK) != JS_PROP_NORMAL)
  {
    JS_FreeValue(ctx, desc.value);
    JS_FreeValue(ctx, desc.getter);
    JS_FreeValue(ctx, desc.setter);
    return false;
  }
  JS_FreeValue(ctx, desc.getter);
  JS_FreeValue(ctx, desc.setter);
  *j_handle_out = desc.value;
  return true;
}

// Defined in quickjsrb.c. Declared here because the crypto reader needs it to
// give back an exception a guest's getter parked on its way through.
VALUE find_ruby_error(JSContext *ctx, JSValue j_error);
// Also in quickjsrb.c: whether the evaluation has outrun the budget it was
// armed with. Anything that hands a throw back to the guest has to ask, or a
// deadline that fired inside a getter becomes catchable.
bool eval_budget_lapsed_now(JSContext *ctx);
// Also in quickjsrb.c: takes a throw a reader is about to drop, after giving
// find_ruby_error the chance to unpark what it carries.
void quickjsrb_drain_pending(JSContext *ctx);

// The source the handle is drawn from, resolved once at Init and pinned rather
// than looked up per registration: the registrar runs inside QuickJS native
// callbacks with no rb_protect between them and the interpreter, which is the
// hazard r_crypto_key_class is written around, and a constant lookup is exactly
// the raise that hazard is about. The limit is 2^48 - 1 so the draw lands in
// 1 .. 2^48 - 1, because every reader treats a zero handle as "no entry" and a
// zero draw would strand the object.
//
// Narrowed rather than closed: the draw still calls into Ruby, so a
// NoMemoryError or an entropy failure raises from the same place. Pre-resolving
// takes the reachable cause off that path; the rest goes with the table, in
// #114.
//
// Defined in quickjsrb.c rather than here, because a static in a header gives
// every translation unit its own copy and only the one Init touched would be
// set.
extern VALUE quickjsrb_secure_random;
extern VALUE quickjsrb_handle_limit;
void quickjsrb_init_handle_source(void);

// Both rows go together: alive_handles is only a way back to the handle, and a
// handle left in alive_objects is what anchors the object for the life of the
// VM.
// Takes the handle rather than deriving it, so nothing here dispatches: these
// run on unwind paths inside JSCFunctions, where a raise is #134, and the
// registration side is under rb_protect for exactly that reason. rb_hash_delete
// on an existing key allocates nothing.
static inline void alive_objects_unregister(VMData *data, VALUE r_handle, VALUE r_object_id)
{
  rb_hash_delete(data->alive_objects, r_handle);
  rb_hash_delete(data->alive_handles, r_object_id);
}

// Same, for a caller that has the object but not the handle it was given. A
// miss is not an error: the object may never have been registered.
static inline void alive_objects_forget(VMData *data, VALUE r_object)
{
  VALUE r_object_id = rb_obj_id(r_object);
  VALUE r_handle = rb_hash_lookup2(data->alive_handles, r_object_id, Qnil);
  if (!NIL_P(r_handle))
    alive_objects_unregister(data, r_handle, r_object_id);
}

struct alive_register_work
{
  VMData *data;
  VALUE r_object;
  bool created;
};

static VALUE alive_objects_register_body(VALUE r_work)
{
  struct alive_register_work *work = (struct alive_register_work *)r_work;
  VMData *data = work->data;
  VALUE r_object = work->r_object;
  bool *created = &work->created;

  // One entry per object, not per crossing. The old handle was the object_id,
  // so re-bridging the same File or exception overwrote its own row; drawing a
  // fresh handle every time would instead add one, and nothing is ever removed,
  // so `for (i = 0; i < 200000; i++) f()` would grow the table by 200000.
  // rb_obj_id, not the method: a subclass can override object_id, and the two
  // sides of this table have to agree on the key find_ruby_error will use.
  VALUE r_object_id = rb_obj_id(r_object);
  VALUE r_known = rb_hash_lookup2(data->alive_handles, r_object_id, Qnil);
  // Reused only when the row still holds this object. Asking merely whether
  // the handle is occupied would hand back one that a later draw had given to
  // something else, since an object_id is only unique among live objects.
  if (!NIL_P(r_known) && rb_hash_lookup2(data->alive_objects, r_known, Qnil) == r_object)
  {
    if (created != NULL)
      *created = false;
    return r_known;
  }

  // Bounded, because nothing can interrupt a C loop: no QuickJS interrupt is
  // polled inside it, so timeout_msec cannot end it and only an outer
  // Timeout.timeout would, by longjmping out of here through the JSCFunction
  // frames this file warns about elsewhere. A host whose suite stubs the
  // source flat (`SecureRandom.random_number` returning a constant is an
  // ordinary test-double line) would otherwise spin forever on the second
  // object it bridges. Sixteen draws against a 2^48 range only run out when
  // the source is not random, so say that rather than degrade to a sequence a
  // guest could walk.
  //
  // Refusing rather than raising also settles what the old note here worried
  // about: there is no longjmp out of js_crypto_key_to_js past a promise
  // capability it never allocated, because there is no longjmp at all.
  VALUE r_handle;
  int attempts = 0;
  do
  {
    if (++attempts > QUICKJSRB_HANDLE_DRAW_LIMIT)
    {
      // Latched and handed back as a refusal, never raised from here. This runs
      // inside a JSCFunction, and a longjmp out of one leaves the runtime's
      // frame chain pointing at C stack that is gone: the next Error the guest
      // builds walks it in build_backtrace and takes the process with it. The
      // next entry point reports this instead, the way an out-of-memory is.
      data->handle_source_broken = true;
      if (created != NULL)
        *created = false;
      return Qnil;
    }
    r_handle = rb_funcall(quickjsrb_secure_random, rb_intern("random_number"), 1, quickjsrb_handle_limit);

    // The draw is checked into an int64_t before anything uses it as a number.
    // The bound above only catches a source that keeps returning the same
    // value, and everything else a source can return raises here, inside the
    // loop, before the bound is ever consulted: NUM2LL raises RangeError on a
    // Bignum, dispatching + raises NoMethodError on nil, and a raise out of a
    // JSCFunction is #134. rb_integer_pack answers the sign and reports a
    // value too wide to fit rather than raising about it, and it does not
    // dispatch, which a source could also answer for.
    //
    // Out of range is refused rather than clamped: a negative draw is stored
    // under a key every reader treats as "no entry", so the object is anchored
    // for the life of the VM and the exception it was bridging comes back as a
    // generic Quickjs::RuntimeError instead of itself.
    int64_t drawn = 0;
    bool usable = RB_INTEGER_TYPE_P(r_handle);
    if (usable)
    {
      // Asked only of an Integer: rb_integer_pack raises on anything else,
      // which is the raise this check exists to avoid.
      int sign = rb_integer_pack(r_handle, &drawn, 1, sizeof(int64_t), 0,
                                 INTEGER_PACK_NATIVE_BYTE_ORDER | INTEGER_PACK_2COMP);
      usable = sign >= 0 && sign <= 1 && drawn >= 0 && drawn < ((int64_t)1 << QUICKJSRB_HANDLE_BITS);
    }
    if (!usable)
    {
      data->handle_source_broken = true;
      if (created != NULL)
        *created = false;
      return Qnil;
    }
    r_handle = LL2NUM(drawn + 1);
  } while (!NIL_P(rb_hash_lookup2(data->alive_objects, r_handle, Qnil)));

  rb_hash_aset(data->alive_objects, r_handle, r_object);
  rb_hash_aset(data->alive_handles, r_object_id, r_handle);
  if (created != NULL)
    *created = true;
  return r_handle;
}

// Answers the handle, and says through `created` whether this call is the one
// that made the row: a caller that has to undo the registration must not undo
// a row an earlier crossing of the same object is still relying on. Answers
// Qnil, having latched handle_source_broken, when it cannot draw one.
//
// Protected, because the work it wraps runs inside a JSCFunction and a raise out
// of one leaves QuickJS's frame chain pointing at C stack that is gone: the
// next Error the guest builds walks it and takes the process with it (#134).
// The draw is a Ruby dispatch this branch introduced, so it is this branch's
// job not to open that door: a strict test double raises on an unexpected
// invocation as readily as a loose one returns a constant, and rb_hash_aset can
// raise NoMemoryError on the same path. A raise is treated as an unusable draw,
// which is what it is.
static inline VALUE alive_objects_register(VMData *data, VALUE r_object, bool *created)
{
  struct alive_register_work work = {data, r_object, false};
  int state = 0;
  VALUE r_handle = rb_protect(alive_objects_register_body, (VALUE)&work, &state);
  if (state)
  {
    // Kept, not discarded. rb_protect catches everything, and most of what it
    // can catch here is not a broken handle source: an Interrupt from Ctrl-C, a
    // Timeout::Error from the host's own Timeout.timeout, anything a
    // Thread#raise lands in this window. Swallowing one of those loses it with
    // no trace and then blames a test double that does not exist. It is
    // re-raised from the next entry point instead, with its own class and
    // message, because here there is a QuickJS frame to unwind through and
    // that is #134.
    //
    // Not latched, either: a Timeout::Error that arrived once says nothing
    // about the handle source, and condemning the VM for it would be the wrong
    // diagnosis twice over. The latch is for a source that answers badly, which
    // is decided inside the body and does not come through here.
    data->r_registrar_error = rb_errinfo();
    rb_set_errinfo(Qnil);
    if (created != NULL)
      *created = false;
    return Qnil;
  }
  if (created != NULL)
    *created = work.created;
  return r_handle;
}

static void random_filename(char buf[QUICKJSRB_GENERATED_NAME_SIZE])
{
  VALUE r_rand = rb_funcall(
      rb_const_get(rb_cClass, rb_intern("SecureRandom")),
      rb_intern("alphanumeric"),
      1,
      INT2NUM(QUICKJSRB_GENERATED_NAME_LEN));
  // Copy the bytes out rather than handing back StringValueCStr(r_rand):
  // nothing else references the generated String, so a GC anywhere in the
  // caller's remaining work frees it and leaves the caller formatting bytes
  // from a recycled slot.
  snprintf(buf, QUICKJSRB_GENERATED_NAME_SIZE, "%s", StringValueCStr(r_rand));
  RB_GC_GUARD(r_rand);
}

static bool is_native_error_name(const char *error_name)
{
  for (int i = 0; i < num_native_errors; i++)
  {
    if (strcmp(native_errors[i], error_name) == 0)
      return true;
  }
  return false;
}

// Constants

static void r_define_constants(VALUE r_parent_class)
{
  rb_define_const(r_parent_class, "MODULE_STD", QUICKJSRB_SYM(featureStdId));
  rb_define_const(r_parent_class, "MODULE_OS", QUICKJSRB_SYM(featureOsId));
  rb_define_const(r_parent_class, "FEATURE_TIMEOUT", QUICKJSRB_SYM(featureTimeoutId));
  rb_define_const(r_parent_class, "POLYFILL_FILE", QUICKJSRB_SYM(featurePolyfillFileId));
  rb_define_const(r_parent_class, "POLYFILL_ENCODING", QUICKJSRB_SYM(featurePolyfillEncodingId));
  rb_define_const(r_parent_class, "POLYFILL_URL", QUICKJSRB_SYM(featurePolyfillUrlId));
  rb_define_const(r_parent_class, "POLYFILL_CRYPTO", QUICKJSRB_SYM(featurePolyfillCryptoId));

  VALUE rb_cQuickjsValue = rb_define_class_under(r_parent_class, "Value", rb_cObject);
  rb_define_const(rb_cQuickjsValue, "UNDEFINED", QUICKJSRB_SYM(undefinedId));
  rb_define_const(rb_cQuickjsValue, "NAN", QUICKJSRB_SYM(nanId));
}

// Log class

static VALUE r_proc_pick_raw(VALUE block_arg, VALUE data, int argc, const VALUE *argv, VALUE blockarg)
{
  return rb_hash_aref(block_arg, ID2SYM(rb_intern("raw")));
}

static VALUE r_log_m_raw(VALUE r_self)
{
  VALUE row = rb_iv_get(r_self, "@row");
  VALUE r_ary = rb_block_call(row, rb_intern("map"), 0, NULL, r_proc_pick_raw, Qnil);

  return r_ary;
}

static VALUE r_proc_pick_c(VALUE block_arg, VALUE data, int argc, const VALUE *argv, VALUE blockarg)
{
  return rb_hash_aref(block_arg, ID2SYM(rb_intern("c")));
}

static VALUE r_log_m_to_s(VALUE r_self)
{
  VALUE row = rb_iv_get(r_self, "@row");
  VALUE r_ary = rb_block_call(row, rb_intern("map"), 0, NULL, r_proc_pick_c, Qnil);

  return rb_funcall(r_ary, rb_intern("join"), 1, rb_str_new2(" "));
}

static VALUE r_define_log_class(VALUE r_parent_class)
{
  VALUE r_log_class = rb_define_class_under(r_parent_class, "Log", rb_cObject);
  rb_define_attr(r_log_class, "severity", 1, 0);
  rb_define_method(r_log_class, "raw", r_log_m_raw, 0);
  rb_define_method(r_log_class, "to_s", r_log_m_to_s, 0);
  rb_define_method(r_log_class, "inspect", r_log_m_to_s, 0);

  return r_log_class;
}

static VALUE r_log_new(const char *severity, VALUE r_row)
{
  VALUE r_log_class = rb_const_get(rb_const_get(rb_const_get(rb_cClass, rb_intern("Quickjs")), rb_intern("VM")), rb_intern("Log"));
  VALUE r_log = rb_funcall(r_log_class, rb_intern("new"), 0);
  rb_iv_set(r_log, "@severity", ID2SYM(rb_intern(severity)));
  rb_iv_set(r_log, "@row", r_row);
  return r_log;
}

static VALUE r_log_body_new(VALUE r_raw, VALUE r_c)
{
  VALUE r_log_body = rb_hash_new();
  rb_hash_aset(r_log_body, ID2SYM(rb_intern("raw")), r_raw);
  rb_hash_aset(r_log_body, ID2SYM(rb_intern("c")), r_c);
  return r_log_body;
}

// Exceptions

#define QUICKJSRB_ROOT_RUNTIME_ERROR "RuntimeError"
#define QUICKJSRB_INTERRUPTED_ERROR "InterruptedError"
#define QUICKJSRB_NO_AWAIT_ERROR "NoAwaitError"

#define QUICKJSRB_ERROR_FOR(name) \
  (VALUE) { rb_const_get(rb_const_get(rb_cClass, rb_intern("Quickjs")), rb_intern(name)) }

static VALUE vm_m_initialize_quickjs_error(VALUE self, VALUE r_message, VALUE r_js_name)
{
  rb_call_super(1, &r_message);
  rb_iv_set(self, "@js_name", r_js_name);

  return self;
}

static void r_define_exception_classes(VALUE r_parent_class)
{
  VALUE r_runtime_error = rb_define_class_under(r_parent_class, QUICKJSRB_ROOT_RUNTIME_ERROR, rb_eRuntimeError);
  rb_define_method(r_runtime_error, "initialize", vm_m_initialize_quickjs_error, 2);
  rb_define_attr(r_runtime_error, "js_name", 1, 0);

  for (int i = 0; i < num_native_errors; i++)
  {
    rb_define_class_under(r_parent_class, native_errors[i], r_runtime_error);
  }

  // quickjsrb specific errors
  rb_define_class_under(r_parent_class, QUICKJSRB_INTERRUPTED_ERROR, r_runtime_error);
  rb_define_class_under(r_parent_class, QUICKJSRB_NO_AWAIT_ERROR, r_runtime_error);
}

#endif /* QUICKJSRB_H */
