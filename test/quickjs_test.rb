# frozen_string_literal: true

require "test_helper"

class QuickjsTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Quickjs.const_defined?(:VERSION)
    end
  end

  test "support returning integer" do
    assert_equal(::Quickjs.evalCode("2+3"), 5)
    assert_equal(::Quickjs.evalCode("const func = () => 8; func();"), 8)
  end
end
