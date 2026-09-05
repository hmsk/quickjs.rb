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

    # The bytes stay out of the string form. to_js_value has no case for this
    # class, so anything that hands a key back to JS, a pass-through
    # define_function or a logged value, converts it by calling this: a key
    # generated with extractable: false would otherwise reach the guest in full
    # through a function that exportKey refuses one call away.
    def inspect
      format(
        '#<%s type=%p extractable=%p algorithm=%p usages=%p key_data=[FILTERED]>',
        self.class, @type, @extractable, @algorithm, @usages
      )
    end
    alias to_s inspect
  end
end
