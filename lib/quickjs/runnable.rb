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
      Quickjs._with_vm(on) {|vm| vm.send(:_run_bytecode, @bytecode) }
    end
  end

  class VM
    def compile(source, **opts)
      Runnable.new(send(:_compile_to_bytecode, source, **opts))
    end
  end
end
