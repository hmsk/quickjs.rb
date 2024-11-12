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

    test "void (undefined per JSON.stringify) becomes a specific constant" do
      assert_code("() => 'hi'", Quickjs::Value::UNDEFINED)
    end
  end

  class Exceptions < QuickjsTest
    test "throws Quickjs::SyntaxError if SyntaxError happens" do
      err = assert_raises(Quickjs::SyntaxError) { ::Quickjs.eval_code("}{") }
      assert_equal("unexpected token in expression: '}'", err.message)
      assert_equal("SyntaxError", err.js_name)
    end

    test "throws Quickjs::TypeError if TypeError happens" do
      err = assert_raises(Quickjs::TypeError) { ::Quickjs.eval_code("globalThis.func()") }
      assert_equal("not a function", err.message)
      assert_equal("TypeError", err.js_name)
    end

    test "throws Quickjs::ReferenceError if ReferenceError happens" do
      err = assert_raises(Quickjs::ReferenceError) { ::Quickjs.eval_code("let a = undefinedVariable;") }
      assert_equal("'undefinedVariable' is not defined", err.message)
      assert_equal("ReferenceError", err.js_name)
    end

    test "throws Quickjs::RangeError if RangeError happens" do
      err = assert_raises(Quickjs::RangeError) { ::Quickjs.eval_code("throw new RangeError('out of range')") }
      assert_equal("out of range", err.message)
      assert_equal("RangeError", err.js_name)
    end

    test "throws Quickjs::EvalError if EvalError happens" do
      err = assert_raises(Quickjs::EvalError) { ::Quickjs.eval_code("throw new EvalError('I am old')") }
      assert_equal("I am old", err.message)
      assert_equal("EvalError", err.js_name)
    end

    test "throws Quickjs::URIError if URIError happens" do
      err = assert_raises(Quickjs::URIError) { ::Quickjs.eval_code("decodeURIComponent('%')") }
      assert_equal("expecting hex digit", err.message)
      assert_equal("URIError", err.js_name)
    end

    test "throws Quickjs::AggregateError if AggregateError happens" do
      err = assert_raises(Quickjs::AggregateError) { ::Quickjs.eval_code("throw new AggregateError([new Error('some error')], 'aggregated')") }
      assert_equal("aggregated", err.message)
      assert_equal("AggregateError", err.js_name)
    end

    test "throws Quickjs::RuntimeError if custom exception happens" do
      err = assert_raises(Quickjs::RuntimeError) { ::Quickjs.eval_code("class MyError extends Error { constructor(message) { super(message); this.name = 'CustomError'; } }; throw new MyError('my error')") }
      assert_equal("my error", err.message)
      assert_equal("CustomError", err.js_name)
    end

    test "throws is awaited Promise is rejected" do
      err = assert_raises(Quickjs::RuntimeError) do
        ::Quickjs.eval_code("const promise = new Promise((res) => { throw 'asynchronously sad' });await promise")
      end
      assert_equal("asynchronously sad", err.message)
      assert_equal(nil, err.js_name)
    end

    test "throws an exception if promise instance is returned" do
      err = assert_raises(Quickjs::NoAwaitError) do
        ::Quickjs.eval_code("const promise = new Promise((res) => { res('awaited yo') });promise")
      end
      assert_equal("An unawaited Promise was returned to the top-level", err.message)
      assert_equal(nil, err.js_name)
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

      test "returns original exception" do
        @vm.define_function("get_exception") { IOError.new("yo") }

        exception = @vm.eval_code("get_exception()")
        assert_equal(exception.class, IOError)
        assert_equal(exception.message, 'yo')
      end

      test "returns inspected string for otherwise" do
        @vm.define_function("get_class") { Class.new }

        assert_match(/#<Class:/, @vm.eval_code("get_class()"))
      end

      test "global timeout still works" do
        @vm.define_function("infinite") { loop {} }

        assert_raise_with_message(Quickjs::InterruptedError, /Ruby runtime got timeout/) { @vm.eval_code("infinite();") }
      end

      test ":async keyword lets global function be defined as async" do
        @vm.define_function "unblocked", :async do
          'asynchronous return'
        end
        assert_equal(@vm.eval_code("const awaited = await unblocked().then((result) => result + '!'); awaited;"), 'asynchronous return!')
      end

      test "throws an internal error which will be converted to Quickjs::RubyFunctionError in JS world when Ruby function raises" do
        @vm.define_function("errorable") { raise IOError, 'sad error happened within Ruby' }

        assert_raise_with_message(IOError, 'sad error happened within Ruby') { @vm.eval_code("errorable();") }
      end
    end

    class Import < QuickjsVmTest
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

      test "imports named exports from given ESM code as is" do
        @vm.import(['defaultMember', 'member'], from: File.read('./test/fixture.esm.js'))

        assert_equal(@vm.eval_code("defaultMember()"), "I am a default export of ESM.")
        assert_equal(@vm.eval_code("member()"), "I am a exported member of ESM.")
      end

      test "imports named exports from given ESM code with alias" do
        @vm.import({ default: 'aliasedDefault', member: 'aliasedMember' }, from: File.read('./test/fixture.esm.js'))

        assert_equal(@vm.eval_code("aliasedDefault()"), "I am a default export of ESM.")
        assert_equal(@vm.eval_code("aliasedMember()"), "I am a exported member of ESM.")
      end

      test "imports all exports from given ESM code into a single alias" do
        @vm.import('* as all', from: File.read('./test/fixture.esm.js'))

        assert_equal(@vm.eval_code("all.default()"), "I am a default export of ESM.")
        assert_equal(@vm.eval_code("all.defaultMember()"), "I am a default export of ESM.")
        assert_equal(@vm.eval_code("all.member()"), "I am a exported member of ESM.")
      end

      test "imports with implicit default from given ESM code" do
        @vm.import('Imported', from: File.read('./test/fixture.esm.js'))

        assert_equal(@vm.eval_code("Imported()"), "I am a default export of ESM.")
      end

      test "code_to_expose can differentiate the way to globalize" do
        @vm.import('Imported', from: File.read('./test/fixture.esm.js'), code_to_expose: 'globalThis.RenamedImported = Imported;')

        assert_equal(@vm.eval_code('RenamedImported()'), 'I am a default export of ESM.')
        assert_equal(@vm.eval_code('!!globalThis.Imported'), false)
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

      test "can log Promise object as just a string" do
        @vm.eval_code('async function hi() {}')
        @vm.eval_code('console.log("log promise", hi())')

        assert_equal(@vm.logs.last.to_s, ['log promise', '[object Promise]'].join(' '))
        assert_equal(@vm.logs.last.raw, ['log promise', 'Promise'])
      end
    end

    class StackTraces < QuickjsVmTest
      setup { @vm = Quickjs::VM.new }
      teardown { @vm = nil }

      test 'unhandled exception with an Error class should be logged with stack trace' do
        assert_raises(Quickjs::ReferenceError) do
          @vm.eval_code("
            const a = 1;
            const c = 3;
            a + b;
          ")
        end
        assert_equal(@vm.logs.size, 1)
        assert_equal(@vm.logs.last.severity, :error)
        assert_equal(
          @vm.logs.last.raw.first.split("\n"),
          [
            "Uncaught ReferenceError: 'b' is not defined",
            '    at <eval> (<code>:4)'
          ]
        )
      end

      test 'unhandled exception without any Error class should be logged with stack trace' do
        assert_raises(Quickjs::RuntimeError) do
          @vm.eval_code("
            const a = 1;
            throw 'Don\\'t wanna compute at all';
          ")
        end
        assert_equal(@vm.logs.size, 1)
        assert_equal(@vm.logs.last.severity, :error)
        assert_equal(
          @vm.logs.last.raw.first.split("\n"),
          [
            "Uncaught 'Don't wanna compute at all'"
          ]
        )
      end

      test 'should include multi layers of stack trace' do
        @vm.import(['wrapError'], from: File.read('./test/fixture.esm.js'))
        assert_raises(Quickjs::RuntimeError) do
          @vm.eval_code('wrapError();')
        end
        assert_equal(@vm.logs.size, 1)
        assert_equal(@vm.logs.last.severity, :error)
        trace = @vm.logs.last.raw.first.split("\n")
        assert_equal(trace.size, 4)
        assert_equal(trace[0], 'Uncaught Error: unpleasant wrapped error')
        assert_match(/at thrower \(\w{12}:6\)/, trace[1])
        assert_match(/at wrapError \(\w{12}:10\)/, trace[2])
        assert_equal('    at <eval> (<code>)', trace[3])
      end
    end
  end
end
