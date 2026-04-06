# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle AES-CTR encrypt/decrypt" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  it "encrypts and decrypts round-trip" do
    code = <<~JS
      const key = await crypto.subtle.generateKey({name: "AES-CTR", length: 256}, false, ["encrypt", "decrypt"]);
      const counter = new Uint8Array(16);
      const pt = new Uint8Array([1, 2, 3, 4, 5]);
      const ct = await crypto.subtle.encrypt({name: "AES-CTR", counter, length: 64}, key, pt);
      const dt = await crypto.subtle.decrypt({name: "AES-CTR", counter, length: 64}, key, ct);
      new Uint8Array(dt).join(',')
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal "1,2,3,4,5"
  end

  it "ciphertext is same length as plaintext (stream cipher)" do
    code = <<~JS
      const key = await crypto.subtle.generateKey({name: "AES-CTR", length: 128}, false, ["encrypt"]);
      const counter = new Uint8Array(16);
      const ct = await crypto.subtle.encrypt({name: "AES-CTR", counter, length: 64}, key, new Uint8Array(13));
      ct.byteLength
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal 13
  end

  it "produces deterministic ciphertext for same key+counter" do
    code = <<~JS
      const rawKey = new Uint8Array(16).fill(5);
      const counter = new Uint8Array(16).fill(3);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-CTR"}, false, ["encrypt"]);
      const pt = new Uint8Array([10, 20, 30]);
      const ct1 = new Uint8Array(await crypto.subtle.encrypt({name: "AES-CTR", counter, length: 64}, key, pt));
      const ct2 = new Uint8Array(await crypto.subtle.encrypt({name: "AES-CTR", counter, length: 64}, key, pt));
      ct1.every((v, i) => v === ct2[i])
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal true
  end
end
