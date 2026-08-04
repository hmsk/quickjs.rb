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
end
