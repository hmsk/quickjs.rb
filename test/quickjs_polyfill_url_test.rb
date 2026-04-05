# frozen_string_literal: true

require_relative "test_helper"

describe "PolyfillURL" do
  before do
    @options = { features: [::Quickjs::POLYFILL_URL] }
  end

  describe "URL" do
    it "is not available without the feature" do
      _(proc { ::Quickjs.eval_code("new URL('https://example.com/')") }).must_raise ::Quickjs::ReferenceError
    end

    it "parses a basic URL" do
      _(::Quickjs.eval_code("new URL('https://example.com/').href", @options)).must_equal "https://example.com/"
    end

    it "exposes protocol" do
      _(::Quickjs.eval_code("new URL('https://example.com/').protocol", @options)).must_equal "https:"
    end

    it "exposes hostname" do
      _(::Quickjs.eval_code("new URL('https://example.com/path').hostname", @options)).must_equal "example.com"
    end

    it "exposes pathname" do
      _(::Quickjs.eval_code("new URL('https://example.com/path/to/page').pathname", @options)).must_equal "/path/to/page"
    end

    it "exposes port" do
      _(::Quickjs.eval_code("new URL('https://example.com:8080/').port", @options)).must_equal "8080"
    end

    it "returns empty string for default port" do
      _(::Quickjs.eval_code("new URL('https://example.com:443/').port", @options)).must_equal ""
    end

    it "exposes search" do
      _(::Quickjs.eval_code("new URL('https://example.com/?foo=bar').search", @options)).must_equal "?foo=bar"
    end

    it "exposes hash" do
      _(::Quickjs.eval_code("new URL('https://example.com/#section').hash", @options)).must_equal "#section"
    end

    it "exposes origin" do
      _(::Quickjs.eval_code("new URL('https://example.com/path').origin", @options)).must_equal "https://example.com"
    end

    it "exposes host with port" do
      _(::Quickjs.eval_code("new URL('https://example.com:8080/').host", @options)).must_equal "example.com:8080"
    end

    it "handles username and password" do
      _(::Quickjs.eval_code("new URL('https://user:pass@example.com/').username", @options)).must_equal "user"
      _(::Quickjs.eval_code("new URL('https://user:pass@example.com/').password", @options)).must_equal "pass"
    end

    it "resolves relative URL against base" do
      _(::Quickjs.eval_code("new URL('/path', 'https://example.com').href", @options)).must_equal "https://example.com/path"
    end

    it "resolves relative path against base" do
      _(::Quickjs.eval_code("new URL('page.html', 'https://example.com/dir/').href", @options)).must_equal "https://example.com/dir/page.html"
    end

    it "normalizes path dots" do
      _(::Quickjs.eval_code("new URL('https://example.com/a/b/../c').pathname", @options)).must_equal "/a/c"
    end

    it "throws TypeError for invalid URL" do
      _(proc { ::Quickjs.eval_code("new URL('not a url')", @options) }).must_raise ::Quickjs::TypeError
    end

    it "throws TypeError for invalid base" do
      _(proc { ::Quickjs.eval_code("new URL('/path', 'not a url')", @options) }).must_raise ::Quickjs::TypeError
    end

    it "supports toString" do
      _(::Quickjs.eval_code("new URL('https://example.com/').toString()", @options)).must_equal "https://example.com/"
    end

    it "supports toJSON" do
      _(::Quickjs.eval_code("new URL('https://example.com/').toJSON()", @options)).must_equal "https://example.com/"
    end

    it "supports URL.canParse" do
      _(::Quickjs.eval_code("URL.canParse('https://example.com/')", @options)).must_equal true
      _(::Quickjs.eval_code("URL.canParse('not a url')", @options)).must_equal false
    end

    it "supports URL.parse" do
      _(::Quickjs.eval_code("URL.parse('https://example.com/').href", @options)).must_equal "https://example.com/"
      _(::Quickjs.eval_code("URL.parse('not a url')", @options)).must_be_nil
    end

    it "supports setting href" do
      code = <<~JS
        const u = new URL('https://example.com/');
        u.href = 'https://other.com/path';
        u.href
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "https://other.com/path"
    end

    it "supports setting pathname" do
      code = <<~JS
        const u = new URL('https://example.com/old');
        u.pathname = '/new';
        u.pathname
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "/new"
    end

    it "supports setting search" do
      code = <<~JS
        const u = new URL('https://example.com/');
        u.search = '?key=value';
        u.search
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "?key=value"
    end

    it "supports setting hash" do
      code = <<~JS
        const u = new URL('https://example.com/');
        u.hash = '#anchor';
        u.hash
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "#anchor"
    end
  end

  describe "URLSearchParams" do
    it "is not available without the feature" do
      _(proc { ::Quickjs.eval_code("new URLSearchParams('foo=bar').get('foo')") }).must_raise ::Quickjs::ReferenceError
    end

    it "parses a query string" do
      _(::Quickjs.eval_code("new URLSearchParams('foo=bar').get('foo')", @options)).must_equal "bar"
    end

    it "parses a query string with leading ?" do
      _(::Quickjs.eval_code("new URLSearchParams('?foo=bar').get('foo')", @options)).must_equal "bar"
    end

    it "returns null for missing key" do
      _(::Quickjs.eval_code("new URLSearchParams('foo=bar').get('baz')", @options)).must_be_nil
    end

    it "supports has" do
      _(::Quickjs.eval_code("new URLSearchParams('foo=bar').has('foo')", @options)).must_equal true
      _(::Quickjs.eval_code("new URLSearchParams('foo=bar').has('baz')", @options)).must_equal false
    end

    it "supports getAll" do
      _(::Quickjs.eval_code("JSON.stringify(new URLSearchParams('foo=1&foo=2').getAll('foo'))", @options)).must_equal '["1","2"]'
    end

    it "supports append" do
      code = <<~JS
        const p = new URLSearchParams('foo=1');
        p.append('foo', '2');
        JSON.stringify(p.getAll('foo'))
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal '["1","2"]'
    end

    it "supports delete" do
      code = <<~JS
        const p = new URLSearchParams('foo=1&bar=2');
        p.delete('foo');
        p.toString()
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "bar=2"
    end

    it "supports set" do
      code = <<~JS
        const p = new URLSearchParams('foo=1&foo=2');
        p.set('foo', '3');
        p.toString()
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "foo=3"
    end

    it "supports sort" do
      code = <<~JS
        const p = new URLSearchParams('b=2&a=1');
        p.sort();
        p.toString()
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "a=1&b=2"
    end

    it "supports toString" do
      _(::Quickjs.eval_code("new URLSearchParams('foo=bar&baz=qux').toString()", @options)).must_equal "foo=bar&baz=qux"
    end

    it "supports size" do
      _(::Quickjs.eval_code("new URLSearchParams('foo=1&bar=2').size", @options)).must_equal 2
    end

    it "initializes from object" do
      _(::Quickjs.eval_code("new URLSearchParams({ foo: 'bar' }).get('foo')", @options)).must_equal "bar"
    end

    it "initializes from array of pairs" do
      _(::Quickjs.eval_code("new URLSearchParams([['foo', 'bar']]).get('foo')", @options)).must_equal "bar"
    end

    it "encodes special characters" do
      _(::Quickjs.eval_code("new URLSearchParams('q=hello+world').get('q')", @options)).must_equal "hello world"
    end

    it "is linked to URL.searchParams" do
      code = <<~JS
        const u = new URL('https://example.com/?foo=bar');
        u.searchParams.get('foo')
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "bar"
    end

    it "updating searchParams updates URL.search" do
      code = <<~JS
        const u = new URL('https://example.com/?foo=bar');
        u.searchParams.set('foo', 'baz');
        u.search
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal "?foo=baz"
    end
  end
end
