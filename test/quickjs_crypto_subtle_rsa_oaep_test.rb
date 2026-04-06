# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle RSA-OAEP encrypt/decrypt" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
    @algo = "{name: 'RSA-OAEP', modulusLength: 1024, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256'}"
  end

  it "encrypts and decrypts round-trip" do
    code = <<~JS
      const pair = await crypto.subtle.generateKey(#{@algo}, false, ["encrypt", "decrypt"]);
      const pt = new Uint8Array([1, 2, 3, 4, 5]);
      const ct = await crypto.subtle.encrypt({name: "RSA-OAEP"}, pair.publicKey, pt);
      const dt = await crypto.subtle.decrypt({name: "RSA-OAEP"}, pair.privateKey, ct);
      new Uint8Array(dt).join(',')
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal "1,2,3,4,5"
  end

  it "ciphertext size equals key modulus size (1024 bit = 128 bytes)" do
    code = <<~JS
      const pair = await crypto.subtle.generateKey(#{@algo}, false, ["encrypt"]);
      const ct = await crypto.subtle.encrypt({name: "RSA-OAEP"}, pair.publicKey, new Uint8Array(5));
      ct.byteLength
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal 128
  end

  it "fails to decrypt with wrong key" do
    code = <<~JS
      const pair1 = await crypto.subtle.generateKey(#{@algo}, false, ["encrypt", "decrypt"]);
      const pair2 = await crypto.subtle.generateKey(#{@algo}, false, ["encrypt", "decrypt"]);
      const ct = await crypto.subtle.encrypt({name: "RSA-OAEP"}, pair1.publicKey, new Uint8Array([1, 2, 3]));
      await crypto.subtle.decrypt({name: "RSA-OAEP"}, pair2.privateKey, ct)
    JS
    _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
  end
end
