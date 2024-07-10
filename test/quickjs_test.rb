# frozen_string_literal: true

require "test_helper"

class QuickjsTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Quickjs.const_defined?(:VERSION)
    end
  end

  test "throw an exception" do
    assert_raise_with_message(RuntimeError, /SyntaxError:/) { ::Quickjs.eval_code("}{") }
  end

  test "support returning null" do
    assert_equal(::Quickjs.eval_code("null"), nil)
    assert_equal(::Quickjs.eval_code("const func = () => null; func();"), nil)
  end

  test "support returning undefined" do
    assert_equal(::Quickjs.eval_code("undefined"), Quickjs::Value::UNDEFINED)
    assert_equal(::Quickjs.eval_code("const obj = {}; obj.key;"), Quickjs::Value::UNDEFINED)
  end

  test "support returning NaN" do
    assert_equal(::Quickjs.eval_code("Number('whatever')"), Quickjs::Value::NAN)
  end

  test "support returning string" do
    assert_equal(::Quickjs.eval_code("'1'"), "1")
    assert_equal(::Quickjs.eval_code("const func = () => 'hello'; func();"), "hello")
  end

  test "support returning integer" do
    assert_equal(::Quickjs.eval_code("2+3"), 5)
    assert_equal(::Quickjs.eval_code("const func = () => 8; func();"), 8)
    assert_equal(::Quickjs.eval_code("18014398509481982n"), 18014398509481982)
  end

  test "support returning float" do
    assert_equal(::Quickjs.eval_code("1.0"), 1.0)
    assert_equal(::Quickjs.eval_code("2 ** 0.5"), 1.4142135623730951)
  end

  test "support returning boolean" do
    assert_equal(::Quickjs.eval_code("false"), false)
    assert_equal(::Quickjs.eval_code("true"), true)
    assert_equal(::Quickjs.eval_code("const func = () => 1 == 1; func();"), true)
    assert_equal(::Quickjs.eval_code("const func = () => 1 == 3; func();"), false)
  end

  test "support returning plain object/array" do
    assert_equal(::Quickjs.eval_code("const func = () => ({ a: '1', b: 1 }); func();"), { 'a' => '1', 'b' => 1 })
    assert_equal(::Quickjs.eval_code("const func = () => ({ funcCantRemain: () => {} }); func();"), {})
    assert_equal(::Quickjs.eval_code("[1,2,3]"), [1,2,3])
  end

  test "support returning Promise (resolved) with awaiting result automatically" do
    assert_equal(::Quickjs.eval_code("const promise = new Promise((res) => { res('awaited yo') });promise"), "awaited yo")
  end

  test "support returning Promise (rejected) with awaiting result automatically" do
    assert_raise_with_message(RuntimeError, /asynchronously sad/) do
      ::Quickjs.eval_code("const promise = new Promise((res) => { throw 'asynchronously sad' });promise")
    end
  end

  test "std is disabled" do
    assert_equal(::Quickjs.eval_code("typeof std === 'undefined'"), true)
  end

  test "os is disabled" do
    assert_equal(::Quickjs.eval_code("typeof os === 'undefined'"), true)
  end

  test "std can be enabled" do
    assert_equal(::Quickjs.eval_code("!!std.urlGet", { features: [::Quickjs::MODULE_STD] }), true)
  end

  test "os can be enabled" do
    assert_equal(::Quickjs.eval_code("!!os.kill", { features: [::Quickjs::MODULE_OS] }), true)
  end

  class QuickjsTestVm < Test::Unit::TestCase
    class WithPlainVM < QuickjsTestVm
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

      test "VM maintains runtime and context" do
        @vm.eval_code('const a = { b: "c" };')
        assert_equal(@vm.eval_code('a.b'), "c")
        @vm.eval_code('a.b = "d"')
        assert_equal(@vm.eval_code('a.b'), "d")
      end

      test "VM doesn't eval codes anymore after disposing" do
        @vm.eval_code('const a = { b: "c" };')
        @vm.dispose!
        assert_raise_with_message(RuntimeError, /disposed/) { @vm.eval_code('a.b = "d"') }
      end

      test "VM does not enable std features as default" do
        assert_equal(@vm.eval_code("typeof std === 'undefined'"), true)
      end

      test "VM does not enable os features as default" do
        assert_equal(@vm.eval_code("typeof os === 'undefined'"), true)
      end
    end

    test "VM accepts some options to constrain its resource" do
      vm = Quickjs::VM.new(
        memory_limit: 1024 * 1024,
        max_stack_size: 1024 * 1024,
      )
      assert_equal(vm.eval_code('1+2'), 3)
    end

    test "VM enables std feature" do
      vm = Quickjs::VM.new(
        features: [::Quickjs::MODULE_STD],
      )
      assert_equal(vm.eval_code("!!std.urlGet"), true)
    end

    test "VM enables os feature" do
      vm = Quickjs::VM.new(
        features: [::Quickjs::MODULE_OS],
      )
      assert_equal(vm.eval_code("!!os.kill"), true)
    end

    test "gets timeout" do
      vm = Quickjs::VM.new

      assert_raise_with_message(RuntimeError, /interrupted/) { vm.eval_code("while(1) {}") }
    end

    test "VM accepts timeout_msec to control maximum evaluation time" do
      vm = Quickjs::VM.new(timeout_msec: 200)

      started = Time.now.to_f * 1000
      assert_raise_with_message(RuntimeError, /interrupted/) { vm.eval_code("while(1) {}") }
      assert_in_delta(started + 200, Time.now.to_f * 1000, 5) # within 5 msec
    end

    class GlobalFunction < QuickjsTestVm
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

      test "define global function that accepts no args" do
        @vm.define_function("callRuby") do
          ['Message', 'from', 'Ruby'].join(' ')
        end

        assert_equal(@vm.eval_code("callRuby()"), 'Message from Ruby')
      end

      test "define global function that accepts an arg" do
        @vm.define_function("greetingTo") do |arg1|
          ['Hello!', arg1].join(' ')
        end

        assert_equal(@vm.eval_code("greetingTo('Rick')"), 'Hello! Rick')
      end

      test "define global function that accepts two args" do
        @vm.define_function("concat") do |arg1, arg2|
          "#{arg1}#{arg2}"
        end

        assert_equal(@vm.eval_code("concat('Ri', 'ck')"), 'Rick')
      end

      test "define global function that accepts many args" do
        @vm.define_function("buildCSV") do |arg1, arg2, arg3, arg4|
          [arg1, arg2, arg3, arg4].join(' ')
        end

        assert_equal(@vm.eval_code("buildCSV('R', 'i', 'c', 'k')"), 'R i c k')
      end

      test "define global function that accepts many args including an optional one" do
        @vm.define_function("callName") do |arg1, arg2, arg3, arg4, arg5 = 'Song'|
          [arg1, arg2, arg3, arg4].join('') + ' ' + arg5
        end

        assert_equal(@vm.eval_code("callName('R', 'i', 'c', 'k')"), 'Rick Song')
      end

      test "returns symbol as string" do
        @vm.define_function("get_sym") { :symsym }

        assert_equal(@vm.eval_code("get_sym() === 'symsym'"), true)
      end

      test "returns nil as null" do
        @vm.define_function("get_nil") { nil }

        assert_equal(@vm.eval_code("get_nil() === null"), true)
      end

      test "returns fixnum as number" do
        @vm.define_function("get_fixnum") { 3 }

        assert_equal(@vm.eval_code("get_fixnum() === 3"), true)
      end

      test "returns float as number" do
        @vm.define_function("get_float") { 3.14 }

        assert_equal(@vm.eval_code("get_float() === 3.14"), true)
      end

      test "returns true as is" do
        @vm.define_function("get_true") { true }

        assert_equal(@vm.eval_code("get_true() === true"), true)
      end

      test "returns false as is" do
        @vm.define_function("get_false") { false }

        assert_equal(@vm.eval_code("get_false() === false"), true)
      end

      test "returns array as is if serializable" do
        @vm.define_function("get_array") { [1, '2'] }

        assert_equal(@vm.eval_code("get_array()"), [1, '2'])
      end

      test "returns hash as is (ish) if serializable" do
        @vm.define_function("get_obj") { { a: 1 } }

        assert_equal(@vm.eval_code("get_obj()"), { 'a' => 1 })
      end

      test "returns inspected string for otherwise" do
        @vm.define_function("get_class") { Class.new }

        assert_match(/#<Class:/, @vm.eval_code("get_class()"))
      end
    end
  end
end
