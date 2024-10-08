# frozen_string_literal: true

require "test_helper"

class QuickjsTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Quickjs.const_defined?(:VERSION)
    end
  end

  def assert_code(code, expected)
    assert_equal(::Quickjs.eval_code(code), expected)
  end

  class ResultConversion < QuickjsTest
    test "null becomes nil" do
      assert_code("null", nil)
    end

    test "undefined becomes a specific constant" do
      assert_code("undefined", Quickjs::Value::UNDEFINED)
      assert_code("const obj = {}; obj.missing;", Quickjs::Value::UNDEFINED)
    end

    test "NaN becomes a specific constant" do
      assert_code("Number('whatever')", Quickjs::Value::NAN)
    end

    test "string becomes String" do
      assert_code("'1'", "1")
      assert_code("const promise = new Promise((res) => { res('awaited yo') });await promise", "awaited yo")
    end

    test "number for integer becomes Integer" do
      assert_code("2+3", 5)
      assert_code("18014398509481982n", 18014398509481982)
    end

    test "number for float becomes Float" do
      assert_code("1.0", 1.0)
      assert_code("2 ** 0.5", 1.4142135623730951)
    end

    test "boolean becomes TruClass/FalseClass" do
      assert_code("false", false)
      assert_code("true", true)
      assert_code("1 === 1", true)
      assert_code("1 == 3", false)
    end

    test "plain k-v object becomes Hash" do
      assert_code("const obj = {}; obj", {})
      assert_code("const obj = { a: '1', b: 1 }; obj;", { 'a' => '1', 'b' => 1 })
    end

    test "plain array object becomes Array" do
      assert_code("[1, 2, 3]", [1, 2, 3])
      assert_code("['a', 2, 'third']", ['a', 2, 'third'])
      assert_code("[1, 2, { 'third': 'sad' }]", [1, 2, { 'third' => 'sad' }])
    end
  end

  class Exceptions < QuickjsTest
    test "throws Quickjs::SyntaxError if SyntaxError happens" do
      assert_raise_with_message(Quickjs::SyntaxError, /unexpected token in/) { ::Quickjs.eval_code("}{") }
    end

    test "throws Quickjs::TypeError if TypeError happens" do
      assert_raise_with_message(Quickjs::TypeError, /not a function/) { ::Quickjs.eval_code("globalThis.func()") }
    end

    test "throws Quickjs::ReferenceError if ReferenceError happens" do
      assert_raise_with_message(Quickjs::ReferenceError, /is not defined/) { ::Quickjs.eval_code("let a = undefinedVariable;") }
    end

    test "throws Quickjs::RangeError if RangeError happens" do
      assert_raise_with_message(Quickjs::RangeError, /out of range/) { ::Quickjs.eval_code("throw new RangeError('out of range')") }
    end

    test "throws Quickjs::EvalError if EvalError happens" do
      assert_raise_with_message(Quickjs::EvalError, /I am old/) { ::Quickjs.eval_code("throw new EvalError('I am old')") }
    end

    test "throws Quickjs::URIError if URIError happens" do
      assert_raise_with_message(Quickjs::URIError, /expecting/) { ::Quickjs.eval_code("decodeURIComponent('%')") }
    end

    test "throws Quickjs::AggregateError if AggregateError happens" do
      assert_raise_with_message(Quickjs::AggregateError, /aggregated/) { ::Quickjs.eval_code("throw new AggregateError([new Error('some error')], 'aggregated')") }
    end

    test "throws is awaited Promise is rejected" do
      assert_raise_with_message(Quickjs::RuntimeError, /asynchronously sad/) do
        ::Quickjs.eval_code("const promise = new Promise((res) => { throw 'asynchronously sad' });await promise")
      end
    end

    test "throws an exception if promise instance is returned" do
      assert_raise_with_message(Quickjs::NoAwaitError, /An unawaited Promise was/) do
        ::Quickjs.eval_code("const promise = new Promise((res) => { res('awaited yo') });promise")
      end
    end
  end

  test "std module can be enabled" do
    assert_code("typeof std === 'undefined'", true)
    assert_equal(::Quickjs.eval_code("!!std.urlGet", { features: [::Quickjs::MODULE_STD] }), true)
  end

  test "os module can be enabled" do
    assert_code("typeof os === 'undefined'", true)
    assert_equal(::Quickjs.eval_code("!!os.kill", { features: [::Quickjs::MODULE_OS] }), true)
  end

  test "js timeout funcs can be injected" do
    assert_code("typeof setTimeout === 'undefined'", true)
    assert_code("typeof clearTimeout === 'undefined'", true)
    assert_equal(::Quickjs.eval_code("!!setTimeout && !!clearTimeout", { features: [::Quickjs::FEATURES_TIMEOUT] }), true)
  end

  class QuickjsVmTest < Test::Unit::TestCase
    class WithPlainVM < QuickjsVmTest
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

      test "maintains the same context within a vm" do
        @vm.eval_code('const a = { b: "c" };')
        assert_equal(@vm.eval_code('a.b'), "c")
        @vm.eval_code('a.b = "d"')
        assert_equal(@vm.eval_code('a.b'), "d")
      end

      test "does not enable std/os module as default" do
        assert_equal(@vm.eval_code("typeof std === 'undefined'"), true)
        assert_equal(@vm.eval_code("typeof os === 'undefined'"), true)
      end

      test "does not have std helpers" do
        assert_equal(@vm.eval_code("typeof __loadScript === 'undefined'"), true)
        assert_equal(@vm.eval_code("typeof scriptArgs === 'undefined'"), true)
        assert_equal(@vm.eval_code("typeof print === 'undefined'"), true)
      end
    end

    test "accepts some options to constrain its resource" do
      vm = Quickjs::VM.new(
        memory_limit: 1024 * 1024,
        max_stack_size: 1024 * 1024,
      )
      assert_equal(vm.eval_code('1+2'), 3)
    end

    test "enables std module via features option" do
      vm = Quickjs::VM.new(
        features: [::Quickjs::MODULE_STD],
      )
      assert_equal(vm.eval_code("!!std.urlGet"), true)
    end

    test "enables os module via features option" do
      vm = Quickjs::VM.new(
        features: [::Quickjs::MODULE_OS],
      )
      assert_equal(vm.eval_code("!!os.kill"), true)
    end

    test "gets timeout from evaluation" do
      vm = Quickjs::VM.new

      assert_raise_with_message(Quickjs::InterruptedError, /timeout/) { vm.eval_code("while(1) {}") }
    end

    test "accepts timeout_msec option to control maximum evaluation time" do
      vm = Quickjs::VM.new(timeout_msec: 200)

      started = Time.now.to_f * 1000
      assert_raise_with_message(Quickjs::InterruptedError, /timeout/) { vm.eval_code("while(1) {}") }
      assert_in_delta(started + 200, Time.now.to_f * 1000, 10) # within 10 msec
    end

    test "can enable setTimeout selectively" do
      pend "should timeout"
      vm = Quickjs::VM.new(features: [::Quickjs::MODULE_OS])
      vm.eval_code('const longProcess = () => { const pro = new Promise((res) => os.setTimeout(() => res(), 5000)); return pro; }')

      assert_raise_with_message(Quickjs::InterruptedError, /timeout/) { vm.eval_code("await longProcess()") }
    end

    class GlobalFunction < QuickjsVmTest
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

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
      ].each do |test_case, i|
        test "define_function #{test_case[:subject]}" do
          @vm.define_function(test_case[:js].scan(/(.+)\(.+$/).first.first, &test_case[:defined_function])
          assert_equal(@vm.eval_code(test_case[:js]), test_case[:result])
        end
      end

      [
        ["'symsym'", :symsym],
        ["null", nil],
        ["3", 3],
        ["3.14", 3.14],
        ["true", true],
        ["false", false],
      ].each do |js, ruby|
        test "retuned {ruby} by Ruby is #{js} in VM" do
          @vm.define_function("get_ret") { ruby }
          assert_equal(@vm.eval_code("get_ret() === #{js}"), true)
        end
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

      test "global timeout still works" do
        @vm.define_function("infinite") { loop {} }
        assert_raise_with_message(Quickjs::InterruptedError, /Ruby runtime got timeout/) { @vm.eval_code("infinite();") }
      end
    end

    class GlobalFunction < QuickjsVmTest
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

      test "imports from given ESM code" do
        @vm.import("fixture", from: File.read('./test/fixture.esm.js'))

        assert_equal(@vm.eval_code("fixture.default()"), "I am a default export of ESM.")
        assert_equal(@vm.eval_code("fixture.member()"), "I am a exported member of ESM.")
      end
    end

    class ConsoleLoggers < QuickjsVmTest
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

      test "there are functions for some severities" do
        @vm.eval_code('console.log("log it")')
        assert_equal(@vm.logs.last.severity, :info)
        assert_equal(@vm.logs.last.to_s, 'log it')

        @vm.eval_code('console.info("info it")')
        assert_equal(@vm.logs.last.severity, :info)
        assert_equal(@vm.logs.last.to_s, 'info it')

        @vm.eval_code('console.debug("debug it")')
        assert_equal(@vm.logs.last.severity, :verbose)
        assert_equal(@vm.logs.last.to_s, 'debug it')

        @vm.eval_code('console.warn("warn it")')
        assert_equal(@vm.logs.last.severity, :warning)
        assert_equal(@vm.logs.last.to_s, 'warn it')

        @vm.eval_code('console.error("error it")')
        assert_equal(@vm.logs.last.severity, :error)
        assert_equal(@vm.logs.last.to_s, 'error it')

        assert_equal(@vm.logs.size, 5)
      end

      test "can give multiple arguments" do
        @vm.eval_code('const variable = "var!";')
        @vm.eval_code('console.log(128, "str", variable, undefined, null, { key: "value" }, [1, 2, 3])')

        assert_equal(@vm.logs.last.to_s, [
          "128", "str", "var!", "undefined", "null", "[object Object]", "1,2,3"
        ].join(' '))
      end

      test "can give converted given data as 'raw'" do
        @vm.eval_code('const variable = "var!";')
        @vm.eval_code('console.log(128, "str", variable, undefined, null, { key: "value" }, [1, 2, 3])')

        assert_equal(@vm.logs.last.raw, [
          128, "str", "var!", Quickjs::Value::UNDEFINED, nil, { "key" => "value" }, [1,2,3]
        ])
      end
    end
  end
end
