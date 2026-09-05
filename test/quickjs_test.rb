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

    it "shared reference converts to the same Ruby object, not nil" do
      result = ::Quickjs.eval_code("const o = {a: 1}; [o, o]")
      _(result).must_equal [{'a' => 1}, {'a' => 1}]
      _(result[0]).must_be_same_as result[1]
    end

    it "shared reference under distinct keys keeps both branches" do
      assert_code("const o = {a: 1}; ({x: o, y: o})", {'x' => {'a' => 1}, 'y' => {'a' => 1}})
    end

    it "object that is both a cycle and a share keeps the cycle marker in every occurrence" do
      result = ::Quickjs.eval_code("const o = {n: 1}; o.self = o; [o, o]")
      _(result).must_equal [{'n' => 1, 'self' => nil}, {'n' => 1, 'self' => nil}]
      _(result[0]).must_be_same_as result[1]
    end

    it "share whose first occurrence is nested deeper than its second" do
      result = ::Quickjs.eval_code("const o = {n: 1}; [{deep: {o}}, o]")
      _(result).must_equal [{'deep' => {'o' => {'n' => 1}}}, {'n' => 1}]
      _(result[0]['deep']['o']).must_be_same_as result[1]
    end

    it "shared reference through an array element stays shared" do
      result = ::Quickjs.eval_code("const a = [1]; ({x: a, y: a})")
      _(result).must_equal({'x' => [1], 'y' => [1]})
      _(result['x']).must_be_same_as result['y']
    end

    it "a DAG converts every branch instead of nilling repeats" do
      # Each level references the same child twice, so the old visited set nil'd
      # every right-hand branch. Sharing keeps one hash per level, and keeps the
      # graph from being duplicated into ~2M hashes on the way.
      result = ::Quickjs.eval_code(<<~JS)
        let cur = {leaf: 1};
        for (let i = 0; i < 20; i++) { cur = {l: cur, r: cur}; }
        cur;
      JS
      _(result['l']).must_be_same_as result['r']

      depth = 0
      node = result
      until node.key?('leaf')
        node = node['r']
        depth += 1
      end
      _(depth).must_equal 20
    end

    it "toJSON representation is recomputed per occurrence, not shared" do
      # Sharing it would hand the same mutable String to both slots.
      result = ::Quickjs.eval_code("const d = new Date(0); [d, d]")
      _(result).must_equal ['1970-01-01T00:00:00.000Z'] * 2
      _(result[0]).wont_be_same_as result[1]
    end

    it "toJSON returning another object shares that object's conversion" do
      # The instance itself is not memoized, but its stand-in is `inner`, so
      # both slots legitimately describe the same JS object.
      result = ::Quickjs.eval_code(<<~JS)
        const inner = {v: 1};
        class C { toJSON() { return inner } }
        [new C(), inner];
      JS
      _(result).must_equal [{'v' => 1}, {'v' => 1}]
      _(result[0]).must_be_same_as result[1]
    end

    it "an object freed by a getter cannot be mistaken for an earlier one" do
      # Conversion keys objects by address, so it pins every one it has seen:
      # without that, dropping `holder[0]` frees it and the object minted by the
      # getter can land on the same address and hit the earlier entry.
      assert_code(<<~JS, {'a' => {'tag' => 'DEAD'}, 'b' => {'tag' => 'FRESH'}})
        const holder = [{tag: 'DEAD'}];
        const o = {
          a: holder[0],
          get b() { holder.length = 0; delete o.a; return {tag: 'FRESH'} },
        };
        o;
      JS
    end

    it "a share reached first through a cycle keeps the truncated shape" do
      # `b` is not part of a cycle at the top level, but it converted under `a`
      # where it was, so both occurrences carry the same nil marker. The
      # truncation point follows traversal order.
      result = ::Quickjs.eval_code("const a = {n: 1}; const b = {a}; a.b = b; [{x: a}, b]")
      _(result).must_equal [{'x' => {'n' => 1, 'b' => {'a' => nil}}}, {'a' => nil}]
      _(result[0]['x']['b']).must_be_same_as result[1]
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

    # JS_IsArray answers -1 rather than false when it cannot resolve a proxy,
    # and read as a boolean that took the array path: a value whose every trap
    # throws came back as [], indistinguishable from a genuine empty Array.
    describe "a revoked Proxy" do
      def revoked
        "const {proxy, revoke} = Proxy.revocable({a: 1}, {}); revoke();"
      end

      it "reports the TypeError the guest would see" do
        error = _ { ::Quickjs.eval_code("#{revoked} proxy") }.must_raise Quickjs::TypeError
        _(error.message).must_equal 'revoked proxy'
      end

      it "reports it from inside a container too" do
        _ { ::Quickjs.eval_code("#{revoked} ({ok: 1, bad: proxy})") }.must_raise Quickjs::TypeError
        _ { ::Quickjs.eval_code("#{revoked} [1, proxy]") }.must_raise Quickjs::TypeError
      end

      it "leaves the VM usable, having taken the throw off the context" do
        vm = Quickjs::VM.new
        _ { vm.eval_code("#{revoked} proxy") }.must_raise Quickjs::TypeError
        _(vm.eval_code('1 + 1')).must_equal 2
      ensure
        vm.dispose!
      end

      # The -1 is the proxy being unresolvable, not the target being an array,
      # so a live proxy has to keep converting as whatever it wraps.
      it "does not change what a live Proxy converts to" do
        assert_code("new Proxy([1, 2, 3], {})", [1, 2, 3])
        assert_code("new Proxy({a: 1}, {})", {'a' => 1})
      end

      # A log line must not decide whether the statement after it runs, so the
      # row builder substitutes the way it does for a Promise, rather than
      # letting the conversion report. The raise would also come back to the
      # guest catchable, pinning a Ruby exception per catch.
      it "is substituted in a log row rather than reported" do
        vm = Quickjs::VM.new
        rows = []
        vm.on_log { |l| rows << l.to_s }

        result = vm.eval_code("#{revoked} let c = 'none'; try { console.log('x', proxy) } catch (e) { c = e.message } c")

        _(result).must_equal 'none'
        _(rows).must_equal ['x (unrenderable value)']
      ensure
        vm.dispose!
      end

      it "is substituted at whatever depth it sits in a log row" do
        vm = Quickjs::VM.new
        rows = []
        vm.on_log { |l| rows << l.raw }

        result = vm.eval_code("#{revoked} console.log([proxy], {p: proxy}); 'after'")

        _(result).must_equal 'after'
        _(rows).must_equal [[['(unrenderable value)'], {'p' => '(unrenderable value)'}]]
      ensure
        vm.dispose!
      end

      # Met twice in one row it is two substitutions, not a substitution and a
      # cycle: nil is what this conversion reserves for a genuine cycle.
      it "is substituted once per occurrence in a log row" do
        vm = Quickjs::VM.new
        rows = []
        vm.on_log { |l| rows << l.raw }

        vm.eval_code("#{revoked} console.log({a: proxy, b: proxy}, [proxy, proxy]); 1")

        _(rows).must_equal [[
          {'a' => '(unrenderable value)', 'b' => '(unrenderable value)'},
          ['(unrenderable value)', '(unrenderable value)'],
        ]]
      ensure
        vm&.dispose!
      end

      # JS_IsFunction reads a proxy's is_func without resolving it, so a
      # function target would be claimed by that branch and raise from the
      # toString read rather than being substituted with the rest.
      it "is substituted in a log row over a function target too" do
        vm = Quickjs::VM.new
        rows = []
        vm.on_log { |l| rows << l.raw }

        fn_revoked = "const {proxy, revoke} = Proxy.revocable(function(){}, {}); revoke();"
        result = vm.eval_code("#{fn_revoked} console.log('x', proxy); 'after'")

        _(result).must_equal 'after'
        _(rows).must_equal [['x', '(unrenderable value)']]
      ensure
        vm&.dispose!
      end

      # The check at the top of the object case is not the last word: the reads
      # after it run the guest's own traps, and one of them can revoke the
      # proxy that was live when it was asked about.
      describe "revoking itself from its own trap" do
        def self_revoking(target)
          <<~JS
            globalThis.mk = () => {
              let rev;
              const t = #{target};
              const p = new Proxy(t, {
                get(x, k) { if (rev) { rev(); rev = null } return x[k] },
                getPrototypeOf(x) { if (rev) { rev(); rev = null } return Object.getPrototypeOf(x) },
              });
              const r = Proxy.revocable(p, {});
              rev = r.revoke;
              return r.proxy;
            };
          JS
        end

        it "is still substituted, over an object target" do
          vm = Quickjs::VM.new
          rows = []
          vm.on_log { |l| rows << l.raw }
          vm.eval_code(self_revoking('{a: 1}'))

          _(vm.eval_code("console.log(mk(), mk()); 'after'")).must_equal 'after'
          _(rows).must_equal [['(unrenderable value)', '(unrenderable value)']]
        ensure
          vm&.dispose!
        end

        # Over a function target it still reports, and that is deliberate.
        # JS_IsFunction answers off is_func without resolving, so this one is
        # claimed by the function branch and refuses at its toString, where the
        # throw already pending is not necessarily the proxy's: it can be an
        # out-of-memory, which has to reach the renderer that latches the VM.
        # Substituting there would swallow it. The row is lost for this one
        # shape rather than the latch for every shape.
        it "reports rather than substitutes, over a function target" do
          vm = Quickjs::VM.new
          rows = []
          vm.on_log { |l| rows << l.raw }
          vm.eval_code(self_revoking('function(){}'))

          _ { vm.eval_code("console.log(mk()); 'after'") }.must_raise Quickjs::TypeError
          _(rows).must_equal []
        ensure
          vm&.dispose!
        end

        # The reason the substitution stops at the function branch. Over an
        # object target the same shape is still lost, but it is lost on main
        # too: the unchecked rb_object_id read swallows the out-of-memory and
        # JS_IsArray's own throw replaces it. That is #119, not this branch.
        it "still condemns the VM when the trap runs the heap out" do
          vm = Quickjs::VM.new(memory_limit: 8 * 1024 * 1024)
          vm.on_log { |l| }
          vm.eval_code(<<~JS)
            globalThis.mk = () => {
              let rev;
              const t = function(){};
              const p = new Proxy(t, { get(x, k) {
                if (rev) { rev(); rev = null; const a = []; for (;;) a.push(new Array(10000).fill(0)) }
                return x[k]
              } });
              const r = Proxy.revocable(p, {});
              rev = r.revoke;
              return r.proxy;
            };
          JS

          error = _ { vm.eval_code("console.log(mk()); 'after'") }.must_raise Quickjs::RuntimeError
          _(error.message).must_match(/out of memory/)
          _(vm.memory_poisoned?).must_equal true
        ensure
          vm&.dispose!
        end

        # The throw held aside while the proxy is asked about can be a bridge
        # reporting a host failure. Discarding it would swallow the error and
        # leave the Ruby exception parked in alive_objects, which only
        # find_ruby_error takes it out of.
        it "still reports a host error raised by the revoking trap itself" do
          vm = Quickjs::VM.new
          vm.on_log { |l| }
          vm.define_function('boom') { raise IOError, 'host' }
          vm.eval_code(<<~JS)
            globalThis.mk = () => {
              let rev;
              const t = function(){};
              const p = new Proxy(t, { get(x, k) { if (rev) { rev(); rev = null; boom() } return x[k] } });
              const r = Proxy.revocable(p, {});
              rev = r.revoke;
              return r.proxy;
            };
          JS

          error = _ { vm.eval_code("console.log(mk()); 'after'") }.must_raise IOError
          _(error.message).must_equal 'host'
        ensure
          vm&.dispose!
        end

        # The substitution is for the proxy refusing, not for every throw the
        # same read can carry.
        it "still lets a host error out of a function's toString" do
          vm = Quickjs::VM.new
          vm.on_log { |l| }
          vm.define_function('boom') { raise IOError, 'host' }
          vm.eval_code("globalThis.f = function(){}; f.toString = () => { boom() }")

          error = _ { vm.eval_code("console.log(f); 1") }.must_raise IOError
          _(error.message).must_equal 'host'
        ensure
          vm&.dispose!
        end
      end

      # The argument loop is a JSCFunction with nothing between it and the
      # interpreter, so a raise there used to longjmp past the JS_FreeValue and
      # pin the argument's whole graph on the JS heap, once per call and
      # repeatable, which condemns the VM rather than merely leaking.
      describe "as a define_function argument" do
        it "reaches the guest as a catchable error" do
          vm = Quickjs::VM.new
          vm.define_function(:take) { |x| 'unreachable' }

          caught = vm.eval_code("#{revoked} let c = 'none'; try { take(proxy) } catch (e) { c = e.message } c")

          _(caught).must_equal 'revoked proxy'
        ensure
          vm&.dispose!
        end

        it "does not accumulate on the JS heap across calls" do
          vm = Quickjs::VM.new
          vm.define_function(:take) { |x| 1 }
          vm.eval_code('globalThis.mk = () => { const {proxy, revoke} = Proxy.revocable({a: 1, big: new Array(200).fill(0)}, {}); revoke(); return proxy }')
          200.times { vm.eval_code('try { take(mk()) } catch (e) {}') }
          vm.gc!
          before = vm.memory_usage

          500.times { vm.eval_code('try { take(mk()) } catch (e) {}') }
          vm.gc!
          after = vm.memory_usage

          _((after[:obj_count] - before[:obj_count]) / 500.0).must_be :<, 1.0
          _(vm.memory_poisoned?).must_equal false
        ensure
          vm&.dispose!
        end
      end

      # Only the one refusal is substituted. A host failure met while walking a
      # logged value is not the log path's to swallow.
      it "still lets a host error out of a logged value" do
        vm = Quickjs::VM.new
        vm.on_log { |l| }
        vm.define_function('boom') { raise IOError, 'host' }
        vm.eval_code("globalThis.C = class { toJSON() { boom() } }")

        error = _ { vm.eval_code("console.log({o: new C()}); 'after'") }.must_raise IOError
        _(error.message).must_equal 'host'
      ensure
        vm.dispose!
      end

      # The other way js_resolve_proxy answers -1. Reported rather than
      # swallowed for the same reason: it is what Array.isArray would have
      # said about the same value.
      it "reports the stack overflow of a chain too deep to resolve" do
        deep = "let p = [1, 2]; for (let i = 0; i < 1500; i++) p = new Proxy(p, {});"
        error = _ { ::Quickjs.eval_code("#{deep} p") }.must_raise Quickjs::RuntimeError
        _(error.message).must_match(/stack overflow/)
      end
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

  # A conversion that raises partway through — a Promise nested in the graph is
  # the reachable case — must release everything it was holding on that exit.
  # What leaks is guest-chosen and never returned, so a long-lived VM fills up
  # at a rate the script picks.
  describe "ConversionUnwind" do
    # Objects and bytes both matter: obj_count does not count JSStrings, so a
    # leak made entirely of strings would pass an object-only assertion. Both
    # come from QuickJS's own accounting, so this sees what the VM allocated
    # and not what the extension allocated beside it on the Ruby heap.
    def retained(vm, iterations)
      # The first rounds cache shapes, intern atoms and settle whatever the
      # previous evaluation left pending, all of which persist for the life of
      # the VM. Measure once that has stopped moving.
      2.times { yield }
      vm.gc!
      before = vm.memory_usage
      iterations.times { yield }
      vm.gc!
      after = vm.memory_usage
      {objects: after[:obj_count] - before[:obj_count],
       bytes:   after[:malloc_size] - before[:malloc_size]}
    end

    # to_js_value runs inspect on the caller's own objects, so converting the
    # arguments of a call can raise part-way through — and the ones already
    # converted went with it, along with the array they sat in.
    it "releases the arguments already converted when a later one raises" do
      vm = Quickjs::VM.new
      vm.eval_code('globalThis.f = () => 1')
      raiser = Class.new { def inspect = raise(ArgumentError, 'mid-conversion') }

      retained = retained(vm, 200) do
        begin
          vm.call('f', {a: [1, 2, 3], b: 'x' * 64}, raiser.new)
          flunk 'expected inspect to raise'
        rescue ArgumentError
        end
      end

      _(retained).must_equal({objects: 0, bytes: 0})
    ensure
      vm.dispose!
    end

    # The expected error is named rather than swallowed: a source that stops
    # raising — or never raised, because it was a syntax error all along —
    # would otherwise measure nothing and pass.
    def retained_by_eval(vm, code, iterations, raising:)
      retained(vm, iterations) do
        begin
          vm.eval_code(code)
          flunk "expected the conversion to raise #{raising}"
        rescue raising
        end
      end
    end

    NOTHING = {objects: 0, bytes: 0}.freeze

    it "releases the graph it was walking when the conversion raises" do
      vm = Quickjs::VM.new
      _(retained_by_eval(vm, '({a: {b: 1}, p: Promise.resolve(1)})', 200, raising: Quickjs::RuntimeError)).must_equal NOTHING
    ensure
      vm.dispose!
    end

    it "releases a toJSON result the returned value does not reference" do
      vm = Quickjs::VM.new
      vm.eval_code('globalThis.C = class { toJSON() { return {p: Promise.resolve(1)} } }')
      _(retained_by_eval(vm, '({o: new C()})', 200, raising: Quickjs::RuntimeError)).must_equal NOTHING
    ensure
      vm.dispose!
    end

    it "releases the property table when a getter raises through a bridge" do
      vm = Quickjs::VM.new
      vm.define_function('boom') { raise IOError, 'boom' }
      _(retained_by_eval(vm, '({a: {deep: 1}, get b() { boom() }})', 200, raising: IOError)).must_equal NOTHING
    ensure
      vm.dispose!
    end

    # Past CONV_FRAMES_INLINE, so the frame stack has to grow and still be
    # drained by the unwind.
    it "releases a graph nested deeper than the inline frame stack" do
      vm = Quickjs::VM.new
      code = "#{'{a: ' * 20}{p: Promise.resolve(1)}#{'}' * 20}"
      _(retained_by_eval(vm, "(#{code})", 200, raising: Quickjs::RuntimeError)).must_equal NOTHING
    ensure
      vm.dispose!
    end

    # A function converts through its own toString, which is guest code.
    it "releases a function whose toString throws" do
      vm = Quickjs::VM.new
      # Wrapped in a call so the binding is fresh on every evaluation; a bare
      # `const h` would redeclare and turn every round after the first into a
      # syntax error that never reaches a conversion.
      code = "(() => { const h = () => 1; h.toString = () => { throw new RangeError('z') }; return {h} })()"
      _(retained_by_eval(vm, code, 200, raising: Quickjs::RangeError)).must_equal NOTHING
    ensure
      vm.dispose!
    end

    # Not a JS-level raise at all: Timeout and Thread#raise land wherever the
    # conversion happens to be, which is the exit the result's owner covers.
    it "releases the result when an async interrupt lands in the conversion" do
      vm = Quickjs::VM.new
      vm.define_function('slow') { Thread.current.raise(IOError, 'interrupted'); 1 }
      code = "({a: {b: 1}, get c() { slow() }})"
      _(retained_by_eval(vm, code, 200, raising: IOError)).must_equal NOTHING
    ensure
      vm.dispose!
    end

    # Conversion runs guest JS, so it is a JS entry like any other: dispose!
    # reached from a getter has to be refused rather than freeing the runtime
    # the walk is still reading.
    it "refuses dispose! reached from a getter during result conversion" do
      vm = Quickjs::VM.new
      vm.define_function('bye') { vm.dispose!; 1 }

      _ do
        vm.eval_code(<<~JS)
          const o = {};
          Object.defineProperty(o, 'a', {enumerable: true, get() { bye(); return {z: 1} }});
          o.b = {y: 2};
          o;
        JS
      end.must_raise ThreadError

      _(vm.disposed?).must_equal false
    ensure
      vm.dispose!
    end

    # JS_ToCString answers NULL when the value's own toString throws, and the
    # block that renders an error into a Ruby one used to raise on that NULL
    # past its own frees, abandoning the message it had already built.
    it "releases the rendered error when reading its name throws" do
      vm = Quickjs::VM.new
      code = <<~JS
        (() => {
          const e = new Error('y'.repeat(4000));
          Object.defineProperty(e, 'name', {get() { throw new RangeError('z') }});
          throw e;
        })()
      JS
      _(retained_by_eval(vm, code, 200, raising: Quickjs::RuntimeError)).must_equal NOTHING
    ensure
      vm.dispose!
    end

    # The two blocks below hold references on the path that does not raise, so
    # a regression there leaks on every log line and every rejection rather
    # than only when something goes wrong.
    it "releases what it read from a logged error" do
      vm = Quickjs::VM.new
      vm.on_log {|log| }
      _(retained(vm, 200) { vm.eval_code("console.log(new RangeError('l'))") }).must_equal NOTHING
    ensure
      vm.dispose!
    end

    it "releases what it read from a rejection reason" do
      vm = Quickjs::VM.new
      vm.on_unhandled_rejection {|err| }
      _(retained(vm, 200) { vm.eval_code("void Promise.reject(new TypeError('r'))") }).must_equal NOTHING
    ensure
      vm.dispose!
    end

    # A BigInt is not JS_TAG_OBJECT, so the conversion state that owns
    # references for the object walk is never built for this branch.
    it "releases a BigInt whose toString throws" do
      vm = Quickjs::VM.new
      code = "(() => { BigInt.prototype.toString = () => { throw new RangeError('q') }; return 1n })()"
      _(retained_by_eval(vm, code, 200, raising: Quickjs::RangeError)).must_equal NOTHING
    ensure
      vm.dispose!
    end
  end

  describe "UnrenderableValues" do
    # Reading `name` off the rejected error throws, so JS_ToCString answers
    # NULL and the name reached strcmp, which dereferenced it and took the
    # process down. Guest JavaScript alone; the host only registered a handler.
    it "reports a rejection whose name getter throws instead of crashing" do
      vm = Quickjs::VM.new
      captured = []
      vm.on_unhandled_rejection {|err| captured << err }
      vm.eval_code(<<~JS)
        const e = new Error('the reason survives');
        Object.defineProperty(e, 'name', {get() { throw new RangeError('z') }});
        void Promise.reject(e);
      JS

      _(captured.size).must_equal 1
      _(captured.first).must_be_kind_of Quickjs::RuntimeError
      _(captured.first.message).must_match(/the reason survives/)
    ensure
      vm.dispose!
    end

    # The same NULL one property over. This one raised ArgumentError out of
    # the tracker, which is a longjmp through a QuickJS host callback: the
    # rb_protect meant to stop exactly that sat below the conversion.
    it "reports a rejection whose message getter throws instead of raising out of eval" do
      vm = Quickjs::VM.new
      captured = []
      vm.on_unhandled_rejection {|err| captured << err }
      vm.eval_code(<<~JS)
        const e = new Error('m');
        Object.defineProperty(e, 'message', {get() { throw new RangeError('z') }});
        void Promise.reject(e);
      JS

      _(captured.size).must_equal 1
      _(captured.first.message).must_match(/unrenderable/)
      _(vm.eval_code('40 + 2')).must_equal 42
    ensure
      vm.dispose!
    end

    it "raises the error a throwing name getter hid, rather than reporting the NULL" do
      vm = Quickjs::VM.new
      error = _ do
        vm.eval_code(<<~JS)
          const e = new Error('the message survives');
          Object.defineProperty(e, 'name', {get() { throw new RangeError('z') }});
          throw e;
        JS
      end.must_raise Quickjs::RuntimeError

      _(error.message).must_match(/the message survives/)
    ensure
      vm.dispose!
    end

    # A Symbol has no string form at all, so this needs no guest-defined
    # method: JS_ToCString refuses it and rb_str_new2 was handed the NULL.
    it "logs a Symbol instead of raising ArgumentError" do
      vm = Quickjs::VM.new
      logged = []
      vm.on_log {|log| logged << log.to_s }
      vm.eval_code('console.log(Symbol("x"))')

      _(logged.size).must_equal 1
      _(logged.first).must_match(/unrenderable/)
    ensure
      vm.dispose!
    end

    # Passing NULL to a "%s" is undefined; glibc prints "(null)" and other
    # libcs dereference it. Asserting on the placeholder catches the formatting
    # everywhere, including where it happens not to crash.
    it "logs an Error whose stack getter throws" do
      vm = Quickjs::VM.new
      logged = []
      vm.on_log {|log| logged.concat(log.raw) }
      vm.eval_code(<<~JS)
        const e = new Error('still readable');
        Object.defineProperty(e, 'stack', {get() { throw new RangeError('z') }});
        console.log(e);
      JS

      _(logged.first).must_match(/still readable/)
      _(logged.first).wont_match(/\(null\)/)
    ensure
      vm.dispose!
    end

    it "reports a thrown value that cannot be stringified" do
      vm = Quickjs::VM.new
      error = _ do
        vm.eval_code('throw {toString() { throw new RangeError("z") }}')
      end.must_raise Quickjs::RuntimeError

      _(error.message).must_match(/unrenderable/)
      _(error.message).wont_match(/null/)
    ensure
      vm.dispose!
    end

    # The throw came from a bridge, so the error the caller is owed is the Ruby
    # one it raised. Reporting the NULL instead is how a dispose! reached from
    # a toString used to surface as ArgumentError.
    it "gives back ThreadError when a toString disposes the VM mid-conversion" do
      vm = Quickjs::VM.new
      vm.define_function('bye') { vm.dispose! }

      _ do
        vm.eval_code(<<~JS)
          const h = () => 1;
          h.toString = () => { bye(); return 'x' };
          ({h});
        JS
      end.must_raise ThreadError

      _(vm.disposed?).must_equal false
    ensure
      vm.dispose!
    end

    it "propagates the error from a BigInt whose toString throws" do
      vm = Quickjs::VM.new
      error = _ do
        vm.eval_code("BigInt.prototype.toString = () => { throw new RangeError('q') }; 1n")
      end.must_raise Quickjs::RangeError

      _(error.message).must_match(/q/)
    ensure
      vm.dispose!
    end

    # Calling a value that is itself an exception throws "not a function" over
    # the error being reported, so the property read has to be checked before
    # the call rather than after it.
    it "propagates the error from a BigInt whose toString accessor throws" do
      vm = Quickjs::VM.new
      error = _ do
        vm.eval_code('Object.defineProperty(BigInt.prototype, "toString", {get() { throw new RangeError("q") }}); 1n')
      end.must_raise Quickjs::RangeError

      _(error.message).must_match(/q/)
    ensure
      vm.dispose!
    end

    # A bridge raising is a host failure being reported, not a value without a
    # string form, so it comes back out instead of being replaced by a
    # placeholder. Swallowing it would also strand the Ruby exception in the
    # VM's live-object map, where nothing would ever claim it.
    it "propagates a bridge error raised from a logged value's toString" do
      vm = Quickjs::VM.new
      vm.on_log {|log| }
      vm.define_function('boom') { raise IOError, 'host failure' }

      begin
        vm.eval_code('console.log({toString() { boom() }}); 1')
        flunk 'expected the bridge error to come back out'
      rescue IOError => e
        _(e.message).must_equal 'host failure'
      end

      _(vm.eval_code('40 + 2')).must_equal 42
      _($!).must_be_nil
    ensure
      vm.dispose!
    end

    it "propagates a bridge error raised while rendering a thrown error" do
      vm = Quickjs::VM.new
      vm.define_function('boom') { raise IOError, 'from the name getter' }

      error = _ do
        vm.eval_code(<<~JS)
          const e = new Error('m');
          Object.defineProperty(e, 'name', {get() { boom() }});
          throw e;
        JS
      end.must_raise IOError

      _(error.message).must_equal 'from the name getter'
    ensure
      vm.dispose!
    end

    it "gives back ThreadError when a logged toString disposes the VM" do
      vm = Quickjs::VM.new
      vm.on_log {|log| }
      vm.define_function('bye') { vm.dispose! }

      _ { vm.eval_code('console.log({toString() { bye() }}); 1') }.must_raise ThreadError

      _(vm.disposed?).must_equal false
    ensure
      vm.dispose!
    end
  end

  # The renderer that turns a pending JS exception into a Ruby one is also the
  # one that announces an uncaught error to the console and condemns a VM that
  # ran out of memory. A conversion that fails part-way through a value the
  # evaluation did return borrows the rendering and none of the rest: that
  # error is on its way to the caller, and nothing about it went uncaught.
  describe "ConversionErrorRouting" do
    it "does not announce a failed conversion to the log listener" do
      vm = Quickjs::VM.new
      logged = []
      vm.on_log {|log| logged << log.to_s }

      _ { vm.eval_code("BigInt.prototype.toString = () => { throw new RangeError('q') }; 1n") }.must_raise Quickjs::RangeError

      _(logged).must_equal []
    ensure
      vm.dispose!
    end

    # Worse than an extra row: the announcement unwound the row being built, so
    # the one row the listener did get described an uncaught error that was on
    # its way to the caller. The console.log row is lost either way — its
    # argument is what refused to convert — but silence is the honest outcome.
    it "does not announce over the console row it was building" do
      vm = Quickjs::VM.new
      logged = []
      vm.on_log {|log| logged << log.to_s }

      _ { vm.eval_code("const h = () => 1; h.toString = () => { throw new RangeError('z') }; console.log({h}); 1") }.must_raise Quickjs::RangeError

      _(logged).must_equal []
    ensure
      vm.dispose!
    end

    # Reached through a property read rather than one of the branches this
    # changed, so it says the split follows where the exception was met and not
    # which conversion happened to meet it.
    it "does not announce a getter that threw while its object was being walked" do
      vm = Quickjs::VM.new
      logged = []
      vm.on_log {|log| logged << log.to_s }

      _ { vm.eval_code("({get x() { throw new RangeError('g') }})") }.must_raise Quickjs::RangeError

      _(logged).must_equal []
    ensure
      vm.dispose!
    end

    it "still announces an error that reached the top level uncaught" do
      vm = Quickjs::VM.new
      logged = []
      vm.on_log {|log| logged << log.to_s }

      _ { vm.eval_code("throw new RangeError('top level')") }.must_raise Quickjs::RangeError

      _(logged.size).must_equal 1
      _(logged.first).must_match(/\AUncaught RangeError: top level/)
    ensure
      vm.dispose!
    end

    # The one thing the uncaught path does not keep to itself. Running out of
    # memory is a fact about the heap rather than about who was asking, and this
    # is the shape that proves the split cannot own it: the evaluation returns
    # its object and the allocation that fails is in a getter read afterwards.
    it "still condemns the VM for an out-of-memory a getter hit during conversion" do
      vm = Quickjs::VM.new(memory_limit: 1024 * 1024)

      _ { vm.eval_code('({get x() { return new Array(2_000_000).fill(0) }})') }.must_raise Quickjs::RuntimeError

      _(vm.memory_poisoned?).must_equal true
      err = _ { vm.eval_code('1 + 1') }.must_raise Quickjs::RuntimeError
      _(err.message).must_match(/poisoned/)
    ensure
      vm.dispose!
    end

    # Substituting for a read the deadline outlived loses the only evidence the
    # run overran: rendering happens after the evaluation, so there is no next
    # interrupt check to raise it again.
    it "reports the timeout that lapsed inside the error it was rendering" do
      vm = Quickjs::VM.new(timeout_msec: 50)

      _ do
        vm.eval_code(<<~JS)
          const e = new Error('m');
          Object.defineProperty(e, 'name', {get() { const t = Date.now(); while (Date.now() - t < 1000) {}; return 'X' }});
          throw e;
        JS
      end.must_raise Quickjs::InterruptedError
    ensure
      vm.dispose!
    end

    it "reports the timeout that lapsed while rendering an error met mid-conversion" do
      vm = Quickjs::VM.new(timeout_msec: 50)

      _ do
        vm.eval_code(<<~JS)
          ({get x() {
            const e = new Error('m');
            Object.defineProperty(e, 'name', {get() { const t = Date.now(); while (Date.now() - t < 1000) {}; return 'X' }});
            throw e;
          }})
        JS
      end.must_raise Quickjs::InterruptedError
    ensure
      vm.dispose!
    end

    # started_at belongs to the entry that armed it. call resolved its path and
    # rendered any failure before arming, so a render there read the previous
    # entry's clock — which had simply aged past the budget while nothing ran.
    # call now arms above its resolution like its two siblings; the flag itself
    # cannot drop between entries, since an evaluation is two counted regions
    # and its budget spans both.
    it "does not report a timeout off a clock the previous entry left behind" do
      vm = Quickjs::VM.new(timeout_msec: 50)
      vm.eval_code("globalThis.a = {get b() { throw Symbol('nope') }}; 1")
      sleep 0.15

      error = _ { vm.call('a.b') }.must_raise Quickjs::RuntimeError

      _(error.class).must_equal Quickjs::RuntimeError
      _(error.message).must_match(/unrenderable/)
    ensure
      vm.dispose!
    end

    # The arguments are converted before the clock for resolution and the call
    # starts: inspect on the caller's objects, allocation, a yield to another
    # thread — none of it is the guest's to pay for.
    it "does not charge converting the arguments of call to the budget" do
      slow = Class.new { def inspect = (sleep 0.15; 'slow') }
      vm = Quickjs::VM.new(timeout_msec: 100)
      vm.eval_code('globalThis.f = (x) => { let n = 0; for (let i = 0; i < 50000; i++) n += i; return n }')

      _(vm.call('f', slow.new)).must_equal 1249975000
    ensure
      vm.dispose!
    end

    # Resolution and the call are one budget. A second arm beside the JS_Call
    # handed a single call twice timeout_msec of guest JS: half in a getter on
    # the path, half in the function it found, neither tripping alone.
    it "gives a call one budget across resolving its path and running it" do
      vm = Quickjs::VM.new(timeout_msec: 200)
      # Each phase alone is well inside the budget; only their sum is not.
      vm.eval_code(<<~JS)
        globalThis.holder = {get f() {
          const t = Date.now(); while (Date.now() - t < 120) {}
          return () => { const u = Date.now(); while (Date.now() - u < 120) {}; return 'done' };
        }}; 1
      JS

      _ { vm.call('holder.f') }.must_raise Quickjs::InterruptedError
    ensure
      vm.dispose!
    end

    # The bytecode read runs no JS, but a failed read is rendered, and the guest
    # can give SyntaxError.prototype a name getter that throws. That render ran
    # on whatever clock the previous entry left behind.
    it "does not report a timeout off a stale clock when a preload fails" do
      vm = Quickjs::VM.new(timeout_msec: 50)
      vm.eval_code("Object.defineProperty(SyntaxError.prototype, 'name', {get() { throw Symbol('x') }}); 1")
      sleep 0.15

      error = _ { vm.send(:_preload_module_bytecode, 'garbage', 'm') }.must_raise Quickjs::RuntimeError

      _(error.class).must_equal Quickjs::RuntimeError
    ensure
      vm.dispose!
    end

    # A logged argument whose toString outlives the budget was substituted and
    # forgotten, and the evaluation returned normally having spent several times
    # its budget: the row's hold recorded the lapse and nothing read it.
    it "reports the timeout that lapsed inside a logged value" do
      vm = Quickjs::VM.new(timeout_msec: 50)
      vm.on_log {|log| }

      _ do
        vm.eval_code("console.log({toString() { const t = Date.now(); while (Date.now() - t < 1000) {}; return 'x' }}); 1")
      end.must_raise Quickjs::InterruptedError
    ensure
      vm.dispose!
    end

    # Thrown from the bridge as the interrupt QuickJS itself throws — uncatchable
    # — rather than bridged as a Ruby exception a try/catch could swallow, which
    # would also have pinned one InterruptedError in alive_objects per catch.
    it "throws the logged-value timeout as an interrupt the guest cannot catch" do
      vm = Quickjs::VM.new(timeout_msec: 50)
      vm.on_log {|log| }
      spinner = "({toString() { const t = Date.now(); while (Date.now() - t < 1000) {}; return 'x' }})"

      GC.start
      before = ObjectSpace.each_object(Quickjs::InterruptedError).count
      _ do
        vm.eval_code("let caught = 0; for (let i = 0; i < 20; i++) { try { console.log(#{spinner}) } catch (e) { caught++ } }; caught")
      end.must_raise Quickjs::InterruptedError
      GC.start

      _(ObjectSpace.each_object(Quickjs::InterruptedError).count - before).must_be :<=, 1
    ensure
      vm.dispose!
    end

    # A listener that raises unwinds past whatever follows it in the row
    # builder, so the lapse has to be recorded before the listener runs — and
    # it outranks the listener's raise on the way out, or the guest is handed a
    # catchable error to repeat the overrun behind.
    it "reports the logged-value timeout even when the listener raises" do
      vm = Quickjs::VM.new(timeout_msec: 50)
      vm.on_log {|log| raise IOError, 'listener' }
      spinner = "({toString() { const t = Date.now(); while (Date.now() - t < 1000) {}; return 'x' }})"

      _ do
        vm.eval_code("let caught = 0; for (let i = 0; i < 20; i++) { try { console.log(#{spinner}) } catch (e) { caught++ } }; caught")
      end.must_raise Quickjs::InterruptedError
    ensure
      vm.dispose!
    end

    it "hands the listener the timeout that lapsed inside a rejection reason" do
      vm = Quickjs::VM.new(timeout_msec: 50)
      seen = []
      vm.on_unhandled_rejection {|err| seen << err }
      vm.eval_code(<<~JS)
        const e = new Error('r');
        Object.defineProperty(e, 'name', {get() { const t = Date.now(); while (Date.now() - t < 1000) {}; return 'X' }});
        void Promise.reject(e);
      JS

      _(seen.map(&:class)).must_equal [Quickjs::InterruptedError]
    ensure
      vm.dispose!
    end

    # The budget is read off the clock rather than off the thrown error's name
    # and message, both of which a script writes for itself. Recognising it by
    # those strings let a guest relabel its own error as a timeout on a VM with
    # almost its whole budget left, and destroy the real message doing it.
    it "does not take a guest-written InternalError for a lapsed budget" do
      vm = Quickjs::VM.new(timeout_msec: 60_000)

      error = _ do
        vm.eval_code(<<~JS)
          const ev = new Error('nothing was interrupted');
          ev.name = 'InternalError';
          const e = new Error('the real error survives');
          Object.defineProperty(e, 'name', {get() { throw ev }});
          throw e;
        JS
      end.must_raise Quickjs::RuntimeError

      _(error.class).must_equal Quickjs::RuntimeError
      _(error.message).must_match(/the real error survives/)
    ensure
      vm.dispose!
    end

    # Reading name and message off a discarded throw runs that object's getters,
    # and a getter reaching a bridge hands back a Ruby exception the discard has
    # nowhere to put: find_ruby_error is the only thing that takes one out of
    # alive_objects, so it stayed there until dispose!, once per evaluation and
    # at a rate the guest picks. Nothing guest-written runs on that throw now.
    it "runs nothing on a throw it discards, and so pins nothing" do
      marker = Class.new(StandardError)
      calls = 0
      vm = Quickjs::VM.new
      vm.define_function('boom') { calls += 1; raise marker, 'host failure' }
      code = <<~JS
        const ev = new Error('e');
        Object.defineProperty(ev, 'name', {get() { boom() }});
        throw {toString() { throw ev }};
      JS

      3.times { vm.eval_code(code) rescue nil }
      GC.start
      before = ObjectSpace.each_object(marker).count
      200.times { vm.eval_code(code) rescue nil }
      GC.start

      _(calls).must_equal 0
      _(ObjectSpace.each_object(marker).count - before).must_equal 0
    ensure
      vm.dispose!
    end

    it "leaves js_name unset when the name could not be read" do
      vm = Quickjs::VM.new

      error = _ do
        vm.eval_code(<<~JS)
          const e = new Error('the message survives');
          Object.defineProperty(e, 'name', {get() { throw new RangeError('z') }});
          throw e;
        JS
      end.must_raise Quickjs::RuntimeError

      _(error.js_name).must_be_nil
      _(error.message).must_match(/the message survives/)
    ensure
      vm.dispose!
    end

    it "leaves js_name unset on a rejection reason whose name could not be read" do
      vm = Quickjs::VM.new
      captured = []
      vm.on_unhandled_rejection {|err| captured << err }
      vm.eval_code(<<~JS)
        const e = new Error('the reason survives');
        Object.defineProperty(e, 'name', {get() { throw new RangeError('z') }});
        void Promise.reject(e);
      JS

      _(captured.first.js_name).must_be_nil
    ensure
      vm.dispose!
    end

    # The rejection was reportable — only one read of it was not — so the
    # listener hears the host failure rather than nothing at all.
    it "hands the listener a bridge failure met while converting a reason" do
      vm = Quickjs::VM.new
      captured = []
      vm.on_unhandled_rejection {|err| captured << err }
      vm.define_function('boom') { raise IOError, 'host failure' }
      vm.eval_code(<<~JS)
        const e = new Error('r');
        Object.defineProperty(e, 'name', {get() { boom() }});
        void Promise.reject(e);
      JS

      _(captured.size).must_equal 1
      _(captured.first).must_be_kind_of IOError
      _(captured.first.message).must_equal 'host failure'
      _($!).must_be_nil
    ensure
      vm.dispose!
    end

    # rb_protect reports a Ruby `throw` the same way it reports a raise, but
    # errinfo then holds internal throw data rather than an exception, and a
    # listener handed that meets a raw VALUE as "method 'object_id' called on
    # unexpected T_IMEMO". What the block receives has to be an exception on
    # every route into it, whatever the route did on the way.
    it "never hands the listener something that is not an exception" do
      vm = Quickjs::VM.new
      seen = []
      vm.on_unhandled_rejection {|err| seen << err }
      vm.define_function('jump') { throw :out }

      catch(:out) do
        vm.eval_code(<<~JS)
          const e = new Error('r');
          Object.defineProperty(e, 'name', {get() { jump() }});
          void Promise.reject(e);
        JS
      end

      seen.each {|err| _(err).must_be_kind_of Exception }
      _($!).must_be_nil
      _(vm.eval_code('40 + 2')).must_equal 42
    ensure
      vm.dispose!
    end

    it "still drops a raise from the listener itself, having nowhere to put it" do
      vm = Quickjs::VM.new
      vm.on_unhandled_rejection {|err| raise IOError, 'from the listener' }
      vm.eval_code("void Promise.reject(new Error('r'))")

      _($!).must_be_nil
      _(vm.eval_code('40 + 2')).must_equal 42
    ensure
      vm.dispose!
    end
  end

  describe "Dispose" do
