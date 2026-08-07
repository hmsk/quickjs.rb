# frozen_string_literal: true

require_relative "test_helper"

describe "Quickjs.register_module" do
  # Each test registers under a unique name and tears it down so tests
  # don't leak registry state into each other.
  before { @name = "_test_module_#{object_id}" }
  after  { Quickjs._unregister_module(@name) }

  it "rejects non-String names" do
    _ {
      Quickjs.register_module(:not_a_string, source: 'export const x = 1;')
    }.must_raise TypeError
  end

  it "rejects non-String, non-Proc sources" do
    _ {
      Quickjs.register_module(@name, source: 42)
    }.must_raise TypeError
  end

  it "is importable by a VM that preloads it" do
    Quickjs.register_module(@name, source: 'export const greet = () => "hello";')
    vm = Quickjs::VM.new(preload_modules: [@name])
    vm.import(['greet'], filename: @name)

    _(vm.eval_code('greet()')).must_equal 'hello'
  end

  it "accepts a Proc source and calls it lazily" do
    calls = 0
    Quickjs.register_module(@name, source: -> { calls += 1; 'export const x = 42;' })
    _(calls).must_equal 0

    vm = Quickjs::VM.new(preload_modules: [@name])
    vm.import(['x'], filename: @name)

    _(vm.eval_code('x')).must_equal 42
    _(calls).must_equal 1
  end

  it "compiles once and reuses the bytecode across VMs" do
    calls = 0
    Quickjs.register_module(@name, source: -> { calls += 1; 'export const x = 1;' })

    3.times { Quickjs::VM.new(preload_modules: [@name]).dispose! }

    _(calls).must_equal 1
  end

  it "leaves the source intact when compilation fails, so a later VM can retry" do
    sources = ['export const = ;', 'export const x = "recovered";']
    Quickjs.register_module(@name, source: -> { sources.shift })

    _ { Quickjs::VM.new(preload_modules: [@name]) }.must_raise Quickjs::SyntaxError

    vm = Quickjs::VM.new(preload_modules: [@name])
    vm.import(['x'], filename: @name)
    _(vm.eval_code('x')).must_equal 'recovered'
  end

  it "raises when a Proc source doesn't return a String" do
    Quickjs.register_module(@name, source: -> { 42 })

    _ { Quickjs::VM.new(preload_modules: [@name]) }.must_raise TypeError
  end

  it "raises for a name that isn't registered" do
    _ {
      Quickjs::VM.new(preload_modules: ['_never_registered'])
    }.must_raise ArgumentError
  end

  it "rejects Symbols in preload_modules:" do
    Quickjs.register_module(@name, source: 'export const x = 1;')

    _ {
      Quickjs::VM.new(preload_modules: [@name.to_sym])
    }.must_raise TypeError
  end

  it "rejects a non-Array preload_modules:" do
    Quickjs.register_module(@name, source: 'export const x = 1;')

    _ {
      Quickjs::VM.new(preload_modules: @name)
    }.must_raise TypeError
  end

  it "does not preload registered modules a VM didn't ask for" do
    Quickjs.register_module(@name, source: 'export const x = 1;')
    vm = Quickjs::VM.new

    _ { vm.import(['x'], filename: @name) }.must_raise Quickjs::ReferenceError
  end

  it "replaces the entry when a name is registered again" do
    Quickjs.register_module(@name, source: 'export const x = "first";')
    Quickjs::VM.new(preload_modules: [@name]).dispose!
    Quickjs.register_module(@name, source: 'export const x = "second";')

    vm = Quickjs::VM.new(preload_modules: [@name])
    vm.import(['x'], filename: @name)
    _(vm.eval_code('x')).must_equal 'second'
  end

  it "preloads a registered module that imports another registered module" do
    dep = "#{@name}_dep"
    Quickjs.register_module(dep, source: 'export const d = () => "dep";')
    Quickjs.register_module(@name, source: "import { d } from '#{dep}';\nexport const combined = () => `main+${d()}`;")

    vm = Quickjs::VM.new(preload_modules: [dep, @name])
    vm.import(['combined'], filename: @name)

    _(vm.eval_code('combined()')).must_equal 'main+dep'
  ensure
    Quickjs._unregister_module(dep)
  end

  it "coexists with a module_loader that resolves everything else" do
    Quickjs.register_module(@name, source: 'export const fromRegistry = () => "registry";')
    vm = Quickjs::VM.new(preload_modules: [@name])
    asked = []
    vm.module_loader = ->(specifier, _importer) {
      asked << specifier
      'export const fromLoader = () => "loader";' if specifier == 'other'
    }

    vm.import(['fromRegistry'], filename: @name)
    vm.import(['fromLoader'], filename: 'other')

    _(vm.eval_code('fromRegistry() + "/" + fromLoader()')).must_equal 'registry/loader'
    _(asked).must_equal ['other']
  end

  it "sees polyfilled globals from a preloaded module" do
    Quickjs.register_module(@name, source: 'export const kind = typeof Blob;')
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE], preload_modules: [@name])
    vm.import(['kind'], filename: @name)

    _(vm.eval_code('kind')).must_equal 'function'
  end

  it "compiles once across threads racing to construct VMs" do
    calls = Queue.new
    Quickjs.register_module(@name, source: -> { calls << 1; 'export const x = 1;' })

    threads = Array.new(4) { Thread.new { Quickjs::VM.new(preload_modules: [@name]).dispose! } }
    threads.each(&:join)

    _(calls.size).must_equal 1
  end
end
