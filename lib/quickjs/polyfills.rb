# frozen_string_literal: true

module Quickjs
  # Process-wide registry; entries are lazily compiled to bytecode on
  # first use and the bytecode is reused across VMs.
  @_polyfills = {}

  # `source:` accepts either a `String` (eager) or a `Proc` returning one
  # (lazy). The lazy form lets a companion gem call `register_polyfill`
  # at require time without paying the file-read cost unless a VM
  # actually opts into the feature. The Proc must not itself construct a
  # VM with the same feature: compilation is locked per entry, so that
  # recursion raises ThreadError instead of deadlocking silently.
  #
  # The polyfill's top level must settle synchronously — no top-level
  # await. `VM.new(features:)` promises a usable polyfill on return, but
  # loads never drain the job queue, so nothing past the first await
  # would have run by then; a pending load raises Quickjs::RuntimeError
  # instead of handing back a silently half-applied VM.
  #
  # Re-registering a name replaces the entry wholesale, lock included: a
  # VM construction already compiling under the old entry finishes
  # against it (and loads the old bytecode) while the first construction
  # under the new entry compiles the new source independently. Each
  # registration compiles at most once; the two compiles can overlap.
  def self.register_polyfill(name, source:, init: nil)
    raise ::TypeError, "name must be a Symbol, got #{name.class}" unless name.is_a?(Symbol)
    raise ::TypeError, "source: must be a String or Proc, got #{source.class}" unless source.is_a?(String) || source.is_a?(Proc)
    raise ::TypeError, "init: must be a String or nil, got #{init.class}" unless init.nil? || init.is_a?(String)

    @_polyfills[name] = {source: source, init: init&.freeze, bytecode: nil, mutex: Mutex.new}
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
      # The per-entry mutex makes first-use compilation happen exactly once
      # even when threads race to construct VMs with the same polyfill —
      # `||=` alone isn't atomic (`_precompile_polyfill` yields the GVL
      # inside `Quickjs.compile`), and a losing thread could otherwise
      # double-compile or read entry[:source] after the winner cleared it.
      # A compile failure leaves bytecode nil and source intact, so a later
      # attempt can retry. The unlocked first read keeps the post-compile
      # hot path (warmer pools constructing VMs concurrently) off the lock;
      # a stale nil just falls into the synchronize.
      bytecode = entry[:bytecode] || entry[:mutex].synchronize {
        entry[:bytecode] ||= begin
          compiled = _precompile_polyfill(entry, feature)
          # The Proc / String source isn't needed again once the bytecode
          # is cached — drop it so its captured scope can be GC'd.
          entry[:source] = nil
          entry[:init]   = nil
          compiled
        end
      }
      begin
        vm.send(:_load_polyfill_bytecode, bytecode)
      rescue Quickjs::RuntimeError => e
        # The C layer only sees bytecode; name the registration so a VM
        # with several polyfill features points at the one that failed.
        # `raise e, msg` clones — class, js_name, and any JS backtrace
        # already set on the original all survive.
        raise e, "#{feature}: #{e.message}"
      end
    end
  end

  # Compiled once per process per polyfill on a disposable VM whose
  # generous timeout covers parsing multi-MB bundles (e.g. the companion
  # `quickjs-polyfill-intl` gem's FormatJS bundles run a couple MB). The
  # user's per-VM `timeout_msec` is for their own JS — it would otherwise
  # interrupt our infrastructure on tight defaults. `features: []` skips
  # applying any registered polyfills to the temp VM (no recursion / no
  # wasted polyfill loads).
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
