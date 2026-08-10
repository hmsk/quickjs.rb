# frozen_string_literal: true

module Quickjs
  # An ES module compiled to bytecode once and importable into any number of
  # VMs without reparsing. The module-map counterpart of `Runnable`, which does
  # the same for classic scripts.
  #
  # Unlike `Quickjs.register_module`, nothing about this is process-global:
  # hold the object, drop it when you're done. That matters for a library that
  # ships JS of its own, since a global registry would make unrelated gems
  # coordinate on a name none of their VMs ever share.
  class Importable
    attr_reader :name

    def initialize(bytecode, name)
      @bytecode = bytecode
      @name = name
    end

    def inspect
      "#<#{self.class} #{@name} (#{@bytecode.bytesize} bytes)>"
    end

    private

    # Deliberately not public. Handing out the blob would invite persisting it,
    # and the bytecode format is tied to the QuickJS build with only a one-byte
    # version tag to catch a mismatch.
    def bytecode
      @bytecode
    end
  end

  # Compiles `source` as an ES module and returns an `Importable`.
  #
  # The module's name is generated rather than taken from the caller, because
  # it is baked into the bytecode and becomes the module's identity in every VM
  # that imports it. Generating it means two independently built Importables
  # can never collide, which is the whole point when the JS ships inside a gem.
  # `filename:` prefixes the generated name so stack traces stay readable; it is
  # a label, not an identity.
  #
  # Compiles on a disposable VM: compilation installs a stub module loader to
  # satisfy QuickJS's compile-time import resolution, and those stubs land in
  # the compiling context's module map. The default timeout is generous because
  # a VM's `timeout_msec` is a budget for its own JS, not for parsing.
  def self.compile_module(source, filename: nil, **opts)
    raise ::TypeError, "source must be a String, got #{source.class}" unless source.is_a?(String)
    unless filename.nil? || filename.is_a?(String)
      raise ::TypeError, "filename: must be a String, got #{filename.class}"
    end

    name = "#{filename || 'module'}-#{SecureRandom.hex(8)}"
    vm = VM.new(**{timeout_msec: 60_000, features: []}.merge(opts))
    Importable.new(vm.send(:_compile_module_to_bytecode, source, name), name)
  ensure
    vm&.dispose!
  end

  module ImportableSupport
    # `from:` an Importable reads the bytecode into this VM and then imports it
    # by name, so it takes the same path a preloaded module does: resolution
    # finds it in the module map and `module_loader` is never asked about it.
    # Reading is idempotent, so importing the same Importable repeatedly costs
    # nothing after the first.
    def import(imported, **opts)
      importable = opts[:from]
      return super unless importable.is_a?(Importable)

      send(:_preload_module_bytecode, importable.send(:bytecode), importable.name)
      super(imported, **opts.except(:from), filename: importable.name)
    end
  end

  VM.prepend(ImportableSupport) unless VM.ancestors.include?(ImportableSupport)
end
