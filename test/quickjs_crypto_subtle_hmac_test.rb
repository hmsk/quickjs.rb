# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle HMAC" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  describe "generateKey" do
    it "returns a CryptoKey with correct properties" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "HMAC", hash: "SHA-256"}, true, ["sign", "verify"]);
        ({ type: key.type, name: key.algorithm.name, hash: key.algorithm.hash.name, length: key.algorithm.length })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["type"]).must_equal "secret"
      _(result["name"]).must_equal "HMAC"
      _(result["hash"]).must_equal "SHA-256"
      _(result["length"]).must_equal 256
    end

    it "uses hash output length as default key length" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "HMAC", hash: "SHA-512"}, true, ["sign"]);
        key.algorithm.length
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 512
    end

    it "respects explicit length" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "HMAC", hash: "SHA-256", length: 128}, true, ["sign"]);
        key.algorithm.length
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 128
    end
  end

  describe "importKey / exportKey" do
    it "imports raw HMAC key and exports it back" do
      code = <<~JS
        const raw = new Uint8Array(32).fill(7);
        const key = await crypto.subtle.importKey("raw", raw, {name: "HMAC", hash: "SHA-256"}, true, ["sign"]);
        const exported = await crypto.subtle.exportKey("raw", key);
        new Uint8Array(exported).every((v, i) => v === raw[i]) && exported.byteLength === 32
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end
  end

  describe "sign / verify" do
    it "sign produces a 32-byte MAC for SHA-256" do
      code = <<~JS
        const key = await crypto.subtle.importKey("raw", new Uint8Array(32), {name: "HMAC", hash: "SHA-256"}, false, ["sign"]);
        const sig = await crypto.subtle.sign("HMAC", key, new Uint8Array([1, 2, 3]));
        sig.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "verify returns true for correct signature" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "HMAC", hash: "SHA-256"}, false, ["sign", "verify"]);
        const data = new Uint8Array([10, 20, 30]);
        const sig = await crypto.subtle.sign("HMAC", key, data);
        await crypto.subtle.verify("HMAC", key, sig, data)
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "verify returns false for wrong signature" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "HMAC", hash: "SHA-256"}, false, ["sign", "verify"]);
        const data = new Uint8Array([10, 20, 30]);
        const wrongSig = new Uint8Array(32);
        await crypto.subtle.verify("HMAC", key, wrongSig, data)
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal false
    end

    it "verify returns false for tampered data" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "HMAC", hash: "SHA-256"}, false, ["sign", "verify"]);
        const data = new Uint8Array([10, 20, 30]);
        const sig = await crypto.subtle.sign("HMAC", key, data);
        await crypto.subtle.verify("HMAC", key, sig, new Uint8Array([10, 20, 31]))
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal false
    end

    it "sign produces deterministic MAC" do
      code = <<~JS
        const key = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), {name: "HMAC", hash: "SHA-256"}, false, ["sign"]);
        const data = new Uint8Array([1, 2, 3]);
        const s1 = new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
        const s2 = new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
        s1.every((v, i) => v === s2[i])
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end
  end
end
