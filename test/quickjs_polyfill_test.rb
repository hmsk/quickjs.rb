# frozen_string_literal: true

require_relative "test_helper"

describe "PolyfillIntl" do
  before do
    @options_to_enable_polyfill = { features: [::Quickjs::POLYFILL_INTL] }
  end

  describe "Intl.DateTimeFormat" do
    it "polyfill is provided by the feature" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'UTC', timeStyle: 'long', dateStyle: 'short' })"

      _(::Quickjs.eval_code(code)).must_match(/^03\/1(1|0)\/2025,\s/)
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '3/10/25, 3:00:00 PM UTC'
    end

    it "is a bit diff from common behavior for default options" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'America/Los_Angeles' })"

      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal '3/10/2025'
    end

    it "is a bit diff from common behavior for delimiter of time format" do
      code = "new Date('2025-03-11T00:00:00.000+09:00').toLocaleString('en-US', { timeZone: 'America/Los_Angeles', timeStyle: 'long', dateStyle: 'long' })"

      _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal 'March 10, 2025, 8:00:00 AM PDT'
    end

    # Timezones beyond UTC and America/Los_Angeles are available thanks to add-all-tz.js
    describe "with all timezones" do
      it "supports Asia/Tokyo timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Tokyo', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-01-01T00:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '1/1/25, 9:00:00 AM GMT+9'
      end

      it "supports Europe/London timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Europe/London', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-01-15T12:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '1/15/25, 12:00:00 PM GMT'
      end

      it "supports Pacific/Auckland timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Auckland', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-01-01T00:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '1/1/25, 1:00:00 PM GMT+13'
      end

      it "supports Africa/Nairobi timezone" do
        code = "new Intl.DateTimeFormat('en-US', { timeZone: 'Africa/Nairobi', timeStyle: 'long', dateStyle: 'short' }).format(new Date('2025-06-15T00:00:00.000Z'))"

        _(::Quickjs.eval_code(code, @options_to_enable_polyfill).gsub(/[[:space:]]/, ' ')).must_equal '6/15/25, 3:00:00 AM GMT+3'
      end
    end
  end

  describe "Intl.Locale" do
    it "polyfill is provided" do
      code = 'new Intl.Locale("ja-Jpan-JP-u-ca-japanese-hc-h12").toString()'

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal 'ja-Jpan-JP-u-ca-japanese-hc-h12'
    end
  end

  describe "Intl.PluralRules" do
    it "polyfill is provided" do
      code = 'new Intl.PluralRules("en-US").select(1);'

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal 'one'
    end
  end

  describe "Intl.NumberFormat" do
    it "polyfill is provided" do
      code = "new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(12345)"

      _ { ::Quickjs.eval_code(code) }.must_raise Quickjs::ReferenceError
      _(::Quickjs.eval_code(code, @options_to_enable_polyfill)).must_equal '$12,345.00'
    end
  end
end
