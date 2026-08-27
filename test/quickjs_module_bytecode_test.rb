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
    _(vm.send(:_preload_module_bytecode, bytecode, 'lib')).must_equal 'lib'
    vm.import(['hi'], filename: 'lib')

    _(vm.eval_code('hi()')).must_equal 'hello'
  end

  it "raises on a syntax error in the module source" do
    _ { compile_module("export const = ;", 'broken') }.must_raise Quickjs::SyntaxError
  end

  it "rejects bytecode that isn't an ES module" do
    classic = Quickjs.compile("1 + 1;").to_s

    _ {
      Quickjs::VM.new.send(:_preload_module_bytecode, classic, 'classic')
    }.must_raise TypeError
  end

  it "rejects a blob that isn't bytecode at all" do
    _ {
      Quickjs::VM.new.send(:_preload_module_bytecode, 'not bytecode', 'junk')
    }.must_raise Quickjs::SyntaxError
  end

  it "rejects a non-String blob rather than coercing it" do
    coercible = Object.new
    def coercible.to_str = 'not bytecode'

    _ {
      Quickjs::VM.new.send(:_preload_module_bytecode, coercible, 'junk')
    }.must_raise TypeError
  end

  describe "resolution" do
    before do
      @bytecode = compile_module("export const who = () => 'preloaded';", 'lib')
    end

    it "resolves without any module_loader set" do
      vm = Quickjs::VM.new
      vm.send(:_preload_module_bytecode, @bytecode, 'lib')
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
      vm.send(:_preload_module_bytecode, @bytecode, 'lib')
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
      vm.send(:_preload_module_bytecode, @bytecode, 'lib')
      vm.import(['who'], filename: 'lib')

      _(vm.eval_code('who()')).must_equal 'preloaded'
      _(asked).must_be_empty
    end

    it "is reachable through a loader that maps a specifier onto the preloaded name" do
      vm = Quickjs::VM.new
      vm.module_loader = ->(specifier, _importer) {
        {code: 'export const who = () => "unused";', as: 'lib'} if specifier == 'aliased'
      }
      vm.send(:_preload_module_bytecode, @bytecode, 'lib')
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
      vm.send(:_preload_module_bytecode, bytecode, 'lib')
      vm.import(['combined'], filename: 'lib')

      _(vm.eval_code('combined()')).must_equal 'pre+dep'
      _(seen).must_equal [['dep', 'lib']]
    end
  end

  it "gives each VM its own instance of the module" do
    bytecode = compile_module("const s = { n: 0 };\nexport const inc = () => ++s.n;", 'counter')

    vm1 = Quickjs::VM.new
    vm1.send(:_preload_module_bytecode, bytecode, 'counter')
    vm1.import(['inc'], filename: 'counter')
    vm2 = Quickjs::VM.new
    vm2.send(:_preload_module_bytecode, bytecode, 'counter')
    vm2.import(['inc'], filename: 'counter')

    _(vm1.eval_code('inc()')).must_equal 1
    _(vm1.eval_code('inc()')).must_equal 2
    _(vm2.eval_code('inc()')).must_equal 1
  end

  describe "preloading the same module twice" do
    before do
      @bytecode = compile_module("const s = { n: 0 };\nexport const inc = () => ++s.n;", 'counter')
    end

    # js_read_module appends a second JSModuleDef under the same name rather
    # than replacing or rejecting, and js_find_loaded_module returns the first
    # one it walks past, so a re-read leaves an orphan holding its bytecode for
    # the life of the context.
    it "reads the bytecode only once" do
      vm = Quickjs::VM.new
      vm.send(:_preload_module_bytecode, @bytecode, 'counter')
      after_first = vm.memory_usage[:js_func_code_size]
      vm.send(:_preload_module_bytecode, @bytecode, 'counter')

      _(vm.memory_usage[:js_func_code_size]).must_equal after_first
    end

    it "keeps a single instance of the module" do
      vm = Quickjs::VM.new
      vm.send(:_preload_module_bytecode, @bytecode, 'counter')
      vm.send(:_preload_module_bytecode, @bytecode, 'counter')
      vm.import(['inc'], filename: 'counter')

      _(vm.eval_code('inc()')).must_equal 1
      _(vm.eval_code('inc()')).must_equal 2
    end

    it "tolerates a name listed twice in preload_modules:" do
      Quickjs.register_module('_test_dup', source: 'export const x = 1;')
      vm = Quickjs::VM.new(preload_modules: ['_test_dup'])
      baseline = vm.memory_usage[:js_func_code_size]
      vm.dispose!

      vm = Quickjs::VM.new(preload_modules: ['_test_dup', '_test_dup'])

      _(vm.memory_usage[:js_func_code_size]).must_equal baseline
    ensure
      Quickjs._unregister_module('_test_dup')
    end
  end

  it "rejects bytecode whose baked name isn't the one it's filed under" do
    bytecode = compile_module('export const x = 1;', 'actual')

    _ {
      Quickjs::VM.new.send(:_preload_module_bytecode, bytecode, 'claimed')
    }.must_raise ArgumentError
  end

  it "does not evaluate the module until it is imported" do
    bytecode = compile_module("globalThis.sideEffect = 'ran';\nexport const x = 1;", 'effectful')

    vm = Quickjs::VM.new
    vm.send(:_preload_module_bytecode, bytecode, 'effectful')
    _(vm.eval_code('typeof globalThis.sideEffect')).must_equal 'undefined'

    vm.import(['x'], filename: 'effectful')
    _(vm.eval_code('globalThis.sideEffect')).must_equal 'ran'
  end

  it "reads the same bytecode into a VM per thread without crashing" do
    bytecode = compile_module('export const answer = () => 21 * 2;', 'answer')

    results = Array.new(8) {
      Thread.new {
        vm = Quickjs::VM.new

        begin
          vm.send(:_preload_module_bytecode, bytecode, 'answer')
          vm.import(['answer'], filename: 'answer')
          vm.eval_code('answer()')
        ensure
          vm.dispose!
        end
      }
    }.map(&:value)

    _(results).must_equal Array.new(8, 42)
  end

  # Deserializing is proportional to the blob, not to what the module computes,
  # so the timing workload is a module made large rather than one made slow.
  #
  # The size is tuned rather than arbitrary, because it trades the two failure
  # modes against each other. Growing it grows the GVL-free dispose! in lockstep
  # with the read, which lifts the GVL-held case toward the 0.8 threshold —
  # measured 1.11 at 5k functions, 0.92 at 10k, 0.83 at 20k, i.e. closer to
  # passing when it shouldn't. Shrinking it leaves thread setup a bigger share
  # of a shorter run, which lifts the released case — 0.62 at 5k, up to 0.75 at
  # 2.5k, closer to failing when it shouldn't. 5k sits near the widest point.
  def bulky_module_source(functions: 5_000)
    Array.new(functions) {|i|
      "export function f#{i}(a, b) { return a * #{i} + b - Math.sqrt(a + #{i}); }"
    }.join("\n")
  end

  # Preloading is the warmer-pool hot path for modules: compile a bundle once,
  # read it into a VM per thread. The read releases the GVL unconditionally —
  # it registers the module def without running any of it, so no bridge can
  # fire and no can_eval_gvl_free gate is needed. Before the release, threads
  # populating their VMs serialized on the GVL.
  #
  # Each iteration reads a distinct module into one long-lived VM rather than
  # building a VM per read, because dispose! releases the GVL on its own: with
  # a VM per iteration the freeing parallelizes either way and swamps what is
  # being measured, leaving held and released only 0.85 vs 0.78 apart. Reading
  # into a single VM keeps the deserialize dominant, and the two land on
  # opposite sides of the threshold with room to spare (~1.1 vs ~0.5).
  it "reads module bytecode concurrently with measurable speedup" do
    source  = bulky_module_source
    modules = Array.new(8) {|i| [compile_module(source, "bulky#{i}"), "bulky#{i}"] }

    # The iteration count is told to the helper rather than left to its default,
    # because every iteration has to read a module the VM hasn't seen: a repeat
    # is deduplicated into a no-op, so wrapping around the list would silently
    # give the one-thread and two-thread runs different amounts of work to do.
    #
    # More trials than the helper's default because this workload has less
    # headroom above the 0.8 threshold than the other GVL tests: it flapped on
    # CI at 0.811, missing by 1.3%, on 4 of 8 jobs in one run while the same
    # commit went 8 for 8 in the other. Each side is the min of its trials, so
    # more attempts only lowers both floors, and a runner has to be busy across
    # all of them to produce a false failure. Widening the threshold instead
    # would buy false passes, which is the worse direction: the GVL-held case
    # measures as low as 0.83 on some machines.
    assert_releases_gvl(iterations: modules.size) do |iterations|
      vm = Quickjs::VM.new

      begin
        iterations.times {|i| vm.send(:_preload_module_bytecode, *modules[i]) }
      ensure
        vm.dispose!
      end
    end
  end
end
