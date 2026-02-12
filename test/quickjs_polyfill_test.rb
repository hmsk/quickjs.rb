# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

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

describe "PolyfillBlob" do
  before do
    @options = { features: [::Quickjs::POLYFILL_FILE] }
  end

  it "is not available without the polyfill" do
    _ { ::Quickjs.eval_code("new Blob()") }.must_raise Quickjs::ReferenceError
  end

  describe "constructor" do
    it "creates an empty blob with no arguments" do
      _(::Quickjs.eval_code("new Blob().size", @options)).must_equal 0
    end

    it "creates a blob from string parts" do
      _(::Quickjs.eval_code("new Blob(['hello', ' ', 'world']).size", @options)).must_equal 11
    end

    it "creates a blob with type option" do
      _(::Quickjs.eval_code("new Blob([], { type: 'text/plain' }).type", @options)).must_equal 'text/plain'
    end

    it "normalizes type to lowercase" do
      _(::Quickjs.eval_code("new Blob([], { type: 'Text/Plain' }).type", @options)).must_equal 'text/plain'
    end

    it "rejects type with non-ASCII characters" do
      _(::Quickjs.eval_code("new Blob([], { type: 'text/plàin' }).type", @options)).must_equal ''
    end

    it "creates a blob from ArrayBuffer" do
      code = "const buf = new ArrayBuffer(4); new Uint8Array(buf).set([1,2,3,4]); new Blob([buf]).size"
      _(::Quickjs.eval_code(code, @options)).must_equal 4
    end

    it "creates a blob from Uint8Array" do
      code = "new Blob([new Uint8Array([72, 105])]).size"
      _(::Quickjs.eval_code(code, @options)).must_equal 2
    end

    it "creates a blob from mixed parts including another Blob" do
      code = <<~JS
        const b1 = new Blob(['hello']);
        const b2 = new Blob([b1, ' world']);
        await b2.text()
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello world'
    end

    it "throws TypeError for non-array argument" do
      _ { ::Quickjs.eval_code("new Blob('hello')", @options) }.must_raise Quickjs::TypeError
    end
  end

  describe "size and type" do
    it "returns correct size for multibyte UTF-8" do
      # "café" is 5 bytes in UTF-8 (é is 2 bytes)
      _(::Quickjs.eval_code("new Blob(['café']).size", @options)).must_equal 5
    end

    it "returns empty string type by default" do
      _(::Quickjs.eval_code("new Blob().type", @options)).must_equal ''
    end
  end

  describe "slice" do
    it "slices a blob" do
      code = "await new Blob(['hello world']).slice(0, 5).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello'
    end

    it "slices with negative start" do
      code = "await new Blob(['hello world']).slice(-5).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'world'
    end

    it "slices with content type" do
      code = "new Blob(['test']).slice(0, 4, 'text/plain').type"
      _(::Quickjs.eval_code(code, @options)).must_equal 'text/plain'
    end

    it "returns empty blob for out-of-range slice" do
      code = "new Blob(['hi']).slice(10, 20).size"
      _(::Quickjs.eval_code(code, @options)).must_equal 0
    end
  end

  describe "text" do
    it "returns text content" do
      code = "await new Blob(['hello']).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello'
    end

    it "handles multibyte characters" do
      code = "await new Blob(['日本語']).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal '日本語'
    end
  end

  describe "arrayBuffer" do
    it "returns an ArrayBuffer with correct length" do
      code = "const buf = await new Blob(['hi']).arrayBuffer(); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 2
    end

    it "returns correct bytes" do
      code = <<~JS
        const buf = await new Blob(['AB']).arrayBuffer();
        const arr = new Uint8Array(buf);
        [arr[0], arr[1]].join(',')
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal '65,66'
    end
  end

  describe "toString and toStringTag" do
    it "has correct toString" do
      _(::Quickjs.eval_code("new Blob().toString()", @options)).must_equal '[object Blob]'
    end

    it "has correct toStringTag" do
      _(::Quickjs.eval_code("Object.prototype.toString.call(new Blob())", @options)).must_equal '[object Blob]'
    end
  end
end

