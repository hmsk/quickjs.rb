# frozen_string_literal: true

require_relative "test_helper"

describe "Quickjs.compile_module" do
  it "is importable into a VM" do
    lib = Quickjs.compile_module('export const greet = () => "hello";')
    vm = Quickjs::VM.new
    vm.import(['greet'], from: lib)

    _(vm.eval_code('greet()')).must_equal 'hello'
  end

  it "imports into any number of VMs without recompiling" do
    lib = Quickjs.compile_module('export const greet = () => "hello";')

    3.times do
      vm = Quickjs::VM.new
      vm.import(['greet'], from: lib)
      _(vm.eval_code('greet()')).must_equal 'hello'
      vm.dispose!
    end
  end

  it "gives each VM its own instance of the module" do
    counter = Quickjs.compile_module("const s = { n: 0 };\nexport const inc = () => ++s.n;")

    vm1 = Quickjs::VM.new
    vm1.import(['inc'], from: counter)
    vm2 = Quickjs::VM.new
    vm2.import(['inc'], from: counter)

    _(vm1.eval_code('inc()')).must_equal 1
    _(vm1.eval_code('inc()')).must_equal 2
    _(vm2.eval_code('inc()')).must_equal 1
  end

  it "supports the same import shapes as an inline source" do
    lib = Quickjs.compile_module('export default { v: "def" };
export const member = () => "mem";')

    vm = Quickjs::VM.new
    vm.import({default: 'aliased', member: 'member'}, from: lib)

    _(vm.eval_code('aliased.v')).must_equal 'def'
    _(vm.eval_code('member()')).must_equal 'mem'
  end

  it "honors code_to_expose:" do
    lib = Quickjs.compile_module('export const value = () => "renamed";')
    vm = Quickjs::VM.new
    vm.import(['value'], from: lib, code_to_expose: 'globalThis.custom = value;')

    _(vm.eval_code('custom()')).must_equal 'renamed'
    _(vm.eval_code('typeof globalThis.value')).must_equal 'undefined'
  end

  # Each import compiles a small bridge module, so a repeat import is never
  # free. What must not repeat is reading the module itself, so the module is
  # made large enough here that a second read would dwarf the bridge.
  it "reads the bytecode only once when imported repeatedly into one VM" do
    body = Array.new(200) { |i| "export const fn#{i} = (a) => a + #{i};" }.join("\n")
    lib = Quickjs.compile_module(body)
    vm = Quickjs::VM.new

    before = vm.memory_usage[:js_func_code_size]
    vm.import(['fn0'], from: lib)
    first = vm.memory_usage[:js_func_code_size] - before
    vm.import(['fn1'], from: lib)
    second = vm.memory_usage[:js_func_code_size] - before - first

    _(second).must_be :<, first / 10
  end

  # The reason to generate the name rather than take one: two gems that both
  # ship a 'lib.js' must not collide in a VM that imports both.
  it "never collides with another Importable built from the same filename" do
    one = Quickjs.compile_module('export const which = () => "one";', filename: 'lib.js')
    two = Quickjs.compile_module('export const which = () => "two";', filename: 'lib.js')

    _(one.name).wont_equal two.name

    vm = Quickjs::VM.new
    vm.import({which: 'whichOne'}, from: one)
    vm.import({which: 'whichTwo'}, from: two)

    _(vm.eval_code('whichOne()')).must_equal 'one'
    _(vm.eval_code('whichTwo()')).must_equal 'two'
  end

  it "puts filename: in the module name for stack traces" do
    lib = Quickjs.compile_module('export const boom = () => { throw new Error("bang"); };',
                                 filename: 'my_gem/lib.js')
    _(lib.name).must_match(%r{\Amy_gem/lib\.js-\h{16}\z})

    vm = Quickjs::VM.new
    vm.import(['boom'], from: lib)
    err = _ { vm.eval_code('boom()') }.must_raise Quickjs::RuntimeError

    _(err.backtrace.join("\n")).must_include 'my_gem/lib.js'
  end

  it "rejects a non-String source" do
    _ { Quickjs.compile_module(42) }.must_raise TypeError
  end

  it "rejects a non-String filename" do
    _ { Quickjs.compile_module('export const x = 1;', filename: :lib) }.must_raise TypeError
  end

  it "raises on a syntax error in the module source" do
    _ { Quickjs.compile_module('export const = ;') }.must_raise Quickjs::SyntaxError
  end

  it "accepts VM options for compiling large sources" do
    lib = Quickjs.compile_module('export const x = 1;', memory_limit: 1024 * 1024 * 64)
    vm = Quickjs::VM.new
    vm.import(['x'], from: lib)

    _(vm.eval_code('x')).must_equal 1
  end

  it "does not leak the bytecode through the public interface" do
    lib = Quickjs.compile_module('export const x = 1;')

    _(lib).wont_respond_to :to_s_bytecode
    _ { lib.bytecode }.must_raise NoMethodError
  end

  describe "alongside module_loader" do
    it "resolves without consulting a loader that doesn't know the name" do
      lib = Quickjs.compile_module('export const x = "from-importable";')
      vm = Quickjs::VM.new
      asked = []
      vm.module_loader = ->(specifier, _importer) { asked << specifier; nil }
      vm.import(['x'], from: lib)

      _(vm.eval_code('x')).must_equal 'from-importable'
      _(asked).must_be_empty
    end

    it "still routes the module's own imports through the loader" do
      lib = Quickjs.compile_module("import { d } from 'dep';\nexport const combined = () => `imp+${d()}`;")
      vm = Quickjs::VM.new
      seen = []
      vm.module_loader = ->(specifier, importer) {
        seen << specifier
        "export const d = () => 'dep';" if specifier == 'dep'
      }
      vm.import(['combined'], from: lib)

      _(vm.eval_code('combined()')).must_equal 'imp+dep'
      _(seen).must_equal ['dep']
    end
  end

  it "leaves a String from: working as before" do
    vm = Quickjs::VM.new
    vm.import(['plain'], from: 'export const plain = () => "inline";')

    _(vm.eval_code('plain()')).must_equal 'inline'
  end
end
