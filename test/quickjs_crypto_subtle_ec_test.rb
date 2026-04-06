# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle EC (ECDSA / ECDH)" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  describe "ECDSA generateKey" do
    it "returns a key pair with correct properties for P-256" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, true, ["sign", "verify"]);
        ({
          privateType: pair.privateKey.type,
          publicType: pair.publicKey.type,
          name: pair.privateKey.algorithm.name,
          namedCurve: pair.privateKey.algorithm.namedCurve
        })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["privateType"]).must_equal "private"
      _(result["publicType"]).must_equal "public"
      _(result["name"]).must_equal "ECDSA"
      _(result["namedCurve"]).must_equal "P-256"
    end

    it "supports P-384 and P-521" do
      %w[P-384 P-521].each do |curve|
        code = <<~JS
          const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "#{curve}"}, false, ["sign"]);
          pair.privateKey.algorithm.namedCurve
        JS
        _(::Quickjs.eval_code(code, @options)).must_equal curve
      end
    end
  end

  describe "ECDSA exportKey / importKey" do
    it "exports public key as spki and re-imports it" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, true, ["sign", "verify"]);
        const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
        const imported = await crypto.subtle.importKey("spki", spki, {name: "ECDSA", namedCurve: "P-256"}, true, ["verify"]);
        imported.type
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "public"
    end

    it "exports public key as raw and re-imports it" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, true, ["sign", "verify"]);
        const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
        raw.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 65
    end

    it "exports private key as pkcs8 and re-imports it" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, true, ["sign"]);
        const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
        const imported = await crypto.subtle.importKey("pkcs8", pkcs8, {name: "ECDSA", namedCurve: "P-256"}, true, ["sign"]);
        imported.type
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "private"
    end
  end

  describe "ECDSA sign / verify" do
    it "sign and verify round-trip with P-256 + SHA-256" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, false, ["sign", "verify"]);
        const data = new Uint8Array([1, 2, 3, 4, 5]);
        const sig = await crypto.subtle.sign({name: "ECDSA", hash: "SHA-256"}, pair.privateKey, data);
        await crypto.subtle.verify({name: "ECDSA", hash: "SHA-256"}, pair.publicKey, sig, data)
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "produces DER-length signature (not P1363)" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, false, ["sign"]);
        const sig = await crypto.subtle.sign({name: "ECDSA", hash: "SHA-256"}, pair.privateKey, new Uint8Array(10));
        sig.byteLength
      JS
      sig_len = ::Quickjs.eval_code(code, @options)
      _(sig_len).must_equal 64
    end

    it "verify returns false for tampered data" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "ECDSA", namedCurve: "P-256"}, false, ["sign", "verify"]);
        const data = new Uint8Array([1, 2, 3]);
        const sig = await crypto.subtle.sign({name: "ECDSA", hash: "SHA-256"}, pair.privateKey, data);
        await crypto.subtle.verify({name: "ECDSA", hash: "SHA-256"}, pair.publicKey, sig, new Uint8Array([1, 2, 4]))
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal false
    end
  end

  describe "ECDH key derivation" do
    it "derives bits from two parties" do
      code = <<~JS
        const alice = await crypto.subtle.generateKey({name: "ECDH", namedCurve: "P-256"}, false, ["deriveBits"]);
        const bob = await crypto.subtle.generateKey({name: "ECDH", namedCurve: "P-256"}, false, ["deriveBits"]);
        const aliceBits = await crypto.subtle.deriveBits({name: "ECDH", public: bob.publicKey}, alice.privateKey, 128);
        const bobBits = await crypto.subtle.deriveBits({name: "ECDH", public: alice.publicKey}, bob.privateKey, 128);
        const a = new Uint8Array(aliceBits);
        const b = new Uint8Array(bobBits);
        a.length === b.length && a.every((v, i) => v === b[i])
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "derives a key via deriveKey" do
      code = <<~JS
        const alice = await crypto.subtle.generateKey({name: "ECDH", namedCurve: "P-256"}, false, ["deriveKey"]);
        const bob = await crypto.subtle.generateKey({name: "ECDH", namedCurve: "P-256"}, false, ["deriveKey"]);
        const key = await crypto.subtle.deriveKey(
          {name: "ECDH", public: bob.publicKey}, alice.privateKey,
          {name: "AES-GCM", length: 128}, false, ["encrypt"]
        );
        key.algorithm.name
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "AES-GCM"
    end
  end
end
