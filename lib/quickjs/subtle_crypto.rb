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

    AES_ALGORITHMS = %w[AES-GCM AES-CBC AES-CTR].freeze
    AES_VALID_LENGTHS = [128, 192, 256].freeze

    def self.digest(algorithm_name, data)
      ossl_name = DIGEST_ALGORITHMS[algorithm_name] or
        raise ArgumentError, "SubtleCrypto: unsupported digest algorithm '#{algorithm_name}'"
      OpenSSL::Digest.digest(ossl_name, data)
    end

    def self.generate_key(name, length, extractable, usages)
      raise ArgumentError, "SubtleCrypto: unsupported generateKey algorithm '#{name}'" unless AES_ALGORITHMS.include?(name)
      raise ArgumentError, "SubtleCrypto: invalid AES key length #{length}" unless AES_VALID_LENGTHS.include?(length)

      key_data = OpenSSL::Random.random_bytes(length / 8)
      Quickjs::CryptoKey.new("secret", extractable, { "name" => name, "length" => length }, usages, key_data)
    end

    def self.import_key(format, key_data, name, extractable, usages)
      case format
      when "raw"
        raise ArgumentError, "SubtleCrypto: unsupported importKey algorithm '#{name}'" unless AES_ALGORITHMS.include?(name)
        length = key_data.bytesize * 8
        raise ArgumentError, "SubtleCrypto: invalid AES key length #{length}" unless AES_VALID_LENGTHS.include?(length)
        Quickjs::CryptoKey.new("secret", extractable, { "name" => name, "length" => length }, usages, key_data)
      else
        raise ArgumentError, "SubtleCrypto: unsupported importKey format '#{format}'"
      end
    end

    def self.export_key(format, key)
      case format
      when "raw"
        raise ArgumentError, "SubtleCrypto: key is not extractable" unless key.extractable
        key.key_data
      else
        raise ArgumentError, "SubtleCrypto: unsupported exportKey format '#{format}'"
      end
    end

    def self.encrypt(name, key, data, params = {})
      case name
      when "AES-GCM"
        aes_gcm_encrypt(key, data, params)
      when "AES-CBC"
        aes_cbc_crypt(key, data, params, :encrypt)
      else
        raise ArgumentError, "SubtleCrypto: unsupported encrypt algorithm '#{name}'"
      end
    end

    def self.decrypt(name, key, data, params = {})
      case name
      when "AES-GCM"
        aes_gcm_decrypt(key, data, params)
      when "AES-CBC"
        aes_cbc_crypt(key, data, params, :decrypt)
      else
        raise ArgumentError, "SubtleCrypto: unsupported decrypt algorithm '#{name}'"
      end
    end

    def self.aes_gcm_encrypt(key, data, params)
      iv = params.fetch(:iv)
      tag_length = params.fetch(:tag_length, 128)
      additional_data = params[:additional_data]

      cipher = OpenSSL::Cipher.new("aes-#{key.algorithm["length"]}-gcm")
      cipher.encrypt
      cipher.key = key.key_data
      cipher.iv = iv
      cipher.auth_data = additional_data || ""
      ciphertext = cipher.update(data) + cipher.final
      tag = cipher.auth_tag(tag_length / 8)
      ciphertext + tag
    end
    private_class_method :aes_gcm_encrypt

    def self.aes_gcm_decrypt(key, data, params)
      iv = params.fetch(:iv)
      tag_length = params.fetch(:tag_length, 128)
      additional_data = params[:additional_data]

      tag_bytes = tag_length / 8
      ciphertext = data[0, data.bytesize - tag_bytes]
      tag = data[-tag_bytes, tag_bytes]

      decipher = OpenSSL::Cipher.new("aes-#{key.algorithm["length"]}-gcm")
      decipher.decrypt
      decipher.key = key.key_data
      decipher.iv = iv
      decipher.auth_tag = tag
      decipher.auth_data = additional_data || ""
      decipher.update(ciphertext) + decipher.final
    end
    private_class_method :aes_gcm_decrypt

    def self.aes_cbc_crypt(key, data, params, direction)
      iv = params.fetch(:iv)

      cipher = OpenSSL::Cipher.new("aes-#{key.algorithm["length"]}-cbc")
      direction == :encrypt ? cipher.encrypt : cipher.decrypt
      cipher.key = key.key_data
      cipher.iv = iv
      cipher.update(data) + cipher.final
    end
    private_class_method :aes_cbc_crypt
  end
end
