# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle AES-GCM encrypt/decrypt" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  it "encrypts and decrypts round-trip" do
    code = <<~JS
      const key = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, false, ["encrypt", "decrypt"]);
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const plaintext = new TextEncoder().encode("hello world");
      const ciphertext = await crypto.subtle.encrypt({name: "AES-GCM", iv}, key, plaintext);
      const decrypted = await crypto.subtle.decrypt({name: "AES-GCM", iv}, key, ciphertext);
      new TextDecoder().decode(decrypted)
    JS
    _(::Quickjs.eval_code(code, { features: [::Quickjs::POLYFILL_CRYPTO, ::Quickjs::POLYFILL_ENCODING] })).must_equal "hello world"
  end

  it "produces deterministic ciphertext for same key+iv" do
    code = <<~JS
      const rawKey = new Uint8Array(32).fill(1);
      const iv = new Uint8Array(12).fill(2);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-GCM"}, false, ["encrypt"]);
      const ct1 = await crypto.subtle.encrypt({name: "AES-GCM", iv}, key, new Uint8Array([104, 101, 108, 108, 111]));
      const ct2 = await crypto.subtle.encrypt({name: "AES-GCM", iv}, key, new Uint8Array([104, 101, 108, 108, 111]));
      const a = new Uint8Array(ct1);
      const b = new Uint8Array(ct2);
      a.length === b.length && a.every((v, i) => v === b[i])
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal true
  end

  it "returns ciphertext with tag appended (byteLength = plaintext + 16)" do
    code = <<~JS
      const rawKey = new Uint8Array(32);
      const iv = new Uint8Array(12);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-GCM"}, false, ["encrypt"]);
      const ct = await crypto.subtle.encrypt({name: "AES-GCM", iv}, key, new Uint8Array(10));
      ct.byteLength
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal 26
  end

  it "supports custom tagLength (e.g. 96 bits = 12 bytes tag)" do
    code = <<~JS
      const rawKey = new Uint8Array(16);
      const iv = new Uint8Array(12);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-GCM"}, false, ["encrypt", "decrypt"]);
      const pt = new Uint8Array(5);
      const ct = await crypto.subtle.encrypt({name: "AES-GCM", iv, tagLength: 96}, key, pt);
      const dt = await crypto.subtle.decrypt({name: "AES-GCM", iv, tagLength: 96}, key, ct);
      ct.byteLength === 17 && dt.byteLength === 5
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal true
  end

  it "supports additionalData (AEAD)" do
    code = <<~JS
      const rawKey = new Uint8Array(32);
      const iv = new Uint8Array(12);
      const ad = new Uint8Array([1, 2, 3]);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-GCM"}, false, ["encrypt", "decrypt"]);
      const pt = new Uint8Array([10, 20, 30]);
      const ct = await crypto.subtle.encrypt({name: "AES-GCM", iv, additionalData: ad}, key, pt);
      const dt = await crypto.subtle.decrypt({name: "AES-GCM", iv, additionalData: ad}, key, ct);
      new Uint8Array(dt).join(',')
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal "10,20,30"
  end

  it "fails to decrypt with wrong iv" do
    code = <<~JS
      const rawKey = new Uint8Array(32);
      const iv1 = new Uint8Array(12).fill(1);
      const iv2 = new Uint8Array(12).fill(2);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-GCM"}, false, ["encrypt", "decrypt"]);
      const ct = await crypto.subtle.encrypt({name: "AES-GCM", iv: iv1}, key, new Uint8Array([1,2,3]));
      await crypto.subtle.decrypt({name: "AES-GCM", iv: iv2}, key, ct)
    JS
    _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
  end

  it "rejects unsupported algorithm" do
    code = <<~JS
      const rawKey = new Uint8Array(32);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-GCM"}, false, ["encrypt"]);
      await crypto.subtle.encrypt({name: "AES-XYZ"}, key, new Uint8Array([1]))
    JS
    _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
  end
end
