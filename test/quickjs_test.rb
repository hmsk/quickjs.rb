# frozen_string_literal: true

require_relative "test_helper"

describe Quickjs do
  it "VERSION" do
    assert ::Quickjs.const_defined?(:VERSION)
  end

  def assert_code(code, expected)
    result = ::Quickjs.eval_code(code)
    if expected.nil?
      _(result).must_be_nil
    else
      _(result).must_equal expected
    end
  end

  describe "ResultConversion" do
    it "null becomes nil" do
      assert_code("null", nil)
    end

    it "undefined becomes a specific constant" do
      assert_code("undefined", Quickjs::Value::UNDEFINED)
      assert_code("const obj = {}; obj.missing;", Quickjs::Value::UNDEFINED)
    end

    it "NaN becomes a specific constant" do
      assert_code("Number('whatever')", Quickjs::Value::NAN)
    end

    it "string becomes String" do
      assert_code("'1'", "1")
      assert_code("const promise = new Promise((res) => { res('awaited yo') });await promise", "awaited yo")
    end

    it "non-ascii string even becomes String" do
      assert_code("'ボーナス'", "ボーナス")
      assert_code("'🆔'", "🆔")
    end

    it "source code containing an embedded NUL byte is not truncated" do
      assert_code("'a\0b'.length", 3)
    end

    it "string built via repeated concat (QuickJS rope) round-trips" do
      result = ::Quickjs.eval_code(<<~JS)
        let s = "";
        for (let i = 0; i < 10000; i++) s += "abc";
        s;
      JS
      _(result).must_equal 'abc' * 10000
    end

    it "number for integer becomes Integer" do
      assert_code("2+3", 5)
      assert_code("18014398509481982n", 18014398509481982)
    end

    it "number for float becomes Float" do
      assert_code("1.0", 1.0)
      assert_code("2 ** 0.5", 1.4142135623730951)
    end

    it "boolean becomes TruClass/FalseClass" do
      assert_code("false", false)
      assert_code("true", true)
      assert_code("1 === 1", true)
      assert_code("1 == 3", false)
    end

    it "plain k-v object becomes Hash" do
      assert_code("const obj = {}; obj", {})
      assert_code("const obj = { a: '1', b: 1 }; obj;", { 'a' => '1', 'b' => 1 })
    end

    it "plain array object becomes Array" do
      assert_code("[1, 2, 3]", [1, 2, 3])
      assert_code("['a', 2, 'third']", ['a', 2, 'third'])
      assert_code("[1, 2, { 'third': 'sad' }]", [1, 2, { 'third' => 'sad' }])
    end

    it "undefined nested in plain object or array is preserved" do
      assert_code("({ a: undefined, b: 1 })", { 'a' => Quickjs::Value::UNDEFINED, 'b' => 1 })
      assert_code("({ a: { b: undefined } })", { 'a' => { 'b' => Quickjs::Value::UNDEFINED } })
      assert_code("[1, undefined, 3]", [1, Quickjs::Value::UNDEFINED, 3])
    end

    it "NaN nested in plain object or array is preserved" do
      assert_code("({ a: NaN })", { 'a' => Quickjs::Value::NAN })
      assert_code("[NaN, 1]", [Quickjs::Value::NAN, 1])
    end

    it "non-plain objects fall back to JSON conversion" do
      assert_code("new Date('2024-01-01T00:00:00.000Z').toISOString()", "2024-01-01T00:00:00.000Z")
    end

    it "Date object becomes its ISO string via toJSON" do
      assert_code("new Date('2024-01-01T00:00:00.000Z')", "2024-01-01T00:00:00.000Z")
    end

    it "object with toJSON honours its custom representation" do
      assert_code(<<~JS, 1.5)
        class Money {
          constructor(cents) { this._cents = cents }
          toJSON() { return this._cents / 100 }
        }
        new Money(150);
      JS
    end

    it "class instance without toJSON preserves undefined own properties" do
      assert_code(<<~JS, {'a' => 1, 'b' => Quickjs::Value::UNDEFINED})
        class X {
          constructor() { this.a = 1; this.b = undefined }
        }
        new X();
      JS
    end

    it "Map and RegExp without enumerable own properties become {}" do
      assert_code("new Map([['a', 1]])", {})
      assert_code("/abc/g", {})
    end

    it "circular plain object converts cycle entry to nil" do
      assert_code("const o = {a: 1}; o.self = o; o", {'a' => 1, 'self' => nil})
    end

    it "circular non-plain object converts cycle entry to nil" do
      # Without cycle detection this would recurse via js_plain_object_to_rb
      # forever and SIGILL the host.
      assert_code(<<~JS, {'self' => nil})
        const o = {};
        o.self = o;
        Object.setPrototypeOf(o, Object.create({ tag: 1 }));
        o;
      JS
    end

    it "circular array converts cycle entry to nil" do
      assert_code("const a = [1, 2]; a.push(a); a", [1, 2, nil])
    end

    it "circular non-plain object via vm.call returns the same shape" do
      vm = Quickjs::VM.new
      vm.eval_code(<<~JS)
        globalThis.makeCircular = () => {
          const o = {};
          o.self = o;
          Object.setPrototypeOf(o, Object.create({ tag: 1 }));
          return o;
        };
      JS
      _(vm.call('makeCircular')).must_equal({'self' => nil})
    end

    it "function becomes Quickjs::Function" do
      result = ::Quickjs.eval_code("() => 'hi'")
      _(result).must_be_instance_of Quickjs::Function
    end
  end

  describe "Exceptions" do
    it "throws Quickjs::SyntaxError if SyntaxError happens" do
      err = _ { ::Quickjs.eval_code("}{") }.must_raise Quickjs::SyntaxError
      _(err.message).must_equal "unexpected token in expression: '}'"
      _(err.js_name).must_equal "SyntaxError"
    end

    it "throws Quickjs::TypeError if TypeError happens" do
      err = _ { ::Quickjs.eval_code("globalThis.func()") }.must_raise Quickjs::TypeError
      _(err.message).must_equal "not a function"
      _(err.js_name).must_equal "TypeError"
    end

    it "throws Quickjs::ReferenceError if ReferenceError happens" do
      err = _ { ::Quickjs.eval_code("let a = undefinedVariable;") }.must_raise Quickjs::ReferenceError
      _(err.message).must_equal "'undefinedVariable' is not defined"
      _(err.js_name).must_equal "ReferenceError"
    end

    it "throws Quickjs::RangeError if RangeError happens" do
      err = _ { ::Quickjs.eval_code("throw new RangeError('out of range')") }.must_raise Quickjs::RangeError
      _(err.message).must_equal "out of range"
      _(err.js_name).must_equal "RangeError"
    end

    it "throws Quickjs::EvalError if EvalError happens" do
      err = _ { ::Quickjs.eval_code("throw new EvalError('I am old')") }.must_raise Quickjs::EvalError
      _(err.message).must_equal "I am old"
      _(err.js_name).must_equal "EvalError"
    end

    it "throws Quickjs::URIError if URIError happens" do
      err = _ { ::Quickjs.eval_code("decodeURIComponent('%')") }.must_raise Quickjs::URIError
      _(err.message).must_equal "expecting hex digit"
      _(err.js_name).must_equal "URIError"
    end

    it "throws Quickjs::AggregateError if AggregateError happens" do
      err = _ { ::Quickjs.eval_code("throw new AggregateError([new Error('some error')], 'aggregated')") }.must_raise Quickjs::AggregateError
      _(err.message).must_equal "aggregated"
      _(err.js_name).must_equal "AggregateError"
    end

    it "throws Quickjs::RuntimeError if custom exception happens" do
      err = _ { ::Quickjs.eval_code("class MyError extends Error { constructor(message) { super(message); this.name = 'CustomError'; } }; throw new MyError('my error')") }.must_raise Quickjs::RuntimeError
      _(err.message).must_equal "my error"
      _(err.js_name).must_equal "CustomError"
    end

    it "throws is awaited Promise is rejected" do
      err = _ {
        ::Quickjs.eval_code("const promise = new Promise((res) => { throw 'asynchronously sad' });await promise")
      }.must_raise Quickjs::RuntimeError
      _(err.message).must_equal "asynchronously sad"
      _(err.js_name).must_be_nil
    end

    it "exposes the JS Error.stack as the Ruby exception's backtrace" do
      err = _ {
        ::Quickjs.eval_code(<<~JS, filename: 'demo.js')
          function inner() { throw new TypeError('boom'); }
          function outer() { inner(); }
          outer();
        JS
      }.must_raise Quickjs::TypeError

      _(err.backtrace).wont_be_nil
      joined = err.backtrace.join("\n")
      _(joined).must_match(/inner.*demo\.js/)
      _(joined).must_match(/outer.*demo\.js/)
    end

    it "leaves the Ruby default backtrace in place for non-Error throws (no JS stack to surface)" do
      err = _ {
        ::Quickjs.eval_code("throw 'bare string';", filename: 'demo.js')
      }.must_raise Quickjs::RuntimeError

      # A bare throw has no .stack property, so no JS frame ever lands in
      # the backtrace — Ruby's default is left in place.
      _(err.backtrace.any? {|line| line.include?('demo.js') }).must_equal false
    end

    it "throws an exception if promise instance is returned" do
      err = _ {
        ::Quickjs.eval_code("const promise = new Promise((res) => { res('awaited yo') });promise")
      }.must_raise Quickjs::NoAwaitError
      _(err.message).must_equal "An unawaited Promise was returned to the top-level"
      _(err.js_name).must_be_nil
    end

    it "throws TypeError if nil is passed to eval_code" do
      err = _ { ::Quickjs.eval_code(nil) }.must_raise TypeError
      _(err.message).must_equal "JavaScript code must be a String, got NilClass"
    end

    it "throws TypeError if Hash is passed to eval_code" do
      err = _ { ::Quickjs.eval_code({ code: "test" }) }.must_raise TypeError
      _(err.message).must_equal "JavaScript code must be a String, got Hash"
    end
  end

  describe "EvalFilename" do
    it "uses '<code>' as the source name by default" do
      stack = ::Quickjs.eval_code(<<~JS)
        try { throw new Error('boom') } catch (e) { e.stack }
      JS
      _(stack).must_match(/<code>/)
    end

    it "carries filename: through to JS stack traces" do
      stack = ::Quickjs.eval_code(<<~JS, filename: '/path/to/jquery.js')
        try { throw new Error('boom') } catch (e) { e.stack }
      JS
      _(stack).must_match(%r{/path/to/jquery\.js})
    end

    it "Quickjs::VM#eval_code accepts filename: too" do
      vm = Quickjs::VM.new
      stack = vm.eval_code(<<~JS, filename: 'foo.js')
        try { throw new Error('x') } catch (e) { e.stack }
      JS
      _(stack).must_match(/foo\.js/)
    end
  end

  describe "SyncEval" do
    it "evaluates synchronously when async: false" do
      vm = Quickjs::VM.new
      _(vm.eval_code('1 + 1', async: false)).must_equal 2
      _(vm.eval_code('"hi"', async: false)).must_equal "hi"
    end

    it "returns a Promise object instead of awaiting in sync mode" do
      vm = Quickjs::VM.new
      # In async (default) mode this would await and resolve to "ok".
      # In sync mode the Promise leaks back to the embedder; we surface it via
      # the existing NoAwaitError.
      _ {
        vm.eval_code('Promise.resolve("ok")', async: false)
      }.must_raise Quickjs::NoAwaitError
    end

    it "Quickjs.eval_code forwards async: option" do
      _(::Quickjs.eval_code('1 + 2', async: false)).must_equal 3
    end
  end

  it "std module can be enabled" do
    assert_code("typeof std === 'undefined'", true)
    _(::Quickjs.eval_code("!!std.urlGet", { features: [::Quickjs::MODULE_STD] })).must_equal true
  end

  it "os module can be enabled" do
    assert_code("typeof os === 'undefined'", true)
    _(::Quickjs.eval_code("!!os.kill", { features: [::Quickjs::MODULE_OS] })).must_equal true
  end

  it "only setTimeout is provided per the flag" do
    assert_code("typeof setTimeout === 'undefined'", true)
    _(::Quickjs.eval_code("typeof setTimeout", { features: [::Quickjs::FEATURE_TIMEOUT] })).must_equal 'function'
  end

