# frozen_string_literal: true

require "json"
require_relative "quickjs/version"
require_relative "quickjs/quickjsrb"

module Quickjs
  def eval_code(
    code,
    overwrite_opts = {}
  )

    Quickjs::VM.new(**overwrite_opts).eval_code(code)
  end
  module_function :eval_code
end