describe "PolyfillFile" do
  before do
    @options = { features: [::Quickjs::POLYFILL_FILE] }
  end

  it "is not available without the polyfill" do
    _ { ::Quickjs.eval_code("new File([], 'test.txt')") }.must_raise Quickjs::ReferenceError
  end

  describe "constructor" do
    it "creates a file with name" do
      _(::Quickjs.eval_code("new File(['hello'], 'test.txt').name", @options)).must_equal 'test.txt'
    end

    it "creates a file with content from parts" do
      code = "await new File(['hello', ' world'], 'test.txt').text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello world'
    end

    it "has correct size" do
      _(::Quickjs.eval_code("new File(['abc'], 'test.txt').size", @options)).must_equal 3
    end

    it "accepts type option" do
      _(::Quickjs.eval_code("new File([], 'test.txt', { type: 'text/plain' }).type", @options)).must_equal 'text/plain'
    end

    it "has lastModified defaulting to now" do
      code = <<~JS
        const before = Date.now();
        const f = new File([], 'test.txt');
        const after = Date.now();
        f.lastModified >= before && f.lastModified <= after
      JS
      _(::Quickjs.eval_code(code, @options)).must_equal true
    end

    it "accepts custom lastModified" do
      _(::Quickjs.eval_code("new File([], 'test.txt', { lastModified: 1234567890 }).lastModified", @options)).must_equal 1234567890
    end

    it "throws TypeError with fewer than 2 arguments" do
      _ { ::Quickjs.eval_code("new File([])", @options) }.must_raise Quickjs::TypeError
    end
  end

  describe "inheritance from Blob" do
    it "is an instance of Blob" do
      _(::Quickjs.eval_code("new File([], 'test.txt') instanceof Blob", @options)).must_equal true
    end

    it "supports slice" do
      code = "await new File(['hello world'], 'test.txt').slice(0, 5).text()"
      _(::Quickjs.eval_code(code, @options)).must_equal 'hello'
    end

    it "supports arrayBuffer" do
      code = "const buf = await new File(['AB'], 'test.txt').arrayBuffer(); buf.byteLength"
      _(::Quickjs.eval_code(code, @options)).must_equal 2
    end
  end

  describe "toString and toStringTag" do
    it "has correct toString" do
      _(::Quickjs.eval_code("new File([], 'test.txt').toString()", @options)).must_equal '[object File]'
    end

    it "has correct toStringTag" do
      _(::Quickjs.eval_code("Object.prototype.toString.call(new File([], 'x'))", @options)).must_equal '[object File]'
    end
  end
end

describe "RubyFileProxy" do
  before do
    @tempfile = Tempfile.new(['test', '.txt'])
    @tempfile.write('hello world')
    @tempfile.flush
    @file = File.open(@tempfile.path, 'r')
  end

  after do
    @file.close
    @tempfile.close
    @tempfile.unlink
  end

  describe "with POLYFILL_FILE feature" do
    it "is an instance of File" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("get_file() instanceof File")).must_equal true
    end

    it "is an instance of Blob" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("get_file() instanceof Blob")).must_equal true
    end

    it "returns correct name (basename)" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      result = vm.eval_code("get_file().name")
      _(result).must_equal File.basename(@file.path)
    end

    it "returns correct size" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("get_file().size")).must_equal 11
    end

    it "returns empty string for type" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("get_file().type")).must_equal ''
    end

    it "returns lastModified as a number" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      result = vm.eval_code("typeof get_file().lastModified")
      _(result).must_equal 'number'
    end

    it "has correct toStringTag" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("Object.prototype.toString.call(get_file())")).must_equal '[object File]'
    end
  end

  describe "text()" do
    it "returns file content as string" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("await get_file().text()")).must_equal 'hello world'
    end

    it "can be called multiple times" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("await get_file().text()")).must_equal 'hello world'
      _(vm.eval_code("await get_file().text()")).must_equal 'hello world'
    end
  end

  describe "arrayBuffer()" do
    it "returns ArrayBuffer with correct byteLength" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      _(vm.eval_code("(await get_file().arrayBuffer()).byteLength")).must_equal 11
    end

    it "returns correct bytes" do
      vm = Quickjs::VM.new(features: [Quickjs::POLYFILL_FILE])
      vm.define_function(:get_file) { @file }
      code = <<~JS
        const buf = await get_file().arrayBuffer();
        const arr = new Uint8Array(buf);
        [arr[0], arr[1], arr[2], arr[3], arr[4]].join(',')
      JS
      _(vm.eval_code(code)).must_equal '104,101,108,108,111' # "hello"
    end
  end

  describe "without POLYFILL_FILE feature" do
    it "falls through to inspect string" do
      vm = Quickjs::VM.new
      vm.define_function(:get_file) { @file }
      result = vm.eval_code("get_file()")
      _(result).must_include '#<File:'
    end
  end
end
