# frozen_string_literal: true

require_relative "test_helper"

# Low-level tests for the two primitives Quickjs.register_module is built on:
# compiling an ES module to bytecode, and reading that bytecode into a VM.
describe "module bytecode primitives" do
  def compile_module(source, name)
    vm = Quickjs::VM.new
    vm.send(:_compile_module_to_bytecode, source, name)
  ensure
    vm&.dispose!
  end

  it "round-trips a module through bytecode" do
    bytecode = compile_module("export const hi = () => 'hello';", 'lib')

    _(bytecode).must_be_kind_of String
    _(bytecode.encoding).must_equal Encoding::ASCII_8BIT
    _(bytecode).must_be :frozen?

    vm = Quickjs::VM.new
    _(vm.send(:_preload_module_bytecode, bytecode)).must_equal 'lib'
    vm.import(['hi'], filename: 'lib')

    _(vm.eval_code('hi()')).must_equal 'hello'
  end

  it "raises on a syntax error in the module source" do
    _ { compile_module("export const = ;", 'broken') }.must_raise Quickjs::SyntaxError
  end

  it "rejects bytecode that isn't an ES module" do
    classic = Quickjs.compile("1 + 1;").to_s

    _ {
      Quickjs::VM.new.send(:_preload_module_bytecode, classic)
    }.must_raise TypeError
  end

  it "rejects a blob that isn't bytecode at all" do
    _ {
      Quickjs::VM.new.send(:_preload_module_bytecode, 'not bytecode')
    }.must_raise Quickjs::SyntaxError
  end

  describe "resolution" do
    before do
      @bytecode = compile_module("export const who = () => 'preloaded';", 'lib')
    end

    it "resolves without any module_loader set" do
      vm = Quickjs::VM.new
      vm.send(:_preload_module_bytecode, @bytecode)
      vm.import(['who'], filename: 'lib')

      _(vm.eval_code('who()')).must_equal 'preloaded'
    end

    # QuickJS calls the normalize hook before it looks in ctx->loaded_modules,
    # so without the preloaded-name short-circuit this raised
    # Quickjs::ReferenceError even though the module was already loaded.
    it "resolves when a module_loader is set that doesn't know the name" do
      vm = Quickjs::VM.new
      asked = []
      vm.module_loader = ->(specifier, _importer) { asked << specifier; nil }
      vm.send(:_preload_module_bytecode, @bytecode)
      vm.import(['who'], filename: 'lib')

      _(vm.eval_code('who()')).must_equal 'preloaded'
      _(asked).must_be_empty
    end

    it "wins over a module_loader that does know the name" do
      vm = Quickjs::VM.new
      asked = []
      vm.module_loader = ->(specifier, _importer) {
        asked << specifier
        "export const who = () => 'from-loader';"
      }
      vm.send(:_preload_module_bytecode, @bytecode)
      vm.import(['who'], filename: 'lib')

      _(vm.eval_code('who()')).must_equal 'preloaded'
      _(asked).must_be_empty
    end

    it "is reachable through a loader that maps a specifier onto the preloaded name" do
      vm = Quickjs::VM.new
      vm.module_loader = ->(specifier, _importer) {
        {code: 'export const who = () => "unused";', as: 'lib'} if specifier == 'aliased'
      }
      vm.send(:_preload_module_bytecode, @bytecode)
      vm.import(['who'], filename: 'aliased')

      _(vm.eval_code('who()')).must_equal 'preloaded'
      # The load hook never fires on this path (QuickJS finds the preloaded
      # module first), so the source the loader handed us must not be stashed
      # for it: nothing would ever clear the entry, and it is the seam where a
      # second instance of the module could come back through the alias.
      _(vm.send(:_pending_module_source_count)).must_equal 0
    end

    it "clears the stashed source once a loader-provided module is loaded" do
      vm = Quickjs::VM.new
      vm.module_loader = ->(specifier, _importer) {
        "export const who = () => 'from-loader';" if specifier == 'plain'
      }
      vm.import(['who'], filename: 'plain')

      _(vm.eval_code('who()')).must_equal 'from-loader'
      _(vm.send(:_pending_module_source_count)).must_equal 0
    end

    it "still routes the preloaded module's own imports through the loader" do
      bytecode = compile_module("import { d } from 'dep';\nexport const combined = () => `pre+${d()}`;", 'lib')
      vm = Quickjs::VM.new
      seen = []
      vm.module_loader = ->(specifier, importer) {
        seen << [specifier, importer]
        "export const d = () => 'dep';" if specifier == 'dep'
      }
      vm.send(:_preload_module_bytecode, bytecode)
      vm.import(['combined'], filename: 'lib')

      _(vm.eval_code('combined()')).must_equal 'pre+dep'
      _(seen).must_equal [['dep', 'lib']]
    end
  end

  it "gives each VM its own instance of the module" do
    bytecode = compile_module("const s = { n: 0 };\nexport const inc = () => ++s.n;", 'counter')

    vm1 = Quickjs::VM.new
    vm1.send(:_preload_module_bytecode, bytecode)
    vm1.import(['inc'], filename: 'counter')
    vm2 = Quickjs::VM.new
    vm2.send(:_preload_module_bytecode, bytecode)
    vm2.import(['inc'], filename: 'counter')

    _(vm1.eval_code('inc()')).must_equal 1
    _(vm1.eval_code('inc()')).must_equal 2
    _(vm2.eval_code('inc()')).must_equal 1
  end

  it "does not evaluate the module until it is imported" do
    bytecode = compile_module("globalThis.sideEffect = 'ran';\nexport const x = 1;", 'effectful')

    vm = Quickjs::VM.new
    vm.send(:_preload_module_bytecode, bytecode)
    _(vm.eval_code('typeof globalThis.sideEffect')).must_equal 'undefined'

    vm.import(['x'], filename: 'effectful')
    _(vm.eval_code('globalThis.sideEffect')).must_equal 'ran'
  end
end
