# frozen_string_literal: true

require "test_helper"

describe "VM#define_const / #define_let / #define_var" do
  before do
    @vm = Quickjs::VM.new
  end

  after do
    @vm.dispose!
  end

  describe "binding forms" do
    it "exposes a const to later eval_code" do
      @vm.define_const(:user, {name: "Itadori"})

      _(@vm.eval_code("user.name")).must_equal "Itadori"
    end

    it "makes a const read-only for JS" do
      @vm.define_const(:user, 1)

      _ { @vm.eval_code("user = 2;") }.must_raise Quickjs::TypeError
    end

    it "makes a const collide loudly with a redeclaration in user code" do
      @vm.define_const(:user, 1)

      _ { @vm.eval_code("let user = 2;") }.must_raise Quickjs::SyntaxError
    end

    it "lets JS reassign a let" do
      @vm.define_let(:counter, 1)

      _(@vm.eval_code("counter = 2; counter")).must_equal 2
    end

    it "keeps a let off globalThis" do
      @vm.define_let(:counter, 1)

      _(@vm.eval_code("typeof globalThis.counter")).must_equal "undefined"
    end

    it "puts a var on globalThis" do
      @vm.define_var(:APP_CONFIG, {retries: 3})

      _(@vm.eval_code("globalThis.APP_CONFIG.retries")).must_equal 3
    end
  end

  describe "redefinition" do
    it "refuses to redefine a const" do
      @vm.define_const(:user, 1)

      error = _ { @vm.define_const(:user, 2) }.must_raise ArgumentError
      _(error.message).must_match(/already defined as a const/)
      _(@vm.eval_code("user")).must_equal 1
    end

    it "assigns when a let is defined again" do
      @vm.define_let(:counter, 1)
      @vm.define_let(:counter, 2)

      _(@vm.eval_code("counter")).must_equal 2
    end

    it "assigns when a var is defined again" do
      @vm.define_var(:config, {a: 1})
      @vm.define_var(:config, {a: 2})

      _(@vm.eval_code("globalThis.config.a")).must_equal 2
    end

    it "refuses to change the binding form of an existing name" do
      @vm.define_let(:counter, 1)

      error = _ { @vm.define_var(:counter, 2) }.must_raise ArgumentError
      _(error.message).must_match(/already defined as a let/)
    end
  end

  describe "name validation" do
    it "accepts a String as well as a Symbol" do
      @vm.define_const("user", 1)

      _(@vm.eval_code("user")).must_equal 1
    end

    it "returns the name as a Symbol" do
      _(@vm.define_const("user", 1)).must_equal :user
    end

    it "rejects a name that is not a String or Symbol" do
      _ { @vm.define_const(1, 2) }.must_raise TypeError
    end

    it "rejects a name that is not a valid identifier" do
      error = _ { @vm.define_const("a-b", 1) }.must_raise ArgumentError
      _(error.message).must_match(/not a valid JavaScript identifier/)
    end

    it "rejects a reserved word" do
      error = _ { @vm.define_const("class", 1) }.must_raise ArgumentError
      _(error.message).must_match(/reserved word/)
    end

    it "refuses to let a name smuggle in JavaScript" do
      _ {
        @vm.define_const("x = 1; globalThis.pwned = 1; //", 2)
      }.must_raise ArgumentError

      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
    end

    it "allows $ and _ as identifier characters" do
      @vm.define_const(:$_x1, 1)

      _(@vm.eval_code("$_x1")).must_equal 1
    end
  end

  describe "value conversion" do
    it "converts primitives" do
      @vm.define_const(:values, [nil, true, false, 1, 1.5, "s"])

      _(@vm.eval_code("JSON.stringify(values)")).must_equal '[null,true,false,1,1.5,"s"]'
    end

    it "converts nested structures" do
      @vm.define_const(:user, {name: "Itadori", tags: ["strong", "kind"]})

      _(@vm.eval_code("user.name + ': ' + user.tags.join(', ')")).must_equal "Itadori: strong, kind"
    end

    it "converts symbol values to strings" do
      @vm.define_const(:role, :admin)

      _(@vm.eval_code("role")).must_equal "admin"
    end

    it "converts Quickjs::Value::UNDEFINED" do
      @vm.define_const(:nothing, Quickjs::Value::UNDEFINED)

      _(@vm.eval_code("typeof nothing")).must_equal "undefined"
    end

    it "converts Quickjs::Value::NAN" do
      @vm.define_const(:notnum, Quickjs::Value::NAN)

      _(@vm.eval_code("Number.isNaN(notnum)")).must_equal true
    end

    it "converts non-finite floats" do
      @vm.define_const(:inf, Float::INFINITY)
      @vm.define_const(:neg, -Float::INFINITY)
      @vm.define_const(:nan, Float::NAN)

      _(@vm.eval_code("[inf, neg, Number.isNaN(nan)]")).must_equal [Float::INFINITY, -Float::INFINITY, true]
    end

    it "converts integer object keys" do
      @vm.define_const(:by_id, {1 => "one"})

      _(@vm.eval_code("by_id['1']")).must_equal "one"
    end

    it "escapes strings rather than splicing them" do
      @vm.define_const(:sneaky, '"; globalThis.pwned = 1; //')

      _(@vm.eval_code("typeof globalThis.pwned")).must_equal "undefined"
      _(@vm.eval_code("sneaky")).must_equal '"; globalThis.pwned = 1; //'
    end

    it "raises on a value it cannot represent" do
      error = _ { @vm.define_const(:at, Time.now) }.must_raise TypeError
      _(error.message).must_match(/cannot be converted/)
    end

    it "raises on an unrepresentable value nested in a structure" do
      _ { @vm.define_const(:wrapper, {at: Time.now}) }.must_raise TypeError
    end

    it "raises on an unusable object key" do
      _ { @vm.define_const(:bad, {[1] => "x"}) }.must_raise TypeError
    end

    it "raises on a circular structure" do
      circular = {}
      circular[:self] = circular

      error = _ { @vm.define_const(:loop, circular) }.must_raise ArgumentError
      _(error.message).must_match(/circular/)
    end

    it "allows the same object to appear twice without calling it circular" do
      shared = {n: 1}
      @vm.define_const(:pair, [shared, shared])

      _(@vm.eval_code("pair[0].n + pair[1].n")).must_equal 2
    end
  end

  describe "interaction with eval_code" do
    it "leaves the caller's line numbers untouched" do
      @vm.define_const(:cfg, 1)

      error = _ {
        @vm.eval_code("\nthrow new Error('boom');", filename: "app.js")
      }.must_raise Quickjs::RuntimeError

      _(error.backtrace.first).must_match(/app\.js:2/)
    end

    it "is visible to a function defined with define_function" do
      @vm.define_const(:factor, 3)
      @vm.define_function("scale") { |n| n }

      _(@vm.eval_code("scale(2) * factor")).must_equal 6
    end
  end

  # Injecting configuration and then importing a module that reads it is the
  # obvious pairing, and a declaration reaching module scope isn't obvious
  # from either feature on its own: a module has its own scope, and only
  # `var` lands on `globalThis`.
  describe "interaction with modules" do
    it "exposes a const to an imported module" do
      @vm.define_const(:injected, "from-ruby")
      @vm.import(["read"], from: Quickjs.compile_module("export const read = () => injected;"))

      _(@vm.eval_code("read()")).must_equal "from-ruby"
    end

    it "exposes a var to an imported module through globalThis" do
      @vm.define_var(:injectedVar, "from-ruby-var")
      @vm.import(["read"], from: Quickjs.compile_module("export const read = () => globalThis.injectedVar;"))

      _(@vm.eval_code("read()")).must_equal "from-ruby-var"
    end

    # The module body evaluates at import time, before this name exists, so
    # this only works because the binding is resolved when `read` is called.
    it "exposes a const defined after the module was imported" do
      @vm.import(["read"], from: Quickjs.compile_module("export const read = () => later;"))
      @vm.define_const(:later, "defined-after")

      _(@vm.eval_code("read()")).must_equal "defined-after"
    end

    it "is visible to a Runnable executed on the same VM" do
      @vm.define_const(:fromRuby, "visible")
      Quickjs.compile("globalThis.seen = fromRuby;").run(on: @vm)

      _(@vm.eval_code("seen")).must_equal "visible"
    end
  end
