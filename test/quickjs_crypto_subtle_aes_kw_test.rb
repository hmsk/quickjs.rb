# frozen_string_literal: true

require_relative "test_helper"

describe "crypto.subtle AES-KW wrapKey/unwrapKey" do
  before do
    @options = { features: [::Quickjs::POLYFILL_CRYPTO] }
  end

  it "wraps and unwraps an AES-GCM key round-trip" do
    code = <<~JS
      const wrappingKey = await crypto.subtle.generateKey({name: "AES-KW", length: 256}, false, ["wrapKey", "unwrapKey"]);
      const keyToWrap = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt"]);
      const wrapped = await crypto.subtle.wrapKey("raw", keyToWrap, wrappingKey, {name: "AES-KW"});
      const unwrapped = await crypto.subtle.unwrapKey(
        "raw", wrapped, wrappingKey, {name: "AES-KW"},
        {name: "AES-GCM", length: 256}, true, ["encrypt"]
      );
      unwrapped.algorithm.name
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal "AES-GCM"
  end

  it "wrapped key is 8 bytes longer than the raw key (AES-KW overhead)" do
    code = <<~JS
      const wrappingKey = await crypto.subtle.generateKey({name: "AES-KW", length: 128}, false, ["wrapKey"]);
      const keyToWrap = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, true, ["encrypt"]);
      const wrapped = await crypto.subtle.wrapKey("raw", keyToWrap, wrappingKey, {name: "AES-KW"});
      wrapped.byteLength
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal 40
  end

  it "unwrapped key data matches original" do
    code = <<~JS
      const rawKey = new Uint8Array(16).fill(42);
      const wrappingKey = await crypto.subtle.generateKey({name: "AES-KW", length: 256}, false, ["wrapKey", "unwrapKey"]);
      const keyToWrap = await crypto.subtle.importKey("raw", rawKey, {name: "AES-GCM"}, true, ["encrypt"]);
      const wrapped = await crypto.subtle.wrapKey("raw", keyToWrap, wrappingKey, {name: "AES-KW"});
      const unwrapped = await crypto.subtle.unwrapKey(
        "raw", wrapped, wrappingKey, {name: "AES-KW"},
        {name: "AES-GCM", length: 128}, true, ["encrypt"]
      );
      const exported = await crypto.subtle.exportKey("raw", unwrapped);
      new Uint8Array(exported).every((v, i) => v === rawKey[i])
    JS
    _(::Quickjs.eval_code(code, @options)).must_equal true
  end
end