end

describe Quickjs::VM do
  describe "WithPlainVM" do
    before do
      @vm = Quickjs::VM.new
    end

    it "maintains the same context within a vm" do
      @vm.eval_code('const a = { b: "c" };')
      _(@vm.eval_code('a.b')).must_equal "c"
      _(@vm.eval_code('a.b')).must_equal "c"
      @vm.eval_code('a.b = "d"')
      _(@vm.eval_code('a.b')).must_equal "d"
    end

    it "after OOM, marks the VM poisoned and refuses further evaluation" do
      # 1 MB limit; allocate a single buffer larger than that.
      vm = Quickjs::VM.new(memory_limit: 1024 * 1024)
      _(vm.memory_poisoned?).must_equal false
      _ { vm.eval_code('new Array(2_000_000).fill(0); void 0') }.must_raise Quickjs::RuntimeError
      _(vm.memory_poisoned?).must_equal true
      err = _ { vm.eval_code('1 + 1') }.must_raise Quickjs::RuntimeError
      _(err.message).must_match(/poisoned/)
    end

    it "memory_usage returns a hash of QuickJS heap stats" do
      stats = @vm.memory_usage
      _(stats).must_be_kind_of Hash
      _(stats[:malloc_size]).must_be :>, 0
      _(stats[:obj_count]).must_be :>, 0
    end

    it "gc! returns nil and is callable" do
      _(@vm.gc!).must_be_nil
    end

    it "does not enable std/os module as default" do
      _(@vm.eval_code("typeof std === 'undefined'")).must_equal true
      _(@vm.eval_code("typeof os === 'undefined'")).must_equal true
    end

    it "does not have std helpers" do
      _(@vm.eval_code("typeof __loadScript === 'undefined'")).must_equal true
      _(@vm.eval_code("typeof scriptArgs === 'undefined'")).must_equal true
      _(@vm.eval_code("typeof print === 'undefined'")).must_equal true
    end

    it "throws TypeError when eval_code receives nil" do
      err = _ { @vm.eval_code(nil) }.must_raise TypeError
      _(err.message).must_equal "JavaScript code must be a String, got NilClass"
    end

    it "throws TypeError when eval_code receives Hash" do
      err = _ { @vm.eval_code({ test: true }) }.must_raise TypeError
      _(err.message).must_equal "JavaScript code must be a String, got Hash"
    end
  end

  describe "Dispose" do
    it "dispose! returns nil and flips disposed?" do
      vm = Quickjs::VM.new
      _(vm.disposed?).must_equal false
      _(vm.dispose!).must_be_nil
      _(vm.disposed?).must_equal true
    end

    it "dispose! is idempotent" do
      vm = Quickjs::VM.new
      vm.dispose!
      _(vm.dispose!).must_be_nil
      _(vm.disposed?).must_equal true
    end

    {
      eval_code:       ->(vm) { vm.eval_code('1 + 1') },
      compile:         ->(vm) { vm.compile('1 + 1') },
      call:            ->(vm) { vm.call('foo') },
      define_function: ->(vm) { vm.define_function('foo') { 1 } },
      import:          ->(vm) { vm.import('x', from: 'export default 1') },
      drain_jobs!:     ->(vm) { vm.drain_jobs! },
      memory_usage:    ->(vm) { vm.memory_usage },
      gc!:             ->(vm) { vm.gc! }
    }.each do |method, invoke|
      it "#{method} on a disposed VM raises Quickjs::RuntimeError" do
        vm = Quickjs::VM.new
        vm.dispose!
        err = _ { invoke.call(vm) }.must_raise Quickjs::RuntimeError
        _(err.message).must_match(/disposed/)
      end
    end

    it "memory_poisoned? remains queryable after dispose" do
      vm = Quickjs::VM.new
      vm.dispose!
      _(vm.memory_poisoned?).must_equal false
    end

    it "lets Ruby GC reclaim a disposed VM without double-free" do
      10.times { Quickjs::VM.new.dispose! }
      GC.start
      pass
    end

    # eval_code releases the GVL on the pure path, so a dispose! from another
    # thread can genuinely overlap a running JS_Eval — freeing the runtime
    # under it would be a use-after-free. The in-flight guard turns that into
    # a loud contract violation instead.
    it "raises ThreadError while another thread is evaluating" do
      in_eval = Queue.new
      vm = nil
      evaluator = Thread.new do
        # Created inside the thread: QuickJS records the creator's stack
        # bounds, and evaluating from a thread whose stack sits below them
        # trips a false stack-overflow error.
        vm = Quickjs::VM.new(timeout_msec: 5_000, features: [::Quickjs::MODULE_OS])
        vm.on_log { |_log| in_eval << true }
        vm.eval_code('console.log("in eval"); os.sleep(1000); "finished"')
      end

      in_eval.pop # the eval is now provably in flight (and stays so for ~1s)
      err = _ { vm.dispose! }.must_raise ThreadError
      _(err.message).must_match(/while it is evaluating/)

      _(evaluator.value).must_equal 'finished'
      vm.dispose!
      _(vm.disposed?).must_equal true
    end

    # The bridged (GVL-held) eval path must be guarded too: setTimeout's
    # js_delay_and_eval_job yields the GVL via rb_thread_wait_for, so a
    # concurrent dispose! can genuinely interleave with the eval even though
    # the eval never released the GVL itself.
    it "raises ThreadError while a bridged (GVL-held) eval is in flight" do
      in_eval = Queue.new
      vm = nil
      evaluator = Thread.new do
        vm = Quickjs::VM.new(timeout_msec: 5_000, features: [::Quickjs::FEATURE_TIMEOUT])
        vm.on_log { |_log| in_eval << true }
        vm.eval_code('console.log("in eval"); await new Promise(resolve => setTimeout(resolve, 1000)); "finished"')
      end

      in_eval.pop
      err = _ { vm.dispose! }.must_raise ThreadError
      _(err.message).must_match(/while it is evaluating/)

      _(evaluator.value).must_equal 'finished'
      vm.dispose!
      _(vm.disposed?).must_equal true
    end

    # An async interrupt (Timeout / Thread#raise) delivered inside setTimeout's
    # rb_thread_wait_for longjmps out of the eval. evals_in_flight must unwind
    # with it (rb_ensure, not a bare ++/-- pair), or the guard above would
    # refuse dispose! forever on a VM that is no longer evaluating anything.
    # One test per GVL-held entry point that elevates the counter around a
    # region that can reach the bridge.
    it "stays disposable after an async interrupt lands mid-eval" do
      vm = Quickjs::VM.new(features: [::Quickjs::FEATURE_TIMEOUT])

      _ {
        Timeout.timeout(0.1) { vm.eval_code('await new Promise(resolve => setTimeout(resolve, 60000));') }
      }.must_raise Timeout::Error

      vm.dispose!
      _(vm.disposed?).must_equal true
    end

    it "stays disposable after an async interrupt lands mid-bytecode-run" do
      vm = Quickjs::VM.new(features: [::Quickjs::FEATURE_TIMEOUT])
      runnable = vm.compile('await new Promise(resolve => setTimeout(resolve, 60000));')

      _ {
        Timeout.timeout(0.1) { runnable.run(on: vm) }
      }.must_raise Timeout::Error

      vm.dispose!
      _(vm.disposed?).must_equal true
    end

    it "stays disposable after an async interrupt lands mid-drain_jobs!" do
      vm = Quickjs::VM.new(features: [::Quickjs::FEATURE_TIMEOUT])
      vm.eval_code('setTimeout(() => {}, 60000); void 0')

      _ {
        Timeout.timeout(0.1) { vm.drain_jobs! }
      }.must_raise Timeout::Error

      vm.dispose!
      _(vm.disposed?).must_equal true
    end
  end

  describe "one VM, one thread at a time" do
    # QuickJS contexts have no internal locking, so two threads inside JS on
    # one VM corrupt the heap. The bridge blocking on a Queue is what makes
    # this deterministic: the proc yields the GVL while it waits, so the
    # second thread genuinely runs while the first is mid-entry.
    it "refuses a second thread while a JS entry is in flight" do
      vm = Quickjs::VM.new(timeout_msec: 30_000)
      entered = Queue.new
      release = Queue.new
      vm.define_function('pause') do
        entered << :in
        release.pop
        1
      end

      runner = Thread.new { vm.eval_code('pause(); 42') }
      entered.pop

      err = _ { vm.eval_code('1 + 1') }.must_raise ThreadError
      _(err.message).must_match(/from two threads at once/)

      release << :go
      _(runner.value).must_equal 42
    end

    it "refuses every entry point, not just eval_code" do
      vm = Quickjs::VM.new(timeout_msec: 30_000)
      entered = Queue.new
      release = Queue.new
      vm.define_function('pause') do
        entered << :in
        release.pop
        1
      end
      vm.eval_code('globalThis.noop = () => 1')

      runner = Thread.new { vm.eval_code('pause(); 42') }
      entered.pop

      _ { vm.compile('1 + 1') }.must_raise ThreadError
      _ { vm.call('noop') }.must_raise ThreadError
      _ { vm.drain_jobs! }.must_raise ThreadError
      _ { vm.import('X', from: 'export default 1;') }.must_raise ThreadError
      _ { vm.define_function('another') { 1 } }.must_raise ThreadError
      # Not JS entries, but they walk the same runtime: JS_RunGC beside live
      # JS is a heap corruptor, and the usage read races the allocator.
      _ { vm.gc! }.must_raise ThreadError
      _ { vm.memory_usage }.must_raise ThreadError

      release << :go
      _(runner.value).must_equal 42
    end

    # The counter alone cannot express the rule: same-thread nesting elevates
    # it too, and a bridge re-entering its own VM is a supported shape.
    it "still allows the owning thread to re-enter from a bridge" do
      vm = Quickjs::VM.new
      vm.define_function('nested') { vm.eval_code('1 + 1') }

      _(vm.eval_code('nested()')).must_equal 2
    end

    it "still allows a VM to move between threads when nothing is in flight" do
      vm = Quickjs::VM.new

      _(Thread.new { vm.eval_code('1 + 1') }.value).must_equal 2
      _(Thread.new { vm.eval_code('2 + 2') }.value).must_equal 4
      _(vm.eval_code('3 + 3')).must_equal 6
    end

    # define_function resolves an array path with JS_Eval, so it holds the VM
    # for real work. A check that only refused when someone else was already
    # in flight would pass on an idle VM and claim nothing, letting a second
    # thread pass the same idle check and land in JS_Eval alongside it.
    it "claims the VM while resolving a define_function path, not just checks" do
      vm = Quickjs::VM.new(timeout_msec: 30_000)
      in_getter = Queue.new
      release = Queue.new
      vm.define_function('gate') do
        in_getter << :in
        release.pop
        1
      end
      vm.eval_code(<<~JS)
        globalThis._lib = {};
        Object.defineProperty(globalThis, 'myLib', { get: () => { gate(); return _lib; } });
        0
      JS

      definer = Thread.new { vm.define_function(%w[myLib hello]) { 42 } }
      in_getter.pop # provably inside JS_Eval on the path's first segment

      _ { vm.eval_code('1 + 1') }.must_raise ThreadError

      release << :go
      definer.join
      _(vm.eval_code('_lib.hello()')).must_equal 42
    end

    # module_loader= swaps the loader on the live runtime, so doing it while
    # another thread imports would change resolution mid-flight.
    it "refuses module_loader= while another thread is evaluating" do
      vm = Quickjs::VM.new(timeout_msec: 30_000)
      entered = Queue.new
      release = Queue.new
      vm.define_function('pause') do
        entered << :in
        release.pop
        1
      end

      runner = Thread.new { vm.eval_code('pause(); 42') }
      entered.pop

      _ { vm.module_loader = ->(_s, _i) { nil } }.must_raise ThreadError

      release << :go
      _(runner.value).must_equal 42
    end

    # register_module_loader_funcs dereferences the context, so this was a
    # use-after-free rather than an exception.
    it "refuses module_loader= on a disposed VM" do
      vm = Quickjs::VM.new
      vm.dispose!

      _ { vm.module_loader = ->(_s, _i) { nil } }.must_raise Quickjs::RuntimeError
    end

    # A stranded owner would lock the VM to one thread for good, the same way
    # a stranded counter would refuse dispose! forever.
    it "releases ownership when the entry ends by raising" do
      vm = Quickjs::VM.new
      _ { vm.eval_code('nope()') }.must_raise Quickjs::ReferenceError

      _(Thread.new { vm.eval_code('1 + 1') }.value).must_equal 2
    end
  end

  it "accepts some options to constrain its resource" do
    vm = Quickjs::VM.new(
      memory_limit: 1024 * 1024,
      max_stack_size: 1024 * 1024,
    )
    _(vm.eval_code('1+2')).must_equal 3
  end

  it "enables std module via features option" do
    vm = Quickjs::VM.new(
      features: [::Quickjs::MODULE_STD],
    )
    _(vm.eval_code("!!std.urlGet")).must_equal true
  end

  it "enables os module via features option" do
    vm = Quickjs::VM.new(
      features: [::Quickjs::MODULE_OS],
    )
    _(vm.eval_code("!!os.kill")).must_equal true
  end

  it "gets timeout from evaluation" do
    vm = Quickjs::VM.new

    _ { vm.eval_code("while(1) {}") }.must_raise Quickjs::InterruptedError
  end

  it "accepts timeout_msec option to control maximum evaluation time" do
    vm = Quickjs::VM.new(timeout_msec: 200)

    started = Time.now.to_f * 1000
    _ { vm.eval_code("while(1) {}") }.must_raise Quickjs::InterruptedError
    # CI runners under load have been observed drifting ~55ms past the
    # configured 200ms. Widen the window so the test catches "timer wildly
    # wrong" (orders of magnitude off) without flapping on normal noise.
    assert_in_delta(started + 200, Time.now.to_f * 1000, 100)
  end

  # compile arms the eval timer, which resets the clock the enclosing eval is
  # being measured against. Unguarded, every c() here pushed started_at
  # forward, interrupt_handler never saw the limit elapse, and the loop ran
  # forever on a VM that asked to be bounded at 200ms.
  #
  # Bounded rather than `while (true)` so a regression fails instead of
  # hanging the suite: one bridged compile costs ~7us, so the budget lapses
  # around iteration 27k and the loop caps out at ~1.5s if it doesn't.
  it "a compile inside a bridge callback does not reset the enclosing eval's budget" do
    vm = Quickjs::VM.new(timeout_msec: 200)
    vm.define_function('c') { vm.compile('function a() {}'); 1 }

    _ {
      vm.eval_code('let s = 0; for (let i = 0; i < 200000; i++) { s += c(); } s')
    }.must_raise Quickjs::InterruptedError
  end

  it "can enable setTimeout selectively" do
    skip "should timeout"
    vm = Quickjs::VM.new(features: [::Quickjs::MODULE_OS])
    vm.eval_code('const longProcess = () => { const pro = new Promise((res) => os.setTimeout(() => res(), 5000)); return pro; }')

    _ { vm.eval_code("await longProcess()") }.must_raise Quickjs::InterruptedError
  end

  describe "StackLimitFollowsTheEvaluatingThread" do
    RUNAWAY = 'function f(n){ return 1 + f(n + 1); } f(0)'

    # A thread that never finishes would hang the suite rather than fail it,
    # and the failure mode being fixed here is exactly one that used to hang.
    def value_within(seconds, &block)
      thread = Thread.new(&block)
      flunk("thread did not finish within #{seconds}s") unless thread.join(seconds)
      thread.value
    end

    # JS_NewRuntime latches rt->stack_top from the creating thread and nothing
    # revisits it, so the overflow limit keeps describing a stack the evaluating
    # thread is not on. Which direction trips is down to where the OS put the two
    # stacks, so both are covered: on Linux the default budget is already a wide
    # enough gap, while on macOS the stacks land close enough that it takes a
    # smaller budget to expose the same latch.
    it "evaluates from a thread other than the one that built the VM" do
      vm = Quickjs::VM.new

      _(value_within(10) { vm.eval_code('1 + 1') }).must_equal 2
    end

    it "evaluates a VM built on another thread from the main one" do
      vm = nil
      Thread.new { vm = Quickjs::VM.new(max_stack_size: 256 * 1024) }.join

      _(vm.eval_code('1 + 1')).must_equal 2
    end

    it "hands VMs from warmer threads to worker threads without false overflows" do
      queue = SizedQueue.new(4)
      warmers = 2.times.map { Thread.new { 10.times { queue << Quickjs::VM.new } } }
      results = 2.times.map do
        Thread.new { 10.times.map { queue.pop.eval_code('1 + 1') } }
      end
      warmers.each { |t| flunk("warmer stalled") unless t.join(20) }
      values = results.flat_map { |t| flunk("worker stalled") unless t.join(20); t.value }

      _(values).must_equal Array.new(20, 2)
    end

    # Re-basing the limit must not become a way of removing it.
    it "still stops runaway recursion on the thread that built the VM" do
      vm = Quickjs::VM.new(timeout_msec: 10_000)

      _ { vm.eval_code(RUNAWAY) }.must_raise Quickjs::RuntimeError
    end

    # A Ruby thread's machine stack is a fraction of the main thread's, so a
    # budget re-based onto one without being clamped to it outlives the stack it
    # is measuring: Ruby's guard page is reached first and the process takes a
    # SystemStackError mid-eval, which is why this asserts the error type rather
    # than just that something was raised.
    it "still stops runaway recursion on a thread that did not build the VM" do
      vm = Quickjs::VM.new(timeout_msec: 10_000)

      err = value_within(20) do
        begin
          vm.eval_code(RUNAWAY)
        rescue => e
          e
        end
      end

      _(err).must_be_kind_of Quickjs::RuntimeError
      _(err.message).must_match(/stack overflow/)
    end

