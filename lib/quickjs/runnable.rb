# frozen_string_literal: true

module Quickjs
  class Runnable
    def initialize(bytecode)
      @bytecode = bytecode
    end

    def to_s
      @bytecode
    end

    def run(on: nil)
      case on
      when Quickjs::VM
        on.send(:_run_bytecode, @bytecode)
      when nil, Hash
        vm = Quickjs::VM.new(**(on || {}))
        res = vm.send(:_run_bytecode, @bytecode)
        vm = nil
        res
      else
        raise ArgumentError, 'on: must be a Quickjs::VM, a Hash of VM options, or nil'
      end
    end
  end

  class VM
    def compile(source, **opts)
      Runnable.new(send(:_compile_to_bytecode, source, **opts))
    end
  end
end
