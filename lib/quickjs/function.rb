# frozen_string_literal: true

require 'json'

module Quickjs
  class Function
    def initialize(source)
      @source = source
    end

    def source
      @source
    end

    def call(*args, on: nil)
      case on
      when Quickjs::VM
        _call_on(on, args)
      when nil, Hash
        vm = Quickjs::VM.new(**on || {})
        res = _call_on(vm, args)
        vm = nil
        res
      else
        raise ArgumentError, 'on: must be a Quickjs::VM, a Hash of VM options, or nil'
      end
    end

    private

    def _call_on(vm, args)
      args_js = args.map { |a| JSON.generate(a) }.join(', ')
      vm.eval_code("(#{@source})(#{args_js})")
    end
  end
end
