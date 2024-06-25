# frozen_string_literal: true

require "json"
require_relative "quickjs/version"
require_relative "quickjs/quickjsrb"

module Quickjs
  MODULE_STD = :std
  MODULE_OS = :os

  def eval_code(
    code,
    opts = {
      memoryLimit: nil,
      maxStackSize: nil,
      features: []
    }
  )

    _eval_code(
      code,
      opts[:memoryLimit] || 1024 * 1024 * 128,
      opts[:maxStackSize] || 1024 * 1024 * 4,
      opts[:features].include?(Quickjs::MODULE_STD),
      opts[:features].include?(Quickjs::MODULE_OS),
    )
  end
  module_function :eval_code
end
