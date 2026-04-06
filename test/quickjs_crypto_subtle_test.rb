# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  it "is not available without the polyfill" do
    _ { ::Quickjs.eval_code("crypto.subtle.digest('SHA-256', new Uint8Array([1,2,3]))") }.must_raise Quickjs::ReferenceError
  end

  describe "digest" do
    it "returns an ArrayBuffer" do
      code = "const buf = await crypto.subtle.digest('SHA-256', new Uint8Array([1,2,3])); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "produces correct SHA-256 digest" do
      code = <<~JS
        const buf = await crypto.subtle.digest('SHA-256', new Uint8Array([104, 101, 108, 108, 111]));
        Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('')
      JS
      result = ::Quickjs.eval_code(code, @options)
      _(result).must_equal "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    end

    it "produces correct SHA-1 digest" do
      code = <<~JS
        const buf = await crypto.subtle.digest('SHA-1', new Uint8Array([104, 101, 108, 108, 111]));
        buf.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 20
    end

    it "produces correct SHA-384 digest" do
      code = "const buf = await crypto.subtle.digest('SHA-384', new Uint8Array([1])); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 48
    end

    it "produces correct SHA-512 digest" do
      code = "const buf = await crypto.subtle.digest('SHA-512', new Uint8Array([1])); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 64
    end

    it "accepts algorithm as an object with name property" do
      code = "const buf = await crypto.subtle.digest({ name: 'SHA-256' }, new Uint8Array([1,2,3])); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "accepts ArrayBuffer as data" do
      code = <<~JS
        const buf = new ArrayBuffer(3);
        new Uint8Array(buf).set([1, 2, 3]);
        const result = await crypto.subtle.digest('SHA-256', buf);
        result.byteLength
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 32
    end

    it "rejects unsupported algorithm" do
      code = "await crypto.subtle.digest('MD5', new Uint8Array([1,2,3]))"
      _ { ::Quickjs.eval_code(code, @options) }.must_raise Quickjs::RuntimeError
    end
  end
end
