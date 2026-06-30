# frozen_string_literal: true

require_relative "test_helper"

describe "Quickjs.register_polyfill" do
  # Each test registers and tears down a unique feature symbol so tests
  # don't leak registry state into each other.
  before { @feature = :"_test_polyfill_#{object_id}" }
  after  { Quickjs._unregister_polyfill(@feature) }

  it "rejects non-Symbol names" do
    _ {
      Quickjs.register_polyfill('not_a_symbol', source: 'globalThis.x = 1;')
    }.must_raise TypeError
  end

  it "rejects non-String sources" do
    _ {
      Quickjs.register_polyfill(@feature, source: 42)
    }.must_raise TypeError
  end

  it "rejects non-String, non-nil init" do
    _ {
      Quickjs.register_polyfill(@feature, source: 'globalThis.x = 1;', init: 42)
    }.must_raise TypeError
  end

  it "is applied when the feature is enabled on a VM" do
    Quickjs.register_polyfill(@feature, source: 'globalThis.myPolyfill = "loaded";')
    vm = Quickjs::VM.new(features: [@feature])

    _(vm.eval_code('myPolyfill')).must_equal 'loaded'
  end

  it "runs init before the polyfill body" do
    Quickjs.register_polyfill(
      @feature,
      init: 'globalThis.beforePolyfill = "init-ran";',
      source: 'globalThis.afterPolyfill = beforePolyfill + "/source-ran";'
    )
    vm = Quickjs::VM.new(features: [@feature])

    _(vm.eval_code('afterPolyfill')).must_equal 'init-ran/source-ran'
  end

  it "is a no-op when the feature is not enabled" do
    Quickjs.register_polyfill(@feature, source: 'globalThis.shouldNotAppear = 1;')
    vm = Quickjs::VM.new

    _(vm.eval_code('typeof shouldNotAppear')).must_equal 'undefined'
  end

  it "reuses the cached bytecode across VMs (memoization)" do
    Quickjs.register_polyfill(@feature, source: 'globalThis.x = (globalThis.x || 0) + 1;')
    Quickjs::VM.new(features: [@feature])

    entry = Quickjs._polyfill_for(@feature)
    cached = entry[:bytecode]
    _(cached).wont_be_nil

    Quickjs::VM.new(features: [@feature])
    # Same bytecode String instance — proves no recompile.
    _(Quickjs._polyfill_for(@feature)[:bytecode].equal?(cached)).must_equal true
  end

  it "calls a Proc source lazily and only once, even across multiple VMs" do
    calls = 0
    Quickjs.register_polyfill(@feature, source: -> {
      calls += 1
      'globalThis.fromProc = "loaded";'
    })

    # Proc not invoked when the feature isn't opted into.
    Quickjs::VM.new
    _(calls).must_equal 0

    # First feature-enabled VM triggers precompile.
    vm = Quickjs::VM.new(features: [@feature])
    _(calls).must_equal 1
    _(vm.eval_code('fromProc')).must_equal 'loaded'

    # Subsequent VMs reuse the cached bytecode — Proc isn't re-invoked.
    Quickjs::VM.new(features: [@feature])
    _(calls).must_equal 1
  end

  it "isn't subject to the user VM's timeout_msec while loading" do
    # Tiny body — but a 1ms user-budget would interrupt the load if our
    # path armed the timer; we intentionally don't.
    Quickjs.register_polyfill(@feature, source: 'globalThis.installed = true;')
    vm = Quickjs::VM.new(features: [@feature], timeout_msec: 1)

    _(vm.eval_code('installed', async: false)).must_equal true
  end

  # Mirrors the GVL-release pattern from VM#eval_code: _load_polyfill_bytecode
  # copies the Ruby String to a malloc'd buffer and releases the GVL during
  # JS_ReadObject + JS_EvalFunction. Without that, csim-style warmer-thread VM
  # pools serialize all polyfill loads through the GVL and lose multi-core
  # scaling — the original motivation for this code path. The workload calls
  # _load_polyfill_bytecode directly on a bare VM so the timing isolates the
  # bytecode-load step from VM construction (which would otherwise release the
  # GVL itself if any bundled polyfill features were enabled).
  it "loads polyfill bytecode in parallel across VMs (GVL released)" do
    Quickjs.register_polyfill(@feature, source: cpu_workload_js)

    Quickjs::VM.new(features: [@feature]).dispose! # populate the bytecode cache
    bytecode = Quickjs._polyfill_for(@feature)[:bytecode]

    assert_run_in_parallel do |iterations|
      iterations.times do
        vm = Quickjs::VM.new
        vm.send(:_load_polyfill_bytecode, bytecode)
        vm.dispose!
      end
    end
  end

  # JS_EvalFunction on a JS_EXCEPTION input replaces the pending exception
  # with a generic "bytecode function expected" TypeError, losing the actual
  # deserialization diagnostic. bytecode_load_job_run (shared by the released
  # and GVL-held paths) short-circuits on JS_IsException to preserve the
  # original error.
  it "preserves the original JS_ReadObject error for corrupt bytecode" do
    vm = Quickjs::VM.new

    err = _ {
      vm.send(:_load_polyfill_bytecode, 'this is not valid bytecode')
    }.must_raise Quickjs::SyntaxError

    _(err.message).wont_match(/bytecode function expected/)
  ensure
    vm&.dispose!
  end

  # vm_m_loadPolyfillBytecode gates on can_eval_gvl_free: when POLYFILL_CRYPTO
  # is enabled, the polyfill's top-level code can reach crypto.getRandomValues
  # (a C bridge that calls rb_funcall directly without honoring gvl_released_js).
  # Releasing the GVL would crash; the gate keeps it held. This test exercises
  # the combo to prove the gate is wired — without it, the crypto bridge runs
  # off-GVL and segfaults under MRI.
  it "loads with GVL held when a Ruby-bridged feature is also enabled" do
    Quickjs.register_polyfill(@feature, source: <<~JS)
      globalThis.fromPolyfill = crypto.getRandomValues(new Uint8Array(4)).length;
    JS
    vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_CRYPTO, @feature])

    _(vm.eval_code('fromPolyfill')).must_equal 4
  ensure
    vm&.dispose!
  end
end
