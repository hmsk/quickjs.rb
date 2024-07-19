# frozen_string_literal: true

require "json"
require_relative "quickjs/version"
require_relative "quickjs/quickjsrb"

module Quickjs
  def eval_code(code, overwrite_opts = {})
    vm = Quickjs::VM.new(**overwrite_opts)
    res = vm.eval_code(code)
    vm = nil
    res
  end
  module_function :eval_code
end
