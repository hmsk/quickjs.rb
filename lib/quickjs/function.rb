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
      Quickjs._with_vm(on) {|vm| _call_on(vm, args) }
    end

    private

    def _call_on(vm, args)
      args_js = args.map { |a| JSON.generate(a) }.join(', ')
      vm.eval_code("(#{@source})(#{args_js})")
    end
  end
end
