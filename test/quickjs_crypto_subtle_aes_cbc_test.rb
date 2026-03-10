# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle AES-CBC encrypt/decrypt" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  it "encrypts and decrypts round-trip" do
    code = <<~JS
      const rawKey = new Uint8Array(32);
      const iv = new Uint8Array(16);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-CBC"}, false, ["encrypt", "decrypt"]);
      const pt = new Uint8Array([1, 2, 3, 4, 5]);
      const ct = await crypto.subtle.encrypt({name: "AES-CBC", iv}, key, pt);
      const dt = await crypto.subtle.decrypt({name: "AES-CBC", iv}, key, ct);
      new Uint8Array(dt).join(',')
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal "1,2,3,4,5"
  end

  it "ciphertext is padded to a multiple of 16 bytes" do
    code = <<~JS
      const rawKey = new Uint8Array(16);
      const iv = new Uint8Array(16);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-CBC"}, false, ["encrypt"]);
      const ct = await crypto.subtle.encrypt({name: "AES-CBC", iv}, key, new Uint8Array(5));
      ct.byteLength
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal 16
  end

  it "produces deterministic ciphertext for same key+iv" do
    code = <<~JS
      const rawKey = new Uint8Array(16).fill(7);
      const iv = new Uint8Array(16).fill(3);
      const key = await crypto.subtle.importKey("raw", rawKey, {name: "AES-CBC"}, false, ["encrypt"]);
      const pt = new Uint8Array([10, 20, 30]);
      const ct1 = await crypto.subtle.encrypt({name: "AES-CBC", iv}, key, pt);
      const ct2 = await crypto.subtle.encrypt({name: "AES-CBC", iv}, key, pt);
      const a = new Uint8Array(ct1);
      const b = new Uint8Array(ct2);
      a.length === b.length && a.every((v, i) => v === b[i])
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal true
  end

  it "fails to decrypt with wrong key" do
    code = <<~JS
      const iv = new Uint8Array(16);
      const key1 = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), {name: "AES-CBC"}, false, ["encrypt", "decrypt"]);
      const key2 = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(2), {name: "AES-CBC"}, false, ["encrypt", "decrypt"]);
      const ct = await crypto.subtle.encrypt({name: "AES-CBC", iv}, key1, new Uint8Array([1, 2, 3]));
      await crypto.subtle.decrypt({name: "AES-CBC", iv}, key2, ct)
    JS
    _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
  end
end
