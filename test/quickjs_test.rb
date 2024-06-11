# frozen_string_literal: true

require "test_helper"

class QuickjsTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Quickjs.const_defined?(:VERSION)
    end
  end

  test "support returning null" do
    assert_equal(::Quickjs.evalCode("null"), nil)
    assert_equal(::Quickjs.evalCode("const func = () => null; func();"), nil)
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
end
