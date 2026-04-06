# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle RSA" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
    @rsa_algo = "{name: 'RSASSA-PKCS1-v1_5', modulusLength: 1024, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256'}"
    @pss_algo = "{name: 'RSA-PSS', modulusLength: 1024, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256'}"
  end

  describe "generateKey" do
    it "returns a key pair with correct properties for RSASSA-PKCS1-v1_5" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey(#{@rsa_algo}, true, ["sign", "verify"]);
        ({
          privateType: pair.privateKey.type,
          publicType: pair.publicKey.type,
          name: pair.privateKey.algorithm.name,
          hash: pair.privateKey.algorithm.hash.name,
          modulusLength: pair.privateKey.algorithm.modulusLength
        })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["privateType"]).must_equal "private"
      _(result["publicType"]).must_equal "public"
      _(result["name"]).must_equal "RSASSA-PKCS1-v1_5"
      _(result["hash"]).must_equal "SHA-256"
      _(result["modulusLength"]).must_equal 1024
    end

    it "generates RSA-PSS key pair" do
      code = "const pair = await crypto.subtle.generateKey(#{@pss_algo}, false, ['sign', 'verify']); pair.privateKey.algorithm.name"
      _(::Quickjs.eval_code(code, @options)).must_equal "RSA-PSS"
    end
  end

  describe "exportKey / importKey" do
    it "exports public key as spki and re-imports it" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey(#{@rsa_algo}, true, ["sign", "verify"]);
        const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
        const imported = await crypto.subtle.importKey("spki", spki, {name: "RSASSA-PKCS1-v1_5", hash: "SHA-256"}, true, ["verify"]);
        imported.type
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "public"
    end

    it "exports private key as pkcs8 and re-imports it" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey(#{@rsa_algo}, true, ["sign", "verify"]);
        const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
        const imported = await crypto.subtle.importKey("pkcs8", pkcs8, {name: "RSASSA-PKCS1-v1_5", hash: "SHA-256"}, true, ["sign"]);
        imported.type
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "private"
    end
  end

  describe "sign / verify with RSASSA-PKCS1-v1_5" do
    it "sign and verify round-trip" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey(#{@rsa_algo}, false, ["sign", "verify"]);
        const data = new Uint8Array([1, 2, 3, 4, 5]);
        const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, data);
        await crypto.subtle.verify("RSASSA-PKCS1-v1_5", pair.publicKey, sig, data)
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "verify returns false for wrong data" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey(#{@rsa_algo}, false, ["sign", "verify"]);
        const data = new Uint8Array([1, 2, 3]);
        const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, data);
        await crypto.subtle.verify("RSASSA-PKCS1-v1_5", pair.publicKey, sig, new Uint8Array([1, 2, 4]))
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal false
    end
  end

  describe "sign / verify with RSA-PSS" do
    it "sign and verify round-trip" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey(#{@pss_algo}, false, ["sign", "verify"]);
        const data = new Uint8Array([10, 20, 30]);
        const sig = await crypto.subtle.sign({name: "RSA-PSS", saltLength: 32}, pair.privateKey, data);
        await crypto.subtle.verify({name: "RSA-PSS", saltLength: 32}, pair.publicKey, sig, data)
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end
  end
end