describe "define_var onto a global that is already there" do
  # var is the only form that lands on globalThis, so it is the only one an
  # existing property can intercept. Both of these used to report success:
  # the accessor took the value in its setter and handed JS back whatever
  # its getter liked, and the non-writable property discarded the
  # assignment silently, because a declaration eval is sloppy mode.
  it "refuses a global that is an accessor, without handing it the value" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      Object.defineProperty(globalThis, 'CONFIG', {
        configurable: true,
        set(v) { globalThis.captured = JSON.stringify(v); },
        get() { return 'guest'; }
      });
    JS

    err = _ { vm.define_var(:CONFIG, { secret: 'value' }) }.must_raise ArgumentError

    _(err.message).must_match(/accessor/)
    _(vm.eval_code('globalThis.captured')).must_equal Quickjs::Value::UNDEFINED
  end

  it "refuses a global that is not writable" do
    vm = Quickjs::VM.new
    vm.eval_code("Object.defineProperty(globalThis, 'LOCKED', { value: 'theirs', writable: false });")

    err = _ { vm.define_var(:LOCKED, 'mine') }.must_raise ArgumentError

    _(err.message).must_match(/not writable/)
    _(vm.eval_code('globalThis.LOCKED')).must_equal 'theirs'
  end

  it "still defines over an ordinary global" do
    vm = Quickjs::VM.new
    vm.eval_code('globalThis.plain = 1;')

    _(vm.define_var(:plain, 42)).must_equal :plain
    _(vm.eval_code('plain')).must_equal 42
  end

  # Neither lexical form touches globalThis, so an accessor there cannot see
  # the value or change what the name resolves to.
  it "leaves const and let alone" do
    vm = Quickjs::VM.new
    vm.eval_code(<<~JS)
      Object.defineProperty(globalThis, 'K', {
        configurable: true, set(v) { globalThis.seen = true; }, get() { return 'guest'; }
      });
    JS

    vm.define_const(:K, 'mine')

    _(vm.eval_code('K')).must_equal 'mine'
    _(vm.eval_code('globalThis.seen')).must_equal Quickjs::Value::UNDEFINED
  end
end

end
