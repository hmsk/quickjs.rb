# frozen_string_literal: true

module Quickjs
  class Runnable
    def initialize(body)
      @body = body
    end

    def call(on: nil)
      case on
      when Quickjs::VM
        on.eval_runnable(@body)
      when nil, Hash
        vm = Quickjs::VM.new(**on || {})
        res = vm.eval_runnable(@body)
        vm = nil
        res
      else
        raise 'unintentional arguments'
      end
    end
  end
end
