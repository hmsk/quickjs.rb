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
end
