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

    it "void (undefined per JSON.stringify) becomes a specific constant" do
      assert_code("() => 'hi'", Quickjs::Value::UNDEFINED)
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

  describe "PolyfillIntl" do
    before do
      @options_to_enable_polyfill = { features: [::Quickjs::POLYFILL_INTL] }
    end

    it "Intl.DateTimeFormat polyfill is provided by the feature" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'UTC', timeStyle: 'long', dateStyle: 'short' })"

      _(::Quickjs.eval_code(code)).must_match(/^03\/1(1|0)\/2025,\s/)
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '3/10/25, 3:00:00 PM UTC'
    end

    it "Intl.DateTimeFormat polyfill is a bit diff from common behavior for default options" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'America/Los_Angeles' })"

      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal '3/10/2025'
    end

    it "Intl.DateTimeFormat polyfill is a bit diff from common behavior for delimiter of time format" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'America/Los_Angeles', timeStyle: 'long', dateStyle: 'long' })"

      _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal 'March 10, 2025, 8:00:00 AM PDT'
    end

    it "Intl.Locale polyfill is provided" do
      code = 'new Intl.Locale("ja-Jpan-JP-u-ca-japanese-hc-h12").toString()'

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal 'ja-Jpan-JP-u-ca-japanese-hc-h12'
    end

    it "Intl.PluralRules polyfill is provided" do
      code = 'new Intl.PluralRules("en-US").select(1);'

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal 'one'
    end

    it "Intl.NumberFormat polyfill is provided" do
      code = "new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(12345)"

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal '$12,345.00'
    end
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
      @vm.eval_code('a.b = "d"')
      _(@vm.eval_code('a.b')).must_equal "d"
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
    assert_in_delta(started + 200, Time.now.to_f * 1000, 10)
  end

  it "can enable setTimeout selectively" do
    skip "should timeout"
    vm = Quickjs::VM.new(features: [::Quickjs::MODULE_OS])
    vm.eval_code('const longProcess = () => { const pro = new Promise((res) => os.setTimeout(() => res(), 5000)); return pro; }')

    _ { vm.eval_code("await longProcess()") }.must_raise Quickjs::InterruptedError
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

    it "function's name can't be others than a symbol nor a string" do
      err = _ {
        @vm.define_function([:sym_in_ary]) { 'never reach' }
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

    it "returns hash as is (ish) if serializable" do
      @vm.define_function("get_obj") { { a: 1 } }
      _(@vm.eval_code("get_obj()")).must_equal({ 'a' => 1 })
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

    it "imports a script which throws error result raising an exception" do
      _ {
        @vm.import('* as all', from: 'should be syntax error')
      }.must_raise Quickjs::SyntaxError
    end
  end

  describe "ConsoleLoggers" do
    before do
      @vm = Quickjs::VM.new
    end

    it "there are functions for some severities" do
      @vm.eval_code('console.log("log it")')
      _(@vm.logs.last.severity).must_equal :info
      _(@vm.logs.last.to_s).must_equal 'log it'

      @vm.eval_code('console.info("info it")')
      _(@vm.logs.last.severity).must_equal :info
      _(@vm.logs.last.to_s).must_equal 'info it'

      @vm.eval_code('console.debug("debug it")')
      _(@vm.logs.last.severity).must_equal :verbose
      _(@vm.logs.last.to_s).must_equal 'debug it'

      @vm.eval_code('console.warn("warn it")')
      _(@vm.logs.last.severity).must_equal :warning
      _(@vm.logs.last.to_s).must_equal 'warn it'

      @vm.eval_code('console.error("error it")')
      _(@vm.logs.last.severity).must_equal :error
      _(@vm.logs.last.to_s).must_equal 'error it'

      _(@vm.logs.size).must_equal 5
    end

    it "can give multiple arguments" do
      @vm.eval_code('const variable = "var!";')
      @vm.eval_code('console.log(128, "str", variable, undefined, null, { key: "value" }, [1, 2, 3], new Error("hey"))')

      _(@vm.logs.last.to_s).must_equal [
        "128", "str", "var!", "undefined", "null", "[object Object]", "1,2,3", "Error: hey"
      ].join(' ')
    end

    it "can give converted given data as 'raw'" do
      @vm.eval_code('const variable = "var!";')
      @vm.eval_code('console.log(128, "str", variable, undefined, null, { key: "value" }, [1, 2, 3], new Error("hey"))')

      _(@vm.logs.last.raw).must_equal [
        128, "str", "var!", Quickjs::Value::UNDEFINED, nil, { "key" => "value" }, [1,2,3], "Error: hey\n    at <eval> (<code>:1:90)\n"
      ]
    end

    it "can log Promise object as just a string" do
      @vm.eval_code('async function hi() {}')
      @vm.eval_code('console.log("log promise", hi())')

      _(@vm.logs.last.to_s).must_equal ['log promise', '[object Promise]'].join(' ')
      _(@vm.logs.last.raw).must_equal ['log promise', 'Promise']
    end

    it "can log exception instance from Ruby like JS Error" do
      @vm.define_function("get_exception") { raise IOError.new("io") }
      @vm.eval_code('try { get_exception() } catch (e) { console.log(e) }')

      _(@vm.logs.last.to_s).must_equal 'Error: io'
      _(@vm.logs.last.raw).must_equal ["Error: io\n    at <eval> (<code>:1:20)\n"]
    end

    it "implemented as native code" do
      _(@vm.eval_code('console.log.toString()')).must_match(/native code/)
    end
  end

  describe "StackTraces" do
    before do
      @vm = Quickjs::VM.new
    end

    it "unhandled exception with an Error class should be logged with stack trace" do
      _ {
        @vm.eval_code(<<~JS)
          const a = 1;
          const c = 3;
          a + b;
        JS
      }.must_raise Quickjs::ReferenceError
      _(@vm.logs.size).must_equal 1
      _(@vm.logs.last.severity).must_equal :error
      _(@vm.logs.last.raw.first.split("\n")).must_equal [
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
      _(@vm.logs.size).must_equal 1
      _(@vm.logs.last.severity).must_equal :error
      _(@vm.logs.last.raw.first.split("\n")).must_equal [
        "Uncaught 'Don't wanna compute at all'"
      ]
    end

    it "should include multi layers of stack trace" do
      @vm.import(['wrapError'], from: File.read('./test/fixture.esm.js'))
      _ {
        @vm.eval_code('wrapError();')
      }.must_raise Quickjs::RuntimeError
      _(@vm.logs.size).must_equal 1
      _(@vm.logs.last.severity).must_equal :error
      trace = @vm.logs.last.raw.first.split("\n")
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

  def refute_sleep_a_sec_within_thread(&block)
    _(run_threads(&block)).wont_equal %w(t1 t1 t1 t2)
  end

  def pend_on_ubuntu
    skip('unresolved stack overflow on Ubuntu of GitHub Actions') unless RUBY_PLATFORM.match(/darwin/)
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
      pend_on_ubuntu
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

    it "os sleep messes" do
      pend_on_ubuntu
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('os.sleep(200);')
      end
    end

    it "awaiting os.setTimeout messes" do
      pend_on_ubuntu
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('await new Promise(resolve => os.setTimeout(resolve, 200));')
      end
    end

    it "awaiting async function which wraps os.setTimeout messes" do
      pend_on_ubuntu
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await new Promise(resolve => os.setTimeout(resolve, 200)); } await top();')
      end
    end

    it "awaiting os.sleepAsync messes" do
      pend_on_ubuntu
      refute_sleep_a_sec_within_thread do
        @vm.eval_code('async function top () { await os.sleepAsync(200); } await top();')
      end
    end
  end

  describe "RubyBasedTimeout" do
    before do
      @vm = Quickjs::VM.new(timeout_msec: 500, features: [::Quickjs::FEATURE_TIMEOUT])
    end

    it "awaiting setTimeout does not block other threads" do
      pend_on_ubuntu
      assert_sleep_a_sec_within_thread do
        @vm.eval_code('await new Promise(resolve => setTimeout(resolve, 200));')
      end
    end
  end
end
