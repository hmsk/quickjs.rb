# frozen_string_literal: true

require "json"
require_relative "quickjs/version"
require_relative "quickjs/quickjsrb"

module Quickjs
  FEATURE_STD = :std
  FEATURE_OS = :os

  def evalCode(
    code,
    opts = {
      memoryLimit: nil,
      maxStackSize: nil,
      features: []
    }
  )

    _evalCode(
      code,
      opts[:memoryLimit] || 1024 * 1024 * 128,
      opts[:maxStackSize] || 1024 * 1024 * 4,
      opts[:features].include?(Quickjs::FEATURE_STD),
      opts[:features].include?(Quickjs::FEATURE_OS),
    )
  end
  module_function :evalCode
end
