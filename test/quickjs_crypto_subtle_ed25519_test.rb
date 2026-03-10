# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle Ed25519 / X25519" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  describe "Ed25519" do
    it "generates a key pair with correct properties" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "Ed25519"}, true, ["sign", "verify"]);
        ({ privateType: pair.privateKey.type, publicType: pair.publicKey.type, name: pair.privateKey.algorithm.name })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["privateType"]).must_equal "private"
      _(result["publicType"]).must_equal "public"
      _(result["name"]).must_equal "Ed25519"
    end

    it "sign and verify round-trip" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "Ed25519"}, false, ["sign", "verify"]);
        const data = new Uint8Array([1, 2, 3, 4, 5]);
        const sig = await crypto.subtle.sign("Ed25519", pair.privateKey, data);
        await crypto.subtle.verify("Ed25519", pair.publicKey, sig, data)
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "signature is 64 bytes" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "Ed25519"}, false, ["sign"]);
        const sig = await crypto.subtle.sign("Ed25519", pair.privateKey, new Uint8Array(10));
        sig.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 64
    end

    it "verify returns false for tampered data" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "Ed25519"}, false, ["sign", "verify"]);
        const data = new Uint8Array([1, 2, 3]);
        const sig = await crypto.subtle.sign("Ed25519", pair.privateKey, data);
        await crypto.subtle.verify("Ed25519", pair.publicKey, sig, new Uint8Array([1, 2, 4]))
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal false
    end

    it "exports and imports public key (spki)" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "Ed25519"}, true, ["sign", "verify"]);
        const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
        const imported = await crypto.subtle.importKey("spki", spki, {name: "Ed25519"}, true, ["verify"]);
        imported.type
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "public"
    end

    it "exports public key as raw (32 bytes)" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "Ed25519"}, true, ["sign"]);
        const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
        raw.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "sign with exported-then-imported key pair" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "Ed25519"}, true, ["sign", "verify"]);
        const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
        const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
        const pubKey = await crypto.subtle.importKey("spki", spki, {name: "Ed25519"}, true, ["verify"]);
        const privKey = await crypto.subtle.importKey("pkcs8", pkcs8, {name: "Ed25519"}, true, ["sign"]);
        const data = new Uint8Array([10, 20, 30]);
        const sig = await crypto.subtle.sign("Ed25519", privKey, data);
        await crypto.subtle.verify("Ed25519", pubKey, sig, data)
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end
  end

  describe "X25519" do
    it "generates a key pair with correct properties" do
      code = <<~JS
        const pair = await crypto.subtle.generateKey({name: "X25519"}, true, ["deriveKey", "deriveBits"]);
        ({ privateType: pair.privateKey.type, publicType: pair.publicKey.type, name: pair.privateKey.algorithm.name })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["privateType"]).must_equal "private"
      _(result["name"]).must_equal "X25519"
    end

    it "derives same bits for both parties" do
      code = <<~JS
        const alice = await crypto.subtle.generateKey({name: "X25519"}, true, ["deriveBits"]);
        const bob = await crypto.subtle.generateKey({name: "X25519"}, true, ["deriveBits"]);
        const aliceBits = await crypto.subtle.deriveBits({name: "X25519", public: bob.publicKey}, alice.privateKey, 256);
        const bobBits = await crypto.subtle.deriveBits({name: "X25519", public: alice.publicKey}, bob.privateKey, 256);
        const a = new Uint8Array(aliceBits);
        const b = new Uint8Array(bobBits);
        a.length === 32 && b.length === 32 && a.every((v, i) => v === b[i])
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end
  end
end
