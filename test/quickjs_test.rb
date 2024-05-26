# frozen_string_literal: true

require "test_helper"

class QuickjsTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Quickjs.const_defined?(:VERSION)
    end
  end

  test "something useful" do
    assert_equal(::Quickjs.say_hi, "Hello!")
  end
end
