# frozen_string_literal: true

module Quickjs
  class CryptoKey
    attr_reader :type, :extractable, :algorithm, :usages, :key_data

    def initialize(type, extractable, algorithm, usages, key_data)
      @type = type
      @extractable = extractable
      @algorithm = algorithm
      @usages = usages
      @key_data = key_data
    end
  end
end
