# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle KDF (PBKDF2 / HKDF)" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  describe "PBKDF2" do
    it "importKey accepts raw password" do
      code = <<~JS
        const pw = new TextEncoder().encode("password");
        const key = await crypto.subtle.importKey("raw", pw, "PBKDF2", false, ["deriveBits"]);
        key.algorithm.name
      JS
      _(::Quickjs.eval_code(code, { features: [::Quickjs::POLYFILL_CRYPTO, ::Quickjs::POLYFILL_ENCODING] })).must_equal "PBKDF2"
    end

    it "deriveBits produces correct length" do
      code = <<~JS
        const pw = new Uint8Array([1, 2, 3]);
        const salt = new Uint8Array(16);
        const key = await crypto.subtle.importKey("raw", pw, "PBKDF2", false, ["deriveBits"]);
        const bits = await crypto.subtle.deriveBits(
          {name: "PBKDF2", salt, iterations: 1000, hash: "SHA-256"}, key, 256
        );
        bits.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "deriveBits is deterministic" do
      code = <<~JS
        const pw = new Uint8Array([42]);
        const salt = new Uint8Array([1, 2, 3, 4]);
        const key = await crypto.subtle.importKey("raw", pw, "PBKDF2", false, ["deriveBits"]);
        const params = {name: "PBKDF2", salt, iterations: 100, hash: "SHA-256"};
        const b1 = new Uint8Array(await crypto.subtle.deriveBits(params, key, 128));
        const b2 = new Uint8Array(await crypto.subtle.deriveBits(params, key, 128));
        b1.every((v, i) => v === b2[i])
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "deriveKey produces an AES key" do
      code = <<~JS
        const pw = new Uint8Array([1, 2, 3]);
        const salt = new Uint8Array(16);
        const key = await crypto.subtle.importKey("raw", pw, "PBKDF2", false, ["deriveKey"]);
        const derived = await crypto.subtle.deriveKey(
          {name: "PBKDF2", salt, iterations: 1000, hash: "SHA-256"},
          key, {name: "AES-GCM", length: 256}, false, ["encrypt"]
        );
        derived.algorithm.name
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "AES-GCM"
    end
  end

  describe "HKDF" do
    it "importKey accepts raw key material" do
      code = <<~JS
        const ikm = new Uint8Array(32);
        const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
        key.algorithm.name
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "HKDF"
    end

    it "deriveBits produces correct length" do
      code = <<~JS
        const ikm = new Uint8Array(32);
        const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
        const bits = await crypto.subtle.deriveBits(
          {name: "HKDF", salt: new Uint8Array(32), info: new Uint8Array(0), hash: "SHA-256"},
          key, 256
        );
        bits.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "deriveBits is deterministic" do
      code = <<~JS
        const ikm = new Uint8Array([1, 2, 3]);
        const salt = new Uint8Array([4, 5, 6]);
        const info = new Uint8Array([7, 8]);
        const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
        const params = {name: "HKDF", salt, info, hash: "SHA-256"};
        const b1 = new Uint8Array(await crypto.subtle.deriveBits(params, key, 128));
        const b2 = new Uint8Array(await crypto.subtle.deriveBits(params, key, 128));
        b1.every((v, i) => v === b2[i])
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "deriveKey produces an HMAC key" do
      code = <<~JS
        const ikm = new Uint8Array(32);
        const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveKey"]);
        const derived = await crypto.subtle.deriveKey(
          {name: "HKDF", salt: new Uint8Array(16), info: new Uint8Array(0), hash: "SHA-256"},
          key, {name: "HMAC", hash: "SHA-256"}, false, ["sign"]
        );
        derived.algorithm.name
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "HMAC"
    end
  end
end