# allocate is public on every Ruby class, and an object allocated but never
# initialized still reaches vm_free. That handed js_std_free_handlers a
# runtime whose handlers js_std_init_handlers had never set up, and the
# process died in the GC at exit rather than anywhere a backtrace would
# point at.
it "survives an allocated VM that was never initialized" do
  Quickjs::VM.allocate

  _(Quickjs::VM.new.eval_code('1 + 1')).must_equal 2
end

# initialize writes to the runtime from its second line on, starting with
# JS_SetContextOpaque, and had no disposed check. On a disposed VM that
# dereferenced a context dispose! had already freed, so
# `vm.dispose!; vm.send(:initialize)` took the process down with SIGSEGV
# rather than raising. Private, so it needs send to reach, but reachable.
it "refuses re-initialization of a disposed VM instead of touching the freed context" do
  vm = Quickjs::VM.new
  vm.dispose!

  _ { vm.send(:initialize) }.must_raise Quickjs::RuntimeError
end

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
    # Every wait below is bounded. A runner thread that dies before it reaches
    # the bridge never signals, and an unbounded pop turns that into a six hour
    # CI hang rather than a failure: #82 kills these threads on Linux with a
    # false stack overflow, and the suite sat at the GitHub job limit three
    # times before the cause was visible.
    def await(queue, what)
      queue.pop(timeout: 10) ||
        flunk("timed out waiting for #{what}; a thread likely died before signalling (see #82)")
    end

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
        release.pop(timeout: 30)
        1
      end

      runner = Thread.new { vm.eval_code('pause(); 42') }
      await(entered, "the bridge to be entered")

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
        release.pop(timeout: 30)
        1
      end
      vm.eval_code('globalThis.noop = () => 1')

      runner = Thread.new { vm.eval_code('pause(); 42') }
      await(entered, "the bridge to be entered")

      _ { vm.compile('1 + 1') }.must_raise ThreadError
      _ { vm.call('noop') }.must_raise ThreadError
      _ { vm.drain_jobs! }.must_raise ThreadError
      _ { vm.import('X', from: 'export default 1;') }.must_raise ThreadError
      _ { vm.define_function('another') { 1 } }.must_raise ThreadError
      # Private, so only send reaches it, but every line of it writes to the
      # runtime: a second thread re-running it beside live JS is the same
      # corruption as any other entry.
      _ { vm.send(:initialize) }.must_raise ThreadError
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
        release.pop(timeout: 30)
        1
      end
      vm.eval_code(<<~JS)
        globalThis._lib = {};
        Object.defineProperty(globalThis, 'myLib', { get: () => { gate(); return _lib; } });
        0
      JS

      definer = Thread.new { vm.define_function(%w[myLib hello]) { 42 } }
      await(in_getter, "the path getter to be entered") # inside JS_Eval on the first segment

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
        release.pop(timeout: 30)
        1
      end

      runner = Thread.new { vm.eval_code('pause(); 42') }
      await(entered, "the bridge to be entered")

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
    # A constant here would resolve to ::RUNAWAY and leak onto Object for
    # anything that loads the suite.
    def runaway_js
      'function f(n){ return 1 + f(n + 1); } f(0)'
    end

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

      _ { vm.eval_code(runaway_js) }.must_raise Quickjs::RuntimeError
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
          vm.eval_code(runaway_js)
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
      vm.eval_code(runaway_js)
      nil
    rescue Exception => e
      e
    end
  end.resume

  _(raised).must_be_kind_of Exception
  _(raised).wont_be_kind_of SystemStackError
