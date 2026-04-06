# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle key management" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  describe "generateKey" do
    it "returns a CryptoKey with correct properties for AES-GCM 256" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt", "decrypt"]);
        ({ type: key.type, extractable: key.extractable, name: key.algorithm.name, length: key.algorithm.length, usages: key.usages })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["type"]).must_equal "secret"
      _(result["extractable"]).must_equal true
      _(result["name"]).must_equal "AES-GCM"
      _(result["length"]).must_equal 256
      _(result["usages"]).must_equal ["encrypt", "decrypt"]
    end

    it "supports AES-CBC and AES-CTR" do
      %w[AES-CBC AES-CTR].each do |name|
        code = "const key = await crypto.subtle.generateKey({name: '#{name}', length: 128}, false, ['encrypt']); key.algorithm.name"
        _(::Quickjs.eval_code(code, @options)).must_equal name
      end
    end

    it "supports 128 and 192 bit key lengths" do
      [128, 192].each do |len|
        code = "const key = await crypto.subtle.generateKey({name: 'AES-GCM', length: #{len}}, true, ['encrypt']); key.algorithm.length"
        _(::Quickjs.eval_code(code, @options)).must_equal len
      end
    end

    it "rejects unsupported algorithm" do
      code = "await crypto.subtle.generateKey({name: 'RSA-PSS', length: 2048}, true, ['sign'])"
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end

    it "rejects invalid key length" do
      code = "await crypto.subtle.generateKey({name: 'AES-GCM', length: 512}, true, ['encrypt'])"
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end

    it "rb_object_id is not enumerable (not included in JSON.stringify)" do
      code = "const key = await crypto.subtle.generateKey({name: 'AES-GCM', length: 256}, true, ['encrypt']); Object.keys(key).includes('rb_object_id')"
      _(::Quickjs.eval_code(code, @options)).must_equal false
    end
  end

  describe "exportKey" do
    it "exports a raw AES-GCM key with correct byte length" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt", "decrypt"]);
        const raw = await crypto.subtle.exportKey("raw", key);
        raw.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "exports 128-bit key as 16 bytes" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 128}, true, ["encrypt"]);
        const raw = await crypto.subtle.exportKey("raw", key);
        raw.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 16
    end

    it "rejects export of non-extractable key" do
      code = <<~JS
        const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, false, ["encrypt"]);
        await crypto.subtle.exportKey("raw", key)
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end
  end

  describe "importKey" do
    it "imports a raw key and returns correct properties" do
      code = <<~JS
        const raw = new Uint8Array(32);
        const key = await crypto.subtle.importKey("raw", raw, {name: "AES-GCM"}, true, ["encrypt", "decrypt"]);
        ({ type: key.type, name: key.algorithm.name, length: key.algorithm.length })
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result["type"]).must_equal "secret"
      _(result["name"]).must_equal "AES-GCM"
      _(result["length"]).must_equal 256
    end

    it "round-trips key data through exportKey → importKey → exportKey" do
      code = <<~JS
        const key1 = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt"]);
        const raw1 = await crypto.subtle.exportKey("raw", key1);
        const key2 = await crypto.subtle.importKey("raw", raw1, {name: "AES-GCM"}, true, ["encrypt"]);
        const raw2 = await crypto.subtle.exportKey("raw", key2);
        const a = new Uint8Array(raw1);
        const b = new Uint8Array(raw2);
        a.every((v, i) => v === b[i])
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "rejects unsupported format" do
      code = <<~JS
        const raw = new Uint8Array(32);
        await crypto.subtle.importKey("jwk", raw, {name: "AES-GCM"}, true, ["encrypt"])
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end

    it "rejects invalid key length" do
      code = <<~JS
        const raw = new Uint8Array(10);
        await crypto.subtle.importKey("raw", raw, {name: "AES-GCM"}, true, ["encrypt"])
      JS
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end
  end
end
