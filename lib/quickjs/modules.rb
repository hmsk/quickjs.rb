# frozen_string_literal: true

module Quickjs
  # Process-wide registry of ES modules; entries are lazily compiled to
  # bytecode on first use and the bytecode is reused across VMs.
  @_modules = {}

  # `name` is the module's canonical name: the string JS code writes in its
  # `import` statement, and the name QuickJS keys its module map by. It is
  # baked into the compiled bytecode, so registering under it is what keeps
  # the registry key and the module's identity from drifting apart.
  #
  # `source:` accepts either a `String` (eager) or a `Proc` returning one
  # (lazy). The lazy form lets a gem register a module at require time
  # without paying the file-read cost unless a VM actually preloads it.
  #
  # Registering only makes the module available; a VM picks it up with
  # `VM.new(preload_modules: [name])`. Reading a module into a VM costs
  # real time whether or not it ends up imported, so preloading is a
  # per-VM decision rather than something registration forces on every VM.
  def self.register_module(name, source:)
    raise ::TypeError, "name must be a String, got #{name.class}" unless name.is_a?(String)
    raise ::TypeError, "source: must be a String or Proc, got #{source.class}" unless source.is_a?(String) || source.is_a?(Proc)

    @_modules[-name] = {source: source, bytecode: nil, mutex: Mutex.new}
    nil
  end

  def self._module_registered?(name)
    @_modules.key?(name)
  end

  def self._unregister_module(name)
    @_modules.delete(name)
    nil
  end

  def self._preload_modules(vm, names)
    names.each do |name|
      raise ::TypeError, "preload_modules: entries must be Strings, got #{name.class}" unless name.is_a?(String)

      entry = @_modules[name]
      unless entry
        raise ::ArgumentError,
          "#{name.inspect} is not a registered module; call Quickjs.register_module(#{name.inspect}, source: ...) first"
      end

      # Same locking as registered polyfills: `||=` alone isn't atomic
      # because compilation yields the GVL, so threads racing to construct
      # VMs could double-compile, or a loser could read entry[:source]
      # after the winner cleared it. A compile failure leaves bytecode nil
      # and source intact so a later VM can retry. The unlocked first read
      # keeps the hot path off the lock once the bytecode exists.
      bytecode = entry[:bytecode] || entry[:mutex].synchronize {
        entry[:bytecode] ||= begin
          compiled = _compile_registered_module(entry, name)
          entry[:source] = nil # let the Proc's captured scope be GC'd
          compiled
        end
      }
      vm.send(:_preload_module_bytecode, bytecode, name)
    end
  end

  # Compiled on a disposable VM: compilation installs a stub module loader
  # to satisfy QuickJS's compile-time import resolution, and those stubs
  # land in the compiling context's module map, so it must not be a VM
  # anyone goes on to use. The generous timeout covers parsing large
  # bundles, since the user's per-VM `timeout_msec` is a budget for their
  # own JS. `features: []` keeps registered polyfills off the temp VM.
  def self._compile_registered_module(entry, name)
    source = entry[:source]
    source = source.call if source.is_a?(Proc)
    unless source.is_a?(String)
      raise ::TypeError, "source: Proc for #{name.inspect} must return a String, got #{source.class}"
    end

    vm = VM.new(timeout_msec: 60_000, features: [])
    vm.send(:_compile_module_to_bytecode, source, name)
  ensure
    vm&.dispose!
  end

  module ModulePreloader
    def initialize(preload_modules: [], **opts)
      super(**opts)
      unless preload_modules.is_a?(Array)
        raise ::TypeError, "preload_modules: must be an Array, got #{preload_modules.class}"
      end

      Quickjs._preload_modules(self, preload_modules)
    end
  end

  # Prepended after PolyfillLoader so polyfills are installed first: a
  # module body can reach for a polyfilled global when it evaluates.
  VM.prepend(ModulePreloader) unless VM.ancestors.include?(ModulePreloader)
end
