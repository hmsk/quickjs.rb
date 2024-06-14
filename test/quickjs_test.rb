# frozen_string_literal: true

require "test_helper"

class QuickjsTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Quickjs.const_defined?(:VERSION)
    end
  end

  test "throw an exception" do
    assert_raise_with_message(RuntimeError, /Something/) { ::Quickjs.evalCode("}{") }
  end

  test "support returning null" do
    assert_equal(::Quickjs.evalCode("null"), nil)
    assert_equal(::Quickjs.evalCode("const func = () => null; func();"), nil)
  end

  test "support returning undefined" do
    assert_equal(::Quickjs.evalCode("undefined"), Quickjs::Value::UNDEFINED)
    assert_equal(::Quickjs.evalCode("const obj = {}; obj.key;"), Quickjs::Value::UNDEFINED)
  end

  test "support returning NaN" do
    assert_equal(::Quickjs.evalCode("Number('whatever')"), Quickjs::Value::NAN)
  end

  test "support returning string" do
    assert_equal(::Quickjs.evalCode("'1'"), "1")
    assert_equal(::Quickjs.evalCode("const func = () => 'hello'; func();"), "hello")
  end

  test "support returning integer" do
    assert_equal(::Quickjs.evalCode("2+3"), 5)
    assert_equal(::Quickjs.evalCode("const func = () => 8; func();"), 8)
  end

  test "support returning boolean" do
    assert_equal(::Quickjs.evalCode("false"), false)
    assert_equal(::Quickjs.evalCode("true"), true)
    assert_equal(::Quickjs.evalCode("const func = () => 1 == 1; func();"), true)
    assert_equal(::Quickjs.evalCode("const func = () => 1 == 3; func();"), false)
  end

  class QuickjsTestFeatures < Test::Unit::TestCase
    test "std is disabled" do
      assert_equal(::Quickjs.evalCode("typeof std === 'undefined'"), true)
    end

    test "os is disabled" do
      assert_equal(::Quickjs.evalCode("typeof os === 'undefined'"), true)
    end

    test "std can be enabled" do
      assert_equal(::Quickjs.evalCode("!!std.urlGet", { features: [::Quickjs::FEATURE_STD] }), true)
    end

    test "os can be enabled" do
      assert_equal(::Quickjs.evalCode("!!os.kill", { features: [::Quickjs::FEATURE_OS] }), true)
    end
  end
end
