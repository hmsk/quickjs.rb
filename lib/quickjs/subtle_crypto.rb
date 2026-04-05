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

    AES_ALGORITHMS = %w[AES-GCM AES-CBC AES-CTR AES-KW].freeze
    AES_VALID_LENGTHS = [128, 192, 256].freeze

    HMAC_HASH_OUTPUT_LENGTHS = {
      "SHA-1" => 160, "SHA-256" => 256, "SHA-384" => 384, "SHA-512" => 512,
    }.freeze

    EC_CURVE_MAP = {
      "P-256" => "prime256v1",
      "P-384" => "secp384r1",
      "P-521" => "secp521r1",
    }.freeze

    EC_COORD_SIZES = {
      "P-256" => 32, "P-384" => 48, "P-521" => 66,
    }.freeze

    RSA_ALGORITHMS = %w[RSASSA-PKCS1-v1_5 RSA-PSS RSA-OAEP].freeze
    ECDSA_ALGORITHMS = %w[ECDSA].freeze
    ECDH_ALGORITHMS = %w[ECDH X25519].freeze
    KDF_ALGORITHMS = %w[PBKDF2 HKDF].freeze

    def self.digest(algorithm_name, data)
      ossl_name = DIGEST_ALGORITHMS[algorithm_name] or
        raise ArgumentError, "SubtleCrypto: unsupported digest algorithm '#{algorithm_name}'"
      OpenSSL::Digest.digest(ossl_name, data)
    end

    def self.generate_key(algo, extractable, usages)
      name = algo[:name] or raise ArgumentError, "SubtleCrypto: algorithm name is required"
      case name
      when *AES_ALGORITHMS
        length = algo[:length] or raise ArgumentError, "SubtleCrypto: AES key requires length"
        raise ArgumentError, "SubtleCrypto: invalid AES key length #{length}" unless AES_VALID_LENGTHS.include?(length)
        key_data = OpenSSL::Random.random_bytes(length / 8)
        Quickjs::CryptoKey.new("secret", extractable, { "name" => name, "length" => length }, usages, key_data)
      when "HMAC"
        hash = algo[:hash] or raise ArgumentError, "SubtleCrypto: HMAC requires hash"
        length = algo[:length] || HMAC_HASH_OUTPUT_LENGTHS[hash] or
          raise ArgumentError, "SubtleCrypto: unsupported HMAC hash '#{hash}'"
        key_data = OpenSSL::Random.random_bytes(length / 8)
        Quickjs::CryptoKey.new("secret", extractable, { "name" => "HMAC", "hash" => hash, "length" => length }, usages, key_data)
      when *RSA_ALGORITHMS
        modulus_length = algo[:modulus_length] or raise ArgumentError, "SubtleCrypto: RSA key requires modulusLength"
        public_exponent_bytes = algo[:public_exponent] or raise ArgumentError, "SubtleCrypto: RSA key requires publicExponent"
        hash = algo[:hash] or raise ArgumentError, "SubtleCrypto: RSA key requires hash"
        exponent = public_exponent_bytes.bytes.reduce(0) { |acc, b| (acc << 8) | b }
        pkey = OpenSSL::PKey::RSA.generate(modulus_length, exponent)
        algo_hash = { "name" => name, "modulusLength" => modulus_length, "publicExponent" => public_exponent_bytes, "hash" => hash }
        {
          private_key: Quickjs::CryptoKey.new("private", extractable, algo_hash, usages.select { |u| %w[sign decrypt unwrapKey].include?(u) }, pkey),
          public_key: Quickjs::CryptoKey.new("public", true, algo_hash, usages.select { |u| %w[verify encrypt wrapKey].include?(u) }, pkey),
        }
      when "ECDSA", "ECDH"
        named_curve = algo[:named_curve] or raise ArgumentError, "SubtleCrypto: EC key requires namedCurve"
        ossl_curve = EC_CURVE_MAP[named_curve] or raise ArgumentError, "SubtleCrypto: unsupported curve '#{named_curve}'"
        pkey = OpenSSL::PKey::EC.generate(ossl_curve)
        algo_hash = { "name" => name, "namedCurve" => named_curve }
        private_usages = name == "ECDSA" ? %w[sign] : %w[deriveKey deriveBits]
        public_usages = name == "ECDSA" ? %w[verify] : []
        {
          private_key: Quickjs::CryptoKey.new("private", extractable, algo_hash, usages.select { |u| private_usages.include?(u) }, pkey),
          public_key: Quickjs::CryptoKey.new("public", true, algo_hash, usages.select { |u| public_usages.include?(u) }, pkey),
        }
      when "Ed25519"
        pkey = OpenSSL::PKey.generate_key("ED25519")
        algo_hash = { "name" => "Ed25519" }
        {
          private_key: Quickjs::CryptoKey.new("private", extractable, algo_hash, usages.select { |u| u == "sign" }, pkey),
          public_key: Quickjs::CryptoKey.new("public", true, algo_hash, usages.select { |u| u == "verify" }, pkey),
        }
      when "X25519"
        pkey = OpenSSL::PKey.generate_key("X25519")
        algo_hash = { "name" => "X25519" }
        {
          private_key: Quickjs::CryptoKey.new("private", extractable, algo_hash, usages.select { |u| %w[deriveKey deriveBits].include?(u) }, pkey),
          public_key: Quickjs::CryptoKey.new("public", true, algo_hash, [], pkey),
        }
      else
        raise ArgumentError, "SubtleCrypto: unsupported generateKey algorithm '#{name}'"
      end
    end

    def self.import_key(format, key_data, algo, extractable, usages)
      name = algo[:name] or raise ArgumentError, "SubtleCrypto: algorithm name is required"
      case format
      when "raw"
        case name
        when *AES_ALGORITHMS
          length = key_data.bytesize * 8
          raise ArgumentError, "SubtleCrypto: invalid AES key length #{length}" unless AES_VALID_LENGTHS.include?(length)
          Quickjs::CryptoKey.new("secret", extractable, { "name" => name, "length" => length }, usages, key_data)
        when "HMAC"
          hash = algo[:hash] or raise ArgumentError, "SubtleCrypto: HMAC requires hash"
          length = key_data.bytesize * 8
          Quickjs::CryptoKey.new("secret", extractable, { "name" => "HMAC", "hash" => hash, "length" => length }, usages, key_data)
        when "PBKDF2"
          Quickjs::CryptoKey.new("secret", false, { "name" => "PBKDF2" }, usages, key_data)
        when "HKDF"
          Quickjs::CryptoKey.new("secret", false, { "name" => "HKDF" }, usages, key_data)
        when "ECDSA", "ECDH"
          named_curve = algo[:named_curve] or raise ArgumentError, "SubtleCrypto: EC import requires namedCurve"
          pkey = import_raw_ec_public(key_data, named_curve)
          Quickjs::CryptoKey.new("public", extractable, { "name" => name, "namedCurve" => named_curve }, usages, pkey)
        when "Ed25519"
          pkey = import_raw_okp_public(key_data, "ED25519")
          Quickjs::CryptoKey.new("public", extractable, { "name" => "Ed25519" }, usages, pkey)
        when "X25519"
          pkey = import_raw_okp_public(key_data, "X25519")
          Quickjs::CryptoKey.new("public", extractable, { "name" => "X25519" }, usages, pkey)
        else
          raise ArgumentError, "SubtleCrypto: unsupported raw importKey algorithm '#{name}'"
        end
      when "spki"
        pkey = OpenSSL::PKey.read(key_data)
        case name
        when *RSA_ALGORITHMS
          rsa = pkey.is_a?(OpenSSL::PKey::RSA) ? pkey : raise(ArgumentError, "SubtleCrypto: key is not RSA")
          hash = algo[:hash] or raise ArgumentError, "SubtleCrypto: RSA import requires hash"
          pub_exp_bytes = [rsa.e.to_s(16)].pack("H*")
          algo_hash = { "name" => name, "modulusLength" => rsa.n.num_bits, "publicExponent" => pub_exp_bytes, "hash" => hash }
          Quickjs::CryptoKey.new("public", extractable, algo_hash, usages, pkey)
        when "ECDSA", "ECDH"
          named_curve = algo[:named_curve] or raise ArgumentError, "SubtleCrypto: EC import requires namedCurve"
          Quickjs::CryptoKey.new("public", extractable, { "name" => name, "namedCurve" => named_curve }, usages, pkey)
        when "Ed25519"
          Quickjs::CryptoKey.new("public", extractable, { "name" => "Ed25519" }, usages, pkey)
        when "X25519"
          Quickjs::CryptoKey.new("public", extractable, { "name" => "X25519" }, usages, pkey)
        else
          raise ArgumentError, "SubtleCrypto: unsupported spki importKey algorithm '#{name}'"
        end
      when "pkcs8"
        pkey = OpenSSL::PKey.read(key_data)
        case name
        when *RSA_ALGORITHMS
          hash = algo[:hash] or raise ArgumentError, "SubtleCrypto: RSA import requires hash"
          rsa = pkey.is_a?(OpenSSL::PKey::RSA) ? pkey : raise(ArgumentError, "SubtleCrypto: key is not RSA")
          pub_exp_bytes = [rsa.e.to_s(16)].pack("H*")
          algo_hash = { "name" => name, "modulusLength" => rsa.n.num_bits, "publicExponent" => pub_exp_bytes, "hash" => hash }
          Quickjs::CryptoKey.new("private", extractable, algo_hash, usages, pkey)
        when "ECDSA", "ECDH"
          named_curve = algo[:named_curve] or raise ArgumentError, "SubtleCrypto: EC import requires namedCurve"
          Quickjs::CryptoKey.new("private", extractable, { "name" => name, "namedCurve" => named_curve }, usages, pkey)
        when "Ed25519"
          Quickjs::CryptoKey.new("private", extractable, { "name" => "Ed25519" }, usages, pkey)
        when "X25519"
          Quickjs::CryptoKey.new("private", extractable, { "name" => "X25519" }, usages, pkey)
        else
          raise ArgumentError, "SubtleCrypto: unsupported pkcs8 importKey algorithm '#{name}'"
        end
      else
        raise ArgumentError, "SubtleCrypto: unsupported importKey format '#{format}'"
      end
    end

    def self.export_key(format, key)
      name = key.algorithm["name"]
      case format
      when "raw"
        raise ArgumentError, "SubtleCrypto: key is not extractable" unless key.extractable
        case name
        when *AES_ALGORITHMS, "HMAC"
          key.key_data
        when "ECDSA", "ECDH"
          raise ArgumentError, "SubtleCrypto: raw export only for public EC keys" unless key.type == "public"
          key.key_data.public_to_der.then { |spki_der| ec_spki_to_raw(spki_der) }
        when "Ed25519", "X25519"
          raise ArgumentError, "SubtleCrypto: raw export only for public OKP keys" unless key.type == "public"
          if key.key_data.respond_to?(:raw_public_key)
            key.key_data.raw_public_key
          else
            # raw_public_key added in openssl gem 3.2.0 (Ruby 3.3): https://github.com/ruby/openssl/blob/master/History.md
            # Ed25519/X25519 SPKI DER is 44 bytes with the 32-byte key at the end
            key.key_data.public_to_der[-32..]
          end
        else
          raise ArgumentError, "SubtleCrypto: raw export not supported for '#{name}'"
        end
      when "spki"
        raise ArgumentError, "SubtleCrypto: key is not extractable" unless key.extractable
        raise ArgumentError, "SubtleCrypto: spki export requires public key" unless key.type == "public"
        key.key_data.public_to_der
      when "pkcs8"
        raise ArgumentError, "SubtleCrypto: key is not extractable" unless key.extractable
        raise ArgumentError, "SubtleCrypto: pkcs8 export requires private key" unless key.type == "private"
        key.key_data.private_to_der
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
      when "AES-CTR"
        aes_ctr_crypt(key, data, params, :encrypt)
      when "AES-KW"
        aes_kw_crypt(key, data, :encrypt)
      when "RSA-OAEP"
        rsa_oaep_crypt(key, data, params, :encrypt)
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
      when "AES-CTR"
        aes_ctr_crypt(key, data, params, :decrypt)
      when "AES-KW"
        aes_kw_crypt(key, data, :decrypt)
      when "RSA-OAEP"
        rsa_oaep_crypt(key, data, params, :decrypt)
      else
        raise ArgumentError, "SubtleCrypto: unsupported decrypt algorithm '#{name}'"
      end
    end

    def self.sign(name, key, data, params = {})
      case name
      when "HMAC"
        hash_name = ossl_digest_name(key.algorithm["hash"])
        OpenSSL::HMAC.digest(hash_name, key.key_data, data)
      when "RSASSA-PKCS1-v1_5"
        hash_name = ossl_digest_name(key.algorithm["hash"])
        key.key_data.sign(hash_name, data)
      when "RSA-PSS"
        hash_name = ossl_digest_name(key.algorithm["hash"])
        salt_length = params[:salt_length] || :digest
        key.key_data.sign_pss(hash_name, data, salt_length: salt_length, mgf1_hash: hash_name)
      when "ECDSA"
        hash_name = ossl_digest_name(params[:hash] || key.algorithm["hash"])
        named_curve = key.algorithm["namedCurve"]
        coord_size = EC_COORD_SIZES[named_curve] or raise ArgumentError, "SubtleCrypto: unsupported curve '#{named_curve}'"
        der_sig = key.key_data.sign(hash_name, data)
        der_to_p1363(der_sig, coord_size)
      when "Ed25519"
        key.key_data.sign(nil, data)
      else
        raise ArgumentError, "SubtleCrypto: unsupported sign algorithm '#{name}'"
      end
    end

    def self.verify(name, key, signature, data, params = {})
      case name
      when "HMAC"
        hash_name = ossl_digest_name(key.algorithm["hash"])
        expected = OpenSSL::HMAC.digest(hash_name, key.key_data, data)
        OpenSSL::HMAC.hexdigest(hash_name, key.key_data, data) == OpenSSL::HMAC.hexdigest(hash_name, key.key_data, data) &&
          secure_compare(expected, signature)
      when "RSASSA-PKCS1-v1_5"
        hash_name = ossl_digest_name(key.algorithm["hash"])
        key.key_data.verify(hash_name, signature, data)
      when "RSA-PSS"
        hash_name = ossl_digest_name(key.algorithm["hash"])
        salt_length = params[:salt_length] || :digest
        key.key_data.verify_pss(hash_name, signature, data, salt_length: salt_length, mgf1_hash: hash_name)
      when "ECDSA"
        hash_name = ossl_digest_name(params[:hash] || key.algorithm["hash"])
        named_curve = key.algorithm["namedCurve"]
        coord_size = EC_COORD_SIZES[named_curve] or raise ArgumentError, "SubtleCrypto: unsupported curve '#{named_curve}'"
        begin
          der_sig = p1363_to_der(signature, coord_size)
          key.key_data.verify(hash_name, der_sig, data)
        rescue OpenSSL::PKey::PKeyError
          false
        end
      when "Ed25519"
        begin
          key.key_data.verify(nil, signature, data)
        rescue OpenSSL::PKey::PKeyError
          false
        end
      else
        raise ArgumentError, "SubtleCrypto: unsupported verify algorithm '#{name}'"
      end
    end

    def self.derive_bits(name, key, length_bits, params = {})
      case name
      when "PBKDF2"
        hash_name = ossl_digest_name(params[:hash]) or raise ArgumentError, "SubtleCrypto: PBKDF2 requires hash"
        salt = params[:salt] or raise ArgumentError, "SubtleCrypto: PBKDF2 requires salt"
        iterations = params[:iterations] or raise ArgumentError, "SubtleCrypto: PBKDF2 requires iterations"
        OpenSSL::KDF.pbkdf2_hmac(key.key_data, salt: salt, iterations: iterations, length: length_bits / 8, hash: hash_name)
      when "HKDF"
        hash_name = ossl_digest_name(params[:hash]) or raise ArgumentError, "SubtleCrypto: HKDF requires hash"
        salt = params[:salt] || ""
        info = params[:info] || ""
        OpenSSL::KDF.hkdf(key.key_data, salt: salt, info: info, length: length_bits / 8, hash: hash_name)
      when "ECDH"
        peer_key = params[:public] or raise ArgumentError, "SubtleCrypto: ECDH requires public key"
        shared = key.key_data.dh_compute_key(peer_key.key_data.public_key)
        shared.byteslice(0, length_bits / 8)
      when "X25519"
        peer_key = params[:public] or raise ArgumentError, "SubtleCrypto: X25519 requires public key"
        shared = key.key_data.derive(peer_key.key_data)
        shared.byteslice(0, length_bits / 8)
      else
        raise ArgumentError, "SubtleCrypto: unsupported deriveBits algorithm '#{name}'"
      end
    end

    def self.derive_key(name, key, derived_algo, extractable, usages, params = {})
      derived_name = derived_algo[:name] or raise ArgumentError, "SubtleCrypto: derived key algorithm name is required"
      derived_length = case derived_name
                       when *AES_ALGORITHMS then derived_algo[:length] or raise ArgumentError, "SubtleCrypto: derived AES key requires length"
                       when "HMAC" then derived_algo[:length] || HMAC_HASH_OUTPUT_LENGTHS[derived_algo[:hash]]
                       else raise ArgumentError, "SubtleCrypto: unsupported derived key algorithm '#{derived_name}'"
                       end
      key_bytes = derive_bits(name, key, derived_length, params)
      import_key("raw", key_bytes, derived_algo, extractable, usages)
    end

    def self.wrap_key(format, key, wrapping_key, wrap_algo_hash, wrap_name)
      key_data = export_key(format, key)
      encrypt(wrap_name, wrapping_key, key_data, wrap_algo_hash)
    end

    def self.unwrap_key(format, wrapped, unwrapping_key, unwrap_algo_hash, unwrapped_algo_hash, extractable, usages, unwrap_name)
      key_data = decrypt(unwrap_name, unwrapping_key, wrapped, unwrap_algo_hash)
      import_key(format, key_data, unwrapped_algo_hash, extractable, usages)
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
    rescue OpenSSL::Cipher::CipherError => e
      raise RuntimeError, "SubtleCrypto: AES-GCM decryption failed: #{e.message}"
    end
    private_class_method :aes_gcm_decrypt

    def self.aes_cbc_crypt(key, data, params, direction)
      iv = params.fetch(:iv)

      cipher = OpenSSL::Cipher.new("aes-#{key.algorithm["length"]}-cbc")
      direction == :encrypt ? cipher.encrypt : cipher.decrypt
      cipher.key = key.key_data
      cipher.iv = iv
      cipher.update(data) + cipher.final
    rescue OpenSSL::Cipher::CipherError => e
      raise RuntimeError, "SubtleCrypto: AES-CBC failed: #{e.message}"
    end
    private_class_method :aes_cbc_crypt

    def self.aes_kw_crypt(key, data, direction)
      bits = key.algorithm["length"]
      cipher = OpenSSL::Cipher.new("aes-#{bits}-wrap")
      direction == :encrypt ? cipher.encrypt : cipher.decrypt
      cipher.key = key.key_data
      cipher.update(data) + cipher.final
    rescue OpenSSL::Cipher::CipherError => e
      raise RuntimeError, "SubtleCrypto: AES-KW failed: #{e.message}"
    end
    private_class_method :aes_kw_crypt

    def self.aes_ctr_crypt(key, data, params, direction)
      counter = params.fetch(:counter)
      length = params[:length] || 64

      cipher = OpenSSL::Cipher.new("aes-#{key.algorithm["length"]}-ctr")
      direction == :encrypt ? cipher.encrypt : cipher.decrypt
      cipher.key = key.key_data
      cipher.iv = counter
      cipher.update(data) + cipher.final
    end
    private_class_method :aes_ctr_crypt

    def self.rsa_oaep_crypt(key, data, params, direction)
      hash_name = ossl_digest_name(key.algorithm["hash"])
      opts = { rsa_padding_mode: "oaep", rsa_oaep_md: hash_name, rsa_mgf1_md: hash_name }
      if direction == :encrypt
        key.key_data.encrypt(data, opts)
      else
        key.key_data.decrypt(data, opts)
      end
    rescue OpenSSL::PKey::PKeyError => e
      raise RuntimeError, "SubtleCrypto: RSA-OAEP failed: #{e.message}"
    end
    private_class_method :rsa_oaep_crypt

    def self.ossl_digest_name(hash_name)
      DIGEST_ALGORITHMS[hash_name] or raise ArgumentError, "SubtleCrypto: unsupported hash '#{hash_name}'"
    end
    private_class_method :ossl_digest_name

    def self.secure_compare(a, b)
      return false unless a.bytesize == b.bytesize
      OpenSSL.fixed_length_secure_compare(a, b)
    end
    private_class_method :secure_compare

    def self.der_to_p1363(der_sig, coord_size)
      asn = OpenSSL::ASN1.decode(der_sig)
      r_bn = asn.value[0].value
      s_bn = asn.value[1].value
      r_bytes = r_bn.to_s(2)
      s_bytes = s_bn.to_s(2)
      pad = "\x00" * coord_size
      r_padded = (pad + r_bytes).byteslice(-coord_size, coord_size)
      s_padded = (pad + s_bytes).byteslice(-coord_size, coord_size)
      r_padded + s_padded
    end
    private_class_method :der_to_p1363

    def self.p1363_to_der(p1363_sig, coord_size)
      r_bytes = p1363_sig.byteslice(0, coord_size)
      s_bytes = p1363_sig.byteslice(coord_size, coord_size)
      r_bn = OpenSSL::BN.new(r_bytes, 2)
      s_bn = OpenSSL::BN.new(s_bytes, 2)
      OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Integer(r_bn),
        OpenSSL::ASN1::Integer(s_bn),
      ]).to_der
    end
    private_class_method :p1363_to_der

    def self.import_raw_ec_public(raw_bytes, named_curve)
      ossl_curve = EC_CURVE_MAP[named_curve] or
        raise ArgumentError, "SubtleCrypto: unsupported EC curve '#{named_curve}'"
      ec_oid = OpenSSL::ASN1::ObjectId("id-ecPublicKey")
      curve_oid = OpenSSL::ASN1::ObjectId(ossl_curve)
      algo_seq = OpenSSL::ASN1::Sequence([ec_oid, curve_oid])
      spki = OpenSSL::ASN1::Sequence([algo_seq, OpenSSL::ASN1::BitString(raw_bytes)])
      OpenSSL::PKey.read(spki.to_der)
    end
    private_class_method :import_raw_ec_public

    def self.import_raw_okp_public(raw_bytes, ossl_algo)
      oid = OpenSSL::ASN1::ObjectId(ossl_algo)
      algo_seq = OpenSSL::ASN1::Sequence([oid])
      spki = OpenSSL::ASN1::Sequence([algo_seq, OpenSSL::ASN1::BitString(raw_bytes)])
      OpenSSL::PKey.read(spki.to_der)
    end
    private_class_method :import_raw_okp_public

    def self.ec_spki_to_raw(spki_der)
      asn = OpenSSL::ASN1.decode(spki_der)
      asn.value[1].value
    end
    private_class_method :ec_spki_to_raw
  end
end
