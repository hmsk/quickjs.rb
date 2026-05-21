# frozen_string_literal: true

module Quickjs
  # Process-wide registry; entries are lazily compiled to bytecode on
  # first use and the bytecode is reused across VMs.
  @_polyfills = {}

  # `source:` accepts either a `String` (eager) or a `Proc` returning one
  # (lazy). The lazy form lets a companion gem call `register_polyfill`
  # at require time without paying the file-read cost unless a VM
  # actually opts into the feature.
  def self.register_polyfill(name, source:, init: nil)
    raise ::TypeError, "name must be a Symbol, got #{name.class}" unless name.is_a?(Symbol)
    raise ::TypeError, "source: must be a String or Proc, got #{source.class}" unless source.is_a?(String) || source.is_a?(Proc)
    raise ::TypeError, "init: must be a String or nil, got #{init.class}" unless init.nil? || init.is_a?(String)

    @_polyfills[name] = {source: source, init: init&.freeze, bytecode: nil}
    nil
  end

  def self._polyfill_for(name)
    @_polyfills[name]
  end

  def self._unregister_polyfill(name)
    @_polyfills.delete(name)
    nil
  end

  def self._apply_registered_polyfills(vm, features)
    features.each do |feature|
      next unless (entry = @_polyfills[feature])
      # `||=` isn't atomic — `_precompile_polyfill` releases the GVL inside
      # `Quickjs.compile`, so two threads racing to construct VMs with the
      # same polyfill can both see nil and both compile. The bytecode write
      # is harmless because both threads produce identical bytes; the only
      # observable cost is wasted compile work, and (for `source: Proc`) a
      # second Proc invocation — so register Procs that are safe to call
      # more than once.
      entry[:bytecode] ||= _precompile_polyfill(entry, feature)
      vm.send(:_load_polyfill_bytecode, entry[:bytecode])
    end
  end

  # Compiled once per process per polyfill on a disposable VM whose
  # generous timeout covers parsing multi-MB bundles (FormatJS Intl is
  # ~2 MB). The user's per-VM `timeout_msec` is for their own JS — it
  # would otherwise interrupt our infrastructure on tight defaults.
  # `features: []` skips applying any registered polyfills to the temp
  # VM (no recursion / no wasted polyfill loads).
  def self._precompile_polyfill(entry, feature)
    source = entry[:source]
    source = source.call if source.is_a?(Proc)
    combined = entry[:init] ? "#{entry[:init]}\n#{source}" : source
    Quickjs.compile(combined, filename: feature.to_s, timeout_msec: 60_000, features: []).to_s
  end

  module PolyfillLoader
    def initialize(features: [], **opts)
      super
      Quickjs._apply_registered_polyfills(self, features)
    end
  end

  # Guard against double-prepend if this file is reloaded (e.g. Rails dev).
  VM.prepend(PolyfillLoader) unless VM.ancestors.include?(PolyfillLoader)
end