# A Fiber runs on its own mmap'd machine stack, outside the bounds pthread
# reports for the thread hosting it, so the headroom query cannot describe
# it and answers 0. Enumerator and every fiber scheduler land here too.
# Re-basing on a stack that cannot then be clamped is the one outcome worse
# than not re-basing at all: the budget would outlive the fiber's much
# smaller stack, and runaway recursion would reach Ruby's guard page and
# take the process down instead of raising. Whatever happens in a fiber has
# to stay inside the exception system.
it "does not run off the end of a Fiber's stack" do
  vm = Quickjs::VM.new(timeout_msec: 10_000)

  raised = Fiber.new do
    begin
      vm.eval_code(RUNAWAY)
      nil
    rescue Exception => e
      e
    end
  end.resume

  _(raised).must_be_kind_of Exception
  _(raised).wont_be_kind_of SystemStackError
end

    # A bridge re-entering its own VM is deeper on the same stack, so it must
    # keep the outermost entry's budget. Handing it a fresh one would remove the
    # guard exactly where runaway recursion needs catching.
    it "does not hand a nested entry a fresh budget" do
      vm = Quickjs::VM.new(timeout_msec: 10_000)
      vm.define_function('again') { vm.eval_code('again()') }

      _ { vm.eval_code('again()') }.must_raise Quickjs::RuntimeError
    end
  end

  describe "DrainJobs" do
    before do
      @vm = Quickjs::VM.new
    end

    it "returns 0 when no jobs are pending" do
      _(@vm.drain_jobs!).must_equal 0
    end

    it "runs a Promise.resolve().then() callback that eval_code leaves pending" do
      @vm.eval_code('globalThis.x = 0; Promise.resolve().then(() => { x = 1 }); void 0')
      _(@vm.eval_code('x')).must_equal 0
      _(@vm.drain_jobs!).must_equal 1
      _(@vm.eval_code('x')).must_equal 1
    end

    it "drains chained then() across multiple ticks" do
      @vm.eval_code(<<~JS)
        globalThis.log = []
        Promise.resolve()
          .then(() => log.push('a'))
          .then(() => log.push('b'))
          .then(() => log.push('c'))
        void 0
      JS
      _(@vm.drain_jobs!).must_equal 3
      _(@vm.eval_code('log.join(",")')).must_equal 'a,b,c'
    end

    it "drains jobs scheduled from within other jobs" do
      @vm.eval_code(<<~JS)
        globalThis.depth = 0
        function schedule(n) {
          if (n === 0) return
          Promise.resolve().then(() => { depth++; schedule(n - 1) })
        }
        schedule(5)
        void 0
      JS
      _(@vm.drain_jobs!).must_equal 5
      _(@vm.eval_code('depth')).must_equal 5
    end

    it "leaves the queue empty after draining" do
      @vm.eval_code('Promise.resolve().then(() => {}); void 0')
      _(@vm.drain_jobs!).must_equal 1
      _(@vm.drain_jobs!).must_equal 0
    end

    it "respects timeout_msec while draining" do
      vm = Quickjs::VM.new(timeout_msec: 100)
      vm.eval_code(<<~JS)
        function loop() { Promise.resolve().then(loop) }
        loop()
        void 0
      JS

      started = Time.now.to_f * 1000
      vm.drain_jobs!
      elapsed = Time.now.to_f * 1000 - started
      assert_operator elapsed, :>=, 50
      assert_operator elapsed, :<, 300
    end

    it "raises Quickjs::RuntimeError after the VM is OOM-poisoned" do
      vm = Quickjs::VM.new(memory_limit: 1024 * 1024)
      _ { vm.eval_code('new Array(2_000_000).fill(0); void 0') }.must_raise Quickjs::RuntimeError
      _ { vm.drain_jobs! }.must_raise Quickjs::RuntimeError
    end
  end

  describe "GlobalFunction" do
    before do
      @vm = Quickjs::VM.new
    end

    [
      {
        subject: "accepts a block with blank args",
        js: "callRuby()",
        defined_function: Proc.new { ['Message', 'from', 'Ruby'].join(' ') },
        result: 'Message from Ruby',
      },
      {
        subject: 'accepts a block with an arg',
        js: "greetingTo('Rick')",
        defined_function: Proc.new { |arg1| ['Hello!', arg1].join(' ') },
        result: 'Hello! Rick',
      },
      {
        subject: 'accepts a block with two args',
        js: "concat('Ri', 'ck')",
        defined_function: Proc.new { |arg1, arg2| "#{arg1}#{arg2}" },
        result: 'Rick',
      },
      {
        subject: 'accepts a block with many args',
        js: "buildCSV('R', 'i', 'c', 'k')",
        defined_function: Proc.new { |arg1, arg2, arg3, arg4| [arg1, arg2, arg3, arg4].join(' ') },
        result: 'R i c k',
      },
      {
        subject: 'accepts a block with many args including an optional one',
        js: "callName('R', 'i', 'c', 'k')",
        defined_function: Proc.new { |arg1, arg2, arg3, arg4, arg5 = 'Song'| [arg1, arg2, arg3, arg4].join('') + " #{arg5}" },
        result: 'Rick Song',
      },
    ].each do |test_case|
      it "define_function #{test_case[:subject]}" do
        @vm.define_function(test_case[:js].scan(/(.+)\(.+$/).first.first, &test_case[:defined_function])
        _(@vm.eval_code(test_case[:js])).must_equal test_case[:result]
      end
    end

    it "function's name can be a symbol" do
      @vm.define_function(:sym) { true }
      assert @vm.eval_code('sym()')
    end

    it "function's name can't be others than a symbol, string, or array" do
      err = _ {
        @vm.define_function(123) { 'never reach' }
      }.must_raise TypeError
      _(err.message).must_equal "function's name should be a Symbol or a String"
    end

    it "returns a symbol" do
      _(@vm.define_function('should_be_sym') { true }).must_equal :should_be_sym
    end

    [
      ["'symsym'", :symsym],
      ["null", nil],
      ["3", 3],
      ["3.14", 3.14],
      ["true", true],
      ["false", false],
    ].each do |js, ruby|
      it "returned #{ruby} by Ruby is #{js} in VM" do
        @vm.define_function("get_ret") { ruby }
        _(@vm.eval_code("get_ret() === #{js}")).must_equal true
      end
    end

    it "returns array as is if serializable" do
      @vm.define_function("get_array") { [1, '2'] }
      _(@vm.eval_code("get_array()")).must_equal [1, '2']
    end

    it "returns array with undefined preserved" do
      @vm.define_function("get_array") { [1, Quickjs::Value::UNDEFINED, '2'] }
      _(@vm.eval_code("get_array()[1] === undefined")).must_equal true
    end

    it "returns hash as is (ish) if serializable" do
      @vm.define_function("get_obj") { { a: 1 } }
      _(@vm.eval_code("get_obj()")).must_equal({ 'a' => 1 })
    end

    it "returns hash with undefined value preserved" do
      @vm.define_function("get_obj") { { a: Quickjs::Value::UNDEFINED, b: 1 } }
      _(@vm.eval_code("get_obj().a === undefined")).must_equal true
      _(@vm.eval_code("get_obj().b")).must_equal 1
    end

    it "returns original exception" do
      @vm.define_function("get_exception") { IOError.new("yo") }

      exception = @vm.eval_code("get_exception()")
      _(exception.class).must_equal IOError
      _(exception.message).must_equal 'yo'
    end

    it "returns inspected string for otherwise" do
      @vm.define_function("get_class") { Class.new }
      _(@vm.eval_code("get_class()")).must_match(/#<Class:/)
    end

    it "global timeout still works" do
      @vm.define_function("infinite") { loop {} }
      _ { @vm.eval_code("infinite();") }.must_raise Quickjs::InterruptedError
    end

    it "multiple functions can be defined" do
      @vm.define_function("first_ruby") { "hi" }
      @vm.define_function("second_ruby") { "yo" }

      _(@vm.eval_code("first_ruby()")).must_equal "hi"
      _(@vm.eval_code("second_ruby()")).must_equal "yo"
    end

    it "same name function is overwritten" do
      @vm.define_function("first_ruby") { "hi" }
      @vm.define_function("first_ruby") { "yo" }

      _(@vm.eval_code("first_ruby()")).must_equal "yo"
    end

    it ":async keyword lets global function be defined as async" do
      @vm.define_function "unblocked", :async do
        'asynchronous return'
      end
      _(@vm.eval_code("const awaited = await unblocked().then((result) => result + '!'); awaited;")).must_equal 'asynchronous return!'
    end

    it ":async function can throw" do
      @vm.define_function "unblocked", :async do
        raise 'asynchronous sadness'
      end

      _(@vm.eval_code("const awaited = await unblocked().catch((result) => result + '!'); awaited;")).must_equal 'Error: asynchronous sadness!'
    end

    it "throws an internal error which will be converted to Quickjs::RubyFunctionError in JS world when Ruby function raises" do
      @vm.define_function("errorable") { raise IOError, 'sad error happened within Ruby' }

      err = _ { @vm.eval_code("errorable();") }.must_raise IOError
      _(err.message).must_equal 'sad error happened within Ruby'
    end

    it "implemented as native code" do
      @vm.define_function("a_ruby") { "hi" }
      _(@vm.eval_code('a_ruby.toString()')).must_match(/native code/)
    end

    it "receives a long string argument (QuickJS rope) correctly" do
      received = nil
      @vm.define_function("capture") { |arg| received = arg }
      @vm.eval_code(<<~JS)
        const long = "x".repeat(10000);
        capture(`Hey ${long}`);
      JS
      _(received).must_equal "Hey #{'x' * 10000}"
    end

    describe "nested via array path" do
      it "defines a function on an existing object" do
        @vm.eval_code("const myLib = {}")
        @vm.define_function(["myLib", "hello"]) { |name| "Hello, #{name}!" }
        _(@vm.eval_code("myLib.hello('world')")).must_equal "Hello, world!"
      end

      it "defines a function on a deeply nested object" do
        @vm.eval_code("const a = { b: { c: {} } }")
        @vm.define_function(["a", "b", "c", "fn"]) { |x| x * 2 }
        _(@vm.eval_code("a.b.c.fn(21)")).must_equal 42
      end

      it "returns an array of symbols" do
        @vm.eval_code("const ns = {}")
        result = @vm.define_function(["ns", "fn"]) { true }
        _(result).must_equal [:ns, :fn]
      end

      it "accepts symbols as path elements" do
        @vm.eval_code("const obj = {}")
        @vm.define_function([:obj, :greet]) { "hi" }
        _(@vm.eval_code("obj.greet()")).must_equal "hi"
      end

      it "works with :async flag" do
        @vm.eval_code("const lib = {}")
        @vm.define_function(["lib", "fetch"], :async) { "data" }
        _(@vm.eval_code("await lib.fetch().then(r => r + '!')")).must_equal "data!"
      end

      it "raises ArgumentError when parent does not exist" do
        err = _ { @vm.define_function(["nonexistent", "fn"]) { } }.must_raise ArgumentError
        _(err.message).must_include "nonexistent"
      end

      it "raises ArgumentError when intermediate segment is not an object" do
        @vm.eval_code("const x = { y: 42 }")
        err = _ { @vm.define_function(["x", "y", "fn"]) { } }.must_raise ArgumentError
        _(err.message).must_include "y"
      end

      it "single-element array registers on the global object" do
        @vm.define_function(["lone"]) { 42 }
        _(@vm.eval_code("lone()")).must_equal 42
      end

      it "single-element array returns a one-element array of symbols" do
        result = @vm.define_function(["lone"]) { }
        _(result).must_equal [:lone]
      end

      it "raises ArgumentError for an empty array" do
        err = _ { @vm.define_function([]) { } }.must_raise ArgumentError
        _(err.message).must_include "empty"
      end

      it "raises TypeError when an array element is not a String or Symbol" do
        err = _ { @vm.define_function(["obj", 123]) { } }.must_raise TypeError
        _(err.message).must_include "Symbol or a String"
      end

      # Resolving a path is not a lookup: the first segment goes through
      # JS_Eval and the rest through JS_GetPropertyStr, so an accessor
      # property runs user JS that can call back into Ruby. Until
      # define_function elevated evals_in_flight for its whole body, dispose!
      # did not refuse from inside that callback, and the traversal carried on
      # against a freed JSContext — a SIGSEGV rather than an exception, so a
      # regression takes the whole suite down with it.
      it "refuses dispose! from a bridge reached while resolving the path" do
        outcome = nil
        @vm.eval_code(<<~JS)
          globalThis._lib = {};
          Object.defineProperty(globalThis, 'myLib', { get: () => { probe(); return _lib; } });
          0
        JS
        @vm.define_function('probe') {
          outcome = begin
            @vm.dispose!
            :disposed
          rescue ThreadError => e
            e
          end
          nil
        }

        _(@vm.define_function(["myLib", "hello"]) { 42 }).must_equal [:myLib, :hello]
        _(outcome).must_be_kind_of ThreadError
        _(@vm.eval_code("_lib.hello()")).must_equal 42
      end
    end
  end

  describe "Call" do
    before do
      @vm = Quickjs::VM.new
    end

    it "calls a global function with no args" do
      @vm.eval_code("function greet() { return 'hello'; }")
      _(@vm.call('greet')).must_equal 'hello'
    end

    it "accepts a Symbol as function name" do
      @vm.eval_code("function greet() { return 'hello'; }")
      _(@vm.call(:greet)).must_equal 'hello'
    end

    it "passes primitive args" do
      @vm.eval_code("function add(a, b) { return a + b; }")
      _(@vm.call('add', 1, 2)).must_equal 3
    end

    it "passes hash as object" do
      @vm.eval_code("function getName(obj) { return obj.name; }")
      _(@vm.call('getName', { name: 'Alice' })).must_equal 'Alice'
    end

    it "passes array arg" do
      @vm.eval_code("function sum(arr) { return arr.reduce((a, b) => a + b, 0); }")
      _(@vm.call('sum', [1, 2, 3])).must_equal 6
    end

    it "passes mixed args" do
      @vm.eval_code("function format(tmpl, data) { return tmpl.replace('{name}', data.name); }")
      _(@vm.call('format', 'Hello, {name}!', { name: 'Bob' })).must_equal 'Hello, Bob!'
    end

    it "passes nil as null" do
      @vm.eval_code("function isNull(v) { return v === null; }")
      _(@vm.call('isNull', nil)).must_equal true
    end

    it "automatically awaits async functions" do
      @vm.eval_code("async function asyncGreet() { return 'async hello'; }")
      _(@vm.call('asyncGreet')).must_equal 'async hello'
    end

    it "raises ReferenceError when the name is not defined" do
      _ { @vm.call('nonExistent') }.must_raise Quickjs::ReferenceError
    end

    it "raises RuntimeError when the path resolves to a non-function" do
      err = _ { @vm.call('console') }.must_raise Quickjs::RuntimeError
      _(err.message).must_equal 'given path is not a function'
    end

    it "raises TypeError when function name is not a String or Symbol" do
      _ { @vm.call(42) }.must_raise TypeError
    end

    it "raises an error raised within the function" do
      @vm.eval_code("function boom() { throw new TypeError('bang'); }")
      err = _ { @vm.call('boom') }.must_raise Quickjs::TypeError
      _(err.message).must_equal 'bang'
    end

    it "calls a nested function via dot-notation string" do
      @vm.eval_code("const obj = { greet: function(name) { return 'hello ' + name; } };")
      _(@vm.call('obj.greet', 'Alice')).must_equal 'hello Alice'
    end

    it "preserves this binding with dot-notation string" do
      @vm.eval_code("const counter = { count: 0, increment: function() { this.count++; return this.count; } };")
      _(@vm.call('counter.increment')).must_equal 1
      _(@vm.call('counter.increment')).must_equal 2
    end

    it "supports deeply nested dot-notation string" do
      @vm.eval_code("const a = { b: { c: function() { return 42; } } };")
      _(@vm.call('a.b.c')).must_equal 42
    end

    it "calls a nested function via bracket-notation string" do
      @vm.eval_code("const obj = { greet: function(name) { return 'hello ' + name; } };")
      _(@vm.call('obj["greet"]', 'Alice')).must_equal 'hello Alice'
    end

    it "supports bracket notation for keys with special characters" do
      @vm.eval_code("const obj = {}; obj['my-func'] = function(x) { return x * 2; };")
      _(@vm.call('obj["my-func"]', 21)).must_equal 42
    end

    it "supports bracket notation for emoji keys" do
      @vm.eval_code("const obj = {}; obj['🎉'] = function(x) { return x + '!'; };")
      _(@vm.call('obj["🎉"]', 'party')).must_equal 'party!'
    end

    it "supports mixed dot and bracket notation" do
      @vm.eval_code("const a = { b: {} }; a.b['c-d'] = function() { return 'mixed'; };")
      _(@vm.call('a.b["c-d"]')).must_equal 'mixed'
    end

  end

  describe "Function" do
    before do
      @vm = Quickjs::VM.new
    end

    it "JS function passed to Ruby becomes a Quickjs::Function" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture((a, b) => a + b)")
      _(received).must_be_instance_of Quickjs::Function
    end

    it "exposes the JS source via source" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture((a, b) => a + b)")
      _(received.source).must_equal "(a, b) => a + b"
    end

    it "call with no args runs on a fresh VM" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture(() => 42)")
      _(received.call).must_equal 42
    end

    it "call passes args to the function" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture((a, b) => a + b)")
      _(received.call(3, 4)).must_equal 7
    end

    it "call with on: vm runs on the given VM" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture((x) => x * 2)")
      other_vm = Quickjs::VM.new
      _(received.call(5, on: other_vm)).must_equal 10
    end

    it "call with on: Hash passes VM options" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture(() => !!std)")
      _(received.call(on: { features: [Quickjs::MODULE_STD] })).must_equal true
    end

    it "is independent of the original VM" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture((x) => x + 1)")
      @vm = nil
      _(received.call(10)).must_equal 11
    end

    it "named function is callable" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture(function add(a, b) { return a + b; })")
      _(received.call(2, 3)).must_equal 5
    end

    it "passes complex args" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture((obj) => obj.x + obj.y)")
      _(received.call({ x: 1, y: 2 })).must_equal 3
    end

    it "raises ArgumentError for invalid on: argument" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture(() => 1)")
      _ { received.call(on: "bad") }.must_raise ArgumentError
    end

    it "call with no on: disposes the temporary VM after execution" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture(() => 42)")
      _(received.call).must_equal 42
    end

    it "call with on: vm does not dispose the external VM" do
      received = nil
      @vm.define_function("capture") { |fn| received = fn }
      @vm.eval_code("capture(() => 1)")
      other_vm = Quickjs::VM.new
      received.call(on: other_vm)
      _(other_vm.disposed?).must_equal false
      other_vm.dispose!
    end
  end

  describe "Import" do
    before do
      @vm = Quickjs::VM.new
    end

    it "imports named exports from given ESM code as is" do
      @vm.import(['defaultMember', 'member'], from: File.read('./test/fixture.esm.js'))

      _(@vm.eval_code("defaultMember()")).must_equal "I am a default export of ESM."
      _(@vm.eval_code("member()")).must_equal "I am a exported member of ESM."
    end

    it "imports named exports from given ESM code with alias" do
      @vm.import({ default: 'aliasedDefault', member: 'aliasedMember' }, from: File.read('./test/fixture.esm.js'))

      _(@vm.eval_code("aliasedDefault()")).must_equal "I am a default export of ESM."
      _(@vm.eval_code("aliasedMember()")).must_equal "I am a exported member of ESM."
    end

    it "imports all exports from given ESM code into a single alias" do
      @vm.import('* as all', from: File.read('./test/fixture.esm.js'))

      _(@vm.eval_code("all.default()")).must_equal "I am a default export of ESM."
      _(@vm.eval_code("all.defaultMember()")).must_equal "I am a default export of ESM."
      _(@vm.eval_code("all.member()")).must_equal "I am a exported member of ESM."
    end

    it "imports with implicit default from given ESM code" do
      @vm.import('Imported', from: File.read('./test/fixture.esm.js'))

      _(@vm.eval_code("Imported()")).must_equal "I am a default export of ESM."
    end

    it "code_to_expose can differentiate the way to globalize" do
      @vm.import('Imported', from: File.read('./test/fixture.esm.js'), code_to_expose: 'globalThis.RenamedImported = Imported;')

      _(@vm.eval_code('RenamedImported()')).must_equal 'I am a default export of ESM.'
      _(@vm.eval_code('!!globalThis.Imported')).must_equal false
    end

    it "code_to_expose with an empty string runs the module for side effects only" do
      @vm.import('Imported', from: 'globalThis.sideEffect = true; export default 1;', code_to_expose: '')

      _(@vm.eval_code('globalThis.sideEffect')).must_equal true
      _(@vm.eval_code('!!globalThis.Imported')).must_equal false
    end

    it "code_to_expose also works with filename:" do
      @vm.module_loader = ->(name) { 'export const greet = () => "hi";' if name == 'greet' }
      @vm.import(['greet'], filename: 'greet', code_to_expose: 'globalThis.shout = () => greet().toUpperCase();')

      _(@vm.eval_code('shout()')).must_equal 'HI'
      _(@vm.eval_code('typeof globalThis.greet')).must_equal 'undefined'
    end

    it "imports a script which throws error result raising an exception" do
      _ {
        @vm.import('* as all', from: 'should be syntax error')
      }.must_raise Quickjs::SyntaxError
    end

    it "resolves via module_loader when filename: is given instead of from:" do
      @vm.module_loader = ->(name) { 'export const greet = (who) => `Hello, ${who}!`;' if name == 'greet' }
      @vm.import(['greet'], filename: 'greet')

      _(@vm.eval_code("greet('world')")).must_equal 'Hello, world!'
    end

    it "raises when a module body throws synchronously" do
      err = _ {
        @vm.import('* as x', from: "throw new TypeError('top-level boom');")
      }.must_raise Quickjs::TypeError
      _(err.message).must_match(/top-level boom/)
    end

    it "applies timeout_msec to module top-level code" do
      vm = Quickjs::VM.new(timeout_msec: 50)

      _ {
        vm.import('* as x', from: 'while (true) {}; export const x = 1;')
      }.must_raise Quickjs::InterruptedError
    ensure
      vm&.dispose!
    end

    it "raises when the loader-resolved module throws synchronously" do
      @vm.module_loader = ->(name) {
        "export const x = 1; throw new RangeError('loader-throw');" if name == 'bad'
      }
      _ {
        @vm.import(['x'], filename: 'bad')
      }.must_raise Quickjs::RangeError
    end

    it "raises when top-level await rejects" do
      err = _ {
        @vm.import('* as x', from: "await Promise.reject(new Error('async boom'));")
      }.must_raise Quickjs::RuntimeError
      _(err.message).must_match(/async boom/)
    end

    it "raises ArgumentError when both from: and filename: are passed" do
      _ {
        @vm.import('x', from: 'export default 1;', filename: 'x')
      }.must_raise ArgumentError
    end
  end

  describe "on_unhandled_rejection" do
    before do
      @vm = Quickjs::VM.new
    end

    it "fires the block with a Ruby exception for a fire-and-forget rejection" do
      captured = []
      @vm.on_unhandled_rejection { |err| captured << err }
      @vm.eval_code("void Promise.reject(new TypeError('drift'));")

      _(captured.size).must_equal 1
      _(captured.first).must_be_kind_of Quickjs::TypeError
      _(captured.first.message).must_match(/drift/)
    end

    it "wraps non-Error rejection reasons in Quickjs::RuntimeError" do
      captured = []
      @vm.on_unhandled_rejection { |err| captured << err }
      @vm.eval_code("void Promise.reject('just-a-string');")

      _(captured.first).must_be_kind_of Quickjs::RuntimeError
      _(captured.first.message).must_match(/just-a-string/)
    end

    it "exposes the JS Error.stack as the captured exception's backtrace" do
      captured = []
      @vm.on_unhandled_rejection { |err| captured << err }
      @vm.eval_code(<<~JS, filename: 'rej.js')
        function detonate() { throw new TypeError('rejection-stack-test'); }
        function trigger() {
          try { detonate(); } catch (e) { void Promise.reject(e); }
        }
        trigger();
      JS

      _(captured.first.backtrace).wont_be_nil
      joined = captured.first.backtrace.join("\n")
      _(joined).must_match(/detonate.*rej\.js/)
      _(joined).must_match(/trigger.*rej\.js/)
    end

    it "replaces the previously registered block on a second call" do
      first = []
      second = []
      @vm.on_unhandled_rejection { |err| first << err }
      @vm.on_unhandled_rejection { |err| second << err }
      @vm.eval_code("void Promise.reject(new Error('boom'));")

      _(first).must_be_empty
      _(second.size).must_equal 1
    end

    it "raises LocalJumpError when called without a block" do
      _ { @vm.on_unhandled_rejection }.must_raise LocalJumpError
    end

    it "swallows exceptions raised inside the block" do
      called = false
      @vm.on_unhandled_rejection { |_| called = true; raise 'callback boom' }
      @vm.eval_code("void Promise.reject(new Error('x'));")

      _(called).must_equal true
      _(@vm.eval_code('42')).must_equal 42
    end
  end

  describe "ModuleLoader" do
    before do
      @vm = Quickjs::VM.new
    end

    it "is nil by default" do
      _(@vm.module_loader).must_be_nil
    end

    it "resolves bare specifiers via a Ruby callback" do
      @vm.module_loader = ->(name) {
        'export const greet = (who) => `Hello, ${who}!`;' if name == 'greet'
      }
      @vm.import(['greet'], from: "import { greet } from 'greet'; export { greet };")

      _(@vm.eval_code("greet('world')")).must_equal 'Hello, world!'
    end

    it "resolves transitive imports across multiple in-memory modules" do
      modules = {
        'a' => "import { b } from 'b'; export const a = () => `a-${b()}`;",
        'b' => "export const b = () => 'b-result';"
      }
      @vm.module_loader = ->(name) { modules[name] }
      @vm.import(['a'], from: "import { a } from 'a'; export { a };")

      _(@vm.eval_code('a()')).must_equal 'a-b-result'
    end

    it "raises ReferenceError when the loader returns nil" do
      @vm.module_loader = ->(_) { nil }
      _ {
        @vm.import('Helper', from: "import x from 'missing'; export default x;")
      }.must_raise Quickjs::ReferenceError
    end

    it "raises TypeError when the loader returns a non-string" do
      @vm.module_loader = ->(_) { 42 }
      _ {
        @vm.import('Helper', from: "import x from 'mod'; export default x;")
      }.must_raise Quickjs::TypeError
    end

    it "propagates Ruby exceptions raised inside the loader" do
      @vm.module_loader = ->(_) { raise 'boom from loader' }
      err = _ {
        @vm.import('Helper', from: "import x from 'mod'; export default x;")
      }.must_raise RuntimeError
      _(err.message).must_match(/boom from loader/)
    end

    it "accepts nil to clear a previously set loader" do
      @vm.module_loader = ->(_) { 'export default 1;' }
      @vm.module_loader = nil
      _(@vm.module_loader).must_be_nil
    end

    it "rejects non-Proc, non-nil values" do
      _ { @vm.module_loader = 'not a proc' }.must_raise TypeError
    end

    # The bridge module imports the generated filename after looking it up in
    # the resolution cache. A filename that went stale before the bridge source
    # was built reads as garbage, misses the cache, and falls through here, so
    # an empty `asked` is what pins the generated name staying valid.
    it "never asks the loader for the bridge filename it generated" do
      asked = []
      @vm.module_loader = ->(specifier, _importer) { asked << specifier; nil }
      @vm.import('Imported', from: File.read('./test/fixture.esm.js'))

      _(@vm.eval_code("Imported()")).must_equal "I am a default export of ESM."
      _(asked).must_be_empty
    end

    # A filename: that is not already a String is coerced by StringValueCStr,
    # and the coerced String is referenced by nothing the caller can see: the
    # kwargs hash still holds the original object. Pins that the borrowed
    # pointer survives Quickjs._build_import running arbitrary Ruby.
    it "accepts a to_str filename and still resolves it through the loader" do
      coercible = Object.new
      def coercible.to_str = 'mod.js'.dup

      @vm.module_loader = ->(specifier, _importer) {
        "export default () => 'from loader';" if specifier == 'mod.js'
      }
      @vm.import('Imported', filename: coercible)

      _(@vm.eval_code('Imported()')).must_equal 'from loader'
    end

    it "passes the from: bridge filename as importer to a 2-arity loader" do
      seen_importer = nil
      @vm.module_loader = ->(specifier, importer) {
        seen_importer = importer
        'export const x = 42;' if specifier == 'dep'
      }
      @vm.import(['x'], from: "import { x } from 'dep'; export { x };")
      _(@vm.eval_code('x')).must_equal 42
      _(seen_importer).must_be_kind_of String
      _(seen_importer).wont_equal 'dep'
    end

    it "passes the importer as a second arg to a 2-arity loader" do
      seen = []
      @vm.module_loader = ->(specifier, importer) {
        seen << [specifier, importer]
        case specifier
        when 'a' then "import { b } from 'b'; export const a = () => b();"
        when 'b' then "export const b = () => 'b-result';"
        end
      }
      @vm.import(['a'], filename: 'a')

      _(seen).must_include ['b', 'a']
    end

    it "supports importmap-style scopes via the Hash return form" do
      modules = {
        '/vendor/lodash.js'       => 'export default { v: "global" };',
        '/vendor/lodash-admin.js' => 'export default { v: "admin"  };',
        '/app/admin/main.js'      => "import _ from 'lodash'; export const tag = _.v;",
        '/app/main.js'            => "import _ from 'lodash'; export const tag = _.v;"
      }
      @vm.module_loader = ->(specifier, importer) {
        case specifier
        when 'lodash'
          target = importer.start_with?('/app/admin/') ? '/vendor/lodash-admin.js' : '/vendor/lodash.js'
          {code: modules[target], as: target}
        else
          modules[specifier]
        end
      }
      @vm.import(['tag'], filename: '/app/admin/main.js')
      _(@vm.eval_code('tag')).must_equal 'admin'

      vm2 = Quickjs::VM.new
      vm2.module_loader = @vm.module_loader
      vm2.import(['tag'], filename: '/app/main.js')
      _(vm2.eval_code('tag')).must_equal 'global'
    end

    it "memoizes resolution per (specifier, importer) so the loader fires once" do
      call_count = 0
      @vm.module_loader = ->(specifier, _importer) {
        call_count += 1
        'export const x = 1;' if specifier == 'mod'
      }
      @vm.eval_code(<<~JS, async: true)
        await import('mod');
        await import('mod');
        await import('mod');
      JS

      _(call_count).must_equal 1
    end

    # A Hash without code: is a redirect, so it can only point at a module that
    # is already loaded. Pointing at one that isn't leaves nothing to load.
    it "raises ReferenceError when a redirect points at a module that isn't loaded" do
      @vm.module_loader = ->(_specifier, _importer) { {as: '/anywhere'} }
      err = _ {
        @vm.import(['x'], from: "import { x } from 'mod'; export { x };")
      }.must_raise Quickjs::ReferenceError

      _(err.message).must_match(%r{/anywhere})
      _(err.message).must_match(/without code:/)
    end

    it "raises TypeError when the loader Hash has a non-String code:" do
      @vm.module_loader = ->(_specifier, _importer) { {code: 42, as: '/anywhere'} }
      _ {
        @vm.import(['x'], from: "import { x } from 'mod'; export { x };")
      }.must_raise Quickjs::TypeError
    end

    it "redirects a specifier onto a module the loader already provided" do
      loaded = []
      @vm.module_loader = ->(specifier, _importer) {
        loaded << specifier
        case specifier
        when '/real.js' then {code: "const s = { n: 0 };\nexport const bump = () => ++s.n;", as: '/real.js'}
        when 'alias' then {as: '/real.js'}
        end
      }

      @vm.import(['bump'], from: "import { bump } from '/real.js'; export { bump };")
      @vm.import({bump: 'aliasBump'}, from: "import { bump } from 'alias'; export { bump };")

      # Same module instance behind both specifiers, so the counter is shared.
      _(@vm.eval_code('bump()')).must_equal 1
      _(@vm.eval_code('aliasBump()')).must_equal 2
      _(loaded).must_equal ['/real.js', 'alias']
    end

    it "redirects a specifier onto a preloaded module" do
      Quickjs.register_module('_test_redirect_target', source: 'export const hi = () => "preloaded";')
      vm = Quickjs::VM.new(preload_modules: ['_test_redirect_target'])
      vm.module_loader = ->(specifier, _importer) {
        {as: '_test_redirect_target'} if specifier == 'friendly-name'
      }

      vm.import(['hi'], filename: 'friendly-name')

      _(vm.eval_code('hi()')).must_equal 'preloaded'
      _(vm.send(:_pending_module_source_count)).must_equal 0
    ensure
      Quickjs._unregister_module('_test_redirect_target')
    end

    it "raises TypeError when the loader Hash is missing as:" do
      @vm.module_loader = ->(_specifier, _importer) { {code: 'export const x = 1;'} }
      _ {
        @vm.import(['x'], from: "import { x } from 'mod'; export { x };")
      }.must_raise Quickjs::TypeError
    end

    it "raises TypeError when the loader returns an unexpected type" do
      @vm.module_loader = ->(_specifier, _importer) { 42 }
      _ {
        @vm.import(['x'], from: "import { x } from 'mod'; export { x };")
      }.must_raise Quickjs::TypeError
    end

    it "fires the loader again when the same specifier comes from a different importer" do
      call_count = 0
      @vm.module_loader = ->(specifier, _importer) {
        call_count += 1
        case specifier
        when 'app1' then "import 'dep'; export const x = 1;"
        when 'app2' then "import 'dep'; export const x = 2;"
        when 'dep'  then 'export const d = 1;'
        end
      }
      @vm.import(['x'], filename: 'app1')
      @vm.import(['x'], filename: 'app2')

      # 'app1', 'app2' once each; 'dep' resolved from each — distinct importer pairs.
      _(call_count).must_equal 4
    end
  end

  describe "Quickjs.compile" do
    it "returns a Quickjs::Runnable" do
      _(::Quickjs.compile('1 + 1')).must_be_instance_of Quickjs::Runnable
    end

    it "the Runnable runs correctly" do
      _(::Quickjs.compile('40 + 2').run).must_equal 42
    end

    it "supports filename: option" do
      _ { ::Quickjs.compile('}{', filename: 'app.js') }.must_raise Quickjs::SyntaxError
    end
  end

  describe "Runnable" do
    before do
      @vm = Quickjs::VM.new
    end

    it "vm.compile returns a Quickjs::Runnable" do
      _(@vm.compile('1 + 1')).must_be_instance_of Quickjs::Runnable
    end

    it "to_s returns a frozen ASCII-8BIT bytecode String" do
      bytecode = @vm.compile('1 + 1').to_s
      _(bytecode).must_be_instance_of String
      _(bytecode.encoding).must_equal Encoding::ASCII_8BIT
      _(bytecode.frozen?).must_equal true
      _(bytecode.bytesize).must_be :>, 0
    end

    it "run(on: vm) executes on the given VM" do
      _(@vm.compile('1 + 2').run(on: @vm)).must_equal 3
      _(@vm.compile('"hi"').run(on: @vm)).must_equal 'hi'
    end

    it "run(on: vm) preserves side effects on the given VM" do
      @vm.compile('globalThis.greeting = "hello";').run(on: @vm)
      _(@vm.eval_code('globalThis.greeting')).must_equal 'hello'
    end

    it "run with no on: creates a fresh VM and executes" do
      _(@vm.compile('40 + 2').run).must_equal 42
    end

    it "run(on: hash) creates a fresh VM with the given options" do
      runnable = @vm.compile('typeof std')
      _(runnable.run).must_equal 'undefined'
      _(runnable.run(on: { features: [::Quickjs::MODULE_STD] })).must_equal 'object'
    end

    it "supports top-level await in compiled code" do
      runnable = @vm.compile(<<~JS)
        const p = new Promise((res) => { res('awaited'); });
        await p;
      JS
      _(runnable.run(on: @vm)).must_equal 'awaited'
    end

    it "carries filename: through to JS stack traces" do
      runnable = @vm.compile(<<~JS, filename: '/path/to/bundle.js')
        try { throw new Error('boom') } catch (e) { e.stack }
      JS
      _(runnable.run(on: @vm)).must_match(%r{/path/to/bundle\.js})
    end

    it "Quickjs::Runnable.new(bytecode) round-trips through to_s" do
      bytecode = @vm.compile('123 + 456').to_s
      restored = Quickjs::Runnable.new(bytecode)
      _(restored.run).must_equal 579
    end

    it "compile raises Quickjs::SyntaxError on syntactically invalid source" do
      _ { @vm.compile('}{') }.must_raise Quickjs::SyntaxError
    end

    it "compile raises TypeError when source isn't a String" do
      _ { @vm.compile(nil) }.must_raise TypeError
      _ { @vm.compile(123) }.must_raise TypeError
    end

    it "Quickjs::Runnable.new accepts any String — validation is lazy" do
      runnable = Quickjs::Runnable.new("not a real bytecode blob")
      _ { runnable.run }.must_raise Quickjs::RuntimeError
    end

    it "run(on: invalid) raises ArgumentError" do
      runnable = @vm.compile('1')
      _ { runnable.run(on: 42) }.must_raise ArgumentError
      _ { runnable.run(on: 'vm') }.must_raise ArgumentError
    end

    it "run(on: vm) honors timeout_msec" do
      runnable = @vm.compile('while (true) {}')
      vm = Quickjs::VM.new(timeout_msec: 50)
      _ { runnable.run(on: vm) }.must_raise Quickjs::InterruptedError
    end

    it "run(on: vm) raises Quickjs::RuntimeError after the VM is OOM-poisoned" do
      runnable = @vm.compile('1 + 1')
      vm = Quickjs::VM.new(memory_limit: 1024 * 1024)
      _ { vm.eval_code('new Array(2_000_000).fill(0); void 0') }.must_raise Quickjs::RuntimeError

      err = _ { runnable.run(on: vm) }.must_raise Quickjs::RuntimeError
      _(err.message).must_match(/poisoned/)
    end

    # Compiling is the entry point that most needs the guard: the state OOM
    # leaves behind is precisely what another throw on the parser-error path
    # can turn into a segfault.
    it "compile raises Quickjs::RuntimeError after the VM is OOM-poisoned" do
      vm = Quickjs::VM.new(memory_limit: 1024 * 1024)
      _ { vm.eval_code('new Array(2_000_000).fill(0); void 0') }.must_raise Quickjs::RuntimeError

      err = _ { vm.compile('1 + 1') }.must_raise Quickjs::RuntimeError
      _(err.message).must_match(/poisoned/)
    end

    # Converting a thrown value reads name, message and stack off the error
    # object, and any of the three can be an accessor inherited from a
    # prototype the VM's own JS has replaced. So a parse failure runs a bridge
    # during conversion — and with the parse's counter already released,
    # dispose! from that bridge was granted and the rest of the conversion ran
    # against a freed context. SIGSEGV rather than an exception, so a
    # regression takes the suite down with it.
    it "refuses dispose! from a bridge reached while converting a compile error" do
      vm = Quickjs::VM.new
      outcome = nil
      vm.define_function('probe') {
        outcome = begin
          vm.dispose!
          :disposed
        rescue ThreadError => e
          e
        end
        'Poisoned'
      }
      vm.eval_code(<<~JS)
        Object.defineProperty(SyntaxError.prototype, 'name', { configurable: true, get: () => probe() });
        0
      JS

      _ { vm.compile('function (') }.must_raise Quickjs::RuntimeError
      _(outcome).must_be_kind_of ThreadError
      _(vm.disposed?).must_equal false
    ensure
      vm.dispose!
    end

    it "run with no on: disposes the temporary VM after execution" do
      runnable = @vm.compile('40 + 2')
      _(runnable.run).must_equal 42
    end

    it "run(on: vm) does not dispose the external VM" do
      runnable = @vm.compile('1 + 1')
      other_vm = Quickjs::VM.new
      runnable.run(on: other_vm)
      _(other_vm.disposed?).must_equal false
      other_vm.dispose!
    end

    # A define_function bridge disqualifies can_eval_gvl_free, so this run
    # takes the GVL-held branch — bridge callbacks call Ruby APIs and must
    # hold the GVL. Locks the branch split in vm_m_evalBytecode.
    it "run(on: vm) reaches Ruby-bridged functions on the GVL-held path" do
      vm = Quickjs::VM.new
      vm.define_function('fromRuby') { 'bridged' }
      runnable = vm.compile('fromRuby()')

      _(runnable.run(on: vm)).must_equal 'bridged'
    ensure
      vm&.dispose!
    end

    # A bare VM takes the GVL-released branch; console.log inside the run
    # reaches js_quickjsrb_log off-GVL, which must re-acquire before
    # invoking the on_log block — same re-acquire path eval_code exercises.
    it "delivers console.log to on_log during a GVL-released run" do
      runnable = @vm.compile('console.log("from bytecode"); 1 + 1')
      vm       = Quickjs::VM.new
      received = []
      vm.on_log { |log| received << log }

      _(runnable.run(on: vm)).must_equal 2
      _(received.map(&:to_s)).must_equal ['from bytecode']
    ensure
      vm&.dispose!
    end
  end

  describe "ConsoleLoggers" do
    before do
      @vm = Quickjs::VM.new
      @received = []
      @vm.on_log { |log| @received << log }
    end

    it "there are functions for some severities" do
      @vm.eval_code('console.log("log it")')
      _(@received.last.severity).must_equal :info
      _(@received.last.to_s).must_equal 'log it'

      @vm.eval_code('console.info("info it")')
      _(@received.last.severity).must_equal :info
      _(@received.last.to_s).must_equal 'info it'

      @vm.eval_code('console.debug("debug it")')
      _(@received.last.severity).must_equal :verbose
      _(@received.last.to_s).must_equal 'debug it'

      @vm.eval_code('console.warn("warn it")')
      _(@received.last.severity).must_equal :warning
      _(@received.last.to_s).must_equal 'warn it'

      @vm.eval_code('console.error("error it")')
      _(@received.last.severity).must_equal :error
      _(@received.last.to_s).must_equal 'error it'

      _(@received.size).must_equal 5
    end

    it "can give multiple arguments" do
      @vm.eval_code('const variable = "var!";')
      @vm.eval_code('console.log(128, "str", variable, undefined, null, { key: "value" }, [1, 2, 3], new Error("hey"))')

      _(@received.last.to_s).must_equal [
        "128", "str", "var!", "undefined", "null", "[object Object]", "1,2,3", "Error: hey"
      ].join(' ')
    end

    it "can give converted given data as 'raw'" do
      @vm.eval_code('const variable = "var!";')
      @vm.eval_code('console.log(128, "str", variable, undefined, null, { key: "value" }, [1, 2, 3], new Error("hey"))')

      _(@received.last.raw).must_equal [
        128, "str", "var!", Quickjs::Value::UNDEFINED, nil, { "key" => "value" }, [1,2,3], "Error: hey\n    at <eval> (<code>:1:90)\n"
      ]
    end

    it "can log Promise object as just a string" do
      @vm.eval_code('async function hi() {}')
      @vm.eval_code('console.log("log promise", hi())')

      _(@received.last.to_s).must_equal ['log promise', '[object Promise]'].join(' ')
      _(@received.last.raw).must_equal ['log promise', 'Promise']
    end

    it "can log exception instance from Ruby like JS Error" do
      @vm.define_function("get_exception") { raise IOError.new("io") }
      @vm.eval_code('try { get_exception() } catch (e) { console.log(e) }')

      _(@received.last.to_s).must_equal 'Error: io'
      _(@received.last.raw).must_equal ["Error: io\n    at <eval> (<code>:1:20)\n"]
    end

    it "implemented as native code" do
      _(@vm.eval_code('console.log.toString()')).must_match(/native code/)
    end
  end

  describe "OnLog" do
    before do
      @vm = Quickjs::VM.new
    end

    it "receives log entries via listener for each severity" do
      received = []
      @vm.on_log { |log| received << log }

      @vm.eval_code('console.log("log it")')
      @vm.eval_code('console.info("info it")')
      @vm.eval_code('console.debug("debug it")')
      @vm.eval_code('console.warn("warn it")')
      @vm.eval_code('console.error("error it")')

      _(received.size).must_equal 5
      _(received[0].severity).must_equal :info
      _(received[0].to_s).must_equal 'log it'
      _(received[1].severity).must_equal :info
      _(received[2].severity).must_equal :verbose
      _(received[3].severity).must_equal :warning
      _(received[4].severity).must_equal :error
    end

    it "receives log with multiple arguments" do
      received = []
      @vm.on_log { |log| received << log }

      @vm.eval_code('console.log("hello", 42, "world")')

      _(received.size).must_equal 1
      _(received.first.to_s).must_equal 'hello 42 world'
      _(received.first.raw).must_equal ['hello', 42, 'world']
    end

    it "raw value of a long logged string (QuickJS rope) is correct" do
      received = []
      @vm.on_log { |log| received << log }

      @vm.eval_code(<<~JS)
        const long = "x".repeat(10000);
        console.log(`Hey ${long}`);
      JS

      _(received.first.raw).must_equal ["Hey #{'x' * 10000}"]
    end

    it "receives error logs from unhandled exceptions" do
      received = []
      @vm.on_log { |log| received << log }

      _ {
        @vm.eval_code('a + b;')
      }.must_raise Quickjs::ReferenceError

      _(received.size).must_equal 1
      _(received.first.severity).must_equal :error
    end

    it "receives error logs from non-Error exceptions" do
      received = []
      @vm.on_log { |log| received << log }

      _ {
        @vm.eval_code("throw 'plain string error';")
      }.must_raise Quickjs::RuntimeError

      _(received.size).must_equal 1
      _(received.first.severity).must_equal :error
    end

    it "listener exception is catchable in JS try/catch" do
      @vm.on_log { |_log| raise IOError, "listener broke" }

      result = @vm.eval_code('try { console.log("boom"); "no error"; } catch(e) { e.message; }')
      _(result).must_equal "listener broke"
    end

    it "listener exception propagates as Ruby error when uncaught in JS" do
      @vm.on_log { |_log| raise IOError, "listener broke" }

      err = _ { @vm.eval_code('console.log("boom")') }.must_raise IOError
      _(err.message).must_equal "listener broke"
    end

    it "listener exception in error path does not interfere with original exception" do
      @vm.on_log { |_log| raise IOError, "listener broke" }

      _ {
        @vm.eval_code('a + b;')
      }.must_raise Quickjs::ReferenceError
    end

    # A Promise nested inside a container falls through console.log's
    # top-level Promise special case into to_rb_value, which raises. On the
    # pure path that raise fires inside the GVL re-acquired log dispatcher —
    # it must surface as a JS throw, not longjmp across the
    # rb_thread_call_without_gvl region.
    it "surfaces a row-building failure as a catchable JS error" do
      @vm.on_log { |_log| }

      result = @vm.eval_code('try { console.log([Promise.resolve(1)]); "not thrown"; } catch(e) { "caught: " + e.message; }')
      _(result).must_match(/\Acaught: /)
    end

    it "keeps the VM usable after a row-building failure during a GVL-released eval" do
      received = []
      @vm.on_log { |log| received << log }

      err = _ { @vm.eval_code('console.log([Promise.resolve(1)])') }.must_raise Quickjs::RuntimeError
      _(err.message).must_match(/cannot translate a Promise/)

      # gvl_released_eval must not be left stuck by the failure: register a
      # bridge so the next eval keeps the GVL — a leaked flag would make
      # console.log re-acquire the GVL while already holding it, aborting MRI.
      @vm.define_function('noop') { nil }
      _(@vm.eval_code('console.log("after"); "still alive"')).must_equal 'still alive'
      _(received.last.to_s).must_equal 'after'
    end

    it "keeps the release flag balanced when the listener re-enters eval_code" do
      received = []
      @vm.on_log do |log|
        received << log.to_s
        @vm.eval_code('1 + 1')
      end

      # The nested eval must restore (not clear) the outer eval's released
      # flag; otherwise the second console.log touches Ruby without the GVL.
      _(@vm.eval_code('console.log("first"); console.log("second"); "done"')).must_equal 'done'
      _(received).must_equal ['first', 'second']
    end

    # The listener runs with the GVL re-acquired, so JS re-entered from it
    # through a GVL-held path (here: VM#call, which always holds the GVL)
    # must see the release flag cleared — otherwise its console.log would
    # re-acquire an already-held GVL, which MRI aborts on.
    it "routes console.log inline when the listener re-enters a GVL-held path" do
      received = []
      @vm.eval_code('globalThis.nested = () => { console.log("nested"); return 1; }')
      @vm.on_log do |log|
        received << log.to_s
        @vm.call('nested') if received.size == 1
      end

      _(@vm.eval_code('console.log("outer"); "done"')).must_equal 'done'
      _(received).must_equal ['outer', 'nested']
    end

    # Registering a bridge mid-eval would invalidate the can_eval_gvl_free
    # decision the running (GVL-released) eval was started under — the JS
    # continuing after the listener could reach the new bridge and call
    # Ruby without holding the GVL. The registration APIs refuse instead.
    it "refuses to install a bridge from a listener during a GVL-released eval" do
      errors = []
      @vm.on_log do |_log|
        begin
          @vm.define_function('sneaky') { 1 }
        rescue ThreadError => e
          errors << e
        end
      end

      _(@vm.eval_code('console.log("x"); "done"')).must_equal 'done'
      _(errors.size).must_equal 1
      _(errors.first.message).must_match(/bridge/)
    end
  end

  describe "StackTraces" do
    before do
      @vm = Quickjs::VM.new
      @received = []
      @vm.on_log { |log| @received << log }
    end

    it "unhandled exception with an Error class should be logged with stack trace" do
      _ {
        @vm.eval_code(<<~JS)
          const a = 1;
          const c = 3;
          a + b;
        JS
      }.must_raise Quickjs::ReferenceError
      _(@received.size).must_equal 1
      _(@received.last.severity).must_equal :error
      _(@received.last.raw.first.split("\n")).must_equal [
        "Uncaught ReferenceError: 'b' is not defined",
        '    at <eval> (<code>:3:5)'
      ]
    end

    it "unhandled exception without any Error class should be logged with stack trace" do
      _ {
        @vm.eval_code(<<~JS)
          const a = 1;
          throw 'Don\\'t wanna compute at all';
        JS
      }.must_raise Quickjs::RuntimeError
      _(@received.size).must_equal 1
      _(@received.last.severity).must_equal :error
      _(@received.last.raw.first.split("\n")).must_equal [
        "Uncaught 'Don't wanna compute at all'"
      ]
    end

    it "should include multi layers of stack trace" do
      @vm.import(['wrapError'], from: File.read('./test/fixture.esm.js'))
      _ {
        @vm.eval_code('wrapError();')
      }.must_raise Quickjs::RuntimeError
      _(@received.size).must_equal 1
      _(@received.last.severity).must_equal :error
      trace = @received.last.raw.first.split("\n")
      _(trace.size).must_equal 4
      _(trace[0]).must_equal 'Uncaught Error: unpleasant wrapped error'
      _(trace[1]).must_match(/at thrower \(\w{12}:6:18\)/)
      _(trace[2]).must_match(/at wrapError \(\w{12}:10:10\)/)
      _(trace[3]).must_equal '    at <eval> (<code>:1:10)'
    end
  end
end

describe "Quickjs::Blocking" do
  def run_threads(&block)
    queue = Queue.new
    t1 = Thread.new(queue) {|q| 3.times { |i| q << 't1'; sleep 0.01 } }
    t2 = Thread.new(queue) {|q| block.call; q << 't2' }
    [t1, t2].each { |t| t.join }
    queue.size.times.map { queue.pop }
  end

  def assert_sleep_a_sec_within_thread(&block)
    _(run_threads(&block)).must_equal %w(t1 t1 t1 t2)
  end

  describe "ProcessBlocking" do
    before do
      @vm = Quickjs::VM.new(timeout_msec: 500, features: [::Quickjs::MODULE_OS])
    end

    it "ensure Kernel#sleep is fine" do
      assert_sleep_a_sec_within_thread do
        sleep 0.2
      end
    end

    it "ensure Kernel#sleep via a provided function is fine" do
      @vm.define_function 'rbsleep' do |n|
        sleep n
      end

      assert_sleep_a_sec_within_thread do
        @vm.eval_code('await rbsleep(0.2);')
      end

      assert_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await new Promise(async resolve => { rbsleep(0.2); resolve(); }); } await top();')
      end
    end

    # The GVL is released during VM#eval_code on the pure path, so these
    # blocking-looking calls (os.sleep, os.setTimeout, os.sleepAsync) no
    # longer hold up sibling Ruby threads.
    it "os.sleep does not block other threads" do
      assert_sleep_a_sec_within_thread do
        @vm.eval_code('os.sleep(200);')
      end
    end

    it "awaiting os.setTimeout does not block other threads" do
      assert_sleep_a_sec_within_thread do
        @vm.eval_code('await new Promise(resolve => os.setTimeout(resolve, 200));')
      end
    end

    it "awaiting async function which wraps os.setTimeout does not block other threads" do
      assert_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await new Promise(resolve => os.setTimeout(resolve, 200)); } await top();')
      end
    end

    it "awaiting os.sleepAsync does not block other threads" do
      assert_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await os.sleepAsync(200); } await top();')
      end
    end
  end

  describe "RubyBasedTimeout" do
    before do
      @vm = Quickjs::VM.new(timeout_msec: 500, features: [::Quickjs::FEATURE_TIMEOUT])
    end

    it "awaiting setTimeout does not block other threads" do
      assert_sleep_a_sec_within_thread do
        @vm.eval_code('await new Promise(resolve => setTimeout(resolve, 200));')
      end
    end
  end

  describe "ParallelEval" do
    # Smoke test for VM#eval_code releasing the GVL: N threads each running
    # a CPU-bound JS workload on their own VM should all complete with the
    # expected result. Regressions in the pure-eval fast path (lost work,
    # corrupted state, missing GVL re-acquire) surface as crashes or wrong
    # return values here, even without measuring wall-clock scaling.
    def cpu_workload
      <<~JS
        (() => {
          let acc = 0;
          for (let i = 0; i < 5000; i++) {
            acc = (acc + i) % 1e9;
          }
          return acc;
        })();
      JS
    end

    it "runs eval_code in parallel across multiple VMs without crashing" do
      expected = (0...5000).sum % 1_000_000_000
      threads  = Array.new(4) {
        Thread.new {
          vm = Quickjs::VM.new

          begin
            5.times.map { vm.eval_code(cpu_workload) }
          ensure
            vm.dispose!
          end
        }
      }
      results = threads.map(&:value)
      _(results.flatten.uniq).must_equal [expected]
    end

    it "evaluates pure JS concurrently with measurable speedup" do
      timing_workload = cpu_workload_js

      assert_run_in_parallel do |iterations|
        # The eval budget is wall-clock, so a scheduling stall on a busy CI
        # runner can push one ~10ms eval past the 100ms default and error
        # the test with InterruptedError. Parallelism is what's asserted
        # here, not the budget — make the timeout a non-factor.
        vm = Quickjs::VM.new(timeout_msec: 10_000)
        begin
          iterations.times { vm.eval_code(timing_workload) }
        ensure
          vm.dispose!
        end
      end
    end

    # Runnable#run is the warmer-pool hot path: compile a bundle once, run
    # it on per-thread VMs. Before the release, the bytecode eval held the
    # GVL and N threads fully serialized.
    it "runs compiled bytecode concurrently with measurable speedup" do
      runnable = Quickjs.compile(cpu_workload_js)

      assert_run_in_parallel do |iterations|
        vm = Quickjs::VM.new(timeout_msec: 10_000)
        begin
          iterations.times { runnable.run(on: vm) }
        ensure
          vm.dispose!
        end
      end
    end

    # Parsing is proportional to the source, not to what the source computes,
    # so the compile workloads below are made large rather than slow. Scaling
    # this much further needs a different shape: JS_EVAL_FLAG_ASYNC turns
    # these top-level declarations into closure variables, and somewhere past
    # 65k of them the compile fails outright.
    def bulky_source(functions: 2_000)
      Array.new(functions) {|i|
        "function f#{i}(a, b) { return a * #{i} + b - Math.sqrt(a + #{i}); }"
      }.join("\n")
    end

    it "compiles on a VM per thread without crashing" do
      source   = bulky_source(functions: 20)
      expected = Quickjs.compile(source).to_s

      results = Array.new(4) {
        Thread.new {
          vm = Quickjs::VM.new(timeout_msec: 10_000)

          begin
            3.times.map { vm.compile(source).to_s }
          ensure
            vm.dispose!
          end
        }
      }.map(&:value)

      # Not `.uniq`: a thread that quietly produced fewer results than it was
      # asked for would still leave one distinct value behind.
      _(results.flatten).must_equal Array.new(12, expected)
    end

    # Compiling is a pool's other bottleneck: a dedicated compile-only VM
    # turns each new script body into bytecode, and before the release it
    # held the GVL for the whole parse — stopping every other thread,
    # including the warmers building the next VMs.
    #
    # The release is unconditional here, unlike the two above: a compile-only
    # eval runs no JS, so no bridge can fire and no can_eval_gvl_free gate is
    # needed.
    #
    # 2000 functions rather than the 500 this started at, because 500 put the
    # single-threaded side at ~13ms on a macOS runner and a window that short
    # loses to scheduler noise: it measured 0.88 there and exhausted all three
    # of the helper's attempts, while the same commit passed the same job on
    # an earlier run. Raising the workload is available here even though #77
    # ruled it out for the preload test — that one's confound is dispose!
    # cost growing with the resident module defs, and a compile VM keeps
    # nothing, so its dispose! stays flat. Measured: VM.new + dispose! is
    # 0.04ms, which is 0.6% of the timed block at 500 and 0.1% at 2000, and
    # the ratio itself holds at 0.50-0.58 from 31KB of source through 262KB.
    it "compiles concurrently with measurable speedup" do
      source = bulky_source

      assert_run_in_parallel do |iterations|
        vm = Quickjs::VM.new(timeout_msec: 10_000)

        begin
          iterations.times { vm.compile(source) }
        ensure
          vm.dispose!
        end
      end
    end

    # The pure-eval fast path releases the GVL, so console.log inside that
    # eval reaches js_quickjsrb_log without holding it. The dispatcher must
    # re-acquire the GVL via rb_thread_call_with_gvl before invoking the
    # on_log block — otherwise touching Ruby APIs from the released thread
    # crashes the interpreter. This test exercises that re-acquire path.
    it "delivers console.log to on_log during a GVL-released eval" do
      vm       = Quickjs::VM.new
      received = []
      vm.on_log { |log| received << log }

      begin
        vm.eval_code('console.log("hello"); console.log(42, "world"); 1 + 1')

        _(received.size).must_equal 2
        _(received[0].to_s).must_equal 'hello'
        _(received[1].to_s).must_equal '42 world'
      ensure
        vm.dispose!
      end
    end

    # Regression test: setTimeout enqueues js_delay_and_eval_job which calls
    # rb_funcall and rb_thread_wait_for synchronously. The pure-eval fast
    # path must keep the GVL held when FEATURE_TIMEOUT is enabled, otherwise
    # those Ruby APIs run without the GVL and crash.
    it "tolerates setTimeout in JS without crashing the interpreter" do
      vm = Quickjs::VM.new(features: [::Quickjs::FEATURE_TIMEOUT])

      begin
        _(vm.eval_code('await new Promise(resolve => setTimeout(() => resolve(42), 10));')).must_equal 42
      ensure
        vm.dispose!
      end
    end
  end
end