end

# JS_SetMemoryLimit takes a size_t, but the option was read with NUM2UINT,
# so the ceiling was 4GB and the error naming 'unsigned int' never said
# which option had gone wrong.
it "accepts a memory_limit that does not fit in 32 bits" do
  vm = Quickjs::VM.new(memory_limit: 8 * 1024**3)

  _(vm.memory_usage[:malloc_limit]).must_equal 8 * 1024**3
  _(vm.eval_code('1 + 1')).must_equal 2
end

# NUM2UINT wrapped it to UINT_MAX, so -1 was a silent 4GB cap. QuickJS uses
# -1 for "no limit" itself, which is exactly the confusion to refuse.
it "refuses a negative memory_limit, by name" do
  err = _ { Quickjs::VM.new(memory_limit: -1) }.must_raise ArgumentError

  _(err.message).must_match(/memory_limit/)
end

    # NUM2ULL reads a negative as SIZE_MAX, which puts stack_limit above
    # stack_top and makes every eval raise "stack overflow". Only the headroom
    # clamp hid that, and only where the stack can be measured at all.
    it "refuses a negative max_stack_size" do
      _ { Quickjs::VM.new(max_stack_size: -1) }.must_raise ArgumentError
    end

    # The guard is only observable where the request wins the clamp, which is
    # the main thread: headroom there is far above max_stack_size, so the budget
    # is the request and a nested re-base would restart it from a deeper frame.
    #
    # Asserted through the shape rather than an absolute depth, which is machine
    # specific. Sharing the outermost budget makes the reachable nesting depth
    # scale with the option; restarting it per entry makes the machine stack the
    # only bound, and the depth stops responding to the option at all. Measured
    # while writing this: 22 and 44 with the guard, 1361 and 1361 without it.
    it "makes a nested entry share the outermost budget rather than restart it" do
      reached = lambda do |size|
        vm = Quickjs::VM.new(timeout_msec: 20_000, max_stack_size: size)
        depth = 0
        vm.define_function('again') { depth += 1; vm.eval_code('again()') }
        begin
          vm.eval_code('again()')
        rescue StandardError
          nil
        end
        depth
      end

      small = reached.call(128 * 1024)
      large = reached.call(256 * 1024)

      _(small).must_be :>, 0
      _(large.to_f / small).must_be :>, 1.5
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

    # The negative control. assert_releases_gvl is worth nothing if it passes
    # for work that holds the GVL, and a bridge on the VM takes the GVL-held
    # eval path by construction, since can_eval_gvl_free refuses to release
    # once one is registered. If this ever stops raising, the four tests below
    # have become decorative, which is a thing a measurement cannot report
    # about itself.
    it "reports a workload that holds the GVL" do
      err = with_gvl_held_workload do |held|
        _ { assert_releases_gvl(&held) }.must_raise Minitest::Assertion
      end

      _(err.message).must_match(/not releasing it/)
    end

    it "evaluates pure JS concurrently with measurable speedup" do
      timing_workload = cpu_workload_js

      assert_releases_gvl do |iterations|
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

      assert_releases_gvl do |iterations|
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

      assert_releases_gvl do |iterations|
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
