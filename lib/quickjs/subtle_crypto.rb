# frozen_string_literal: true

require "openssl"

module Quickjs
  module SubtleCrypto
    DIGEST_ALGORITHMS = {
      "SHA-1"   => "SHA1",
      "SHA-256" => "SHA256",
      "SHA-384" => "SHA384",
      "SHA-512" => "SHA512",
    }.freeze

    def self.digest(algorithm_name, data)
      ossl_name = DIGEST_ALGORITHMS[algorithm_name] or
        raise ArgumentError, "SubtleCrypto: unsupported digest algorithm '#{algorithm_name}'"
      OpenSSL::Digest.digest(ossl_name, data)
    end
  end
end
